# monitoring

- `namespace.yaml`: node_exporter needs hostNetwork/hostPID/hostPath/hostPort, which the cluster-wide PodSecurity baseline default doesn't allow. The namespace labels override it to privileged.
- `networkpolicy.yaml`: highest fan-in/fan-out namespace in the cluster. Apply this last, only after audit mode has been clean on the simpler namespaces for at least a full day (catches daily cronjobs, backup cycles, etc).
  - Thanos (sidecar, storegateway, compactor) and Loki use GCS (bucket `alialjaffer-homelab`, shared with Velero), not an in-cluster MinIO.
  - kubelet/cAdvisor scrape (port 10250) is modeled as Cilium host/remote-node entities, not a namespace selector, it scrapes node IPs directly.
  - GitHub API egress for grafana-github-datasource is assumed to be `api.github.com:443` (standard for that plugin), not confirmed live. Confirm via audit-mode logs if the datasource gets exercised.
- `values.yaml`: static Grafana admin credentials come from a SealedSecret rather than the chart's auto-generated password. Without `admin.existingSecret`, the chart uses Helm's `lookup` to try to reuse the existing password on every render, but ArgoCD's repo-server doesn't have reliable live-cluster access, so `lookup` intermittently comes back empty and silently re-randomizes the password.
