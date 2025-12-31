#!/usr/bin/env bash

# Script: gcloud-view-logs.sh
# Description: View and filter logs from Google Cloud Logging using gcloud CLI
# Author: Generated for GCP log monitoring
# Usage: ./gcloud-view-logs.sh -p PROJECT [OPTIONS]

set -euo pipefail

# Default values
PROJECT_NAME=""
PHRASE=""
SEVERITY=""
FIELD=""
LIMIT=50
FORMAT="json"
FRESHNESS="24h"
ORDER="desc"
VERBOSE=false
AUTO_LOGIN=false
RESOURCE_TYPE=""
LOG_NAME=""

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

View and filter logs from Google Cloud Logging.

OPTIONS:
    -p, --project PROJECT       GCP project name (required)
    -s, --severity SEVERITY     Filter by log severity (TRACE|DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY)
    -P, --phrase PHRASE        Search phrase to filter logs
    -f, --field FIELD          Custom field to search (used with --phrase)
    -l, --limit LIMIT          Maximum number of log entries to return (default: 50)
    -F, --format FORMAT        Output format: json|text|csv|tabular (default: json)
                               tabular shows timestamp, severity, resource.type, logName, and extracted message
    -t, --freshness TIME       Only return logs newer than duration (e.g., 1h, 30m, 7d) (default: 24h)
    -o, --order ORDER          Sort order: asc|desc (default: desc)
    -r, --resource TYPE        Filter by resource type (e.g., gce_instance, k8s_container, cloud_function)
    -L, --log-name NAME        Filter by specific log name (e.g., syslog, stdout)
    -a, --auto-login           Automatically run gcloud auth login if needed
    -v, --verbose              Verbose output
    -h, --help                 Show this help message

SEVERITY LEVELS:
    TRACE, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY
    
    Note: Severity levels are ordered. Filtering by ERROR will include ERROR, CRITICAL, ALERT, and EMERGENCY.

EXAMPLES:
    # View all logs from the last 24 hours
    $(basename "$0") -p my-project

    # Filter by severity
    $(basename "$0") -p my-project -s ERROR

    # Filter by severity and phrase
    $(basename "$0") -p my-project -s ERROR -P "database connection"

    # Search for a phrase in logs
    $(basename "$0") -p my-project -P "timeout"

    # Search in a specific field
    $(basename "$0") -p my-project -f jsonPayload.message -P "failed"

    # Filter by resource type
    $(basename "$0") -p my-project -r k8s_container -s WARNING

    # Get last 100 logs in text format
    $(basename "$0") -p my-project -l 100 -F text

    # View logs from the last hour
    $(basename "$0") -p my-project -t 1h -s INFO

    # Filter by log name
    $(basename "$0") -p my-project -L syslog -s ERROR

    # Display results in tabular format with extracted messages
    $(basename "$0") -p my-project -s ERROR -F tabular

    # Tabular output with phrase filter
    $(basename "$0") -p my-project -P "timeout" -F tabular

DESCRIPTION:
    This script provides an easy interface to Google Cloud Logging, allowing you to
    filter logs by severity, search phrases, custom fields, resource types, and more.
    
    The script builds and executes gcloud logging read commands based on your parameters,
    supporting multiple filtering options that can be combined for precise log queries.

COMMON RESOURCE TYPES:
    - gce_instance: Compute Engine VM instances
    - k8s_cluster: GKE clusters
    - k8s_node: GKE nodes
    - k8s_pod: GKE pods
    - k8s_container: GKE containers
    - cloud_function: Cloud Functions
    - cloud_run_revision: Cloud Run revisions
    - gae_app: App Engine applications

PREREQUISITES:
    - gcloud CLI installed and configured
    - Appropriate GCP permissions (logging.logEntries.list)
    - Authenticated gcloud account

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

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

# Function to check gcloud authentication
check_gcloud_auth() {
    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
    
    if [ -z "$active_account" ]; then
        warn "Not authenticated with gcloud"
        if [ "$AUTO_LOGIN" = true ]; then
            log "Attempting to authenticate..."
            gcloud auth login || error "Authentication failed"
        else
            error "Please run 'gcloud auth login' or use --auto-login (-a)"
        fi
    else
        log "Authenticated as: $active_account"
    fi
}

# Function to validate severity level
validate_severity() {
    local sev="$1"
    case "$sev" in
        TRACE|DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY)
            return 0
            ;;
        *)
            error "Invalid severity level: $sev. Must be one of: TRACE, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY"
            ;;
    esac
}

# Function to validate format
validate_format() {
    local fmt="$1"
    case "$fmt" in
        json|text|csv|tabular)
            return 0
            ;;
        *)
            error "Invalid format: $fmt. Must be one of: json, text, csv, tabular"
            ;;
    esac
}

# Function to validate order
validate_order() {
    local ord="$1"
    case "$ord" in
        asc|desc)
            return 0
            ;;
        *)
            error "Invalid order: $ord. Must be either 'asc' or 'desc'"
            ;;
    esac
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -s|--severity)
            SEVERITY="$2"
            shift 2
            ;;
        -P|--phrase)
            PHRASE="$2"
            shift 2
            ;;
        -f|--field)
            FIELD="$2"
            shift 2
            ;;
        -l|--limit)
            LIMIT="$2"
            shift 2
            ;;
        -F|--format)
            FORMAT="$2"
            shift 2
            ;;
        -t|--freshness)
            FRESHNESS="$2"
            shift 2
            ;;
        -o|--order)
            ORDER="$2"
            shift 2
            ;;
        -r|--resource)
            RESOURCE_TYPE="$2"
            shift 2
            ;;
        -L|--log-name)
            LOG_NAME="$2"
            shift 2
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
            error "Unknown option: $1. Use -h or --help for usage information."
            ;;
    esac
