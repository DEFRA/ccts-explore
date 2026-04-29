#!/usr/bin/env bash
# Replace the Container App named openwebui (default) in openwebui-ca-env with nginx reverse-proxying to an HTTPS
# upstream that uses a self-signed certificate (proxy_ssl_verify off).
#
# Ingress: default is internal (portal: "Limited to Container Apps environment"). That is expected for private/VNet-only
# setups — not a misconfiguration. Use --ingress-external if you need a public endpoint ("Accepting traffic from anywhere").
#
# Does not create the environment — create a Container Apps environment on a delegated subnet first (Azure CLI or portal).
#
# Usage:
#   ./deploy-containerapps-nginx-proxy.sh -g <rg> -s <sub> [--proxy-upstream URL] [--backend-host name]
#
# Requires: Azure CLI + containerapp extension.
#
# Default image is Microsoft Artifact Registry (Azure Linux nginx) — trusted on Azure, avoids Docker Hub / ECR Public
# throttling during ACA image validation pulls:
#   https://mcr.microsoft.com/en-us/artifact/mar/azurelinux/base/nginx/about
# Override with --image if you use a private ACR copy.

set -eo pipefail

DEFAULT_LOCATION="uksouth"
DEFAULT_ENV_NAME="openwebui-ca-env"
DEFAULT_APP_NAME="openwebui"
DEFAULT_PROXY_UPSTREAM="https://10.179.128.4"
DEFAULT_BACKEND_HOST="10.179.128.4"
DEFAULT_IMAGE="mcr.microsoft.com/azurelinux/base/nginx:1"

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
SUBSCRIPTION="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-$DEFAULT_LOCATION}"
CONTAINER_APPS_ENV_NAME="${CONTAINER_APPS_ENV_NAME:-$DEFAULT_ENV_NAME}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-$DEFAULT_APP_NAME}"
PROXY_UPSTREAM="${PROXY_UPSTREAM:-$DEFAULT_PROXY_UPSTREAM}"
BACKEND_HOST="${BACKEND_HOST:-$DEFAULT_BACKEND_HOST}"
# 0 = internal ingress (default), 1 = external (public) ingress
INGRESS_EXTERNAL="${INGRESS_EXTERNAL:-0}"

usage() {
  cat <<'EOF'
Deploy nginx reverse proxy on Azure Container Apps (replaces existing app; same env as Open WebUI).

Required:
  -g / --resource-group   Container App resource group
  -s / --subscription     Subscription id or name

Optional:
  --environment-name      default: openwebui-ca-env
  --app-name              default: openwebui (this Container App is deleted and recreated)
  --location              default: uksouth
  --proxy-upstream        default: https://10.179.128.4 (PROXY_UPSTREAM)
  --backend-host          Host header to upstream; default: 10.179.128.4 (BACKEND_HOST)
  --image                 default: mcr.microsoft.com/azurelinux/base/nginx:1 (Microsoft Artifact Registry)
  --ingress-external      use external (public) ingress; default is internal ("Limited to Container Apps environment")

The existing Container App is deleted and recreated with nginx only (no Azure Files volumes).

Example (internal ingress — default):
  ./deploy-containerapps-nginx-proxy.sh -g [Resource Group] -s [Subscription]

Example (public / external ingress):
  ./deploy-containerapps-nginx-proxy.sh -g [Resource Group] -s [Subscription] --ingress-external
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
    --environment-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      CONTAINER_APPS_ENV_NAME="$2"
      shift 2
      ;;
    --app-name)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      CONTAINER_APP_NAME="$2"
      shift 2
      ;;
    --location)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      LOCATION="$2"
      shift 2
      ;;
    --proxy-upstream)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      PROXY_UPSTREAM="$2"
      shift 2
      ;;
    --backend-host)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      BACKEND_HOST="$2"
      shift 2
      ;;
    --image)
      [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
      DEFAULT_IMAGE="$2"
      shift 2
      ;;
    --ingress-external)
      INGRESS_EXTERNAL=1
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
      echo "Error: unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: resource group is required (-g or RESOURCE_GROUP)." >&2
  exit 1
