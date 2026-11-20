# hermes

[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research) on Kubernetes, run by the
[hermes-operator](https://github.com/stubbi/hermes-operator). Auto-onboarded by the `workloads`
ApplicationSet; the operator itself is `kubernetes/argocd/apps/infrastructure/hermes-operator.yaml`.

## Shape

- `hermesinstance.yaml` — one `HermesInstance` named `hermes`: StatefulSet, Service on 8443
  (gateway + OpenAI-compatible API server), 10Gi Longhorn PVC on `/opt/data`.
- `configmap.yaml` — the full `config.yaml` Hermes runs with. Edit this, then push; Argo rolls the pod.
- `hermes-providers.sealed.yaml` — `OPENCODE_GO_API_KEY`, `COMMANDCODE_API_KEY` (injected via
  `spec.envFrom`).
- `hermes-fai.sealed.yaml` — the Fai MCP agent key, injected as `FAI_AGENT_KEY` and referenced from
  `config.yaml` as `Bearer ${FAI_AGENT_KEY}`.
- `hermes-tailscale.sealed.yaml` — reusable + ephemeral Tailscale auth key for the Serve sidecar.

## Providers

| Provider | Auth | Used for |
|---|---|---|
| `anthropic` | `hermes auth add anthropic --type oauth` inside the pod (paste-the-code, no API key) | main model `claude-sonnet-5`, planner subagents |
| `opencode-go` | `OPENCODE_GO_API_KEY` | fallbacks and `Fast-C` delegation |
| `commandcode` | `COMMANDCODE_API_KEY` | `Fast-A`/`Fast-B` delegation, planner |

Anthropic OAuth is a Hermes-owned credential stored in `/opt/data/auth.json` on the PVC, so it
survives restarts. It needs Claude Max with extra usage credits. Do not mount a copy of your
laptop's `~/.claude/.credentials.json`: those refresh tokens are single-use and rotate, so sharing
one family with the CLI breaks whichever side refreshes second. That is why
`auth.adopt_external_logins` is `false` here.

Authorize once the pod is up:

```sh
kubectl -n hermes exec -it hermes-0 -- hermes auth add anthropic --type oauth
kubectl -n hermes exec -it hermes-0 -- hermes auth status anthropic
```

The flow prints an authorize URL and waits for you to paste the code back, so it works over plain
`kubectl exec` with no tunnel.

## Tailnet access

`spec.tailscale.enabled` adds the Tailscale Serve sidecar: MagicDNS hostname `hermes`, TLS cert
issued by Tailscale, proxied to the gateway on localhost. Nothing is exposed on the LAN.

```sh
open https://hermes.tail6c5083.ts.net
```

The auth key must be **reusable and ephemeral** (restart re-registers the same hostname, stopped pod
removes the device). Rotate it by resealing `hermes-tailscale.sealed.yaml`.

## Fai

Fai's MCP endpoint (`https://fai.alialjaffer.com/mcp`) is already wired in `config.yaml` under
`mcp_servers.fai`, authenticated with `FAI_AGENT_KEY`. Confirm from inside the pod:

```sh
kubectl -n hermes exec -it hermes-0 -- hermes mcp test fai
```

## Notes

- The image is pinned to `ghcr.io/stubbi/hermes-agent:v0.16.0`, the newest tag the project
  publishes. `config.yaml` was migrated from a slightly newer local install, so Hermes may log
  warnings about keys it does not know; they are inert. Bump the tag (or switch to
  `spec.image.digest`) when upstream publishes a newer release.
- NetworkPolicy is operator-managed: default-deny, DNS, TCP 443 egress, ingress only from the same
  namespace, plus the UDP rules the Tailscale sidecar needs. Model APIs, Tailscale, and Fai all
  work over 443. Adding a self-hosted provider on another port means adding an egress rule through
  `spec.security.networkPolicy.additionalEgress`.
- `platforms.telegram.enabled` is off. Turning a messaging gateway on needs its bot token sealed
  and wired the same way as the provider keys.
