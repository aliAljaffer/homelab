# monitoring

- `namespace.yaml`: node_exporter needs hostNetwork/hostPID/hostPath/hostPort, which the cluster-wide PodSecurity baseline default doesn't allow. The namespace labels override it to privileged.
- `networkpolicy.yaml`: highest fan-in/fan-out namespace in the cluster. Apply this last, only after audit mode has been clean on the simpler namespaces for at least a full day (catches daily cronjobs, backup cycles, etc).
  - Thanos (sidecar, storegateway, compactor) and Loki use GCS (bucket `alialjaffer-homelab`, shared with Longhorn backups), not an in-cluster MinIO.
  - kubelet/cAdvisor scrape (port 10250) is modeled as Cilium host/remote-node entities, not a namespace selector, it scrapes node IPs directly.
  - GitHub API egress for grafana-github-datasource is assumed to be `api.github.com:443` (standard for that plugin), not confirmed live. Confirm via audit-mode logs if the datasource gets exercised.
- `values.yaml`: static Grafana admin credentials come from a SealedSecret rather than the chart's auto-generated password. Without `admin.existingSecret`, the chart uses Helm's `lookup` to try to reuse the existing password on every render, but ArgoCD's repo-server doesn't have reliable live-cluster access, so `lookup` intermittently comes back empty and silently re-randomizes the password.

## Long-term metrics storage (Thanos)

Thanos is the only long-term metric store. Prometheus (`retention: 2d`) is just a
buffer, so any block the `thanos-sidecar` fails to upload to the GCS bucket is
lost permanently once it ages out of Prometheus. Blocks land every 2h under the
bucket root (`gs://alialjaffer-homelab/`) — no prefix.

Two failure modes have bitten this cluster, both silent (`TargetDown` and pod
health stayed green the whole time):

1. **Stale objectstore credential.** `OBJSTORE_CONFIG` is injected into the
   sidecar/compactor/storegateway from `thanos-objstore-secret` as an env var, so
   rotating the GCS service-account key does *not* reach a running pod. Rotating
   that secret requires restarting `prometheus-kube-prometheus-prometheus-0` and
   the Thanos statefulsets. In 2026-08 the key was rotated (commit
   `b484670`) without a restart; uploads failed until the pods happened to
   restart in 2026-10.
2. **Bucket egress denied.** `toFQDNs` for `storage.googleapis.com` does not
   populate Cilium's FQDN cache reliably, so the storegateway/compactor got
   `POLICY_DENIED` on every bucket call. Those CNPs now use `toEntities: world`
   + `443/tcp` (commit `e3a8628`). The `prometheus-default` CNP still uses
   `toFQDNs`, which works for the sidecar because Prometheus resolves those
   names itself — but if the sidecar ever stops uploading, check that rule.

The `Thanos Bucket Uploads Stalled` / `Thanos Bucket Access Failing` alert rules
in `values.yaml` exist specifically to page on these, since neither shows up as
a pod-level failure. See the recovery notes in the table below.

### Recovering metric history (2026-10-16)

The Aug 2026 loss left a hole; here is what was recoverable and how:

| Source | Covers | Notes |
| --- | --- | --- |
| `gs://alialjaffer-homelab/thanos/` | 2026-08-08 → 08-14 | Orphaned blocks from when the config still had `prefix: thanos`. Copied to the bucket root to be served again; `deletion-mark.json` must be stripped first or the compactor's block cleaner deletes them immediately. |
| Longhorn daily backups of the Prometheus volume (`pvc-348a0364-…`) | last 14 days | `retain: 14` on the `daily-backup` RecurringJob caps this, so anything older is pruned. Each backup only holds Prometheus' 2d window. |
| Velero snapshots (`velero/kopia/monitoring/`) | 2026-08-13 → 08-24 | Velero was removed in Aug 2026, and its kopia repo password went with the `velero` namespace, so these are not readable any more. |

What was actually recovered on 2026-10-16:

- **2026-08-08 08:55 → 08-13 14:00** from the `thanos/` prefix (two short raw
  gaps remain inside that span — only the compaction outputs survived there).
- **2026-10-01 → 10-13** from the Longhorn backups, which each hold exactly the
  two calendar days before their 02:00 run, so every-other-day backups tile the
  window with no holes (Oct 3, 5, 7, 9, 11, 13, 14).

The **2026-08-14 → 2026-10-01** window was never uploaded and exists nowhere.

Also swept and confirmed empty: every PV/Longhorn volume in the cluster (the
`Released` 20Gi ones from the 2026-08-22 cleanup are all <0.5G actual) and all
Longhorn *local* snapshots (all from the current day — the RecurringJob does not
keep old ones, only the backups listed above).

Restoring a Longhorn backup to Thanos blocks (no cluster changes needed, reads
the backupstore directly):

```sh
# 1. block map for a backup -> list of sharded object paths
#    (blocks/<chk[0:2]>/<chk[2:4]>/<chk>.blk under
#     longhorn/backupstore/volumes/a9/02/pvc-348a0364-…/)
# 2. download them, lz4-frame-decompress each into a sparse image at its Offset,
#    then read the filesystem with debugfs (no root/loop mount required). The PVC
#    is mounted AT /prometheus, so the TSDB lives at /prometheus-db inside the
#    volume:
debugfs -R "ls -l /prometheus-db" img.raw
# rdump requires the destination to already exist, and nests one level deep:
mkdir -p out/<BLOCK_ULID>
debugfs -R "rdump /prometheus-db/<BLOCK_ULID> out/<BLOCK_ULID>" img.raw
# 3. upload the resulting TSDB block dirs to the bucket root; they are already
#    in Thanos block format, so the storegateway serves them on its next sync.
```

