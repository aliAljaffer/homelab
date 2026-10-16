#!/bin/bash
# Reconstruct a Longhorn volume backup into a sparse ext4 image and extract the
# Prometheus TSDB block dirs (already in Thanos block format) ready to upload.
#
# Why offline: a Longhorn `fromBackup` restore materialises a 20Gi replica on
# the already-pressured Longhorn disks and still only yields a raw device. A
# sparse image built in /tmp needs no root/loop mounts and no cluster capacity.
#
# The PVC is mounted AT /prometheus in the pod, so the volume root holds
# lost+found + prometheus-db/ (the TSDB dir).
set -uo pipefail
CFG="$1"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Baseline the 2026 recovery ran against; adjust for other volumes.
B=${LBASE:-gs://alialjaffer-homelab/longhorn/backupstore/volumes/a9/02/pvc-348a0364-a625-4714-a194-088cb805a3bd}
WORK_ROOT=${RECOVERY_DIR:-/tmp/opencode}
NAME=$(python3 -c "import json;print(json.load(open('$CFG'))['Name'])")
WORK=$WORK_ROOT/work/$NAME
CACHE=${BLOCK_CACHE:-$WORK_ROOT/blk}
TSDB=${TSDB_PATH:-/prometheus-db}
mkdir -p "$WORK" "$CACHE"
log(){ echo "[$(date -u +%H:%M:%S)] $NAME $*"; }

# already extracted? (idempotent restart after an interrupted run)
if [ -f "$WORK/EXTRACT_OK" ] && [ "$(ls "$WORK/blocks" 2>/dev/null | wc -l)" -gt 0 ]; then
  log "already extracted ($(ls "$WORK/blocks" | wc -l) dirs) - skipping"
  echo "EXTRACT_SKIP $NAME $WORK/blocks"
  exit 0
fi

log "start ($CFG)"

# 1. source URL list (one per referenced block; sharded path)
python3 - "$CFG" "$B" > "$WORK/sources.txt" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); B=sys.argv[2]
for b in cfg["Blocks"]:
    c=b["BlockChecksum"]
    print(f"{B}/blocks/{c[0:2]}/{c[2:4]}/{c}.blk")
PY
log "referenced blocks: $(wc -l < "$WORK/sources.txt")"

# 2. download blocks into the shared flat cache (dedup across snapshots)
BLOCK_CACHE="$CACHE" python3 "$SELF/download_blocks.py" "$WORK/sources.txt" || exit 2
log "cache: $(ls "$CACHE" | wc -l) files, $(du -sh "$CACHE" | cut -f1)"

# 3. build sparse ext4 image from the block map (each block is lz4-frame)
python3 - "$CFG" "$WORK" "$CACHE" <<'PY' || exit 7
import json,sys,os
import lz4.frame
cfg=json.load(open(sys.argv[1])); work=sys.argv[2]; cache=sys.argv[3]
blocks=cfg["Blocks"]
size=max(int(b["Offset"]) for b in blocks)+2097152
img=os.path.join(work,"img.raw")
missing=0
with open(img,"wb") as f:
    f.truncate(size)
    for b in blocks:
        c=b["BlockChecksum"]; off=int(b["Offset"])
        p=os.path.join(cache,c+".blk")
        if not os.path.exists(p):
            missing+=1; continue
        f.seek(off); f.write(lz4.frame.decompress(open(p,"rb").read()))
print(f"image={img} size={size} missing_blocks={missing}")
sys.exit(7 if missing else 0)
PY
log "image built"

# 4. extract TSDB block dirs (debugfs needs no root/loop mount).
#    Block ULIDs always start with 01; rdump nests one extra level, so flatten.
OUT="$WORK/blocks"; rm -rf "$OUT"; mkdir -p "$OUT"
debugfs -R "ls -l $TSDB" "$WORK/img.raw" 2>/dev/null \
  | grep -oE '01[0-9A-Z]{24}' | sort -u > "$WORK/dirs.txt"
log "TSDB block dirs found: $(wc -l < "$WORK/dirs.txt")"
while read -r d; do
  [ -z "$d" ] && continue
  mkdir -p "$OUT/$d"
  debugfs -R "rdump $TSDB/$d $OUT/$d" "$WORK/img.raw" >/dev/null 2>&1
  if [ -d "$OUT/$d/$d" ]; then
    mv "$OUT/$d/$d" "$OUT/.tmp_$d" && rmdir "$OUT/$d" && mv "$OUT/.tmp_$d" "$OUT/$d"
  fi
done < "$WORK/dirs.txt"
log "extracted: $(ls "$OUT" | wc -l) dirs, $(du -sh "$OUT" | cut -f1)"
touch "$WORK/EXTRACT_OK"
echo "EXTRACT_DONE $NAME $OUT"
