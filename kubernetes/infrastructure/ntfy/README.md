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
