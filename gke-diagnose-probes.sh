#!/bin/bash

# Script to diagnose probe failures in GKE clusters
# Usage: ./gke-diagnose-probes.sh -p <project> -c <cluster> [-z <zone> | -r <region>] [-n <namespace>] [-v] [-q]

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
echo -e "${BOLD}${BLUE}=== GKE Probe Failure Diagnostic Tool ===${NC}\n"

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
TMP_EVENTS=$(mktemp)
TMP_PROBE_FAILURES=$(mktemp)
TMP_PODS_WITH_PROBES=$(mktemp)

trap "rm -f $TMP_EVENTS $TMP_PROBE_FAILURES $TMP_PODS_WITH_PROBES" EXIT

#############################################################################
# 1. CHECK RECENT PROBE FAILURE EVENTS
#############################################################################
echo -e "${BOLD}${MAGENTA}[1/5] Checking for recent probe failure events...${NC}"

kubectl get events $NS_FLAG $KUBECTL_TLS_FLAG --sort-by='.lastTimestamp' 2>/dev/null | \
    grep -E 'Liveness|Readiness|Startup' > "$TMP_EVENTS"

if [ -s "$TMP_EVENTS" ]; then
    EVENT_COUNT=$(wc -l < "$TMP_EVENTS" | tr -d ' ')
    echo -e "${RED}Found $EVENT_COUNT probe-related events:${NC}\n"
    
    # Show recent probe events
    echo -e "${BOLD}Recent Probe Events (last 20):${NC}"
    tail -20 "$TMP_EVENTS" | while IFS= read -r line; do
        if echo "$line" | grep -qi "failed"; then
            echo -e "${RED}  $line${NC}"
        elif echo "$line" | grep -qi "succeeded"; then
            echo -e "${GREEN}  $line${NC}"
        else
            echo -e "${YELLOW}  $line${NC}"
        fi
    done
    
    # Count by probe type
    echo -e "\n${BOLD}Probe Failure Breakdown:${NC}"
    grep -i "failed" "$TMP_EVENTS" | grep -oE '(Liveness|Readiness|Startup)' | sort | uniq -c | sort -rn | while read count type; do
        case "$type" in
            Liveness)
                echo -e "  ${RED}$count${NC} - $type probe failures (causes container restarts)"
                ;;
            Readiness)
                echo -e "  ${YELLOW}$count${NC} - $type probe failures (removes from service)"
                ;;
            Startup)
                echo -e "  ${MAGENTA}$count${NC} - $type probe failures (kills slow-starting containers)"
                ;;
        esac
    done
else
    echo -e "${GREEN}No probe failure events found${NC}"
fi

echo ""

#############################################################################
# 2. IDENTIFY PODS WITH PROBE FAILURES
#############################################################################
echo -e "${BOLD}${MAGENTA}[2/5] Analyzing pods with probe failures...${NC}"

