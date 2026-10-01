# trust-manager

Installs [trust-manager](https://cert-manager.io/docs/projects/trust-manager/)
(chart 0.20.3) into the `cert-manager` namespace.

It is required by the `ziti-controller` chart v3, which uses a
`trust.cert-manager.io/v1alpha1` `Bundle` to compose the controller's ctrl-plane
CA bundle from the edge-root Secret.

- `app.trust.namespace: ziti` — trust-manager may source Bundle inputs from the
  `ziti` namespace (plus the release namespace and `kube-system` by default),
  rather than every namespace.
- `crds.enabled: false` — the `Bundle` CRD is owned/installed by cert-manager;
  trust-manager must not manage it (it is a separate CRD in newer releases).
