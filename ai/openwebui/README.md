# Open WebUI on Azure

This folder is an **exploratory** setup for running **Open WebUI** in a Defra-style spoke VNet.

**Where Open WebUI runs:** use **Azure Container Instances** with **`deploy.sh`** and the JSON templates — **Open WebUI** on port **8080**, optionally fronted in the same group by **Caddy** on **443** using **`tls internal`** (self-signed / internal CA). That is appropriate when you accept browser or client trust warnings for a spike. Caddy is documented in detail below; it is **not** a substitute for standard CCoE ingress (AGW, AFD, CDP, etc.) outside exploratory work.

**Managed TLS at the edge (no self-signed cert on the Container Apps URL):** use **`deploy-containerapps-nginx-proxy.sh`** to run **nginx** on **Azure Container Apps** as a reverse proxy to an **HTTPS** upstream (for example your ACI/Caddy **private** endpoint). **Ingress** on the Container App uses a **platform-managed certificate** on the ACA FQDN. The upstream may still use a self-signed certificate; nginx is configured with **`proxy_ssl_verify off`**. 

**Why not run everything in Container Apps** Running Open WebUI **on** Container Apps with **Azure Files** for persistence was **unreliable** in evaluation (mount and file-locking behaviour). Use **ACI** for the app data path; use **ACA + nginx** only if you want a stable managed-TLS entry point in front of a separate backend. Other options are available to allow Open WebUI to run reliably in Container Apps (e.g. use a PaaS database rather than local), however this was out of scope for this short spike effort.

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

## Templates and scripts in this folder

| File | What it deploys | Storage | Notes |
|------|-----------------|---------|--------|
| `openwebui-snd1.json` | ACI group `openwebui-snd1` | Azure Files (`openwebui-data-test` in template) | Default for `deploy.sh`. Replace **`<subscription-id>`**, **`<vnet-resource-group>`**, **`<vnet-name>`**, **`<subnet-name>`** in **`subnetIds`**, and **`<spoke-dns-*>`** in **`dnsConfig`**, with values for your environment (see **plt-config** for spoke **`dnsServers`**). |
| `deploy-containerapps-nginx-proxy.sh` | Container App (default name `openwebui`) | None — nginx only | **Deletes and recreates** the app in an **existing** Container Apps environment (default env name `openwebui-ca-env`). Proxies to **`--proxy-upstream`** with **`--backend-host`** for `Host`. See **Azure Container Apps: nginx reverse proxy**. |

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

## Azure Container Apps: nginx reverse proxy

Use **`deploy-containerapps-nginx-proxy.sh`** when you want **HTTPS to clients** using the **Container Apps ingress** certificate (managed by the platform on the app FQDN), while the **origin** is a private HTTPS service that may use a **self-signed** certificate (for example Open WebUI + Caddy on ACI).

**What it does**

- Requires a Container Apps **environment** that **already exists** — the script does **not** create it (it exits if the env is missing).
- **Deletes** the target Container App if present and **creates** it again as a single **nginx** container (default image `mcr.microsoft.com/azurelinux/base/nginx:1`).
- Injects a full **`nginx.conf`** at startup and enables **ingress** on port **80** in the container; **TLS** is **not** terminated inside nginx — **ingress** presents **HTTPS** to clients (`transport: auto`).
- Sets **`proxy_ssl_verify off`** and **`proxy_ssl_server_name off`** toward the upstream so a self-signed backend still works.
- Default **`--proxy-upstream`** / **`--backend-host`** point at a private IP; override for your ACI/Caddy address.

**Prerequisites**

- Azure CLI **`containerapp`** extension: `az extension add --name containerapp --upgrade`
- A Container Apps **environment** in your subscription (internal or external as designed), on a subnet **delegated** to **`Microsoft.App/environments`**. Create it with the portal or **`az containerapp env create`** — see [Networking in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/networking) and [VNet integration](https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom).
- Network path from the ACA environment to your **upstream** (private IP or DNS name).

**Deploy**

```bash
./deploy-containerapps-nginx-proxy.sh --help

# Internal ingress (portal: "Limited to Container Apps environment") — default
./deploy-containerapps-nginx-proxy.sh -g '<container-app-rg>' -s '<subscription-id-or-name>'

# Public FQDN / external ingress (managed cert on the public ACA hostname)
./deploy-containerapps-nginx-proxy.sh -g '<container-app-rg>' -s '<subscription-id-or-name>' --ingress-external

# Custom upstream (HTTPS URL) and Host header sent to the backend
./deploy-containerapps-nginx-proxy.sh -g '<rg>' -s '<sub>' \
  --proxy-upstream 'https://10.179.128.4' \
  --backend-host '10.179.128.4'
```

Optional: **`--environment-name`**, **`--app-name`**, **`--location`**, **`--image`**, or **`INGRESS_EXTERNAL=1`** instead of **`--ingress-external`**.

The script prints the app **FQDN** when finished. For **internal** ingress, use **`https://`** from the VNet; corporate trust policies may still apply.

When pasting commands into zsh, avoid copying the shell prompt — a stray **`%`** can break the line.
