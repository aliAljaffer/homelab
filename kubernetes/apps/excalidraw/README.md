# excalidraw

Self-hosted Excalidraw at <https://excalidraw.alialjaffer.com>, built from the
fork in [aliAljaffer/excalidraw](https://github.com/aliAljaffer/excalidraw).

One public hostname, four backends:

| Path | Backend | Purpose |
| --- | --- | --- |
| `/socket.io` | `excalidraw-room` | live collaboration (WebSocket) |
| `/api/v2` | `excalidraw-scenes` | share links and their images |
| `/` (exact) | `oauth2-proxy` | the editor, behind a login |
| `/b/` | `oauth2-proxy` | one board open in the editor |
| `/api/boards` | `oauth2-proxy` then `excalidraw` then `excalidraw-scenes` | the board gallery and its scenes |
| `/libraries/` | `oauth2-proxy` then `excalidraw` | icon libraries for the library panel |
| everything else | `excalidraw` | the static app |

## Access model

The app is public because every link I send points at `/s/`: a share link is
`https://excalidraw.alialjaffer.com/s/#json=<id>,<key>`, a collaboration link is
`/s/#room=<id>,<key>`. The private paths are the bare root, a board at `/b/`,
and the boards API. A board is a private document: it opens from `/b/<id>`,
autosaves through `/api/boards`, and never joins a room. Sharing is a separate,
explicit action in the Share dialog.

Gateway API picks the longest matching path prefix, so the public rules win over
the catch-all whatever order they appear in. Verify a new path with `curl` from
a private window before trusting it.

`excalidraw-scenes` is the Go service in the fork's `backend/`. It stores opaque
blobs: the browser encrypts with a key that stays in the URL fragment, so the
service cannot read a share-link scene. Rows are deleted after 90 days. Board
rooms are exempt while a board points at them.

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

The room Service port declares `appProtocol: kubernetes.io/ws`. Without it the
tunnel gateway forwards the upgrade as plain HTTP and every socket gets a 502.
That one field is the difference between a working room and a silent failure.

The app image carries `nginx.conf.template` from the fork root, rendered by the
image entrypoint so the gallery resolver comes from the pod's own
`resolv.conf`. It holds the CSP, `no-referrer`, `nosniff`, HSTS, the `/s/` SPA
fallback, long-lived `/assets` and `/fonts` caching, and the `/boards` proxy to
`excalidraw-scenes`. That proxy resolves per request: a missing gallery upstream
must never stop nginx, or share links would go down with it.

## Icons

The editor ships five icon libraries for the library panel: AWS, Google Cloud,
Kubernetes, Alibaba Cloud, and DevOps tooling (CNCF artwork plus the devicons
set). They are generated at image build time by the fork's
`scripts/build-icon-libraries.mjs`, which downloads the vendor SVGs into
`public/libraries/` as one `.excalidrawlib` per system plus a
`libraries.json` manifest. Nothing is stored in this repository.

The app fetches the manifest from `/libraries/` on load and merges the items
into the browser's library once per manifest version, then keeps them in
IndexedDB. Re-seeding replaces the previous icon items because the build gives
them deterministic ids. The path sits behind the login like the editor, so the
vendor art is never served to a guest.

`excalidraw` in the fork is patched so a library item can carry the binary
files its image elements reference: import, export, preview render and insert
all keep them. Upstream drops them, which is why its own icon libraries are
hand-drawn shapes.

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
