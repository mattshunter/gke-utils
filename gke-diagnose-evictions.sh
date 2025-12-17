#!/bin/bash

# Script to diagnose pod evictions in GKE clusters
# Usage: ./gke-diagnose-evictions.sh -p <project> -c <cluster> -z <zone> [-n <namespace>] [-v] [-q]

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
    -z, --zone <zone>           GKE cluster zone (e.g., us-east4-a)

Optional Parameters:
    -n, --namespace <namespace> Specific namespace to check (default: all namespaces)
    -a, --all-namespaces        Check all namespaces explicitly
    -v, --verbose               Verbose output
    -q, --quiet                 Quiet mode (minimal output)
    -l, --auto-login            Auto-login to gcloud if not authenticated
    -h, --help                  Show this help message

Examples:
    $0 -p my-project -c my-cluster -z us-east4-a
    $0 --project my-project --cluster my-cluster --zone us-east4-a
    $0 -p my-project -c my-cluster -z us-east4-a -n production
    $0 --project my-project --cluster my-cluster --zone us-east4-a --all-namespaces --verbose

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
if [ -z "$PROJECT" ] || [ -z "$CLUSTER" ] || [ -z "$ZONE" ]; then
    echo -e "${RED}Error: Project, cluster, and zone are required${NC}"
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
    [ "$VERBOSE" = true ] && echo -e "${CYAN}Getting credentials for cluster: $CLUSTER in zone: $ZONE${NC}"
    gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &> /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to get cluster credentials${NC}"
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
echo -e "${BOLD}${BLUE}=== GKE Pod Eviction Diagnostic Tool ===${NC}\n"

check_gcloud_auth
set_project
get_cluster_credentials
check_kubectl

echo -e "${GREEN}Connected to cluster: $CLUSTER${NC}"
echo -e "${GREEN}Project: $PROJECT${NC}"
echo -e "${GREEN}Zone: $ZONE${NC}"
echo -e "${GREEN}Scope: $NS_DISPLAY${NC}\n"

# Create temporary files for data collection
TMP_EVENTS=$(mktemp)
TMP_NODES=$(mktemp)
TMP_PODS=$(mktemp)

trap "rm -f $TMP_EVENTS $TMP_NODES $TMP_PODS" EXIT

#############################################################################
# 1. CHECK EVICTION EVENTS
#############################################################################
echo -e "${BOLD}${MAGENTA}[1/8] Checking for eviction events...${NC}"

kubectl get events $NS_FLAG $KUBECTL_TLS_FLAG --sort-by='.lastTimestamp' 2>/dev/null | grep -i evict > "$TMP_EVENTS"

if [ -s "$TMP_EVENTS" ]; then
    EVICTION_COUNT=$(wc -l < "$TMP_EVENTS" | tr -d ' ')
    echo -e "${RED}Found $EVICTION_COUNT eviction events:${NC}\n"
    
    # Show recent evictions in a formatted table
    echo -e "${BOLD}Recent Evictions:${NC}"
    head -20 "$TMP_EVENTS" | awk '{printf "  %-50s %-20s %s\n", substr($0, index($0, $4)), $1, $2}'
    
    if [ $(wc -l < "$TMP_EVENTS" | tr -d ' ') -gt 20 ]; then
        echo -e "\n  ${YELLOW}... and $((EVICTION_COUNT - 20)) more eviction events${NC}"
    fi
    
    # Analyze eviction reasons
    echo -e "\n${BOLD}Eviction Breakdown by Reason:${NC}"
    grep -oE '(Evicted|Preempting|OutOfMemory|DiskPressure|MemoryPressure|NodeAffinity)' "$TMP_EVENTS" | sort | uniq -c | sort -rn | while read count reason; do
        case "$reason" in
            *Memory*|*OutOfMemory*)
                echo -e "  ${RED}$count${NC} - $reason"
                ;;
            *Disk*)
                echo -e "  ${YELLOW}$count${NC} - $reason"
                ;;
            *)
                echo -e "  ${CYAN}$count${NC} - $reason"
                ;;
        esac
    done
else
    echo -e "${GREEN}No eviction events found${NC}"
fi

echo ""

#############################################################################
# 2. IDENTIFY EVICTION REASONS (Pod Status)
#############################################################################
echo -e "${BOLD}${MAGENTA}[2/8] Checking pod statuses for eviction reasons...${NC}"

kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.reason == "Evicted") | 
    [.metadata.namespace, .metadata.name, .status.reason, .status.message] | @tsv' > "$TMP_PODS"

if [ -s "$TMP_PODS" ]; then
    EVICTED_PODS=$(wc -l < "$TMP_PODS" | tr -d ' ')
    echo -e "${RED}Found $EVICTED_PODS currently evicted pods:${NC}\n"
    
    echo -e "${BOLD}$(printf '%-30s %-50s %-20s %s' 'NAMESPACE' 'POD NAME' 'REASON' 'MESSAGE')${NC}"
    while IFS=$'\t' read -r namespace name reason message; do
        # Truncate message if too long
        short_msg=$(echo "$message" | cut -c1-60)
        printf "%-30s %-50s %-20s %s\n" "$namespace" "$name" "$reason" "$short_msg"
    done < "$TMP_PODS"
    
    echo -e "\n${YELLOW}Tip: Clean up evicted pods with:${NC}"
    echo -e "  kubectl delete pods $NS_FLAG $KUBECTL_TLS_FLAG --field-selector status.phase=Failed"
