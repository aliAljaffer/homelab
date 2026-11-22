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
- `backup-cronjob.yaml` — nightly restic backup to Cloudflare R2 (see below).

## Providers

| Provider | Auth | Used for |
|---|---|---|
| `anthropic` | `ANTHROPIC_TOKEN` from `claude setup-token` (CLI-minted, no API key) | main model `claude-sonnet-5`, planner subagents |
| `opencode-go` | `OPENCODE_GO_API_KEY` | fallbacks and `Fast-C` delegation |
| `commandcode` | `COMMANDCODE_API_KEY` | `Fast-A`/`Fast-B` delegation, planner |

`config.yaml` sets `model.provider: anthropic` explicitly. A bare `model: claude-sonnet-5` has no
provider attached, and Hermes then routes the request to whichever provider holds a key, which was
`opencode-go` and produced a wrong-relay request.

The Anthropic credential is a setup token minted by the Claude Code CLI on the workstation, sealed
into `hermes-providers` as `ANTHROPIC_TOKEN`, and read by the provider at startup. The image's own
`hermes auth add anthropic --type oauth` flow does not work from here: the build it shipped in posts
to an OAuth endpoint Anthropic now answers with 404. Do not mount a copy of your laptop's
`~/.claude/.credentials.json` either: those refresh tokens are single-use and rotate, so sharing one
family with the CLI breaks whichever side refreshes second. That is why
`auth.adopt_external_logins` is `false`.

Rotate it with `claude setup-token` and reseal `hermes-providers`.

## Tailnet access

`ingress-tailnet.yaml` publishes the gateway through the cluster's `tailscale` IngressClass in the
operator's classic per-ingress mode (a dedicated `ts-hermes-tailnet` proxy). MagicDNS name `hermes`,
certificate issued by the Tailscale operator.

```sh
open https://hermes.tail6c5083.ts.net
```

Deliberately NOT on the shared `tailnet-ingress` proxy group (unlike argocd, minio, nexotv, pihole
and stremio): on operator v1.104.7 the proxy-group pods serve TLS only on stale legacy tailnet IPs
and refuse their own current addresses, and its DNS record never followed the live replicas —
which is what made hermes crawl from home. If the classic proxy ever misbehaves the same way,
check the operator version first.

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

## Backups

`backup-cronjob.yaml` runs restic nightly at 03:00 against
`s3:https://<account>.r2.cloudflarestorage.com/my-hermes`, keeping 7 daily and 4 weekly snapshots.
Credentials live in the sealed `hermes-backup` Secret (`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`,
`RESTIC_PASSWORD`). The restic password is the only thing protecting the repository contents, so it
also belongs in your password manager; without it the snapshots cannot be read.

The job mounts `hermes-data` read-only at `/opt/data` and uses pod affinity to land on the node that
already holds that ReadWriteOnce volume.

Restore a file or the whole tree:

```sh
kubectl -n hermes create job --from=cronjob/hermes-backup hermes-restore-manual   # then override args
# or interactively:
kubectl -n hermes run restic --rm -it --image=restic/restic:0.16.4 \
  --overrides='{"spec":{"containers":[{"name":"restic","image":"restic/restic:0.16.4","command":["/bin/sh"],"stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"hermes-backup"}}],"env":[{"name":"RESTIC_REPOSITORY","value":"s3:https://<account>.r2.cloudflarestorage.com/my-hermes"},{"name":"AWS_DEFAULT_REGION","value":"auto"}]}]}}' -- /bin/sh
```

`spec.backup` is disabled on purpose. The 0.2.0 operator renders a restic Job with no `/tmp` mount
under a read-only rootfs (`mktemp: Read-only file system`) and still points at the pre-`/opt/data`
Hermes home. The block is kept commented in `hermesinstance.yaml`; switch back once upstream ships
the fix that is already on their `main`.

## Notes

- The image is the official `nousresearch/hermes-agent`, currently `v0.23.3`. The operator's
  `ghcr.io/stubbi/hermes-agent` mirror stopped at `v0.16.0` (its `latest` is the same digest), which
  is five months behind and carries the broken Anthropic OAuth flow. The operator only requires the
  upstream contract (s6 entrypoint, `gateway run`, `HERMES_HOME=/opt/data`), which the official image
  keeps.
- NetworkPolicy is operator-managed: default-deny, DNS, TCP 443 egress, ingress only from the same
  namespace. The tailnet proxy group reaches the Service from outside the namespace, so keep
  `additionalEgress` in mind if a self-hosted provider listens on another port.
- `platforms.telegram` is off. Turning a gateway on needs its bot token sealed and wired like the
  provider keys.
- Metrics are not enabled.
- The operator does not roll the pod when the ConfigMap changes, so after editing `configmap.yaml`
  run `kubectl -n hermes delete pod hermes-0` (Argo recreates it).
