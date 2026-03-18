#!/usr/bin/env zsh

################################################################################
# GCP Project Storage Diagnostics Script
################################################################################
# This script diagnoses storage limitations and usage at the GCP project level.
# It checks quotas, disk usage, persistent disks, snapshots, images, and buckets.
#
# Usage: ./gcp-diagnose-storage.sh -p <project> [OPTIONS]
################################################################################

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
REGION=""
ZONE=""
VERBOSE=false
QUIET=false
AUTO_LOGIN=false
CHECK_BUCKETS=true
CHECK_DISKS=true
CHECK_SNAPSHOTS=true
CHECK_IMAGES=true
CHECK_QUOTAS=true
SHOW_RECOMMENDATIONS=true

# Usage function
usage() {
    cat << EOF
${BOLD}GCP Project Storage Diagnostics${NC}

Usage: $0 [OPTIONS]

${BOLD}Required Parameters:${NC}
    -p, --project <project>     GCP project ID

${BOLD}Optional Parameters:${NC}
    -r, --region <region>       Focus on specific region (default: all regions)
    -z, --zone <zone>           Focus on specific zone (default: all zones in region)
    -v, --verbose               Verbose output with detailed information
    -q, --quiet                 Quiet mode (minimal output, errors only)
    -l, --auto-login            Auto-login to gcloud if not authenticated

${BOLD}Diagnostic Filters:${NC}
    --no-buckets                Skip Cloud Storage buckets analysis
    --no-disks                  Skip Persistent Disks analysis
    --no-snapshots              Skip disk snapshots analysis
    --no-images                 Skip custom images analysis
    --no-quotas                 Skip quota checks
    --no-recommendations        Skip recommendations output

    --only-buckets              Check only Cloud Storage buckets
    --only-disks                Check only Persistent Disks
    --only-snapshots            Check only disk snapshots
    --only-images               Check only custom images
    --only-quotas               Check only quotas

${BOLD}Examples:${NC}
    $0 -p my-project
    $0 -p my-project -r us-east4 --verbose
    $0 -p my-project --only-disks
    $0 -p my-project -z us-east4-a --no-recommendations
    $0 -p my-project --only-quotas -r us-central1

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
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -z|--zone)
            ZONE="$2"
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
        --no-buckets)
            CHECK_BUCKETS=false
            shift
            ;;
        --no-disks)
            CHECK_DISKS=false
            shift
            ;;
        --no-snapshots)
            CHECK_SNAPSHOTS=false
            shift
            ;;
        --no-images)
            CHECK_IMAGES=false
            shift
            ;;
        --no-quotas)
            CHECK_QUOTAS=false
            shift
            ;;
        --no-recommendations)
            SHOW_RECOMMENDATIONS=false
            shift
            ;;
        --only-buckets)
            CHECK_DISKS=false
            CHECK_SNAPSHOTS=false
            CHECK_IMAGES=false
            CHECK_QUOTAS=false
            shift
            ;;
        --only-disks)
            CHECK_BUCKETS=false
            CHECK_SNAPSHOTS=false
            CHECK_IMAGES=false
            CHECK_QUOTAS=false
            shift
            ;;
        --only-snapshots)
            CHECK_BUCKETS=false
            CHECK_DISKS=false
            CHECK_IMAGES=false
            CHECK_QUOTAS=false
            shift
            ;;
        --only-images)
            CHECK_BUCKETS=false
            CHECK_DISKS=false
            CHECK_SNAPSHOTS=false
            CHECK_QUOTAS=false
            shift
            ;;
        --only-quotas)
            CHECK_BUCKETS=false
            CHECK_DISKS=false
            CHECK_SNAPSHOTS=false
            CHECK_IMAGES=false
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
if [ -z "$PROJECT" ]; then
    echo -e "${RED}Error: Project ID is required${NC}"
    usage
fi

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    echo "Please install it from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

################################################################################
# Helper Functions
################################################################################

