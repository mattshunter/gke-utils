#!/bin/bash

################################################################################
# GCP Load Balancer Diagnostics Script
################################################################################
# Diagnose Google Cloud Load Balancers by hostname and/or IP address.
#
# Features:
# - Identifies matching forwarding rules and frontend details
# - Detects supported frontend protocols and target proxy type
# - Validates certificates (Google-managed vs self-managed)
# - Verifies certificate domains/SANs against requested hostname
# - Inspects URL maps, backend services, health checks, and logging settings
#
# Usage: ./gcp-diagnose-load-balancer.sh -p <project> [-H <hostname>] [-i <ip>]
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

# Defaults
PROJECT=""
HOSTNAME=""
IP_ADDRESS=""
REGION_FILTER=""
VERBOSE=false
QUIET=false
AUTO_LOGIN=false
LIST_ALL=false

FOUND_RULES=0
MATCHING_RULES=0
CERT_WARNINGS=0
DNS_WARNINGS=0
CHAIN_WARNINGS=0
OPENSSL_AVAILABLE=false
CRITICAL_FINDINGS=0

# Usage function
usage() {
    cat << EOF
${BOLD}GCP Load Balancer Diagnostics${NC}

Usage: $0 [OPTIONS]

${BOLD}Required Parameters:${NC}
    -p, --project <project>         GCP project ID

${BOLD}Target Selection (at least one, unless --list-all):${NC}
    -H, --hostname <hostname>       Hostname to analyze (example: api.example.com)
    -i, --ip <ip-address>           Frontend IP address to analyze

${BOLD}Optional Parameters:${NC}
    -r, --region <region>           Focus on forwarding rules in a region
    --list-all                      Analyze all forwarding rules in project
    -v, --verbose                   Verbose output
    -q, --quiet                     Quiet mode (minimal output)
    -l, --auto-login                Auto-login to gcloud if not authenticated
    -h, --help                      Show this help message

${BOLD}Examples:${NC}
    $0 -p my-project -H api.example.com
    $0 -p my-project -i 34.123.45.67
    $0 -p my-project -H api.example.com -i 34.123.45.67
    $0 -p my-project --list-all --region us-central1

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
        -H|--hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        -i|--ip)
            IP_ADDRESS="$2"
            shift 2
            ;;
        -r|--region)
            REGION_FILTER="$2"
            shift 2
            ;;
        --list-all)
            LIST_ALL=true
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

# Validation
if [ -z "$PROJECT" ]; then
    echo -e "${RED}Error: Project is required${NC}"
    usage
fi

if [ "$LIST_ALL" = false ] && [ -z "$HOSTNAME" ] && [ -z "$IP_ADDRESS" ]; then
    echo -e "${RED}Error: Provide --hostname and/or --ip (or use --list-all)${NC}"
    usage
fi

# Helpers
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
        echo -e "${GREEN}✅${NC} $1"
    fi
}

print_warn() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

print_dns_warn() {
    DNS_WARNINGS=$((DNS_WARNINGS + 1))
    echo -e "${YELLOW}⚠️${NC} $1"
}

print_chain_warn() {
    CHAIN_WARNINGS=$((CHAIN_WARNINGS + 1))
    echo -e "${YELLOW}⚠️${NC} $1"
}

print_critical() {
    CRITICAL_FINDINGS=$((CRITICAL_FINDINGS + 1))
    CHAIN_WARNINGS=$((CHAIN_WARNINGS + 1))
    echo -e "${RED}❗️${NC} $1"
}

print_summary_count() {
    local label="$1"
    local count="$2"

    if [ "$count" -gt 0 ]; then
        echo -e "⚠️ ${label}: ${count}"
    else
        echo -e "✅ ${label}: ${count}"
    fi
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

extract_name_from_url() {
    echo "$1" | awk -F'/' '{print $NF}'
}

extract_collection_from_url() {
    echo "$1" | awk -F'/' '{print $(NF-1)}'
}

extract_region_from_url() {
    local url="$1"
    if echo "$url" | grep -q '/regions/'; then
        echo "$url" | sed -n 's|.*/regions/\([^/]*\)/.*|\1|p'
    fi
}

host_matches_pattern() {
    local host
    local pattern
    host=$(lower "$1")
    pattern=$(lower "$2")

    if [ "$host" = "$pattern" ]; then
        return 0
    fi

    if echo "$pattern" | grep -q '^\*\.'; then
        local suffix="${pattern#*.}"
        if [[ "$host" == *".$suffix" ]]; then
            return 0
        fi
    fi

    return 1
}

protocol_from_target_collection() {
    case "$1" in
        targetHttpProxies|regionTargetHttpProxies)
            echo "HTTP"
            ;;
        targetHttpsProxies|regionTargetHttpsProxies)
            echo "HTTPS"
            ;;
        targetGrpcProxies|regionTargetGrpcProxies)
            echo "GRPC/HTTP2"
            ;;
        targetSslProxies|regionTargetSslProxies)
            echo "SSL/TLS"
            ;;
        targetTcpProxies|regionTargetTcpProxies)
            echo "TCP"
            ;;
        targetPools)
            echo "TCP/UDP passthrough"
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}

