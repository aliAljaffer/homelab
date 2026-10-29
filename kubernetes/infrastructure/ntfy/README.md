# ntfy

Shared, cluster-wide [ntfy](https://ntfy.sh) server so any homelab app can push
notifications to iOS (or other subscribers), not scoped to any one app. First
consumer: `fai`'s reminders and meeting-outcome prompts.

Registered as a hand-written ArgoCD Application (`kubernetes/argocd/apps/infrastructure/ntfy.yaml`),
not the `workloads` ApplicationSet — that only covers `kubernetes/apps/*`. Sync-wave
`"1"`, after `cloudflare-tunnel-gateway-controller` (wave `"0"`) and `external-dns`
(wave `"-2"`), so its HTTPRoute isn't created before the Gateway/DNS controller exist.

## Design

- **Auth is the real access gate, not topic-name obscurity**: `auth-default-access:
  deny-all` in `server.yml`. Topic names are still kept non-guessable as
  defense-in-depth (see `fai`'s `fai-secret.sealed.yaml` for its actual topic name).
- Two bootstrapped users, idempotently created by an initContainer on every pod
  (re)start (`ntfy user --auth-file ... add --ignore-exists ...` no-ops once a user
  exists — verified directly against the real image before writing this):
  - `ali` — admin, used to subscribe from the iOS app.
  - `fai-publisher` — write-only on the `tasks-*` topic pattern, used by `fai`'s
    `internal/ntfy` client. The same password is sealed in both
    `ntfy-credentials.sealed.yaml` here and `fai-secret.sealed.yaml` in
    `kubernetes/apps/fai/` — they must match.
- **Delegates iOS push delivery to ntfy.sh** (`upstream-base-url`) rather than running
  a self-hosted Firebase/APNs project: ntfy.sh's relay sees the topic name and that an
  event occurred, not the message body. This is ntfy's own recommended pattern for
  solo self-hosters and the pragmatic choice here.
- Plain `Deployment` + PVC + `Recreate` strategy (not a StatefulSet) — single
  replica, same shape as `vaultwarden`'s.

## Public exposure

Two hostnames, because ntfy has no OIDC support (ntfy#1596) and no trusted-header
auth (ntfy#1971), so a reverse proxy can never become ntfy's identity source:

- `ntfy.alialjaffer.com` → `oauth2-proxy` (shared Keycloak `homelab` realm client,
  see `kubernetes/components/oauth2-proxy`) → ntfy. Hides the public web UI shell
  behind a Keycloak login. The web app still asks for the `ali` ntfy credentials
  once afterwards — double auth is unavoidable without header auth in ntfy.
- `ntfy-api.alialjaffer.com` → ntfy directly, ntfy's own auth only. This is what
  the iOS app must be configured with; it cannot follow an OIDC redirect. Same
  exposure as before: publish/subscribe are `deny-all`, `/` and `/v1/health` are
  public.

Both hostnames serve the same ntfy process, so `https://ntfy-api.../` also loads
the web app shell. Gating the UI is therefore per-hostname and cosmetic; the data
is protected by ntfy's auth on both. To hide it on the api host too you'd need a
Cloudflare WAF rule (not managed in this repo) — ntfy's `web-root: disable` would
also kill the UI on the gated hostname.

`base-url` stays on the UI hostname. That does not affect iOS push: the relay's
poll request carries only topic + id, and the app polls the server URL configured
in the app (the api host).

The `oauth2-proxy` Keycloak client already existed as a declaration in
`keycloak-realm-homelab.yaml` but not live (the realm predates it), so it was
created by hand with the same settings — see the re-import caveat in
`kubernetes/components/oauth2-proxy/README.md`.

## How an app publishes

In-cluster, via the Service — not the public hostname, to avoid a pointless hairpin
through Cloudflare:

```
POST http://ntfy.ntfy.svc.cluster.local/
Authorization: Basic <fai-publisher creds>
Content-Type: application/json

{"topic": "tasks-...", "title": "...", "message": "..."}
```

The `NetworkPolicy` allows ingress from the `fai` namespace specifically; add the
publishing app's namespace there too if a future app wants to use this server.
