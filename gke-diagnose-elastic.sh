#!/bin/bash

# Script to diagnose Elasticsearch issues in GKE clusters
# Usage: ./gke-diagnose-elastic.sh -p <project> -c <cluster> [-z <zone> | -r <region>] [-n <namespace>] [-v] [-q]

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
POD_NAME=""
SECRET_NAME=""
VERBOSE=false
QUIET=false
AUTO_LOGIN=false
ELASTIC_USER=""
ELASTIC_PASSWORD=""
CACHE_DIR="$HOME/.cache/gke-elastic"
CACHE_FILE="$CACHE_DIR/credentials.enc"
CACHE_EXPIRY_DAYS=30

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Required Parameters:
    -p, --project <project>     GCP project ID
    -c, --cluster <cluster>     GKE cluster name
    -z, --zone <zone>           GKE cluster zone (e.g., us-east4-a) - for zonal clusters
    -r, --region <region>       GKE cluster region (e.g., us-east4) - for regional clusters
    -n, --namespace <namespace> Kubernetes namespace containing Elasticsearch

Optional Parameters:
    -d, --pod <pod-name>        Specific Elasticsearch pod name (default: first master pod)
    -s, --secret <secret-name>  Kubernetes secret containing Elasticsearch credentials
    -v, --verbose               Verbose output (includes full log lines with all fields)
    -q, --quiet                 Quiet mode (minimal output)
    -l, --auto-login            Auto-login to gcloud if not authenticated
    -h, --help                  Show this help message

Note: Credentials will be prompted interactively if not found in cache or secrets.
      Credentials are cached (encrypted) for 30 days in ~/.cache/gke-elastic/

