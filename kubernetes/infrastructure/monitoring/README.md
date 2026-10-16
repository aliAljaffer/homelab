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

Hard-won detail: **the bucket's soft-delete window is a first-class recovery
source.** A pruned Longhorn backup's cfg and its now-unreferenced blocks are only
*soft*-deleted, so `gcloud storage restore` can bring them back until their
`hardDeleteTime`. That is how part of the 2026 window was saved at the last
minute — check it before concluding anything is gone.

| Source | Covers | Notes |
| --- | --- | --- |
| `gs://alialjaffer-homelab/thanos/` | 2026-08-08 → 08-14 | Orphaned blocks from when the config still had `prefix: thanos`. Copied to the bucket root to be served again; `deletion-mark.json` must be stripped first or the compactor's block cleaner deletes them immediately. |
| Longhorn backups of the Prometheus volume (`pvc-348a0364-…`) | `daily-backup` retain **30** d + `monthly-backup` retain **12** m | Each backup only holds Prometheus' 2d window, but consecutive dailies tile without holes. The 2026 incident needed ~38 days, which the old `retain: 14` could not reach — hence the bumped daily and the new monthly job. |
| GCS soft-deleted objects | the soft-delete window (**30 d**) | Where the retention-pruned backups went. Undelete *fast*: raising the policy is **not retroactive**, objects already soft-deleted keep their original `hardDeleteTime`. |
| Velero kopia snapshots (`velero/kopia/monitoring/`) | 2026-08-13 → 08-24 | Readable offline with the kopia CLI once you have the bucket SA **and** the repo password. Velero's chart shipped the static default `static-passw0rd`; the 2026 outage lost 10 days because the auto-generated password was never captured before the `velero` namespace was deleted. |

What was recovered on 2026-10-16:

- **2026-08-08 08:55 → 08-13 14:00** from the `thanos/` prefix (two short raw
  gaps remain inside that span — only the compaction outputs survived there).
- **2026-08-13 → 08-24** from the Velero kopia repo, once the password above was
  found (each snapshot holds Prometheus' 2d window; 11 snapshots cover the span).
- **2026-09-24 → 10-02** by undeleteing 7 retention-pruned Longhorn backups
  (`bb84f102…` … `446e044f…`) and their 37 007 unique blocks out of soft-delete.
- **2026-10-01 → now** from the live Longhorn backups (Sept 30–Oct 16: dailies
  covering 10-01…10-14, plus the bucket's own 10-13→now) and `thanos/` blocks.

The **2026-08-24 → 2026-09-24** window (about four weeks) is the only permanent
hole: Velero stopped at 08-24, Longhorn's daily backups from that period were
pruned long before soft-delete existed, and nothing else held it. `2026-08-14 →
08-24` is partially covered by kopia; `08-24 → 09-24` is not.

Also swept and confirmed empty: every PV/Longhorn volume in the cluster (the
`Released` 20Gi ones from the 2026-08-22 cleanup are all <0.5G actual) and all
Longhorn *local* snapshots (all from the current day — the RecurringJob does not
keep old ones, only the backups listed above).

The recovery itself is scripted and committed:
`./thanos-recovery/` (block download → sparse-image extract via `debugfs` →
`chunks`-first/`meta.json`-last upload, plus kopia-restore and soft-delete
undelete helpers). See its README for the decision tree.

```sh
# minimal manual version, no cluster changes (reads the backupstore directly):
# 1. block map for a backup -> list of sharded object paths
#    (blocks/<chk[0:2]>/<chk[2:4]>/<chk>.blk under
#     longhorn/backupstore/volumes/a9/02/pvc-348a0364-…/)
# 2. download them, lz4-frame-decompress each into a sparse image at its Offset,
#    then read the filesystem with debugfs (no root/loop mount required). The PVC
#    is mounted AT /prometheus, so the TSDB lives at /prometheus-db inside the volume:
debugfs -R "ls -l /prometheus-db" img.raw
# rdump requires the destination to already exist, and nests one level deep:
mkdir -p out/<BLOCK_ULID>
debugfs -R "rdump /prometheus-db/<BLOCK_ULID> out/<BLOCK_ULID>" img.raw
# 3. upload the resulting TSDB block dirs to the bucket root; they are already
#    in Thanos block format, so the storegateway serves them on its next sync.
```

### Preventing the next loss

The failure was silent for ~2 months, so prevention is layered:

1. **Alert within hours, not months.** `Thanos Bucket Uploads Stalled` fires when
   the storegateway stops loading new blocks (i.e. the sidecar stopped
   uploading); `Thanos Bucket Access Failing` fires on bucket operation
   failures. Both are in `values.yaml`; see the comments there for the exact
   expressions.
2. **Keep more durable copies.**
   - Longhorn `daily-backup` retain **30** + new `monthly-backup` retain **12** →
     a month of fine-grained plus a year of coarse PVC snapshots (see
     `kubernetes/infrastructure/longhorn/`).
   - Bucket **soft-delete raised to 30 days** (`gcloud storage buckets update
     gs://alialjaffer-homelab --soft-delete-duration=30d`). This is bucket config,
     not in git — treat it as bootstrap state and re-check after any bucket
     recreation.
3. **Make credential rotation a restart.** The sidecar arg is
   `--objstore.config=$(OBJSTORE_CONFIG)`, so the secret value is frozen at pod
   start. After rotating `thanos-objstore-secret`, restart
   `prometheus-kube-prometheus-prometheus-0` **and** the `thanos-compactor` /
   `thanos-storegateway` statefulsets. The Prometheus CRD also supports
   `thanos.objectStorageConfigFile` (a mounted file) if a hot-reloadable setup is
   ever wanted.
4. **Keep the DR password in git.** If Velero (or any repo-password-gated tool) is
   ever reintroduced, its repository password must be a SealedSecret in the repo
   *before* the namespace can be deleted, or its backups are write-only.


