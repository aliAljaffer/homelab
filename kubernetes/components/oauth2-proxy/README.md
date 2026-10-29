# oauth2-proxy

A reusable [oauth2-proxy](https://oauth2-proxy.dev) component that puts your
Keycloak login (`homelab` realm) in front of any app that has no auth gate of
its own.

It is a kustomize **Component**, not an ArgoCD Application. Nothing is deployed
until an app includes it. The app points its HTTPRoute at the proxy instead of
its own Service, and the proxy forwards to the app once the user is logged in.

```
browser -> Gateway (HTTPS) -> oauth2-proxy -> app Service
                    \                 /
                     `-> Keycloak  <-'
```

## Why reverse proxy and not forward-auth

Cilium's Gateway API does not (yet) support the Gateway API
`HTTPRouteExternalAuth` filter ([cilium#45704](https://github.com/cilium/cilium/issues/45704)),
so a single central auth gate would need a hand-rolled `CiliumEnvoyConfig`
patching the gateway's Envoy listener. Instead each protected app runs its own
small oauth2-proxy in front of it. Standard, no Cilium internals, survives
Cilium upgrades.

## Prerequisites

The OIDC client is declared in the `homelab` realm
(`kubernetes/infrastructure/keycloak/keycloak-realm-homelab.yaml`): client id
`oauth2-proxy`, secret from the `keycloak-oauth2-proxy-secret` SealedSecret.
Keycloak matches redirect URIs **exactly** (wildcards in the host are not
supported), so each app registers its own
`https://<app>.alialjaffer.com/oauth2/callback` — currently only `ntfy`. All
instances share the client, so every app gets SSO off the same session cookie.

> **Re-import caveat.** A `KeycloakRealmImport` only creates a realm that does
> not exist yet (`kc.sh import --override=false`); it never updates one. On a
> cluster where the `homelab` realm already exists, adding this client to the
> import in Git does nothing until you either add the client by hand in the
> Keycloak admin console (Clients -> Create client -> OpenID Connect, id
> `oauth2-proxy`, confidential, standard flow, PKCE S256, redirect URI
> `https://<app>.alialjaffer.com/oauth2/callback`, then set the secret to
> `keycloak-oauth2-proxy-secret`'s `CLIENT_SECRET`), or delete the realm *and*
> its `KeycloakRealmImport` CR so ArgoCD recreates both — that wipes any users or
> edits that exist only in Keycloak. Fresh installs get the client automatically.

## Adding it to an app

1. Add `https://<app>.alialjaffer.com/oauth2/callback` to the shared client's
   valid redirect URIs — both in `keycloak-realm-homelab.yaml` (for a future
   from-scratch realm) **and** in the live realm via the admin console or
   `kcadm`, per the re-import caveat above. Skipping this gives
   `Invalid parameter: redirect_uri` at login.

2. Include the component and add the two resources it expects in the app's
   `kustomization.yaml` (plus `namespace:`, so the component's Deployment and
   Service land in the app's namespace):

   ```yaml
   namespace: myapp
   resources:
     - oauth2-proxy-config.yaml
     - oauth2-proxy-secret.sealed.yaml
   components:
     - ../../components/oauth2-proxy
   ```

3. `oauth2-proxy-config.yaml` — non-secret, per-app settings:

   ```yaml
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: oauth2-proxy-config
   data:
     OAUTH2_PROXY_UPSTREAMS: "http://myapp.myapp.svc.cluster.local:80"
     OAUTH2_PROXY_REDIRECT_URL: "https://myapp.alialjaffer.com/oauth2/callback"
     OAUTH2_PROXY_COOKIE_DOMAINS: ".alialjaffer.com"
     OAUTH2_PROXY_WHITELIST_DOMAINS: ".alialjaffer.com"
     OAUTH2_PROXY_EMAIL_DOMAINS: "*"
   ```

4. `oauth2-proxy-secret.sealed.yaml` — seal the shared credentials into the
   **app's** namespace (SealedSecrets are namespaced). The canonical values live
   in `keycloak-oauth2-proxy-secret` in the `keycloak` namespace, so read them
   out and re-seal:

   ```bash
   CLIENT_SECRET=$(kubectl -n keycloak get secret keycloak-oauth2-proxy-secret \
     -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
   COOKIE_SECRET=$(kubectl -n keycloak get secret keycloak-oauth2-proxy-secret \
     -o jsonpath='{.data.COOKIE_SECRET}' | base64 -d)

   kubectl create secret generic oauth2-proxy-secret -n myapp \
     --from-literal=OAUTH2_PROXY_CLIENT_ID=oauth2-proxy \
     --from-literal=OAUTH2_PROXY_CLIENT_SECRET="$CLIENT_SECRET" \
     --from-literal=OAUTH2_PROXY_COOKIE_SECRET="$COOKIE_SECRET" \
     --dry-run=client -o yaml \
     | kubeseal --cert pub-sealed-secrets.pem --scope namespace-wide -o yaml \
     > kubernetes/apps/myapp/oauth2-proxy-secret.sealed.yaml
   ```

   The cookie secret is the same across apps on purpose: it is what makes one
   login work for every `*.alialjaffer.com` app. Rotating it logs everyone out.

5. Point the app's HTTPRoute at the proxy, and update the app's NetworkPolicy:

   ```yaml
   rules:
     - backendRefs:
         - name: oauth2-proxy
           port: 80
   ```

   The app pod must accept its port from `app.kubernetes.io/name: oauth2-proxy`,
   and the proxy needs egress to the upstream, DNS, and
   `kc.alialjaffer.com:443`. The proxy itself needs ingress on 4180 from the
   `cloudflare-tunnel-system` namespace (the tunnel → Cilium Gateway path) plus
   from `host` for the kubelet probes — see `infrastructure/ntfy/networkpolicy.yaml`.

## When not to use this

Only put it in front of things a **browser** reaches. Programmatic clients
(Stremio addons like `nexotv`, API consumers) cannot follow an interactive OIDC
redirect and will break. Apps with their own auth (Grafana, ArgoCD, Vaultwarden,
Umami) already have a gate and generally do not need this.

## Notes

- The proxy trusts `X-Forwarded-*` only from `192.168.8.0/24` (the Cilium Envoy
  DaemonSet is host-networked, so it connects from a node IP). If node addresses
  change, update `--trusted-proxy-ip` in `deployment.yaml`.
- Each app's callback URI is registered explicitly on the shared `oauth2-proxy`
  client: Keycloak does not support wildcards in the host part of a redirect
  URI. Adding an app means updating both `keycloak-realm-homelab.yaml` and the
  live realm (see the re-import caveat).
