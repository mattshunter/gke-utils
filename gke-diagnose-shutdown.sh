#!/bin/bash

# Script to diagnose ungraceful shutdown issues in GKE clusters
# Usage: ./gke-diagnose-shutdown.sh -p <project> -c <cluster> [-z <zone> | -r <region>] [-n <namespace>] [-v] [-q]

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
PROJECT=""
CLUSTER=""
ZONE=""
REGION=""
NAMESPACE=""
ALL_NAMESPACES=false
VERBOSE=false
QUIET=false
AUTO_LOGIN=false

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Required Parameters:
    -p, --project <project>     GCP project ID
    -c, --cluster <cluster>     GKE cluster name
    -z, --zone <zone>           GKE cluster zone (e.g., us-east4-a) - for zonal clusters
    -r, --region <region>       GKE cluster region (e.g., us-east4) - for regional clusters

Optional Parameters:
    -n, --namespace <namespace> Specific namespace to check (default: all namespaces)
    -a, --all-namespaces        Check all namespaces explicitly
    -v, --verbose               Verbose output
    -q, --quiet                 Quiet mode (minimal output)
    -l, --auto-login            Auto-login to gcloud if not authenticated
    -h, --help                  Show this help message

Examples:
    $0 -p my-project -c my-cluster -z us-east4-a
    $0 --project my-project --cluster my-cluster --region us-east4
    $0 -p my-project -c my-cluster -z us-east4-a -n production
    $0 --project my-project --cluster my-cluster --region us-east4 --all-namespaces --verbose

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
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
        -a|--all-namespaces)
            ALL_NAMESPACES=true
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
        -l|--auto-login)
            AUTO_LOGIN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$PROJECT" ] || [ -z "$CLUSTER" ]; then
    echo -e "${RED}Error: Project and cluster are required${NC}"
    usage
fi

if [ -z "$ZONE" ] && [ -z "$REGION" ]; then
    echo -e "${RED}Error: Either zone (-z) or region (-r) must be specified${NC}"
    usage
fi

if [ -n "$ZONE" ] && [ -n "$REGION" ]; then
    echo -e "${RED}Error: Cannot specify both zone and region${NC}"
    usage
fi

# Set namespace flag for kubectl
if [ -n "$NAMESPACE" ]; then
    NS_FLAG="-n $NAMESPACE"
    NS_DISPLAY="namespace: $NAMESPACE"
else
    NS_FLAG="--all-namespaces"
    NS_DISPLAY="all namespaces"
fi

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    echo "Please install it from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed${NC}"
    echo "Please install it from: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Please install it from: https://stedolan.github.io/jq/"
    exit 1
fi

# Function to check gcloud authentication
check_gcloud_auth() {
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
        echo -e "${YELLOW}Warning: Not authenticated with gcloud${NC}"
        if [ "$AUTO_LOGIN" = true ]; then
            echo "Attempting to authenticate..."
            gcloud auth login
        else
            echo "Please run: gcloud auth login"
            exit 1
        fi
    fi
}

# Function to set project
set_project() {
    [ "$VERBOSE" = true ] && echo -e "${CYAN}Setting project to: $PROJECT${NC}"
    gcloud config set project "$PROJECT" &> /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to set project${NC}"
        exit 1
    fi
}

