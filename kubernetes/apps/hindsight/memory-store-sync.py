# Usage: memory-store-sync.py <memory-store checkout>
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse
import urllib.request

API = os.environ["HINDSIGHT_API_URL"]
BANK = os.environ["HINDSIGHT_BANK_ID"]
KEY = os.environ["HINDSIGHT_API_KEY"]
TAG = "source:memory-store"
STRATEGY = "memory-store"
PREFIX = "memory-store/"
SKIP = {"INDEX.md", "README.md", "TEMPLATE.md", "_INDEX.md"}


def call(method, path, body=None):
    req = urllib.request.Request(
        f"{API}/v1/default/banks/{BANK}{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def local_entries(repo):
    entries = {}
    for path in sorted(repo.rglob("*.md")):
        rel = path.relative_to(repo)
        if rel.parts[0] == ".git" or path.name in SKIP:
            continue
        data = path.read_bytes()
        entries[PREFIX + rel.as_posix()] = (rel, data.decode(), hashlib.sha256(data).hexdigest())
    return entries


def remote_hashes():
    query = urllib.parse.urlencode({"tags": TAG, "limit": 1000})
    items = call("GET", f"/documents?{query}")["items"]
    return {d["id"]: (d.get("document_metadata") or {}).get("sha256") for d in items}


def main():
    repo = pathlib.Path(sys.argv[1])
    # The bank-wide custom policy drops anything already written down, which is all of memory-store.
    call("PATCH", "/config", {"updates": {"retain_strategies": {STRATEGY: {"retain_extraction_mode": "verbatim"}}}})

    local = local_entries(repo)
    remote = remote_hashes()

    items = [
        {
            "content": text,
            "document_id": doc_id,
            "timestamp": "unset",
            "context": "memory-store entry: a solved problem, its root cause, and the fix",
            "metadata": {"sha256": sha, "path": rel.as_posix()},
            "tags": [TAG, f"domain:{rel.parts[0]}"],
            "strategy": STRATEGY,
        }
        for doc_id, (rel, text, sha) in local.items()
        if remote.get(doc_id) != sha
    ]
    if items:
        call("POST", "/memories", {"items": items, "async": True})

    stale = sorted(set(remote) - set(local))
    # Deletes are rare (an entry removed from the repo), so one at a time is fine.
    for doc_id in stale:
        call("DELETE", "/documents/" + urllib.parse.quote(doc_id, safe="/"))

    print(f"local={len(local)} retained={len(items)} deleted={len(stale)}")


if __name__ == "__main__":
    main()