print_header() {
    if [ "$QUIET" = false ]; then
        echo -e "\n${BOLD}${CYAN}========================================${NC}"
        echo -e "${BOLD}${CYAN}$1${NC}"
        echo -e "${BOLD}${CYAN}========================================${NC}"
    fi
}

print_section() {
    if [ "$QUIET" = false ]; then
        echo -e "\n${BOLD}${BLUE}>>> $1${NC}"
    fi
}

print_info() {
    if [ "$QUIET" = false ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    
    awk -v bytes="$bytes" 'BEGIN {
        units[0] = "B"
        units[1] = "KB"
        units[2] = "MB"
        units[3] = "GB"
        units[4] = "TB"
        units[5] = "PB"
        
        unit = 0
        size = bytes
        
        while (size >= 1024 && unit < 5) {
            size = size / 1024
            unit++
        }
        
        printf "%.2f %s\n", size, units[unit]
    }'
}

# Calculate percentage
calc_percentage() {
    local used=$1
    local total=$2
    
    if [ "$total" = "0" ] || [ -z "$total" ]; then
        echo "0"
        return
    fi
    
    awk -v used="$used" -v total="$total" 'BEGIN {
        printf "%.1f", (used / total) * 100
    }'
}

# Estimate monthly storage cost based on size and storage class
estimate_monthly_cost() {
    local size_bytes=$1
    local storage_class=$2
    
    # GCS pricing per GB per month (approximate US multi-region/regional rates)
    local price_per_gb=0
    case "$storage_class" in
        STANDARD)
            price_per_gb=0.020  # $0.020/GB/month (regional) or $0.026 (multi-region)
            ;;
        NEARLINE)
            price_per_gb=0.010  # $0.010/GB/month
            ;;
        COLDLINE)
            price_per_gb=0.004  # $0.004/GB/month
            ;;
        ARCHIVE)
            price_per_gb=0.0012 # $0.0012/GB/month
            ;;
        *)
            price_per_gb=0.020  # Default to STANDARD
            ;;
    esac
    
    local size_gb=$(awk -v bytes="$size_bytes" 'BEGIN {printf "%.2f", bytes / 1073741824}')
    local monthly_cost=$(awk -v size="$size_gb" -v price="$price_per_gb" 'BEGIN {printf "%.2f", size * price}')
    
    echo "$monthly_cost"
}

################################################################################
# Authentication and Setup
################################################################################

check_gcloud_auth() {
    print_verbose "Checking gcloud authentication..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
        print_warn "Not authenticated with gcloud"
        if [ "$AUTO_LOGIN" = true ]; then
            print_info "Attempting to authenticate..."
            gcloud auth login
        else
            print_error "Please run: gcloud auth login"
            exit 1
        fi
    fi
    
    local account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    print_verbose "Authenticated as: $account"
}

set_project() {
    print_verbose "Setting project to: $PROJECT"
    if ! gcloud config set project "$PROJECT" &> /dev/null; then
        print_error "Failed to set project: $PROJECT"
        exit 1
    fi
    
    # Verify project exists and we have access
    if ! gcloud projects describe "$PROJECT" &> /dev/null; then
        print_error "Cannot access project: $PROJECT (project may not exist or you lack permissions)"
        exit 1
    fi
    
    print_verbose "Project set successfully"
}

################################################################################
# Storage Quota Analysis
################################################################################

