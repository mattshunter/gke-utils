#!/bin/bash

# Script to discover and explore GCP projects, GKE clusters, and Kubernetes resources
# Usage: ./gke-discover.sh [OPTIONS]

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Cache directory
CACHE_DIR="${HOME}/.cache/gke-discover"
CACHE_TTL=3600  # Cache Time To Live in seconds (1 hour)

# Parse command line arguments
SHOW_PROJECTS=false
SHOW_CLUSTERS=false
SHOW_NAMESPACES=false
SHOW_SERVICES=false
SHOW_PODS=false
SHOW_ALL=false
PROJECT=""
CLUSTER=""
NAMESPACE=""
NO_CACHE=false
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --projects)
            SHOW_PROJECTS=true
            shift
            ;;
        --clusters)
            SHOW_CLUSTERS=true
            shift
            ;;
        --namespaces)
            SHOW_NAMESPACES=true
            shift
            ;;
        --services)
            SHOW_SERVICES=true
            shift
            ;;
        --pods)
            SHOW_PODS=true
            shift
            ;;
        --all)
            SHOW_ALL=true
            shift
            ;;
        --project|-p)
            PROJECT="$2"
            shift 2
            ;;
        --cluster|-c)
            CLUSTER="$2"
            shift 2
            ;;
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --interactive|-i)
            INTERACTIVE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Discovery modes:"
            echo "  --projects              List all accessible GCP projects"
            echo "  --clusters              List all GKE clusters (requires --project)"
            echo "  --namespaces            List all namespaces (requires --project and --cluster)"
            echo "  --services              List all services (requires --project, --cluster, and optionally --namespace)"
            echo "  --pods                  List all pods (requires --project, --cluster, and optionally --namespace)"
            echo "  --all                   Show everything (interactive discovery)"
            echo "  --interactive, -i       Interactive mode - walk through discovery step by step"
            echo ""
            echo "Options:"
            echo "  --project, -p PROJECT   Specify GCP project"
            echo "  --cluster, -c CLUSTER   Specify GKE cluster"
            echo "  --namespace, -n NS      Specify Kubernetes namespace"
            echo "  --no-cache              Skip cache and fetch fresh data"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --projects                           # List all projects"
            echo "  $0 --clusters --project my-project      # List clusters in a project"
            echo "  $0 --all --project my-project           # Discover everything in a project"
            echo "  $0 --interactive                        # Guided discovery"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Function to check cache validity
is_cache_valid() {
    local cache_file="$1"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    if [[ "$NO_CACHE" == true ]]; then
        return 1
    fi
    
    local file_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)))
    
    if [[ $file_age -gt $CACHE_TTL ]]; then
        return 1
    fi
    
    return 0
}

# Function to check if user is logged in to gcloud
check_gcloud_auth() {
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
        echo -e "${YELLOW}Not logged in. Initiating gcloud login...${NC}"
        gcloud auth login
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to authenticate with Google Cloud${NC}"
            exit 1
        fi
    else
        ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        echo -e "${GREEN}✓ Authenticated as: $ACTIVE_ACCOUNT${NC}\n"
    fi
}

