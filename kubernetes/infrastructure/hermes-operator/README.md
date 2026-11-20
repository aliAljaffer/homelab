# hermes-operator

The [hermes-operator](https://github.com/stubbi/hermes-operator) controller, deployed from the
v0.2.0 release manifest.

`install.yaml` is the release asset `install.yaml` from
`https://github.com/stubbi/hermes-operator/releases/download/v0.2.0/install.yaml`, with the
controller image pinned from `:latest` to `v0.2.0`.

The Helm chart is not used on purpose. The last chart published to
`oci://ghcr.io/stubbi/charts/hermes-operator` is 0.1.6, and its CRD has no `spec.tailscale`, so a
Tailscale Serve instance cannot be applied. The release manifest carries the 0.2.0 CRDs. Re-vendor
this file when a newer release ships, or switch back to the chart once it catches up.

The manifest ships no admission webhooks, so there is no cert-manager or defaulting-webhook
dependency. Defaults the webhooks would have filled in (`spec.resources`, security contexts,
`spec.image.repository`) are written out explicitly in `kubernetes/apps/hermes`.
