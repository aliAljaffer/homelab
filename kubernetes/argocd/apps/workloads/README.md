# Workload Applications

- `arc.yaml`: ArgoCD only manages the namespaces and the `github-token`
  SealedSecret. The `arc-controller` and `arc-runner-set` Helm releases are
  installed via the Helm CLI, because ArgoCD 2.14 doesn't support OCI Helm
  registries (`ghcr.io`). To upgrade either release:

  ```bash
  helm upgrade arc-controller \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    --version <new-version> --namespace arc-systems

  helm upgrade arc-runner-set \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --version <new-version> --namespace arc-runners
  ```