# Get pods with restarts (likely probe failures)
kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses[]? | .restartCount > 0) | 
    .metadata.namespace as $ns | .metadata.name as $pod |
    .status.containerStatuses[] | 
    select(.restartCount > 0) |
    [$ns, $pod, .name, .restartCount, (.lastState.terminated.reason // "Unknown"), (.lastState.terminated.exitCode // "N/A")] | @tsv' \
    > "$TMP_PROBE_FAILURES"

if [ -s "$TMP_PROBE_FAILURES" ]; then
    RESTART_COUNT=$(wc -l < "$TMP_PROBE_FAILURES" | tr -d ' ')
    echo -e "${YELLOW}Found $RESTART_COUNT containers with restarts (may indicate probe failures):${NC}\n"
    
    echo -e "${BOLD}$(printf '%-30s %-50s %-30s %-10s %-15s %s' 'NAMESPACE' 'POD' 'CONTAINER' 'RESTARTS' 'REASON' 'EXIT_CODE')${NC}"
    while IFS=$'\t' read -r ns pod container restarts reason exitcode; do
        if [ "$restarts" -gt 10 ]; then
            color="${RED}"
        elif [ "$restarts" -gt 5 ]; then
            color="${YELLOW}"
        else
            color="${CYAN}"
        fi
        printf "${color}%-30s %-50s %-30s %-10s %-15s %s${NC}\n" "$ns" "$pod" "$container" "$restarts" "$reason" "$exitcode"
    done < "$TMP_PROBE_FAILURES"
else
    echo -e "${GREEN}No containers with restarts found${NC}"
fi

echo ""

#############################################################################
# 3. ANALYZE PROBE CONFIGURATIONS
#############################################################################
echo -e "${BOLD}${MAGENTA}[3/5] Analyzing probe configurations for pods with restarts...${NC}"

if [ -s "$TMP_PROBE_FAILURES" ]; then
    echo -e "${BOLD}Probe Configurations:${NC}\n"
    
    # For each pod with restarts, show probe config
    while IFS=$'\t' read -r ns pod container restarts reason exitcode; do
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}Pod: ${BLUE}$pod${NC} ${BOLD}(namespace: $ns, container: $container)${NC}"
        echo -e "${YELLOW}Restarts: $restarts | Last Exit: $reason ($exitcode)${NC}\n"
        
        # Get probe configurations
        PROBE_CONFIG=$(kubectl get pod "$pod" -n "$ns" $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
            jq -r --arg container "$container" '
            .spec.containers[] | select(.name == $container) | 
            {
                liveness: .livenessProbe,
                readiness: .readinessProbe,
                startup: .startupProbe
            }')
        
        # Extract probe paths for comparison
        LIVENESS_PATH=$(echo "$PROBE_CONFIG" | jq -r '.liveness.httpGet.path // empty')
        READINESS_PATH=$(echo "$PROBE_CONFIG" | jq -r '.readiness.httpGet.path // empty')
        
        # Liveness Probe
        LIVENESS=$(echo "$PROBE_CONFIG" | jq -r '.liveness // empty')
        if [ -n "$LIVENESS" ] && [ "$LIVENESS" != "null" ]; then
            echo -e "${BOLD}  Liveness Probe:${NC}"
            echo "$LIVENESS" | jq -r 'to_entries | .[] | "    \(.key): \(.value)"' | sed 's/^/  /'
            echo ""
        else
            echo -e "${YELLOW}  Liveness Probe: Not configured${NC}\n"
        fi
        
        # Readiness Probe
        READINESS=$(echo "$PROBE_CONFIG" | jq -r '.readiness // empty')
        if [ -n "$READINESS" ] && [ "$READINESS" != "null" ]; then
            echo -e "${BOLD}  Readiness Probe:${NC}"
            echo "$READINESS" | jq -r 'to_entries | .[] | "    \(.key): \(.value)"' | sed 's/^/  /'
            echo ""
        else
            echo -e "${YELLOW}  Readiness Probe: Not configured${NC}\n"
        fi
        
        # Check if liveness and readiness use same endpoint (anti-pattern)
        if [ -n "$LIVENESS_PATH" ] && [ -n "$READINESS_PATH" ] && [ "$LIVENESS_PATH" = "$READINESS_PATH" ]; then
            echo -e "${RED}  ⚠ WARNING: Liveness and Readiness probes use the same endpoint: $LIVENESS_PATH${NC}"
            echo -e "${RED}     This is an anti-pattern! They should check different conditions:${NC}"
            echo -e "${RED}     - Liveness: Is the app running? (restart if fails)${NC}"
            echo -e "${RED}     - Readiness: Can the app handle traffic? (remove from service if fails)${NC}\n"
        fi
        
        # Startup Probe
        STARTUP=$(echo "$PROBE_CONFIG" | jq -r '.startup // empty')
        if [ -n "$STARTUP" ] && [ "$STARTUP" != "null" ]; then
            echo -e "${BOLD}  Startup Probe:${NC}"
            echo "$STARTUP" | jq -r 'to_entries | .[] | "    \(.key): \(.value)"' | sed 's/^/  /'
            echo ""
        else
            echo -e "${YELLOW}  Startup Probe: Not configured${NC}\n"
        fi
        
        # Show recent events for this pod
        echo -e "${BOLD}  Recent Events:${NC}"
        kubectl get events -n "$ns" $KUBECTL_TLS_FLAG --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' 2>/dev/null | \
            grep -E 'Liveness|Readiness|Startup|Killing|Unhealthy|BackOff' | tail -5 | sed 's/^/    /'
        echo ""
        
    done < "$TMP_PROBE_FAILURES" | head -100
else
    echo -e "${GREEN}No containers with restarts to analyze${NC}"
fi

echo ""

#############################################################################
# 4. CHECK PODS WITHOUT PROBES
#############################################################################
echo -e "${BOLD}${MAGENTA}[4/5] Checking for pods without health probes...${NC}"

# Find running pods without liveness or readiness probes
NO_PROBES=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase == "Running") | 
    .metadata.namespace as $ns | .metadata.name as $pod |
    .spec.containers[] | 
    select(.livenessProbe == null and .readinessProbe == null) |
    [$ns, $pod, .name] | @tsv' | head -20)

if [ -n "$NO_PROBES" ]; then
    echo -e "${YELLOW}Found pods without health probes (first 20):${NC}\n"
    echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'CONTAINER')${NC}"
    echo "$NO_PROBES" | while IFS=$'\t' read -r ns pod container; do
        printf "${YELLOW}%-30s %-50s %s${NC}\n" "$ns" "$pod" "$container"
    done
    
    echo -e "${CYAN}Recommendation: Add liveness and readiness probes for better health monitoring${NC}"
