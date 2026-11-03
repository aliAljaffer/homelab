#!/bin/bash
# Validate extracted Prometheus TSDB block dirs and upload them to the Thanos
# bucket root, where the storegateway will serve them.
#
# Data goes up first and meta.json LAST: Thanos only sees a block once meta.json
# exists, so an interrupted upload is ignored instead of half-loaded (a
# half-loaded block makes the storegateway spam block-load failures).
#
# Two lessons baked in from the 2026-10 recovery, both found the hard way:
#
# 1. Blocks built by this toolkit never go through the sidecar, so they never
#    get a `thanos.labels` section in meta.json. The compactor requires
#    non-empty external labels on every block in a group it merges; a block
#    without them makes the WHOLE group fail forever ("empty external labels
#    are not allowed"), retried every cycle with a fresh output ULID, no
#    progress. inject_labels() stamps the same labels the sidecar would.
#
# 2. The debugfs/ext4 sparse-image extraction this toolkit uses is NOT
#    reliably deterministic -- one run silently corrupted 47 of 156 blocks
#    (file present, right size, but internally broken: Thanos failed to load
#    it with "reference sequence 0 out of range" / "segment index out of
#    range"). A plain re-extraction of the exact same backup fixed it. Nothing
#    about file existence or size catches this. validate_block() does a
#    cheap, partial check -- TSDB magic bytes and a minimum chunk size -- which
#    catches gross truncation/corruption but CANNOT prove full index-to-chunk
#    consistency. The only real proof is a live query against the block's
#    time range after it's uploaded and the storegateway has synced; this
#    script does not do that automatically, so re-run the validation query
#    pass from the recovery session afterward rather than trusting a clean
#    upload log alone.
set -uo pipefail
SRC="$1"
BUCKET=${THANOS_BUCKET:-gs://alialjaffer-homelab}
[ -d "$SRC" ] || { echo "no such dir: $SRC"; exit 1; }

inject_labels() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
if not m.get("thanos", {}).get("labels"):
    m["thanos"] = {
        "labels": {
            "prometheus": "monitoring/kube-prometheus-prometheus",
            "prometheus_replica": "prometheus-kube-prometheus-prometheus-0",
        },
        "downsample": {"resolution": 0},
        "source": "recovery",
    }
    json.dump(m, open(path, "w"), indent="\t")
PY
}

# Exits 1 and prints why on the first problem found; silent on success.
validate_block() {
  python3 - "$1" "$2" <<'PY'
import sys
index_path, chunk_path = sys.argv[1], sys.argv[2]
with open(index_path, "rb") as f:
    head = f.read(5)
if head[:4] != b"\xba\xaa\xad\x70":
    print("index: bad magic bytes (truncated or not a TSDB index)"); sys.exit(1)
with open(chunk_path, "rb") as f:
    head = f.read(5)
if head[:4] != b"\x85\xbd\x40\xdd":
    print("chunks/000001: bad magic bytes (truncated or not a TSDB chunk segment)"); sys.exit(1)
import os
if os.path.getsize(chunk_path) < 1024:
    print("chunks/000001: suspiciously small (<1KiB) for a 2h block"); sys.exit(1)
PY
}

upload_block() {
  local d=$1 u reason
  u=$(basename "$d")
  if [ ! -f "$d/meta.json" ] || [ ! -d "$d/chunks" ] || [ ! -f "$d/index" ]; then
    echo "  SKIP $u (incomplete locally)" >&2; echo bad; return
  fi
  if gcloud storage ls "$BUCKET/$u/chunks/" >/dev/null 2>&1; then
    echo "  skip $u (already in bucket)" >&2; echo skip; return
  fi
  if ! reason=$(validate_block "$d/index" "$d/chunks/000001" 2>&1); then
    echo "  SKIP $u (failed local validation: $reason)" >&2; echo bad; return
  fi
  inject_labels "$d/meta.json"
  python3 - "$d/meta.json" >&2 <<'PY'
import json,sys,datetime
m=json.load(open(sys.argv[1]))
f=lambda ms: datetime.datetime.fromtimestamp(ms/1000, datetime.UTC).strftime("%Y-%m-%d %H:%M")
print("  up   %s level=%s %s -> %s" % (m["ulid"], m.get("compaction",{}).get("level"), f(m["minTime"]), f(m["maxTime"])))
PY
  gsutil -m -q -o GSUtil:parallel_thread_count=16 cp -r "$d/chunks" "$BUCKET/$u/" \
    || { echo "       chunks FAILED" >&2; echo bad; return; }
  gsutil -m -q cp "$d/index" "$BUCKET/$u/" 2>/dev/null || true
  gsutil -m -q cp "$d/tombstones" "$BUCKET/$u/" 2>/dev/null || true
  gsutil -q cp "$d/meta.json" "$BUCKET/$u/meta.json" \
    || { echo "       meta FAILED" >&2; echo bad; return; }
  echo ok
}
export BUCKET
export -f inject_labels validate_block upload_block

# Each block is independent; meta.json still goes up last within its own block.
statuses=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0 \
  | xargs -0 -r -P "${UPLOAD_JOBS:-4}" -I{} bash -c 'upload_block "$1"' _ {})
read -r ok skip bad <<<"$(printf '%s\n' "$statuses" \
  | awk '{c[$1]++} END {print c["ok"]+0, c["skip"]+0, c["bad"]+0}')"
echo "uploaded=$ok already_present=$skip invalid=$bad"
echo "UPLOAD_DONE"
