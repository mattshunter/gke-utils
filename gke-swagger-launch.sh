#!/bin/bash

# Script to launch Swagger UI via GKE port forwarding
# Usage: ./gke-swagger-launch.sh --project PROJECT --service SERVICE --namespace NAMESPACE [--local-port PORT] [--remote-port PORT] [--swagger-path PATH]

set -e

# Default values
LOCAL_PORT=8080
REMOTE_PORT=8080
SWAGGER_PATH="/swagger-ui/index.html"
PROTOCOL="https"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --project|-p)
            PROJECT="$2"
            shift 2
            ;;
        --cluster|-c)
            CLUSTER="$2"
            shift 2
            ;;
        --zone|-z)
            ZONE="$2"
            shift 2
            ;;
        --region|-r)
            REGION="$2"
            shift 2
            ;;
        --service|-s)
            SERVICE="$2"
            shift 2
            ;;
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --local-port|-l)
            LOCAL_PORT="$2"
            shift 2
            ;;
        --remote-port|-R)
            REMOTE_PORT="$2"
            shift 2
            ;;
        --swagger-path)
            SWAGGER_PATH="$2"
            shift 2
            ;;
        --http)
            PROTOCOL="http"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 --project PROJECT --cluster CLUSTER --zone ZONE|--region REGION --service SERVICE --namespace NAMESPACE [OPTIONS]"
            echo ""
            echo "Required arguments:"
            echo "  --project, -p PROJECT       GCP project ID"
            echo "  --cluster, -c CLUSTER       GKE cluster name"
            echo "  --zone, -z ZONE             Zone for zonal cluster (use either --zone or --region)"
            echo "  --region, -r REGION         Region for regional cluster (use either --zone or --region)"
            echo "  --service, -s SERVICE       Kubernetes service name"
            echo "  --namespace, -n NAMESPACE   Kubernetes namespace"
            echo ""
            echo "Optional arguments:"
            echo "  --local-port, -l PORT       Local port for forwarding (default: 8080)"
            echo "  --remote-port, -R PORT      Remote port for forwarding (default: 8080)"
            echo "  --swagger-path PATH         Path to Swagger UI (default: /swagger-ui/index.html)"
            echo "  --http                      Use HTTP instead of HTTPS (default: HTTPS)"
            echo "  --help, -h                  Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Configuration directory and acknowledgement file
CONFIG_DIR="${HOME}/.config/gke-scripts"
ACK_FILE="${CONFIG_DIR}/.swagger-launch-acknowledged"

# Display security warning (only if not previously acknowledged)
if [[ ! -f "$ACK_FILE" ]]; then
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                            ⚠️  SECURITY WARNING ⚠️                           ║${NC}"
    echo -e "${RED}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                           ║${NC}"
    echo -e "${RED}║  THIS SCRIPT IS FOR INTERNAL DEVELOPMENT AND OPERATIONS USE ONLY         ║${NC}"
    echo -e "${RED}║                                                                           ║${NC}"
    echo -e "${RED}║  ❌ DO NOT use this script to provide API documentation to consumers      ║${NC}"
    echo -e "${RED}║                                                                           ║${NC}"
    echo -e "${RED}║  Using this script requires direct GCP environment access, which API     ║${NC}"
    echo -e "${RED}║  consumers should NEVER have. Providing this access violates security    ║${NC}"
    echo -e "${RED}║  boundaries and exposes production infrastructure.                       ║${NC}"
    echo -e "${RED}║                                                                           ║${NC}"
    echo -e "${RED}║  For API consumers:                                                       ║${NC}"
    echo -e "${RED}║  ✓ Publish OpenAPI/Swagger specs through proper documentation channels   ║${NC}"
    echo -e "${RED}║  ✓ Use API gateways or dedicated documentation portals                   ║${NC}"
    echo -e "${RED}║  ✓ Never grant GCP/GKE access to external consumers                      ║${NC}"
    echo -e "${RED}║                                                                           ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "I understand this is for internal use only and should not be shared with API consumers. Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled by user${NC}"
        exit 0
    fi
    
    # Save acknowledgement
    mkdir -p "$CONFIG_DIR"
    cat > "$ACK_FILE" <<EOF
# GKE Swagger Launch Script - Security Acknowledgement
# User acknowledged security warning on $(date)
# This script is for internal development and operations use only
# Should NOT be used to provide API documentation to external consumers
ACKNOWLEDGED=true
EOF
    echo -e "${GREEN}Acknowledgement saved. You will not be prompted again.${NC}"
    echo ""
fi

