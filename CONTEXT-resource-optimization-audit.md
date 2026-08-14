# Resource optimization audit: requests/limits gap + sizing from real usage

## Task

Every Deployment/StatefulSet/DaemonSet container must have CPU and memory
requests and limits set. Where usage was unknown, VPA in recommend mode was
the fallback option. Baseline usage must be recorded before any change, so
it can be compared against after.

## Method

1. `kubectl get deploy,sts,ds -A -o json` for the full container inventory
   (95 containers across 21 namespaces).
2. `kubectl top pods -A --containers` for an instant snapshot (baseline,
   timestamped `2026-08-14T06:21:54Z`, stored at
   `/private/tmp/.../scratchpad/top-containers-snapshot.txt`, not in repo).
3. Prometheus/Thanos (already deployed, `monitoring` namespace) queried via
   port-forward to `thanos-query:9090` for **3-day** history:
   - `quantile_over_time(0.95, rate(container_cpu_usage_seconds_total[5m])[3d:1m])`
   - `max_over_time(container_memory_working_set_bytes[3d])`
4. First attempt used a 14-day window and produced physically impossible
   values (e.g. argocd-application-controller at 573 cores on a 28-core
   cluster) - a Thanos downsampling artifact where `rate()` over a subquery
   crosses the raw-to-5m-downsampled boundary. Dropped to 3d, which stays
   inside raw retention and matches sane values (cross-checked against
   `kubectl top` and cluster capacity).
5. Joined usage data to workloads by matching pod name prefix against known
   workload names per namespace, took max across replicas/duplicate cgroup
   `id` labels. All 95 containers matched (0 unmatched) once ephemeral
   Velero backup/job pods were correctly excluded (their container names
   are per-backup UUIDs, not the daemonset/deployment name, so they never
   matched by construction - no manual namespace exclusion needed).
