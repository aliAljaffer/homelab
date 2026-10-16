# Thanos metrics recovery toolkit

Offline tooling to pull historical Prometheus TSDB blocks back into the Thanos
bucket from every durable copy we have. Written during the 2026 metrics-loss
incident (see `../README.md`); kept in the repo so the next recovery is a
runbook, not an archaeological dig.

Everything here runs from a workstation with `gcloud` auth, `debugfs`,
`python-lz4` (`pip install --user --break-system-packages lz4`), and ~100 GB of
scratch space (default `/tmp/opencode`, override with `RECOVERY_DIR`). No root,
no loop mounts, no cluster capacity.

## Where the copies live (and how far back each reaches)

| Source | Path | Typical reach |
|---|---|---|
| Thanos live bucket | `gs://alialjaffer-homelab/<ULID>/` | current |
| Thanos older prefix | `gs://alialjaffer-homelab/thanos/` | whatever survived |
| Longhorn daily backups | `.../longhorn/backupstore/volumes/<v>/backups/` | `retain` days (daily job) |
| Longhorn monthly backups | same | `retain` months (monthly job) |
| GCS soft-deleted objects | `gcloud storage ls --soft-deleted …` | soft-delete window |
| Velero kopia repo | `gs://…/velero/kopia/<ns>/` | up to when Velero was removed |

Each Longhorn backup covers the two days *before* its 02:00 run, so consecutive
daily backups tile without holes; weekly/monthly carry month ULIDs at their 03:00
run.

## Decision tree

1. **Is the data in the live bucket / `thanos/` prefix?** Just copy block dirs to
   the bucket root and strip `deletion-mark.json`. Nothing else needed.
2. **Is it in a live Longhorn backup?** → `run_two_phase.sh <backup-name…>`.
   Download the `.cfg` first with
   `gcloud storage cat <B>/backups/backup_<name>.cfg > lhcfg/backup_<name>.cfg`.
3. **Was the Longhorn backup already pruned?** → check GCS soft-delete with
   `undelete_longhorn_backup.sh <id…>`, then `run_two_phase.sh`.
4. **Is it only in the Velero kopia repo?** → `restore_kopia.sh <snapshot-id…>`.

## Scripts

- `extract_snapshot.sh <cfg>` — rebuild a Longhorn backup as a sparse ext4 image
  (each block lz4-frame-decompressed to its `Offset`) and `debugfs`-dump the TSDB
  block dirs. Idempotent (`EXTRACT_OK`).
- `download_blocks.py <urls>` — parallel block fetcher into a content-addressed
  cache. Uses the GCS JSON API because `gsutil -m cp -I` silently drops entries.
- `run_two_phase.sh <name…>` — download+extract everything, *then* upload
  everything. Two phases because on an asymmetric link concurrent downloads
  starve uploads.
- `upload_blocks.sh <dir>` — push block dirs to the bucket root, **chunks first,
  `meta.json` last**, so a partial upload is invisible to Thanos instead of
  half-loaded. Skips blocks already present.
- `restore_kopia.sh <id…>` — kopia read-only connect + restore + upload.
- `undelete_longhorn_backup.sh <id…>` — `gcloud storage restore` a pruned backup's
  cfg and referenced blocks out of the soft-delete window.

## kopia notes (cost us days)

- The GCS `--prefix` **must** end in `/`; kopia concatenates `Prefix + blobID`,
  so a missing slash gives "repository not initialized in the provided storage".
- Snapshots are stored under `default@default` → use `snapshot list --all`.
- `GOOGLE_APPLICATION_CREDENTIALS` must point at the bucket service-account JSON
  (readable from the live `thanos-objstore-secret`).
