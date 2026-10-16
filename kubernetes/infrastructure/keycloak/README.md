# keycloak

- `keycloak.yaml`: if `bootstrapAdmin` is left unset, the operator auto-generates
  admin bootstrap credentials into the `keycloak-initial-admin` Secret. Retrieve them with:

  ```bash
  kubectl get secret keycloak-initial-admin -n keycloak \
    -o go-template='{{.data.username | base64decode}}{{"\n"}}{{.data.password | base64decode}}{{"\n"}}'
  ```

- `keycloak-realm-homelab.yaml` / `keycloak-realm-external-users.yaml`:
  `KeycloakRealmImport` CRs created at install time, one per realm. The operator
  runs a separate import Job per CR that waits for the Keycloak CR to be ready,
  so both realms exist as soon as Keycloak comes up. An import only *creates* a
  realm, it never updates one that already exists, so runtime edits are not
  reverted and spec changes require deleting/re-creating the realm to take effect.
- `keycloak-smtp-secret.sealed.yaml`: the Resend SMTP password (same credentials
  as Vaultwarden), consumed by both realm imports through `spec.placeholders`.
  Only the password is secret, the username is literally `resend`.
- `postgres-cluster.yaml`: CNPG auto-generates app credentials into the
  `keycloak-db-app` Secret (keys: username, password, dbname, host, port, uri, ...).
- `networkpolicy.yaml`: default-deny egress for the operator, app, and DB pods.
  The keycloak-operator chart already ships an ingress-only NetworkPolicy for the
  app pods. Kubernetes NetworkPolicies are additive, so this file only adds Egress.

## Re-install notes

- Both realms get SMTP (`smtp.resend.com:587`, STARTTLS, from
  `homelab@alialjaffer.com`) via the realm import, so notification emails work on
  a fresh install. Because realm import skips existing realms, changing the SMTP
  block later needs the realm deleted first.
- `networkpolicy.yaml` is enforced (`policy-audit-mode` is off), so the DB pods
  need their `toEntities: kube-apiserver` egress rule or CNPG's initdb/failover
  times out and the whole install stalls.
- The `kc.alialjaffer.com` HTTPRoute uses the LAN `homelab-gateway`, not the
  public Cloudflare tunnel, and is not Cloudflare-proxied.