# Function to get cluster credentials
get_cluster_credentials() {
    local location_flag
    local location_display
    
    if [ -n "$ZONE" ]; then
        location_flag="--zone"
        location_display="zone: $ZONE"
        LOCATION="$ZONE"
    else
        location_flag="--region"
        location_display="region: $REGION"
        LOCATION="$REGION"
    fi
    
    [ "$VERBOSE" = true ] && echo -e "${CYAN}Getting credentials for cluster: $CLUSTER ($location_display)${NC}"
    
    local error_output
    error_output=$(gcloud container clusters get-credentials "$CLUSTER" $location_flag "$LOCATION" --project "$PROJECT" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to get cluster credentials${NC}"
        echo -e "${YELLOW}Details: $error_output${NC}"
        echo -e "\n${CYAN}Hint: Verify cluster name, location, and project with:${NC}"
        echo -e "  gcloud container clusters list --project $PROJECT"
        exit 1
    fi
}

# Function to check if we need --insecure-skip-tls-verify
check_kubectl() {
    if kubectl cluster-info &> /dev/null; then
        KUBECTL_TLS_FLAG=""
        [ "$VERBOSE" = true ] && echo -e "${GREEN}kubectl connection successful (TLS verified)${NC}"
    else
        KUBECTL_TLS_FLAG="--insecure-skip-tls-verify=true"
        [ "$VERBOSE" = true ] && echo -e "${YELLOW}Using --insecure-skip-tls-verify for kubectl commands${NC}"
    fi
}

# Main execution
echo -e "${BOLD}${BLUE}=== GKE Ungraceful Shutdown Diagnostic Tool ===${NC}\n"

check_gcloud_auth
set_project
get_cluster_credentials
check_kubectl

echo -e "${GREEN}Connected to cluster: $CLUSTER${NC}"
echo -e "${GREEN}Project: $PROJECT${NC}"
if [ -n "$ZONE" ]; then
    echo -e "${GREEN}Zone: $ZONE${NC}"
else
    echo -e "${GREEN}Region: $REGION${NC}"
fi
echo -e "${GREEN}Scope: $NS_DISPLAY${NC}\n"

# Create temporary files for data collection
TMP_SIGTERM=$(mktemp)
TMP_SIGKILL=$(mktemp)
TMP_GRACE_PERIODS=$(mktemp)

trap "rm -f $TMP_SIGTERM $TMP_SIGKILL $TMP_GRACE_PERIODS" EXIT

#############################################################################
# 1. FIND PODS WITH SIGTERM/SIGKILL EXITS
#############################################################################
echo -e "${BOLD}${MAGENTA}[1/6] Identifying pods with shutdown-related exit codes...${NC}"

# Exit 143 = SIGTERM (received shutdown signal)
# Exit 137 = SIGKILL (forcefully killed after grace period)
kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | 
    .metadata.namespace as $ns | .metadata.name as $pod |
    .status.containerStatuses[]? | 
    select(.restartCount > 0) |
    select((.lastState.terminated.exitCode == 143) or (.lastState.terminated.exitCode == 137)) |
    [$ns, $pod, .name, .restartCount, .lastState.terminated.exitCode, .lastState.terminated.reason, .lastState.terminated.finishedAt] | @tsv' \
    > "$TMP_SIGTERM"

if [ -s "$TMP_SIGTERM" ]; then
    POD_COUNT=$(wc -l < "$TMP_SIGTERM" | tr -d ' ')
    echo -e "${YELLOW}Found $POD_COUNT containers with shutdown-related exit codes:${NC}\n"
    
    echo -e "${BOLD}$(printf '%-30s %-50s %-30s %-10s %-10s %-15s %s' 'NAMESPACE' 'POD' 'CONTAINER' 'RESTARTS' 'EXIT_CODE' 'REASON' 'LAST_TERMINATED')${NC}"
    while IFS=$'\t' read -r ns pod container restarts exitcode reason finished; do
        if [ "$exitcode" = "137" ]; then
            # SIGKILL - forcefully killed (BAD)
            color="${RED}"
            indicator="[SIGKILL - Forced]"
        else
            # SIGTERM - shutdown signal (could be normal or problematic)
            color="${YELLOW}"
            indicator="[SIGTERM]"
        fi
        printf "${color}%-30s %-50s %-30s %-10s %-10s %-15s %s %s${NC}\n" "$ns" "$pod" "$container" "$restarts" "$exitcode" "$reason" "$finished" "$indicator"
    done < "$TMP_SIGTERM"
    
    echo -e "\n${CYAN}Exit Code Reference:${NC}"
    echo -e "  ${YELLOW}143 (SIGTERM)${NC} - Received termination signal (may be normal during rolling updates)"
    echo -e "  ${RED}137 (SIGKILL)${NC} - Forcefully killed after grace period expired (ungraceful shutdown)"
else
    echo -e "${GREEN}No pods with SIGTERM/SIGKILL exit codes found${NC}"
fi

echo ""

#############################################################################
# 2. CHECK TERMINATION GRACE PERIODS
#############################################################################
echo -e "${BOLD}${MAGENTA}[2/6] Analyzing termination grace periods...${NC}"

kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | 
    select(.status.phase == "Running") |
    [.metadata.namespace, .metadata.name, (.spec.terminationGracePeriodSeconds // 30)] | @tsv' \
    > "$TMP_GRACE_PERIODS"

if [ -s "$TMP_GRACE_PERIODS" ]; then
    # Count grace periods
    TOTAL=$(wc -l < "$TMP_GRACE_PERIODS" | tr -d ' ')
    DEFAULT_30=$(awk -F'\t' '$3 == 30' "$TMP_GRACE_PERIODS" | wc -l | tr -d ' ')
    SHORT=$(awk -F'\t' '$3 < 30' "$TMP_GRACE_PERIODS" | wc -l | tr -d ' ')
    LONG=$(awk -F'\t' '$3 > 30' "$TMP_GRACE_PERIODS" | wc -l | tr -d ' ')
    
    echo -e "${BOLD}Grace Period Distribution:${NC}"
    echo -e "  ${GREEN}Total pods analyzed: $TOTAL${NC}"
    echo -e "  ${CYAN}Default (30s): $DEFAULT_30${NC}"
    echo -e "  ${YELLOW}Short (<30s): $SHORT${NC}"
    echo -e "  ${BLUE}Long (>30s): $LONG${NC}"
    
    # Show pods with short grace periods
    if [ "$SHORT" -gt 0 ]; then
        echo -e "\n${YELLOW}Pods with SHORT grace periods (<30s):${NC}"
        echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'GRACE_PERIOD')${NC}"
        awk -F'\t' '$3 < 30 {printf "%-30s %-50s %ss\n", $1, $2, $3}' "$TMP_GRACE_PERIODS" | head -10
        [ "$SHORT" -gt 10 ] && echo -e "  ${CYAN}... and $((SHORT - 10)) more${NC}"
    fi
    
    # Show pods with custom long grace periods
    if [ "$LONG" -gt 0 ]; then
        echo -e "\n${BLUE}Pods with CUSTOM grace periods (>30s):${NC}"
        echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'GRACE_PERIOD')${NC}"
        awk -F'\t' '$3 > 30 {printf "%-30s %-50s %ss\n", $1, $2, $3}' "$TMP_GRACE_PERIODS" | head -10
        [ "$LONG" -gt 10 ] && echo -e "  ${CYAN}... and $((LONG - 10)) more${NC}"
    fi
else
    echo -e "${YELLOW}No running pods found to analyze${NC}"
fi

echo ""

#############################################################################
# 3. CHECK FOR PRESTOP HOOKS
#############################################################################
echo -e "${BOLD}${MAGENTA}[3/6] Checking for preStop lifecycle hooks...${NC}"

PODS_WITH_PRESTOP=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | 
    select(.status.phase == "Running") |
    .metadata.namespace as $ns | .metadata.name as $pod |
    .spec.containers[] | 
    select(.lifecycle.preStop != null) |
    [$ns, $pod, .name] | @tsv')

PODS_WITHOUT_PRESTOP=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | 
    select(.status.phase == "Running") |
    .metadata.namespace as $ns | .metadata.name as $pod |
    .spec.containers[] | 
    select(.lifecycle.preStop == null) |
    [$ns, $pod, .name] | @tsv' | head -20)

if [ -n "$PODS_WITH_PRESTOP" ]; then
    PRESTOP_COUNT=$(echo "$PODS_WITH_PRESTOP" | wc -l | tr -d ' ')
    echo -e "${GREEN}Found $PRESTOP_COUNT containers with preStop hooks configured${NC}\n"
    
    echo -e "${BOLD}Containers with preStop hooks (first 10):${NC}"
    echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'CONTAINER')${NC}"
    echo "$PODS_WITH_PRESTOP" | head -10 | while IFS=$'\t' read -r ns pod container; do
        printf "${GREEN}%-30s %-50s %s${NC}\n" "$ns" "$pod" "$container"
    done
    [ "$PRESTOP_COUNT" -gt 10 ] && echo -e "  ${CYAN}... and $((PRESTOP_COUNT - 10)) more${NC}"
