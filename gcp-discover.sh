#!/bin/bash

# Script to discover and explore GCP projects, GKE clusters, Cloud Storage buckets, and other GCP resources
# Usage: ./gcp-discover.sh [OPTIONS]

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
CACHE_DIR="${HOME}/.cache/gcp-discover"
CACHE_TTL=3600  # Cache Time To Live in seconds (1 hour)

# Parse command line arguments
SHOW_PROJECTS=false
SHOW_CLUSTERS=false
SHOW_NAMESPACES=false
SHOW_SERVICES=false
SHOW_PODS=false
SHOW_BUCKETS=false
SHOW_IAM=false
SHOW_ALL=false
PROJECT=""
CLUSTER=""
NAMESPACE=""
BUCKET=""
IAM_ROLE_FILTER=""
IAM_MEMBER_FILTER=""
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
        --buckets)
            SHOW_BUCKETS=true
            shift
            ;;
        --iam)
            SHOW_IAM=true
            shift
            ;;
        --role)
            IAM_ROLE_FILTER="$2"
            shift 2
            ;;
        --member)
            IAM_MEMBER_FILTER="$2"
            shift 2
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
        --bucket|-b)
            BUCKET="$2"
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
            echo "  --buckets               List all Cloud Storage buckets (requires --project)"
            echo "  --iam                   Show IAM policy bindings (requires --project)"
            echo "  --all                   Show everything (interactive discovery)"
            echo "  --interactive, -i       Interactive mode - walk through discovery step by step"
            echo ""
            echo "Options:"
            echo "  --project, -p PROJECT   Specify GCP project"
            echo "  --cluster, -c CLUSTER   Specify GKE cluster"
            echo "  --namespace, -n NS      Specify Kubernetes namespace"
            echo "  --bucket, -b BUCKET     Specify Cloud Storage bucket"
            echo "  --role ROLE             Filter IAM results by role (substring match)"
            echo "  --member MEMBER         Filter IAM results by member (substring match)"
            echo "  --no-cache              Skip cache and fetch fresh data"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --projects                           # List all projects"
            echo "  $0 --clusters --project my-project      # List clusters in a project"
            echo "  $0 --buckets --project my-project       # List buckets in a project"
            echo "  $0 --iam --project my-project           # Show IAM bindings for a project"
            echo "  $0 --iam --project my-project --role editor   # Show IAM bindings filtered by role"
            echo "  $0 --iam --project my-project --member user@  # Show IAM bindings filtered by member"
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