Examples:
    $0 -p my-project -c my-cluster -z us-east4-a -n elastic
    $0 --project my-project --cluster my-cluster --region us-east4 --namespace elastic
    $0 -p my-project -c my-cluster -z us-east4-a -n elastic -d elasticsearch-master-0
    $0 -p my-project -c my-cluster -z us-east4-a -n elastic --secret elasticsearch-master-credentials

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
        -s|--secret)
            SECRET_NAME="$2"
            shift 2
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
if [ -z "$PROJECT" ] || [ -z "$CLUSTER" ] || [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Error: Project, cluster, and namespace are required${NC}"
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

# Function to get cache key for this cluster
get_cache_key() {
    echo "${PROJECT}_${CLUSTER}_${NAMESPACE}"
}

# Function to check if cache entry is valid (not expired)
is_cache_valid() {
    local cache_entry="$1"
    local timestamp=$(echo "$cache_entry" | cut -d'|' -f4)
    
    if [ -z "$timestamp" ]; then
        return 1
    fi
    
    local current_time=$(date +%s)
    local cache_age_days=$(( (current_time - timestamp) / 86400 ))
    
    if [ $cache_age_days -lt $CACHE_EXPIRY_DAYS ]; then
        return 0
    else
        return 1
    fi
}

# Function to encrypt and cache credentials
cache_credentials() {
    local user="$1"
    local password="$2"
    local cache_key=$(get_cache_key)
    local timestamp=$(date +%s)
    
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
    
    # Create entry: cache_key|username|password|timestamp
    local entry="${cache_key}|${user}|${password}|${timestamp}"
    
    # Encrypt using openssl with a machine-specific key
    local machine_id=$(uname -n)_$(id -u)
    echo "$entry" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$machine_id" -out "${CACHE_FILE}.tmp" 2>/dev/null
    
    if [ -f "$CACHE_FILE" ]; then
        # Decrypt existing cache
        local existing=$(openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"$machine_id" -in "$CACHE_FILE" 2>/dev/null || echo "")
        
        # Remove old entry for this cache key and keep valid entries
        local new_cache=""
        while IFS='|' read -r key user pass ts; do
            if [ "$key" != "$cache_key" ]; then
                local test_entry="${key}|${user}|${pass}|${ts}"
                if is_cache_valid "$test_entry"; then
                    new_cache="${new_cache}${test_entry}\n"
                fi
            fi
        done <<< "$existing"
        
        # Add new entry
        new_cache="${new_cache}${entry}\n"
        
        # Encrypt and save
        echo -e "$new_cache" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$machine_id" -out "${CACHE_FILE}.tmp" 2>/dev/null
    fi
    
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null
    chmod 600 "$CACHE_FILE"
    
    [ "$VERBOSE" = true ] && echo -e "${GREEN}Credentials cached for ${CACHE_EXPIRY_DAYS} days${NC}"
}

# Function to retrieve credentials from cache
get_cached_credentials() {
    if [ ! -f "$CACHE_FILE" ]; then
        return 1
    fi
    
    local cache_key=$(get_cache_key)
    local machine_id=$(uname -n)_$(id -u)
    
    # Decrypt cache
    local cache_contents=$(openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"$machine_id" -in "$CACHE_FILE" 2>/dev/null || echo "")
    
    if [ -z "$cache_contents" ]; then
        return 1
    fi
    
    # Find matching entry
    while IFS='|' read -r key user pass ts; do
        if [ "$key" = "$cache_key" ]; then
            local entry="${key}|${user}|${pass}|${ts}"
            if is_cache_valid "$entry"; then
                ELASTIC_USER="$user"
                ELASTIC_PASSWORD="$pass"
                [ "$VERBOSE" = true ] && echo -e "${GREEN}Using cached credentials${NC}"
                return 0
            else
                [ "$VERBOSE" = true ] && echo -e "${YELLOW}Cached credentials expired${NC}"
                return 1
            fi
        fi
    done <<< "$cache_contents"
    
    return 1
}

# Function to get credentials from Kubernetes secret
get_credentials_from_secret() {
    local secret_name="$1"
    
    [ "$VERBOSE" = true ] && echo -e "${CYAN}Retrieving credentials from secret: $secret_name${NC}"
    
    local username=$(kubectl get secret $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)
    local password=$(kubectl get secret $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
    
    if [ -z "$password" ]; then
        # Try alternative keys
        password=$(kubectl get secret $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d 2>/dev/null)
    fi
    
    if [ -n "$password" ]; then
        ELASTIC_USER="${username:-elastic}"
        ELASTIC_PASSWORD="$password"
        [ "$VERBOSE" = true ] && echo -e "${GREEN}Retrieved credentials from secret${NC}"
        
        # Cache the credentials
        cache_credentials "$ELASTIC_USER" "$ELASTIC_PASSWORD"
        return 0
    fi
    
    return 1
}

# Function to try common secret names
try_common_secrets() {
    [ "$VERBOSE" = true ] && echo -e "${CYAN}Searching for credentials in common secret names...${NC}"
    
    for secret_name in "elasticsearch-master-credentials" "elasticsearch-credentials" "elastic-credentials" "elasticsearch-master-secret"; do
        if get_credentials_from_secret "$secret_name"; then
            return 0
        fi
    done
    
    # Try to find password in environment variables of Elasticsearch pods
    if [ -n "$POD_NAME" ]; then
        local env_pass=$(kubectl exec $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$POD_NAME" -- env 2>/dev/null | grep -i "ELASTIC_PASSWORD" | cut -d'=' -f2 | head -1)
        if [ -n "$env_pass" ]; then
            ELASTIC_USER="elastic"
            ELASTIC_PASSWORD="$env_pass"
            [ "$VERBOSE" = true ] && echo -e "${GREEN}Found credentials in pod environment${NC}"
            cache_credentials "$ELASTIC_USER" "$ELASTIC_PASSWORD"
            return 0
        fi
    fi
    
    return 1
}

# Function to prompt for credentials interactively
prompt_for_credentials() {
    echo -e "${CYAN}Elasticsearch credentials required${NC}"
    echo -e "${CYAN}Credentials will be encrypted and cached for ${CACHE_EXPIRY_DAYS} days${NC}\n"
    
    # Prompt for username
    read -p "Enter Elasticsearch username [elastic]: " ELASTIC_USER
    ELASTIC_USER="${ELASTIC_USER:-elastic}"
    
    # Prompt for password (masked)
    echo -n "Enter Elasticsearch password: "
    read -s ELASTIC_PASSWORD
    echo ""
    
    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo -e "${RED}Error: Password cannot be empty${NC}"
        return 1
    fi
    
    # Cache the credentials
    cache_credentials "$ELASTIC_USER" "$ELASTIC_PASSWORD"
    return 0
}

# Function to get Elasticsearch credentials
get_elastic_credentials() {
    # Try cache first
    if get_cached_credentials; then
        return 0
    fi
    
    # If secret name specified, try that
    if [ -n "$SECRET_NAME" ]; then
        if get_credentials_from_secret "$SECRET_NAME"; then
            return 0
        else
            echo -e "${RED}Error: Could not retrieve credentials from secret: $SECRET_NAME${NC}"
            return 1
        fi
    fi
    
    # Try common secret names
    if try_common_secrets; then
        return 0
    fi
    
    # Prompt for credentials
    if ! prompt_for_credentials; then
        echo -e "${RED}Error: Failed to obtain credentials${NC}"
        return 1
    fi
    
    return 0
}

# Function to find Elasticsearch master pod
find_elastic_pod() {
    if [ -n "$POD_NAME" ]; then
        # Verify pod exists
        if ! kubectl get pod $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$POD_NAME" &>/dev/null; then
            echo -e "${RED}Error: Pod $POD_NAME not found in namespace $NAMESPACE${NC}"
            exit 1
        fi
        return
    fi
    
    # Find first Elasticsearch master pod
    POD_NAME=$(kubectl get pods $KUBECTL_TLS_FLAG -n "$NAMESPACE" -l "app.kubernetes.io/component=master" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POD_NAME" ]; then
        # Try alternative label
        POD_NAME=$(kubectl get pods $KUBECTL_TLS_FLAG -n "$NAMESPACE" -l "component=elasticsearch" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    
    if [ -z "$POD_NAME" ]; then
        # Try pattern matching
        POD_NAME=$(kubectl get pods $KUBECTL_TLS_FLAG -n "$NAMESPACE" -o name 2>/dev/null | grep -i elasticsearch | grep -i master | head -1 | cut -d'/' -f2)
    fi
    
    if [ -z "$POD_NAME" ]; then
        echo -e "${RED}Error: Could not find Elasticsearch pod in namespace $NAMESPACE${NC}"
        echo -e "${YELLOW}Please specify pod name with --pod flag${NC}"
        exit 1
    fi
    
    [ "$VERBOSE" = true ] && echo -e "${GREEN}Using Elasticsearch pod: $POD_NAME${NC}"
}

# Function to execute Elasticsearch API call
es_api_call() {
    local endpoint="$1"
    local method="${2:-GET}"
    
    if [ -z "$ELASTIC_PASSWORD" ]; then
        kubectl exec $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$POD_NAME" -- curl -sk "https://localhost:9200${endpoint}" 2>/dev/null
    else
        kubectl exec $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$POD_NAME" -- curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "https://localhost:9200${endpoint}" 2>/dev/null
    fi
}

# Main execution
echo -e "${BOLD}${BLUE}=== GKE Elasticsearch Diagnostic Tool ===${NC}\n"

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
echo -e "${GREEN}Namespace: $NAMESPACE${NC}\n"

find_elastic_pod

# Get credentials
if ! get_elastic_credentials; then
    exit 1
fi

#############################################################################
# 1. CHECK POD STATUS
#############################################################################
echo -e "${BOLD}${MAGENTA}[1/8] Checking Elasticsearch pod status...${NC}\n"

PODS=$(kubectl get pods $KUBECTL_TLS_FLAG -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | test("elasticsearch")) | "\(.metadata.name) \(.status.phase) \(.status.containerStatuses[0].ready) \(.status.containerStatuses[0].restartCount)"' 2>/dev/null)

if [ -z "$PODS" ]; then
    echo -e "${RED}No Elasticsearch pods found${NC}\n"
else
    printf "%-50s %-15s %-10s %-10s\n" "POD NAME" "STATUS" "READY" "RESTARTS"
    printf "%-50s %-15s %-10s %-10s\n" "--------------------------------------------------" "---------------" "----------" "----------"
    
    UNHEALTHY_COUNT=0
    while read -r pod phase ready restarts; do
        if [ "$phase" != "Running" ] || [ "$ready" != "true" ]; then
            echo -e "${RED}$(printf "%-50s %-15s %-10s %-10s" "$pod" "$phase" "$ready" "$restarts")${NC}"
            UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
        else
            echo -e "${GREEN}$(printf "%-50s %-15s %-10s %-10s" "$pod" "$phase" "$ready" "$restarts")${NC}"
        fi
    done <<< "$PODS"
    echo ""
    
    if [ $UNHEALTHY_COUNT -gt 0 ]; then
        echo -e "${YELLOW}⚠️ $UNHEALTHY_COUNT pod(s) not in healthy state${NC}\n"
    fi
fi

#############################################################################
# 2. CHECK CLUSTER HEALTH
#############################################################################
echo -e "${BOLD}${MAGENTA}[2/8] Checking Elasticsearch cluster health...${NC}\n"

HEALTH_OUTPUT=$(es_api_call "/_cluster/health?pretty" 2>/dev/null)

if [ -z "$HEALTH_OUTPUT" ] || echo "$HEALTH_OUTPUT" | grep -q "Empty reply"; then
    echo -e "${RED}✗ Unable to connect to Elasticsearch API${NC}"
    echo -e "${YELLOW}  Possible causes:${NC}"
    echo -e "${YELLOW}    - Elasticsearch is not running${NC}"
    echo -e "${YELLOW}    - Authentication credentials are incorrect${NC}"
    echo -e "${YELLOW}    - SSL/TLS configuration issue${NC}\n"
else
    echo "$HEALTH_OUTPUT"
    
    CLUSTER_STATUS=$(echo "$HEALTH_OUTPUT" | jq -r '.status' 2>/dev/null)
    case "$CLUSTER_STATUS" in
        "green")
            echo -e "\n${GREEN}✅ Cluster status: GREEN (healthy)${NC}\n"
            ;;
        "yellow")
            echo -e "\n${YELLOW}⚠️ Cluster status: YELLOW (degraded)${NC}"
            UNASSIGNED=$(echo "$HEALTH_OUTPUT" | jq -r '.unassigned_shards' 2>/dev/null)
            echo -e "${YELLOW}  Unassigned shards: $UNASSIGNED${NC}\n"
            ;;
        "red")
            echo -e "\n${RED}✗ Cluster status: RED (critical)${NC}"
            UNASSIGNED=$(echo "$HEALTH_OUTPUT" | jq -r '.unassigned_shards' 2>/dev/null)
            echo -e "${RED}  Unassigned shards: $UNASSIGNED${NC}\n"
            ;;
        *)
            echo -e "\n${YELLOW}⚠️ Unknown cluster status${NC}\n"
            ;;
    esac
fi

#############################################################################
# 3. CHECK NODE INFORMATION
#############################################################################
echo -e "${BOLD}${MAGENTA}[3/8] Checking Elasticsearch nodes...${NC}\n"

NODES_OUTPUT=$(es_api_call "/_cat/nodes?v&h=name,heap.percent,ram.percent,cpu,load_1m,disk.used_percent,disk.avail,node.role" 2>/dev/null)

if [ -n "$NODES_OUTPUT" ] && ! echo "$NODES_OUTPUT" | grep -q "Empty reply"; then
    echo "$NODES_OUTPUT"
    echo ""
    
    # Check for high resource usage
    HIGH_HEAP=$(echo "$NODES_OUTPUT" | awk 'NR>1 && $2+0 >= 85 {print $1": "$2"%"}')
    HIGH_DISK=$(echo "$NODES_OUTPUT" | awk 'NR>1 && $6+0 >= 80 {print $1": "$6"%"}')
    
    if [ -n "$HIGH_HEAP" ]; then
        echo -e "${RED}⚠️ High heap usage detected:${NC}"
        echo "$HIGH_HEAP" | while read -r line; do
            echo -e "${RED}  $line${NC}"
        done
        echo ""
    fi
    
    if [ -n "$HIGH_DISK" ]; then
        echo -e "${RED}⚠️ High disk usage detected (≥80%):${NC}"
        echo "$HIGH_DISK" | while read -r line; do
            echo -e "${RED}  $line${NC}"
        done
        echo ""
    fi
else
    echo -e "${YELLOW}Unable to retrieve node information${NC}\n"
fi

#############################################################################
# 4. CHECK SHARD ALLOCATION
#############################################################################
echo -e "${BOLD}${MAGENTA}[4/8] Checking shard allocation...${NC}\n"

if [ "$CLUSTER_STATUS" = "yellow" ] || [ "$CLUSTER_STATUS" = "red" ]; then
    ALLOCATION=$(es_api_call "/_cluster/allocation/explain?pretty" 2>/dev/null)
    
    if [ -n "$ALLOCATION" ] && ! echo "$ALLOCATION" | grep -q "Empty reply"; then
        echo "$ALLOCATION" | jq -r '.allocate_explanation, .node_allocation_decisions[0].deciders[] | select(.decision=="NO") | "  Reason: " + .decider + " - " + .explanation' 2>/dev/null || echo "$ALLOCATION"
        echo ""
    else
        echo -e "${YELLOW}Unable to retrieve allocation explanation${NC}\n"
    fi
else
    echo -e "${GREEN}✅ All shards allocated (cluster is green)${NC}\n"
fi

#############################################################################
# 5. CHECK INDICES
#############################################################################
echo -e "${BOLD}${MAGENTA}[5/8] Checking indices (top 10 by size)...${NC}\n"

INDICES=$(es_api_call "/_cat/indices?v&h=index,health,status,pri,rep,docs.count,store.size&s=store.size:desc" 2>/dev/null | head -11)

if [ -n "$INDICES" ] && ! echo "$INDICES" | grep -q "Empty reply"; then
    echo "$INDICES"
    echo ""
else
    echo -e "${YELLOW}Unable to retrieve index information${NC}\n"
fi

#############################################################################
# 6. CHECK CLUSTER SETTINGS
#############################################################################
echo -e "${BOLD}${MAGENTA}[6/8] Checking critical cluster settings...${NC}\n"

SETTINGS=$(es_api_call "/_cluster/settings?flat_settings=true&include_defaults=true" 2>/dev/null)

if [ -n "$SETTINGS" ] && ! echo "$SETTINGS" | grep -q "Empty reply"; then
    echo "Disk Watermark Settings:"
    echo "$SETTINGS" | jq -r '.defaults["cluster.routing.allocation.disk.watermark.low"] // .persistent["cluster.routing.allocation.disk.watermark.low"] // .transient["cluster.routing.allocation.disk.watermark.low"] // "85%"' 2>/dev/null | sed 's/^/  Low: /'
    echo "$SETTINGS" | jq -r '.defaults["cluster.routing.allocation.disk.watermark.high"] // .persistent["cluster.routing.allocation.disk.watermark.high"] // .transient["cluster.routing.allocation.disk.watermark.high"] // "90%"' 2>/dev/null | sed 's/^/  High: /'
    echo "$SETTINGS" | jq -r '.defaults["cluster.routing.allocation.disk.watermark.flood_stage"] // .persistent["cluster.routing.allocation.disk.watermark.flood_stage"] // .transient["cluster.routing.allocation.disk.watermark.flood_stage"] // "95%"' 2>/dev/null | sed 's/^/  Flood Stage: /'
    echo ""
else
    echo -e "${YELLOW}Unable to retrieve cluster settings${NC}\n"
fi

#############################################################################
# 7. CHECK POD LOGS FOR ERRORS
#############################################################################
echo -e "${BOLD}${MAGENTA}[7/8] Checking recent pod logs for errors...${NC}\n"

RECENT_ERRORS=$(kubectl logs $KUBECTL_TLS_FLAG -n "$NAMESPACE" "$POD_NAME" --tail=100 2>/dev/null | \
    grep -iE "error|exception|failed|fatal" | tail -10)

if [ -n "$RECENT_ERRORS" ]; then
    echo -e "${YELLOW}Recent errors found in $POD_NAME:${NC}"
    
    if [ "$VERBOSE" = true ]; then
        # Show full log lines in verbose mode
        echo "$RECENT_ERRORS"
    else
        # Parse and show only timestamp and message by default
        echo "$RECENT_ERRORS" | while IFS= read -r line; do
            # Try to parse as JSON first (Elasticsearch 8.x default format)
            if echo "$line" | jq -e . >/dev/null 2>&1; then
                TIMESTAMP=$(echo "$line" | jq -r '.["@timestamp"] // ."timestamp" // empty' 2>/dev/null)
                MESSAGE=$(echo "$line" | jq -r '.message // empty' 2>/dev/null)
                if [ -n "$TIMESTAMP" ] && [ -n "$MESSAGE" ]; then
                    echo "  [$TIMESTAMP] $MESSAGE"
                else
                    # Fallback if fields not found
                    echo "  $line"
                fi
            else
                # Not JSON - try to extract timestamp pattern and rest of line
                if [[ "$line" =~ ^(\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}[^\]]*\]?) ]]; then
                    TIMESTAMP="${BASH_REMATCH[1]}"
                    MESSAGE="${line#*$TIMESTAMP}"
                    echo "  $TIMESTAMP$MESSAGE"
                else
                    # No recognizable timestamp, show as-is
                    echo "  $line"
                fi
            fi
        done
    fi
    echo ""
