#!/usr/bin/env bash

# Script: gke-view-logs.sh
# Description: Create tmux split-pane view of pod logs in a GKE cluster using xpanes
# Author: Generated for GKE log monitoring
# Usage: ./gke-view-logs.sh -p PROJECT -c CLUSTER -z ZONE||-r REGION -n NAMESPACE [-C CONTAINER]

set -euo pipefail

# Default values
PROJECT_NAME=""
CLUSTER_NAME=""
ZONE=""
REGION=""
NAMESPACE=""
CONTAINER=""
ALL_CONTAINERS=false
SINCE_TIME=""
UNTIL_TIME=""
VERBOSE=false
AUTO_LOGIN=false
FOLLOW=true
TAIL_LINES=100

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Create a tmux split-pane view of pod logs in a GKE cluster using xpanes.

OPTIONS:
    -p, --project PROJECT       GCP project name (required)
    -c, --cluster CLUSTER       GKE cluster name (required)
    -z, --zone ZONE            Cluster zone (for zonal clusters)
    -r, --region REGION        Cluster region (for regional clusters)
    -n, --namespace NAMESPACE   Kubernetes namespace (required)
    -C, --container CONTAINER   Specific container name to tail (optional)
    -A, --all-containers       Show all containers (creates pane per container, default: first container only)
    -t, --tail LINES           Number of lines to tail (default: 100)
    -s, --since TIME           Show logs since timestamp (RFC3339 or relative like '1h', '30m')
    -u, --until TIME           Show logs until timestamp (RFC3339 format)
    -F, --no-follow            Don't follow logs (default: follow)
    -a, --auto-login           Automatically run gcloud auth login
    -v, --verbose              Verbose output
    -h, --help                 Show this help message

EXAMPLES:
    $(basename "$0") -p my-project -c prod-cluster -z us-central1-a -n search-service
    $(basename "$0") -p my-project -c dev-cluster -r us-west1 -n istio-system -C envoy
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c -n default -A
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c -n default -t 50
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c -n default -s 2025-01-30T10:00:00Z -u 2025-01-31T10:00:00Z
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c -n default -s 1h -t 100

DESCRIPTION:
    This script uses xpanes (tmux-based) to create a split-pane terminal view showing
    logs from all pods in the specified namespace. Each pod gets its own pane, making
    it easy to monitor multiple pods simultaneously.
    If a container name is specified with -C, only logs from that container will be shown.
    If -A (--all-containers) is used, each container gets its own pane (labeled pod/container).
    Otherwise, only the first container in each pod will be shown.
    Otherwise, the script will attempt to show logs from all containers in each pod.

PREREQUISITES:
    - gcloud CLI installed and configured
    - kubectl installed
    - xpanes installed (brew install xpanes on macOS)
    - tmux installed (dependency of xpanes)
    - Appropriate GCP and Kubernetes permissions

INSTALLATION:
    macOS:    brew install xpanes
    Linux:    See https://github.com/greymd/tmux-xpanes for installation options

EOF
    exit 0
}

# Logging functions
log() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[INFO]${NC} $*" >&2
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -z|--zone)
            ZONE="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -C|--container)
            CONTAINER="$2"
            shift 2
            ;;
        -A|--all-containers)
            ALL_CONTAINERS=true
            shift
            ;;
        -t|--tail)
            TAIL_LINES="$2"
            shift 2
            ;;
        -s|--since)
            SINCE_TIME="$2"
            shift 2
            ;;
        -u|--until)
            UNTIL_TIME="$2"
            shift 2
            ;;
        -F|--no-follow)
            FOLLOW=false
            shift
            ;;
        -a|--auto-login)
            AUTO_LOGIN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$PROJECT_NAME" ]]; then
    echo -e "${RED}Error: Missing required argument --project${NC}"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -z "$CLUSTER_NAME" ]]; then
    echo -e "${RED}Error: Missing required argument --cluster${NC}"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -z "$NAMESPACE" ]]; then
    echo -e "${RED}Error: Missing required argument --namespace${NC}"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -z "$ZONE" ]] && [[ -z "$REGION" ]]; then
    echo -e "${RED}Error: Either --zone or --region must be specified${NC}"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -n "$ZONE" ]] && [[ -n "$REGION" ]]; then
    echo -e "${RED}Error: Cannot specify both --zone and --region${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Disable follow if until time is specified
