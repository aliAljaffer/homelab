# pihole

Notes on files where the gotcha isn't obvious from the YAML alone.

- `networkpolicy.yaml`: default-deny CiliumNetworkPolicy, not yet wired into `kustomization.yaml`. Apply only after `policyAuditMode: true` in `kubernetes/bootstrap/cilium/values.yaml` is rolled out and confirmed live, so a mistake here logs instead of dropping real traffic. `pihole-dns` and `pihole-web` are also exposed directly via MetalLB LoadBalancer IPs (`pihole-service-*.yaml`), so LAN clients hit these pods without going through `cloudflare-tunnel-system`. The `192.168.8.0/24` CIDR assumes that's the full LAN range, confirm against the actual subnet before enforcing. Gravity/adlist update egress isn't covered (FQDNs vary by adlist), leave the namespace in audit mode through at least one gravity update cycle and add `toFQDNs` entries before enforcing.
