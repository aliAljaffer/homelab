# NetworkPolicy audit: namespace-to-namespace traffic map

## Task

Before writing any default-deny NetworkPolicy, map every real namespace-to-
namespace dependency in the cluster so enforcement doesn't drop live traffic.
Two sources were combined:

1. **Live traffic** - Hubble (already deployed, `hubble-relay` in
   `kube-system`) captured via `hubble observe --follow` for ~20 minutes
   across a normal workload period. Raw capture:
   `/private/tmp/claude-501/.../scratchpad/hubble-flows.jsonl` (local scratch,
   not in repo).
2. **Static manifests** - full grep of `kubernetes/apps/*` and
   `kubernetes/infrastructure/*` for cross-namespace Service references,
   HTTPRoute backendRefs, ExternalName Services, CNPG clusters, and OIDC/SSO
   wiring.

Both agreed. Nothing showed up in the static scan that traffic didn't also
confirm, except low-frequency stuff traffic can't catch in a 20-minute window
(see caveats).

## The matrix (source ns -> dest ns : port : reason)

| Source | Destination | Port | Reason |
|---|---|---|---|
| `cloudflare-tunnel-system` | `argocd` | 80 (`argocd-server`) | Gateway API HTTPRoute backend |
| `cloudflare-tunnel-system` | `keycloak` | 8080 (`keycloak-service`) | HTTPRoute backend |
| `cloudflare-tunnel-system` | `monitoring` | 80 (`monitoring-grafana`) | HTTPRoute backend, confirmed live |
| `cloudflare-tunnel-system` | `vaultwarden` | 80 (`vaultwarden`) | HTTPRoute backend |
| `cloudflare-tunnel-system` | `pihole` | 80 (`pihole-web`) | HTTPRoute backend |
| `kube-system` | `longhorn-system` | 80 (`longhorn-frontend`) | HTTPRoute backend (ReferenceGrant already exists: `cilium-config/refgrant-longhorn.yaml`) |
| `kube-system` | `catus-locatus` | 9001 (`minio-svc`) | HTTPRoute backend (MinIO console) |
| `cloudflared` (namespace) | `catus-locatus` | 4001, 9000, 80 | Legacy cloudflared tunnel ingress, confirmed live |
| `cloudflared` / `catus-locatus`'s own cloudflared | `portfolio-website` | 80 | See **flag** below - unmanaged namespace |
| `monitoring` | *every namespace* | component-specific (see below) | Prometheus scraping, confirmed live |
| every namespace | `kube-system` | 53 | CoreDNS, confirmed live, universal |

### `monitoring` -> everywhere (Prometheus scrape targets, confirmed)

`argocd`, `cert-manager`, `cnpg-system` (operator only, port 8080),
`longhorn-system` (9500), `metallb-system` (9120), `kyverno` (8000),
`external-dns` (7979), `velero` (8085), `kepler` (28282),
`cloudflare-tunnel-system` (8081), `arc-systems` (8080), `keycloak`
(9187, postgres-exporter sidecar on the CNPG pods), `catus-locatus` (4001,
static scrape config), `pihole` (9617, static scrape config).

This is Prometheus Operator's default cluster-wide ServiceMonitor/PodMonitor
discovery - there's no `serviceMonitorNamespaceSelector` restriction in
`kubernetes/infrastructure/monitoring/values.yaml`, so it will keep matching
new namespaces as they add a `release: monitoring`-labeled ServiceMonitor.

## What does NOT need a cross-namespace allow

- **`argocd` -> app namespaces**: ArgoCD reconciles through the in-cluster
  Kubernetes API server, not pod-to-pod. No NetworkPolicy needed for
  sync/reconciliation.
- **`velero` -> app namespaces**: backups go through the k8s API and
  node-level CSI/filesystem access (`node-agent` DaemonSet), not pod network.
  No backup hooks (`pre.hook.backup.velero.io`) exist in the repo.