frontend_type_hint() {
    local scheme="$1"
    local target_collection="$2"

    case "$target_collection" in
        targetHttpProxies|targetHttpsProxies|targetGrpcProxies)
            if [ "$scheme" = "EXTERNAL_MANAGED" ]; then
                echo "Global external Application Load Balancer"
            else
                echo "Global HTTP(S)/gRPC proxy load balancer"
            fi
            ;;
        regionTargetHttpProxies|regionTargetHttpsProxies|regionTargetGrpcProxies)
            echo "Regional Application Load Balancer"
            ;;
        targetSslProxies|targetTcpProxies)
            echo "Global proxy Network Load Balancer"
            ;;
        regionTargetSslProxies|regionTargetTcpProxies)
            echo "Regional proxy Network Load Balancer"
            ;;
        targetPools)
            echo "External passthrough Network Load Balancer"
            ;;
        *)
            echo "Load balancer type could not be inferred"
            ;;
    esac
}

# Dependency checks
if ! command -v gcloud >/dev/null 2>&1; then
    print_error "gcloud CLI is not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required for this script"
    echo "Install with: brew install jq"
    exit 1
fi

if command -v openssl >/dev/null 2>&1; then
    OPENSSL_AVAILABLE=true
else
    print_warn "openssl is not installed; certificate chain and trust checks will be skipped"
fi

# Authentication checks
check_gcloud_auth() {
    local active
    active=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    if [ -z "$active" ]; then
        if [ "$AUTO_LOGIN" = true ]; then
            print_info "Not authenticated. Starting gcloud auth login..."
            gcloud auth login || {
                print_error "Failed to authenticate"
                exit 1
            }
        else
            print_error "Not authenticated in gcloud. Run: gcloud auth login"
            exit 1
        fi
    else
        print_verbose "Authenticated as: $active"
    fi
}

set_project() {
    gcloud config set project "$PROJECT" >/dev/null 2>&1 || {
        print_error "Failed to set project: $PROJECT"
        exit 1
    }
}

# Target describe helpers with global/regional fallback
try_describe_target_proxy() {
    local collection="$1"
    local name="$2"
    local region="$3"

    case "$collection" in
        targetHttpProxies)
            gcloud compute target-http-proxies describe "$name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
            [ -n "$region" ] && gcloud compute region-target-http-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        regionTargetHttpProxies)
            [ -n "$region" ] && gcloud compute region-target-http-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        targetHttpsProxies)
            gcloud compute target-https-proxies describe "$name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
            [ -n "$region" ] && gcloud compute region-target-https-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        regionTargetHttpsProxies)
            [ -n "$region" ] && gcloud compute region-target-https-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        targetGrpcProxies)
            gcloud compute target-grpc-proxies describe "$name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
            [ -n "$region" ] && gcloud compute region-target-grpc-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        regionTargetGrpcProxies)
            [ -n "$region" ] && gcloud compute region-target-grpc-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        targetSslProxies)
            gcloud compute target-ssl-proxies describe "$name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
            [ -n "$region" ] && gcloud compute region-target-ssl-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        regionTargetSslProxies)
            [ -n "$region" ] && gcloud compute region-target-ssl-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        targetTcpProxies)
            gcloud compute target-tcp-proxies describe "$name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
            [ -n "$region" ] && gcloud compute region-target-tcp-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
        regionTargetTcpProxies)
            [ -n "$region" ] && gcloud compute region-target-tcp-proxies describe "$name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0
            ;;
    esac

    return 1
}

describe_url_map() {
    local map_name="$1"
    local region="$2"

    gcloud compute url-maps describe "$map_name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
    [ -n "$region" ] && gcloud compute region-url-maps describe "$map_name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0

    return 1
}

