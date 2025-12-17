#!/bin/bash

# GKE Pod Restart Status Script
# Checks for pod restarts in Google Kubernetes Engine (GKE) clusters
#
# See also:
#   gke-diagnose-probes.sh    - Diagnose liveness/readiness/startup probe failures
#   gke-diagnose-shutdown.sh  - Diagnose ungraceful shutdown issues (SIGTERM/SIGKILL)
#   gke-diagnose-evictions.sh - Diagnose pod eviction issues

set -e

# Default values
PROJECT_NAME=""
CLUSTER_NAME=""
ZONE=""
REGION=""
NAMESPACE="default"
VERBOSE=false
QUIET=false
AUTO_LOGIN=false
ALL_NAMESPACES=false

# Color and formatting
redbold='\033[0;1m\033[0;31m'
clearf='\033[0m'
blueb='\033[1m\033[1;34m'
greenb='\033[1m\033[1;32m'
yellowb='\033[1m\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD=$(tput bold 2>/dev/null || echo '')
RESET=$(tput sgr0 2>/dev/null || echo '')

TZ=America/Toronto

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Check pod restart status in Google Kubernetes Engine (GKE) clusters.

OPTIONS:
    -p, --project PROJECT       GCP project name (required)
    -c, --cluster CLUSTER       GKE cluster name (required)
    -z, --zone ZONE            Cluster zone (for zonal clusters)
    -r, --region REGION        Cluster region (for regional clusters)
    -n, --namespace NAMESPACE   Kubernetes namespace (default: default)
    -A, --all-namespaces       Check all namespaces
    -a, --auto-login           Automatically run gcloud auth login
    -v, --verbose              Verbose output
    -q, --quiet                Quiet mode (only show errors and results)
    -h, --help                 Show this help message

EXAMPLES:
    $(basename "$0") --project my-project --cluster prod-cluster --zone us-central1-a
    $(basename "$0") -p my-project -c dev-cluster -r us-west1 -n istio-system
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c --all-namespaces
    $(basename "$0") --project my-project --cluster test --region us-central1 --auto-login

DESCRIPTION:
    This script connects to a GKE cluster and checks for pod restarts in the specified
    namespace(s). It reports pods with restart counts greater than 0, along with exit
    codes, restart reasons, and timestamps.

PREREQUISITES:
    - gcloud CLI installed and configured
    - kubectl installed
    - Appropriate GCP and Kubernetes permissions
    - Active GKE cluster context

EOF
}

# Error function
error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Log function for verbose output
log() {
    if [ "$VERBOSE" = true ] && [ "$QUIET" = false ]; then
        echo -e "${BLUE}[INFO]${NC} $1" >&2
    fi
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
        -A|--all-namespaces)
            ALL_NAMESPACES=true
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
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required parameters
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

