#!/bin/bash

# GKE Certificate Check Script
# Enhanced with getopts and cross-platform support (macOS/Linux)

# Default values
PROJECT_NAME=""
GKE_CLUSTER_NAME=""
CLUSTER_ZONE=""
NAMESPACE="default"
SECRET_NAME=""
VERBOSE=false
QUIET=false
AUTO_LOGIN=false
FORMAT="human"
SKIP_CERT_CHECK=false
VERIFY=false

# Detect operating system
detect_os() {
    case "$(uname -s)" in
        Darwin*)    OS="macos" ;;
        Linux*)     OS="linux" ;;
        *)          OS="unknown" ;;
    esac
}

# Color and formatting functions
setup_colors() {
    # Check if we're outputting to a terminal and colors are supported
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        BLUE=$(tput setaf 4)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    else
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        BOLD=""
        RESET=""
    fi
}

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Check SSL certificates stored in Google Kubernetes Engine (GKE) secrets.

OPTIONS:
    -p, --project PROJECT       GCP project name (required)
    -c, --cluster CLUSTER       GKE cluster name (required)
    -z, --zone ZONE            Cluster zone (required)
    -n, --namespace NAMESPACE   Kubernetes namespace (default: default)
    -s, --secret SECRET        Specific secret name to check (optional)
    -f, --format FORMAT        Output format: human|json|list (default: human)
    -a, --auto-login           Automatically run gcloud auth login
    -k, --skip-cert-check      Skip cluster certificate verification check
    -V, --verify               Perform additional certificate verification checks
    -v, --verbose              Verbose output
    -q, --quiet                Quiet mode (only show errors)
    -h, --help                 Show this help message

EXAMPLES:
    $(basename "$0") --project my-project --cluster prod-cluster --zone us-central1-a
    $(basename "$0") -p my-project -c dev-cluster -z us-west1-b -n istio-system
    $(basename "$0") -p my-project -c prod-cluster -z us-east1-c -s my-tls-secret -v
    $(basename "$0") --project my-project --cluster test --zone us-central1-a --auto-login

DESCRIPTION:
    This script connects to a GKE cluster and checks TLS certificates stored in
    Kubernetes secrets. It can list all secrets in a namespace or check a specific
    secret, displaying certificate information including expiration dates.

PREREQUISITES:
    - gcloud CLI installed and configured
    - kubectl installed
    - Appropriate GCP and Kubernetes permissions

EOF
}

# Error function
error() {
    echo "${RED}Error: $1${RESET}" >&2
    exit 1
}

# Log function for verbose output
log() {
    if [ "$VERBOSE" = true ] && [ "$QUIET" = false ]; then
        echo "${BLUE}[INFO]${RESET} $1" >&2
    fi
}

# Success message
success() {
    if [[ "$QUIET" != "true" ]]; then
        echo "${GREEN}✅${RESET} $1"
    fi
}

# Warning message
warning() {
    if [[ "$QUIET" != "true" ]]; then
        echo "${YELLOW}⚠️${RESET} $1"
    fi
}

# Parse date based on OS
parse_date() {
    local date_str="$1"
    detect_os
    
    case "$OS" in
        macos)
            date -j -f "%b %d %T %Y %Z" "$date_str" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null ||
            date -j -f "%b %d %H:%M:%S %Y %Z" "$date_str" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null
            ;;
        linux)
            date -d "$date_str" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null
            ;;
        *)
            echo "$date_str"
            ;;
    esac
}

# Format date for display
format_display_date() {
    local date_str="$1"
    detect_os
    
    case "$OS" in
        macos)
            date -j -f "%b %d %T %Y %Z" "$date_str" "+%B %d, %Y" 2>/dev/null ||
            date -j -f "%b %d %H:%M:%S %Y %Z" "$date_str" "+%B %d, %Y" 2>/dev/null ||
            echo "$date_str"
            ;;
        linux)
            date -d "$date_str" "+%B %d, %Y" 2>/dev/null || echo "$date_str"
            ;;
        *)
            echo "$date_str"
            ;;
    esac
}