6. **VPA was not installed.** All 66 gap containers already had 3 days of
   real usage in Prometheus, which is a better signal than a freshly
   installed VPA would produce (VPA needs its own observation window before
   its recommendations are trustworthy, and Kubernetes' own recommendation:
   VPA in recommend-mode is really for once-unknown workloads; here every
   container already had a signal). No genuinely "unknown" application
   surfaced: the actual custom apps (`catus-locatus`, `stremio`,
   `vaultwarden`, `pihole`, `cloudflared`, `tuwaiq-tracker`'s CronJob) had
   already had requests/limits set by hand. VPA remains an option later if
   ongoing auto-recommendation is wanted; not needed for this pass.

## Findings

**95 containers total, across 21 namespaces. 66 are missing requests
*and* limits entirely (not partial). 3 more are missing only limits**
(`metrics-server`, `alertmanager`, `alloy`'s `config-reloader` - all have
requests set, no limit). None of the 66-gap set are custom/unknown apps -
all are third-party Helm-chart-installed cluster infrastructure that never
had `resources:` set in the chart's `values.yaml`.

Already fully specified (no action needed): `catus-locatus` (cl-be/cl-fe),
`stremio`, `vaultwarden`, `pihole`, `cloudflared`,
`cloudflare-tunnel-gateway-controller`(-proxy), `kepler`, `keycloak` +
`keycloak-operator`, all of `knative-serving`, `kubelet-serving-cert-approver`,
`kyverno-*` (memory only, no CPU limit - a defensible choice, not flagged),
`coredns` (same), `loki-chunks-cache`/`loki-results-cache` memcached, and
the `tuwaiq-tracker` `refresh-db` CronJob.

### Full gap list with usage-derived recommendations

Sizing formula (memory: 1.3x max observed for request, 1.8x for limit,
floor 16Mi/32Mi; CPU: 1.2x p95 for request, 3x p95 for limit, floor 5m/20m):
see `/private/tmp/.../scratchpad/gap_recommendations.json` for the
machine-readable version (this session's scratchpad; regenerate via
`join.py` + `recommend.py` in the same directory if needed later).

| Namespace | Workload | Container | P95 CPU (3d) | Max Mem (3d) | -> Request | -> Limit |
|---|---|---|---|---|---|---|
| arc-systems | arc-controller-gha-rs-controller | manager | 1m | 66Mi | 5m/88Mi | 20m/176Mi |
| argocd | argocd-application-controller | application-controller | 397m | 1166Mi | 480m/1520Mi | 1440m/3040Mi |
| argocd | argocd-applicationset-controller | applicationset-controller | 4m | 58Mi | 5m/80Mi | 20m/160Mi |
| argocd | argocd-dex-server | dex-server | 1m | 32Mi | 5m/48Mi | 20m/96Mi |
| argocd | argocd-notifications-controller | notifications-controller | 2m | 67Mi | 5m/88Mi | 20m/176Mi |
| argocd | argocd-redis | metrics | 1m | 10Mi | 5m/16Mi | 20m/32Mi |
| argocd | argocd-redis | redis | 3m | 92Mi | 5m/120Mi | 20m/240Mi |
| argocd | argocd-repo-server | repo-server | 54m | 291Mi | 65m/384Mi | 195m/768Mi |
| argocd | argocd-server | server | 3m | 299Mi | 5m/392Mi | 20m/784Mi |
| catus-locatus | minio | minio | 2m | 151Mi | 5m/200Mi | 20m/400Mi |
| cert-manager | cert-manager | cert-manager-controller | 1m | 87Mi | 5m/120Mi | 20m/240Mi |
| cert-manager | cert-manager-cainjector | cert-manager-cainjector | 4m | 130Mi | 5m/176Mi | 20m/352Mi |
| cert-manager | cert-manager-webhook | cert-manager-webhook | 0m | 58Mi | 5m/80Mi | 20m/160Mi |
| cnpg-system | cloudnative-pg | manager | 10m | 74Mi | 15m/104Mi | 45m/208Mi |
| external-dns | external-dns | external-dns | 3m | 109Mi | 5m/144Mi | 20m/288Mi |
| kube-system | cilium | cilium-agent | 103m | 430Mi | 125m/560Mi | 375m/1120Mi |
| kube-system | cilium-envoy | cilium-envoy | 8m | 64Mi | 10m/88Mi | 30m/176Mi |
| kube-system | cilium-operator | cilium-operator | 4m | 143Mi | 5m/192Mi | 20m/384Mi |
| kube-system | hubble-relay | hubble-relay | 27m | 30Mi | 35m/40Mi | 105m/80Mi |
| kube-system | hubble-ui | backend | 23m | 52Mi | 30m/72Mi | 90m/144Mi |
| kube-system | hubble-ui | frontend | 0m | 12Mi | 5m/16Mi | 20m/32Mi |
| kube-system | metrics-server | metrics-server | 6m | 81Mi | 10m/112Mi (has req, add limit) | 30m/224Mi |
| kube-system | sealed-secrets-controller | sealed-secrets-controller | 0m | 68Mi | 5m/96Mi | 20m/192Mi |
| kube-system | snapshot-controller | snapshot-controller | 0m | 39Mi | 5m/56Mi | 20m/112Mi |
| longhorn-system | csi-attacher | csi-attacher | 1m | 62Mi | 5m/88Mi | 20m/176Mi |
| longhorn-system | csi-provisioner | csi-provisioner | 2m | 48Mi | 5m/64Mi | 20m/128Mi |
| longhorn-system | csi-resizer | csi-resizer | 0m | 59Mi | 5m/80Mi | 20m/160Mi |
| longhorn-system | csi-snapshotter | csi-snapshotter | 3m | 57Mi | 5m/80Mi | 20m/160Mi |
| longhorn-system | engine-image-ei-a4d05f02 | engine-image-ei-a4d05f02 | 20m | 14Mi | 25m/24Mi | 75m/48Mi |
| longhorn-system | engine-image-ei-db6c2b6f | engine-image-ei-db6c2b6f | 23m | 16Mi | 30m/24Mi | 90m/48Mi |
| longhorn-system | longhorn-csi-plugin | longhorn-csi-plugin | 1m | 54Mi | 5m/72Mi | 20m/144Mi |
| longhorn-system | longhorn-csi-plugin | longhorn-liveness-probe | 0m | 28Mi | 5m/40Mi | 20m/80Mi |
| longhorn-system | longhorn-csi-plugin | node-driver-registrar | 0m | 6Mi | 5m/16Mi | 20m/32Mi |
| longhorn-system | longhorn-driver-deployer | longhorn-driver-deployer | 0m | 10Mi | 5m/16Mi | 20m/32Mi |
| longhorn-system | longhorn-manager | longhorn-manager | 50m | 295Mi | 60m/384Mi | 180m/768Mi |
| longhorn-system | longhorn-manager | pre-pull-share-manager-image | 0m | 4Mi | 5m/16Mi | 20m/32Mi |
| longhorn-system | longhorn-ui | longhorn-ui | 0m | 4Mi | 5m/16Mi | 20m/32Mi |
| metallb-system | metallb-controller | controller | 2m | 178Mi | 5m/232Mi | 20m/464Mi |
| metallb-system | metallb-frr-k8s | controller | 2m | 24Mi | 5m/32Mi | 20m/64Mi |
| metallb-system | metallb-frr-k8s | frr | 2m | 43Mi | 5m/56Mi | 20m/112Mi |
| metallb-system | metallb-frr-k8s | frr-metrics | 11m | 38Mi | 15m/56Mi | 45m/112Mi |
| metallb-system | metallb-frr-k8s | frr-status | 1m | 19Mi | 5m/32Mi | 20m/64Mi |
| metallb-system | metallb-frr-k8s | reloader | 1m | 7Mi | 5m/16Mi | 20m/32Mi |
| metallb-system | metallb-frr-k8s-statuscleaner | frr-k8s-statuscleaner | 4m | 19Mi | 5m/32Mi | 20m/64Mi |
| metallb-system | metallb-speaker | speaker | 15m | 37Mi | 20m/56Mi | 60m/112Mi |
| monitoring | alertmanager-kube-prometheus-alertmanager | alertmanager | 1m | 38Mi | (has req, add limit) | 20m/112Mi |
| monitoring | alertmanager-kube-prometheus-alertmanager | config-reloader | 0m | 16Mi | 5m/24Mi | 20m/48Mi |
| monitoring | alloy | alloy | 46m | 442Mi | 60m/576Mi | 180m/1152Mi |
| monitoring | alloy | config-reloader | 0m | 36Mi | (has req, add limit) | 20m/96Mi |
| monitoring | kube-prometheus-operator | kube-prometheus-stack | 11m | 35Mi | 15m/48Mi | 45m/96Mi |
| monitoring | loki | loki | 58m | 429Mi | 70m/560Mi | 210m/1120Mi |
| monitoring | loki | loki-sc-rules | 12m | 76Mi | 15m/104Mi | 45m/208Mi |
| monitoring | loki-canary | loki-canary | 14m | 45Mi | 20m/64Mi | 60m/128Mi |
| monitoring | loki-chunks-cache | exporter | 6m | 20Mi | 10m/32Mi | 30m/64Mi |
| monitoring | loki-gateway | nginx | 5m | 15Mi | 10m/24Mi | 30m/48Mi |
| monitoring | loki-results-cache | exporter | 3m | 20Mi | 5m/32Mi | 20m/64Mi |
| monitoring | monitoring-grafana | grafana | 38m | 673Mi | 50m/880Mi | 150m/1760Mi |
| monitoring | monitoring-grafana | grafana-sc-dashboard | 20m | 100Mi | 25m/136Mi | 75m/272Mi |
| monitoring | monitoring-grafana | grafana-sc-datasources | 20m | 78Mi | 25m/104Mi | 75m/208Mi |
| monitoring | monitoring-kube-state-metrics | kube-state-metrics | 17m | 78Mi | 25m/104Mi | 75m/208Mi |
| monitoring | monitoring-prometheus-node-exporter | node-exporter | 5m | 28Mi | 10m/40Mi | 30m/80Mi |
| monitoring | prometheus-kube-prometheus-prometheus | config-reloader | 0m | 17Mi | 5m/24Mi | 20m/48Mi |
| monitoring | prometheus-kube-prometheus-prometheus | prometheus | 150m | 2935Mi | 180m/3816Mi | 540m/7632Mi |
| monitoring | prometheus-kube-prometheus-prometheus | thanos-sidecar | 3m | 131Mi | 5m/176Mi | 20m/352Mi |
| monitoring | thanos-compactor | compactor | 24m | 1763Mi | 30m/2296Mi | 90m/4592Mi |
| monitoring | thanos-query | query | 7m | 198Mi | 10m/264Mi | 30m/528Mi |
| monitoring | thanos-storegateway | storegateway | 4m | 488Mi | 5m/640Mi | 20m/1280Mi |
| velero | node-agent | node-agent | 11m | 96Mi | 15m/128Mi | 45m/256Mi |
| velero | velero | velero | 11m | 301Mi | 15m/392Mi | 45m/784Mi |

### Cluster capacity sanity check

5 nodes: cp0 (4 CPU/16Gi), wrk0-3 (6 CPU/16Gi each) = 28 CPU / ~80.8Gi total.
Current per-node usage (instant, `kubectl top nodes`): 19-57% CPU,
29-48% memory - headroom exists on every node.

Adding all 66 recommended **requests** sums to **1.7 CPU / 16.4Gi memory**
cluster-wide (6% / 20% of total capacity) - this mostly reflects memory
*already being consumed* today by unconstrained pods (Prometheus, Thanos
compactor, Grafana, argocd-application-controller are the big four), not
new demand. Limits are not summed/reserved by the scheduler, so their sum
(5.3 CPU / 32.8Gi) is informational only, not a capacity commitment.

One flag: `kubectl describe nodes` shows one worker already at 78-92%
memory *request* utilization from the handful of workloads that already
have requests set (loki-chunks-cache's 9830Mi memcached request is the
main driver). Worth spreading the new memory-heavy requests (prometheus,
thanos-compactor, argocd-application-controller) across nodes via
topology/anti-affinity if they end up landing on the same already-tight
node - check after applying, not before (nothing to fix yet, just a watch
item).

## Risk flags on specific components (control-plane / critical path)

These three carry outsized blast radius if the limit is too tight (OOMKill
during high load), given they gate other cluster operations:

- `argocd-application-controller` - if OOMKilled during a large sync, GitOps
  reconciliation stalls cluster-wide until it recovers. Limit set to 2.6x
  observed max (3040Mi vs 1166Mi seen). ArgoCD's own upstream default
  recommendation for larger repos is 1-2Gi+ requests; 1520Mi request is in
  that range.
- `argocd-repo-server` - only 291Mi observed max over 3 days, but repo-server
  memory can spike hard during Helm chart templating for large charts
  (kube-prometheus-stack is in this repo). 768Mi limit may be tight under a
  big sync burst; worth widening safety margin here specifically before
  applying (e.g. 4x instead of 2.6x -> ~1.2Gi limit) since a 3-day window
  may not have captured a worst-case sync.
- `cilium-agent` - if OOMKilled, node networking for all pods on that node
  breaks until restart. 1120Mi limit vs 430Mi observed (2.6x) - probably
  fine, flagging because impact-if-wrong is highest of anything in this list.

## Decision (confirmed with user)

- **Rollout: single pass**, all ~15 charts in one sweep. Margins were judged
  generous enough (2.6-3x observed peak on limits; the 16.4Gi memory request
  total mostly formalizes usage already happening unconstrained today) to
  not need a phased rollout.
- **`argocd-repo-server` limit widened** beyond the standard formula: 1.2Gi
  instead of the formula's 768Mi, since repo-server memory spikes hard
  during Helm chart templating and the 3-day window may not have caught a
  worst-case sync. Request stays at the formula's 384Mi.

## Remaining work

Editing ~15 Helm `values.yaml` files (argocd, cilium, cert-manager,
external-dns, longhorn, metallb, kube-prometheus-stack, loki, alloy, velero,
cnpg, sealed-secrets, snapshot-controller, arc) - checking each chart
actually exposes a `resources:` key for every sub-component listed before
editing (some CSI sidecars / metallb's `frr-k8s` subchart may have limited
exposure).
