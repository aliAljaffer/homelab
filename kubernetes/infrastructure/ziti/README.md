# ziti (controller + router)

The OpenZiti data plane for the homelab: an in-cluster Ziti controller and one
edge router. Deployed by the `ziti` ArgoCD Application, which combines two
upstream charts from `https://openziti.io/helm-charts/`:

| Chart | Version | Image |
| --- | --- | --- |
| `ziti-controller` | 3.3.2 | `openziti/ziti-controller:2.0.4` |
| `ziti-router` | 3.0.3 | `openziti/ziti-router:2.0.4` |

Ziti 2.0.4 is the version the `ziti-operator` (v0.1.2) is tested against; the
chart `appVersion`s are 2.0.3, so `image.tag` pins both to 2.0.4.

## Ordering

1. `trust-manager` (wave -3) must be running first. The controller chart v3
   requires it: the chart renders a `trust.cert-manager.io/v1alpha1` `Bundle`
   that composes the controller's ctrl-plane CA bundle from the edge-root
   Secret.
2. `ziti` (wave 2) installs the controller, then the router.
3. The router needs an enrollment JWT (see below).

## Namespace and endpoints

- Namespace: `ziti`.
- Controller client API: `ziti-controller-client.ziti.svc:443`.
- Controller management API: `ziti-controller-mgmt.ziti.svc:443` (split out via
  `managementApi.service.enabled=true`).
- Router edge listener: in-cluster Service DNS, e.g.
  `ziti-router-edge.ziti.svc:443`.

These are `ClusterIP`; nothing is exposed outside the cluster.

## Router enrollment (the one non-GitOps step)

The `ziti-router` chart enrolls from a one-time JWT on first start, then stores
its identity on a Longhorn PVC. The JWT is Ziti API state, so it cannot be
committed to git. It is delivered by `scripts/enroll-router.sh`, which:

1. waits for the controller to be ready,
2. runs `ziti edge create edge-router router1 --tunneler-enabled --jwt-output-file`,
3. writes the JWT to the Secret `ziti-router-enrollment` (key `enrollmentJwt`).

That Secret is **not** tracked by Argo, so Argo never prunes it and the router can
re-enroll if its volume is lost. Re-run the script after a fresh install, or
after wiping the router's PVC.

```sh
kubernetes/infrastructure/ziti/scripts/enroll-router.sh
```

## Alternative: let the operator create the router

The companion `ziti-operator` can own router creation via a `ZitiRouter`
resource and hand out the JWT itself — no imperative step. Two blockers today:

1. The operator writes the JWT under the key `enrollment.jwt`
   (`internal/controller/ziti_router_controller.go`), while the `ziti-router`
   chart reads the key `enrollmentJwt`. One key name must change for a drop-in
   fit.
2. There is a bootstrap ordering loop: the operator's `ZitiConnection`
   `hostingRouters` wants the router's Ziti name, but the router is created by
   the operator afterwards. It works if the `ZitiRouter` is created with the
   name listed in `hostingRouters`; just sequence the resources.

Once (1) is resolved, a `ZitiRouter` + a helper ConfigMap/Secret can replace
`scripts/enroll-router.sh` entirely.

## Metrics and dashboard

Both the controller and the router are scraped, and a Grafana dashboard named
"OpenZiti" renders them.

- Controller: `prometheus.service.enabled=true` creates the Service and a
  ServiceMonitor. The chart's ServiceMonitor is not labeled as
  kube-prometheus-stack requires, so `controller-servicemonitor.yaml` adds one
  that is.
- Router: the chart can collect fabric metrics (`fabric.metrics.enabled`) but
  has no way to expose them, so this directory overrides the generated
  `ziti-router-config` ConfigMap to add a metrics web listener, plus
  `router-metrics.yaml` for the Service and ServiceMonitor. `scripts/check-router-config.sh`
  guards that override against chart drift.
- `fabric.events.enabled=true` turns on the full fabric event set.