# Verify private key matches certificate
verify_key_match() {
    local secret_name="$1"
    local namespace="$2"
    
    log "Checking if private key matches certificate..."
    
    # Get the private key
    local key_data
    key_data=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.tls\.key}' 2>/dev/null)
    
    if [ -z "$key_data" ]; then
        log "No tls.key found in secret"
        return 1
    fi
    
    # Get certificate modulus
    local cert_modulus
    cert_modulus=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -modulus 2>/dev/null | openssl md5)
    
    # Get key modulus
    local key_modulus
    key_modulus=$(echo "$key_data" | base64 -d | openssl rsa -noout -modulus 2>/dev/null | openssl md5)
    
    if [ "$cert_modulus" = "$key_modulus" ]; then
        echo "${RED}${RESET} Private key matches certificate"
        return 0
    else
        echo "${GREEN}✅${RESET} Private key does NOT match certificate"
        return 1
    fi
}

# Check if certificate is self-signed
check_self_signed() {
    local cert_decoded="$1"
    
    local subject
    local issuer
    subject=$(echo "$cert_decoded" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
    issuer=$(echo "$cert_decoded" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
    
    if [ "$subject" = "$issuer" ]; then
        echo "${BLUE}🚨${RESET} This is a self-signed certificate"
        return 0
    else
        echo "${BLUE}ℹ️${RESET} Certificate issued by: $issuer"
        return 1
    fi
}

# Find deployments using this secret
find_deployments_using_secret() {
    local secret_name="$1"
    local namespace="$2"
    
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        log "jq not available - skipping deployment discovery"
        return 0
    fi
    
    log "Finding deployments that use secret: $secret_name"
    
    # Search for deployments/statefulsets that reference this secret
    local deployments
    deployments=$(kubectl get deployments,statefulsets -n "$namespace" -o json 2>/dev/null | jq -r --arg secret "$secret_name" '.items[] | select(.spec.template.spec.volumes[]?.secret?.secretName == $secret or .spec.template.spec.containers[].env[]?.valueFrom?.secretKeyRef?.name == $secret or .spec.template.spec.containers[].envFrom[]?.secretRef?.name == $secret) | "\(.kind)/\(.metadata.name)"' 2>/dev/null)
    
    if [ -n "$deployments" ]; then
        echo ""
        echo "${YELLOW}⚠️${RESET} The following workloads use this certificate:"
        echo "$deployments" | while read -r workload; do
            echo "  • $workload"
        done
        echo ""
        echo "${BLUE}Tip:${RESET} After updating certificates, restart these workloads:"
        echo "$deployments" | while read -r workload; do
            local kind=$(echo "$workload" | cut -d'/' -f1)
            local name=$(echo "$workload" | cut -d'/' -f2)
            echo "  kubectl rollout restart $kind/$name -n $namespace"
        done
    fi
}

# Calculate days until expiration
days_until_expiry() {
    local expiry_date="$1"
    detect_os
    
    case "$OS" in
        macos)
            local expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" "+%s" 2>/dev/null ||
                                date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" "+%s" 2>/dev/null)
            ;;
        linux)
            local expiry_epoch=$(date -d "$expiry_date" "+%s" 2>/dev/null)
            ;;
        *)
            echo "unknown"
            return
            ;;
    esac
    
    if [ -n "$expiry_epoch" ]; then
        local current_epoch=$(date "+%s")
        local diff_seconds=$((expiry_epoch - current_epoch))
        local diff_days=$((diff_seconds / 86400))
        echo "$diff_days"
    else
        echo "unknown"
    fi
}

