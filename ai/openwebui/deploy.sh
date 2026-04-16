#!/usr/bin/env bash
# Deploy Open WebUI ACI. Injects storage account key from env so the key is never in the repo.
#
# Requires target scope (no defaults — do not commit subscription or RG names):
#   -g / --resource-group and -s / --subscription, OR
#   RESOURCE_GROUP and SUBSCRIPTION_ID in the environment.
#
# Usage:
#   ./deploy.sh -g <container-rg> -s <subscription-id-or-name>
#   ./deploy.sh -g <container-rg> -s <subscription-id-or-name> other-template.json
#   RESOURCE_GROUP=... SUBSCRIPTION_ID=... STORAGE_ACCOUNT_KEY='...' ./deploy.sh
#   STORAGE_ACCOUNT_RESOURCE_GROUP='<storage-rg>' ./deploy.sh -g <container-rg> -s <sub>   # fetch key
#
# Default template file: openwebui-snd1.json when no template argument is given.

set -e

DEFAULT_FILE="openwebui-snd1.json"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
SUBSCRIPTION="${SUBSCRIPTION_ID:-}"
FILE=""

usage() {
  cat <<'EOF'
Deploy Open WebUI ACI. Injects storage account key from env so the key is never in the repo.

Requires target scope (no defaults):
  -g / --resource-group and -s / --subscription, OR RESOURCE_GROUP and SUBSCRIPTION_ID.

Usage:
  ./deploy.sh -g <container-rg> -s <subscription-id-or-name>
  ./deploy.sh -g <container-rg> -s <subscription-id-or-name> [template.json]
  RESOURCE_GROUP=... SUBSCRIPTION_ID=... STORAGE_ACCOUNT_KEY='...' ./deploy.sh

When the template uses Azure Files, set STORAGE_ACCOUNT_KEY or STORAGE_ACCOUNT_RESOURCE_GROUP
(to fetch the key; the fetch path uses storage account name containerinstance — change the script if yours differs).

Default template: openwebui-snd1.json
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -g|--resource-group)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    -s|--subscription)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      SUBSCRIPTION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1 (try --help)" >&2
      exit 1
      ;;
    *)
      if [[ -n "$FILE" ]]; then
        echo "Error: unexpected extra argument: $1 (only one template file allowed)" >&2
        exit 1
      fi
      FILE="$1"
      shift
      ;;
  esac
done

[[ -n "$FILE" ]] || FILE="$DEFAULT_FILE"

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: resource group is required. Pass -g / --resource-group or set RESOURCE_GROUP." >&2
  exit 1
fi
if [[ -z "$SUBSCRIPTION" ]]; then
  echo "Error: subscription is required. Pass -s / --subscription or set SUBSCRIPTION_ID." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f "$FILE" ]]; then
  echo "Error: $FILE not found in $SCRIPT_DIR" >&2
  exit 1
fi

# Only need storage key if this template uses Azure Files
NEED_KEY=0
if jq -e '.properties.volumes[] | select(.azureFile != null)' "$FILE" >/dev/null 2>&1; then
  NEED_KEY=1
fi

if [[ "$NEED_KEY" -eq 1 ]]; then
  if [[ -z "${STORAGE_ACCOUNT_KEY:-}" ]]; then
    if [[ -n "${STORAGE_ACCOUNT_RESOURCE_GROUP:-}" ]]; then
      echo "Fetching storage account key..."
      STORAGE_ACCOUNT_KEY=$(az storage account keys list \
        --account-name containerinstance \
        --resource-group "$STORAGE_ACCOUNT_RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION" \
        --query '[0].value' -o tsv)
    else
      echo "Error: Set STORAGE_ACCOUNT_KEY or STORAGE_ACCOUNT_RESOURCE_GROUP (to fetch the key)." >&2
      exit 1
    fi
  fi
fi

# Build deploy JSON (inject key only when template has Azure File volume)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
if [[ "$NEED_KEY" -eq 1 ]]; then
  jq --arg k "$STORAGE_ACCOUNT_KEY" '
    .properties.volumes |= map(
      if .name == "openwebui-data" then .azureFile.storageAccountKey = $k else . end
    )
  ' "$FILE" > "$TMPFILE"
  # Verify key is present in payload (non-empty); don't print the key
  KEY_IN_PAYLOAD=$(jq -r '.properties.volumes[] | select(.name == "openwebui-data") | .azureFile.storageAccountKey // ""' "$TMPFILE")
  if [[ -z "$KEY_IN_PAYLOAD" ]]; then
    echo "Error: Storage key was not injected into the deploy JSON (key empty or missing in payload)." >&2
    exit 1
  fi
  echo "Storage key injected (length: ${#KEY_IN_PAYLOAD} chars)."
else
  cp "$FILE" "$TMPFILE"
fi

GROUP_NAME=$(jq -r '.name' "$TMPFILE")
echo "Deploying container group '$GROUP_NAME' from $FILE (resource group: $RESOURCE_GROUP) ..."
az container create \
  --resource-group "$RESOURCE_GROUP" \
  --subscription "$SUBSCRIPTION" \
  --file "$TMPFILE"

echo "Done. Get IP with: az container show -g $RESOURCE_GROUP -n $GROUP_NAME --subscription $SUBSCRIPTION --query ipAddress.ip -o tsv"