describe_backend_service() {
    local bs_name="$1"
    local region="$2"

    gcloud compute backend-services describe "$bs_name" --global --project "$PROJECT" --format=json 2>/dev/null && return 0
    [ -n "$region" ] && gcloud compute backend-services describe "$bs_name" --region "$region" --project "$PROJECT" --format=json 2>/dev/null && return 0

    return 1
}

describe_ssl_certificate() {
    local cert_name="$1"
    gcloud compute ssl-certificates describe "$cert_name" --global --project "$PROJECT" --format=json 2>/dev/null
}

describe_certificate_manager_certificate() {
    local cert_name="$1"
    gcloud certificate-manager certificates describe "$cert_name" --location=global --project "$PROJECT" --format=json 2>/dev/null
}

list_certificate_map_entries() {
    local map_name="$1"
    gcloud certificate-manager maps entries list --map="$map_name" --location=global --project "$PROJECT" --format=json 2>/dev/null
}

# DNS checks
RESOLVED_A_RECORDS=""
perform_dns_checks() {
    if [ -z "$HOSTNAME" ]; then
        return
    fi

    print_section "DNS Resolution Checks"

    if command -v dig >/dev/null 2>&1; then
        RESOLVED_A_RECORDS=$(dig +short A "$HOSTNAME" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr '\n' ' ')
        if [ -z "$RESOLVED_A_RECORDS" ]; then
            print_dns_warn "No A records found for hostname: $HOSTNAME"
        else
            print_info "A records for $HOSTNAME: $RESOLVED_A_RECORDS"
            if [ -n "$IP_ADDRESS" ]; then
                if echo " $RESOLVED_A_RECORDS " | grep -q " $IP_ADDRESS "; then
                    print_info "Provided IP matches DNS records"
                else
                    print_dns_warn "Provided IP ($IP_ADDRESS) does not match DNS A records"
                fi
            fi
        fi
    else
        print_dns_warn "dig is not installed; skipping DNS resolution checks"
    fi
}

host_matches_any_cert_domain() {
    local host="$1"
    shift
    local domains=("$@")

    for d in "${domains[@]}"; do
        [ -z "$d" ] && continue
        if host_matches_pattern "$host" "$d"; then
            return 0
        fi
    done

    return 1
}

analyze_pem_chain_bundle() {
    local pem_bundle="$1"
    local label="$2"

    if [ "$OPENSSL_AVAILABLE" != true ]; then
        return
    fi

    if [ -z "$pem_bundle" ] || ! echo "$pem_bundle" | grep -q "BEGIN CERTIFICATE"; then
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null)
    if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
        print_chain_warn "Unable to create temp directory for certificate chain analysis"
        return
    fi

    echo "$pem_bundle" | awk -v dir="$tmpdir" '
        /-----BEGIN CERTIFICATE-----/ { in_cert=1; idx++; file=sprintf("%s/cert-%02d.pem", dir, idx) }
        in_cert { print > file }
        /-----END CERTIFICATE-----/ { in_cert=0 }
        END { print idx+0 }
    ' > "$tmpdir/count.txt"

    local cert_count
    cert_count=$(cat "$tmpdir/count.txt" 2>/dev/null)
    if [ -z "$cert_count" ] || [ "$cert_count" -eq 0 ]; then
        rm -rf "$tmpdir"
        return
    fi

    echo "  Chain Certificates (${label}): $cert_count"

    local previous_issuer=""
    local leaf_subject=""
    local leaf_issuer=""
    local i
    for (( i=1; i<=cert_count; i++ )); do
        local cert_file
        cert_file=$(printf "%s/cert-%02d.pem" "$tmpdir" "$i")

        local subject issuer not_after is_ca
        subject=$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
        not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
        is_ca=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | awk '/Basic Constraints/{getline; if($0 ~ /CA:TRUE/) print "true"; else print "false"; exit}')
        [ -z "$is_ca" ] && is_ca="unknown"

        echo "    [$i] Subject: ${subject:-unknown}"
        echo "        Issuer: ${issuer:-unknown}"
        echo "        Not After: ${not_after:-unknown}"
        echo "        Is CA: $is_ca"

        if [ "$i" -eq 1 ]; then
            leaf_subject="$subject"
            leaf_issuer="$issuer"
        fi

        if [ -n "$previous_issuer" ] && [ -n "$subject" ] && [ "$subject" != "$previous_issuer" ]; then
            print_chain_warn "Chain continuity mismatch between certificate $((i-1)) issuer and certificate $i subject"
        fi

        previous_issuer="$issuer"
    done

    # Red flag common misconfiguration: non-self-signed leaf with no intermediates.
    if [ "$cert_count" -eq 1 ] && [ -n "$leaf_subject" ] && [ -n "$leaf_issuer" ] && [ "$leaf_subject" != "$leaf_issuer" ]; then
        print_critical "leaf certificate appears to be missing intermediate/root chain certificates"
    fi

    # Validate trust/chain if we have OpenSSL data to verify.
    local leaf_file
    leaf_file=$(printf "%s/cert-%02d.pem" "$tmpdir" 1)
    local chain_file
    chain_file="$tmpdir/untrusted-chain.pem"
    : > "$chain_file"

    if [ "$cert_count" -gt 1 ]; then
        local j
        for (( j=2; j<=cert_count; j++ )); do
            cat "$(printf "%s/cert-%02d.pem" "$tmpdir" "$j")" >> "$chain_file"
            echo "" >> "$chain_file"
        done
    fi

    local verify_output
    if [ -s "$chain_file" ]; then
        verify_output=$(openssl verify -purpose sslserver -untrusted "$chain_file" "$leaf_file" 2>&1)
    else
        verify_output=$(openssl verify -purpose sslserver "$leaf_file" 2>&1)
    fi

    if echo "$verify_output" | grep -q ": OK$"; then
        echo "  Chain Verify: ✅ OK"
    else
        print_critical "certificate trust/chain verification failed (${label})"
        echo "  Chain Verify: ⚠️ FAILED"
        echo "  Verify Detail: $(echo "$verify_output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    fi

    rm -rf "$tmpdir"
}

