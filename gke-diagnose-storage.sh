#!/bin/bash

# Script to diagnose storage and disk space issues in GKE clusters
# Usage: ./gke-diagnose-storage.sh -p <project> -c <cluster> [-z <zone> | -r <region>] [-n <namespace>] [-v] [-q]

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
POD_NAME=""

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
    -d, --pod <pod-name>        Specific pod to diagnose (shows detailed disk usage)
    -a, --all-namespaces        Check all namespaces explicitly
    -v, --verbose               Verbose output
    -q, --quiet                 Quiet mode (minimal output)
    -l, --auto-login            Auto-login to gcloud if not authenticated
    -h, --help                  Show this help message

Examples:
    $0 -p my-project -c my-cluster -z us-east4-a
    $0 --project my-project --cluster my-cluster --region us-east4
    $0 -p my-project -c my-cluster -z us-east4-a -n elastic
    $0 -p my-project -c my-cluster -z us-east4-a -n elastic -d elasticsearch-master-0
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
        -d|--pod)
            POD_NAME="$2"
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

# Validate zone or region
if [ -z "$ZONE" ] && [ -z "$REGION" ]; then
    echo -e "${RED}Error: Either zone (-z) or region (-r) must be specified${NC}"
    usage
fi

# If pod is specified, namespace is required
if [ -n "$POD_NAME" ] && [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Error: Namespace (-n) is required when specifying a pod (-d)${NC}"
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
    if [ -n "$ZONE" ]; then
        [ "$VERBOSE" = true ] && echo -e "${CYAN}Getting credentials for cluster: $CLUSTER in zone: $ZONE${NC}"
        gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &> /dev/null
    else
        [ "$VERBOSE" = true ] && echo -e "${CYAN}Getting credentials for cluster: $CLUSTER in region: $REGION${NC}"
        gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" &> /dev/null
    fi
    
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

# Function to format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0B"
        return
    fi
    
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while [ $(echo "$size >= 1024" | bc 2>/dev/null || echo 0) -eq 1 ] && [ $unit -lt 4 ]; do
        size=$(echo "scale=2; $size / 1024" | bc 2>/dev/null || echo $size)
        unit=$((unit + 1))
    done
    
    echo "${size}${units[$unit]}"
}

# Function to get pod storage info
get_pod_storage_info() {
    local pod=$1
    local namespace=$2
    
    echo -e "\n${BOLD}${CYAN}Storage details for pod: $pod${NC}"
    
    # Get filesystem usage
    echo -e "\n${YELLOW}Filesystem Usage:${NC}"
    kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- df -h 2>/dev/null || {
        echo -e "${RED}Failed to retrieve filesystem info${NC}"
        return
    }
    
    # Try to find data directories
    echo -e "\n${YELLOW}Checking common data directories:${NC}"
    
    # Elasticsearch data
    if kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- test -d /usr/share/elasticsearch/data 2>/dev/null; then
        echo -e "${GREEN}Elasticsearch data directory:${NC}"
        kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- du -sh /usr/share/elasticsearch/data 2>/dev/null
        
        echo -e "\n${YELLOW}Top 10 largest directories:${NC}"
        kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- sh -c "du -h /usr/share/elasticsearch/data 2>/dev/null | sort -h | tail -20" 2>/dev/null
    fi
    
    # Generic data directories
    for dir in /data /var/lib /opt/data /mnt/data; do
        if kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- test -d "$dir" 2>/dev/null; then
            echo -e "\n${GREEN}Directory: $dir${NC}"
            kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- du -sh "$dir" 2>/dev/null || true
        fi
    done
}

# Main execution
echo -e "${BOLD}${BLUE}=== GKE Storage Diagnostic Tool ===${NC}\n"

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

# Initialize tracking arrays for summary
HIGH_USAGE_PODS=()
HIGH_USAGE_PERCENTAGES=()

#############################################################################
# SPECIFIC POD DIAGNOSIS
#############################################################################
if [ -n "$POD_NAME" ]; then
    get_pod_storage_info "$POD_NAME" "$NAMESPACE"
    exit 0
fi

#############################################################################
# 1. CHECK PVC STATUS AND CAPACITY
#############################################################################
echo -e "${BOLD}${MAGENTA}[1/6] Checking Persistent Volume Claims (PVC)...${NC}\n"

PVC_OUTPUT=$(kubectl get pvc $NS_FLAG $KUBECTL_TLS_FLAG -o wide 2>/dev/null)
if [ -z "$PVC_OUTPUT" ]; then
    echo -e "${YELLOW}No PVCs found in scope${NC}\n"