- **`cnpg-system` -> app namespaces**: there is no shared CNPG cluster. Both
  `keycloak` and `catus-locatus` run their own in-namespace `Cluster` CR. The
  operator's only observed traffic is: apiserver -> operator (webhook, 9443),
  operator -> apiserver (6443), and monitoring scraping it (8080).
- **`keycloak` -> anything**: stood up but nothing consumes it as an OIDC
  provider yet (grepped the whole repo for oidc/oauth/keycloak - zero hits
  outside its own directory). No allowance needed today; this will change
  the moment something is wired to it.

## Flags / things to resolve before enforcing

1. **`portfolio-website` namespace doesn't exist in this repo or the live
   cluster**, but both `kubernetes/apps/cloudflared/config.yaml` and
   `kubernetes/apps/catus-locatus/cloudflared/config.yaml` route to
   `portfolio-website-svc.portfolio-website.svc.cluster.local:80`. Find out
   where that namespace actually lives (different cluster? not yet deployed?
   dead config?) before writing a NetworkPolicy that assumes it's local.
2. **CNPG operator-to-instance traffic wasn't observed.** CNPG's operator
   occasionally talks directly to instance-manager pods (port 8000) during
   failover/switchover/backup orchestration - this didn't fire during the
   20-minute capture because no such event happened. Recommend either (a)
   pre-emptively allow `cnpg-system -> {keycloak, catus-locatus}:8000`, or
   (b) run Cilium's `policy-audit-mode` (logs would-be-drops without
   enforcing) for a few days that include a backup cycle before switching to
   enforce.
3. **`stremio`** is exposed directly via MetalLB LoadBalancer
   (`192.168.8.200:8099`), not through either Cloudflare Tunnel path. It's
   reachable straight from the LAN, bypassing Cloudflare entirely. Separate
   issue from NetworkPolicy but worth knowing before assuming Cloudflare
   Tunnel is the only ingress path in the cluster - `pihole` also has two
   LoadBalancer services (`pihole-dns:53`, `pihole-web:80`) alongside its
   HTTPRoute.

## Recommended rollout (don't go straight to default-deny)

1. Turn on Cilium's policy audit mode cluster-wide first
   (`--policy-audit-mode=true` and/or Hubble policy verdicts), which lets you
   see what a policy *would* drop without actually dropping it.
2. Write default-deny + explicit-allow `CiliumNetworkPolicy` per namespace
   using the matrix above, starting with the namespaces that have the
   simplest allow-lists (`vaultwarden`, `pihole`, `keycloak`) before touching
   `monitoring` (highest fan-in/fan-out) or `cloudflare-tunnel-system`
   (breaks all ingress if wrong).
3. Watch Hubble/audit-mode logs for at least one full day (to catch daily
   cronjobs: Velero backup, `tuwaiq-tracker`'s `refresh-db` at `0 */12 * * *`,
   cert-manager renewal checks) before flipping to enforce.
4. Resolve the `portfolio-website` and CNPG-operator flags above first.

## Repo location