# Spinner function
spinner() {
    local chars=('|' / - '\')

    # hide the cursor
    tput civis 2>/dev/null || true
    trap 'printf "\010"; tput cvvis 2>/dev/null || true; return' INT TERM

    printf "%b" "$*"

    while :; do
        for i in {0..3}; do
            printf %s "${chars[i]}"
            sleep 0.3
            printf '\010'
        done
    done
}

# Function to check if user is logged in to gcloud
check_gcloud_auth() {
    log "Checking Google Cloud authentication..."
    
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
        if [ "$AUTO_LOGIN" = true ]; then
            echo -e "${YELLOW}Not logged in. Initiating gcloud login...${NC}"
            gcloud auth login || error "Failed to authenticate with Google Cloud"
        else
            error "Not logged in to gcloud. Use --auto-login or run 'gcloud auth login' manually"
        fi
    else
        ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        log "Already authenticated as: $ACTIVE_ACCOUNT"
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
    
    log "Cluster credentials retrieved successfully"
}

# Function to verify kubectl is connected
check_kubectl() {
    log "Verifying kubectl connection..."
    
    local current_context=$(kubectl config current-context 2>/dev/null || echo "")
    if [ -z "$current_context" ]; then
        error "No kubectl context is set. Failed to configure cluster access."
    fi
    
    log "Using cluster context: $current_context"
    
    # Try to get namespaces as a connection test
    local test_result
    test_result=$(kubectl get namespaces --insecure-skip-tls-verify=true 2>&1)
    local test_exit=$?
    
    if [ $test_exit -ne 0 ]; then
        if echo "$test_result" | grep -q "certificate signed by unknown authority"; then
            if [ "$QUIET" = false ]; then
                echo ""
                echo -e "${YELLOW}Certificate trust issue detected${NC}"
                echo ""
                echo -e "${YELLOW}Automatically configuring kubeconfig to skip TLS verification...${NC}"
            fi
            
            # Automatically fix the issue by setting insecure-skip-tls-verify
            kubectl config set-cluster "$current_context" --insecure-skip-tls-verify=true >/dev/null 2>&1
            kubectl config unset "clusters.${current_context}.certificate-authority-data" >/dev/null 2>&1
            
            # Verify the fix worked
            test_result=$(kubectl get namespaces --insecure-skip-tls-verify=true 2>&1)
            test_exit=$?
            
            if [ $test_exit -ne 0 ]; then
                if [ "$VERBOSE" = true ]; then
                    echo -e "${YELLOW}Detailed kubectl error after TLS fix:${NC}" >&2
                    echo "$test_result" >&2
                fi
                error "Unable to connect to cluster even after skipping TLS verification"
            else
                if [ "$QUIET" = false ]; then
                    echo -e "${GREEN}Certificate verification configured successfully${NC}"
                fi
                log "Certificate verification configured successfully"
            fi
        elif echo "$test_result" | grep -qi "unable to connect\|connection refused\|timeout"; then
            if [ "$QUIET" = false ]; then
                echo ""
                echo -e "${YELLOW}Unable to connect to cluster${NC}"
                echo ""
                echo -e "${YELLOW}Cannot establish connection to the cluster.${NC}"
                echo ""
                echo "Possible causes:"
                echo "  • Network connectivity issues"
                echo "  • Firewall blocking access"
                echo "  • Cluster is private and requires VPN/bastion access"
                echo ""
            fi
            error "Unable to connect to cluster: $CLUSTER_NAME"
        else
            if [ "$VERBOSE" = true ]; then
                echo -e "${YELLOW}Detailed kubectl error:${NC}" >&2
                echo "$test_result" >&2
            fi
            error "Cannot connect to Kubernetes cluster. Check your network connection and cluster access permissions."
        fi
    fi
    
    log "Successfully connected to cluster"
}

# Function to check a single namespace
check_namespace() {
    local ns=$1
    local pid return
    
    if [ "$QUIET" = false ]; then
        spinner "${blueb}Checking${clearf} $ns... " & pid=$!
    fi

    log "Processing namespace: $ns"
    
    # Get pods with restarts and parse the data - iterate through items to preserve pod context
    local jq_output
    jq_output=$(kubectl get pods --namespace "${ns}" --field-selector status.phase=Running --insecure-skip-tls-verify=true -o json 2>/dev/null | \
    jq -r --arg ns "$ns" '.items[] | .status.containerStatuses[] | select (.restartCount? > 0) | [(.name),(.image),$ns,(.restartCount?),(.lastState?.terminated?.exitCode? // "N/A"),(.lastState?.terminated?.reason? // "N/A"),(.lastState?.terminated?.finishedAt? // "N/A" | if . == "N/A" then . else (fromdate | localtime | strflocaltime("%FT%T")) end)] | @csv')
    
    log "Found $(echo "$jq_output" | wc -l | tr -d ' ') lines of output from jq"
    
    if [ -n "$jq_output" ]; then
        echo "$jq_output" | while IFS= read -r line; do
            # Remove quotes from CSV line
            line=$(echo "$line" | sed 's/"//g')
            
            log "Processing line: $line"
            
            # Split the CSV line
            IFS=',' read -r name image namespace restartCount exitCode reason finishedAt <<< "$line"
            
            # Extract service name and version from image
            # Handle different image formats: registry/path/service:version or service:version
            if [[ "$image" == *":"* ]]; then
                # Extract everything after the last / and split on :
                serviceFull=$(echo "$image" | awk -F'/' '{print $NF}')
                serviceName=$(echo "$serviceFull" | cut -d: -f1)
                version=$(echo "$serviceFull" | cut -d: -f2)
            else
                serviceName="$image"
                version="latest"
            fi
            
            # Output in the expected format
            output_line="$namespace,$serviceName,$version,$restartCount,$exitCode,$reason,$finishedAt"
            log "Writing: $output_line"
            echo "$output_line"
        done >> tmp-pod-rep 2>/dev/null
    else
        log "No containers with restarts found in namespace: $ns"
    fi

    return=$?
    
    if [ "$QUIET" = false ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        if [[ "$return" -eq 0 ]]; then
            echo "🏁 "
        else
            echo "💣 "
        fi
    fi
}

# Main check function
check() {
    # Initialize the output file with headers
    echo -e "${redbold}Namespace${clearf},${redbold}Service Name${clearf},${redbold}Image Version${clearf},${redbold}Restart Count${clearf},${redbold}Return Code${clearf},${redbold}Restart Reason${clearf},${redbold}Finished At${clearf}" > tmp-pod-rep

    if [ "$ALL_NAMESPACES" = true ]; then
        log "Checking all namespaces..."
        # Get all namespaces
        namespaces=$(kubectl get namespaces --insecure-skip-tls-verify=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        if [ -z "$namespaces" ]; then
            log "Warning: No namespaces found or unable to list namespaces"
            return 1
        fi
        
        log "Found namespaces: $namespaces"
        
        for namespace in $namespaces; do
            check_namespace "$namespace"
        done
    else
        log "Checking namespace: $NAMESPACE"
        check_namespace "$NAMESPACE"
    fi
}

# Cleanup function
cleanup() {
    tput cvvis 2>/dev/null || true
    if [ -f tmp-pod-rep ]; then
        rm -f tmp-pod-rep 2>/dev/null || true
    fi
}

# Set up trap to cleanup on script exit
trap cleanup EXIT

# Hide cursor
tput civis 2>/dev/null || true

# Main execution
if [ "$QUIET" = false ]; then
    echo -e "${greenb}=== GKE Pod Restart Status ===${clearf}\n"
fi

check_gcloud_auth
set_project
get_cluster_credentials
check_kubectl
check

# Display results
if [ "$QUIET" = false ]; then
    echo -e "\n${greenb}=== Results ===${clearf}\n"
fi

# Check if we have any data beyond the header
line_count=$(wc -l < tmp-pod-rep)
if [ "$line_count" -gt 1 ]; then
    # Check if tty-table is available
    if command -v tty-table >/dev/null 2>&1; then
        cat tmp-pod-rep | sort -t, -k7,7 | tty-table
    else
        # Fallback to column if tty-table is not available
        if command -v column >/dev/null 2>&1; then
            cat tmp-pod-rep | sort -t, -k7,7 | column -t -s,
        else
            # Just output the CSV
            cat tmp-pod-rep | sort -t, -k7,7
        fi
    fi
    
    # Collect unique exit codes and reasons
    echo -e "\n${greenb}=== Exit Code Analysis ===${clearf}\n"
    
    # Extract unique exit codes (skip header, get column 5)
    unique_codes=$(tail -n +2 tmp-pod-rep | cut -d, -f5 | sort -u | grep -v "N/A")
    
    if [ -n "$unique_codes" ]; then
        while IFS= read -r code; do
            # Count occurrences of this exit code
            count=$(tail -n +2 tmp-pod-rep | cut -d, -f5 | grep -c "^${code}$")
            
            echo -e "${yellowb}Exit Code $code${clearf} (${count} occurrence(s))"
            
            # Provide explanation for common exit codes
            case $code in
                0)
                    echo "  ✓ Success - Container exited normally"
                    echo "  └─ This usually indicates a clean shutdown or completed job"
                    ;;
                1)
                    echo "  ❌ Application Error - General application failure"
                    echo "  └─ Check application logs for specific error messages"
                    ;;
                2)
                    echo "  ❌ Misuse of shell builtin - Invalid command or arguments"
                    echo "  └─ Review container command and arguments in pod specification"
                    ;;
                126)
                    echo "  ❌ Command cannot execute - Permission problem or not executable"
                    echo "  └─ Check file permissions and execute bit on binary"
                    ;;
                127)
                    echo "  ❌ Command not found - Binary/executable doesn't exist"
                    echo "  └─ Verify the command path and container image contents"
                    ;;
                128)
                    echo "  ❌ Invalid exit argument - Exit code out of range"
                    echo "  └─ Application may be returning an invalid exit code"
                    ;;
                130)
                    echo "  ⚠️️ Container terminated by Ctrl+C (SIGINT)"
                    echo "  └─ Interactive termination or process received interrupt signal"
                    ;;
                137)
                    echo "  ⚠️️ Container killed by SIGKILL (signal 9)"
                    echo "  └─ Possible causes:"
                    echo "     • OOMKilled - Container exceeded memory limits"
                    echo "     • Node pressure - Node running out of resources"
                    echo "     • Force termination - Process did not respond to SIGTERM"
                    echo "  └─ Action: Check memory limits and node resources"
                    ;;
                139)
                    echo "  ❌ Segmentation fault (SIGSEGV)"
                    echo "  └─ Application crashed due to memory access violation"
                    echo "  └─ Action: Review application code and check for memory issues"
                    ;;
                143)
                    echo "  ⚠️️ Container terminated by SIGTERM (signal 15)"
                    echo "  └─ Graceful termination requested - Common causes:"
                    echo "     • Pod deleted or evicted"
                    echo "     • Rolling deployment/update"
                    echo "     • Node drain or maintenance"
                    echo "     • Manual pod termination"
                    echo "     • PreStop hook execution"
                    echo "  └─ This is often normal during deployments, but frequent restarts may indicate:"
                    echo "     • Liveness probe failures"
                    echo "     • Application crash loops"
                    echo "     • Resource constraints"
                    ;;
                255)
                    echo "  ❌ Exit status out of range"
                    echo "  └─ Application may have returned an invalid or wrapped exit code"
                    ;;
                *)
                    if [ "$code" -gt 128 ] && [ "$code" -lt 256 ]; then
                        signal=$((code - 128))
                        echo "  ⚠️️ Container terminated by signal $signal"
                        echo "  └─ Common signals:"
                        echo "     • Signal 1 (SIGHUP) - Hangup"
                        echo "     • Signal 2 (SIGINT) - Interrupt"
                        echo "     • Signal 9 (SIGKILL) - Kill"
                        echo "     • Signal 15 (SIGTERM) - Terminate"
                    else
                        echo "  ‼️ Unknown exit code - Application-specific error"
                        echo "  └─ Check application documentation and logs for details"
                    fi
                    ;;
            esac
            
            # Show the reason field for this exit code
            reasons=$(tail -n +2 tmp-pod-rep | awk -F',' -v code="$code" '$5 == code {print $6}' | sort -u)
            if [ -n "$reasons" ]; then
                echo -e "\n  ${BLUE}Kubernetes Reason(s):${NC}"
                while IFS= read -r reason; do
                    if [ "$reason" != "N/A" ]; then
                        echo "    • $reason"
                    fi
                done <<< "$reasons"
            fi
            echo ""
        done <<< "$unique_codes"
        
        # Additional troubleshooting tips
        echo -e "${greenb}=== Troubleshooting Tips ===${clearf}\n"
        echo "To investigate further, here are copy/paste commands for the pods with restarts:"
        echo ""
        
        # Get unique namespace|serviceName combinations from our data
        tail -n +2 tmp-pod-rep | awk -F',' '{print $1"|"$2}' | sort -u | while IFS='|' read -r namespace containerName; do
            # Get all pods in this namespace that have any restarts
            kubectl get pods -n "$namespace" --insecure-skip-tls-verify=true --field-selector status.phase=Running -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.containerStatuses[]? | .restartCount > 0) | 
                    {podName: .metadata.name, containers: [.status.containerStatuses[] | select(.restartCount > 0) | .name]} | 
                    .podName as $pod | .containers[] | "\($pod)|\(.)"' | \
                while IFS='|' read -r pod_name container_name; do
                    if [ -n "$pod_name" ] && [ -n "$container_name" ]; then
                        echo -e "${BLUE}Pod:${NC} $pod_name (container: $container_name, namespace: $namespace)"
                        echo ""
                        echo "  View pod events and details:"
                        echo "    ${BOLD}kubectl describe pod $pod_name -n $namespace --insecure-skip-tls-verify=true${RESET}"
                        echo ""
                        echo "  Check previous container logs (from failed container):"
                        echo "    ${BOLD}kubectl logs $pod_name -c $container_name -n $namespace --previous --insecure-skip-tls-verify=true${RESET}"
                        echo ""
                        echo "  Check current container logs:"
                        echo "    ${BOLD}kubectl logs $pod_name -c $container_name -n $namespace --insecure-skip-tls-verify=true${RESET}"
                        echo ""
                        echo "  View pod YAML (check resource limits, probes, etc.):"
                        echo "    ${BOLD}kubectl get pod $pod_name -n $namespace -o yaml --insecure-skip-tls-verify=true${RESET}"
                        echo ""
                        echo "  Follow logs in real-time:"
                        echo "    ${BOLD}kubectl logs $pod_name -c $container_name -n $namespace -f --insecure-skip-tls-verify=true${RESET}"
                        echo ""
                        echo "  ---"
                        echo ""
                    fi
                done
        done
        
        echo ""
        echo "Check resource usage across namespace(s):"
        # Get unique namespaces
        unique_namespaces=$(tail -n +2 tmp-pod-rep | cut -d, -f1 | sort -u)
        while IFS= read -r ns; do
            echo "  ${BOLD}kubectl top pods -n $ns --insecure-skip-tls-verify=true${RESET}"
        done <<< "$unique_namespaces"
        echo ""
        
        # Check for common patterns in the data
        oom_count=$(tail -n +2 tmp-pod-rep 2>/dev/null | grep -c "OOMKilled" 2>/dev/null || echo "0")
        oom_count=$(echo "$oom_count" | head -1 | tr -d '\n' | tr -d ' ')
        error_137_count=$(tail -n +2 tmp-pod-rep 2>/dev/null | grep -c ",137," 2>/dev/null || echo "0")
        error_137_count=$(echo "$error_137_count" | head -1 | tr -d '\n' | tr -d ' ')
        
        if [ "$oom_count" -gt 0 ] 2>/dev/null || [ "$error_137_count" -gt 0 ] 2>/dev/null; then
            echo -e "${yellowb}⚠️️️ Memory Issues Detected${clearf}"
            echo "Found $((oom_count + error_137_count)) potential OOM (Out of Memory) kills"
            echo "Consider increasing memory limits or investigating memory leaks"
            echo ""
        fi
        
        error_143_count=$(tail -n +2 tmp-pod-rep 2>/dev/null | grep -c ",143," 2>/dev/null || echo "0")
        error_143_count=$(echo "$error_143_count" | head -1 | tr -d '\n' | tr -d ' ')
        if [ "$error_143_count" -gt 3 ] 2>/dev/null; then
            echo -e "${yellowb}⚠️️️ High SIGTERM Count${clearf}"
            echo "Found $error_143_count SIGTERM (143) terminations"
            echo "This may indicate:"
            echo "  • Frequent pod evictions or rescheduling"
            echo "  • Failing liveness/readiness probes"
            echo "  • Application not handling shutdown gracefully"
            echo ""
            echo "For detailed analysis, run:"
            echo "  ./gke-diagnose-shutdown.sh -p $PROJECT_NAME -c $CLUSTER_NAME $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION")$([ "$NAMESPACE" != "default" ] && echo " -n $NAMESPACE" || echo "")"
            echo ""
        fi
    else
        echo "No exit code information available (all restarts may have N/A exit codes)"
    fi
else
    echo -e "${greenb}✅ No pods with restarts found!${clearf}"
fi

echo ""
echo -e "${cyanb}Related Diagnostic Tools:${clearf}"
echo "  • Probe failures:      ./gke-diagnose-probes.sh -p $PROJECT_NAME -c $CLUSTER_NAME $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION")$([ "$NAMESPACE" != "default" ] && echo " -n $NAMESPACE" || echo "")"
echo "  • Shutdown issues:     ./gke-diagnose-shutdown.sh -p $PROJECT_NAME -c $CLUSTER_NAME $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION")$([ "$NAMESPACE" != "default" ] && echo " -n $NAMESPACE" || echo "")"
echo "  • Pod evictions:       ./gke-diagnose-evictions.sh -p $PROJECT_NAME -c $CLUSTER_NAME $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION")$([ "$NAMESPACE" != "default" ] && echo " -n $NAMESPACE" || echo "")"
echo ""

# Clean up is handled by trap