# Function to list buckets in a project
list_buckets() {
    local proj="${1:-$PROJECT}"
    
    if [[ -z "$proj" ]]; then
        echo -e "${RED}Error: Project not specified${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${BLUE}=== Cloud Storage Buckets in Project: $proj ===${NC}\n"
    
    local cache_file="$CACHE_DIR/buckets-${proj}.cache"
    local list_cache="$CACHE_DIR/buckets-${proj}-list.cache"
    
    if is_cache_valid "$cache_file" && [[ -f "$list_cache" ]]; then
        echo -e "${CYAN}(Using cached data)${NC}\n"
        cat "$cache_file"
    else
        echo -e "${YELLOW}Fetching buckets...${NC}\n"
        
        local buckets=$(gsutil ls -p "$proj" 2>/dev/null)
        
        if [[ -z "$buckets" ]]; then
            echo -e "${YELLOW}No buckets found in project $proj${NC}"
            return 0
        fi
        
        # Format bucket output
        echo -e "${BOLD}BUCKET_NAME${NC}"
        echo "$buckets" | sed 's|gs://||' | sed 's|/$||' | tee "$cache_file" > /dev/null
        
        # Save bucket names to array cache
        echo "$buckets" | sed 's|gs://||' | sed 's|/$||' > "$list_cache"
    fi
    
    # Display numbered list
    BUCKET_LIST=()
    while IFS= read -r bucket; do
        BUCKET_LIST+=("$bucket")
    done < "$list_cache"
    
    if [[ ${#BUCKET_LIST[@]} -gt 0 ]]; then
        echo -e "\n${BOLD}${BLUE}Bucket Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        local i=1
        for bucket in "${BUCKET_LIST[@]}"; do
            echo -e "${CYAN}[$i]${NC} $bucket"
            ((i++))
        done
        
        local count=${#BUCKET_LIST[@]}
        echo -e "\n${GREEN}Total: $count bucket(s)${NC}"
    fi
}

# Function to list IAM policy bindings for a project
list_iam_policy() {
    local proj="${1:-$PROJECT}"
    local role_filter="${2:-$IAM_ROLE_FILTER}"
    local member_filter="${3:-$IAM_MEMBER_FILTER}"
    
    if [[ -z "$proj" ]]; then
        echo -e "${RED}Error: Project not specified${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${BLUE}=== IAM Policy Bindings for Project: $proj ===${NC}\n"
    
    if [[ -n "$role_filter" ]]; then
        echo -e "${CYAN}Filtering by role: ${role_filter}${NC}"
    fi
    if [[ -n "$member_filter" ]]; then
        echo -e "${CYAN}Filtering by member: ${member_filter}${NC}"
    fi
    
    local cache_file="$CACHE_DIR/iam-${proj}.cache"
    local iam_json=""
    
    if is_cache_valid "$cache_file"; then
        echo -e "${CYAN}(Using cached data)${NC}\n"
        iam_json=$(cat "$cache_file")
    else
        echo -e "${YELLOW}Fetching IAM policy...${NC}\n"
        
        iam_json=$(gcloud projects get-iam-policy "$proj" --format=json 2>/dev/null)
        
        if [[ -z "$iam_json" ]] || [[ "$iam_json" == "{}" ]]; then
            echo -e "${RED}No IAM policy found or unable to retrieve IAM policy for project $proj${NC}"
            echo -e "${YELLOW}You may need the resourcemanager.projects.getIamPolicy permission.${NC}"
            return 1
        fi
        
        echo "$iam_json" > "$cache_file"
    fi
    
    # Parse and display bindings
    local bindings=$(echo "$iam_json" | jq -r '.bindings[]? | .role as $role | .members[]? | "\($role)\t\(.)"' 2>/dev/null)
    
    if [[ -z "$bindings" ]]; then
        echo -e "${YELLOW}No IAM bindings found${NC}"
        return 0
    fi
    
    # Apply filters
    local filtered="$bindings"
    if [[ -n "$role_filter" ]]; then
        filtered=$(echo "$filtered" | grep -i "$role_filter" || true)
    fi
    if [[ -n "$member_filter" ]]; then
        filtered=$(echo "$filtered" | grep -i "$member_filter" || true)
    fi
    
    if [[ -z "$filtered" ]]; then
        echo -e "${YELLOW}No bindings match the specified filter(s)${NC}"
        return 0
    fi
    
    # Group output by role
    echo -e "${BOLD}ROLE                                                      MEMBER${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local current_role=""
    echo "$filtered" | sort | while IFS=$'\t' read -r role member; do
        # Color-code by member type
        local member_display=""
        case "$member" in
            user:*)
                member_display="${GREEN}${member}${NC}"
                ;;
            serviceAccount:*)
                member_display="${CYAN}${member}${NC}"
                ;;
            group:*)
                member_display="${MAGENTA}${member}${NC}"
                ;;
            domain:*)
                member_display="${YELLOW}${member}${NC}"
                ;;
            *)
                member_display="${member}"
                ;;
        esac
        
        if [[ "$role" != "$current_role" ]]; then
            current_role="$role"
            echo -e "\n${BOLD}${BLUE}${role}${NC}"
            echo -e "  ${member_display}"
        else
            echo -e "  ${member_display}"
        fi
    done
    
    # Summary statistics
    echo ""
    echo -e "${BOLD}${BLUE}IAM Summary\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
    
    local total_bindings=$(echo "$filtered" | wc -l | tr -d ' ')
    local unique_roles=$(echo "$filtered" | awk -F'\t' '{print $1}' | sort -u | wc -l | tr -d ' ')
    local unique_members=$(echo "$filtered" | awk -F'\t' '{print $2}' | sort -u | wc -l | tr -d ' ')
    local user_count=$(echo "$filtered" | awk -F'\t' '{print $2}' | grep -c "^user:" || true)
    local sa_count=$(echo "$filtered" | awk -F'\t' '{print $2}' | grep -c "^serviceAccount:" || true)
    local group_count=$(echo "$filtered" | awk -F'\t' '{print $2}' | grep -c "^group:" || true)
    local domain_count=$(echo "$filtered" | awk -F'\t' '{print $2}' | grep -c "^domain:" || true)
    
    echo -e "  ${BOLD}Total bindings:${NC}         $total_bindings"
    echo -e "  ${BOLD}Unique roles:${NC}           $unique_roles"
    echo -e "  ${BOLD}Unique members:${NC}         $unique_members"
    echo -e "  ${GREEN}Users:${NC}                  $user_count"
    echo -e "  ${CYAN}Service accounts:${NC}       $sa_count"
    echo -e "  ${MAGENTA}Groups:${NC}                 $group_count"
    if [[ "$domain_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}Domains:${NC}                $domain_count"
    fi
    
    # List unique members
    echo ""
    echo -e "${BOLD}${BLUE}Unique Members\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
    echo "$filtered" | awk -F'\t' '{print $2}' | sort -u | while read -r member; do
        local role_count=$(echo "$filtered" | awk -F'\t' -v m="$member" '$2 == m {print $1}' | wc -l | tr -d ' ')
        case "$member" in
            user:*)
                echo -e "  ${GREEN}${member}${NC} (${role_count} role(s))"
                ;;
            serviceAccount:*)
                echo -e "  ${CYAN}${member}${NC} (${role_count} role(s))"
                ;;
            group:*)
                echo -e "  ${MAGENTA}${member}${NC} (${role_count} role(s))"
                ;;
            domain:*)
                echo -e "  ${YELLOW}${member}${NC} (${role_count} role(s))"
                ;;
            *)
                echo -e "  ${member} (${role_count} role(s))"
                ;;
        esac
    done
}