# Function to list all accessible projects
list_projects() {
    echo -e "${BOLD}${BLUE}=== Google Cloud Projects ===${NC}\n"
    
    local cache_file="$CACHE_DIR/projects.cache"
    local list_cache="$CACHE_DIR/projects-list.cache"
    
    if is_cache_valid "$cache_file" && [[ -f "$list_cache" ]]; then
        echo -e "${CYAN}(Using cached data)${NC}\n"
        cat "$cache_file"
    else
        echo -e "${YELLOW}Fetching projects...${NC}\n"
        
        local projects=$(gcloud projects list --format="table(projectId:label='PROJECT_ID',name:label='NAME',projectNumber:label='NUMBER')" 2>/dev/null)
        
        if [[ -z "$projects" ]]; then
            echo -e "${RED}No projects found or unable to list projects${NC}"
            return 1
        fi
        
        echo "$projects" | tee "$cache_file" > /dev/null
        
        # Save project IDs to array cache
        gcloud projects list --format="value(projectId)" 2>/dev/null > "$list_cache"
    fi
    
    # Display numbered list
    echo -e "\n${BOLD}${BLUE}Project Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
    PROJECT_LIST=()
    while IFS= read -r proj; do
        PROJECT_LIST+=("$proj")
    done < "$list_cache"
    
    local i=1
    for proj in "${PROJECT_LIST[@]}"; do
        echo -e "${CYAN}[$i]${NC} $proj"
        ((i++))
    done
    
    local count=${#PROJECT_LIST[@]}
    echo -e "\n${GREEN}Total: $count project(s)${NC}"
}

# Function to list clusters in a project
list_clusters() {
    local proj="${1:-$PROJECT}"
    
    if [[ -z "$proj" ]]; then
        echo -e "${RED}Error: Project not specified${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${BLUE}=== GKE Clusters in Project: $proj ===${NC}\n"
    
    local cache_file="$CACHE_DIR/clusters-${proj}.cache"
    local list_cache="$CACHE_DIR/clusters-${proj}-list.cache"
    
    if is_cache_valid "$cache_file" && [[ -f "$list_cache" ]]; then
        echo -e "${CYAN}(Using cached data)${NC}\n"
        cat "$cache_file"
    else
        echo -e "${YELLOW}Fetching clusters...${NC}\n"
        
        # Get both zonal and regional clusters
        local clusters=$(gcloud container clusters list --project="$proj" --format="table(name:label='CLUSTER_NAME',location:label='LOCATION',locationType:label='TYPE',currentMasterVersion:label='VERSION',currentNodeCount:label='NODES',status:label='STATUS')" 2>/dev/null)
        
        if [[ -z "$clusters" ]] || ! echo "$clusters" | grep -q "CLUSTER_NAME"; then
            echo -e "${YELLOW}No clusters found in project $proj${NC}"
            return 0
        fi
        
        echo "$clusters" | tee "$cache_file" > /dev/null
        
        # Save cluster names to array cache
        gcloud container clusters list --project="$proj" --format="value(name)" 2>/dev/null > "$list_cache"
    fi
    
    # Display numbered list
    CLUSTER_LIST=()
    while IFS= read -r cluster; do
        CLUSTER_LIST+=("$cluster")
    done < "$list_cache"
    
    echo -e "\n${BOLD}${BLUE}Cluster Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
    local i=1
    for cluster in "${CLUSTER_LIST[@]}"; do
        echo -e "${CYAN}[$i]${NC} $cluster"
        ((i++))
    done
    
    local count=${#CLUSTER_LIST[@]}
    echo -e "\n${GREEN}Total: $count cluster(s)${NC}"
}

# Function to detect if insecure-skip-tls-verify is needed
check_tls_verify_needed() {
    # Try kubectl without the flag first
    if kubectl cluster-info >/dev/null 2>&1; then
        # Works without the flag
        NEEDS_INSECURE_SKIP_TLS="false"
        return 0
    fi
    
    # Try with the flag
    if kubectl cluster-info --insecure-skip-tls-verify=true >/dev/null 2>&1; then
        # Works with the flag, so it's needed
        NEEDS_INSECURE_SKIP_TLS="true"
        return 0
    fi
    
    # Neither works, default to requiring the flag
    NEEDS_INSECURE_SKIP_TLS="true"
    return 1
}

# Function to get cluster credentials
get_credentials() {
    local proj="$1"
    local cluster="$2"
    local location="$3"
    local location_type="$4"
    
    echo -e "${YELLOW}Getting credentials for cluster: $cluster${NC}"
    
    if [[ "$location_type" == "ZONAL" ]] || [[ "$location" =~ -[a-z]$ ]]; then
        echo -e "${CYAN}  Cluster type: Zonal (zone: $location)${NC}"
        gcloud container clusters get-credentials "$cluster" --zone="$location" --project="$proj"
    else
        echo -e "${CYAN}  Cluster type: Regional (region: $location)${NC}"
        gcloud container clusters get-credentials "$cluster" --region="$location" --project="$proj"
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to get cluster credentials${NC}"
        return 1
    fi
    echo -e "${GREEN}Cluster credentials configured${NC}"
    
    # Check if insecure-skip-tls-verify is needed
    echo -e "${YELLOW}Checking TLS configuration...${NC}"
    if check_tls_verify_needed; then
        if [[ "$NEEDS_INSECURE_SKIP_TLS" == "true" ]]; then
            echo -e "${YELLOW}Note: Cluster requires --insecure-skip-tls-verify flag${NC}"
        else
            echo -e "${GREEN}TLS verification enabled${NC}"
        fi
    fi
    
    return 0
}

# Function to list namespaces
list_namespaces() {
    echo -e "${BOLD}${BLUE}=== Namespaces ===${NC}\n"
    
    echo -e "${YELLOW}Fetching namespaces...${NC}"
    local namespaces=$(kubectl get namespaces --insecure-skip-tls-verify=true --no-headers 2>&1)
    local kubectl_exit=$?
    
    if [ $kubectl_exit -ne 0 ]; then
        echo -e "${RED}Unable to connect to cluster${NC}"
        echo -e "${YELLOW}Error details:${NC}"
        echo "$namespaces" | head -5
        return 1
    fi
    
    if [[ -z "$namespaces" ]]; then
        echo -e "${RED}No namespaces found${NC}"
        return 1
    fi
    
    # Build namespace list array
    NAMESPACE_LIST=()
    while IFS= read -r line; do
        local ns_name=$(echo "$line" | awk '{print $1}')
        local ns_status=$(echo "$line" | awk '{print $2}')
        NAMESPACE_LIST+=("$ns_name")
    done <<< "$namespaces"
    
    # Display numbered list
    local i=1
    while IFS= read -r line; do
        local ns_name=$(echo "$line" | awk '{print $1}')
        local ns_status=$(echo "$line" | awk '{print $2}')
        echo -e "${CYAN}[$i]${NC} $ns_name ($ns_status)"
        ((i++))
    done <<< "$namespaces"
    
    local count=${#NAMESPACE_LIST[@]}
    echo -e "\n${GREEN}Total: $count namespace(s)${NC}"
}

# Function to list services
list_services() {
    local ns="${1:-$NAMESPACE}"
    
    if [[ -n "$ns" ]]; then
        echo -e "${BOLD}${BLUE}=== Services in Namespace: $ns ===${NC}\n"
        kubectl get services -n "$ns" --insecure-skip-tls-verify=true 2>/dev/null
    else
        echo -e "${BOLD}${BLUE}=== Services (All Namespaces) ===${NC}\n"
        kubectl get services --all-namespaces --insecure-skip-tls-verify=true 2>/dev/null
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to list services${NC}"
        return 1
    fi
}

# Function to list pods
list_pods() {
    local ns="${1:-$NAMESPACE}"
    
    if [[ -n "$ns" ]]; then
        echo -e "${BOLD}${BLUE}=== Pods in Namespace: $ns ===${NC}\n"
        kubectl get pods -n "$ns" -o wide --insecure-skip-tls-verify=true 2>/dev/null
    else
        echo -e "${BOLD}${BLUE}=== Pods (All Namespaces) ===${NC}\n"
        kubectl get pods --all-namespaces -o wide --insecure-skip-tls-verify=true 2>/dev/null
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to list pods${NC}"
        return 1
    fi
}

# Function for interactive mode
interactive_mode() {
    echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║        GKE Interactive Discovery Tool                     ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}\n"
    
    # Step 1: Select project
    list_projects
    echo ""
    read -p "Enter project number or ID (or 'q' to quit): " selected_project
    
    if [[ "$selected_project" == "q" ]]; then
        exit 0
    fi
    
    if [[ -z "$selected_project" ]]; then
        echo -e "${RED}No project selected${NC}"
        exit 0
    fi
    
    # Check if input is a number
    if [[ "$selected_project" =~ ^[0-9]+$ ]]; then
        local idx=$((selected_project - 1))
        if [[ $idx -ge 0 && $idx -lt ${#PROJECT_LIST[@]} ]]; then
            PROJECT="${PROJECT_LIST[$idx]}"
            echo -e "${GREEN}Selected: $PROJECT${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"
            exit 1
        fi
    else
        PROJECT="$selected_project"
    fi
    echo ""
    
    # Step 2: Select cluster
    list_clusters "$PROJECT"
    echo ""
    read -p "Enter cluster number or name (or 'q' to quit): " selected_cluster
    
    if [[ "$selected_cluster" == "q" ]]; then
        exit 0
    fi
    
    if [[ -z "$selected_cluster" ]]; then
        echo -e "${RED}No cluster selected${NC}"
        exit 0
    fi
    
    # Check if input is a number
    if [[ "$selected_cluster" =~ ^[0-9]+$ ]]; then
        local idx=$((selected_cluster - 1))
        if [[ $idx -ge 0 && $idx -lt ${#CLUSTER_LIST[@]} ]]; then
            CLUSTER="${CLUSTER_LIST[$idx]}"
            echo -e "${GREEN}Selected: $CLUSTER${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"
            exit 1
        fi
    else
        CLUSTER="$selected_cluster"
    fi
    echo ""
    
    # Get cluster location
    local cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
    local location=$(echo "$cluster_info" | awk '{print $1}')
    local location_type=$(echo "$cluster_info" | awk '{print $2}')
    
    if [[ -z "$location" ]]; then
        echo -e "${RED}Could not determine cluster location${NC}"
        exit 1
    fi
    
    # Get credentials
    get_credentials "$PROJECT" "$CLUSTER" "$location" "$location_type"
    echo ""
    
    # Step 3: Explore resources
    while true; do
        echo -e "${BOLD}${BLUE}Exploration Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        echo "[1] Namespaces"
        echo "[2] Services (all namespaces)"
        echo "[3] Services (specific namespace)"
        echo "[4] Pods (all namespaces)"
        echo "[5] Pods (specific namespace)"
        echo "[6] Generate command template"
        echo "[q] Quit"
        echo ""
        read -p "Select option: " option
        echo ""
        
        case $option in
            1)
                list_namespaces
                echo ""
                ;;
            2)
                list_services
                echo ""
                ;;
            3)
                list_namespaces
                echo ""
                read -p "Enter namespace number or name: " ns_input
                
                # Check if input is a number
                if [[ "$ns_input" =~ ^[0-9]+$ ]]; then
                    local idx=$((ns_input - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#NAMESPACE_LIST[@]} ]]; then
                        ns="${NAMESPACE_LIST[$idx]}"
                        echo -e "${GREEN}Selected: $ns${NC}"
                    else
                        echo -e "${RED}Invalid selection${NC}"
                        continue
                    fi
                else
                    ns="$ns_input"
                fi
                
                list_services "$ns"
                echo ""
                ;;
            4)
                list_pods
                echo ""
                ;;
            5)
                list_namespaces
                echo ""
                read -p "Enter namespace number or name: " ns_input
                
                # Check if input is a number
                if [[ "$ns_input" =~ ^[0-9]+$ ]]; then
                    local idx=$((ns_input - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#NAMESPACE_LIST[@]} ]]; then
                        ns="${NAMESPACE_LIST[$idx]}"
                        echo -e "${GREEN}Selected: $ns${NC}"
                    else
                        echo -e "${RED}Invalid selection${NC}"
                        continue
                    fi
                else
                    ns="$ns_input"
                fi
                
                list_pods "$ns"
                echo ""
                ;;
            6)
                generate_command_template
                echo ""
                ;;
            q|Q)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}\n"
                ;;
        esac
    done
}

# Function to generate command templates
generate_command_template() {
    echo -e "${BOLD}${GREEN}=== Command Templates ===${NC}\n"
    
    # Determine location parameters
    local location=""
    local location_type=""
    local zone_param=""
    local region_param=""
    local insecure_flag=""
    
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        local cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
        location=$(echo "$cluster_info" | awk '{print $1}')
        location_type=$(echo "$cluster_info" | awk '{print $2}')
        
        if [[ "$location_type" == "ZONAL" ]] || [[ "$location" =~ -[a-z]$ ]]; then
            zone_param="--zone $location"
        else
            region_param="--region $location"
        fi
        
        # Add insecure flag if needed
        if [[ "${NEEDS_INSECURE_SKIP_TLS:-true}" == "true" ]]; then
            insecure_flag="--insecure-skip-tls-verify"
        fi
    fi
    
    # gke-swagger-launch.sh
    echo -e "${BOLD}${BLUE}Swagger UI Launcher:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        if [[ -n "$zone_param" ]]; then
            echo "./gke-swagger-launch.sh --project $PROJECT --cluster $CLUSTER $zone_param --service SERVICE_NAME --namespace NAMESPACE"
        else
            echo "./gke-swagger-launch.sh --project $PROJECT --cluster $CLUSTER $region_param --service SERVICE_NAME --namespace NAMESPACE"
        fi
    else
        echo "./gke-swagger-launch.sh --project PROJECT_ID --cluster CLUSTER_NAME --zone ZONE --service SERVICE_NAME --namespace NAMESPACE"
    fi
    
    if [[ -n "$insecure_flag" ]]; then
        echo -e "${YELLOW}Note: Add $insecure_flag if needed for kubectl commands${NC}"
    fi
    
    echo ""
    
    # gke-view-logs.sh
    echo -e "${BOLD}${BLUE}View Logs (tmux/xpanes):${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        if [[ -n "$zone_param" ]]; then
            echo "./gke-view-logs.sh -p $PROJECT -c $CLUSTER $zone_param -n NAMESPACE"
        else
            echo "./gke-view-logs.sh -p $PROJECT -c $CLUSTER $region_param -n NAMESPACE"
        fi
    else
        echo "./gke-view-logs.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
    fi
    
    echo ""
    
    # gke-restart-status.sh
    echo -e "${BOLD}${BLUE}Pod Restart Status:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        if [[ -n "$zone_param" ]]; then
            echo "./gke-restart-status.sh -p $PROJECT -c $CLUSTER $zone_param -n NAMESPACE"
        else
            echo "./gke-restart-status.sh -p $PROJECT -c $CLUSTER $region_param -n NAMESPACE"
        fi
        echo "./gke-restart-status.sh -p $PROJECT -c $CLUSTER ${zone_param}${region_param} --all-namespaces"
    else
        echo "./gke-restart-status.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
        echo "./gke-restart-status.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE --all-namespaces"
    fi
    
    echo ""
    
    # gke-cert-check.sh
    echo -e "${BOLD}${BLUE}Certificate Check:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]] && [[ -n "$location" ]]; then
        echo "./gke-cert-check.sh -p $PROJECT -c $CLUSTER -z $location -n NAMESPACE"
        echo "./gke-cert-check.sh -p $PROJECT -c $CLUSTER -z $location -n NAMESPACE -s SECRET_NAME"
    else
        echo "./gke-cert-check.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
        echo "./gke-cert-check.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE -s SECRET_NAME"
    fi
    
    echo ""
    
    # Diagnostic scripts
    echo -e "${BOLD}${BLUE}Diagnostic Scripts:${NC}"
    
    echo -e "${YELLOW}Diagnose Probe Failures:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        if [[ -n "$zone_param" ]]; then
            echo "./gke-diagnose-probes.sh -p $PROJECT -c $CLUSTER $zone_param -n NAMESPACE"
        else
            echo "./gke-diagnose-probes.sh -p $PROJECT -c $CLUSTER $region_param -n NAMESPACE"
        fi
    else
        echo "./gke-diagnose-probes.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
    fi
    
    echo ""
    echo -e "${YELLOW}Diagnose Evictions:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]] && [[ -n "$location" ]]; then
        echo "./gke-diagnose-evictions.sh -p $PROJECT -c $CLUSTER -z $location -n NAMESPACE"
        echo "./gke-diagnose-evictions.sh -p $PROJECT -c $CLUSTER -z $location --all-namespaces"
    else
        echo "./gke-diagnose-evictions.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
        echo "./gke-diagnose-evictions.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE --all-namespaces"
    fi
    
    echo ""
    echo -e "${YELLOW}Diagnose Shutdown Issues:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        if [[ -n "$zone_param" ]]; then
            echo "./gke-diagnose-shutdown.sh -p $PROJECT -c $CLUSTER $zone_param -n NAMESPACE"
        else
            echo "./gke-diagnose-shutdown.sh -p $PROJECT -c $CLUSTER $region_param -n NAMESPACE"
        fi
    else
        echo "./gke-diagnose-shutdown.sh -p PROJECT_ID -c CLUSTER_NAME -z ZONE -n NAMESPACE"
    fi
    
    echo ""
    
    # kubectl commands
    echo -e "${BOLD}${BLUE}Common kubectl Commands:${NC}"
    if [[ -n "$PROJECT" ]] && [[ -n "$CLUSTER" ]]; then
        echo -e "${GREEN}# Already configured for project: $PROJECT, cluster: $CLUSTER${NC}"
    fi
    
    if [[ -n "$insecure_flag" ]]; then
        echo "kubectl get pods -n NAMESPACE $insecure_flag"
        echo "kubectl get services -n NAMESPACE $insecure_flag"
        echo "kubectl describe pod POD_NAME -n NAMESPACE $insecure_flag"
        echo "kubectl logs POD_NAME -n NAMESPACE $insecure_flag"
        echo "kubectl port-forward service/SERVICE_NAME -n NAMESPACE LOCAL_PORT:REMOTE_PORT $insecure_flag"
    else
        echo "kubectl get pods -n NAMESPACE"
        echo "kubectl get services -n NAMESPACE"
        echo "kubectl describe pod POD_NAME -n NAMESPACE"
        echo "kubectl logs POD_NAME -n NAMESPACE"
        echo "kubectl port-forward service/SERVICE_NAME -n NAMESPACE LOCAL_PORT:REMOTE_PORT"
    fi
}

# Main execution
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           GKE Resource Discovery Tool                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"

check_gcloud_auth

# Handle different modes
if [[ "$INTERACTIVE" == true ]] || [[ "$SHOW_ALL" == true && -z "$PROJECT" ]]; then
    interactive_mode
elif [[ "$SHOW_PROJECTS" == true ]]; then
    list_projects
elif [[ "$SHOW_CLUSTERS" == true ]]; then
    list_clusters "$PROJECT"
elif [[ "$SHOW_ALL" == true ]] && [[ -n "$PROJECT" ]]; then
    # Show everything for a specific project
    list_clusters "$PROJECT"
    echo -e "\n"
    
    # Ask which cluster to explore
    read -p "Enter cluster number or name to explore further (or press Enter to skip): " selected_cluster
    
    if [[ -n "$selected_cluster" ]]; then
        # Check if input is a number
        if [[ "$selected_cluster" =~ ^[0-9]+$ ]]; then
            local idx=$((selected_cluster - 1))
            if [[ $idx -ge 0 && $idx -lt ${#CLUSTER_LIST[@]} ]]; then
                CLUSTER="${CLUSTER_LIST[$idx]}"
                echo -e "${GREEN}Selected: $CLUSTER${NC}"
            else
                echo -e "${RED}Invalid selection${NC}"
                exit 1
            fi
        else
            CLUSTER="$selected_cluster"
        fi
        
        # Get cluster location
        cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
        location=$(echo "$cluster_info" | awk '{print $1}')
        location_type=$(echo "$cluster_info" | awk '{print $2}')
        
        get_credentials "$PROJECT" "$CLUSTER" "$location" "$location_type"
        echo -e "\n"
        
        list_namespaces
        echo -e "\n"
        
        list_services
        echo -e "\n"
        
        generate_command_template
    fi
elif [[ "$SHOW_NAMESPACES" == true ]]; then
    if [[ -z "$PROJECT" ]] || [[ -z "$CLUSTER" ]]; then
        echo -e "${RED}Error: --namespaces requires --project and --cluster${NC}"
        exit 1
    fi
    
    # Get cluster credentials
    cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
    location=$(echo "$cluster_info" | awk '{print $1}')
    location_type=$(echo "$cluster_info" | awk '{print $2}')
    
    get_credentials "$PROJECT" "$CLUSTER" "$location" "$location_type"
    echo ""
    list_namespaces
elif [[ "$SHOW_SERVICES" == true ]]; then
    if [[ -z "$PROJECT" ]] || [[ -z "$CLUSTER" ]]; then
        echo -e "${RED}Error: --services requires --project and --cluster${NC}"
        exit 1
    fi
    
    # Get cluster credentials
    cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
    location=$(echo "$cluster_info" | awk '{print $1}')
    location_type=$(echo "$cluster_info" | awk '{print $2}')
    
    get_credentials "$PROJECT" "$CLUSTER" "$location" "$location_type"
    echo ""
    list_services "$NAMESPACE"
elif [[ "$SHOW_PODS" == true ]]; then
    if [[ -z "$PROJECT" ]] || [[ -z "$CLUSTER" ]]; then
        echo -e "${RED}Error: --pods requires --project and --cluster${NC}"
        exit 1
    fi
    
    # Get cluster credentials
    cluster_info=$(gcloud container clusters list --project="$PROJECT" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
    location=$(echo "$cluster_info" | awk '{print $1}')
    location_type=$(echo "$cluster_info" | awk '{print $2}')
    
    get_credentials "$PROJECT" "$CLUSTER" "$location" "$location_type"
    echo ""
    list_pods "$NAMESPACE"
else
    # No specific mode selected, show help
    echo -e "${YELLOW}No discovery mode specified. Use --help for options.${NC}\n"
    echo -e "${CYAN}Quick start:${NC}"
    echo "  $0 --interactive              # Interactive guided discovery"
    echo "  $0 --projects                 # List all projects"
    echo "  $0 --all --project PROJECT    # Discover everything in a project"
fi

echo ""
