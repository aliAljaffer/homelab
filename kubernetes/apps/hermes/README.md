# hermes

[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research) on Kubernetes, run by the
[hermes-operator](https://github.com/stubbi/hermes-operator). Auto-onboarded by the `workloads`
ApplicationSet; the operator itself is `kubernetes/argocd/apps/infrastructure/hermes-operator.yaml`.

## Shape

- `hermesinstance.yaml` — one `HermesInstance` named `hermes`: StatefulSet, Service on 8443
  (gateway + OpenAI-compatible API server), 100Gi Longhorn PVC on `/opt/data`.
- `configmap.yaml` — the full `config.yaml` Hermes runs with. It is `hermes-agent-config`, not
  `hermes-config`: the operator owns `<instance>-config` and adds its own keys there.
- `hermes-providers.sealed.yaml` — `OPENCODE_GO_API_KEY`, `COMMANDCODE_API_KEY` (injected via
  `spec.envFrom`).
- `hermes-fai.sealed.yaml` — the Fai MCP agent key, injected as `FAI_AGENT_KEY` and referenced from
  `config.yaml` as `Bearer ${FAI_AGENT_KEY}`.
- `ingress-tailnet.yaml` — the tailnet route (see below).

## Providers

| Provider | Auth | Used for |
|---|---|---|
| `anthropic` | `hermes auth add anthropic --type oauth` inside the pod (paste-the-code, no API key) | main model `claude-sonnet-5`, planner subagents |
| `opencode-go` | `OPENCODE_GO_API_KEY` | fallbacks and `Fast-C` delegation |
| `commandcode` | `COMMANDCODE_API_KEY` | `Fast-A`/`Fast-B` delegation, planner |

`config.yaml` sets `model.provider: anthropic` explicitly. A bare `model: claude-sonnet-5` has no
provider attached, and Hermes then routes the request to whichever provider holds a key, which was
`opencode-go` and produced a wrong-relay request.

Anthropic OAuth is a Hermes-owned credential stored in `/opt/data/auth.json` on the PVC, so it
survives restarts. It needs Claude Max with extra usage credits. Do not mount a copy of your
laptop's `~/.claude/.credentials.json`: those refresh tokens are single-use and rotate, so sharing
one family with the CLI breaks whichever side refreshes second. That is why
`auth.adopt_external_logins` is `false` here.

Authorize once:

```sh
kubectl -n hermes exec -it hermes-0 -- hermes auth add anthropic --type oauth
kubectl -n hermes exec -it hermes-0 -- hermes auth status anthropic
```

The flow prints an authorize URL and waits for you to paste the code back, so it works over plain
`kubectl exec` with no tunnel. Until it is done, every turn fails on the main model and falls back
to `opencode-go`.

## Tailnet access

`ingress-tailnet.yaml` publishes the gateway through the cluster's `tailscale` IngressClass and the
shared `tailnet-ingress` proxy group, the same way argocd, minio, nexotv, pihole and stremio are
published. MagicDNS name `hermes`, certificate issued by the Tailscale operator.

```sh
open https://hermes.tail6c5083.ts.net
```

`spec.tailscale` is deliberately off. The operator's Serve sidecar cannot start in-cluster:
its ServiceAccount sets `automountServiceAccountToken: false`, so `containerboot` fails at kube
client init (`open /var/run/secrets/kubernetes.io/serviceaccount/namespace: no such file`). With a
token injected by hand it then fails on the `tailscale` state Secret, and with that Secret and RBAC
in place it fails on state reset. Revisit when upstream ships a fix.

## Fai

Fai's MCP endpoint (`https://fai.alialjaffer.com/mcp`) is wired under `mcp_servers.fai`, authenticated
with `FAI_AGENT_KEY`. Verified from inside the pod:

```sh
kubectl -n hermes exec hermes-0 -- hermes mcp test fai
```

## Notes

- The image comes from the Harbor `mirror` project by digest. The `ghcr.io` pull-through cache
  truncates the 3.7 GB agent image, so the image is copied into `mirror` and pinned instead. To bump
  it: `crane copy --platform linux/amd64 ghcr.io/stubbi/hermes-agent:<tag>
  harbor.alialjaffer.com/mirror/stubbi/hermes-agent:<tag>`, then update `spec.image.digest`.
- NetworkPolicy is operator-managed: default-deny, DNS, TCP 443 egress, ingress only from the same
  namespace. The tailnet proxy group reaches the Service from outside the namespace, so keep
  `additionalEgress` in mind if a self-hosted provider listens on another port.
- `platforms.telegram` is off. Turning a gateway on needs its bot token sealed and wired like the
  provider keys.
- Metrics and S3 backups are not enabled.
- The operator does not roll the pod when the ConfigMap changes, so after editing `configmap.yaml`
  run `kubectl -n hermes delete pod hermes-0` (Argo recreates it).
