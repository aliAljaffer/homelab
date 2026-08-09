# homelab

My Kubernetes homelab, running on Talos Linux and managed entirely through ArgoCD. Everything is in this repo — if it's not here, it doesn't exist on the cluster.

**Talos:** v1.13.8 (control plane) / v1.13.7 (workers)
**Kubernetes:** v1.36.2
**GitOps:** ArgoCD with App-of-Apps pattern

---

## Nodes

### Control Plane

MacBook Pro Mid-2012 (13") — yes, really.

- **IP:** 192.168.8.99
- **OS:** Talos Linux v1.13.8 (custom kernel build — see [docs/talos-intel-mac.md](docs/talos-intel-mac.md))
- **CPU:** Intel Core i5 (Ivy Bridge)
- **RAM:** 16GB DDR3
- **Storage:** 256GB SATA SSD

### Workers

Four Lenovo M920q Tiny nodes. Fanless-ish, low power, surprisingly capable.

| Node | IP | Status | Storage |
|---|---|---|---|
| wrk0 | 192.168.8.100 | Ready | NVMe |
| wrk1 | 192.168.8.101 | Ready | NVMe |
| wrk2 | 192.168.8.102 | Ready | NVMe |
| wrk3 | 192.168.8.103 | Offline | NVMe |

All workers: Intel Core i5/i7 (8th/9th gen), 16–32GB DDR4, Intel UHD 630 iGPU (exposed via i915 extension for Quick Sync).

### GPU Node (bonus, used for AI workloads)

My main PC, dual-boots Fedora. Joins the cluster on-demand with a `gpu=nvidia` taint.

- **CPU:** AMD Ryzen 7 7800X3D
- **RAM:** 32GB
- **GPU:** RTX 4070 Ti Super
- **Storage:** 3× 2TB NVMe

Build: [PCPartPicker](https://pcpartpicker.com/b/QMRTwP)

---

## Stack

| Layer | What |
|---|---|
| OS | Talos Linux (immutable, API-managed) |
| CNI | Cilium (kube-proxy replacement, Gateway API, Hubble) |
| Ingress | Gateway API + HTTPRoutes (no NGINX) |
| Storage | Longhorn (distributed, 2 replicas) |
| GitOps | ArgoCD (App-of-Apps, 22 applications) |
| Secrets | Sealed Secrets + SOPS (age) |
| Metrics | kube-prometheus-stack + Thanos → MinIO (indefinite retention) |
| Logs | Loki → MinIO (90-day retention) |
| Log collector | Grafana Alloy |
| DNS | Cloudflare (ExternalDNS + cert-manager DNS01) |
| Backups | Velero → GCS |
| Remote access | Cloudflare Access Zero Trust tunnel |

---

## Workloads

- **catus-locatus** — my main app (PostGIS backend, Next.js frontend, MinIO)
- **pihole** — DNS + ad-blocking for the home network
- **tuwaiq-tracker** — CronJob hitting an external API every 12 hours
- **stremio** — media server
- **cloudflared** — Cloudflare Tunnel for public traffic
- **arc** — GitHub Actions self-hosted runners
- **velero** — scheduled cluster backups
- **monitoring** — Grafana, Prometheus, Thanos, Loki, Alloy

---

## Docs

- [Bootstrap runbook](kubernetes/bootstrap/README.md)
- [Backup and restore](docs/backup-and-restore.md)
- [Remote access](docs/remote-access.md)
- [Talos on Intel Mac](docs/talos-intel-mac.md)
