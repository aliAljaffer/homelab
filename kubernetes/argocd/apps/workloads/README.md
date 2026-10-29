# Workload Applications

- `arc.yaml`: ARC's controller via ArgoCD, from the `ghcr.io` OCI Helm chart
  (0.14.2), plus the namespaces, GitHub App credential and PodMonitors in
  `kubernetes/apps/arc`. CRDs are applied with server-side apply to avoid the
  256 KB last-applied annotation limit.
- `arc-runner-chat-gateway.yaml`: the single `gha-runner-scale-set` used by
  `aliAljaffer/chat-gateway`. fai/grooszy remain on GitHub-hosted runners. See
  `kubernetes/apps/arc/README.md`.
- `grooszy.yaml` / `nexotv.yaml`: applications outside the auto-discovered
  `kubernetes/apps/*` ApplicationSet, or with custom sync settings.