analyze_live_tls_chain() {
    if [ -z "$HOSTNAME" ] && [ -z "$IP_ADDRESS" ]; then
        return
    fi

    if [ "$OPENSSL_AVAILABLE" != true ]; then
        return
    fi

    print_section "Live TLS Chain and Trust Diagnostics"

    local connect_host
    connect_host="${IP_ADDRESS:-$HOSTNAME}"

    local sni_args=""
    if [ -n "$HOSTNAME" ]; then
        sni_args="-servername $HOSTNAME"
        echo "  Live Probe: ${connect_host}:443 with SNI=$HOSTNAME"
    else
        echo "  Live Probe: ${connect_host}:443 without SNI"
    fi

    local s_client_output
    s_client_output=$(openssl s_client $sni_args -connect "${connect_host}:443" -showcerts -verify 10 < /dev/null 2>&1)
    if [ $? -ne 0 ] && ! echo "$s_client_output" | grep -q "BEGIN CERTIFICATE"; then
        print_chain_warn "TLS handshake failed for ${connect_host}:443"
        return
    fi

    local verify_line verify_code verify_message
    verify_line=$(echo "$s_client_output" | sed -n 's/^ *Verify return code: \([0-9][0-9]*\) (\(.*\))/\1|\2/p' | tail -1)
    verify_code=$(echo "$verify_line" | awk -F'|' '{print $1}')
    verify_message=$(echo "$verify_line" | awk -F'|' '{print $2}')

    if [ -n "$verify_code" ]; then
        echo "  Trust Verification Code: $verify_code (${verify_message:-unknown})"
        if [ "$verify_code" != "0" ]; then
            print_chain_warn "System trust validation failed for live endpoint: ${verify_message:-unknown}"
        fi
    else
        print_chain_warn "Unable to determine trust verification result from live TLS handshake"
    fi

    analyze_pem_chain_bundle "$s_client_output" "live-endpoint"
}