else
    echo -e "${YELLOW}No containers with preStop hooks found${NC}"
fi

if [ -n "$PODS_WITHOUT_PRESTOP" ]; then
    echo -e "\n${YELLOW}Containers WITHOUT preStop hooks (first 20):${NC}"
    echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'CONTAINER')${NC}"
    echo "$PODS_WITHOUT_PRESTOP" | while IFS=$'\t' read -r ns pod container; do
        printf "${YELLOW}%-30s %-50s %s${NC}\n" "$ns" "$pod" "$container"
    done
    
    echo -e "\n${CYAN}Recommendation: Add preStop hooks to drain connections gracefully${NC}"
fi

echo ""

#############################################################################
# 4. ANALYZE SHUTDOWN EVENTS
#############################################################################
echo -e "${BOLD}${MAGENTA}[4/6] Analyzing shutdown-related events...${NC}"

KILL_EVENTS=$(kubectl get events $NS_FLAG $KUBECTL_TLS_FLAG --sort-by='.lastTimestamp' 2>/dev/null | \
    grep -iE 'killing|sigterm|sigkill|graceful|shutdown|stopped' | tail -20)

if [ -n "$KILL_EVENTS" ]; then
    echo -e "${YELLOW}Recent shutdown-related events (last 20):${NC}\n"
    echo "$KILL_EVENTS" | while IFS= read -r line; do
        if echo "$line" | grep -qi "sigkill\|killing"; then
            echo -e "${RED}  $line${NC}"
        else
            echo -e "${YELLOW}  $line${NC}"
        fi
    done
