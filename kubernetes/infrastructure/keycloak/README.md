# keycloak

- `keycloak.yaml`: if `bootstrapAdmin` is left unset, the operator auto-generates admin bootstrap credentials into the `keycloak-initial-admin` Secret.
- `keycloak-smtp-secret.sealed.yaml`: record-keeping only. Keycloak reads SMTP settings from the `homelab` realm's DB row (set via the Admin API), not from this secret. No pod mounts it, it just keeps the credential recoverable/rotatable from git.
- `postgres-cluster.yaml`: CNPG auto-generates app credentials into the `keycloak-db-app` Secret (keys: username, password, dbname, host, port, uri, ...).
- `networkpolicy.yaml`: not yet wired into `kustomization.yaml`. Apply only after `policyAuditMode: true` (`kubernetes/bootstrap/cilium/values.yaml`) has rolled out and been confirmed live, so a mistake here logs instead of dropping real traffic.
  - The keycloak-operator chart already ships an ingress-only NetworkPolicy for the app pods. Kubernetes NetworkPolicies are additive, so this file only adds Egress.
  - No egress rule exists yet for the SMTP host (SES) used by the `homelab` realm, it's set at runtime via the Admin API and isn't in any manifest here. Confirm the real SMTP host before adding a `toFQDNs` rule, until then it'll show as a drop in audit-mode logs when an invite email sends.