analyze_certificate_map() {
    local cert_map_url="$1"

    if [ -z "$cert_map_url" ]; then
        return
    fi

    local cert_map_name
    cert_map_name=$(extract_name_from_url "$cert_map_url")

    print_section "Certificate Map Diagnostics"
    echo "Certificate Map: $cert_map_name"

    local entries_json
    entries_json=$(list_certificate_map_entries "$cert_map_name")

    if [ -z "$entries_json" ] || [ "$entries_json" = "[]" ]; then
        print_warn "Unable to list certificate map entries (or no entries found): $cert_map_name"
        CERT_WARNINGS=$((CERT_WARNINGS + 1))
        return
    fi

    local entry_count
    entry_count=$(echo "$entries_json" | jq 'length')
    echo "Entry Count: $entry_count"

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue

        local entry_name matcher hostname
        entry_name=$(echo "$entry" | jq -r '.name // ""' | awk -F'/' '{print $NF}')
        matcher=$(echo "$entry" | jq -r '.matcher // "PRIMARY"')
        hostname=$(echo "$entry" | jq -r '.hostname // ""')

        echo -e "${BOLD}${entry_name:-unnamed-entry}${NC}"
        echo "  Matcher: $matcher"
        [ -n "$hostname" ] && echo "  Hostname Pattern: $hostname"

        if [ -n "$HOSTNAME" ] && [ -n "$hostname" ]; then
            if host_matches_pattern "$HOSTNAME" "$hostname"; then
                print_info "Hostname matches certificate map entry pattern"
            else
                print_warn "Hostname does not match certificate map entry pattern: $hostname"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
            fi
        fi

        local cert_refs
        cert_refs=$(echo "$entry" | jq -r '.certificates[]?')
        if [ -z "$cert_refs" ]; then
            print_warn "No certificates attached to map entry: ${entry_name:-unknown}"
            CERT_WARNINGS=$((CERT_WARNINGS + 1))
            continue
        fi

        while IFS= read -r cert_ref; do
            [ -z "$cert_ref" ] && continue

            local cm_cert_name cm_cert_json cm_state cm_scope
            cm_cert_name=$(echo "$cert_ref" | awk -F'/' '{print $NF}')
            cm_cert_json=$(describe_certificate_manager_certificate "$cm_cert_name")

            if [ -z "$cm_cert_json" ]; then
                print_warn "Unable to describe Certificate Manager certificate: $cm_cert_name"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
                continue
            fi

            cm_state=$(echo "$cm_cert_json" | jq -r '.managed.state // "N/A"')
            cm_scope=$(echo "$cm_cert_json" | jq -r '.scope // "DEFAULT"')

            echo "  Certificate Manager Cert: $cm_cert_name"
            echo "    Scope: $cm_scope"
            echo "    Managed State: $cm_state"

            if [ "$cm_state" != "N/A" ] && [ "$cm_state" != "ACTIVE" ]; then
                print_warn "Certificate Manager cert not ACTIVE: $cm_cert_name ($cm_state)"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
            fi

            local san_list
            san_list=$(echo "$cm_cert_json" | jq -r '.sanDnsnames[]?')
            if [ -n "$san_list" ]; then
                echo "    SAN DNS Names: $(echo "$san_list" | tr '\n' ' ')"
            fi

            local pem_blocks
            pem_blocks=$(echo "$cm_cert_json" | jq -r '((.pemCertificate.certificate // "") + "\n" + (.pemCertificate.certificateChain // ""))')
            if [ -n "$pem_blocks" ]; then
                analyze_pem_chain_bundle "$pem_blocks" "certificate-manager"
            fi

            if [ -n "$HOSTNAME" ] && [ -n "$san_list" ]; then
                local san_domains=()
                while IFS= read -r san; do
                    [ -n "$san" ] && san_domains+=("$san")
                done <<< "$san_list"

                if host_matches_any_cert_domain "$HOSTNAME" "${san_domains[@]}"; then
                    print_info "Hostname is covered by Certificate Manager SANs: $cm_cert_name"
                else
                    print_warn "Hostname is NOT covered by Certificate Manager SANs: $cm_cert_name"
                    CERT_WARNINGS=$((CERT_WARNINGS + 1))
                fi
            fi
        done <<< "$cert_refs"
    done < <(echo "$entries_json" | jq -c '.[]')
}