# Check if required commands are available
check_prerequisites() {
    local missing_cmds=()
    
    # Core required commands
    for cmd in gcloud kubectl openssl base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [ ${#missing_cmds[@]} -gt 0 ]; then
        error "Required command(s) not found: ${missing_cmds[*]}"
    fi
    
    # Check for jq if verify mode is enabled
    if [ "$VERIFY" = true ]; then
        if ! command -v jq >/dev/null 2>&1; then
            warning "jq is not installed - deployment discovery will be skipped"
            echo ""
            echo "${YELLOW}The --verify flag requires jq to discover workloads using secrets.${RESET}"
            echo ""
            echo "To install jq:"
            echo "  ${BOLD}# macOS:${RESET}"
            echo "    brew install jq"
            echo ""
            echo "  ${BOLD}# Linux (Debian/Ubuntu):${RESET}"
            echo "    sudo apt-get install jq"
            echo ""
            echo "  ${BOLD}# Linux (RHEL/CentOS):${RESET}"
            echo "    sudo yum install jq"
            echo ""
            echo "Continuing without deployment discovery..."
            echo ""
            sleep 2
        else
            log "jq found - deployment discovery available"
        fi
    fi
    
    # Check for GKE auth plugin
    log "Checking for GKE authentication plugin..."
    if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
        warning "GKE authentication plugin not found"
        echo ""
        echo "${YELLOW}The GKE authentication plugin is required to connect to GKE clusters.${RESET}"
        echo ""
        echo "To install it, run:"
        echo "  ${BOLD}gcloud components install gke-gcloud-auth-plugin${RESET}"
        echo ""
        echo "For more information, see:"
        echo "  https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl"
        echo ""
        error "GKE authentication plugin (gke-gcloud-auth-plugin) is required but not installed"
    else
        log "GKE authentication plugin found"
    fi
}

# Authenticate with GCloud
authenticate_gcloud() {
    if [ "$AUTO_LOGIN" = true ]; then
        log "Authenticating with Google Cloud..."
        if ! gcloud auth login; then
            error "Failed to authenticate with Google Cloud"
        fi
        success "Successfully authenticated with Google Cloud"
    else
        log "Checking Google Cloud authentication..."
        if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
            warning "No active Google Cloud authentication found. Use --auto-login to authenticate."
            error "Please run 'gcloud auth login' first or use the --auto-login flag"
        fi
    fi
}

# Set GCP project
set_gcp_project() {
    local project="$1"
    log "Setting GCP project to: $project"
    
    local error_output
    error_output=$(gcloud config set project "$project" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        # Check if the error is related to authentication
        if echo "$error_output" | grep -qi "token\|auth\|credential\|permission"; then
            echo ""
            warning "Authentication may have expired or insufficient permissions"
            echo ""
            echo "${YELLOW}Please re-authenticate with Google Cloud:${RESET}"
            echo "  ${BOLD}gcloud auth login${RESET}"
            echo ""
            echo "Or run this script with the --auto-login flag:"
            echo "  ${BOLD}$0 --auto-login [other options]${RESET}"
            echo ""
        fi
        error "Failed to set GCP project: $project"
    fi
    
    success "Project set to: $project"
}

# Connect to GKE cluster
connect_to_cluster() {
    local cluster="$1"
    local zone="$2"
    local cluster_context="gke_${PROJECT_NAME}_${zone}_${cluster}"
    
    # If skipping cert check, switch context but don't fetch credentials
    if [ "$SKIP_CERT_CHECK" = true ]; then
        log "Switching to cluster context: $cluster_context"
        
        # Check if context exists
        if kubectl config get-contexts "$cluster_context" &>/dev/null; then
            kubectl config use-context "$cluster_context" &>/dev/null
            success "Switched to existing context: $cluster"
            
            # Quick connectivity check to ensure the context is properly configured
            log "Verifying cluster connectivity..."
            local test_result
            test_result=$(kubectl cluster-info 2>&1)
            
            if echo "$test_result" | grep -qi "certificate signed by unknown authority\|tls.*verify"; then
                echo ""
                warning "Certificate verification issue detected"
                echo ""
                echo "${YELLOW}Your kubeconfig needs to be configured to skip TLS verification.${RESET}"
                echo ""
                echo "${BLUE}Fix this by running the script WITHOUT --skip-cert-check once:${RESET}"
                echo "  ${BOLD}$0 --project $PROJECT_NAME --cluster $cluster --zone $zone --namespace elastic${RESET}"
                echo ""
                echo "Or manually configure it:"
                echo "  ${BOLD}kubectl config set-cluster $cluster_context --insecure-skip-tls-verify=true${RESET}"
                echo ""
                error "Cannot connect to cluster due to certificate verification failure"
            elif echo "$test_result" | grep -qi "unable to connect\|connection refused\|timeout\|no such host"; then
                echo ""
                warning "Cannot connect to cluster"
                echo ""
                echo "${YELLOW}Network connectivity issue detected.${RESET}"
                echo "This might indicate the credentials are stale or the cluster endpoint has changed."
                echo ""
                echo "${BLUE}Try refreshing credentials:${RESET}"
                echo "  ${BOLD}$0 --project $PROJECT_NAME --cluster $cluster --zone $zone --namespace elastic${RESET}"
                echo ""
                error "Cannot establish connection to cluster"
            fi
            
            log "Cluster connectivity verified"
            return 0
        else
            # Context doesn't exist, need to fetch credentials
            warning "Context $cluster_context not found in kubeconfig"
            echo ""
            
            # Show available contexts to help diagnose
            local available_contexts
            available_contexts=$(kubectl config get-contexts -o name 2>/dev/null | grep -i "gke" || echo "")
            
            if [ -n "$available_contexts" ]; then
                echo "${BLUE}Available GKE contexts in your kubeconfig:${RESET}"
                echo "$available_contexts" | while read -r ctx; do
                    echo "  • $ctx"
                done
                echo ""
            fi
            
            echo "${YELLOW}Attempting to fetch credentials for this cluster...${RESET}"
            
            local cred_error
            cred_error=$(gcloud container clusters get-credentials "$cluster" --zone "$zone" --project "$PROJECT_NAME" 2>&1)
            local cred_exit=$?
            
            if [ $cred_exit -ne 0 ]; then
                echo ""
                echo "${RED}Failed to get credentials for cluster${RESET}"
                echo ""
                echo "${YELLOW}Error details:${RESET}"
                echo "$cred_error"
                echo ""
                echo "${BLUE}Troubleshooting:${RESET}"
                echo "  1. Verify the cluster name is correct:"
                echo "     ${BOLD}gcloud container clusters list --project=$PROJECT_NAME --filter='name:$cluster'${RESET}"
                echo ""
                echo "  2. List all clusters in the project:"
                echo "     ${BOLD}gcloud container clusters list --project=$PROJECT_NAME${RESET}"
                echo ""
                echo "  3. Check available contexts in kubeconfig:"
                echo "     ${BOLD}kubectl config get-contexts${RESET}"
                echo ""
                echo "  4. Verify you have permission to access this cluster:"
                echo "     ${BOLD}gcloud container clusters describe $cluster --zone=$zone --project=$PROJECT_NAME${RESET}"
                echo ""
                error "Failed to get credentials for cluster: $cluster in zone: $zone"
            fi
            kubectl config use-context "$cluster_context" &>/dev/null
            success "Created and switched to context: $cluster"
            return 0
        fi
    fi
    
    log "Connecting to GKE cluster: $cluster in zone: $zone"
    
    if ! gcloud container clusters get-credentials "$cluster" --zone "$zone" 2>/dev/null; then
        error "Failed to connect to cluster: $cluster in zone: $zone"
    fi
    
    success "Connected to cluster: $cluster"
    
    # Verify cluster connectivity
    log "Verifying cluster connectivity..."
    local test_result
    test_result=$(kubectl cluster-info 2>&1)
    
    if echo "$test_result" | grep -q "certificate signed by unknown authority"; then
        echo ""
        warning "Certificate trust issue detected"
        echo ""
        echo "${YELLOW}Automatically configuring kubeconfig to skip TLS verification...${RESET}"
        
        # Automatically fix the issue by setting insecure-skip-tls-verify
        kubectl config set-cluster "$cluster_context" --insecure-skip-tls-verify=true >/dev/null 2>&1
        kubectl config unset "clusters.${cluster_context}.certificate-authority-data" >/dev/null 2>&1
        
        # Verify the fix worked
        test_result=$(kubectl cluster-info 2>&1)
        if echo "$test_result" | grep -q "certificate signed by unknown authority"; then
            echo ""
            echo "${RED}Automatic fix failed.${RESET}"
            echo ""
            echo "This typically happens when:"
            echo "  • The cluster certificate authority has changed"
            echo "  • There are stale credentials in your kubeconfig"
            echo ""
            echo "To fix this manually, run:"
            echo "  ${BOLD}kubectl config set-cluster $cluster_context --insecure-skip-tls-verify=true${RESET}"
            echo ""
            echo "Or, use Google Cloud Shell which has proper certificates configured."
            echo ""
            echo "Or, run this script with ${BOLD}--skip-cert-check${RESET} flag to skip credential refresh."
            echo ""
            error "Unable to connect to cluster due to certificate verification failure"
        else
            success "Certificate verification configured successfully"
        fi
    elif echo "$test_result" | grep -qi "unable to connect\|connection refused\|timeout"; then
        echo ""
        warning "Unable to connect to cluster"
        echo ""
        echo "${YELLOW}Cannot establish connection to the cluster.${RESET}"
        echo ""
        echo "Possible causes:"
        echo "  • Network connectivity issues"
        echo "  • Firewall blocking access"
        echo "  • Cluster is private and requires VPN/bastion access"
        echo ""
        echo "Try running this script from Google Cloud Shell or verify network access."
        echo ""
        error "Unable to connect to cluster: $cluster"
    fi
    
    log "Cluster connectivity verified"
}

# Extract and check certificate from secret
check_certificate_in_secret() {
    local secret_name="$1"
    local namespace="$2"
    
    log "Checking certificate in secret: $secret_name"
    
    # First, verify the secret exists
    if ! kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        echo ""
        warning "Secret not found: $secret_name"
        echo ""
        echo "${RED}The secret does not exist in namespace: $namespace${RESET}"
        echo ""
        echo "${YELLOW}Please verify:${RESET}"
        echo "  • Secret name is correct: $secret_name"
        echo "  • Namespace is correct: $namespace"
        echo "  • You have permission to access this namespace"
        echo ""
        echo "List all secrets in namespace:"
        echo "  ${BOLD}kubectl get secrets -n $namespace${RESET}"
        echo ""
        return 1
    fi
    
    log "Secret exists, extracting certificate data..."
    
    # Try to find certificate data - check multiple common field names
    local cert_data
    local cert_field=""
    
    # Try tls.crt first (standard TLS secret)
    cert_data=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
    if [ -n "$cert_data" ]; then
        cert_field="tls.crt"
        log "Found certificate in field: tls.crt"
        if [ "$VERBOSE" = true ]; then
            local cert_length=${#cert_data}
            echo "${BLUE}DEBUG:${RESET} Extracted $cert_length bytes of base64 data from tls.crt"
            echo "${BLUE}DEBUG:${RESET} First 100 chars: ${cert_data:0:100}..."
        fi
    fi
    
    # Try ca.crt (CA certificate)
    if [ -z "$cert_data" ]; then
        cert_data=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.ca\.crt}' 2>/dev/null)
        if [ -n "$cert_data" ]; then
            cert_field="ca.crt"
        fi
    fi
    
    # Try cert.pem
    if [ -z "$cert_data" ]; then
        cert_data=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.cert\.pem}' 2>/dev/null)
        if [ -n "$cert_data" ]; then
            cert_field="cert.pem"
        fi
    fi
    
    # Try certificate
    if [ -z "$cert_data" ]; then
        cert_data=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.certificate}' 2>/dev/null)
        if [ -n "$cert_data" ]; then
            cert_field="certificate"
        fi
    fi
    
    if [ -z "$cert_data" ]; then
        echo ""
        warning "No certificate found in secret: $secret_name"
        echo ""
        echo "${YELLOW}Tried the following fields:${RESET}"
        echo "  • tls.crt (standard TLS certificate)"
        echo "  • ca.crt (CA certificate)"
        echo "  • cert.pem (PEM format certificate)"
        echo "  • certificate (generic certificate field)"
        echo ""
        
        # Show what fields actually exist in the secret
        local available_fields
        available_fields=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | sort)
        
        if [ -n "$available_fields" ]; then
            echo "${BLUE}Available fields in this secret:${RESET}"
            echo "$available_fields" | while read -r field; do
                echo "  • $field"
            done
            echo ""
            echo "${YELLOW}Tip:${RESET} If your certificate is in a different field, please open an issue or"
            echo "modify the script to check for that field name."
        else
            echo "${RED}Could not retrieve secret data. Please check:${RESET}"
            echo "  • Secret exists: kubectl get secret $secret_name -n $namespace"
            echo "  • You have permission to read secrets in namespace: $namespace"
        fi
        echo ""
        return 1
    fi
    
    log "Found certificate in field: $cert_field"
    
    # Decode the certificate
    local cert_decoded
    cert_decoded=$(echo "$cert_data" | base64 -d 2>/dev/null)
    
    if [ -z "$cert_decoded" ]; then
        echo ""
        warning "Failed to decode certificate from secret: $secret_name"
        echo ""
        echo "${RED}Unable to decode base64 data from field: $cert_field${RESET}"
        echo ""
        if [ "$VERBOSE" = true ]; then
            echo "${BLUE}DEBUG:${RESET} Attempting to decode base64 data..."
            echo "${BLUE}DEBUG:${RESET} Base64 data length: ${#cert_data}"
            echo "${BLUE}DEBUG:${RESET} Testing base64 decode manually:"
            echo "$cert_data" | base64 -d 2>&1 | head -c 100
            echo ""
        fi
        echo "${YELLOW}This might indicate:${RESET}"
        echo "  • The data is not properly base64 encoded"
        echo "  • The field contains empty or corrupted data"
        echo "  • There's a platform-specific base64 encoding issue"
        echo ""
        return 1
    fi
    
    if [ "$VERBOSE" = true ]; then
        local decoded_length=${#cert_decoded}
        echo "${BLUE}DEBUG:${RESET} Successfully decoded $decoded_length bytes"
        echo "${BLUE}DEBUG:${RESET} First 100 chars of decoded cert: ${cert_decoded:0:100}..."
    fi
    
    # Extract certificate information
    local cert_info
    cert_info=$(echo "$cert_decoded" | openssl x509 -noout -dates -subject 2>/dev/null)
    
    if [ -z "$cert_info" ]; then
        echo ""
        warning "Failed to parse certificate with OpenSSL"
        echo ""
        if [ "$VERBOSE" = true ]; then
            echo "${BLUE}DEBUG:${RESET} Testing OpenSSL parse:"
            echo "$cert_decoded" | openssl x509 -noout -text 2>&1 | head -20
            echo ""
        fi
        echo "${RED}The decoded data is not a valid X.509 certificate${RESET}"
        echo ""
        return 1
    fi
    
    if [ $? -ne 0 ] || [ -z "$cert_info" ]; then
        warning "Failed to parse certificate from secret: $secret_name"
        return 1
    fi
    
    # Parse dates and subject
    local not_before=$(echo "$cert_info" | grep "notBefore=" | cut -d= -f2)
    local not_after=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2)
    local subject=$(echo "$cert_info" | grep "subject=" | cut -d= -f2-)
    
    # Calculate days until expiry
    local days_left=$(days_until_expiry "$not_after")
    
    # Determine certificate type for display
    local cert_type="Certificate"
    if [ "$cert_field" = "ca.crt" ]; then
        cert_type="CA Certificate"
    elif [ "$cert_field" = "tls.crt" ]; then
        cert_type="TLS Certificate"
    fi
    
    # Determine status and emoji
    local status_text
    local status_color
    local status_emoji
    
    if [ "$days_left" != "unknown" ]; then
        if [ "$days_left" -gt 14 ]; then
            status_text="valid"
            status_color="$GREEN"
            status_emoji="✅"
        elif [ "$days_left" -gt 0 ]; then
            status_text="expires soon"
            status_color="$YELLOW"
            status_emoji="⚠️"
        else
            status_text="expired"
            status_color="$RED"
            status_emoji="❌"
        fi
    else
        status_text="unknown"
        status_color="$YELLOW"
        status_emoji="❓"
    fi
    
    # Format output based on requested format
    case "$FORMAT" in
        json)
            cat << EOF
{
  "secret": "$secret_name",
  "namespace": "$namespace",
  "certificate_type": "$cert_type",
  "certificate_field": "$cert_field",
  "subject": "$subject",
  "not_before": "$(parse_date "$not_before")",
  "not_after": "$(parse_date "$not_after")",
  "days_until_expiry": $days_left,
  "status": "$status_text"
}
EOF
            ;;
        list)
            printf "%-40s %-15s %-12s %s\n" "$secret_name" "$status_text" "$days_left days" "$(format_display_date "$not_after")"
            ;;
        human|*)
            echo ""
            echo "$cert_type in secret ${BOLD}${secret_name}${RESET} is ${status_color}${status_text}${RESET} ${status_emoji}"
            echo ""
            echo "Details"
            echo "=========================="
            printf "%-15s %s\n" "Secret:" "$secret_name"
            printf "%-15s %s\n" "Namespace:" "$namespace"
            printf "%-15s %s\n" "Type:" "$cert_type ($cert_field)"
            printf "%-15s %s\n" "Subject:" "$subject"
            printf "%-15s %s\n" "Issued on:" "$(format_display_date "$not_before")"
            printf "%-15s %s\n" "Valid until:" "$(format_display_date "$not_after")"
            
            if [ "$days_left" != "unknown" ]; then
                if [ "$days_left" -gt 0 ]; then
                    printf "%-15s %s\n" "Expires in:" "${days_left} days"
                else
                    printf "%-15s %s\n" "Expired:" "$((days_left * -1)) days ago"
                fi
            fi
            
            # Perform additional verification if requested
            if [ "$VERIFY" = true ]; then
                echo ""
                echo "Verification Checks"
                echo "=========================="
                check_self_signed "$cert_decoded"
                verify_key_match "$secret_name" "$namespace"
                find_deployments_using_secret "$secret_name" "$namespace"
            fi
            ;;
    esac
}

