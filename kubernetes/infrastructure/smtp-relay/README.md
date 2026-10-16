# smtp-relay

A single, rate-limited SMTP egress point for the whole cluster.

## Why

Every application that sends mail (`falcosidekick`, Alertmanager, Grafana,
ArgoCD Notifications, Keycloak, Vaultwarden) used to talk to
`smtp.resend.com` directly. Each one held its own copy of the Resend API key
and each one could send as fast as it liked, so a single noisy app could burn
through Resend's daily quota and lock out *all* email — which is exactly what
the Falco `Drop and execute new binary in container` flood did.

Funnelling everything through one relay means:

- **One rate limit to rule them all.** A runaway sender is throttled at the
  relay regardless of which app it is.
- **One place holding the Resend key.** Senders no longer need SMTP
  credentials at all.
- **One place to watch.** `kubectl -n mail logs deploy/smtp-relay` shows every
  message the cluster tries to send.

## How

The relay is a [boky/postfix](https://github.com/bokysan/docker-postfix)
"null client": it accepts mail from inside the cluster and relays everything to
Resend over authenticated TLS. It is a `Deployment` + `ClusterIP` `Service`
(`smtp-relay.mail.svc.cluster.local:587`), reachable only from the sender
namespaces (see `networkpolicy.yaml`).

### Rate limits

Enforced by Postfix itself, no extra component:

| Setting | Value | Effect |
|---|---|---|
| `smtpd_client_message_rate_limit` | 20 / 60s | Per sender pod (client IP): max messages. |
| `smtpd_client_recipient_rate_limit` | 40 / 60s | Per sender pod: max recipients. |
| `smtpd_client_connection_rate_limit` | 10 / 60s | Per sender pod: max connections. |
| `default_destination_rate_delay` | 1s | Globally, one message to Resend per second. |
| `initial_destination_concurrency` | 1 | No parallel delivery to Resend. |

`anvil(8)` normally exempts clients in `mynetworks` (the private ranges cluster
pods live in). `smtpd_client_event_limit_exceptions` is set to a non-matching
range so that exemption does **not** apply — otherwise the per-client limits
would be a no-op for exactly the clients we care about.

These cap the *rate* of sending. They do not impose a hard daily ceiling;
Resend still returns `550` once its own daily quota is hit.

### TLS

The in-cluster listener is plaintext (`smtpd_tls_security_level = none`) on
purpose: pod traffic is already restricted by CiliumNetworkPolicy, and the
relay's self-signed certificate would otherwise fail verification in clients
that mandate STARTTLS. The relay itself connects to Resend with
`smtp_tls_security_level = encrypt`.

## Senders

Each sender was repointed from `smtp.resend.com:587` (with its own credentials)
to `smtp-relay.mail.svc.cluster.local:587` (no credentials):

| Sender | Config |
|---|---|
| falcosidekick | `kubernetes/infrastructure/falco/values.yaml` |
| Alertmanager | `kubernetes/infrastructure/monitoring/values.yaml` |
| Grafana | `kubernetes/infrastructure/monitoring/values.yaml` |
| ArgoCD Notifications | `kubernetes/bootstrap/argocd/values.yaml` |
| Keycloak | `kubernetes/infrastructure/keycloak/keycloak-realm-*.yaml` |
| Vaultwarden | `kubernetes/apps/vaultwarden/vaultwarden-deployment.yaml` |

The senders' per-app `*-smtp-secret` SealedSecrets are now unused and can be
pruned once this has been in place for a while.

### Caveats

- **ArgoCD** is bootstrap-installed with Helm (not Argo-managed). Editing
  `kubernetes/bootstrap/argocd/values.yaml` only takes effect after
  `helm upgrade argocd argo/argo-cd --version 10.3.0 -n argocd --values
  kubernetes/bootstrap/argocd/values.yaml`.
- **Keycloak**'s realm SMTP is part of the `KeycloakRealmImport`, and the
  operator skips realms that already exist, so changing the manifest does not
  update a live realm. The file is the source of truth for a *fresh* install;
  an existing realm must be updated through the admin API (or deleted and
  re-imported) to pick up the relay.

## Credentials

`RELAYHOST_PASSWORD` is the Resend API key, stored as
`smtp-relay-resend.sealed.yaml` (SealedSecret). It is currently the same key
the applications used individually; rotating it means re-sealing this file.