else
    echo -e "${GREEN}✅ No recent errors in logs${NC}\n"
fi

#############################################################################
# 8. SUMMARY AND RECOMMENDATIONS
#############################################################################
echo -e "${BOLD}${BLUE}=== Summary and Recommendations ===${NC}\n"

# Cluster health summary
case "$CLUSTER_STATUS" in
    "green")
        echo -e "${GREEN}✅ Cluster health: GREEN${NC}"
        ;;
    "yellow")
        echo -e "${YELLOW}⚠️ Cluster health: YELLOW - Some replica shards are unassigned${NC}"
        ;;
    "red")
        echo -e "${RED}✗ Cluster health: RED - Primary shards are unassigned${NC}"
        ;;
esac

# Pod health summary
if [ $UNHEALTHY_COUNT -gt 0 ]; then
    echo -e "${RED}✗ $UNHEALTHY_COUNT unhealthy pod(s)${NC}"
else
    echo -e "${GREEN}✅ All Elasticsearch pods are healthy${NC}"
fi

# Recommendations
echo ""
echo -e "${BOLD}${CYAN}Recommendations:${NC}"

if [ -n "$HIGH_DISK" ]; then
    echo -e "${YELLOW}1. Disk Space Issues:${NC}"
    echo -e "   - Delete old or unnecessary indices"
    echo -e "   - Increase PVC size for Elasticsearch pods"
    echo -e "   - Review index retention policies"
    echo -e "   - Consider using ILM (Index Lifecycle Management)"
    echo ""