else
    echo -e "${GREEN}All running pods have health probes configured${NC}"
fi

echo ""

# Check for same endpoint anti-pattern
echo -e "${BOLD}Checking for liveness/readiness endpoint anti-patterns...${NC}"
SAME_ENDPOINT=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | 
    .metadata.namespace as $ns | .metadata.name as $pod |
    .spec.containers[] | 
    select(.livenessProbe.httpGet.path != null and .readinessProbe.httpGet.path != null) |
    select(.livenessProbe.httpGet.path == .readinessProbe.httpGet.path) |
    [$ns, $pod, .name, .livenessProbe.httpGet.path] | @tsv')

if [ -n "$SAME_ENDPOINT" ]; then
    echo -e "${RED}Found pods where liveness and readiness use the SAME endpoint:${NC}\n"
    echo -e "${BOLD}$(printf '%-30s %-50s %-30s %s' 'NAMESPACE' 'POD' 'CONTAINER' 'SHARED_ENDPOINT')${NC}"
    echo "$SAME_ENDPOINT" | while IFS=$'\t' read -r ns pod container path; do
        printf "${RED}%-30s %-50s %-30s %s${NC}\n" "$ns" "$pod" "$container" "$path"
    done
    echo -e "\n${RED}⚠ ANTI-PATTERN DETECTED!${NC}"
    echo -e "${YELLOW}Liveness and readiness probes should serve different purposes:${NC}"
    echo -e "  • Liveness checks if the app is alive (restart if dead)"
    echo -e "  • Readiness checks if the app can serve traffic (remove from load balancer if not ready)"
    echo -e "\n${CYAN}Best practice: Use separate endpoints (e.g., /healthz for liveness, /ready for readiness)${NC}"
else
    echo -e "${GREEN}No anti-patterns detected - liveness and readiness use different endpoints${NC}"
fi

echo ""

#############################################################################
# 5. PROBE TROUBLESHOOTING COMMANDS
#############################################################################
echo -e "${BOLD}${MAGENTA}[5/5] Troubleshooting commands for pods with probe issues...${NC}"

