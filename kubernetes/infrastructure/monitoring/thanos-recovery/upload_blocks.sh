#!/bin/bash
# Validate extracted Prometheus TSDB block dirs and upload them to the Thanos
# bucket root, where the storegateway will serve them.
#
# Data goes up first and meta.json LAST: Thanos only sees a block once meta.json
# exists, so an interrupted upload is ignored instead of half-loaded (a
# half-loaded block makes the storegateway spam block-load failures).
set -uo pipefail
SRC="$1"
BUCKET=${THANOS_BUCKET:-gs://alialjaffer-homelab}
[ -d "$SRC" ] || { echo "no such dir: $SRC"; exit 1; }

ok=0; bad=0; skip=0
for d in "$SRC"/*/; do
  [ -d "$d" ] || continue
  u=$(basename "$d")
  if [ ! -f "$d/meta.json" ] || [ ! -d "$d/chunks" ] || [ ! -f "$d/index" ]; then
    echo "  SKIP $u (incomplete locally)"; bad=$((bad+1)); continue
  fi
  if gcloud storage ls "$BUCKET/$u/chunks/" >/dev/null 2>&1; then
    echo "  skip $u (already in bucket)"; skip=$((skip+1)); continue
  fi
  python3 - "$d/meta.json" <<'PY'
import json,sys,datetime
m=json.load(open(sys.argv[1]))
f=lambda ms: datetime.datetime.fromtimestamp(ms/1000, datetime.UTC).strftime("%Y-%m-%d %H:%M")
print("  up   %s level=%s %s -> %s" % (m["ulid"], m.get("compaction",{}).get("level"), f(m["minTime"]), f(m["maxTime"])))
PY
  gsutil -m -q -o GSUtil:parallel_thread_count=16 cp -r "$d/chunks" "$BUCKET/$u/" || { echo "       chunks FAILED"; bad=$((bad+1)); continue; }
  gsutil -m -q cp "$d/index" "$BUCKET/$u/" 2>/dev/null || true
  gsutil -m -q cp "$d/tombstones" "$BUCKET/$u/" 2>/dev/null || true
  gsutil -q cp "$d/meta.json" "$BUCKET/$u/meta.json" || { echo "       meta FAILED"; bad=$((bad+1)); continue; }
  ok=$((ok+1))
done
echo "uploaded=$ok already_present=$skip invalid=$bad"
echo "UPLOAD_DONE"
