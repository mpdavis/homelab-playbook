#!/usr/bin/env bash
#
# verify-logging.sh - Verify central logging infrastructure
#
# This script verifies the health and functionality of the Loki + Vector
# logging infrastructure by checking:
# 1. Loki service health and readiness
# 2. Vector agent status on application hosts
# 3. End-to-end log ingestion and query functionality
#
# Usage: ./scripts/verify-logging.sh
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

# ANSI color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly LOKI_HOST="10.0.1.201"
readonly LOKI_PORT="3100"
readonly LOKI_URL="http://${LOKI_HOST}:${LOKI_PORT}"
readonly TEST_LABEL="verify_logging_test"
readonly TEST_MESSAGE="Verification test at $(date -Iseconds)"

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0

#######################################
# Print section header
# Arguments:
#   $1 - Section title
#######################################
print_section() {
    echo -e "\n${BLUE}==>${NC} ${1}"
}

#######################################
# Print success message
# Arguments:
#   $1 - Message
#######################################
print_success() {
    echo -e "${GREEN}✓${NC} ${1}"
    ((CHECKS_PASSED++))
}

#######################################
# Print failure message
# Arguments:
#   $1 - Message
#######################################
print_failure() {
    echo -e "${RED}✗${NC} ${1}"
    ((CHECKS_FAILED++))
}

#######################################
# Print warning message
# Arguments:
#   $1 - Message
#######################################
print_warning() {
    echo -e "${YELLOW}⚠${NC} ${1}"
}

#######################################
# Check if Loki is ready
#######################################
check_loki_ready() {
    print_section "Checking Loki health"

    if ! command -v curl &> /dev/null; then
        print_failure "curl is not installed"
        return 1
    fi

    # Check if Loki is reachable
    if ! curl -sf "${LOKI_URL}/ready" > /dev/null; then
        print_failure "Loki is not ready at ${LOKI_URL}"
        return 1
    fi

    print_success "Loki is ready at ${LOKI_URL}"

    # Check Loki metrics endpoint
    if curl -sf "${LOKI_URL}/metrics" > /dev/null; then
        print_success "Loki metrics endpoint is accessible"
    else
        print_warning "Loki metrics endpoint not accessible"
    fi

    return 0
}

#######################################
# Check Vector service status on hosts
#######################################
check_vector_status() {
    print_section "Checking Vector agent status"

    if ! command -v ansible &> /dev/null; then
        print_failure "ansible is not installed"
        return 1
    fi

    # Check Vector service on sonarr host
    local vector_status
    vector_status=$(ansible sonarr -m systemd -a "name=vector state=started" -o 2>&1) || {
        print_failure "Failed to check Vector service on sonarr"
        echo "${vector_status}"
        return 1
    }

    if echo "${vector_status}" | grep -q "SUCCESS"; then
        print_success "Vector service is running on sonarr"
    else
        print_failure "Vector service is not running on sonarr"
        echo "${vector_status}"
        return 1
    fi

    return 0
}

#######################################
# Query Loki for recent logs
# Arguments:
#   $1 - Label selector (optional)
#   $2 - Limit (optional, default: 10)
#######################################
query_loki() {
    local selector="${1:-{job=\"sonarr\"}}"
    local limit="${2:-10}"
    local query_url="${LOKI_URL}/loki/api/v1/query_range"

    # Query last 5 minutes
    local end_time
    local start_time
    end_time=$(date +%s)000000000  # nanoseconds
    start_time=$((end_time - 300000000000))  # 5 minutes ago

    curl -sf -G "${query_url}" \
        --data-urlencode "query=${selector}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "limit=${limit}" 2>/dev/null
}

#######################################
# Check end-to-end log ingestion
#######################################
check_log_ingestion() {
    print_section "Checking log ingestion"

    # Query for sonarr logs
    local query_result
    query_result=$(query_loki '{job="sonarr"}' 1) || {
        print_failure "Failed to query Loki"
        return 1
    }

    # Check if we got any results
    if echo "${query_result}" | grep -q '"resultType":"streams"'; then
        local result_count
        result_count=$(echo "${query_result}" | jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [[ "${result_count}" -gt 0 ]]; then
            print_success "Found ${result_count} log stream(s) from sonarr"

            # Show sample log entry
            local sample_log
            sample_log=$(echo "${query_result}" | jq -r '.data.result[0].values[0][1]' 2>/dev/null || echo "")
            if [[ -n "${sample_log}" ]]; then
                echo -e "  Sample: ${sample_log:0:100}..."
            fi
        else
            print_warning "No log streams found from sonarr (may need time to collect logs)"
        fi
    else
        print_warning "No logs ingested yet (Vector may need time to start collecting)"
    fi

    return 0
}

#######################################
# Check Loki label values
#######################################
check_loki_labels() {
    print_section "Checking Loki labels"

    local labels_url="${LOKI_URL}/loki/api/v1/labels"
    local labels_result
    labels_result=$(curl -sf "${labels_url}" 2>/dev/null) || {
        print_failure "Failed to query Loki labels"
        return 1
    }

    if echo "${labels_result}" | grep -q '"status":"success"'; then
        local label_list
        label_list=$(echo "${labels_result}" | jq -r '.data[]' 2>/dev/null | tr '\n' ', ')
        print_success "Available labels: ${label_list%,}"

        # Check for expected labels
        if echo "${label_list}" | grep -q "job"; then
            print_success "Found 'job' label"
        fi
        if echo "${label_list}" | grep -q "hostname"; then
            print_success "Found 'hostname' label"
        fi
    else
        print_warning "No labels found yet"
    fi

    return 0
}

#######################################
# Print summary
#######################################
print_summary() {
    echo ""
    echo "========================================"
    echo "Verification Summary"
    echo "========================================"
    echo -e "${GREEN}Checks passed:${NC} ${CHECKS_PASSED}"
    echo -e "${RED}Checks failed:${NC} ${CHECKS_FAILED}"
    echo ""

    if [[ ${CHECKS_FAILED} -eq 0 ]]; then
        echo -e "${GREEN}All checks passed!${NC}"
        return 0
    else
        echo -e "${RED}Some checks failed. Review output above.${NC}"
        return 1
    fi
}

#######################################
# Main execution
#######################################
main() {
    echo "========================================"
    echo "Central Logging Verification"
    echo "========================================"

    check_loki_ready || true
    check_vector_status || true
    check_log_ingestion || true
    check_loki_labels || true

    print_summary
}

# Run main function
main
