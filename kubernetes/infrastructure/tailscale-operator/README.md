# tailscale-operator

Tailscale Kubernetes operator plus one Connector that advertises the LAN.

- `operator-oauth.sealed.yaml`: precreated OAuth credentials Secret. The chart
  mounts a fixed-name Secret `operator-oauth` with keys `client_id` and
  `client_secret` whenever the `oauth` value block is empty, so the credentials
  never enter `values.yaml`. The client is scoped to `tag:k8s-operator`.
- `connector-lan.yaml`: subnet router for `192.168.8.0/24`. Cluster-scoped CRD.
  The `SkipDryRunOnMissingResource` annotation is required because the Connector
  CRD ships in the same ArgoCD sync. The route is auto-approved through
  `autoApprovers` in `policy.hujson` for `tag:k8s`.
- `policy.hujson`: tailnet policy, applied through the API and not by ArgoCD.
  Validate before posting:

  ```bash
  source /tmp/TS_MCP
  curl -X POST -H "Authorization: Bearer $API_KEY" --data-binary @policy.hujson \
    "https://api.tailscale.com/api/v2/tailnet/$TAILNET/acl/validate"
  curl -X POST -H "Authorization: Bearer $API_KEY" --data-binary @policy.hujson \
    "https://api.tailscale.com/api/v2/tailnet/$TAILNET/acl"
  ```

  The Kubernetes capability grant maps `autogroup:member` to `system:masters`,
  which is fine for one user. Narrow `src` before adding a second.
- Chart version equals the operator and proxy image version. Do not set
  `proxyConfig.image.tag`; bumping `targetRevision` moves them together.
- API server proxy runs in auth mode. It needs HTTPS certificates enabled for
  the tailnet (admin console, DNS page). Tailnet DNS settings are otherwise left
  alone: public Cloudflare records already resolve LAN hostnames to
  `192.168.8.129`, and the subnet router makes that address reachable.
