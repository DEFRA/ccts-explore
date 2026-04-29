#!/usr/bin/env bash
# Deploy Open WebUI on Azure Container Apps: internal-only environment (no public endpoint),
# HTTPS terminated at Container Apps ingress (no Caddy). Same image, env, CPU/RAM, and
# Azure Files share as the ACI template in openwebui-snd1.json (defaults match that file).
#
# Prerequisites:
#   - Subnet delegated to Microsoft.App/environments (dedicated to the Container Apps env; not the ACI subnet).
#   - File share and storage account already exist (same as ACI).
#   - Azure CLI with containerapp extension: az extension add --name containerapp
#
# Requires (no subscription/RG defaults):
#   -g / --resource-group, -s / --subscription, OR RESOURCE_GROUP and SUBSCRIPTION_ID
#   --infrastructure-subnet-id (full ARM ID) unless --skip-env-create and the env already exists
#
# Usage:
#   ./deploy-containerapps.sh -g <rg> -s <sub> --infrastructure-subnet-id <subnet-arm-id>
#   RESOURCE_GROUP=... SUBSCRIPTION_ID=... INFRASTRUCTURE_SUBNET_ID=... ./deploy-containerapps.sh
#   ./deploy-containerapps.sh ... --skip-env-create   # use existing CONTAINER_APPS_ENV_NAME
#   ./deploy-containerapps.sh ... my-app-name         # optional trailing app name (default: openwebui)
#
# Storage key: STORAGE_ACCOUNT_KEY or STORAGE_ACCOUNT_RESOURCE_GROUP (same pattern as deploy.sh).
#
# SMB (default): standard Azure Files share + account key.
# NFS (--nfs or STORAGE_PROTOCOL=nfs): Azure Files Premium with an NFS share; VNet integration between the ACA env and the
# storage account; "Secure transfer required" disabled on the storage account. Share path is /STORAGE_ACCOUNT/SHARE_NAME.
# See https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts?tabs=nfs

set -eo pipefail

storage_protocol_is_nfs() {
  [[ "$(printf '%s' "$STORAGE_PROTOCOL" | tr '[:upper:]' '[:lower:]')" == "nfs" ]]
}

DEFAULT_LOCATION="uksouth"
DEFAULT_ENV_NAME="openwebui-ca-env"
DEFAULT_APP_NAME="openwebui"
DEFAULT_ENV_STORAGE_NAME="openwebui-data"
DEFAULT_STORAGE_ACCOUNT_NAME="containerinstance"
DEFAULT_FILE_SHARE_NAME="openwebui-containerapp"
DEFAULT_IMAGE="ghcr.io/open-webui/open-webui:main"

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
SUBSCRIPTION="${SUBSCRIPTION_ID:-}"
INFRASTRUCTURE_SUBNET_ID="${INFRASTRUCTURE_SUBNET_ID:-}"
LOCATION="${LOCATION:-$DEFAULT_LOCATION}"
CONTAINER_APPS_ENV_NAME="${CONTAINER_APPS_ENV_NAME:-$DEFAULT_ENV_NAME}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-$DEFAULT_APP_NAME}"
ENV_STORAGE_NAME="${ENV_STORAGE_NAME:-$DEFAULT_ENV_STORAGE_NAME}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-$DEFAULT_STORAGE_ACCOUNT_NAME}"
FILE_SHARE_NAME="${FILE_SHARE_NAME:-$DEFAULT_FILE_SHARE_NAME}"
STORAGE_ACCOUNT_KEY="${STORAGE_ACCOUNT_KEY:-}"
STORAGE_ACCOUNT_RESOURCE_GROUP="${STORAGE_ACCOUNT_RESOURCE_GROUP:-}"
# smb (default) or nfs — NFS uses NfsAzureFile on the Container Apps environment (see header).
STORAGE_PROTOCOL="${STORAGE_PROTOCOL:-smb}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_SHARE_PATH="${NFS_SHARE_PATH:-}"
NFS_SHARE_PATH_CLI=""
SKIP_ENV_CREATE=0
POSITIONAL_APP_NAME=""
EXPLICIT_APP_NAME=0