fi
if [[ -z "$SUBSCRIPTION" ]]; then
  echo "Error: subscription is required (-s or SUBSCRIPTION_ID)." >&2
  exit 1
fi

command -v az >/dev/null || { echo "Error: Azure CLI (az) not found." >&2; exit 1; }

az_scoped() {
  az "$@" --subscription "$SUBSCRIPTION"
}

if ! az_scoped containerapp env show \
  --name "$CONTAINER_APPS_ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Error: Container Apps environment '$CONTAINER_APPS_ENV_NAME' not found in $RESOURCE_GROUP." >&2
  echo "Create the environment first (e.g. az containerapp env create on a subnet delegated to Microsoft.App/environments, or the portal). See Azure Container Apps networking docs." >&2
  exit 1
fi

MANAGED_ENV_ID=$(az_scoped containerapp env show \
  --name "$CONTAINER_APPS_ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

TMPNGINX=$(mktemp)
TMPYAML=$(mktemp)
trap 'rm -f "$TMPYAML" "$TMPNGINX"' EXIT

# Full nginx.conf (not conf.d fragment): Azure Linux nginx image may not include conf.d/*.conf,
# so a standalone file + `nginx -c` ensures the proxy is actually loaded.
cat >"$TMPNGINX" <<NGINX
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx-proxy.pid;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  types_hash_max_size 2048;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen 80;
    location / {
      proxy_pass ${PROXY_UPSTREAM};
      proxy_ssl_verify off;
      proxy_ssl_server_name off;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host ${BACKEND_HOST};
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
  }
}
NGINX

# Single-line base64 for YAML env (portable macOS/Linux).
NGINX_B64=$(base64 <"$TMPNGINX" | tr -d '\n')

if [[ "$INGRESS_EXTERNAL" -eq 1 ]]; then
  YAML_INGRESS_EXTERNAL=true
  INGRESS_CLI_TYPE=external
else
  YAML_INGRESS_EXTERNAL=false
  INGRESS_CLI_TYPE=internal
fi

write_proxy_yaml() {
  local out="$1"
  {
    cat <<YAML
location: ${LOCATION}
name: ${CONTAINER_APP_NAME}
type: Microsoft.App/containerApps
properties:
  managedEnvironmentId: ${MANAGED_ENV_ID}
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: ${YAML_INGRESS_EXTERNAL}
      targetPort: 80
      transport: Auto
      allowInsecure: false
  template:
    scale:
      minReplicas: 1
      maxReplicas: 1
    containers:
      - name: nginx
        image: ${DEFAULT_IMAGE}
        resources:
          cpu: 0.25
          memory: 0.5Gi
        env:
          - name: NGINX_CONF_B64
            value: "${NGINX_B64}"
YAML
    cat <<'PART'
        command:
          - /bin/sh
          - -c
        args:
          - |
            echo "$NGINX_CONF_B64" | base64 -d > /tmp/nginx-proxy.conf
            exec nginx -c /tmp/nginx-proxy.conf -g 'daemon off;'
PART
  } >"$out"
}

write_proxy_yaml "$TMPYAML"

if az_scoped containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Deleting existing Container App '$CONTAINER_APP_NAME' (replacing with nginx proxy)..."
  az_scoped containerapp delete \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --yes
fi

echo "Creating Container App '$CONTAINER_APP_NAME' (nginx -> $PROXY_UPSTREAM, Host: $BACKEND_HOST)..."
az_scoped containerapp create \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --yaml "$TMPYAML"

# YAML ingress is not always applied by create; enable explicitly after create.
echo "Enabling ${INGRESS_CLI_TYPE} ingress (target port 80, platform TLS)..."
az_scoped containerapp ingress enable \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type "$INGRESS_CLI_TYPE" \
  --target-port 80 \
  --transport auto

echo ""
if [[ "$INGRESS_EXTERNAL" -eq 1 ]]; then
  echo "Done. Public FQDN (HTTPS at ingress; nginx listens on 80 in the container):"
else
  echo "Done. Internal FQDN (HTTPS at ingress; portal shows \"Limited to Container Apps environment\"; nginx on :80):"
fi
az_scoped containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv
