# Remote Cluster Access

Two paths exist. Tailscale is the primary one. The Cloudflare tunnel stays as a
fallback that does not depend on the Tailscale operator or tailnet policy.

---

# Tailscale (primary)

The operator runs in the `tailscale` namespace. Two things make the cluster and
the LAN reachable:

- `Connector lan` advertises `192.168.8.0/24`, so any tailnet device can reach
  every LAN address, including the cluster's MetalLB VIPs.
- The API server proxy (auth mode) impersonates your Tailscale identity and maps
  it to Kubernetes RBAC.

## Reach services by their normal names

DNS needs no tailnet configuration. Public Cloudflare DNS already returns
`192.168.8.129` for LAN-only hostnames (ExternalDNS), and those hostnames carry
the wildcard `*.alialjaffer.com` certificate. Over the tailnet, the subnet route
makes that address work. Public hostnames keep going through Cloudflare.

```bash
tailscale status | grep homelab-lan-0
tailscale status --json | jq -r '.Peer[] | select(.HostName=="homelab-lan-0") | .PrimaryRoutes'
curl -sI https://argocd.alialjaffer.com | head -1
```

The connector device is `homelab-lan-0`. The CR sets `hostnamePrefix: homelab-lan`
and the operator appends the replica index. The plain `tailscale status` output
does not list routes, so read `PrimaryRoutes` from the JSON.

## Accept the subnet route on each client

`192.168.8.0/24` is an advertised route, so each device must accept it:

```bash
tailscale set --accept-routes
```

On the macOS and Windows apps, the equivalent setting is **Use Tailscale
subnets**. Without it, only `100.x` addresses work off-LAN.

## Overlapping local subnet

Accepting the route is not enough when the client sits on a network that also
uses `192.168.8.0/24`. The local link wins and the tailnet route is never used.
The symptom is a hostname that resolves to `192.168.8.129` and then refuses
connections:

```bash
route -n get 192.168.8.129
# interface: en0   <- local link, the tailnet route is bypassed
```

Check the client address too. A DHCP lease in that range is the cause, and a
lease on `192.168.8.99` also collides with cp0.

The API server proxy needs no LAN routing, so `kubectl` keeps working:

```bash
tailscale configure kubeconfig tailscale-operator
kubectl get nodes
```

`talosctl` and the VIPs do need it, so they stay unreachable until the client
leaves the overlapping network or the two subnets differ.

## kubectl

Auth mode needs HTTPS certificates enabled for the tailnet (admin console,
**DNS** page, **HTTPS Certificates**), which is on. The proxy hostname carries a
Let's Encrypt certificate for `tailscale-operator.<tailnet>.ts.net`.

```bash
tailscale configure kubeconfig tailscale-operator
kubectl auth whoami    # Username aliAljaffer@github, Groups [system:masters ...]
kubectl get nodes
```

The grant in `kubernetes/infrastructure/tailscale-operator/policy.hujson` maps
`autogroup:member` to `system:masters`. That is deliberate for a single-user
tailnet; narrow it before adding users.

## talosctl

Plain subnet routing, no proxy involved. It needs the accepted route and a
talosconfig context that holds the client certificate:

```bash
talosctl config info
talosctl --talosconfig ~/.talos/config --endpoints 192.168.8.99 --nodes 192.168.8.99 get nodes
```

`--endpoints` and `--nodes` are not enough on their own. With an empty
`~/.talos/config` (`context: ""`, `contexts: {}`) talosctl stops at
`talos config file is empty` before it touches the network.

## Verify

```bash
tailscale status
tailscale ping homelab-lan-0
```

`tailscale status` lists every device in the tailnet, not only the cluster ones.
A pong `via DERP(...)` means the route works but the path is relayed, not direct.

---

# SSO with Keycloak (prepared, not enabled)

Tailscale only lets a tailnet switch to a custom OIDC provider when the tailnet
uses a custom domain. This tailnet signs in with GitHub, so the switch needs
Tailscale support and now trades a working login for no access gain. Everything
except the switch itself is in place:

- Keycloak client `tailscale` in the `homelab` realm, redirect
  `https://login.tailscale.com/a/oauth_response`.
- Sealed client secret `tailscale-oidc-secret` in the `keycloak` namespace.
- WebFinger Worker in `cloudflare/webfinger`, not deployed.