check_storage_quotas() {
    if [ "$CHECK_QUOTAS" = false ]; then
        return
    fi
    
    print_header "Storage Quotas Analysis"
    
    # Determine regions to check
    local regions_to_check=()
    if [ -n "$REGION" ]; then
        regions_to_check=("$REGION")
    else
        print_verbose "Fetching available regions..."
        # Get regions where we have compute resources
        mapfile -t regions_to_check < <(gcloud compute regions list --format="value(name)" 2>/dev/null | head -10)
    fi
    
    for region in "${regions_to_check[@]}"; do
        print_section "Region: $region"
        
        # Check compute disk quotas
        print_info "Checking disk quotas for $region..."
        
        # SSD Persistent Disk
        local ssd_quota=$(gcloud compute regions describe "$region" --format="value(quotas.filter(metric:SSD_TOTAL_GB).limit)" 2>/dev/null)
        local ssd_usage=$(gcloud compute regions describe "$region" --format="value(quotas.filter(metric:SSD_TOTAL_GB).usage)" 2>/dev/null)
        
        if [ -n "$ssd_quota" ] && [ "$ssd_quota" != "0" ]; then
            local ssd_pct=$(calc_percentage "$ssd_usage" "$ssd_quota")
            echo -e "  SSD Persistent Disk:  ${ssd_usage} / ${ssd_quota} GB (${ssd_pct}%)"
            
            if [ "$(echo "$ssd_pct > 80" | bc -l)" -eq 1 ]; then
                print_warn "SSD Persistent Disk quota is over 80% in $region"
            fi
        fi
        
        # Standard Persistent Disk
        local std_quota=$(gcloud compute regions describe "$region" --format="value(quotas.filter(metric:DISKS_TOTAL_GB).limit)" 2>/dev/null)
        local std_usage=$(gcloud compute regions describe "$region" --format="value(quotas.filter(metric:DISKS_TOTAL_GB).usage)" 2>/dev/null)
        
        if [ -n "$std_quota" ] && [ "$std_quota" != "0" ]; then
            local std_pct=$(calc_percentage "$std_usage" "$std_quota")
            echo -e "  Standard Disk:        ${std_usage} / ${std_quota} GB (${std_pct}%)"
            
            if [ "$(echo "$std_pct > 80" | bc -l)" -eq 1 ]; then
                print_warn "Standard Persistent Disk quota is over 80% in $region"
            fi
        fi
        
        # Snapshots quota
        local snap_quota=$(gcloud compute project-info describe --format="value(quotas.filter(metric:SNAPSHOTS).limit)" 2>/dev/null)
        local snap_usage=$(gcloud compute project-info describe --format="value(quotas.filter(metric:SNAPSHOTS).usage)" 2>/dev/null)
        
        if [ -n "$snap_quota" ] && [ "$snap_quota" != "0" ]; then
            local snap_pct=$(calc_percentage "$snap_usage" "$snap_quota")
            echo -e "  Snapshots (project):  ${snap_usage} / ${snap_quota} (${snap_pct}%)"
            
            if [ "$(echo "$snap_pct > 80" | bc -l)" -eq 1 ]; then
                print_warn "Snapshot quota is over 80%"
            fi
        fi
    done
}

################################################################################
# Persistent Disks Analysis
################################################################################

check_persistent_disks() {
    if [ "$CHECK_DISKS" = false ]; then
        return
    fi
    
    print_header "Persistent Disks Analysis"
    
    local zone_filter=""
    if [ -n "$ZONE" ]; then
        zone_filter="--filter=zone:$ZONE"
    elif [ -n "$REGION" ]; then
        zone_filter="--filter=zone~$REGION"
    fi
    
    print_verbose "Fetching persistent disks..."
    local disks=$(gcloud compute disks list $zone_filter --format="json" 2>/dev/null)
    
    if [ -z "$disks" ] || [ "$disks" = "[]" ]; then
        print_info "No persistent disks found"
        return
    fi
    
    # Summary statistics
    local total_disks=$(echo "$disks" | jq '. | length')
    local total_size_gb=$(echo "$disks" | jq '[.[].sizeGb | tonumber] | add')
    local attached_count=$(echo "$disks" | jq '[.[] | select(.users != null)] | length')
    local unattached_count=$((total_disks - attached_count))
    
    print_section "Summary"
    echo -e "  Total Disks:          $total_disks"
    echo -e "  Total Size:           ${total_size_gb} GB"
    echo -e "  Attached:             $attached_count"
    echo -e "  Unattached:           $unattached_count"
    
    if [ $unattached_count -gt 0 ]; then
        print_warn "Found $unattached_count unattached disk(s) - consider deletion to save costs"
    fi
    
    # Breakdown by type
    print_section "Breakdown by Disk Type"
    echo "$disks" | jq -r 'group_by(.type | split("/")[-1]) | .[] | "\(.[] | select(. != null) | .type | split("/")[-1]): \(length) disks, \([.[] | .sizeGb | tonumber] | add) GB"' | while read line; do
        echo -e "  $line"
    done
    
    # Largest disks
    print_section "Top 10 Largest Disks"
    echo "$disks" | jq -r 'sort_by(.sizeGb | tonumber) | reverse | .[0:10] | .[] | "  \(.name) - \(.sizeGb)GB (\(.type | split("/")[-1])) - Zone: \(.zone | split("/")[-1])"'
    
    # Unattached disks detail
    if [ $unattached_count -gt 0 ] && [ "$VERBOSE" = true ]; then
        print_section "Unattached Disks (Consider Cleanup)"
        echo "$disks" | jq -r '.[] | select(.users == null) | "  \(.name) - \(.sizeGb)GB in \(.zone | split("/")[-1]) (created: \(.creationTimestamp | split("T")[0]))"'
    fi
}