analyze_certificates() {
    local cert_urls_csv="$1"

    if [ -z "$cert_urls_csv" ] || [ "$cert_urls_csv" = "null" ]; then
        print_warn "No SSL certificates attached to proxy"
        CERT_WARNINGS=$((CERT_WARNINGS + 1))
        return
    fi

    print_section "Certificate Diagnostics"

    IFS=',' read -r -a cert_urls <<< "$cert_urls_csv"
    local cert_index=0
    local cert_total=${#cert_urls[@]}
    for cert_url in "${cert_urls[@]}"; do
        cert_index=$((cert_index + 1))

        if [ "$cert_index" -gt 1 ]; then
            echo ""
            echo "----------------------------------------"
        fi

        local cert_name
        cert_name=$(extract_name_from_url "$cert_url")

        local cert_json
        cert_json=$(describe_ssl_certificate "$cert_name")

        if [ -z "$cert_json" ]; then
            print_warn "Unable to describe certificate: $cert_name"
            CERT_WARNINGS=$((CERT_WARNINGS + 1))
            continue
        fi

        local cert_type
        local expire_time
        cert_type=$(echo "$cert_json" | jq -r '.type // "UNKNOWN"')
        expire_time=$(echo "$cert_json" | jq -r '.expireTime // "N/A"')

        echo -e "${BOLD}[${cert_index}/${cert_total}] $cert_name${NC}"
        echo "  Type: $cert_type"
        echo "  Expire Time: $expire_time"

        local domain_list=""
        local managed_status=""

        if [ "$cert_type" = "MANAGED" ]; then
            managed_status=$(echo "$cert_json" | jq -r '.managed.status // "UNKNOWN"')
            domain_list=$(echo "$cert_json" | jq -r '.managed.domains[]?')
            echo "  Managed Status: $managed_status"
            if [ -n "$domain_list" ]; then
                echo "  Managed Domains: $(echo "$domain_list" | tr '\n' ' ')"
            fi
            if [ "$managed_status" != "ACTIVE" ]; then
                print_warn "Managed certificate not ACTIVE: $cert_name ($managed_status)"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
            fi
        else
            domain_list=$(echo "$cert_json" | jq -r '.subjectAlternativeNames[]?')
            if [ -n "$domain_list" ]; then
                echo "  Subject Alternative Names: $(echo "$domain_list" | tr '\n' ' ')"
            fi
        fi

        local cert_pem
        cert_pem=$(echo "$cert_json" | jq -r '.certificate // ""')
        if [ -n "$cert_pem" ]; then
            analyze_pem_chain_bundle "$cert_pem" "configured-certificate"
        fi

        if [ -n "$HOSTNAME" ]; then
            local domains=()
            while IFS= read -r d; do
                [ -n "$d" ] && domains+=("$d")
            done <<< "$domain_list"

            if [ ${#domains[@]} -eq 0 ]; then
                print_warn "No domains/SANs found for certificate: $cert_name"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
            elif host_matches_any_cert_domain "$HOSTNAME" "${domains[@]}"; then
                print_info "Hostname is covered by certificate: $cert_name"
            else
                print_warn "Hostname is NOT covered by certificate: $cert_name"
                CERT_WARNINGS=$((CERT_WARNINGS + 1))
            fi
        fi
    done
}

analyze_backend_services() {
    local backend_csv="$1"
    local default_region="$2"

    if [ -z "$backend_csv" ] || [ "$backend_csv" = "null" ]; then
        print_warn "No backend services discovered"
        return
    fi

    print_section "Backend Service Diagnostics"

    IFS=',' read -r -a bs_urls <<< "$backend_csv"
    for bs_url in "${bs_urls[@]}"; do
        [ -z "$bs_url" ] && continue

        local bs_name bs_region
        bs_name=$(extract_name_from_url "$bs_url")
        bs_region=$(extract_region_from_url "$bs_url")
        [ -z "$bs_region" ] && bs_region="$default_region"

        local bs_json
        bs_json=$(describe_backend_service "$bs_name" "$bs_region")

        if [ -z "$bs_json" ]; then
            print_warn "Unable to describe backend service: $bs_name"
            continue
        fi

        local protocol timeout_sec session_affinity cdn_enabled log_enabled
        protocol=$(echo "$bs_json" | jq -r '.protocol // "UNKNOWN"')
        timeout_sec=$(echo "$bs_json" | jq -r '.timeoutSec // "N/A"')
        session_affinity=$(echo "$bs_json" | jq -r '.sessionAffinity // "NONE"')
        cdn_enabled=$(echo "$bs_json" | jq -r '.enableCDN // false')
        log_enabled=$(echo "$bs_json" | jq -r '.logConfig.enable // false')

        echo -e "${BOLD}$bs_name${NC}"
        echo "  Region Scope: ${bs_region:-global}"
        echo "  Protocol: $protocol"
        echo "  TimeoutSec: $timeout_sec"
        echo "  Session Affinity: $session_affinity"
        echo "  CDN Enabled: $cdn_enabled"
        echo "  Request Logging Enabled: $log_enabled"

        local health_checks
        health_checks=$(echo "$bs_json" | jq -r '.healthChecks[]?')
        if [ -n "$health_checks" ]; then
            echo "  Health Checks:"
            while IFS= read -r hc; do
                [ -z "$hc" ] && continue
                echo "    - $(extract_name_from_url "$hc")"
            done <<< "$health_checks"
        else
            print_warn "No health checks configured on backend service: $bs_name"
        fi
    done
}

analyze_forwarding_rule() {
    local rule_json="$1"

    FOUND_RULES=$((FOUND_RULES + 1))

    local fr_name fr_ip fr_ip_protocol fr_ports fr_scheme fr_network_tier fr_region fr_target
    fr_name=$(echo "$rule_json" | jq -r '.name')
    fr_ip=$(echo "$rule_json" | jq -r '.IPAddress // "N/A"')
    fr_ip_protocol=$(echo "$rule_json" | jq -r '.IPProtocol // "UNKNOWN"')
    fr_ports=$(echo "$rule_json" | jq -r '.portRange // (.ports // [] | join(",")) // "all"')
    fr_scheme=$(echo "$rule_json" | jq -r '.loadBalancingScheme // "UNKNOWN"')
    fr_network_tier=$(echo "$rule_json" | jq -r '.networkTier // "UNKNOWN"')
    fr_region=$(echo "$rule_json" | jq -r '.region // ""' | awk -F'/' '{print $NF}')
    fr_target=$(echo "$rule_json" | jq -r '.target // ""')

    local target_collection target_name
    target_collection=$(extract_collection_from_url "$fr_target")
    target_name=$(extract_name_from_url "$fr_target")

    local protocol_hint lb_hint
    protocol_hint=$(protocol_from_target_collection "$target_collection")
    lb_hint=$(frontend_type_hint "$fr_scheme" "$target_collection")

    # IP filter check
    if [ -n "$IP_ADDRESS" ] && [ "$fr_ip" != "$IP_ADDRESS" ]; then
        print_verbose "Skipping $fr_name (IP $fr_ip != requested $IP_ADDRESS)"
        return
    fi

    # Region filter check
    if [ -n "$REGION_FILTER" ] && [ -n "$fr_region" ] && [ "$fr_region" != "$REGION_FILTER" ]; then
        print_verbose "Skipping $fr_name (region $fr_region != filter $REGION_FILTER)"
        return
    fi

    local proxy_json=""
    local url_map=""
    local cert_map=""
    local cert_urls_csv=""
    local backend_service_csv=""
    local host_match="unknown"

    if [ -n "$target_collection" ] && [ -n "$target_name" ]; then
        proxy_json=$(try_describe_target_proxy "$target_collection" "$target_name" "$fr_region" || true)

        if [ -n "$proxy_json" ]; then
            url_map=$(echo "$proxy_json" | jq -r '.urlMap // ""')
            cert_map=$(echo "$proxy_json" | jq -r '.certificateMap // ""')
            cert_urls_csv=$(echo "$proxy_json" | jq -r '.sslCertificates // [] | join(",")')

            local direct_backend
            direct_backend=$(echo "$proxy_json" | jq -r '.service // ""')
            if [ -n "$direct_backend" ]; then
                backend_service_csv="$direct_backend"
            fi
        fi
    fi

    if [ -n "$url_map" ]; then
        local url_map_name
        local url_json
        url_map_name=$(extract_name_from_url "$url_map")
        url_json=$(describe_url_map "$url_map_name" "$fr_region" || true)

        if [ -n "$url_json" ]; then
            # Collect backend services from URL map
            backend_service_csv=$(echo "$url_json" | jq -r '[
                .defaultService,
                (.pathMatchers[]?.defaultService),
                (.pathMatchers[]?.pathRules[]?.service),
                (.pathMatchers[]?.routeRules[]?.service),
                (.pathMatchers[]?.routeRules[]?.routeAction?.weightedBackendServices[]?.backendService),
                (.defaultRouteAction?.weightedBackendServices[]?.backendService)
            ] | map(select(. != null and . != "")) | unique | join(",")')

            # Hostname match check against URL map host rules
            if [ -n "$HOSTNAME" ]; then
                local host_patterns
                host_patterns=$(echo "$url_json" | jq -r '.hostRules[]?.hosts[]?')
                if [ -z "$host_patterns" ]; then
                    host_match="no-host-rules"
                else
                    host_match="no"
                    while IFS= read -r p; do
                        [ -z "$p" ] && continue
                        if host_matches_pattern "$HOSTNAME" "$p"; then
                            host_match="yes"
                            break
                        fi
                    done <<< "$host_patterns"
                fi
            fi
        fi
    fi

    # Hostname acceptance fallback when URL map does not provide host rules
    if [ -n "$HOSTNAME" ] && [ "$host_match" = "unknown" ]; then
        if [ -n "$RESOLVED_A_RECORDS" ] && echo " $RESOLVED_A_RECORDS " | grep -q " $fr_ip "; then
            host_match="dns-ip-match"
        else
            host_match="unknown"
        fi
    fi

    # Enforce hostname filter if requested
    if [ -n "$HOSTNAME" ]; then
        case "$host_match" in
            yes|dns-ip-match|no-host-rules|unknown)
                ;;
            no)
                print_verbose "Skipping $fr_name because hostname does not match URL map host rules"
                return
                ;;
        esac
    fi

    MATCHING_RULES=$((MATCHING_RULES + 1))

    print_header "Forwarding Rule: $fr_name"
    echo "Frontend Type: $lb_hint"
    echo "Frontend IP: $fr_ip"
    echo "Region: ${fr_region:-global}"
    echo "Network Tier: $fr_network_tier"
    echo "Load Balancing Scheme: $fr_scheme"
    echo "IP Protocol: $fr_ip_protocol"
    echo "Ports: $fr_ports"
    echo "Target: ${fr_target:-N/A}"
    echo "Inferred Frontend Protocols: $protocol_hint"

    if [ -n "$HOSTNAME" ]; then
        echo "Hostname Match State: $host_match"
    fi

    if [ -n "$url_map" ]; then
        print_section "URL Map Diagnostics"
        echo "URL Map: $(extract_name_from_url "$url_map")"
    fi

    if [ -n "$cert_map" ]; then
        analyze_certificate_map "$cert_map"
    fi

    if [ "$protocol_hint" = "HTTPS" ] || [ "$protocol_hint" = "SSL/TLS" ] || [ "$protocol_hint" = "GRPC/HTTP2" ] || [ -n "$cert_urls_csv" ]; then
        analyze_certificates "$cert_urls_csv"
    fi

    analyze_backend_services "$backend_service_csv" "$fr_region"
}

# Main
print_header "GCP Load Balancer Diagnostics"
print_info "Project: $PROJECT"
[ -n "$HOSTNAME" ] && print_info "Hostname: $HOSTNAME"
[ -n "$IP_ADDRESS" ] && print_info "IP Address: $IP_ADDRESS"
[ -n "$REGION_FILTER" ] && print_info "Region Filter: $REGION_FILTER"

check_gcloud_auth
set_project
perform_dns_checks
analyze_live_tls_chain

print_section "Discovering Forwarding Rules"
FR_JSON=$(gcloud compute forwarding-rules list --project "$PROJECT" --format=json 2>/dev/null)
if [ -z "$FR_JSON" ] || [ "$FR_JSON" = "[]" ]; then
    print_error "No forwarding rules found in project: $PROJECT"
    exit 1
fi

# Iterate over rules
while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    analyze_forwarding_rule "$rule"
done < <(echo "$FR_JSON" | jq -c '.[]')

print_header "Diagnostic Summary"
echo "ℹ️ Forwarding rules scanned: $FOUND_RULES"
echo "ℹ️ Matching forwarding rules: $MATCHING_RULES"
print_summary_count "Certificate warnings" "$CERT_WARNINGS"
print_summary_count "DNS warnings" "$DNS_WARNINGS"
print_summary_count "Chain/Trust warnings" "$CHAIN_WARNINGS"
print_summary_count "Critical findings" "$CRITICAL_FINDINGS"

if [ "$CRITICAL_FINDINGS" -gt 0 ]; then
    echo "❗️ One or more critical certificate findings were detected"
elif [ "$CERT_WARNINGS" -gt 0 ] || [ "$DNS_WARNINGS" -gt 0 ] || [ "$CHAIN_WARNINGS" -gt 0 ]; then
    echo "⚠️ Non-critical warnings were detected"
else
    echo "✅ No certificate or DNS warnings detected"
fi

if [ "$MATCHING_RULES" -eq 0 ]; then
    print_warn "No matching load balancer frontends were found for the given inputs"
    echo ""
    echo "Suggestions:"
    echo "  1) Confirm the project ID and active account permissions"
    echo "  2) Check if the hostname resolves to a different IP than expected"
    echo "  3) Verify whether the load balancer uses a certificate map with host rules"
    echo "  4) Re-run with --list-all -v to inspect all forwarding rules"
    exit 2
fi

echo ""
print_info "Diagnostics complete"