if [ -s "$TMP_PROBE_FAILURES" ]; then
    echo -e "${BOLD}Copy/paste commands to investigate probe failures:${NC}\n"
    
    # Generate commands for each pod
    while IFS=$'\t' read -r ns pod container restarts reason exitcode; do
        echo -e "${BLUE}Pod:${NC} $pod (container: $container, namespace: $ns)"
        echo ""
        echo "  Check pod events for probe failures:"
        echo -e "    ${BOLD}kubectl get events -n $ns $KUBECTL_TLS_FLAG --field-selector involvedObject.name=$pod --sort-by='.lastTimestamp'${NC}"
        echo ""
        echo "  Describe pod to see probe configuration and status:"
        echo -e "    ${BOLD}kubectl describe pod $pod -n $ns $KUBECTL_TLS_FLAG | grep -A 10 'Liveness:\\|Readiness:\\|Startup:'${NC}"
        echo ""
        echo "  Check current container logs:"
        echo -e "    ${BOLD}kubectl logs $pod -c $container -n $ns $KUBECTL_TLS_FLAG${NC}"
        echo ""
        echo "  Check previous container logs (from failed container):"
        echo -e "    ${BOLD}kubectl logs $pod -c $container -n $ns --previous $KUBECTL_TLS_FLAG${NC}"
        echo ""
        echo "  Manually test liveness/readiness endpoint (if HTTP):"
        echo -e "    ${BOLD}kubectl exec $pod -c $container -n $ns $KUBECTL_TLS_FLAG -- wget -qO- http://localhost:<port><path>${NC}"
        echo -e "    ${BOLD}kubectl exec $pod -c $container -n $ns $KUBECTL_TLS_FLAG -- curl -v http://localhost:<port><path>${NC}"
        echo ""
        echo "  ---"
        echo ""
    done < "$TMP_PROBE_FAILURES" | head -200
else
    echo -e "${GREEN}No probe failures to troubleshoot${NC}"
fi

echo ""

#############################################################################
# SUMMARY AND RECOMMENDATIONS
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary and Recommendations ===${NC}\n"

ISSUES=0
WARNINGS=0

if [ -s "$TMP_EVENTS" ] && grep -qi "failed" "$TMP_EVENTS"; then
    ISSUES=$((ISSUES + 1))
    FAILURE_COUNT=$(grep -ci "failed" "$TMP_EVENTS")
    echo -e "${RED}✗ Active probe failures detected ($FAILURE_COUNT events)${NC}"
fi

if [ -s "$TMP_PROBE_FAILURES" ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ Containers with restarts detected (may indicate probe issues)${NC}"
fi

if [ -n "$NO_PROBES" ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ Pods without health probes detected${NC}"
fi

if [ $ISSUES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ No probe issues detected${NC}"
else
    echo ""
    echo -e "${BOLD}Common Probe Failure Causes:${NC}"
    echo -e "  ${CYAN}1. Application startup time exceeds probe timeout${NC}"
    echo -e "     Fix: Increase initialDelaySeconds or add a startup probe"
    echo ""
    echo -e "  ${CYAN}2. Probe endpoint returns wrong HTTP status${NC}"
    echo -e "     Fix: Ensure health endpoint returns 200-399 for success"
    echo ""
    echo -e "  ${CYAN}3. Probe timeout too aggressive${NC}"
    echo -e "  ${CYAN}5. Resource constraints causing slow response${NC}"
    echo -e "     Fix: Increase CPU/memory limits or reduce probe frequency"
    echo ""
    echo -e "  ${CYAN}6. Liveness and readiness using the same endpoint${NC}"
    echo -e "     Fix: Use separate endpoints for different purposes"
    echo ""
    
    echo -e "${BOLD}Recommended Probe Settings:${NC}"
    echo -e "  ${CYAN}5. Resource constraints causing slow response${NC}"
    echo -e "     Fix: Increase CPU/memory limits or reduce probe frequency"
    echo ""
    
    echo -e "${BOLD}Recommended Probe Settings:${NC}"
    cat << 'EOF'
  livenessProbe:
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 30    # Wait for app to start
    periodSeconds: 10          # Check every 10s
    timeoutSeconds: 5          # Wait 5s for response
    failureThreshold: 3        # Restart after 3 failures
    
  readinessProbe:
    httpGet:
      path: /ready
      port: 8080
    initialDelaySeconds: 10    # Check sooner than liveness
    periodSeconds: 5           # Check more frequently
    timeoutSeconds: 3
    failureThreshold: 3        # Remove from service after 3 failures
    
  startupProbe:                # For slow-starting apps
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 30       # Allow up to 5 minutes to start
EOF
fi

echo ""
echo -e "${GREEN}Probe diagnosis complete!${NC}"
