#!/bin/bash
# Restore Prometheus TSDB blocks from the Velero kopia repository in GCS.
#
# Velero's node-agent kept a kopia repository at <bucket>/velero/kopia/<ns>/
# holding daily `snapshot-pod-volume` snapshots of the Prometheus PVC. It is
# readable offline with the kopia CLI as long as you have (a) the bucket service
# account and (b) the repository password.
#
# Password: the Velero Helm chart historically shipped repo-credentials with the
# static default `static-passw0rd`; verify with `kopia repository connect`.
# The 2026 outage was unrecoverable for 10 days because the auto-generated
# password was never captured before the velero namespace was deleted -- hence
# the rule: always keep the repo password in a sealed secret in git.
#
# Gotchas learned the hard way:
#   * the GCS `--prefix` MUST end in `/` (kopia concatenates Prefix + blobID),
#     otherwise you get "repository not initialized in the provided storage"
#   * GOOGLE_APPLICATION_CREDENTIALS must point at the bucket SA JSON
#   * snapshots live under user/host `default@default` -> `snapshot list --all`
#
# Usage: restore_kopia.sh <snapshot-id> [<snapshot-id> ...]
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${RECOVERY_DIR:-/tmp/opencode}"
KOPIA="${KOPIA:-$RECOVERY_DIR/kopia-0.23.1-linux-x64/kopia}"
CFG="$RECOVERY_DIR/kopia-recovery.config"
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-$RECOVERY_DIR/gcs-sa.json}"
KOPIA_PASSWORD="${KOPIA_PASSWORD:-static-passw0rd}"
BUCKET="${THANOS_BUCKET:-gs://alialjaffer-homelab}"
OUT="$RECOVERY_DIR/velero_restore"

# connect read-only (idempotent)
if ! "$KOPIA" --config-file="$CFG" repository status >/dev/null 2>&1; then
  "$KOPIA" --config-file="$CFG" repository connect gcs \
    --bucket="${BUCKET#gs://}" --prefix="velero/kopia/monitoring/" \
    --password="$KOPIA_PASSWORD" --readonly
fi

for id in "$@"; do
  d="$OUT/$id"
  if [ ! -e "$d/.DONE" ]; then
    rm -rf "$d"; mkdir -p "$d"
    echo "[$(date +%H:%M:%S)] restoring $id"
    "$KOPIA" --config-file="$CFG" snapshot restore "$id" "$d" && touch "$d/.DONE"
  fi
  # the restored PVC root holds prometheus-db/ (and lost+found/)
  bash "$SELF/upload_blocks.sh" "$d/prometheus-db"
done