else
    echo -e "${GREEN}No recent shutdown-related events found${NC}"
fi

echo ""

#############################################################################
# 5. DETAILED ANALYSIS OF PROBLEM PODS
#############################################################################
echo -e "${BOLD}${MAGENTA}[5/6] Detailed analysis of pods with shutdown issues...${NC}"

if [ -s "$TMP_SIGTERM" ]; then
    echo -e "${BOLD}Analyzing pods with SIGTERM/SIGKILL exits:${NC}\n"
    
    # Focus on SIGKILL pods (forced kills) first
    SIGKILL_PODS=$(awk -F'\t' '$5 == 137' "$TMP_SIGTERM")
    
    if [ -n "$SIGKILL_PODS" ]; then
        echo -e "${RED}Critical: Pods forcefully killed (SIGKILL - exit 137):${NC}\n"
        
        echo "$SIGKILL_PODS" | while IFS=$'\t' read -r ns pod container restarts exitcode reason finished; do
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BOLD}Pod: ${BLUE}$pod${NC} ${BOLD}(namespace: $ns, container: $container)${NC}"
            echo -e "${RED}Exit Code: 137 (SIGKILL - forced termination)${NC}"
            echo -e "${YELLOW}Restarts: $restarts${NC}\n"
            
            # Get grace period
            GRACE=$(kubectl get pod "$pod" -n "$ns" $KUBECTL_TLS_FLAG -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null || echo "30")
            echo -e "${BOLD}  Termination Grace Period: ${GRACE}s${NC}"
            
            if [ "$GRACE" -le 30 ]; then
                echo -e "${YELLOW}    ⚠ Using default or short grace period - may need to increase${NC}"
            fi
            
            # Check for preStop hook
            PRESTOP=$(kubectl get pod "$pod" -n "$ns" $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
                jq -r --arg container "$container" '.spec.containers[] | select(.name == $container) | .lifecycle.preStop // empty')
            
            if [ -n "$PRESTOP" ] && [ "$PRESTOP" != "null" ]; then
                echo -e "${BOLD}  PreStop Hook: Configured${NC}"
                echo "$PRESTOP" | jq '.' 2>/dev/null | sed 's/^/    /'
            else
                echo -e "${RED}  PreStop Hook: Not configured${NC}"
                echo -e "${YELLOW}    ⚠ Add preStop hook to allow graceful connection draining${NC}"
            fi
            
            echo ""
            
        done | head -100
    fi
    
    # Then show SIGTERM pods
    SIGTERM_PODS=$(awk -F'\t' '$5 == 143' "$TMP_SIGTERM" | head -5)
    
    if [ -n "$SIGTERM_PODS" ]; then
        echo -e "\n${YELLOW}Pods terminated with SIGTERM (exit 143) - first 5:${NC}\n"
        
        echo "$SIGTERM_PODS" | while IFS=$'\t' read -r ns pod container restarts exitcode reason finished; do
            echo -e "${BOLD}Pod:${NC} $pod (ns: $ns, container: $container)"
            
            GRACE=$(kubectl get pod "$pod" -n "$ns" $KUBECTL_TLS_FLAG -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null || echo "30")
            PRESTOP=$(kubectl get pod "$pod" -n "$ns" $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
                jq -r --arg container "$container" '.spec.containers[] | select(.name == $container) | .lifecycle.preStop // empty')
            
            echo -e "  Grace Period: ${GRACE}s | PreStop: $([ -n "$PRESTOP" ] && [ "$PRESTOP" != "null" ] && echo "✓" || echo "✗")"
            echo ""
        done
    fi