else
    echo "$PVC_OUTPUT"
    echo ""
    
    # Count PVCs
    PVC_COUNT=$(echo "$PVC_OUTPUT" | grep -v "^NAMESPACE\|^NAME" | wc -l | tr -d ' ')
    echo -e "${CYAN}Total PVCs: $PVC_COUNT${NC}\n"
fi

#############################################################################
# 2. CHECK PVC USAGE DETAILS
#############################################################################
echo -e "${BOLD}${MAGENTA}[2/6] Analyzing PVC capacity and usage...${NC}\n"

if [ -z "$PVC_OUTPUT" ]; then
    echo -e "${YELLOW}Skipping - no PVCs found${NC}\n"
else
    # Get detailed PVC information
    if [ -n "$NAMESPACE" ]; then
        PVCS=$(kubectl get pvc -n "$NAMESPACE" $KUBECTL_TLS_FLAG -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{.spec.resources.requests.storage}{" "}{.status.capacity.storage}{"\n"}{end}' 2>/dev/null)
    else
        PVCS=$(kubectl get pvc --all-namespaces $KUBECTL_TLS_FLAG -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{.spec.resources.requests.storage}{" "}{.status.capacity.storage}{"\n"}{end}' 2>/dev/null)
    fi
    
    if [ -n "$PVCS" ]; then
        printf "%-40s %-20s %-15s %-15s\n" "PVC NAME" "NAMESPACE" "REQUESTED" "CAPACITY"
        printf "%-40s %-20s %-15s %-15s\n" "----------------------------------------" "--------------------" "---------------" "---------------"
        echo "$PVCS" | while read -r name namespace requested capacity; do
            printf "%-40s %-20s %-15s %-15s\n" "$name" "$namespace" "$requested" "$capacity"
        done
        echo ""
    fi
fi

#############################################################################
# 3. CHECK POD DISK USAGE (for pods with PVCs)
#############################################################################
echo -e "${BOLD}${MAGENTA}[3/6] Checking disk usage for pods with storage...${NC}\n"

if [ -z "$PVC_OUTPUT" ]; then
    echo -e "${YELLOW}Skipping - no PVCs found${NC}\n"
else
    # Get pods that have PVCs mounted
    PODS_WITH_STORAGE=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim != null) | "\(.metadata.name) \(.metadata.namespace)"' 2>/dev/null)
    
    if [ -z "$PODS_WITH_STORAGE" ]; then
        echo -e "${YELLOW}No pods found with PVC mounts${NC}\n"
    else
        while read -r pod namespace; do
            if [ -z "$pod" ]; then
                continue
            fi
            
            echo -e "${CYAN}Pod: $pod (namespace: $namespace)${NC}"
            
            # Check if pod is running
            POD_STATUS=$(kubectl get pod $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "$POD_STATUS" != "Running" ]; then
                echo -e "${YELLOW}  Status: $POD_STATUS (skipping - not running)${NC}\n"
                continue
            fi
            
            # Try to get df output
            DF_OUTPUT=$(kubectl exec $KUBECTL_TLS_FLAG -n "$namespace" "$pod" -- df -h 2>/dev/null | grep -E "Filesystem|/dev/|overlay" || true)
            if [ -n "$DF_OUTPUT" ]; then
                while IFS= read -r line; do
                    # Check for high usage (>80%)
                    if echo "$line" | grep -qE "[8-9][0-9]%|100%"; then
                        USAGE_PCT=$(echo "$line" | grep -oE "[0-9]+%" | tail -1 | tr -d '%')
                        if [ "$USAGE_PCT" -ge 80 ]; then
                            echo -e "  ${RED}$line${NC}"
                            HIGH_USAGE_PODS+=("$pod ($namespace)")
                            HIGH_USAGE_PERCENTAGES+=("$USAGE_PCT")
                        else
                            echo "  $line"
                        fi
                    else
                        echo "  $line"
                    fi
                done <<< "$DF_OUTPUT"
            else
                echo -e "${YELLOW}  Unable to retrieve disk usage${NC}"
            fi
            echo ""
        done <<< "$PODS_WITH_STORAGE"
    fi
fi

#############################################################################
# 4. CHECK NODE DISK PRESSURE
#############################################################################
echo -e "${BOLD}${MAGENTA}[4/6] Checking node disk pressure...${NC}\n"

NODE_CONDITIONS=$(kubectl get nodes $KUBECTL_TLS_FLAG -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.name) \(.status.conditions[] | select(.type=="DiskPressure") | .status)"' 2>/dev/null)

if [ -z "$NODE_CONDITIONS" ]; then
    echo -e "${YELLOW}Unable to retrieve node conditions${NC}\n"
else
    printf "%-50s %-15s\n" "NODE NAME" "DISK PRESSURE"
    printf "%-50s %-15s\n" "--------------------------------------------------" "---------------"
    
    PRESSURE_COUNT=0
    echo "$NODE_CONDITIONS" | while read -r node pressure; do
        if [ "$pressure" = "True" ]; then
            echo -e "${RED}$(printf "%-50s %-15s" "$node" "$pressure")${NC}"
            PRESSURE_COUNT=$((PRESSURE_COUNT + 1))
        else
            echo -e "${GREEN}$(printf "%-50s %-15s" "$node" "$pressure")${NC}"
        fi
    done
    echo ""
fi

#############################################################################
# 5. CHECK STORAGE CLASSES
#############################################################################
echo -e "${BOLD}${MAGENTA}[5/6] Checking available storage classes...${NC}\n"

SC_OUTPUT=$(kubectl get storageclass $KUBECTL_TLS_FLAG 2>/dev/null)
if [ -z "$SC_OUTPUT" ]; then
    echo -e "${YELLOW}No storage classes found${NC}\n"
else
    echo "$SC_OUTPUT"
    echo ""
fi

#############################################################################
# 6. CHECK FOR PODS IN PENDING STATE (storage issues)
#############################################################################
echo -e "${BOLD}${MAGENTA}[6/6] Checking for pods pending due to storage issues...${NC}\n"

PENDING_PODS=$(kubectl get pods $NS_FLAG $KUBECTL_TLS_FLAG 2>/dev/null | grep Pending || true)
if [ -z "$PENDING_PODS" ]; then
    echo -e "${GREEN}No pending pods found${NC}\n"
else
    echo -e "${YELLOW}Pending pods found:${NC}"
    echo "$PENDING_PODS"
    echo ""
    
    # Check events for storage-related issues
    echo -e "${YELLOW}Checking events for storage-related issues...${NC}\n"
    kubectl get events $NS_FLAG $KUBECTL_TLS_FLAG --sort-by='.lastTimestamp' 2>/dev/null | \
        grep -iE "failedmount|failedattachvolume|volumebindingfailed" | tail -10 || \
        echo -e "${GREEN}No storage-related events found${NC}"
    echo ""
fi

#############################################################################
# SUMMARY
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary ===${NC}\n"

#############################################################################
# SUMMARY
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary ===${NC}\n"

if [ -n "$PVC_OUTPUT" ]; then
    PVC_COUNT=$(echo "$PVC_OUTPUT" | grep -v "^NAMESPACE\|^NAME" | wc -l | tr -d ' ')
    echo -e "${GREEN}✓ Found $PVC_COUNT PVC(s)${NC}"
fi

PRESSURE_COUNT=$(echo "$NODE_CONDITIONS" | awk '{if ($2 == "True") print $1}' | wc -l | tr -d ' ')
if [ "$PRESSURE_COUNT" -gt 0 ]; then
    echo -e "${RED}✗ $PRESSURE_COUNT node(s) under disk pressure${NC}"
else
    echo -e "${GREEN}✓ No nodes under disk pressure${NC}"
fi

PENDING_COUNT=$(echo "$PENDING_PODS" | wc -l | tr -d ' ')
if [ "$PENDING_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ $PENDING_COUNT pending pod(s) - check logs above${NC}"
else
    echo -e "${GREEN}✓ No pending pods${NC}"
fi

# Check for high disk usage warnings
if [ ${#HIGH_USAGE_PODS[@]} -gt 0 ]; then
    echo -e "${RED}${BOLD}✗ CRITICAL: ${#HIGH_USAGE_PODS[@]} pod(s) with disk usage ≥80%${NC}"
    for i in "${!HIGH_USAGE_PODS[@]}"; do
        echo -e "${RED}  - ${HIGH_USAGE_PODS[$i]}: ${HIGH_USAGE_PERCENTAGES[$i]}% used${NC}"
    done
    echo ""
    echo -e "${YELLOW}${BOLD}⚠ WARNING: High disk usage detected!${NC}"
    echo -e "${YELLOW}  Elasticsearch and other applications may refuse to allocate resources${NC}"
    echo -e "${YELLOW}  when disk usage exceeds 85% (low watermark threshold).${NC}"
    echo -e "${YELLOW}  Recommended actions:${NC}"
    echo -e "${YELLOW}    1. Delete old/unused indices or data${NC}"
    echo -e "${YELLOW}    2. Increase PVC size (if storage class supports expansion)${NC}"
    echo -e "${YELLOW}    3. Review retention policies and cleanup schedules${NC}"
else
    echo -e "${GREEN}✓ All pods have healthy disk usage (<80%)${NC}"
fi

echo ""
echo -e "${BOLD}${CYAN}Tip:${NC} To diagnose specific pod disk usage, run:"
echo -e "${CYAN}  $0 -p $PROJECT -c $CLUSTER $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION") -n <namespace> -d <pod-name>${NC}"
echo ""