else
    echo -e "${GREEN}No currently evicted pods found${NC}"
fi

echo ""

#############################################################################
# 3. CHECK NODE CONDITIONS
#############################################################################
echo -e "${BOLD}${MAGENTA}[3/8] Checking node conditions for pressure...${NC}"

kubectl get nodes $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | .metadata.name as $node | 
    .status.conditions[] | select(.status == "True" and (.type | test("Pressure|DiskPressure|MemoryPressure|PIDPressure"))) | 
    [$node, .type, .reason, .message] | @tsv' > "$TMP_NODES"

if [ -s "$TMP_NODES" ]; then
    echo -e "${RED}Nodes under pressure:${NC}\n"
    echo -e "${BOLD}$(printf '%-50s %-20s %-30s %s' 'NODE' 'CONDITION' 'REASON' 'MESSAGE')${NC}"
    while IFS=$'\t' read -r node condition reason message; do
        case "$condition" in
            *Memory*)
                color="${RED}"
                ;;
            *Disk*)
                color="${YELLOW}"
                ;;
            *)
                color="${CYAN}"
                ;;
        esac
        printf "${color}%-50s %-20s %-30s %s${NC}\n" "$node" "$condition" "$reason" "$(echo $message | cut -c1-40)"
    done < "$TMP_NODES"
else
    echo -e "${GREEN}All nodes healthy - no pressure conditions detected${NC}"
fi

# Also show all node conditions for reference
echo -e "\n${BOLD}All Node Conditions:${NC}"
kubectl get nodes $KUBECTL_TLS_FLAG -o wide 2>/dev/null | head -10

echo ""

#############################################################################
# 4. REVIEW POD RESOURCE REQUESTS/LIMITS
#############################################################################
echo -e "${BOLD}${MAGENTA}[4/8] Analyzing pod resource requests and limits...${NC}"

# Find pods without resource requests (high eviction risk)
echo -e "${BOLD}Pods without memory requests (highest eviction risk):${NC}"
NO_REQUESTS=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.containers[].resources.requests.memory == null) | 
    [.metadata.namespace, .metadata.name, .spec.containers[].name] | @tsv' | head -20)

if [ -n "$NO_REQUESTS" ]; then
    echo -e "${RED}Found pods without memory requests:${NC}\n"
    echo -e "${BOLD}$(printf '%-30s %-50s %s' 'NAMESPACE' 'POD' 'CONTAINER')${NC}"
    echo "$NO_REQUESTS" | while IFS=$'\t' read -r ns pod container; do
        printf "${RED}%-30s %-50s %s${NC}\n" "$ns" "$pod" "$container"
    done
    
    echo -e "\n${YELLOW}Recommendation: Add resource requests to prevent unexpected evictions${NC}"
else
    echo -e "${GREEN}All pods have memory requests defined${NC}"
fi

echo ""

