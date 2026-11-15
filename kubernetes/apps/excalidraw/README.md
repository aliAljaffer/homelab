# excalidraw

Self-hosted Excalidraw at <https://excalidraw.alialjaffer.com>, built from the
fork in [aliAljaffer/excalidraw](https://github.com/aliAljaffer/excalidraw).

One public hostname, three backends:

| Path | Backend | Purpose |
| --- | --- | --- |
| `/socket.io` | `excalidraw-room` | live collaboration (WebSocket) |
| `/api/v2/scenes` | `excalidraw-scenes` | share links and their images |
| `/` | `excalidraw` | the static app |

`excalidraw-scenes` is the Go service in the fork's `backend/`. It stores opaque
blobs: the browser encrypts with a key that stays in the URL fragment, so the
service cannot read a scene. Rows are deleted after 90 days.

## Images

Both are built on the `arc-runner-excalidraw` scale set and pushed to Harbor by
the fork's `images` workflow, which then pins the digests here. Nothing is built
from this repository.

- `harbor.alialjaffer.com/mirror/excalidraw`
- `harbor.alialjaffer.com/mirror/excalidraw-scenes`

`excalidraw-room` is the upstream `excalidraw/excalidraw-room` image, unchanged.

## Storage

`excalidraw-db` is a single-instance CloudNativePG cluster (2Gi Longhorn) with
daily volume snapshots. The credentials come from the `excalidraw-db`
SealedSecret, which is also the `initdb` secret.

```bash
kubectl -n excalidraw get secret excalidraw-db \
  -o jsonpath='{.data.password}' | base64 -d
```

## Notes

- Share links and collaboration are public: anyone with a link can open it. The
  room server holds a scene only while people are connected; persisted share
  links live in Postgres.
- `UPLOADS_PER_HOUR` caps share-link uploads per client IP (Cloudflare's
  `CF-Connecting-IP`). Cloudflare WAF rate limiting is the better place for a
  stricter limit.
- The gateway proxy must be allowed to reach this namespace; see the egress
  allowlist in `kubernetes/infrastructure/cloudflare-tunnel-gateway-controller`.
