# homelab

My Kubernetes homelab, running on Talos Linux and managed entirely through ArgoCD. Everything is in this repo - if it's not here, it doesn't exist on the cluster.

**Talos:** v1.13.8 (control plane) / v1.13.7 (workers)
**Kubernetes:** v1.36.2

---

## Nodes

### Control plane

MacBook Pro Mid-2012 (13"). Yes, really.

It runs `cp0` at `192.168.8.99` with a custom-built Talos kernel because Apple's EFI firmware rejects the LLD-compiled kernel that ships in v1.13.0+. Intel Core i5 (Ivy Bridge), 16GB DDR3, 256GB SATA SSD. The whole kernel build story is in [docs/talos-intel-mac.md](docs/talos-intel-mac.md).

`wrk0` and `wrk1` also run the control-plane role, so the cluster has three stacked etcd members.

### Workers

Four Lenovo M920q Tiny nodes. Fanless-ish, low power, surprisingly capable.

| Node | IP            | Status |
| ---- | ------------- | ------ |
| wrk0 | 192.168.8.101 | Ready  |
| wrk1 | 192.168.8.102 | Ready  |
| wrk2 | 192.168.8.103 | Ready  |
| wrk3 | 192.168.8.100 | Ready  |

All on Intel Core i5/i7 (8th/9th gen), 16-32GB DDR4, NVMe storage. The iGPU (Intel UHD 630) is exposed via the `i915` Talos extension for Quick Sync/VAAPI transcoding, scheduled cluster-wide as `gpu.intel.com/i915` via Node Feature Discovery + the Intel device plugin.

### GPU node (on-demand)

My main PC joins the cluster on-demand with a `gpu=nvidia` taint for AI workloads.

AMD Ryzen 7 7800X3D, 32GB RAM, RTX 4070 Ti Super, 3x 2TB NVMe, dual-boots Fedora. [PCPartPicker build](https://pcpartpicker.com/b/QMRTwP).

---

## Stack

| Layer            | What                                                                                                                                                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OS               | Talos Linux (immutable, API-managed)                                                                                                                                                                                                                     |
| CNI              | Cilium (kube-proxy replacement, Gateway API, Hubble)                                                                                                                                                                                                     |
| Ingress (LAN)    | Gateway API + HTTPRoutes via Cilium's GatewayClass (no NGINX)                                                                                                                                                                                            |
| Ingress (public) | cloudflare-tunnel-gateway-controller - dedicated Cloudflare Tunnel bound to its own GatewayClass/Gateway, so public HTTPRoutes need no manual tunnel config                                                                                              |
| Load balancer    | MetalLB (pool `192.168.8.128-192.168.8.240`, Cilium Gateway on `192.168.8.129`)                                                                                                                                                                          |
| Storage          | Longhorn (distributed, 2 replicas)                                                                                                                                                                                                                       |
| Snapshots        | external-snapshotter (`longhorn-snapshot` VolumeSnapshotClass)                                                                                                                                                                                           |
| Registry cache   | Harbor (LAN-only pull-through cache for docker.io, ghcr.io, quay.io, registry.k8s.io via Talos containerd mirrors)                                                                                                                                        |
| Database         | CloudNativePG (Postgres operator)                                                                                                                                                                                                                        |
| Redis            | redis-operator with a standalone Valkey instance                                                                                                                                                                                                         |
| Identity         | Keycloak (HA, 3 instances, CloudNativePG-backed; realms `homelab` + `external-users`)                                                                                                                                                                     |
| Auth gate        | oauth2-proxy, a reusable per-app OIDC reverse proxy for apps with no login of their own (reuses the Keycloak `homelab` realm)                                                                                                                             |
| GitOps           | ArgoCD (App-of-Apps: `infrastructure` + `workloads` ApplicationSet, 43 applications)                                                                                                                                                                     |
| Secrets (static) | Sealed Secrets + SOPS (age)                                                                                                                                                                                                                              |
| Policy engine    | Kyverno                                                                                                                                                                                                                                                  |
| Runtime security | Falco (DaemonSet, alerts routed through the SMTP relay)                                                                                                                                                                                                   |
| Notifications    | ntfy (cluster-wide push server, oauth2-proxy in front, first consumer is `fai`)                                                                                                                                                                          |
| Email egress     | smtp-relay - single rate-limited SMTP hop to Resend for Alertmanager, Grafana, ArgoCD, Keycloak, Vaultwarden and Falco                                                                                                                                     |
| GPU scheduling   | Node Feature Discovery + Intel device plugin (`gpu.intel.com/i915`)                                                                                                                                                                                      |
| Metrics          | kube-prometheus-stack + Thanos (indefinite retention, GCS bucket `alialjaffer-homelab`)                                                                                                                                                                  |
| Logs             | Loki (7-day retention, GCS bucket `alialjaffer-homelab`)                                                                                                                                                                                                 |
| Log collector    | Grafana Alloy                                                                                                                                                                                                                                            |
| DNS              | Cloudflare (ExternalDNS + cert-manager DNS01)                                                                                                                                                                                                            |
| Backups          | Longhorn native backup (S3-compatible to GCS, daily at 02:00 UTC keeping 30, monthly on the 1st keeping 12)                                                                                                                                              |
| Power monitoring | Kepler (RAPL energy counters, node-level)                                                                                                                                                                                                                |
| Remote access    | Legacy `cloudflared` tunnel (workload-specific routes: kubectl/talosctl endpoints plus catus-locatus) + the public Gateway tunnel, which exposes vaultwarden, keycloak, umami, chat-api, ntfy, fai and grooszy externally (Cloudflare-proxied); everything else (argocd, grafana, pihole, harbor, Hubble, Longhorn, MinIO console, stremio) stays LAN-only on the internal Gateway |

---

## Workloads

- **catus-locatus** - my main app (PostGIS backend, Next.js frontend, MinIO)
- **vaultwarden** - self-hosted Bitwarden-compatible password manager (SQLite on Longhorn)
- **pihole** - DNS + ad-blocking for the home network (Longhorn-persisted, Prometheus metrics via exporter sidecar)
- **tuwaiq-tracker** - CronJob hitting an external API every 12 hours
- **stremio** - self-hosted Stremio, GPU-transcoded. I'm running the `nightly` image because I needed a WASM build my LG TV's old webOS browser could actually run, and even then I ended up sideloading it onto the TV as a native app instead, the browser route just never worked out (see [docs/lg-tv-sideload.md](docs/lg-tv-sideload.md))
- **nexotv** - Stremio addon I use for an IPTV catalog over Xtream Codes. ArgoCD-managed through a hand-written Application (it is excluded from the `workloads` ApplicationSet) and deployed into the `stremio` namespace
- **umami** - self-hosted analytics (CNPG-backed Postgres)
- **fai** - personal task tracker / Kanban / notes (Next.js frontend, Go backend, CNPG Postgres, ReadWriteMany Longhorn PVC for attachments); the backend validates Keycloak JWTs itself, so it does not sit behind oauth2-proxy
- **grooszy** - private expense analysis app (web + API, CNPG Postgres)
- **ntfy** - cluster-wide push notification server, oauth2-proxy in front; `fai` is the first consumer
- **chat** - one private chat API for every app: each app wraps its own UI and calls the API with a per-app key. Runs OpenCode as a text-only agent. See [kubernetes/apps/chat](kubernetes/apps/chat/README.md) and [aliAljaffer/chat-gateway](https://github.com/aliAljaffer/chat-gateway).
- **cloudflared** - Cloudflare Tunnel for public traffic
- **arc** - GitHub Actions self-hosted runners for `chat-gateway`, `grooszy`, and `fai`'s build CI (fai release stays hosted; toolchain image built in CI and served through Harbor)
- **longhorn-backup** - scheduled PV backups to GCS (Longhorn RecurringJob)
- **monitoring** - Grafana, Prometheus, Thanos, Loki, Alloy

I tore down the Jellyfin/\*arr media stack (Sonarr, Radarr, Prowlarr, Seerr, Decypharr, Dispatcharr) I used to run here, Stremio + NexoTV replaced it.

---

## Docs

- [Bootstrap runbook](kubernetes/bootstrap/README.md)
- [oauth2-proxy auth gate](kubernetes/components/oauth2-proxy/README.md)
- [Backup and restore](docs/backup-and-restore.md)
- [Remote access](docs/remote-access.md)
- [Talos on Intel Mac](docs/talos-intel-mac.md)
- [LG webOS TV sideload](docs/lg-tv-sideload.md)
