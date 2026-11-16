# tailnet-access

Exposes the LAN-only web UIs to the tailnet by name, so a client never needs the
`192.168.8.0/24` subnet route.

One `ProxyGroup` runs two ingress proxies. Each `Ingress` asks for a single-label
tailnet name in `tls.hosts`, and the operator provisions a Let's Encrypt
certificate plus a Tailscale Service that resolves inside the tailnet only:

| Ingress | Tailnet name | Backend |
|---|---|---|
| argocd-tailnet | `argocd.<tailnet>.ts.net` | `argocd/argocd-server:80` |
| pihole-tailnet | `pihole.<tailnet>.ts.net` | `pihole/pihole-web:80` |
| stremio-tailnet | `stremio.<tailnet>.ts.net` | `stremio/stremio:8099` |
| nexotv-tailnet | `nexotv.<tailnet>.ts.net` | `stremio/nexotv:7000` |
| minio-tailnet | `minio.<tailnet>.ts.net` | `catus-locatus/minio-svc:9001` |

The Cilium Gateway keeps serving the same Services on `*.alialjaffer.com` for
LAN and public clients. Both paths share the backend, so nothing is duplicated.

## Check

```bash
kubectl get proxygroup tailnet-ingress
kubectl get ingress -A -l tailscale.com/proxy-group=tailnet-ingress
kubectl get ingress -n pihole pihole-tailnet          # ADDRESS holds the ts.net name
```

`ADDRESS` stays empty until the proxy pods are up and the certificate is issued.
Tailscale serialises certificate requests, so expect a minute or two per name.

## Add another app

Add an `Ingress` with `ingressClassName: tailscale`, the
`tailscale.com/proxy-group: tailnet-ingress` annotation, and a unique single-label
`tls.hosts` entry, then list it in `kustomization.yaml`.

## Gotchas

- The OAuth client behind `operator-oauth` needs the `Services` write scope for
  `ProxyGroup` mode. Without it the group reports a provisioning error in the
  operator log and the Ingress `ADDRESS` stays empty. Remove the
  `tailscale.com/proxy-group` annotation as a fallback: the operator then creates
  a standalone proxy pod per Ingress, which needs no Services scope.
- `tls.hosts` takes a DNS label, not a FQDN. The tailnet suffix comes from the
  tailnet itself.
- A second hostname only works for apps that build URLs from the request. The five
  here qualify: Argo CD, Pi-hole, Stremio, NexoTV, and the MinIO console use
  relative paths and same-origin calls. Argo CD is the near miss: `argocd-cm` sets
  `url = https://argocd.alialjaffer.com`, which matters only for generated absolute
  links and for SSO redirects. Admin password login works over the ts.net name.
  Adding dex or OIDC later breaks that login, because the callback is registered
  against the canonical name.
- Never add an app that sits behind oauth2-proxy (`OAUTH2_PROXY_REDIRECT_URL`) or
  that pins origins, such as `excalidraw`, `grooszy`, `chat`, or the
  `catus-locatus` backend's `ALLOWED_ORIGINS`. Their callback and CORS allowlist
  name the original host, so the ts.net name fails the redirect.
- This is tailnet-only exposure. Nothing here answers from the public internet.
