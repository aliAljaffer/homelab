# homelab

My Kubernetes homelab, running on Talos Linux and managed entirely through ArgoCD. Everything is in this repo - if it's not here, it doesn't exist on the cluster.

**Talos:** v1.13.8 (control plane) / v1.13.7 (workers)
**Kubernetes:** v1.36.2

---

## Nodes

### Control plane

MacBook Pro Mid-2012 (13"). Yes, really.

It runs `cp0` at `192.168.8.99` with a custom-built Talos kernel because Apple's EFI firmware rejects the LLD-compiled kernel that ships in v1.13.0+. Intel Core i5 (Ivy Bridge), 16GB DDR3, 256GB SATA SSD. The whole kernel build story is in [docs/talos-intel-mac.md](docs/talos-intel-mac.md).

### Workers

Four Lenovo M920q Tiny nodes. Fanless-ish, low power, surprisingly capable.

| Node | IP | Status |
|---|---|---|
| wrk0 | 192.168.8.101 | Ready |
| wrk1 | 192.168.8.102 | Ready |
| wrk2 | 192.168.8.103 | Ready |
| wrk3 | 192.168.8.100 | Ready |

All on Intel Core i5/i7 (8th/9th gen), 16-32GB DDR4, NVMe storage. The iGPU (Intel UHD 630) is exposed via the `i915` Talos extension for Quick Sync transcoding.

### GPU node (on-demand)

My main PC joins the cluster on-demand with a `gpu=nvidia` taint for AI workloads.

AMD Ryzen 7 7800X3D, 32GB RAM, RTX 4070 Ti Super, 3x 2TB NVMe, dual-boots Fedora. [PCPartPicker build](https://pcpartpicker.com/b/QMRTwP).

---

## Stack

| Layer | What |
|---|---|
| OS | Talos Linux (immutable, API-managed) |
| CNI | Cilium (kube-proxy replacement, Gateway API, Hubble) |
| Ingress | Gateway API + HTTPRoutes (no NGINX) |
| Storage | Longhorn (distributed, 2 replicas) |
| GitOps | ArgoCD (App-of-Apps, 24 applications) |
| Secrets | Sealed Secrets + SOPS (age) |
| Metrics | kube-prometheus-stack + Thanos (indefinite retention via MinIO) |
| Logs | Loki (90-day retention via MinIO) |
| Log collector | Grafana Alloy |
| DNS | Cloudflare (ExternalDNS + cert-manager DNS01) |
| Backups | Velero (scheduled, GCS, CSI snapshots via Longhorn) + Longhorn native backup (AWS S3) |
| Power monitoring | Kepler (RAPL energy counters, node-level) |
| Remote access | Cloudflare Access Zero Trust tunnel |

---

## Workloads

- **catus-locatus** - my main app (PostGIS backend, Next.js frontend, MinIO)
- **pihole** - DNS + ad-blocking for the home network
- **tuwaiq-tracker** - CronJob hitting an external API every 12 hours
- **stremio** - media server
- **cloudflared** - Cloudflare Tunnel for public traffic
- **arc** - GitHub Actions self-hosted runners
- **velero** - scheduled cluster backups
- **monitoring** - Grafana, Prometheus, Thanos, Loki, Alloy

---

## Docs

- [Bootstrap runbook](kubernetes/bootstrap/README.md)
- [Backup and restore](docs/backup-and-restore.md)
- [Remote access](docs/remote-access.md)
- [Talos on Intel Mac](docs/talos-intel-mac.md)
