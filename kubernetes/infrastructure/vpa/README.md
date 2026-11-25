# vpa

Upstream chart `vertical-pod-autoscaler/charts/vertical-pod-autoscaler` from
kubernetes/autoscaler, installed recommender-only (`values.yaml` turns off the
updater and the admission controller). `fullnameOverride: vpa` names the
deployment `vpa-recommender`.

Nothing here evicts, patches or restarts a workload. VPA objects are read as
advice: `kubectl -n <ns> describe vpa <name>` prints the recommendation, and
`kubectl -n <ns> get vpa <name> -o jsonpath="{.status.recommendation}"` prints
it raw. Changing `updatePolicy.updateMode` to `Auto` would evict and recreate
pods, and `InPlaceOrRecreate` resizes them without restarting (the cluster runs
Kubernetes 1.36, in-place resize is GA and containers default to
`resizePolicy: NotRequired`).

The recommender needs a few days of samples before its recommendations mean
anything.

## Requirements

Kubernetes 1.32+ for the CRDs the chart ships (it uses `status.subresource` and
per-container recommendation policies). The cluster runs 1.36.