# Show top resource consumers
echo -e "${BOLD}Top pods by memory request:${NC}"
kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $pod | 
    .spec.containers[] | 
    select(.resources.requests.memory != null) | 
    [$ns, $pod, .name, .resources.requests.memory, (.resources.limits.memory // "none")] | @tsv' | \
    sort -t$'\t' -k4 -h | tail -10 | while IFS=$'\t' read -r ns pod container req lim; do
        printf "  %-25s %-40s %-25s Req: %-10s Lim: %s\n" "$ns" "$pod" "$container" "$req" "$lim"
    done

echo ""

#############################################################################
# 5. CHECK NODE RESOURCE USAGE
#############################################################################
echo -e "${BOLD}${MAGENTA}[5/8] Checking current node resource usage...${NC}"

if command -v column &> /dev/null; then
    echo -e "${BOLD}Node Resource Usage:${NC}"
    kubectl top nodes $KUBECTL_TLS_FLAG 2>/dev/null | column -t
else
    echo -e "${BOLD}Node Resource Usage:${NC}"
    kubectl top nodes $KUBECTL_TLS_FLAG 2>/dev/null
fi

echo ""

echo -e "${BOLD}Top memory-consuming pods:${NC}"
if command -v column &> /dev/null; then
    kubectl top pods $NS_FLAG $KUBECTL_TLS_FLAG --sort-by=memory 2>/dev/null | head -15 | column -t
else
    kubectl top pods $NS_FLAG $KUBECTL_TLS_FLAG --sort-by=memory 2>/dev/null | head -15
fi

echo ""

#############################################################################
# 6. REVIEW EVICTION THRESHOLDS
#############################################################################
echo -e "${BOLD}${MAGENTA}[6/8] Checking kubelet eviction thresholds...${NC}"

echo -e "${BOLD}Default GKE Eviction Thresholds:${NC}"
echo -e "  ${CYAN}memory.available${NC} < 100Mi"
echo -e "  ${CYAN}nodefs.available${NC} < 10%"
echo -e "  ${CYAN}imagefs.available${NC} < 15%"
echo -e "  ${CYAN}nodefs.inodesFree${NC} < 5%"

echo -e "\n${BOLD}Current Node Allocatable Resources:${NC}"
kubectl get nodes $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | [.metadata.name, .status.allocatable.memory, .status.allocatable.pods, .status.allocatable.cpu] | @tsv' | \
    while IFS=$'\t' read -r node mem pods cpu; do
        printf "  %-50s Memory: %-12s Pods: %-5s CPU: %s\n" "$node" "$mem" "$pods" "$cpu"
    done

echo -e "\n${YELLOW}Note: To view actual kubelet configuration, SSH to a node and check:${NC}"
echo -e "  /var/lib/kubelet/config.yaml"

echo ""

#############################################################################
# 7. CHECK POD PRIORITY CLASSES
#############################################################################
echo -e "${BOLD}${MAGENTA}[7/8] Analyzing pod priority classes...${NC}"

echo -e "${BOLD}Available Priority Classes:${NC}"
kubectl get priorityclasses $KUBECTL_TLS_FLAG 2>/dev/null | head -10

echo -e "\n${BOLD}Pods by Priority Class:${NC}"
kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | [(.spec.priorityClassName // "none"), .metadata.namespace, .metadata.name] | @tsv' | \
    awk -F'\t' '{pc[$1]++; total++} END {
        for (p in pc) {
            printf "  %-30s %5d pods (%.1f%%)\n", p, pc[p], (pc[p]/total)*100
        }
    }'

echo -e "\n${YELLOW}Tip: Pods without priority classes are more likely to be evicted${NC}"
echo -e "${YELLOW}Consider creating priority classes for critical workloads${NC}"

echo ""

#############################################################################
# 8. CHECK POD DISRUPTION BUDGETS
#############################################################################
echo -e "${BOLD}${MAGENTA}[8/8] Checking Pod Disruption Budgets (PDBs)...${NC}"

PDB_OUTPUT=$(kubectl get pdb $NS_FLAG $KUBECTL_TLS_FLAG 2>/dev/null)

if [ -n "$PDB_OUTPUT" ] && [ $(echo "$PDB_OUTPUT" | wc -l) -gt 1 ]; then
    echo -e "${BOLD}Existing Pod Disruption Budgets:${NC}"
    echo "$PDB_OUTPUT" | head -20
    
    if [ $(echo "$PDB_OUTPUT" | wc -l) -gt 20 ]; then
        echo -e "\n  ${YELLOW}... and more PDBs${NC}"
    fi
else
    echo -e "${YELLOW}No Pod Disruption Budgets found${NC}"
    echo -e "\n${YELLOW}Recommendation: Create PDBs to limit disruptions during evictions${NC}"
    echo -e "\nExample PDB:"
    cat << 'EOF'
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: my-app-pdb
  spec:
    minAvailable: 1
    selector:
      matchLabels:
        app: my-app
EOF
fi

echo ""

#############################################################################
# SUMMARY AND RECOMMENDATIONS
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary and Recommendations ===${NC}\n"

# Count issues
ISSUES=0
WARNINGS=0

if [ -s "$TMP_EVENTS" ]; then
    ISSUES=$((ISSUES + 1))
    echo -e "${RED}✗ Eviction events detected ($EVICTION_COUNT events)${NC}"
fi

if [ -s "$TMP_NODES" ]; then
    ISSUES=$((ISSUES + 1))
    echo -e "${RED}✗ Nodes under resource pressure${NC}"
fi

if [ -n "$NO_REQUESTS" ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ Pods without resource requests detected${NC}"
fi

if [ -z "$PDB_OUTPUT" ] || [ $(echo "$PDB_OUTPUT" | wc -l) -le 1 ]; then
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ No Pod Disruption Budgets configured${NC}"
fi

if [ $ISSUES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ No major issues detected${NC}"
else
    echo ""
    echo -e "${BOLD}Action Items:${NC}"
    
    if [ -s "$TMP_EVENTS" ]; then
        echo -e "  1. Investigate eviction events and their root causes"
        echo -e "     ${CYAN}kubectl describe node <node-name> $KUBECTL_TLS_FLAG${NC}"
    fi
    
    if [ -s "$TMP_NODES" ]; then
        echo -e "  2. Address node resource pressure (consider scaling cluster)"
        echo -e "     ${CYAN}gcloud container clusters resize $CLUSTER --zone $ZONE --num-nodes <count>${NC}"
    fi
    
    if [ -n "$NO_REQUESTS" ]; then
        echo -e "  3. Add resource requests/limits to pods without them"
        echo -e "     ${CYAN}See pods listed in section [4/8]${NC}"
    fi
    
    if [ -z "$PDB_OUTPUT" ] || [ $(echo "$PDB_OUTPUT" | wc -l) -le 1 ]; then
        echo -e "  4. Create Pod Disruption Budgets for critical applications"
        echo -e "     ${CYAN}kubectl apply -f <pdb-manifest.yaml>${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Diagnosis complete!${NC}"