else
    echo -e "${GREEN}No pods with shutdown issues to analyze${NC}"
fi

echo ""

#############################################################################
# 6. TROUBLESHOOTING COMMANDS
#############################################################################
echo -e "${BOLD}${MAGENTA}[6/6] Troubleshooting commands for shutdown issues...${NC}"

if [ -s "$TMP_SIGTERM" ]; then
    echo -e "${BOLD}Copy/paste commands to investigate shutdown problems:${NC}\n"
    
    # Generate commands for pods with issues
    while IFS=$'\t' read -r ns pod container restarts exitcode reason finished; do
        echo -e "${BLUE}Pod:${NC} $pod (container: $container, namespace: $ns, exit: $exitcode)"
        echo ""
        echo "  Check pod specification for grace period and preStop hook:"
        echo -e "    ${BOLD}kubectl get pod $pod -n $ns $KUBECTL_TLS_FLAG -o yaml | grep -A 5 'terminationGracePeriodSeconds\\|preStop'${NC}"
        echo ""
        echo "  View full pod lifecycle configuration:"
        echo -e "    ${BOLD}kubectl get pod $pod -n $ns $KUBECTL_TLS_FLAG -o json | jq '.spec.containers[] | {name, lifecycle, terminationGracePeriodSeconds: .terminationGracePeriodSeconds}'${NC}"
        echo ""
        echo "  Check logs for SIGTERM handling:"
        echo -e "    ${BOLD}kubectl logs $pod -c $container -n $ns --previous $KUBECTL_TLS_FLAG | grep -i 'sigterm\\|shutdown\\|graceful'${NC}"
        echo ""
        echo "  View recent termination events:"
        echo -e "    ${BOLD}kubectl get events -n $ns $KUBECTL_TLS_FLAG --field-selector involvedObject.name=$pod --sort-by='.lastTimestamp' | grep -i 'kill\\|term'${NC}"
        echo ""
        echo "  Describe pod for detailed status:"
        echo -e "    ${BOLD}kubectl describe pod $pod -n $ns $KUBECTL_TLS_FLAG${NC}"
        echo ""
        echo "  ---"
        echo ""
    done < "$TMP_SIGTERM" | head -200