fi

if [ "$CLUSTER_STATUS" = "yellow" ] || [ "$CLUSTER_STATUS" = "red" ]; then
    echo -e "${YELLOW}2. Shard Allocation Issues:${NC}"
    echo -e "   - Check disk space on all nodes (must be below 85% watermark)"
    echo -e "   - Verify node count matches replica settings"
    echo -e "   - Review allocation filters and shard allocation settings"
    echo -e "   - Check for sufficient resources (CPU, memory)"
    echo ""
fi

if [ $UNHEALTHY_COUNT -gt 0 ]; then
    echo -e "${YELLOW}3. Pod Health Issues:${NC}"
    echo -e "   - Check pod logs: kubectl logs -n $NAMESPACE <pod-name>"
    echo -e "   - Describe pod for events: kubectl describe pod -n $NAMESPACE <pod-name>"
    echo -e "   - Verify resource requests and limits"
    echo -e "   - Check for probe failures with: ./gke-diagnose-probes.sh"
    echo ""
fi

echo -e "${BOLD}${CYAN}Related Commands:${NC}"
echo -e "  # View detailed storage diagnosis"
echo -e "  ./gke-diagnose-storage.sh -p $PROJECT -c $CLUSTER $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION") -n $NAMESPACE"
echo ""
echo -e "  # Check for pod restart issues"
echo -e "  ./gke-restart-status.sh -p $PROJECT -c $CLUSTER $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION") -n $NAMESPACE"
echo ""
echo -e "  # View real-time logs"
echo -e "  ./gke-view-logs.sh -p $PROJECT -c $CLUSTER $([ -n "$ZONE" ] && echo "-z $ZONE" || echo "-r $REGION") -n $NAMESPACE"
echo ""