# List and check all TLS secrets in namespace
check_all_secrets() {
    local namespace="$1"
    
    log "Fetching all secrets in namespace: $namespace"
    
    # Get all secrets of type kubernetes.io/tls
    local secrets
    local error_output
    error_output=$(kubectl get secrets -n "$namespace" 2>&1 >/dev/null)
    
    if [ -n "$error_output" ]; then
        echo ""
        warning "Failed to fetch secrets from namespace: $namespace"
        echo ""
        echo "${RED}Error details:${RESET}"
        echo "$error_output"
        echo ""
        error "Cannot access secrets in namespace: $namespace"
    fi
    
    secrets=$(kubectl get secrets -n "$namespace" -o jsonpath='{range .items[?(@.type=="kubernetes.io/tls")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    
    if [ -z "$secrets" ]; then
        # Check if namespace exists and has any secrets at all
        local all_secrets_count
        all_secrets_count=$(kubectl get secrets -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [ "$all_secrets_count" -eq 0 ]; then
            warning "No secrets found in namespace: $namespace"
        else
            warning "No TLS secrets found in namespace: $namespace (found $all_secrets_count non-TLS secret(s))"
            echo ""
            echo "Available secrets in namespace ${BOLD}$namespace${RESET}:"
            kubectl get secrets -n "$namespace" --no-headers 2>/dev/null | awk '{printf "  • %-50s (type: %s)\n", $1, $2}'
            echo ""
            echo "${BLUE}Tip:${RESET} This script only checks secrets of type ${BOLD}kubernetes.io/tls${RESET}"
        fi
        return 1
    fi
    
    local secret_count=$(echo "$secrets" | wc -l | tr -d ' ')
    success "Found $secret_count TLS secret(s) in namespace: $namespace"
    
    if [ "$FORMAT" = "list" ]; then
        echo ""
        printf "%-40s %-15s %-12s %s\n" "SECRET NAME" "STATUS" "EXPIRES IN" "EXPIRATION DATE"
        printf "%-40s %-15s %-12s %s\n" "$(printf '=%.0s' {1..40})" "$(printf '=%.0s' {1..15})" "$(printf '=%.0s' {1..12})" "$(printf '=%.0s' {1..20})"
    fi
    
    # Check each secret
    while IFS= read -r secret_name; do
        [ -z "$secret_name" ] && continue
        check_certificate_in_secret "$secret_name" "$namespace"
    done <<< "$secrets"
}

# Convert long options to short options for getopts compatibility
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --project)
            args+=("-p" "$2")
            shift 2
            ;;
        --cluster)
            args+=("-c" "$2")
            shift 2
            ;;
        --zone)
            args+=("-z" "$2")
            shift 2
            ;;
        --namespace)
            args+=("-n" "$2")
            shift 2
            ;;
        --secret)
            args+=("-s" "$2")
            shift 2
            ;;
        --format)
            args+=("-f" "$2")
            shift 2
            ;;
        --auto-login)
            args+=("-a")
            shift
            ;;
        --skip-cert-check)
            args+=("-k")
            shift
            ;;
        --verify)
            args+=("-V")
            shift
            ;;
        --verbose)
            args+=("-v")
            shift
            ;;
        --quiet)
            args+=("-q")
            shift
            ;;
        --help)
            args+=("-h")
            shift
            ;;
        --project=*)
            args+=("-p" "${1#*=}")
            shift
            ;;
        --cluster=*)
            args+=("-c" "${1#*=}")
            shift
            ;;
        --zone=*)
            args+=("-z" "${1#*=}")
            shift
            ;;
        --namespace=*)
            args+=("-n" "${1#*=}")
            shift
            ;;
        --secret=*)
            args+=("-s" "${1#*=}")
            shift
            ;;
        --format=*)
            args+=("-f" "${1#*=}")
            shift
            ;;
        --)
            shift
            args+=("$@")
            break
            ;;
        -*)
            args+=("$1")
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