################################################################################
# Snapshots Analysis
################################################################################

check_snapshots() {
    if [ "$CHECK_SNAPSHOTS" = false ]; then
        return
    fi
    
    print_header "Disk Snapshots Analysis"
    
    print_verbose "Fetching snapshots..."
    local snapshots=$(gcloud compute snapshots list --format="json" 2>/dev/null)
    
    if [ -z "$snapshots" ] || [ "$snapshots" = "[]" ]; then
        print_info "No snapshots found"
        return
    fi
    
    # Summary statistics
    local total_snapshots=$(echo "$snapshots" | jq '. | length')
    local total_size_gb=$(echo "$snapshots" | jq '[.[].storageBytes | tonumber] | add' 2>/dev/null)
    
    if [ -z "$total_size_gb" ]; then
        total_size_gb=0
    fi
    
    local total_size_readable=$(format_bytes "$total_size_gb")
    
    print_section "Summary"
    echo -e "  Total Snapshots:      $total_snapshots"
    echo -e "  Total Storage:        $total_size_readable"
    
    # Breakdown by source disk
    print_section "Snapshots by Source Disk"
    echo "$snapshots" | jq -r 'group_by(.sourceDisk | split("/")[-1]) | .[] | "  \(.[] | .sourceDisk | split("/")[-1]): \(length) snapshot(s)"' | head -20
    
    # Oldest snapshots
    print_section "Top 10 Oldest Snapshots"
    echo "$snapshots" | jq -r 'sort_by(.creationTimestamp) | .[0:10] | .[] | "  \(.name) - \(.creationTimestamp | split("T")[0]) (Source: \(.sourceDisk | split("/")[-1]))"'
    
    # Largest snapshots
    print_section "Top 10 Largest Snapshots"
    echo "$snapshots" | jq -r 'sort_by(.storageBytes | tonumber) | reverse | .[0:10] | .[] | "  \(.name) - \(.storageBytes | tonumber) bytes (Source: \(.sourceDisk | split("/")[-1]))"'
    
    # Check for old snapshots
    local old_count=$(echo "$snapshots" | jq '[.[] | select(.creationTimestamp | fromdateiso8601 < (now - 31536000))] | length')
    if [ "$old_count" -gt 0 ]; then
        print_warn "Found $old_count snapshot(s) older than 1 year - consider cleanup"
    fi
}

################################################################################
# Custom Images Analysis
################################################################################

