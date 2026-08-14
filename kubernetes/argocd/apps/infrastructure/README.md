# Infrastructure Applications

Notes preserved from in-file comments removed during the comment audit. Sync-wave
ordering itself lives in each file's `argocd.argoproj.io/sync-wave` annotation;
these bullets capture the *why* behind that ordering.

- `cert-manager-config.yaml`: needs cert-manager's CRDs (wave -4) synced first.
- `cilium-config.yaml`: needs Cilium and the Gateway API CRDs already running.
- `cloudflare-tunnel-gateway-controller.yaml`: replaces manual cloudflared
  ConfigMap edits for public routes. Needs the Gateway API CRDs
  (`gateway-api`, wave -5) and Cilium's GatewayClass (`cilium-config`, wave -1).
- `cloudnative-pg.yaml`: needed before any Postgres Cluster CR (e.g. Keycloak's DB).
- `falco.yaml`: needs `monitoring` (wave 0) synced first for the ServiceMonitor CRD.
- `gateway-api.yaml`: CRDs must exist before Cilium's Gateway controller starts.
- `keycloak-operator.yaml`: must exist before the `keycloak` Application (wave 1).
- `keycloak.yaml`: needs `cloudnative-pg` (wave -2) and `keycloak-operator`
  (wave -1) healthy first.
- `knative-serving-crds.yaml`: CRDs must exist before the `knative-serving`
  controller (wave 0).
- `knative-serving.yaml`: wired to the existing Cilium Gateway API stack
  (`homelab-gateway`), not a separate ingress controller.
- `kyverno.yaml`: runs early (wave -2) so policies are in force before workloads sync.
- `longhorn.yaml`: first install uses `helm install --no-hooks` during bootstrap
  to avoid a circular dependency on the pre-upgrade hook's service account. See
  `bootstrap/README.md` steps 1 and 7.
- `metallb-config.yaml`: needs MetalLB's CRDs (wave -3) synced first.
- `sealed-secrets.yaml`: controller installed via `kubectl apply` during bootstrap,
  not Helm. This Application adopts it into ArgoCD afterward. See
  `bootstrap/README.md` step 5.
- `thanos.yaml`: this app is store-gateway/compactor/querier only. The sidecar
  itself runs inside Prometheus, configured in `monitoring/values.yaml`.