# Set the converted arguments
set -- "${args[@]}"

# Parse command line options using getopts
while getopts "p:c:z:n:s:f:akVvqh" opt; do
    case $opt in
        p)
            PROJECT_NAME="$OPTARG"
            ;;
        c)
            GKE_CLUSTER_NAME="$OPTARG"
            ;;
        z)
            CLUSTER_ZONE="$OPTARG"
            ;;
        n)
            NAMESPACE="$OPTARG"
            ;;
        s)
            SECRET_NAME="$OPTARG"
            ;;
        f)
            FORMAT="$OPTARG"
            if [[ ! "$FORMAT" =~ ^(human|json|list)$ ]]; then
                error "Invalid format: $FORMAT. Use human, json, or list"
            fi
            ;;
        a)
            AUTO_LOGIN=true
            ;;
        k)
            SKIP_CERT_CHECK=true
            ;;
        V)
            VERIFY=true
            ;;
        v)
            VERBOSE=true
            ;;
        q)
            QUIET=true
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            echo "Use -h or --help for help" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument" >&2
            echo "Use -h or --help for help" >&2
            exit 1
            ;;
    esac
done

# Setup colors
setup_colors

# Validate required parameters
if [ -z "$PROJECT_NAME" ]; then
    error "Project name is required. Use -p or --project"
fi

if [ -z "$GKE_CLUSTER_NAME" ]; then
    error "Cluster name is required. Use -c or --cluster"
fi

if [ -z "$CLUSTER_ZONE" ]; then
    error "Cluster zone is required. Use -z or --zone"
fi

# Check prerequisites
check_prerequisites

# Detect OS for informational purposes
detect_os
log "Detected OS: $OS"

# Authenticate with GCloud
authenticate_gcloud

# Set GCP project
set_gcp_project "$PROJECT_NAME"

# Connect to GKE cluster
connect_to_cluster "$GKE_CLUSTER_NAME" "$CLUSTER_ZONE"

# Check certificates
if [ -n "$SECRET_NAME" ]; then
    # Check specific secret
    check_certificate_in_secret "$SECRET_NAME" "$NAMESPACE"
else
    # Check all TLS secrets in namespace
    check_all_secrets "$NAMESPACE"
fi

exit 0