if [[ -n "$UNTIL_TIME" ]]; then
    FOLLOW=false
fi

# Check for required tools
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v gcloud &> /dev/null; then
        missing_tools+=("gcloud")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v xpanes &> /dev/null; then
        missing_tools+=("xpanes")
    fi
    
    if ! command -v tmux &> /dev/null; then
        missing_tools+=("tmux")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}\n\nPlease install missing tools:\n  macOS:  brew install ${missing_tools[*]}\n  Linux:  See --help for installation instructions"
    fi
    
    log "All prerequisites satisfied"
}

# Function to authenticate with GCP
authenticate_gcp() {
    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    
    if [[ -z "$active_account" ]]; then
        if [ "$AUTO_LOGIN" = true ]; then
            log "No active account found. Running gcloud auth login..."
            gcloud auth login || error "Authentication failed"
        else
            error "No active GCP account found. Run 'gcloud auth login' or use --auto-login"
        fi
    else
        log "Already authenticated as: $active_account"
    fi
}

# Function to set the active project
set_project() {
    log "Setting active project to: $PROJECT_NAME"
    gcloud config set project "$PROJECT_NAME" >/dev/null 2>&1 || error "Failed to set project"
    log "Project set successfully"
}

# Function to get cluster credentials
get_cluster_credentials() {
    local location_flag
    local location_value
    
    if [[ -n "$ZONE" ]]; then
        location_flag="--zone"
        location_value="$ZONE"
        log "Getting credentials for cluster: $CLUSTER_NAME in zone: $ZONE"
    else
        location_flag="--region"
        location_value="$REGION"
        log "Getting credentials for cluster: $CLUSTER_NAME in region: $REGION"
    fi
    
    local output
    if [ "$VERBOSE" = true ]; then
        output=$(gcloud container clusters get-credentials "$CLUSTER_NAME" \
            $location_flag "$location_value" \
            --project "$PROJECT_NAME" 2>&1)
        local result=$?
        echo "$output" >&2
        if [ $result -ne 0 ]; then
            error "Failed to get cluster credentials. Please verify cluster name and zone/region are correct."
        fi
    else
        gcloud container clusters get-credentials "$CLUSTER_NAME" \
            $location_flag "$location_value" \
            --project "$PROJECT_NAME" >/dev/null 2>&1 || \
            error "Failed to get cluster credentials. Please verify cluster name and zone/region are correct."
    fi
    
    log "Successfully retrieved cluster credentials"
}

# Function to get pods in namespace
get_pods() {
    log "Getting pods in namespace: $NAMESPACE"
    
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" --insecure-skip-tls-verify=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [[ -z "$pods" ]]; then
        error "No pods found in namespace: $NAMESPACE"
    fi
    
    echo "$pods"
}

# Function to get containers for a pod
get_containers() {
    local pod=$1
    kubectl get pod "$pod" -n "$NAMESPACE" --insecure-skip-tls-verify=true \
        -o jsonpath='{.spec.containers[*].name}' 2>/dev/null
}