# Validate required parameters
if [[ -z "$PROJECT" || -z "$CLUSTER" || -z "$SERVICE" || -z "$NAMESPACE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 --project PROJECT --cluster CLUSTER --zone ZONE|--region REGION --service SERVICE --namespace NAMESPACE [OPTIONS]"
    echo "Use --help for more information"
    exit 1
fi

# Validate zone or region is provided
if [[ -z "$ZONE" && -z "$REGION" ]]; then
    echo -e "${RED}Error: Must specify either --zone or --region${NC}"
    echo "Use --help for more information"
    exit 1
fi

if [[ -n "$ZONE" && -n "$REGION" ]]; then
    echo -e "${RED}Error: Cannot specify both --zone and --region${NC}"
    echo "Use --help for more information"
    exit 1
fi

# Function to check if user is logged in to gcloud
check_gcloud_auth() {
    echo -e "${YELLOW}Checking Google Cloud authentication...${NC}"
    
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
        echo -e "${YELLOW}Not logged in. Initiating gcloud login...${NC}"
        gcloud auth login
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to authenticate with Google Cloud${NC}"
            exit 1
        fi
    else
        ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        echo -e "${GREEN}Already authenticated as: $ACTIVE_ACCOUNT${NC}"
    fi
}

# Function to set the active project
set_project() {
    echo -e "${YELLOW}Setting active project to: $PROJECT${NC}"
    gcloud config set project "$PROJECT"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to set project${NC}"
        exit 1
    fi
    echo -e "${GREEN}Project set successfully${NC}"
}

# Function to get cluster credentials and set kubectl context
get_cluster_credentials() {
    echo -e "${YELLOW}Getting credentials for cluster: $CLUSTER${NC}"
    
    if [[ -n "$ZONE" ]]; then
        echo -e "${YELLOW}Cluster type: Zonal (zone: $ZONE)${NC}"
        gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT"
    else
        echo -e "${YELLOW}Cluster type: Regional (region: $REGION)${NC}"
        gcloud container clusters get-credentials "$CLUSTER" --region="$REGION" --project="$PROJECT"
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to get cluster credentials${NC}"
        exit 1
    fi
    echo -e "${GREEN}Cluster credentials configured${NC}"
}

# Function to check if port is already in use
check_port() {
    if lsof -Pi :$LOCAL_PORT -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        echo -e "${YELLOW}Warning: Port $LOCAL_PORT is already in use${NC}"
        read -p "Kill the process using this port? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            lsof -ti:$LOCAL_PORT | xargs kill -9
            echo -e "${GREEN}Port cleared${NC}"
            sleep 1
        else
            echo -e "${RED}Cannot proceed with port $LOCAL_PORT in use${NC}"
            exit 1
        fi
    fi
}

# Function to start port forwarding
start_port_forward() {
    echo -e "${YELLOW}Setting up port forwarding...${NC}"
    echo -e "Service: ${GREEN}$SERVICE${NC}"
    echo -e "Namespace: ${GREEN}$NAMESPACE${NC}"
    echo -e "Port mapping: ${GREEN}$LOCAL_PORT:$REMOTE_PORT${NC}"
    
    # Start port forwarding in background
    kubectl port-forward "$SERVICE" -n "$NAMESPACE" "$LOCAL_PORT:$REMOTE_PORT" --insecure-skip-tls-verify &
    PORT_FORWARD_PID=$!
    
    # Wait a moment for port forwarding to establish
    echo -e "${YELLOW}Waiting for port forwarding to establish...${NC}"
    sleep 3
    
    # Check if port forwarding is still running
    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        echo -e "${RED}Port forwarding failed to start${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Port forwarding established (PID: $PORT_FORWARD_PID)${NC}"
}

# Function to open browser
open_browser() {
    URL="${PROTOCOL}://localhost:${LOCAL_PORT}${SWAGGER_PATH}"
    echo -e "${YELLOW}Opening browser to: ${GREEN}$URL${NC}"
    
    # Detect OS and open browser accordingly
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open "$URL"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v xdg-open &> /dev/null; then
            xdg-open "$URL"
        elif command -v gnome-open &> /dev/null; then
            gnome-open "$URL"
        else
            echo -e "${YELLOW}Could not detect browser opener. Please open manually: $URL${NC}"
        fi
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
        # Windows (Git Bash or similar)
        start "$URL"
    else
        echo -e "${YELLOW}Unknown OS. Please open manually: $URL${NC}"
    fi
}

# Function to handle cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [[ ! -z "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null
        echo -e "${GREEN}Port forwarding stopped${NC}"
    fi
    exit 0
}

# Set up trap to cleanup on script exit
trap cleanup SIGINT SIGTERM EXIT

# Main execution
echo -e "${GREEN}=== GKE Swagger UI Launcher ===${NC}\n"

check_gcloud_auth
set_project
get_cluster_credentials
check_port
start_port_forward
open_browser

echo -e "\n${GREEN}=== Setup Complete ===${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop port forwarding and exit${NC}\n"

# Note about SSL certificates
if [[ "$PROTOCOL" == "https" ]]; then
    echo -e "${YELLOW}Note: If you see SSL certificate warnings in the browser:${NC}"
    echo -e "  - Click 'Advanced' and proceed anyway (varies by browser)"
    echo -e "  - Or use --http flag if the service supports HTTP${NC}\n"
fi

# Keep script running to maintain port forwarding
wait $PORT_FORWARD_PID
