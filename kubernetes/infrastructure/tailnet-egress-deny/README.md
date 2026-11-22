# tailnet-egress-deny

Cluster-wide Cilium egress deny for the tailnet. Every namespace loses egress
to Tailscale addresses except `hermes` (its userspace tailscale sidecar is a
tailnet device) and `tailscale` (operator, Connector subnet router, ProxyGroup
ingress proxies, API server proxy).

## Shape

Two `CiliumClusterwideNetworkPolicy` objects, selected by namespace name
(Cilium selectors cannot glob `hermes*`):

- `deny-tailnet.yaml`: `In` the namespaces that already manage their own
  egress posture, with ONLY an `egressDeny` (100.64.0.0/10 +
  fd7a:115c:a1e0::/48). Their own CNPs stay intact; they just gain the
  tailnet deny.
- `egress-default.yaml`: `NotIn` the above plus the two exemptions, with
  explicit allow rules for every traffic identity (`cluster`, `world`, `host`,
  `remote-node`, `kube-apiserver`, `init`) plus the same deny. A deny-only
  rule would flip these pods into egress enforcement and sever their egress,
  so the allows preserve today's behavior minus the tailnet. Note: an empty
  allow rule (`egress: - {}`) compiles to no allow on Cilium 1.17, so the
  identity list is spelled out.

The two lists must stay mirrored. When a namespace gains its own
egress-enforcing policy, move its name into `deny-tailnet.yaml`; until then
`tailnet-egress-default`'s allow-all neuters that new default-deny. A newly
created namespace automatically lands in `tailnet-egress-default`: tailnet
denied, egress otherwise unchanged.

A new `hermes-*` namespace must be added to both exemption lists, or its
tailscale sidecar loses tailnet access.

## Why 100.64.0.0/10 and not 100.0.0.0/8

Tailscale draws every node, Service and MagicDNS address from RFC 6598
"Shared Address Space" (CGNAT), which IANA reserves so it is never publicly
routed: no real public IP lives in 100.64.0.0/10. The lower half of
100.0.0.0/8 (100.0.0.0/10) is ordinary public IPv4 space, so a /8 deny would
block legitimate internet hosts.

## Limits

- Egress only. Inbound tailnet traffic arrives via the ProxyGroup proxies and
  the Connector (`tailscale` namespace) or the node tailscaled (host level);
  replies to allowed inbound flows are conntracked, so tailnet-to-pod access
  keeps working everywhere.
- A userspace-networking tailscale sidecar (like hermes') never sends packets
  to 100.64.0.0/10; its WireGuard egress targets DERP relays and peer
  endpoints. The CIDR deny cannot stop such a sidecar, which is also why the
  deny is safe to bypass by exemption for hermes.
- MagicDNS (100.100.100.100) and Tailscale Service IPs fall inside
  100.64.0.0/10 and are covered. The IPv6 ULA fd7a:115c:a1e0::/48 is denied
  for when dual-stack lands; IPv6 is currently disabled cluster-wide.
- Enforcement is global, not per-policy: Cilium `policy-audit-mode` is either
  on for the whole dataplane or off. While it is on, this policy (and every
  other Cilium policy) only logs would-be drops.

## Namespace list snapshot (2026-11-22)

In `deny-tailnet.yaml` (enforced by their own policies): assets,
catus-locatus, chat, cloudflare-tunnel-system, excalidraw, fai, grooszy,
keycloak, livesync, mail, monitoring, ntfy, pihole, remediator, stt, umami,
vaultwarden.

Exempt: hermes, tailscale.

Everything else (argocd, cert-manager, cnpg-system, external-dns, harbor,
kube-system, longhorn-system, metallb-system, stremio, tuwaiq-tracker, ...)
lands in `tailnet-egress-default` by exclusion.

Note: the `assets-default` CiliumNetworkPolicy was applied out-of-band with
plain kubectl and has no source file in this repo.
