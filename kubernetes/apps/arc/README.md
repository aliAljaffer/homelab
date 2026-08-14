# arc

Notes on files where the gotcha isn't obvious from the YAML alone.

- `arc-controller-values.yaml`: applied via helm CLI, not ArgoCD (ghcr.io OCI chart limitation).
  `helm upgrade arc-controller oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --namespace arc-systems --version 0.14.2 -f arc-controller-values.yaml`
  The `metrics:` block is undocumented (absent from `helm show values`, only in `templates/deployment.yaml`). Without it the chart hardcodes metrics off.
- `podmonitor.yaml`: works with no RBAC/TLS setup. Once `metrics:` is enabled in `arc-controller-values.yaml`, the controller and listener pods expose plain HTTP `/metrics` (confirmed live). Neither ARC chart has a serviceMonitor toggle.
- `arc-runner-set-values.yaml`: `githubConfigSecret` points at the SealedSecret in `github-token.sealed.yaml`. Never inline the PAT here.