New policies should live per-namespace, e.g.
`kubernetes/apps/<app>/networkpolicy.yaml` /
`kubernetes/infrastructure/<component>/networkpolicy.yaml`, added to that
component's existing `kustomization.yaml`. `argocd` and `cloudflare-tunnel-
system` already ship NetworkPolicies from their own Helm charts (see
`kubectl get networkpolicy -A`), so check chart-provided policies aren't
already handling part of this before duplicating.

## Kubeconfig

`$HOME/.kube/homelab-talos` (implicit `kubectl` context used for this audit)

## Update: policies drafted (not yet enforced)

`CiliumNetworkPolicy` manifests exist for all six matrix namespaces now, none
wired into their `kustomization.yaml` yet:

- `kubernetes/apps/vaultwarden/networkpolicy.yaml`
- `kubernetes/apps/pihole/networkpolicy.yaml`
- `kubernetes/infrastructure/keycloak/networkpolicy.yaml`
- `kubernetes/apps/catus-locatus/networkpolicy.yaml`
- `kubernetes/infrastructure/monitoring/networkpolicy.yaml`
- `kubernetes/infrastructure/cloudflare-tunnel-gateway-controller/networkpolicy.yaml`

`kubernetes/bootstrap/cilium/values.yaml` has `policyAuditMode: true` added
but not applied - do the `helm upgrade` (command in the file's header
comment) before wiring any of the above into a `kustomization.yaml`.

Portfolio-website flag resolved: `kubernetes/apps/catus-locatus/cloudflared/
{config.yaml,deployment.yaml}` were dead (never in any kustomization,
referenced a namespace that doesn't exist) - deleted.

### Corrections found while drafting (matter for anyone continuing this)

- **Service port != container port breaks naive policies.** Cilium enforces
  ingress on the pod's real (post-DNAT) port, not the Service's `port`. Found
  two: `cl-fe-svc` is 80 -> targetPort 8080, and `monitoring-grafana` is 80 ->
  targetPort 3000 (named port "grafana"). Confirmed via Hubble, not
  guessed - a policy written against the Service port alone would have
  silently dropped all real traffic to these two once enforced. Check every
  namespace's Services this way before trusting the original matrix's port
  numbers for CiliumNetworkPolicy ingress rules.
- **Thanos and Loki don't use MinIO.** `kubernetes/bootstrap/README.md` Step
  6's example (MinIO/S3) is stale. Both actually back onto GCS, bucket
  `alialjaffer-homelab`, shared with Velero (confirmed from
  `thanos-objstore-secret` and `loki/values.yaml`). Egress for
  prometheus/thanos-storegateway/thanos-compactor/loki is to
  `storage.googleapis.com` / `oauth2.googleapis.com`, not an in-cluster
  MinIO allow.
- **CoreDNS is scraped by monitoring** via the default
  `kube-prometheus-coredns` ServiceMonitor (`kube-system:9153`) - wasn't in
  the original matrix.
- **kube-controller-manager/scheduler/etcd/kube-proxy ServiceMonitors exist
  but have no live Endpoints** on this Talos cluster - no egress needed.
- **kubelet/cAdvisor scrape** goes to node IPs on :10250, modeled as Cilium
  `host`/`remote-node` entities, not a namespace selector.
- **cloudflare-tunnel-system**: the chart already ships a plain
  `NetworkPolicy` for the proxy pods (`proxy.networkPolicy` in values.yaml,
  Ingress-only, admits same-namespace + monitoring on :8081) - didn't
  duplicate it, only added Egress. The controller pod has no chart-shipped
  policy at all. Proxy egress to the Cloudflare edge is UDP/7844 to `world`
  (observed IPs rotate across Cloudflare's anycast pool - not worth pinning
  to a CIDR).
- **minio-console HTTPRoute is broken**: backends to `minio-svc:9001`, but
  `minio-svc.yaml` only exposes port 9000 (the container does listen on
  9001). Pre-existing bug, unrelated to NetworkPolicy - flagging since it
  means the route has never actually worked.
- **Two credential exposures happened while investigating this** (both in
  this chat's transcript, not committed anywhere): a GCP service-account
  private key for `velero@personal-website-4400.iam.gserviceaccount.com`
  (from reading `thanos-objstore-secret` to find its storage backend), and
  the `grafana-discord-webhook` URL (base64, trivially reversible). Rotate
  both if this transcript's exposure is a concern.

### Still open

- Wire the six `networkpolicy.yaml` files into their `kustomization.yaml`s -
  do this only after `policyAuditMode: true` is confirmed live, one
  namespace at a time, simplest first (vaultwarden, pihole, keycloak) per
  the original rollout order.
- Watch audit-mode/Hubble logs for at least a day per namespace, including a
  Velero backup cycle and a pihole gravity update, before flipping
  `policyAuditMode` back to `false` to actually enforce.
- Confirm `api.cloudflare.com` is really what the tunnel controller calls
  (didn't fire during the capture window - no Gateway/HTTPRoute changed).
- Confirm keycloak's SMTP host (set via Admin API at runtime, not in any
  manifest) before adding its egress rule.
- Confirm `grafana-github-datasource` really calls `api.github.com` (assumed
  from the plugin's standard behavior, not observed live).