usage() {
  cat <<'EOF'
Deploy Open WebUI on Azure Container Apps (private env, ingress HTTPS, Azure Files — no Caddy).

Required:
  -g / --resource-group and -s / --subscription, OR RESOURCE_GROUP and SUBSCRIPTION_ID
  --infrastructure-subnet-id <arm-id>   subnet delegated to Microsoft.App/environments
                                          (omit only with --skip-env-create if env already exists)

Optional:
  --environment-name <name>     default: openwebui-ca-env (CONTAINER_APPS_ENV_NAME)
  --app-name <name>             default: openwebui (CONTAINER_APP_NAME)
  --location <region>           default: uksouth (LOCATION)
  --storage-account-name        default: containerinstance (STORAGE_ACCOUNT_NAME)
  --file-share-name             default: openwebui-containerapp (FILE_SHARE_NAME)
  --env-storage-name            env mount name; default: openwebui-data (ENV_STORAGE_NAME)
  --storage-account-key <key>   or env STORAGE_ACCOUNT_KEY
  --storage-account-resource-group <rg>   fetch key via az (or env STORAGE_ACCOUNT_RESOURCE_GROUP)
  --STORAGE_ACCOUNT_RESOURCE_GROUP <rg>   same as --storage-account-resource-group
  --nfs                       use Azure Files over NFS (NfsAzureFile) instead of SMB; see script header for prerequisites
  --nfs-server <host>       NFS server FQDN (default: STORAGE_ACCOUNT_NAME.file.core.windows.net)
  --nfs-share-path <path>   share path as /account/share (default: /STORAGE_ACCOUNT_NAME/FILE_SHARE_NAME)
  --skip-env-create             do not create the Container Apps environment (must exist)

Storage key (SMB only): STORAGE_ACCOUNT_KEY or STORAGE_ACCOUNT_RESOURCE_GROUP. NFS usually does not need a key; set one if your CLI requires it.

Env: STORAGE_PROTOCOL=nfs is equivalent to --nfs.

Examples:
  ./deploy-containerapps.sh -g myRg -s mySub --infrastructure-subnet-id "/subscriptions/.../subnets/ca-subnet"
  ./deploy-containerapps.sh -g myRg -s mySub --skip-env-create
  ./deploy-containerapps.sh -g myRg -s mySub --skip-env-create --nfs \\
    --storage-account-name mypremiumacct --file-share-name openwebui-nfs --storage-account-resource-group myRg

Optional trailing argument: container app name (same habit as deploy.sh’s template file). Do not use
if you already passed --app-name.
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
    --infrastructure-subnet-id)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      INFRASTRUCTURE_SUBNET_ID="$2"
      shift 2
      ;;
    --environment-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      CONTAINER_APPS_ENV_NAME="$2"
      shift 2
      ;;
    --app-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      CONTAINER_APP_NAME="$2"
      EXPLICIT_APP_NAME=1
      shift 2
      ;;
    --location)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      LOCATION="$2"
      shift 2
      ;;
    --storage-account-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      STORAGE_ACCOUNT_NAME="$2"
      shift 2
      ;;
    --file-share-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      FILE_SHARE_NAME="$2"
      shift 2
      ;;
    --env-storage-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      ENV_STORAGE_NAME="$2"
      shift 2
      ;;
    --storage-account-key)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      STORAGE_ACCOUNT_KEY="$2"
      shift 2
      ;;
    --storage-account-resource-group|--STORAGE_ACCOUNT_RESOURCE_GROUP)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      STORAGE_ACCOUNT_RESOURCE_GROUP="$2"
      shift 2
      ;;
    --nfs)
      STORAGE_PROTOCOL=nfs
      shift
      ;;
    --nfs-server)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      NFS_SERVER="$2"
      shift 2
      ;;
    --nfs-share-path)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      NFS_SHARE_PATH_CLI="$2"
      shift 2
      ;;
    --skip-env-create)
      SKIP_ENV_CREATE=1
      shift
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
      # zsh prompt looks like "… openwebui %"; copy/paste sometimes appends a lone % (or #) as argv.
      if [[ "$1" == '%' || "$1" == '#' ]]; then
        echo "Warning: ignoring stray '$1' (usually pasted from the shell prompt)." >&2
        shift
        continue
      fi
      if [[ -n "$POSITIONAL_APP_NAME" ]]; then
        echo "Error: only one optional container app name allowed (unexpected: $1)." >&2
        echo "Hint: paste only the command line — not \"openwebui %\" or other prompt text." >&2
        exit 1
      fi
      POSITIONAL_APP_NAME="$1"
      shift
      ;;
  esac
done