check_images() {
    if [ "$CHECK_IMAGES" = false ]; then
        return
    fi
    
    print_header "Custom Images Analysis"
    
    print_verbose "Fetching custom images..."
    local images=$(gcloud compute images list --no-standard-images --format="json" 2>/dev/null)
    
    if [ -z "$images" ] || [ "$images" = "[]" ]; then
        print_info "No custom images found"
        return
    fi
    
    # Summary statistics
    local total_images=$(echo "$images" | jq '. | length')
    local total_size_gb=$(echo "$images" | jq '[.[].diskSizeGb | tonumber] | add' 2>/dev/null)
    
    if [ -z "$total_size_gb" ]; then
        total_size_gb=0
    fi
    
    print_section "Summary"
    echo -e "  Total Custom Images:  $total_images"
    echo -e "  Total Disk Size:      ${total_size_gb} GB"
    
    # List images
    print_section "Custom Images"
    echo "$images" | jq -r '.[] | "  \(.name) - \(.diskSizeGb)GB (created: \(.creationTimestamp | split("T")[0]))"'
    
    # Check for deprecated images
    local deprecated_count=$(echo "$images" | jq '[.[] | select(.deprecated != null)] | length')
    if [ "$deprecated_count" -gt 0 ]; then
        print_warn "Found $deprecated_count deprecated image(s)"
        if [ "$VERBOSE" = true ]; then
            echo "$images" | jq -r '.[] | select(.deprecated != null) | "    \(.name)"'
        fi
    fi
}

################################################################################
# Cloud Storage Buckets Analysis
################################################################################

check_storage_buckets() {
    if [ "$CHECK_BUCKETS" = false ]; then
        return
    fi
    
    print_header "Cloud Storage Buckets Analysis"
    
    print_verbose "Fetching storage buckets..."
    local buckets=$(gsutil ls -p "$PROJECT" 2>/dev/null)
    
    if [ -z "$buckets" ]; then
        print_info "No storage buckets found or unable to list buckets"
        print_verbose "Attempted command: gsutil ls -p $PROJECT"
        return
    fi
    
    local bucket_count=$(echo "$buckets" | wc -l | tr -d ' ')
    print_section "Summary"
    echo -e "  Total Buckets:        $bucket_count"
    
    print_verbose "Bucket list:"
    if [ "$VERBOSE" = true ]; then
        echo "$buckets" | while read line; do
            print_verbose "  - $line"
        done
    fi
    
    # First pass: find the maximum bucket size
    print_verbose "Finding largest bucket for visualization..."
    local max_size=0
    
    while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        bucket=${bucket%/}
        local du_output=$(gsutil du -s "$bucket" 2>/dev/null)
        local size_bytes=$(echo "$du_output" | awk '{print $1}')
        
        if [ -n "$size_bytes" ]; then
            # Try numeric comparison, use 0 if it fails
            if [ "$size_bytes" -gt "$max_size" ] 2>/dev/null; then
                max_size=$size_bytes
            fi
        fi
    done <<< "$buckets"
    
    print_verbose "Maximum bucket size: $(format_bytes $max_size)"
    
    # Second pass: display each bucket with visualization
    print_section "Bucket Details (size relative to largest)"
    
    local total_size=0
    local total_objects=0
    local total_cost=0
    local bucket_counter=0
    
    # Track storage class distribution
    local standard_count=0
    local nearline_count=0
    local coldline_count=0
    local archive_count=0
    
    while IFS= read -r bucket; do
        [ -z "$bucket" ] && continue
        bucket_counter=$((bucket_counter + 1))
        # Remove trailing slash
        bucket=${bucket%/}
        local bucket_name=$(basename "$bucket")
        
        print_verbose "[$bucket_counter/$bucket_count] Analyzing bucket: $bucket_name"
        
        # Get bucket size
        local du_output=$(gsutil du -s "$bucket" 2>/dev/null)
        local size_bytes=$(echo "$du_output" | awk '{print $1}')
        
        # Default to 0 if empty/invalid
        [ -z "$size_bytes" ] && size_bytes=0
        
        local size_readable=$(format_bytes "$size_bytes")
        total_size=$((total_size + size_bytes))
        
        # Get object count (skip if verbose is off to speed up)
        local obj_count="N/A"
        if [ "$VERBOSE" = true ]; then
            obj_count=$(timeout 5 gsutil ls "$bucket/**" 2>/dev/null | wc -l | tr -d ' ')
            [ -z "$obj_count" ] && obj_count="N/A"
            [ "$obj_count" != "N/A" ] && total_objects=$((total_objects + obj_count))
        fi
        
        # Get bucket metadata (location and storage class)
        local bucket_info=$(gsutil ls -L -b "$bucket" 2>/dev/null)
        local location=$(echo "$bucket_info" | grep "Location constraint:" | awk '{print $3}')
        local storage_class=$(echo "$bucket_info" | grep "Default storage class:" | awk '{print $4}')
        local created=$(echo "$bucket_info" | grep "Time created:" | awk '{print $3}')
        
        # Default to STANDARD if not found
        [ -z "$storage_class" ] && storage_class="STANDARD"
        [ -z "$location" ] && location="N/A"
        
        # Track storage class distribution
        case "$storage_class" in
            STANDARD) standard_count=$((standard_count + 1)) ;;
            NEARLINE) nearline_count=$((nearline_count + 1)) ;;
            COLDLINE) coldline_count=$((coldline_count + 1)) ;;
            ARCHIVE) archive_count=$((archive_count + 1)) ;;
        esac
        
        # Calculate estimated monthly cost
        local monthly_cost=$(estimate_monthly_cost "$size_bytes" "$storage_class")
        total_cost=$(awk -v total="$total_cost" -v cost="$monthly_cost" 'BEGIN {printf "%.2f", total + cost}')
        
        # Check for old objects (sample first 100 objects for performance)
        local old_objects="N/A"
        if [ "$VERBOSE" = true ] && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            local one_year_ago=$(date -u -v-1y "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '1 year ago' "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
            if [ -n "$one_year_ago" ]; then
                old_objects=$(timeout 10 gsutil ls -l "$bucket/**" 2>/dev/null | head -100 | awk -v cutoff="$one_year_ago" '$2 < cutoff {count++} END {print count+0}')
            fi
        fi
        
        # Add location type indicator
        if [[ "$location" =~ ^(US|EU|ASIA)$ ]]; then
            location="$location (multi-region)"
        elif [ "$location" != "N/A" ]; then
            location="$location (regional)"
        fi
        
        # Create visual size indicator (20 blocks total)
        local bar_length=20
        local used_blocks=0
        if [ "$max_size" -gt 0 ] 2>/dev/null && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            used_blocks=$(awk -v size="$size_bytes" -v max="$max_size" -v len="$bar_length" 'BEGIN {printf "%.0f", (size/max)*len}')
        fi
        local free_blocks=$((bar_length - used_blocks))
        
        # Build the visual bar with colors using the color variables defined at top
        local red_portion=""
        # Dark red blocks for used space
        for ((i=0; i<used_blocks; i++)); do
            red_portion="${red_portion}█"
        done
        red_portion="${RED}${red_portion}${NC}"
        
        # Green blocks for remaining space relative to largest bucket
        local green_portion=""
        for ((i=0; i<free_blocks; i++)); do
            green_portion="${green_portion}█"
        done
        green_portion="${GREEN}${green_portion}${NC}"
        
        # Calculate percentage of largest
        local pct_of_largest="0.0"
        if [ "$max_size" -gt 0 ] 2>/dev/null && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            pct_of_largest=$(calc_percentage "$size_bytes" "$max_size")
        fi
        
        echo -e "  ${BOLD}$bucket_name${NC} ${red_portion}${green_portion} ${pct_of_largest}%"
        echo -e "    Size:               $size_readable"
        echo -e "    Est. Monthly Cost:  \$${monthly_cost}"
        echo -e "    Objects:            $obj_count"
        if [ "$old_objects" != "N/A" ] && [ "$old_objects" -gt 0 ] 2>/dev/null; then
            echo -e "    Old Objects (>1yr): ${YELLOW}$old_objects${NC} (sampled)"
        fi
        echo -e "    Location:           $location"
        echo -e "    Storage Class:      $storage_class"
        if [ -n "$created" ]; then
            echo -e "    Created:            $(echo $created | cut -d'T' -f1)"
        fi
    done <<< "$buckets"
    
    echo ""
    local total_size_readable=$(format_bytes "$total_size")
    print_info "Total Storage Used: $total_size_readable across $total_objects object(s)"
    print_info "Estimated Monthly Cost: \$$total_cost (storage only, excludes operations/egress)"
    
    # Storage class distribution
    if [ $bucket_count -gt 0 ]; then
        print_section "Storage Class Distribution"
        [ $standard_count -gt 0 ] && echo -e "  STANDARD:  $standard_count bucket(s)"
        [ $nearline_count -gt 0 ] && echo -e "  NEARLINE:  $nearline_count bucket(s)"
        [ $coldline_count -gt 0 ] && echo -e "  COLDLINE:  $coldline_count bucket(s)"
        [ $archive_count -gt 0 ] && echo -e "  ARCHIVE:   $archive_count bucket(s)"
        
        echo ""
        if [ $standard_count -eq $bucket_count ]; then
            print_info "All buckets use STANDARD storage. Consider NEARLINE/COLDLINE for infrequently accessed data."
        fi
    fi
}

################################################################################
# Recommendations
################################################################################

show_recommendations() {
    if [ "$SHOW_RECOMMENDATIONS" = false ]; then
        return
    fi
    
    print_header "Recommendations"
    
    echo -e "${YELLOW}Cost Optimization Tips:${NC}"
    echo -e "  1. Delete unattached persistent disks to avoid unnecessary charges"
    echo -e "  2. Review and delete old snapshots (older than retention policy)"
    echo -e "  3. Consider using Standard storage instead of SSD for non-performance-critical workloads"
    echo -e "  4. Enable lifecycle management on Cloud Storage buckets to auto-delete/archive old objects"
    echo -e "  5. Use committed use discounts for persistent disk resources"
    echo -e "  6. Delete unused custom images"
    echo -e "  7. Consider using Nearline or Coldline storage for infrequently accessed data"
    echo ""
    
    echo -e "${YELLOW}Quota Management:${NC}"
    echo -e "  • Request quota increases before reaching 80% usage"
    echo -e "  • Monitor quota usage regularly: https://console.cloud.google.com/iam-admin/quotas"
    echo -e "  • Set up quota alerts in Cloud Monitoring"
    echo ""
    
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo -e "  # Delete unattached disk:"
    echo -e "  ${CYAN}gcloud compute disks delete DISK_NAME --zone=ZONE${NC}"
    echo ""
    echo -e "  # Delete old snapshot:"
    echo -e "  ${CYAN}gcloud compute snapshots delete SNAPSHOT_NAME${NC}"
    echo ""
    echo -e "  # Delete unused custom image:"
    echo -e "  ${CYAN}gcloud compute images delete IMAGE_NAME${NC}"
    echo ""
    echo -e "  # Request quota increase:"
    echo -e "  ${CYAN}https://console.cloud.google.com/iam-admin/quotas${NC}"
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header "GCP Project Storage Diagnostics"
    echo -e "${BOLD}Project:${NC} $PROJECT"
    [ -n "$REGION" ] && echo -e "${BOLD}Region:${NC} $REGION"
    [ -n "$ZONE" ] && echo -e "${BOLD}Zone:${NC} $ZONE"
    echo ""
    
    # Setup
    check_gcloud_auth
    set_project
    
    # Run diagnostics
    check_storage_quotas
    check_persistent_disks
    check_snapshots
    check_images
    check_storage_buckets
    
    # Show recommendations
    show_recommendations
    
    print_header "Diagnostics Complete"
    print_info "Review warnings above for potential issues and optimization opportunities"
}

# Run main function
main