done

# Validate required parameters
if [ -z "$PROJECT_NAME" ]; then
    error "Project name is required. Use -p or --project to specify."
fi

# Check authentication
check_gcloud_auth

# Validate optional parameters
if [ -n "$SEVERITY" ]; then
    validate_severity "$SEVERITY"
fi

validate_format "$FORMAT"
validate_order "$ORDER"

# Validate that if field is specified, phrase must also be specified
if [ -n "$FIELD" ] && [ -z "$PHRASE" ]; then
    error "Field filter (-f/--field) requires a phrase (-P/--phrase) to search for."
fi

# Build the filter expression
build_filter() {
    local filters=()
    
    # Add severity filter
    if [ -n "$SEVERITY" ]; then
        filters+=("severity>=$SEVERITY")
    fi
    
    # Add phrase filter
    if [ -n "$PHRASE" ]; then
        if [ -n "$FIELD" ]; then
            # Search in specific field
            filters+=("${FIELD}:\"${PHRASE}\"")
        else
            # General text search
            filters+=("\"${PHRASE}\"")
        fi
    fi
    
    # Add resource type filter
    if [ -n "$RESOURCE_TYPE" ]; then
        filters+=("resource.type=\"${RESOURCE_TYPE}\"")
    fi
    
    # Add log name filter
    if [ -n "$LOG_NAME" ]; then
        filters+=("logName=~\"${LOG_NAME}\"")
    fi
    
    # Combine filters with AND
    if [ ${#filters[@]} -gt 0 ]; then
        local filter_string=$(IFS=" AND "; echo "${filters[*]}")
        echo "$filter_string"
    else
        echo ""
    fi
}

# Build and execute the gcloud command
execute_logging_command() {
    local filter
    filter=$(build_filter)
    
    local cmd=(
        "gcloud" "logging" "read"
    )
    
    # Add filter if we have one
    if [ -n "$filter" ]; then
        cmd+=("$filter")
    fi
    
    # Add project
    cmd+=("--project=$PROJECT_NAME")
    
    # Add limit
    cmd+=("--limit=$LIMIT")
    
    # Add format
    if [ "$FORMAT" = "tabular" ]; then
        # Use table format with predefined fields for tabular output
        # Use resource.type:label=RESOURCE_TYPE to give it a column header without period
        cmd+=("--format=table(timestamp,severity,resource.type:label=RESOURCE_TYPE,logName,textPayload)")
    else
        cmd+=("--format=$FORMAT")
    fi
    
    # Add freshness
    cmd+=("--freshness=$FRESHNESS")
    
    # Add order
    cmd+=("--order=$ORDER")
    
    # Log the command if verbose
    if [ "$VERBOSE" = true ]; then
        log "Executing command:"
        echo -e "${CYAN}${cmd[*]}${NC}" >&2
        echo "" >&2
    fi
    
    # Execute the command
    if [ "$FORMAT" = "tabular" ]; then
        # First get the data in CSV format for easier parsing
        local csv_cmd=("${cmd[@]}")
        # Replace the table format with CSV
        for i in "${!csv_cmd[@]}"; do
            if [[ "${csv_cmd[$i]}" == --format=table* ]]; then
                csv_cmd[$i]="--format=csv(timestamp,severity,resource.type,logName,textPayload)"
                break
            fi
        done
        
        # Execute and display with tty-table
        if ! "${csv_cmd[@]}" | \
            if command -v tty-table >/dev/null 2>&1; then
                # Create a temporary style file for tty-table
                local style_file=$(mktemp)
                echo 'module.exports=[{align:"left"},{align:"left", "white-space": "nowrap"},{align:"left", "white-space": "nowrap"},{align:"left", width: 70},{align:"left", width: 140}]' > "$style_file"
                tty-table --header "$style_file"
                rm -f "$style_file"
            else
                # Fallback to column if tty-table is not available
                if command -v column >/dev/null 2>&1; then
                    column -t -s,
                else
                    # Just output the CSV
                    cat
                fi
            fi; then
            error "Failed to retrieve logs. Check your parameters and permissions."
        fi
    else
        if ! "${cmd[@]}"; then
            error "Failed to retrieve logs. Check your parameters and permissions."
        fi
    fi
}

# Main execution
main() {
    log "Project: $PROJECT_NAME"
    [ -n "$SEVERITY" ] && log "Severity: >=$SEVERITY"
    [ -n "$PHRASE" ] && log "Phrase: $PHRASE"
    [ -n "$FIELD" ] && log "Field: $FIELD"
    [ -n "$RESOURCE_TYPE" ] && log "Resource Type: $RESOURCE_TYPE"
    [ -n "$LOG_NAME" ] && log "Log Name: $LOG_NAME"
    log "Limit: $LIMIT"
    log "Format: $FORMAT"
    log "Freshness: $FRESHNESS"
    log "Order: $ORDER"
    log ""
    
    execute_logging_command
}

# Run main
main