# Main execution
main() {
    echo -e "${CYAN}${BOLD}GKE Log Viewer with xpanes${NC}"
    echo -e "${CYAN}================================${NC}"
    echo ""
    
    check_prerequisites
    authenticate_gcp
    set_project
    get_cluster_credentials
    
    echo -e "${GREEN}✓${NC} Connected to cluster: ${BOLD}$CLUSTER_NAME${NC}"
    echo -e "${GREEN}✓${NC} Namespace: ${BOLD}$NAMESPACE${NC}"
    
    # Get list of pods
    local pods
    pods=$(get_pods)
    local pod_array=($pods)
    local pod_count=${#pod_array[@]}
    
    if [ $pod_count -eq 0 ]; then
        error "No pods found in namespace: $NAMESPACE"
    fi
    
    echo -e "${GREEN}✓${NC} Found ${BOLD}$pod_count${NC} pod(s)"
    echo ""
    
    # Build list of pod/container combinations
    local targets=()
    local pane_count=0
    
    if [[ -n "$CONTAINER" ]]; then
        # Specific container requested
        echo -e "${BLUE}Container:${NC} $CONTAINER"
        for pod in $pods; do
            targets+=("$pod")
        done
        pane_count=$pod_count
        
        # Build command for specific container
        local logs_cmd="kubectl logs {} --insecure-skip-tls-verify=true -n $NAMESPACE -c $CONTAINER --tail=$TAIL_LINES"
        if [[ -n "$SINCE_TIME" ]]; then
            logs_cmd="$logs_cmd --since-time=$SINCE_TIME"
        fi
        if [[ -n "$UNTIL_TIME" ]]; then
            logs_cmd="$logs_cmd | awk '\$0 < \"$UNTIL_TIME\"'"
        fi
        if [ "$FOLLOW" = true ]; then
            logs_cmd="$logs_cmd -f"
        fi
    elif [ "$ALL_CONTAINERS" = true ]; then
        # Show all containers - create pod/container targets
        echo -e "${BLUE}Mode:${NC} All containers"
        for pod in $pods; do
            local containers
            containers=$(get_containers "$pod")
            for container in $containers; do
                targets+=("$pod/$container")
                ((pane_count++))
            done
        done
        
        # Build command that extracts pod and container from target
        local logs_cmd='kubectl logs $(echo {} | cut -d/ -f1) --insecure-skip-tls-verify=true -n '"$NAMESPACE"' -c $(echo {} | cut -d/ -f2) --tail='"$TAIL_LINES"
        if [[ -n "$SINCE_TIME" ]]; then
            logs_cmd="$logs_cmd --since-time=$SINCE_TIME"
        fi
        if [[ -n "$UNTIL_TIME" ]]; then
            logs_cmd="$logs_cmd | awk '\$0 < \"$UNTIL_TIME\"'"
        fi
        if [ "$FOLLOW" = true ]; then
            logs_cmd="$logs_cmd -f"
        fi
    else
        # Default: first container only
        echo -e "${BLUE}Mode:${NC} First container only (use -A for all containers)"
        for pod in $pods; do
            targets+=("$pod")
        done
        pane_count=$pod_count
        
        # Build command without container specification (uses first container)
        local logs_cmd="kubectl logs {} --insecure-skip-tls-verify=true -n $NAMESPACE --tail=$TAIL_LINES"
        if [[ -n "$SINCE_TIME" ]]; then
            logs_cmd="$logs_cmd --since-time=$SINCE_TIME"
        fi
        if [[ -n "$UNTIL_TIME" ]]; then
            logs_cmd="$logs_cmd | awk '\$0 < \"$UNTIL_TIME\"'"
        fi
        if [ "$FOLLOW" = true ]; then
            logs_cmd="$logs_cmd -f"
        fi
    fi
    
    if [ "$FOLLOW" = true ]; then
        echo -e "${BLUE}Following:${NC} Yes (tail: $TAIL_LINES lines)"
    else
        echo -e "${BLUE}Following:${NC} No (tail: $TAIL_LINES lines)"
    fi
    
    echo ""
    echo -e "${YELLOW}Launching xpanes with $pane_count panes...${NC}"
    echo -e "${YELLOW}Use Ctrl+B then arrow keys to navigate between panes${NC}"
    echo -e "${YELLOW}Use Ctrl+B then 'd' to detach from tmux session${NC}"
    echo ""
    
    # Give user a moment to read the instructions
    sleep 2
    
    # Launch xpanes
    log "Executing: xpanes -c '$logs_cmd' ${targets[*]}"
    xpanes -c "$logs_cmd" "${targets[@]}"
}

# Run main function
main