else
    echo -e "${GREEN}No shutdown issues to troubleshoot${NC}"
fi

echo ""

#############################################################################
# SUMMARY AND RECOMMENDATIONS
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary and Recommendations ===${NC}\n"

CRITICAL=0
WARNINGS=0

# Count SIGKILL pods
SIGKILL_COUNT=$(awk -F'\t' '$5 == 137' "$TMP_SIGTERM" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SIGKILL_COUNT" -gt 0 ]; then
    CRITICAL=$((CRITICAL + 1))
    echo -e "${RED}✗ $SIGKILL_COUNT containers forcefully killed (SIGKILL - exit 137)${NC}"
fi

# Count SIGTERM pods
SIGTERM_COUNT=$(awk -F'\t' '$5 == 143' "$TMP_SIGTERM" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SIGTERM_COUNT" -gt 0 ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ $SIGTERM_COUNT containers terminated with SIGTERM (exit 143)${NC}"
fi

# Check for missing preStop hooks
if [ -n "$PODS_WITHOUT_PRESTOP" ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ Containers without preStop hooks detected${NC}"
fi

if [ $CRITICAL -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ No shutdown issues detected${NC}"
else
    echo ""
    echo -e "${BOLD}Common Causes of Ungraceful Shutdown:${NC}"
    echo -e "  ${CYAN}1. Application doesn't handle SIGTERM signal${NC}"
    echo -e "     Fix: Implement signal handler in your application code"
    echo ""
    echo -e "  ${CYAN}2. Grace period too short for application to shutdown${NC}"
    echo -e "     Fix: Increase terminationGracePeriodSeconds in pod spec"
    echo ""
    echo -e "  ${CYAN}3. No preStop hook to drain connections${NC}"
    echo -e "     Fix: Add preStop hook with sleep to allow load balancer updates"
    echo ""
    echo -e "  ${CYAN}4. Background threads or workers not stopping${NC}"
    echo -e "     Fix: Ensure all threads/workers shutdown on SIGTERM"
    echo ""
    echo -e "  ${CYAN}5. Database connections not closed properly${NC}"
    echo -e "     Fix: Implement connection cleanup in shutdown handler"
    echo ""
    
    echo -e "${BOLD}Recommended Configuration:${NC}"
    cat << 'EOF'
  spec:
    terminationGracePeriodSeconds: 60  # Increase from default 30s
    containers:
    - name: my-app
      lifecycle:
        preStop:
          exec:
            # Sleep to allow time for:
            # 1. Load balancer to remove pod from endpoints (~15s)
            # 2. In-flight requests to complete
            command: ["/bin/sh", "-c", "sleep 15"]
      
  # In your application code, handle SIGTERM:
  # - Stop accepting new requests
  # - Complete in-flight requests
  # - Close database connections
  # - Flush logs/metrics
  # - Exit cleanly within grace period
EOF
    
    echo ""
    echo -e "${BOLD}Testing Graceful Shutdown:${NC}"
    echo -e "  1. Deploy changes and trigger rolling update"
    echo -e "  2. Monitor logs during pod termination:"
    echo -e "     ${CYAN}kubectl logs -f <pod> -c <container> -n <namespace>${NC}"
    echo -e "  3. Check exit codes after restart:"
    echo -e "     ${CYAN}kubectl get pods -n <namespace> -o json | jq '.items[].status.containerStatuses[] | select(.restartCount > 0) | {name, exitCode: .lastState.terminated.exitCode}'${NC}"
    echo -e "  4. Verify no SIGKILL (137) exit codes"
fi

echo ""
echo -e "${GREEN}Shutdown diagnosis complete!${NC}"
