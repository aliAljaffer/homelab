# excalidraw

Self-hosted Excalidraw at <https://excalidraw.alialjaffer.com>, built from the
fork in [aliAljaffer/excalidraw](https://github.com/aliAljaffer/excalidraw).

One public hostname, four backends:

| Path | Backend | Purpose |
| --- | --- | --- |
| `/socket.io` | `excalidraw-room` | live collaboration (WebSocket) |
| `/api/v2` | `excalidraw-scenes` | share links and their images |
| `/` (exact) | `oauth2-proxy` | the editor, behind a login |
| everything else | `excalidraw` | the static app |

## Access model

The app is public because every link I send points at `/s/`: a share link is
`https://excalidraw.alialjaffer.com/s/#json=<id>,<key>`, a collaboration link is
`/s/#room=<id>,<key>`. Only the bare root and the proxy's own `/oauth2/*` paths
demand a login, so boards (session 2) land behind the proxy too.

Gateway API picks the longest matching path prefix, so the public rules win over
the catch-all whatever order they appear in. Verify a new path with `curl` from
a private window before trusting it.

`excalidraw-scenes` is the Go service in the fork's `backend/`. It stores opaque
blobs: the browser encrypts with a key that stays in the URL fragment, so the
service cannot read a scene. Rows are deleted after 90 days.

## Images

All three are built on the `arc-runner-excalidraw` scale set and pushed to
Harbor by the fork's `images` workflow, which then pins the digests here.
Nothing is built from this repository.

- `harbor.alialjaffer.com/mirror/excalidraw`
- `harbor.alialjaffer.com/mirror/excalidraw-scenes`
- `harbor.alialjaffer.com/mirror/excalidraw-room`

`excalidraw-room` is the upstream collaboration server, vendored into the fork
under `room/` and rebuilt on Node 24. It accepts a comma-separated
`CORS_ORIGIN`, rejects room ids outside `[A-Za-z0-9_-]{1,64}`, caps clients per
room (`MAX_CLIENTS_PER_ROOM`), and speaks websocket only.

The app image carries `nginx.conf` from the fork root: CSP, `no-referrer`,
`nosniff`, HSTS, the `/s/` SPA fallback, and long-lived `/assets` and `/fonts`
caching.

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
  `CF-Connecting-IP`).
- Rate limiting at the edge is not in Git. Create two Cloudflare WAF rate
  limiting rules for `alialjaffer.com` by hand:
  - `excalidraw-scenes-uploads`: `startswith(http.request.uri.path, "/api/v2")`,
    30 requests per minute per IP, action block for 1 minute.
  - `excalidraw-socket`: `starts_with(http.request.uri.path, "/socket.io")`,
    120 requests per minute per IP, action block for 1 minute.
- The gateway proxy must be allowed to reach this namespace; see the egress
  allowlist in `kubernetes/infrastructure/cloudflare-tunnel-gateway-controller`.
- The login client is the shared `oauth2-proxy` Keycloak client; its redirect
  URI for this hostname lives in
  `kubernetes/infrastructure/keycloak/keycloak-realm-homelab.yaml` and must also
  be added to the live realm (the realm import does not update an existing
  realm).
