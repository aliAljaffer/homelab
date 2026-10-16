#!/bin/bash
# Two-phase recovery of Prometheus TSDB blocks from Longhorn backups.
#
# Phase 1 downloads + extracts every snapshot with the uplink left alone
# (on an asymmetric link, downloads starve uploads), phase 2 then uploads all
# extracted blocks to the Thanos bucket root. Both phases are idempotent and
# resume from the shared block cache / EXTRACT_OK markers, so re-running after
# an interruption is safe.
#
# Usage: run_two_phase.sh [backup-name ...]   (defaults to a known set)
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
export RECOVERY_DIR="${RECOVERY_DIR:-/tmp/opencode}"
cd "$RECOVERY_DIR"
NAMES="${*:-backup-49b248f0a3114de0 backup-e8559a81dd564825 backup-36e4defff7df479e backup-7cb27ab943404b6f backup-da9289d02f4f4da2 backup-f6afcc4613344476 backup-2d40d20ad3994d16}"

echo "### PHASE 1: download + extract (no upload traffic)"
for name in $NAMES; do
  cfg="lhcfg/backup_$name.cfg"
  if [ ! -f "$cfg" ]; then echo "MISSING cfg for $name"; continue; fi
  bash "$SELF/extract_snapshot.sh" "$cfg" || echo "EXTRACT_FAILED $name"
  rm -f "work/$name/img.raw"        # reclaim ~20G per backup; no longer needed
done

echo "### PHASE 2: upload extracted blocks (clean uplink)"
for name in $NAMES; do
  echo "--- $name"
  bash "$SELF/upload_blocks.sh" "work/$name/blocks" || echo "UPLOAD_FAILED $name"
done
echo "### ALL_DONE"
