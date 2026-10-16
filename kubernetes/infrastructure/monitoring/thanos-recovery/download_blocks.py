#!/usr/bin/env python3
"""Parallel downloader for Longhorn backup block objects.

The GCS JSON API is used directly because `gsutil -m cp -I` silently drops
entries, and the `gsutil` snap package needs an explicit project id. Block
checksums are content-addressed, so the flat cache below deduplicates blocks
that many daily backups share.

Usage: download_blocks.py <file-with-one-gs-url-per-line>
"""
import os, subprocess, sys, time
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

CACHE = os.environ.get("BLOCK_CACHE", "/tmp/opencode/blk")
os.makedirs(CACHE, exist_ok=True)

sources = [l.strip() for l in open(sys.argv[1]) if l.strip()]
todo = []
for s in sources:
    c = s.rsplit("/", 1)[-1]
    if not os.path.exists(os.path.join(CACHE, c)):
        todo.append((s, c))
print(f"needed={len(sources)} already_cached={len(sources)-len(todo)} to_download={len(todo)}", flush=True)
if not todo:
    sys.exit(0)

tok = subprocess.check_output(["gcloud", "auth", "print-access-token"]).decode().strip()
H = {"Authorization": f"Bearer {tok}"}
sess = requests.Session()


def one(item):
    s, c = item
    parts = s.split("/", 3)
    b, o = parts[2], parts[3]
    url = f"https://storage.googleapis.com/storage/v1/b/{b}/o/{requests.utils.quote(o, safe='')}?alt=media"
    for _ in range(4):
        try:
            r = sess.get(url, headers=H, timeout=90)
            if r.status_code == 200:
                tmp = os.path.join(CACHE, c + ".part")
                with open(tmp, "wb") as f:
                    f.write(r.content)
                os.replace(tmp, os.path.join(CACHE, c))
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


ok = 0
with ThreadPoolExecutor(max_workers=32) as ex:
    futs = [ex.submit(one, i) for i in todo]
    for n, f in enumerate(as_completed(futs), 1):
        if f.result():
            ok += 1
        if n % 1000 == 0:
            print(f"  {n}/{len(todo)}", flush=True)
print(f"downloaded={ok}/{len(todo)}")
