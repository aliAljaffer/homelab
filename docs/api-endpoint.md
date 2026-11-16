# Cluster API endpoint (floating VIP)

The Kubernetes API used to be reachable only at `192.168.8.99` (cp0), so losing
cp0 took the API down even though etcd had quorum. It is now fronted by a
**Talos floating VIP** and a DNS name:

| Item | Value |
|---|---|
| Control-plane endpoint | `https://api.alialjaffer.com:6443` |
| Floating VIP | `192.168.8.250` (shared by `cp0`, `wrk0`, `wrk1`) |
| Public DNS | Cloudflare `A api.alialjaffer.com -> 192.168.8.250` (DNS-only) |

## How it is wired

- **VIP** - each control plane runs `machine.network.interfaces[].vip.ip =
  192.168.8.250` (see the `vip:` block per node in `talos/talconfig.yaml`).
  Talos keeps the VIP on one healthy control-plane node (gratuitous ARP) and
  moves it if that node goes away.
- **Serving cert** - the kube-apiserver cert must be valid for the name and the
  VIP. Both are added via `additionalApiServerCertSans` in `talconfig.yaml`
  (renders to `cluster.apiServer.certSANs`):
  `api.alialjaffer.com`, `192.168.8.250`.
- **Endpoint** - `endpoint: https://api.alialjaffer.com:6443` in
  `talconfig.yaml` (renders to `cluster.controlPlane.endpoint` on every node).
- **Cilium** - `k8sServiceHost: 192.168.8.250` in
  `kubernetes/bootstrap/cilium/values.yaml`. With `kubeProxyReplacement: true`
  the cilium-agent uses this address for its own API access, so point it at the
  VIP instead of a single control plane (it was `192.168.8.99`, i.e. cp0 only).
- **DNS** - `api.alialjaffer.com` -> `192.168.8.250`, created out of band in
  Cloudflare (DNS-only, private IP - same pattern as the other internal
  `*.alialjaffer.com` records). external-dns does not manage this record.
- **Remote access** - the cloudflared tunnel targets the VIP, not a single node:
  `k.alialjaffer.com -> tcp://192.168.8.250:6443` and
  `t.alialjaffer.com -> tcp://192.168.8.250:50000`
  (`kubernetes/apps/cloudflared/config.yaml`).

## Client config

### kubectl

The homelab kubeconfig is `~/.kube/homelab-talos` and it talks to the VIP
directly, so it needs no DNS:

```bash
export KUBECONFIG=~/.kube/homelab-talos
kubectl config view --minify \
  -o jsonpath='{.contexts[0].name} {.clusters[0].cluster.server}{"\n"}'
# admin@k8s-homelab https://192.168.8.250:6443
```

`~/.kube/config` is **not** this cluster. It holds one unrelated work context,
so `kubectl` with no `KUBECONFIG` does not reach the homelab.

Off-LAN, use the API server proxy, which needs no subnet route:

```bash
tailscale configure kubeconfig tailscale-operator   # writes ~/.kube/homelab-ts
KUBECONFIG=~/.kube/homelab-ts kubectl get nodes
```

`~/.kube/homelab-ts` points at `https://tailscale-operator.tail6c5083.ts.net`.

### talosctl

`talosctl` needs a talosconfig that holds a client certificate. If
`~/.talos/config` is empty (`context: ""`, `contexts: {}`), every command stops
at `talos config file is empty` before it touches the network. A working copy
lives on `ssh.alialjaffer.com`:

```bash
scp ssh.alialjaffer.com:~/.talos/config ~/.talos/config
talosctl config endpoint 192.168.8.99 192.168.8.101 192.168.8.102
talosctl config info
```

Expect `Current context: k8s-homelab`, `Roles: os:admin`, and a certificate
valid until 2027-07-28.

Endpoints are the three control planes (`cp0`, `wrk0`, `wrk1`), not the VIP.
Port 50000 is served per node, and the VIP only carries the API on 6443.

The repo holds no Talos secrets bundle (`talsecret.yaml`), so the talosconfig
cannot be regenerated from git. Keep a copy outside the repo.

## Operational notes

- The node endpoint is a **DNS name**, so control-plane nodes must be able to
  resolve `api.alialjaffer.com` (they resolve it via their DHCP nameserver ->
  Cloudflare). If DNS is down, nodes still run (kubelet talks to the API through
  local kubePrism), but regenerated kubeconfigs use the name.
- `talhelper` is **not installed** in this repo checkout. The configs under
  `talos/clusterconfig/*.sops.yaml` were updated in place (via `sops set`) and
  applied with `talosctl apply-config`; `talconfig.yaml` was updated to match so
  a future `talhelper genconfig` reproduces the same result.
- If the VIP ever needs to change, update it in three places: `talconfig.yaml`,
  each control-plane `*.sops.yaml`, and the Cloudflare record.
