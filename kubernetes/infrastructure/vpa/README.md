# vpa

Vertical Pod Autoscaler, recommender only. Chart `vpa` from
charts.fairwinds.com (5.2.0, VPA 1.7.1); `values.yaml` turns off the updater and
the admission controller, so nothing here evicts, patches or restarts a
workload. `fullnameOverride: vpa` names the deployment `vpa-recommender`.

VPA objects are read as advice:

    kubectl -n hermes describe vpa hermes
    kubectl -n hermes get vpa hermes -o jsonpath={.status.recommendation}

The recommender wants a few days of samples before the numbers mean anything.

Raising `updatePolicy.updateMode` would change that: `Auto` evicts and recreates
pods, `InPlaceOrRecreate` resizes them where the kubelet allows it. The cluster
runs Kubernetes 1.36, where in-place resize is GA and containers default to
`resizePolicy: NotRequired` for CPU and memory, so `InPlaceOrRecreate` would not
restart `hermes-0` containers.

The upstream in-tree chart (`kubernetes/autoscaler`, path
`vertical-pod-autoscaler/charts/vertical-pod-autoscaler`) was the first choice,
but ArgoCD clones the whole autoscaler repo and times out generating the
manifest, hence the Fairwinds chart.