To finish it later:

1. Give a Keycloak user an `@alialjaffer.com` address. Tailscale derives the
   WebFinger lookup from the email domain, so a gmail address cannot work.
2. Deploy the Worker and check it:

   ```bash
   cd cloudflare/webfinger && npx wrangler deploy
   curl "https://alialjaffer.com/.well-known/webfinger?resource=acct:ali@alialjaffer.com"
   ```

3. Read the client secret:

   ```bash
   kubectl get secret tailscale-oidc-secret -n keycloak \
     -o go-template='{{.data.CLIENT_SECRET | base64decode}}{{"\n"}}'
   ```

4. In the admin console, **Settings > Authentication**, switch the identity
   provider with issuer `https://kc.alialjaffer.com/realms/homelab`, client ID
   `tailscale`, and that secret. Every user re-authenticates afterwards.

Until then Keycloak remains the SSO layer for the applications reached over the
tailnet (oauth2-proxy and app-native OIDC).

---

# Cloudflare tunnel (fallback)

Access `kubectl` and `talosctl` from outside the home network through the
existing Cloudflare Tunnel, protected by Cloudflare Access Zero Trust.

Instead of SSH-ing into a machine, you run a local TCP proxy via `cloudflared`
and point your tools at `localhost`.

## What you need

- `cloudflared` CLI  -  [install](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
- `kubectl` with a working kubeconfig for the cluster
- `talosctl` with `~/.talos/config` or `~/.kube/talosconfig`
- Access to your Cloudflare Zero Trust account (to authenticate the first time)

## How it works

The `cloudflared` daemon in the `cloudflared` namespace exposes two TCP hostnames:

| Hostname | Routes to | Port |
|---|---|---|
| `k.alialjaffer.com` | Talos API server (cp0) | 6443 |
| `t.alialjaffer.com` | Talos node API (cp0) | 50000 |

Both are protected by a Cloudflare Access policy. You authenticate once via your
browser, then `cloudflared access tcp` creates a local proxy that passes traffic
through the tunnel.

## Step 1  -  Set up Cloudflare Access policies

Do this once in the Cloudflare dashboard.

1. Go to **Zero Trust > Access > Applications**.

2. Create an application for `k.alialjaffer.com`:
   - Type: **Self-hosted**
   - Application domain: `k.alialjaffer.com`
   - Policy: require your email (or any identity provider you use)

3. Create a second application for `t.alialjaffer.com` with the same policy.

## Step 2  -  Open the tunnel on your remote machine

Run these two commands in the background before using `kubectl` or `talosctl`.

```bash
# kubectl tunnel (port 6443)
cloudflared access tcp \
  --hostname k.alialjaffer.com \
  --url localhost:6443 &

# talosctl tunnel (port 50000)
cloudflared access tcp \
  --hostname t.alialjaffer.com \
  --url localhost:50000 &
```

The first time you run either command, a browser window opens for Cloudflare Access authentication. After you authenticate, the token is cached locally and future connections are automatic until the token expires (typically 24 hours).

## Step 3  -  Use kubectl over the tunnel

The API server certificate is issued for the cluster's internal hostname, not `localhost`. Pass `--insecure-skip-tls-verify` or create a dedicated remote kubeconfig context.

```bash
kubectl --server=https://localhost:6443 \
  --insecure-skip-tls-verify \
  --kubeconfig ~/.kube/homelab-talos \
  get nodes
```

Or add a permanent context to your kubeconfig:

```bash
kubectl config set-cluster homelab-talos-remote \
  --server=https://localhost:6443 \
  --insecure-skip-tls-verify=true

kubectl config set-context homelab-talos-remote \
  --cluster=homelab-talos-remote \
  --user=$(kubectl config get-contexts homelab-talos --no-headers | awk '{print $4}')

kubectl config use-context homelab-talos-remote
```

## Step 4  -  Use talosctl over the tunnel

```bash
talosctl --endpoints localhost:50000 \
  --nodes localhost \
  get nodes
```

Or set the endpoint permanently for remote use:

```bash
talosctl config endpoint localhost:50000
talosctl config node localhost
```

> [!NOTE]
> Switch the endpoint back to `192.168.8.99` when you are on the home network.

## Disconnecting

When done, kill the background tunnel processes.

```bash
pkill -f "cloudflared access tcp"
```
