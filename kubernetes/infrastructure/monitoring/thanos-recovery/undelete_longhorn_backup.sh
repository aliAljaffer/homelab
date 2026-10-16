#!/bin/bash
# Recover a Longhorn backup that retention already pruned, from GCS soft-delete.
#
# When a Longhorn backup is pruned, its cfg and any blocks no longer referenced
# by a surviving backup are deleted. With the bucket's soft-delete policy those
# objects are only *soft*-deleted for the policy window, so they can be brought
# back with `gcloud storage restore` before their hardDeleteTime.
#
# This bit us in 2026: the daily-retain-14 window meant 2026-09-24..10-02 had
# already been pruned by the time we went looking, and soft-delete was only 7
# days -- we recovered the last ~8 days by undeletion and lost the rest.
#
# Usage: undelete_longhorn_backup.sh <backup-id> [<backup-id> ...]
#   backup-id is the Longhorn id WITHOUT the `backup-` prefix, e.g. bb84f1026c06460d
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
B=${LBASE:-gs://alialjaffer-homelab/longhorn/backupstore/volumes/a9/02/pvc-348a0364-a625-4714-a194-088cb805a3bd}
WORK="${RECOVERY_DIR:-/tmp/opencode}"

for id in "$@"; do
  echo "== backup-$id"
  # 1. undelete the backup config
  gcloud storage restore "$B/backups/backup_backup-$id.cfg"
  gcloud storage cat "$B/backups/backup_backup-$id.cfg" > "$WORK/lhcfg/backup_backup-$id.cfg"

  # 2. undelete every referenced block still in the soft-delete window
  python3 - "$WORK/lhcfg/backup_backup-$id.cfg" "$B" > "$WORK/undelete_$id.urls" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); B=sys.argv[2]
for b in cfg["Blocks"]:
    c=b["BlockChecksum"]
    print(f"{B}/blocks/{c[0:2]}/{c[2:4]}/{c}.blk")
PY
  # only the still-soft-deleted names need restoring
  gcloud storage ls --soft-deleted "$B/blocks/**" 2>/dev/null \
    | sed 's#.*/##;s#\.blk.*##' | sort -u > "$WORK/softdel.list"
  sed 's#.*/##;s#\.blk$##' "$WORK/undelete_$id.urls" | sort -u > "$WORK/want.list"
  comm -12 "$WORK/want.list" "$WORK/softdel.list" \
    | while read -r c; do echo "$B/blocks/${c:0:2}/${c:2:2}/${c}.blk"; done > "$WORK/undelete_$id.soft"
  echo "  blocks to undelete: $(wc -l < "$WORK/undelete_$id.soft")"
  split -n l/16 -d "$WORK/undelete_$id.soft" "$WORK/u_${id}_"
  ls "$WORK/u_${id}_"* | xargs -P 16 -I{} sh -c 'gcloud storage restore -I < "$1" >/dev/null 2>&1' _ {}
  rm -f "$WORK/u_${id}_"*
done
echo "undeleted; now run:  bash $SELF/run_two_phase.sh $(printf 'backup-%s ' "$@")"
