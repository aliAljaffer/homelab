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
  so both realms exist as soon as Keycloak comes up. Re-running an import only
  creates what's missing, it does not overwrite later runtime changes.
- `postgres-cluster.yaml`: CNPG auto-generates app credentials into the
  `keycloak-db-app` Secret (keys: username, password, dbname, host, port, uri, ...).
- `networkpolicy.yaml`: default-deny egress for the operator, app, and DB pods.
  The keycloak-operator chart already ships an ingress-only NetworkPolicy for the
  app pods. Kubernetes NetworkPolicies are additive, so this file only adds Egress.
  - No egress rule exists for an SMTP host. SMTP is set at runtime via the Admin
    API and isn't in any manifest here. Confirm the real SMTP host before adding a
    `toFQDNs` rule.

## Re-install notes

- The SMTP settings for the `homelab` realm lived only in the DB row, not in Git,
  so a fresh install does not restore them. Re-set them via the Admin API if
  invite/verification emails are needed.
- The `kc.alialjaffer.com` HTTPRoute uses the LAN `homelab-gateway`, not the
  public Cloudflare tunnel, and is not Cloudflare-proxied.
