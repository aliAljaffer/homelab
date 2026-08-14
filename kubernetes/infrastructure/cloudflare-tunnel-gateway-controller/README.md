# cloudflare-tunnel-gateway-controller

- `gateway.yaml`: the controller takes exclusive ownership of this tunnel's ingress config. Never add manual routes to it in the Cloudflare dashboard.
- `networkpolicy.yaml`: covers Egress for the proxy pods plus all traffic for the controller pod. Ingress for the proxy pods already comes from the chart itself (`proxy.networkPolicy.ingress` in `values.yaml`), don't duplicate it here.
  - `grafana` rule targets port 3000, not 80. `monitoring-grafana`'s Service is 80 -> targetPort 3000, and Cilium enforces on the post-DNAT port.
  - Cloudflare edge egress (UDP/7844) allows `world` instead of a CIDR. Cloudflare's anycast IP pool rotates, so pinning CIDRs would drift.
  - Controller -> Cloudflare API egress (`api.cloudflare.com:443`) is unconfirmed live, no route change happened during the audit capture. Confirm once a route changes and check audit-mode logs.