if [[ -n "$POSITIONAL_APP_NAME" ]]; then
  if [[ "$EXPLICIT_APP_NAME" -eq 1 ]]; then
    echo "Error: pass app name only once (--app-name or trailing argument, not both)." >&2
    exit 1
  fi
  CONTAINER_APP_NAME="$POSITIONAL_APP_NAME"
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: resource group is required (-g or RESOURCE_GROUP)." >&2
  exit 1
fi
if [[ -z "$SUBSCRIPTION" ]]; then
  echo "Error: subscription is required (-s or SUBSCRIPTION_ID)." >&2
  exit 1
fi
if [[ "$SKIP_ENV_CREATE" -eq 0 && -z "$INFRASTRUCTURE_SUBNET_ID" ]]; then
  echo "Error: --infrastructure-subnet-id is required unless --skip-env-create is set." >&2
  exit 1
fi

command -v az >/dev/null || { echo "Error: Azure CLI (az) not found." >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq not found (required for volume patch path)." >&2; exit 1; }

# Put --subscription after the command (same as deploy.sh). Using `az --subscription X storage ...`
# fails on some CLI builds with "subscription ... misspelled" even when `az account show` works.
az_scoped() {
  az "$@" --subscription "$SUBSCRIPTION"
}

if storage_protocol_is_nfs; then
  echo "Using NFS Azure Files (NfsAzureFile). Ensure: Premium storage account, NFS file share, VNet access from the ACA subnet,"
  echo "and 'Secure transfer required' disabled on the storage account (see Microsoft docs)."
  nfs_server_effective="${NFS_SERVER:-${STORAGE_ACCOUNT_NAME}.file.core.windows.net}"
  nfs_path_effective="${NFS_SHARE_PATH_CLI:-${NFS_SHARE_PATH:-}}"
  if [[ -z "$nfs_path_effective" ]]; then
    nfs_path_effective="/${STORAGE_ACCOUNT_NAME}/${FILE_SHARE_NAME}"
  fi
else
  if [[ -z "${STORAGE_ACCOUNT_KEY:-}" ]]; then
    if [[ -n "${STORAGE_ACCOUNT_RESOURCE_GROUP:-}" ]]; then
      echo "Fetching storage account key for $STORAGE_ACCOUNT_NAME..."
      STORAGE_ACCOUNT_KEY=$(az_scoped storage account keys list \
        --account-name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$STORAGE_ACCOUNT_RESOURCE_GROUP" \
        --query '[0].value' -o tsv)
    else
      echo "Error: Set STORAGE_ACCOUNT_KEY or STORAGE_ACCOUNT_RESOURCE_GROUP (SMB), or use --nfs for NFS shares." >&2
      exit 1
    fi
  fi
  if [[ -z "$STORAGE_ACCOUNT_KEY" ]]; then
    echo "Error: storage account key is empty." >&2
    exit 1
  fi
fi

ensure_env() {
  if az_scoped containerapp env show \
    --name "$CONTAINER_APPS_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    echo "Container Apps environment '$CONTAINER_APPS_ENV_NAME' already exists."
    return 0
  fi
  echo "Creating internal-only Container Apps environment '$CONTAINER_APPS_ENV_NAME'..."
  az_scoped containerapp env create \
    --name "$CONTAINER_APPS_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --infrastructure-subnet-resource-id "$INFRASTRUCTURE_SUBNET_ID" \
    --internal-only true
}

if [[ "$SKIP_ENV_CREATE" -eq 0 ]]; then
  ensure_env
else
  if ! az_scoped containerapp env show \
    --name "$CONTAINER_APPS_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    echo "Error: environment '$CONTAINER_APPS_ENV_NAME' not found (create it or drop --skip-env-create)." >&2
    exit 1
  fi
fi

if storage_protocol_is_nfs; then
  echo "Registering NFS Azure Files storage on the environment (name: $ENV_STORAGE_NAME)..."
  nfs_storage_args=(
    containerapp env storage set
    --name "$CONTAINER_APPS_ENV_NAME"
    --resource-group "$RESOURCE_GROUP"
    --storage-name "$ENV_STORAGE_NAME"
    --storage-type NfsAzureFile
    --server "$nfs_server_effective"
    --azure-file-account-name "$STORAGE_ACCOUNT_NAME"
    --azure-file-share-name "$nfs_path_effective"
    --access-mode ReadWrite
  )
  if [[ -n "${STORAGE_ACCOUNT_KEY:-}" ]]; then
    nfs_storage_args+=(--azure-file-account-key "$STORAGE_ACCOUNT_KEY")
  fi
  az_scoped "${nfs_storage_args[@]}"
else
  echo "Registering SMB Azure Files storage on the environment (name: $ENV_STORAGE_NAME)..."
  # `env storage set` expects -n/--name for the *managed environment*, not --environment-name.
  az_scoped containerapp env storage set \
    --name "$CONTAINER_APPS_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --storage-name "$ENV_STORAGE_NAME" \
    --azure-file-account-name "$STORAGE_ACCOUNT_NAME" \
    --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
    --azure-file-share-name "$FILE_SHARE_NAME" \
    --access-mode ReadWrite
fi

MANAGED_ENV_ID=$(az_scoped containerapp env show \
  --name "$CONTAINER_APPS_ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

write_create_yaml() {
  local out="$1"
  # Single-revision app: internal ingress, platform TLS (transport Auto), Open WebUI only — matches ACI openwebui container.
  cat >"$out" <<YAML
location: ${LOCATION}
name: ${CONTAINER_APP_NAME}
type: Microsoft.App/containerApps
properties:
  managedEnvironmentId: ${MANAGED_ENV_ID}
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: false
      targetPort: 8080
      transport: Auto
      allowInsecure: false
  template:
    scale:
      minReplicas: 1
      maxReplicas: 1
    containers:
      - name: openwebui
        image: ${DEFAULT_IMAGE}
        resources:
          cpu: 2.0
          memory: 4Gi
        env:
          - name: GLOBAL_LOG_LEVEL
            value: DEBUG
          - name: ENABLE_BASE_MODELS_CACHE
            value: "true"
          - name: HF_HOME
            value: /tmp/hf_cache
          - name: SENTENCE_TRANSFORMERS_HOME
            value: /tmp/embedding_models
        volumeMounts:
          - volumeName: openwebui-data
            mountPath: /app/backend/data
    volumes:
      - name: openwebui-data
        storageType: AzureFile
        storageName: ${ENV_STORAGE_NAME}
YAML
}

patch_volumes_if_missing() {
  local app_id patch_body template_json
  app_id=$(az_scoped containerapp show \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)
  template_json=$(az_scoped containerapp show \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    -o json | jq --arg sn "$ENV_STORAGE_NAME" '
    .properties.template
    | .volumes |= (
        if ((. // []) | map(.name) | index("openwebui-data")) != null then .
        else (. // []) + [{
          "name": "openwebui-data",
          "storageType": "AzureFile",
          "storageName": $sn
        }] end
      )
    | .containers[0].volumeMounts |= (
        if ((. // []) | map(.volumeName) | index("openwebui-data")) != null then .
        else (. // []) + [{
          "volumeName": "openwebui-data",
          "mountPath": "/app/backend/data"
        }] end
      )
  ')
  patch_body=$(jq -n --argjson template "$template_json" '{properties: {template: $template}}')
  echo "Ensuring Azure Files volume mount on existing app..."
  az rest --method PATCH \
    --uri "${app_id}?api-version=2024-03-01" \
    --body "$patch_body" \
    --subscription "$SUBSCRIPTION" \
    --headers "Content-Type=application/json"
}

if az_scoped containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Container app '$CONTAINER_APP_NAME' exists; updating ingress, container, then volume mounts..."
  az_scoped containerapp ingress enable \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --type internal \
    --target-port 8080 \
    --transport auto
  az_scoped containerapp update \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$DEFAULT_IMAGE" \
    --min-replicas 1 \
    --max-replicas 1 \
    --cpu 2 \
    --memory 4Gi \
    --set-env-vars \
      "GLOBAL_LOG_LEVEL=DEBUG" \
      "ENABLE_BASE_MODELS_CACHE=true" \
      "HF_HOME=/tmp/hf_cache" \
      "SENTENCE_TRANSFORMERS_HOME=/tmp/embedding_models"
  patch_volumes_if_missing
else
  TMPYAML=$(mktemp)
  trap 'rm -f "$TMPYAML"' EXIT
  write_create_yaml "$TMPYAML"
  echo "Creating container app '$CONTAINER_APP_NAME'..."
  # `-n/--name` is required by the CLI even when the YAML contains `name:`.
  az_scoped containerapp create \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --yaml "$TMPYAML"
fi

echo ""
echo "Done. Internal FQDN (HTTPS via Container Apps ingress; use from the VNet / private DNS):"
az_scoped containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv
