# Remote Cluster Access

Access `kubectl` and `talosctl` from outside the home network using the existing Cloudflare Tunnel, protected by Cloudflare Access Zero Trust.

This replaces the old `ssh.alialjaffer.com` MacBook bastion. Instead of SSH-ing into a machine and running commands from there, you run a local TCP proxy via `cloudflared` and point your tools at `localhost`.

---

## What you need

On your remote machine:

- `cloudflared` CLI  -  [install](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
- `kubectl` with a working kubeconfig for the cluster
- `talosctl` with `~/.talos/config` or `~/.kube/talosconfig`
- Access to your Cloudflare Zero Trust account (to authenticate the first time)

---

## How it works

The `cloudflared` daemon running in the cluster (`cloudflared` namespace) exposes two TCP hostnames:

| Hostname | Routes to | Port |
|---|---|---|
| `kubectl.alialjaffer.com` | Talos API server (cp0) | 6443 |
| `talos.alialjaffer.com` | Talos node API (cp0) | 50000 |

Both are protected by a Cloudflare Access policy. You authenticate once via your browser, then `cloudflared access tcp` creates a local proxy that passes traffic through the tunnel.

---

## Step 1  -  Set up Cloudflare Access policies

Do this once in the Cloudflare dashboard.

1. Go to **Zero Trust > Access > Applications**.

2. Create an application for `kubectl.alialjaffer.com`:
   - Type: **Self-hosted**
   - Application domain: `kubectl.alialjaffer.com`
   - Policy: require your email (or any identity provider you use)

3. Create a second application for `talos.alialjaffer.com` with the same policy.

---

## Step 2  -  Open the tunnel on your remote machine

Run these two commands in the background before using `kubectl` or `talosctl`.

```bash
# kubectl tunnel (port 6443)
cloudflared access tcp \
  --hostname kubectl.alialjaffer.com \
  --url localhost:6443 &

# talosctl tunnel (port 50000)
cloudflared access tcp \
  --hostname talos.alialjaffer.com \
  --url localhost:50000 &
```

The first time you run either command, a browser window opens for Cloudflare Access authentication. After you authenticate, the token is cached locally and future connections are automatic until the token expires (typically 24 hours).

---

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

---

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

> **Note:** Switch the endpoint back to `192.168.8.99` when you are on the home network.

---

## Disconnecting

When done, kill the background tunnel processes.

```bash
pkill -f "cloudflared access tcp"
```
