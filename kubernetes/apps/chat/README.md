# chat

A ready-made chat API for every app in the homelab. Each calling application
wraps the replies in its own interface. The service owns the model integration,
the per-app prompt, the limits, and the streaming.

| Hostname | Surface | Auth |
|---|---|---|
| `chat-api.alialjaffer.com` | `POST /v1/chat` and `/v1/chat/stream` | Per-app bearer key |

There is no hosted UI and no browser login. The API key is the only gate.

## Architecture

One pod, two containers, no PVC:

- `opencode` listens on `127.0.0.1:4096` with the repository config mounted at
  `/config/opencode.json`. The provider key is written to
  `/opencode/data/opencode/auth.json` at startup when the secret exists. Its
  state, auth file, and session database live in the emptyDir at `/opencode`.
- `gateway` listens on `0.0.0.0:8080`. It loads the app profiles from the
  `chat-apps` Secret, checks app keys, builds the text-only prompt, and proxies to
  OpenCode over loopback. It stores nothing.
- The app profiles live in `apps.json`, mounted read-only at `/apps/apps.json`.
  The file is a Secret because it holds the app keys.

The gateway is text-only by three independent controls: the OpenCode agent has
every tool denied, the per-request prompt sets every known tool to false, and the
gateway never exposes a tool callback to callers.

## Deploy

The ApplicationSet picks up `kubernetes/apps/chat` automatically. The source lives
in [aliAljaffer/chat-gateway](https://github.com/aliAljaffer/chat-gateway). Its
`image` workflow runs the Go checks and pushes
`ghcr.io/alialjaffer/chat-gateway:latest` on every push to `main`. The workflow
then checks out this repository with the `update-manifests-homelab` GitHub App and
commits the new digest to `deployment.yaml`. ArgoCD rolls the pod.

The image is about 202 MiB compressed. Most of it is the Node 22 base and the
OpenCode package. The deployment pins the digest with
`imagePullPolicy: IfNotPresent` and prefers `wrk2`, the node that has this build
cached. Remove the affinity once every worker has pulled the image.

## Apps

The gateway reads `/apps/apps.json` at startup. The file holds one entry per
calling application:

```json
{
  "apps": [
    {
      "id": "grooszy",
      "key": "chat_replace_me_with_a_long_random_key",
      "system_prompt": "You are Gersz. Answer only from the supplied summary."
    }
  ]
}
```

The file is stored in the `chat-apps` Secret and sealed in Git. To add an app or
rotate a key:

1. Edit the JSON with the new key and prompt.
2. Seal it:
   ```bash
   kubectl create secret generic chat-apps -n chat \
     --from-file=apps.json=apps.json \
     --dry-run=client -o yaml \
     | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml \
     > kubernetes/apps/chat/chat-apps.sealed.yaml
   ```
3. Commit the sealed file and restart the deployment:
   ```bash
   kubectl rollout restart deployment/chat -n chat
   ```

The gateway hashes the keys in memory and never writes them to disk. There is no
admin API and no UI. The key is never returned by the API and never logged.

The current `chat-apps` entry is `grooszy`. Its key is the same value in the
`grooszy-chat` Secret. That Secret carries the in-cluster URL and key for the
grooszy API. The Gersz prompt is in the `chat-apps` profile, so the calling app
cannot change it.

## Provider key

The default model is `opencode-go/deepseek-v4.1-flash`. It needs an API key for
the `opencode-go` provider. The gateway starts without the key, but every chat
returns an error until the key exists.

Create the secret once, then seal it for Git. The helper reads the key from the
local OpenCode auth file without printing it, or from `OPENCODE_API_KEY`:

```bash
kubernetes/apps/chat/seal-provider.sh
```

Add `chat-provider.sealed.yaml` to `kustomization.yaml`, commit, and let ArgoCD
reconcile. Then restart the deployment. The script needs a reachable cluster,
because `kubeseal` fetches the controller certificate.

To use another provider, change `CHAT_PROVIDER_ID` in `configmap.yaml` and
`model` in `opencode.json` to the same provider and model.

## Wire an app

Set these on the calling application:

| Variable | Value |
|---|---|
| `CHAT_URL` or equivalent | `http://chat.chat.svc.cluster.local` inside the cluster, or `https://chat-api.alialjaffer.com` outside |
| `CHAT_API_KEY` or equivalent | the key from the app's `chat-apps` entry |

Grooszy uses `GROOSZY_CHAT_URL` and `GROOSZY_CHAT_API_KEY`. The values live in the
`grooszy-chat` Secret, and the network policy allows `grooszy-api` to reach the
chat Service on port 8080.

## API

Both endpoints take a bearer key from the app.

```bash
curl -s -X POST https://chat-api.alialjaffer.com/v1/chat \
  -H "Authorization: Bearer $CHAT_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "How much did I spend in May?"}
    ],
    "context": "May spending was 3,500.00 SAR."
  }'
```

```json
{"reply": "You spent 3,500.00 SAR in May."}
```

`POST /v1/chat/stream` returns server-sent events:

```
event: delta
data: {"text":"You spent "}

event: done
data: {"reply":"You spent 3,500.00 SAR in May."}
```

Rules:

| Rule | Value |
|---|---|
| Messages | 1 to 8 |
| Roles | `user` or `assistant` only |
| Last message | `user` |
| Content | 1 to 2000 characters, not blank |
| Context | optional string, at most 16000 characters |
| Body | 64 KiB |
| Rate limit | 30 requests per minute per app, in memory |

Status codes: `401` for a missing or unknown key, `422` for a bad shape, `429`
for the rate limit, `502` when the model fails, `503` when OpenCode is
unavailable, `504` when the model exceeds the timeout.

The API is stateless. The caller sends the history it wants the model to see. The
gateway creates a short-lived OpenCode session, sends one prompt, and deletes the
session. Neither the gateway nor the OpenCode volume keeps the request after the
session is deleted.

## Operations

```bash
kubectl logs -n chat deploy/chat -c gateway -f
kubectl logs -n chat deploy/chat -c opencode -f
kubectl get pods -n chat
```

`/healthz` reports the process. `/readyz` reports OpenCode health.

Known limits:

- One key per app, configured in the Secret. There is no self-service key
  management.
- The app file is read at startup. Adding an app or rotating a key needs a
  deployment restart.
- The rate limit is in memory and resets on restart.
- The model sees the system prompt, the conversation, and the context. It never
  sees a tool result because it has no tools.
- There is no hosted UI, no conversation history, and no database.
