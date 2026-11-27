# omniroute

[OmniRoute](https://github.com/cheaper-inference/OmniRoute), a self-hosted AI gateway:
one OpenAI-compatible endpoint in front of many providers, with quota-aware
fallback and a dashboard. Deployed into its own namespace by the `workloads`
ApplicationSet.

## Shape

- `deployment.yaml` — one replica, `Recreate` strategy, image pinned to the
  Harbor mirror. OmniRoute is a single Node process over one SQLite file, so a
  second pod would corrupt the database.
- `pvc.yaml` — 10Gi Longhorn RWO volume at `/app/data` (SQLite plus provider
  credentials).
- `configmap.yaml` — non-secret runtime settings. `REQUIRE_API_KEY=true`, so all
  `/v1/*` calls need a key; the dashboard keeps its own password login.
- `omniroute-secrets.sealed.yaml` — `JWT_SECRET`, `API_KEY_SECRET`,
  `STORAGE_ENCRYPTION_KEY`, `INITIAL_PASSWORD`.
- `ingress-tailnet.yaml` — `omniroute.tail6c5083.ts.net`, TLS from the Tailscale
  operator. Tailnet-only; nothing is exposed publicly.

## First login

```sh
kubectl -n omniroute get secret omniroute-secrets \
  -o jsonpath='{.data.INITIAL_PASSWORD}' | base64 -d; echo
```

Use the password at `https://omniroute.tail6c5083.ts.net`, then change it in
Settings → Security. `INITIAL_PASSWORD` only seeds the first boot; the saved
password lives in the database.

Create API keys in the dashboard and use
`https://omniroute.tail6c5083.ts.net/v1` as the base URL for OpenAI-compatible
clients.

## Things that break

- The first boot runs SQLite migrations and may rebuild the database; the
  startup probe allows ten minutes. Readiness hides the pod until it answers.
- `STORAGE_ENCRYPTION_KEY` encrypts provider credentials at rest. Without it the
  stored provider connections are unreadable. It is in the sealed Secret, and
  the Longhorn backup covers `/app/data`, but keep a copy outside the cluster.
- Do not scale the Deployment. Throughput comes from separate releases, each
  with its own volume.
- `AUTH_COOKIE_SECURE=true` assumes HTTPS, which the Tailscale proxy provides.
  Reaching the Service by plain `kubectl port-forward` will not set a session
  cookie; use the ts.net name for the dashboard.
- The dashboard's live WebSocket is on port 20132 and is not routed through the
  Ingress. The browser falls back to polling; the rest of the UI is unaffected.