# Function to list contents of a bucket or path
list_bucket_contents() {
    local bucket="$1"
    local path="${2:-}"
    
    if [[ -z "$bucket" ]]; then
        echo -e "${RED}Error: Bucket not specified${NC}"
        return 1
    fi
    
    local full_path="gs://${bucket}"
    if [[ -n "$path" ]]; then
        # Remove any leading slashes from path
        path="${path#/}"
        full_path="${full_path}/${path}"
    fi
    
    # Ensure path ends with / for directory listing
    if [[ ! "$full_path" =~ /$ ]]; then
        full_path="${full_path}/"
    fi
    
    echo -e "${BOLD}${BLUE}=== Contents of ${full_path} ===${NC}\n"
    
    echo -e "${YELLOW}Fetching contents...${NC}\n"
    
    # Use gsutil ls -l to get sizes in one call
    local contents=$(gsutil ls -l "$full_path" 2>&1)
    local ls_exit=$?
    
    if [[ $ls_exit -ne 0 ]]; then
        echo -e "${RED}Error accessing bucket path${NC}"
        echo "$contents" | head -3
        return 1
    fi
    
    if [[ -z "$contents" ]]; then
        echo -e "${YELLOW}No contents found in this location${NC}"
        return 0
    fi
    
    # Parse and display the output
    BUCKET_ITEM_LIST=()
    BUCKET_ITEM_TYPE_LIST=()
    
    echo -e "${BOLD}TYPE    SIZE            NAME${NC}"
    echo "--------------------------------------------"
    
    # Process each line from gsutil ls -l
    # Format: SIZE DATE TIME gs://path or just gs://path/ for dirs
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # Skip TOTAL line
        [[ "$line" =~ ^TOTAL: ]] && continue
        
        # Extract the path (last field with gs://)
        local item_path=$(echo "$line" | grep -o 'gs://[^ ]*' | tail -1)
        [[ -z "$item_path" ]] && continue
        
        # Check if it's a directory (ends with /)
        if [[ "$item_path" =~ /$ ]]; then
            local dir_path=$(echo "$item_path" | sed 's|gs://||' | sed 's|/$||')
            local dir_name=$(basename "$dir_path")
            echo -e "${CYAN}DIR${NC}     ${YELLOW}-${NC}               ${dir_name}/"
            BUCKET_ITEM_LIST+=("$dir_path")
            BUCKET_ITEM_TYPE_LIST+=("dir")
        else
            # It's a file - extract size (first number on line)
            local file_name=$(echo "$item_path" | sed 's|gs://||')
            local display_name=$(basename "$file_name")
            
            # Get size from beginning of line
            local size=$(echo "$line" | awk '{print $1}')
            
            if [[ "$size" =~ ^[0-9]+$ ]]; then
                local formatted_size=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B")
            else
                local formatted_size="-"
            fi
            
            echo -e "${GREEN}FILE${NC}    ${formatted_size}    ${display_name}"
            BUCKET_ITEM_LIST+=("$file_name")
            BUCKET_ITEM_TYPE_LIST+=("file")
        fi
    done <<< "$contents"
    
    # Display numbered list for selection
    if [[ ${#BUCKET_ITEM_LIST[@]} -gt 0 ]]; then
        echo -e "\n${BOLD}${BLUE}Item Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        local i=1
        for idx in "${!BUCKET_ITEM_LIST[@]}"; do
            local item="${BUCKET_ITEM_LIST[$idx]}"
            local item_type="${BUCKET_ITEM_TYPE_LIST[$idx]}"
            local display_item=$(basename "$item")
            
            if [[ "$item_type" == "dir" ]]; then
                echo -e "${CYAN}[$i]${NC} ${YELLOW}[DIR]${NC}  $display_item/"
            else
                echo -e "${CYAN}[$i]${NC} ${GREEN}[FILE]${NC} $display_item"
            fi
            ((i++))
        done
    else
        echo -e "\n${YELLOW}No items found in this location${NC}"
    fi
}

# Function to inspect/display file contents
inspect_file() {
    local file_path="$1"
    local bucket="$2"
    
    if [[ -z "$file_path" ]]; then
        echo -e "${RED}Error: File path not specified${NC}"
        return 1
    fi
    
    # Construct full GCS path
    local full_path
    if [[ "$file_path" =~ ^gs:// ]]; then
        full_path="$file_path"
    else
        # file_path already contains bucket/path format
        full_path="gs://${file_path}"
    fi
    
    echo -e "${BOLD}${BLUE}=== Contents of ${full_path} ===${NC}\n"
    
    # Get file metadata
    echo -e "${YELLOW}File Metadata:${NC}"
    gsutil stat "$full_path" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Could not access file${NC}"
        return 1
    fi
    
    echo ""
    
    # Check file extension to determine how to display
    local ext="${file_path##*.}"
    
    case "$ext" in
        gz|zip|tar|bz2|xz|7z|rar|pdf|jpg|jpeg|png|gif|bmp|ico|exe|dll|so|dylib)
            echo -e "${YELLOW}Binary/compressed file - metadata only (no content preview)${NC}"
            ;;
        json)
            echo -e "${YELLOW}Fetching file contents... (press 'q' to exit viewer)${NC}"
            echo ""
            # Use less with color support for formatted JSON
            gsutil cat "$full_path" 2>/dev/null | jq -C '.' 2>/dev/null | less -R || gsutil cat "$full_path" 2>/dev/null | less
            ;;
        txt|log|yaml|yml|sh|py|js|java|go|rs|md|csv|xml|html|htm|css)
            echo -e "${YELLOW}Fetching file contents... (press 'q' to exit viewer)${NC}"
            echo ""
            gsutil cat "$full_path" 2>/dev/null | less
            ;;
        *)
            # Try to display as text
            local preview=$(gsutil cat "$full_path" 2>/dev/null | head -10)
            if echo "$preview" | grep -q '[^[:print:][:space:]]'; then
                echo -e "${YELLOW}Binary file detected - metadata only (no content preview)${NC}"
            else
                echo -e "${YELLOW}Fetching file contents... (press 'q' to exit viewer)${NC}"
                echo ""
                gsutil cat "$full_path" 2>/dev/null | less
            fi
            ;;
    esac
    
    echo ""
    return 0
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

# Function for bucket exploration mode
explore_bucket() {
    local proj="$1"
    
    # List buckets
    list_buckets "$proj"
    echo ""
    
    if [[ ${#BUCKET_LIST[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No buckets to explore${NC}"
        return 0
    fi
    
    read -p "Enter bucket number or name (or 'q' to quit): " selected_bucket
    
    if [[ "$selected_bucket" == "q" ]]; then
        return 0
    fi
    
    if [[ -z "$selected_bucket" ]]; then
        echo -e "${RED}No bucket selected${NC}"
        return 0
    fi
    
    # Check if input is a number
    local bucket_name=""
    if [[ "$selected_bucket" =~ ^[0-9]+$ ]]; then
        local idx=$((selected_bucket - 1))
        if [[ $idx -ge 0 && $idx -lt ${#BUCKET_LIST[@]} ]]; then
            bucket_name="${BUCKET_LIST[$idx]}"
            echo -e "${GREEN}Selected: $bucket_name${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi
    else
        bucket_name="$selected_bucket"
    fi
    echo ""
    
    # Navigate bucket contents
    local current_path=""
    while true; do
        list_bucket_contents "$bucket_name" "$current_path"
        echo ""
        
        echo -e "${BOLD}${BLUE}Bucket Navigation Options\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        echo "[#] Select item number to navigate into directory or view file"
        echo "[..] Go up one level"
        echo "[r] Return to bucket list"
        echo "[q] Quit"
        echo ""
        
        read -p "Enter choice: " choice
        echo ""
        
        case "$choice" in
            q|Q)
                return 0
                ;;
            r|R)
                break
                ;;
            ..)
                # Go up one directory level
                if [[ -n "$current_path" ]]; then
                    current_path=$(dirname "$current_path")
                    if [[ "$current_path" == "." ]]; then
                        current_path=""
                    fi
                fi
                ;;
            *)
                # Check if it's a number selection
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local idx=$((choice - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#BUCKET_ITEM_LIST[@]} ]]; then
                        local selected_item="${BUCKET_ITEM_LIST[$idx]}"
                        local selected_type="${BUCKET_ITEM_TYPE_LIST[$idx]}"
                        
                        if [[ "$selected_type" == "dir" ]]; then
                            # Navigate into directory
                            local dir_name=$(echo "$selected_item" | sed "s|^${bucket_name}/||")
                            current_path="$dir_name"
                        else
                            # Display file contents
                            inspect_file "$selected_item" "$bucket_name"
                            echo ""
                            read -p "Press Enter to continue..." dummy
                        fi
                    else
                        echo -e "${RED}Invalid selection${NC}"
                    fi
                else
                    echo -e "${RED}Invalid choice${NC}"
                fi
                ;;
        esac
    done
}

# Function for interactive mode
interactive_mode() {
    echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║        GCP Interactive Discovery Tool                     ║${NC}"
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
    
    # Step 2: Choose resource type to explore
    while true; do
        echo -e "${BOLD}${BLUE}Resource Type Selections\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        echo "[1] GKE Clusters & Kubernetes Resources"
        echo "[2] Cloud Storage Buckets"
        echo "[3] IAM Policy Bindings (who has access)"
        echo "[4] All (explore all resources)"
        echo "[q] Quit"
        echo ""
        read -p "Select resource type: " resource_choice
        echo ""
        
        case "$resource_choice" in
            1)
                # GKE exploration
                explore_gke_resources "$PROJECT"
                ;;
            2)
                # Bucket exploration
                explore_bucket "$PROJECT"
                ;;
            3)
                # IAM policy bindings
                list_iam_policy "$PROJECT"
                echo ""
                read -p "Filter by role (or press Enter to skip): " role_input
                if [[ -n "$role_input" ]]; then
                    echo ""
                    list_iam_policy "$PROJECT" "$role_input" ""
                fi
                echo ""
                read -p "Filter by member (or press Enter to skip): " member_input
                if [[ -n "$member_input" ]]; then
                    echo ""
                    list_iam_policy "$PROJECT" "" "$member_input"
                fi
                echo ""
                ;;
            4)
                # Explore all
                echo -e "${BOLD}${CYAN}=== Exploring all resources in project: $PROJECT ===${NC}\n"
                
                # Show buckets first
                echo -e "${BOLD}${BLUE}Cloud Storage Buckets:${NC}"
                list_buckets "$PROJECT"
                echo -e "\n"
                
                read -p "Do you want to explore a bucket? (y/n): " explore_choice
                if [[ "$explore_choice" =~ ^[Yy]$ ]]; then
                    explore_bucket "$PROJECT"
                fi
                echo ""
                
                # Then show GKE resources
                echo -e "${BOLD}${BLUE}GKE Clusters:${NC}"
                list_clusters "$PROJECT"
                echo -e "\n"
                
                read -p "Do you want to explore a cluster? (y/n): " explore_choice
                if [[ "$explore_choice" =~ ^[Yy]$ ]]; then
                    explore_gke_resources "$PROJECT"
                fi
                echo ""
                
                # Show IAM
                echo -e "${BOLD}${BLUE}IAM Policy Bindings:${NC}"
                list_iam_policy "$PROJECT"
                ;;
            q|Q)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid selection${NC}\n"
                ;;
        esac
    done
}

# Function to explore GKE resources (extracted from interactive_mode)
explore_gke_resources() {
    local proj="$1"
    
    # Select cluster
    list_clusters "$proj"
    echo ""
    read -p "Enter cluster number or name (or 'q' to quit): " selected_cluster
    
    if [[ "$selected_cluster" == "q" ]]; then
        return 0
    fi
    
    if [[ -z "$selected_cluster" ]]; then
        echo -e "${RED}No cluster selected${NC}"
        return 0
    fi
    
    # Check if input is a number
    if [[ "$selected_cluster" =~ ^[0-9]+$ ]]; then
        local idx=$((selected_cluster - 1))
        if [[ $idx -ge 0 && $idx -lt ${#CLUSTER_LIST[@]} ]]; then
            CLUSTER="${CLUSTER_LIST[$idx]}"
            echo -e "${GREEN}Selected: $CLUSTER${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi
    else
        CLUSTER="$selected_cluster"
    fi
    echo ""
    
    # Get cluster location
    local cluster_info=$(gcloud container clusters list --project="$proj" --filter="name=$CLUSTER" --format="value(location,locationType)" 2>/dev/null)
    local location=$(echo "$cluster_info" | awk '{print $1}')
    local location_type=$(echo "$cluster_info" | awk '{print $2}')
    
    if [[ -z "$location" ]]; then
        echo -e "${RED}Could not determine cluster location${NC}"
        return 1
    fi
    
    # Get credentials
    get_credentials "$proj" "$CLUSTER" "$location" "$location_type"
    echo ""
    
    # Step 3: Explore resources
    while true; do
        echo -e "${BOLD}${BLUE}Kubernetes Resource Exploration\n⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺${NC}"
        echo "[1] Namespaces"
        echo "[2] Services (all namespaces)"
        echo "[3] Services (specific namespace)"
        echo "[4] Pods (all namespaces)"
        echo "[5] Pods (specific namespace)"
        echo "[6] Generate command template"
        echo "[r] Return to resource type selection"
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
            r|R)
                return 0
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
    
    echo ""
    
    # Cloud Storage commands
    if [[ -n "$PROJECT" ]]; then
        echo -e "${BOLD}${BLUE}Cloud Storage Commands:${NC}"
        echo "gsutil ls -p $PROJECT                    # List all buckets"
        echo "gsutil ls -l gs://BUCKET_NAME/           # List bucket contents"
        echo "gsutil cat gs://BUCKET_NAME/FILE         # View file contents"
        echo "gsutil cp gs://BUCKET_NAME/FILE .        # Download file"
        echo "gsutil stat gs://BUCKET_NAME/FILE        # Get file metadata"
        echo "gsutil du -s gs://BUCKET_NAME/           # Get bucket size"
    else
        echo -e "${BOLD}${BLUE}Cloud Storage Commands:${NC}"
        echo "gsutil ls -p PROJECT_ID                  # List all buckets"
        echo "gsutil ls -l gs://BUCKET_NAME/           # List bucket contents"
        echo "gsutil cat gs://BUCKET_NAME/FILE         # View file contents"
        echo "gsutil cp gs://BUCKET_NAME/FILE .        # Download file"
        echo "gsutil stat gs://BUCKET_NAME/FILE        # Get file metadata"
        echo "gsutil du -s gs://BUCKET_NAME/           # Get bucket size"
    fi
}

# Main execution
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           GCP Resource Discovery Tool                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"

check_gcloud_auth

# Handle different modes
if [[ "$INTERACTIVE" == true ]] || [[ "$SHOW_ALL" == true && -z "$PROJECT" ]]; then
    interactive_mode
elif [[ "$SHOW_PROJECTS" == true ]]; then
    list_projects
elif [[ "$SHOW_BUCKETS" == true ]]; then
    list_buckets "$PROJECT"
elif [[ "$SHOW_IAM" == true ]]; then
    if [[ -z "$PROJECT" ]]; then
        echo -e "${RED}Error: --iam requires --project${NC}"
        exit 1
    fi
    list_iam_policy "$PROJECT" "$IAM_ROLE_FILTER" "$IAM_MEMBER_FILTER"
elif [[ "$SHOW_CLUSTERS" == true ]]; then
    list_clusters "$PROJECT"
elif [[ "$SHOW_ALL" == true ]] && [[ -n "$PROJECT" ]]; then
    # Show everything for a specific project
    echo -e "${BOLD}${CYAN}=== Cloud Storage Buckets ===${NC}"
    list_buckets "$PROJECT"
    echo -e "\n"
    
    echo -e "${BOLD}${CYAN}=== IAM Policy Bindings ===${NC}"
    list_iam_policy "$PROJECT"
    echo -e "\n"
    
    echo -e "${BOLD}${CYAN}=== GKE Clusters ===${NC}"
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
    echo "  $0 --buckets --project PROJECT    # List buckets in a project"
    echo "  $0 --iam --project PROJECT         # View IAM policy bindings"
    echo "  $0 --all --project PROJECT    # Discover everything in a project"
fi

echo ""
