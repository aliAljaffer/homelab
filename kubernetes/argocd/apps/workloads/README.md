# Workload Applications

- `arc.yaml`: manages ARC's controller, namespaces, GitHub App credential and
  PodMonitors. The controller chart comes straight from the `ghcr.io` OCI
  registry (ArgoCD 3.x supports OCI Helm; the old Helm-CLI exception is gone).
- `arc-runners.yaml`: one `gha-runner-scale-set` Helm source per repository.
  See `kubernetes/apps/arc/README.md` for the scale set names and the workflow
  labels they map to.
- `grooszy.yaml` / `nexotv.yaml`: applications outside the auto-discovered
  `kubernetes/apps/*` ApplicationSet, or with custom sync settings.
