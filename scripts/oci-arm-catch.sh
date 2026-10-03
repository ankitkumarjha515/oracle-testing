#!/usr/bin/env bash
# Retries launching an OCI Always Free Ampere (VM.Standard.A1.Flex) instance
# until capacity frees up. Built for GitHub Actions: auth comes from ~/.oci/config
# (written by the workflow) and all settings come from environment variables.

set -uo pipefail

: "${COMPARTMENT_ID:?COMPARTMENT_ID is required}"
: "${AVAILABILITY_DOMAIN:?AVAILABILITY_DOMAIN is required}"
: "${IMAGE_ID:?IMAGE_ID is required}"
: "${SSH_PUBLIC_KEY:?SSH_PUBLIC_KEY is required}"

DISPLAY_NAME="${DISPLAY_NAME:-Ankit}"
SUBNET_NAME="${SUBNET_NAME:-}"
SUBNET_ID="${SUBNET_ID:-}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
RETRY_SECONDS="${RETRY_SECONDS:-60}"
RATE_LIMIT_BACKOFF_SECONDS="${RATE_LIMIT_BACKOFF_SECONDS:-150}"
# Stop the loop after this many minutes so the job ends cleanly before
# GitHub's 6-hour job limit; the next scheduled run picks up from there.
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-340}"

SHAPE="VM.Standard.A1.Flex"
WORKDIR="$(mktemp -d)"
KEY_FILE="$WORKDIR/key.pub"
OUT="$WORKDIR/output.log"
trap 'rm -rf "$WORKDIR"' EXIT

printf '%s\n' "$SSH_PUBLIC_KEY" > "$KEY_FILE"

# Lets the workflow know whether to create the success issue / disable itself.
set_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "$1=$2" >> "$GITHUB_OUTPUT"
    fi
}

existing_instance_count() {
    oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --display-name "$DISPLAY_NAME" \
        --all 2>/dev/null \
    | jq -r --arg shape "$SHAPE" \
        '[.data[]? | select(.shape == $shape and ."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | length' \
    || echo 0
}

echo "Checking for an existing '$DISPLAY_NAME' A1 instance..."
count="$(existing_instance_count)"
if [ "${count:-0}" != "0" ] && [ -n "$count" ]; then
    echo "Instance '$DISPLAY_NAME' already exists. Nothing to do."
    set_output created already-exists
    exit 0
fi

if [ -z "$SUBNET_ID" ]; then
    echo "Looking up subnet..."
    subnets="$(oci network subnet list --compartment-id "$COMPARTMENT_ID" --all)"
    if [ -n "$SUBNET_NAME" ]; then
        SUBNET_ID="$(jq -r --arg n "$SUBNET_NAME" '.data[] | select(."display-name" == $n) | .id' <<< "$subnets" | head -1)"
    fi
    if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "null" ]; then
        SUBNET_ID="$(jq -r '.data[0].id // empty' <<< "$subnets")"
    fi
fi
if [ -z "$SUBNET_ID" ]; then
    echo "❌ No subnet found in the compartment. Create a VCN + public subnet first."
    exit 1
fi
echo "Using subnet: ${SUBNET_ID:0:30}..."

deadline=$(( $(date +%s) + MAX_RUNTIME_MINUTES * 60 ))
attempt=1

while [ "$(date +%s)" -lt "$deadline" ]; do
    echo "------------------------------------------------"
    echo "Attempt #$attempt at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    oci compute instance launch \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --subnet-id "$SUBNET_ID" \
        --assign-private-dns-record true \
        --assign-public-ip true \
        --agent-config '{"is_management_disabled": false, "is_monitoring_disabled": false, "plugins_config": [{"desired_state": "DISABLED", "name": "Vulnerability Scanning"}, {"desired_state": "DISABLED", "name": "OS Management Hub Agent"}, {"desired_state": "DISABLED", "name": "Management Agent"}, {"desired_state": "ENABLED", "name": "Custom Logs Monitoring"}, {"desired_state": "DISABLED", "name": "Compute RDMA GPU Monitoring"}, {"desired_state": "ENABLED", "name": "Compute Instance Run Command"}, {"desired_state": "ENABLED", "name": "Compute Instance Monitoring"}, {"desired_state": "DISABLED", "name": "Compute HPC RDMA Auto-Configuration"}, {"desired_state": "DISABLED", "name": "Compute HPC RDMA Authentication"}, {"desired_state": "ENABLED", "name": "Cloud Guard Workload Protection"}, {"desired_state": "DISABLED", "name": "Block Volume Management"}, {"desired_state": "DISABLED", "name": "Bastion"}]}' \
        --availability-config '{"recovery_action": "RESTORE_INSTANCE"}' \
        --display-name "$DISPLAY_NAME" \
        --image-id "$IMAGE_ID" \
        --instance-options '{"are_legacy_imds_endpoints_disabled": true}' \
        --shape-config "{\"memory_in_gbs\": $MEMORY_GB, \"ocpus\": $OCPUS}" \
        --ssh-authorized-keys-file "$KEY_FILE" > "$OUT" 2>&1
    status=$?

    if [ $status -eq 0 ]; then
        echo "🎉 SUCCESS! Instance '$DISPLAY_NAME' has been created."
        jq -r '.data | "id: \(.id)\nstate: \(."lifecycle-state")\nshape: \(.shape)"' "$OUT" 2>/dev/null || true
        set_output created true
        exit 0
    fi

    if grep -q "Out of host capacity" "$OUT"; then
        echo "Result: Out of host capacity. Retrying in ${RETRY_SECONDS}s..."
        sleep "$RETRY_SECONDS"
    elif grep -qE "TooManyRequests|\"status\": 429" "$OUT"; then
        echo "Result: API rate limit hit. Backing off ${RATE_LIMIT_BACKOFF_SECONDS}s..."
        sleep "$RATE_LIMIT_BACKOFF_SECONDS"
    elif grep -qE "InternalError|ServiceUnavailable|\"status\": 50[0-9]|RequestException|timed out|Connection" "$OUT"; then
        echo "Result: Transient OCI/network error. Retrying in ${RETRY_SECONDS}s..."
        sed -n '1,15p' "$OUT"
        sleep "$RETRY_SECONDS"
    else
        echo "❌ Unexpected error (not capacity related), stopping:"
        cat "$OUT"
        exit 1
    fi
    attempt=$((attempt + 1))
done

echo "Reached ${MAX_RUNTIME_MINUTES}-minute run limit without capacity. The next scheduled run will continue."
set_output created false
exit 0
