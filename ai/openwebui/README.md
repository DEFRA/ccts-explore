# Open WebUI on Azure Container Instances

**Azure Container Instances:** multi-container group with **Open WebUI** (port 8080) and **Caddy** (HTTPS on 443) in a spoke VNet — use `deploy.sh` and the JSON templates in this folder.

**Azure Container Apps:** single-container **Open WebUI** only; **internal** environment (no public ingress); **HTTPS** terminated at the Container Apps ingress (no Caddy). Same image, CPU/memory, environment variables, and **Azure Files** share defaults as the ACI template — use `deploy-containerapps.sh`.

Detail of Caddy below as this may be a useful pattern for other expore services requiring https. It is NOT promoted as an alternative for CCoE standard ingres patterns outside of expolorotory work. 

---

## Caddy sidecar (HTTPS on a private IP)

OpenWebUI is being deployed for evaluation purposes only. As such it has not yet been through architectural review, and thus cannot sit behind the formal CCoE AGW/AFD infrastructure.

For speed of delivery Azure Container Instances have been used to evaluate the product. Though this is a technical spike with dummy data only, a basic level of encryption is required on the wire. To satisfy this requirement a self-signed certificate is deployed with Caddy (deployed as a side car) managing the encrypted traffic.

Should the product be positioned for wider Defra rollout, then standard CCoE approved architectural patterns should be used e.g. AKS Ingress, CDP, AFD or AGW etc. The standard defra.cloud certificate should be used to secure the internal traffic rather than a self signed certificate.

The Caddy container runs a **startup command** that:

1. **Detects the container group’s private IP** at runtime.
2. **Writes a Caddyfile** to `/etc/caddy/Caddyfile` that configures HTTPS on port 443 and reverse-proxies to Open WebUI.
3. **Starts Caddy** with that config.

### Why this pattern is needed

| Topic | Detail |
|--------|--------|
| **Private IP only** | No public FQDN, so Caddy cannot use Let’s Encrypt. Use **`tls internal`** (self-signed / local CA). |
| **Override default Caddyfile** | The official `caddy` image ships a Caddyfile on **port 80** only. This deployment needs **443** and a custom site block, so the file is generated at startup instead of using the image default. |
| **Access by IP and localhost** | Clients may use `https://<private-ip>` or `https://localhost` from inside the group. The internal cert must include those identities. The command adds `:443`, `localhost:443`, and **`<detected-ip>:443`** to the site address. |
| **Backend via `localhost`** | In ACI, containers in one group **share a network namespace**. Caddy uses **`reverse_proxy localhost:8080`** so it does not rely on DNS for the `openwebui` container name (avoids resolution delays and 502s). |

### Startup command (step by step)

| Step | Purpose |
|------|--------|
| `IP=$(ip -4 -o addr show ... \|\| ip route get 1.1.1.1 ... \|\| hostname -i ...)` | Resolve primary IPv4 (interface first, then outbound source, then hostname). Works in private VNets without relying on public routing. |
| `[ -n "$IP" ] && ADD=", $IP:443" \|\| ADD=""` | If an IP was found, append `, <IP>:443` to the site list in the Caddyfile. |
| `printf '...' "$ADD" > /etc/caddy/Caddyfile` | Write the Caddyfile: `:443`, `localhost:443`, optional `<IP>:443`; **`tls internal`**; **`reverse_proxy localhost:8080`**. |
| `exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile` | Run Caddy with **`exec`** so it replaces the shell and receives signals correctly. |

### Resulting Caddyfile (conceptual)

```text
:443, localhost:443[, <detected-IP>:443] {
    tls internal
    reverse_proxy localhost:8080
}
```

### Volume mounts (Caddy)


| Volume (emptyDir) | Mount path | Role |
|-------------------|------------|------|
| `proxy-caddyfile` | `/etc/caddy` | Generated Caddyfile |
| `proxy-data` | `/data` | Caddy TLS / PKI storage |
| `proxy-config` | `/config` | Caddy autosave / runtime config |

---

## Open WebUI: persistent storage and caches

Recommended for all but the smallest of trials. Azure Container Instances can and does restart without request. Without persistence all configuration is lost.

Azure Container Instances supports Azure Files for storage persistence. Azure Files should be presented on the the same VNet as a Private End Point. Storage outside the spoke (including Azure Files accessed over Public Interfaces - where allowed) traverse the Hub Firewalls. ACI may fail to negotiate and present the storage due to TLS inspection. An exception can be put in place for TLS inspection, however presenting a PEP within the spoke VNet avoids this configuration.

- **Azure Files** mounted at **`/app/backend/data`** (same idea as Docker `-v open-webui:/app/backend/data`).
- **Storage account key**: not committed; `deploy.sh` injects **`STORAGE_ACCOUNT_KEY`** (or fetches via **`STORAGE_ACCOUNT_RESOURCE_GROUP`**). `az container show` shows `storageAccountKey: null` — that is normal (secret redaction).
- **Hugging Face / embedding caches**: Azure Files **does not support symlinks**. Point **`HF_HOME`** and **`SENTENCE_TRANSFORMERS_HOME`** at **`/tmp/...`** (or another **local** path) so hub caches are not on the share.

Account Keys have been used in this evaluation due to ACI support. It is unlikely that ACI would be used in a Production hosting strategy.

Create the file share before first deploy (example):

```bash
az storage share create \
  --name <share-name> \
  --account-name <storage-account> \
  --resource-group <storage-account-rg>
```

---

## Templates in this folder

| File | Container group | Storage | Notes |
|------|-----------------|---------|--------|
| `openwebui-snd1.json` | `openwebui-snd1` | Azure Files (`openwebui-data-test` in template) | Default for `deploy.sh`. Replace **`<subscription-id>`**, **`<vnet-resource-group>`**, **`<vnet-name>`**, **`<subnet-name>`** in **`subnetIds`**, and **`<spoke-dns-*>`** in **`dnsConfig`**, with values for your environment (see **plt-config** for spoke **`dnsServers`**). |
| `deploy-containerapps.sh` | `CONTAINER_APP_NAME` (default `openwebui`) | Same share/account defaults as above | No JSON file; script creates/updates the Container Apps env + app. Requires a **delegated** ACA subnet ARM ID unless `--skip-env-create`. |

Add other JSON files (e.g. local-only, other environments) alongside and pass them as the template argument to `deploy.sh` (after the required scope flags).

---

## Deploy

**Subscription and container resource group are not defaulted** (so names and IDs are not committed). You must pass them every time, or set them in the environment for that shell session.

From this directory:

```bash
# Required: where the container group lives and which subscription to use (-g / -s)
CONTAINER_RG='<your-aci-resource-group>'
SUB='<subscription-id-or-name>'

# Default template openwebui-snd1.json — with key in env
export STORAGE_ACCOUNT_KEY='<key>'
./deploy.sh -g "$CONTAINER_RG" -s "$SUB"

# Or fetch the storage key (see deploy.sh for the storage account name used in that call)
export STORAGE_ACCOUNT_RESOURCE_GROUP='<storage-account-rg>'
./deploy.sh -g "$CONTAINER_RG" -s "$SUB"

# Another template file in this folder
./deploy.sh -g "$CONTAINER_RG" -s "$SUB" other-template.json
```

Equivalent without flags (handy for local `.env` or CI secrets):

```bash
export RESOURCE_GROUP='<your-aci-resource-group>'
export SUBSCRIPTION_ID='<subscription-id-or-name>'
export STORAGE_ACCOUNT_KEY='<key>'   # if the template uses Azure Files
./deploy.sh
```

If a template omits Azure Files, you do not need **`STORAGE_ACCOUNT_KEY`**.

Run **`./deploy.sh --help`** for a short usage summary.

---

## Azure Container Apps (private, platform HTTPS)

Use this when you want **Container Apps** instead of ACI: **no public endpoint** on the environment (`--internal-only`), and **TLS** handled by the **ingress proxy** (`transport: Auto`), not a Caddy sidecar. The app still mounts **Azure Files** at **`/app/backend/data`** (defaults: storage account **`containerinstance`**, share **`openwebui-containerapp`**, env storage mount name **`openwebui-data`** — override with flags or env vars).

**Prerequisites**

- Azure CLI **`containerapp`** extension: `az extension add --name containerapp --upgrade`
- A subnet **delegated** to **`Microsoft.App/environments`**, sized per [VNet integration guidance](https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom) (this is **not** the same subnet as the ACI `subnetIds` entry unless you deliberately use one subnet for both patterns).
- **SMB (default):** storage account key via **`STORAGE_ACCOUNT_KEY`** or **`STORAGE_ACCOUNT_RESOURCE_GROUP`**, or **`--storage-account-key`** / **`--storage-account-resource-group`**.

**NFS instead of SMB (Azure Files Premium)**

Container Apps can mount **NFS** Azure Files (`NfsAzureFile`), which uses a different code path than SMB and may behave better for workloads sensitive to file locking (e.g. SQLite). This is **not** the same share type as a typical **standard** SMB share: you need a **Premium** storage account, a file share created with protocol **NFS**, the Container Apps environment on a **VNet**, and the storage account allowing access from that VNet (service endpoint or private endpoint). Disable **Secure transfer required** on the storage account for NFS. See [Use storage mounts in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts?tabs=nfs) (NFS tab) and the practical walkthrough [Setting up a NFS volume with Azure Container Apps](https://azureossd.github.io/2025/10/17/Setting-up-a-NFS-volume-with-Azure-Container-Apps/).

Deploy with **`--nfs`** (or **`STORAGE_PROTOCOL=nfs`**). The script registers the share path as **`/STORAGE_ACCOUNT_NAME/FILE_SHARE_NAME`** unless you set **`--nfs-share-path`**. **`--nfs-server`** defaults to **`STORAGE_ACCOUNT_NAME.file.core.windows.net`**. A storage key is usually **not** required for NFS; upgrade the **`containerapp`** CLI extension if **`--storage-type NfsAzureFile`** is rejected.

**Deploy**

```bash
./deploy-containerapps.sh --help

# Create internal env + app (pass your Container Apps infrastructure subnet ARM ID)
export STORAGE_ACCOUNT_KEY='<key>'
./deploy-containerapps.sh \
  -g '<container-apps-rg>' \
  -s '<subscription-id-or-name>' \
  --infrastructure-subnet-id '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<aca-subnet>'

# Environment already exists
./deploy-containerapps.sh -g '<rg>' -s '<sub>' --skip-env-create

# NFS Premium share (no storage key required; VNet + Premium NFS share must exist first)
./deploy-containerapps.sh -g '<rg>' -s '<sub>' --skip-env-create --nfs \
  --storage-account-name '<premium-nfs-account>' \
  --file-share-name '<nfs-share-name>'
```

Optional: **`CONTAINER_APPS_ENV_NAME`**, **`CONTAINER_APP_NAME`**, **`LOCATION`**, **`STORAGE_ACCOUNT_NAME`**, **`FILE_SHARE_NAME`**, **`ENV_STORAGE_NAME`**, **`STORAGE_PROTOCOL`**, **`--nfs`**, **`--nfs-server`**, **`--nfs-share-path`** (see **`--help`**).

After a successful run, the script prints the app’s **internal FQDN**; use **`https://`** from inside the VNet (platform-managed certificate on the `*.internal.*.azurecontainerapps.io` hostname). If **`az rest` PATCH** fails on your tenant API version, adjust the `api-version` in `deploy-containerapps.sh` or apply the volume mount once via the portal / exported YAML as in [Azure Files mounts](https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts-azure-files).

When pasting commands into zsh, avoid including the prompt (e.g. **`openwebui %`**) — a trailing **`%`** can be parsed as an extra argument; the script warns and drops a lone **`%`** / **`#`**, but a line like **`… 'RG'openwebui`** (missing newline before the prompt) can still break quoting.

---

## Troubleshooting

**Subscription “misspelled” on `storage account keys list` after `deploy-containerapps.sh` prints “Fetching storage account key…”**  
Login is often correct: some Azure CLI builds mishandle a global **`--subscription`** placed immediately after **`az`** when the next group is **`storage`**. The script now passes **`--subscription`** at the **end** of the command (same pattern as **`deploy.sh`**). Pull the latest **`deploy-containerapps.sh`** or upgrade Azure CLI if you still see it.

```bash
az container show -g <rg> -n <container-group> --query "containers[].{name:name,state:instanceView.currentState.state,detail:instanceView.currentState.detailStatus}" -o table
az container show -g <rg> -n <container-group> -o json --query "containers[].instanceView"
az container logs -g <rg> -n <container-group> --container openwebui
az container logs -g <rg> -n <container-group> --container caddy
```

**Browser TLS warnings** with **`tls internal`**: expected until the local CA is trusted or you use a corporate PKI / public hostname.

**Container Apps** (internal ingress uses a platform cert on the internal FQDN; corporate trust policies may still warn):

```bash
az containerapp show -g <rg> -n <app> --query "{state:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn}" -o yaml
az containerapp logs show -g <rg> -n <app> --follow
```

