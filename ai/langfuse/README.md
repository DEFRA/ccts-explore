# Langfuse private AKS POC findings

This folder captures the technical spike used by the AI team to validate Langfuse for organisational/technology fit.

- This is a POC baseline and may be discarded.
- If accepted, this should be formalised with enterprise standards and controls.
- Scripts are intentionally practical, rerunnable but there are no pipelines. It is intended that CD will be delivered if the product is selected for wider organisational consumption.
- External reference: [Langfuse self-hosting documentation](https://langfuse.com/self-hosting).
- It should also be noted that the helm/AKS based deployement was selected with the technical spike in mimd. For a full Enterprise Grade rollout other options (e.g. PaaS based/ CDP based should be evaluated as part of any technical design)

## Design choices captured

- Private AKS with Azure CNI overlay.
- UDR outbound (`--outbound-type userDefinedRouting`) to avoid Public IP creation blocked by policy. 
- `AKS_PRIVATE_DNS_ZONE="none"` with `AKS_DISABLE_PUBLIC_FQDN="false"` for environments where corporate DNS is integrated post-provision.
- Self-managed ingress-nginx with internal LoadBalancer. App Routing Addon deployed ingress was intiaally attempted. Though private networking was selected  the install process attempts to create temporary Public IP resources which is blocked by policy. 
- As this install was part of a time bound Technical Spike self-managed install was used, though it is recommended that any App Routing hurdles are solved for a fuller rollout as this path has much improved vendor support. 
- Langfuse deployed via rerunnable Helm command pattern with Kubernetes secret-backed values.


## Scripts

Located in `ccts-explore/langfuse/scripts/`:

- `01-deploy-private-aks-cni-overlay.sh`
  - Deploy private AKS cluster with CNI overlay and UDR outbound.
- `02-install-ingress-nginx-ilb.ps1`
  - Install ingress-nginx (RBAC + IngressClass + internal LB service).
- `03-install-langfuse-rerunnable.ps1`
  - Add/update Helm repo, create/reuse secrets, and install/upgrade Langfuse.
- `04-apply-langfuse-ingress-https.ps1`
  - Apply HTTPS ingress for Langfuse (IP-based access supported; cert warning expected on raw IP).

## AKS identity permissions for ILB

If ingress service stays `<pending>` and events show `AuthorizationFailed` for subnet actions, grant AKS identity subnet access:

```bash
az role assignment create \
  --assignee-object-id <AKS_IDENTITY_OBJECT_ID> \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "/subscriptions/<subId>/resourceGroups/<vnetRg>/providers/Microsoft.Network/virtualNetworks/<vnetName>/subnets/<subnetName>"
```

Find `<AKS_IDENTITY_OBJECT_ID>` from:

- `kubectl -n ingress-nginx describe svc ingress-nginx-controller` events, or
- Azure CLI query of AKS managed identity.

## Known gotchas

- If signup redirects to `http://localhost:3000`, set `langfuse.nextauth.url` to your real HTTPS ingress URL.
  Example:
  ```powershell
  helm upgrade --install langfuse langfuse/langfuse -n langfuse --reuse-values --set langfuse.nextauth.url="https://<INGRESS_PRIVATE_IP>/"
  kubectl -n langfuse rollout restart deploy/langfuse-web
  ```
- If worker/web logs `WRONGPASS` for Redis, ensure `redis.auth.password` and `langfuse.redis.password` are aligned.
- Password rotation is manual-only for now; automate only with strong guardrails and source-of-truth checks.
