# kepler

- `values.yaml`: Kepler reads RAPL powercap from `/sys` and CPU info from `/proc` via hostPath. On Talos, a privileged pod with hostPath `/sys` reaches the real host `/sys` directly. Do NOT add `kubelet.extraMounts` for `/sys` with `ro+rshared`, it breaks cgroup creation in the kubelet container (CrashLoopBackOff, `mkdir /sys/fs/cgroup/podruntime: no such file or directory`). Full incident in memory-store under `kepler/`.
- `grafana-dashboard.yaml`, `grafana-dashboard-cluster-health.yaml`: live in the `monitoring` namespace, not `kepler`, so the kube-prometheus-stack Grafana sidecar picks them up.
