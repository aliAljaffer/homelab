# arc

GitHub Actions self-hosted runners, now fully managed by ArgoCD:

- `arc` (Application, destination `arc-systems`): the controller Helm chart,
  `gha-runner-scale-set-controller` 0.14.2 from `ghcr.io`, plus the namespaces,
  the app credential and the PodMonitors from this directory.
- `arc-runners` (Application, destination `arc-runners`): one
  `gha-runner-scale-set` 0.14.2 Helm source per repository. The Helm release
  name is the scale set name and therefore the `runs-on:` label:

  | Release name              | Repository                        |
  | ------------------------- | --------------------------------- |
  | `arc-runner-set`          | `aliAljaffer/aliAljaffer.github.io` |
  | `arc-runner-fai`          | `aliAljaffer/fai`                 |
  | `arc-runner-grooszy`      | `aliAljaffer/grooszy`             |
  | `arc-runner-chat-gateway` | `aliAljaffer/chat-gateway`        |

  Add a repository by adding another Helm source to
  `kubernetes/argocd/apps/workloads/arc-runners.yaml` and using its release name
  as `runs-on:` in that repo's workflows.

## Authentication

`githubConfigSecret: github-app` references `github-app.sealed.yaml`, which
holds the `update-manifests-homelab` GitHub App (app id, installation id,
private key). It is installed on `homelab`, `fai`, `grooszy` and
`chat-gateway`, and needs **Repository permissions → Administration: Read and
write** to create runner scale sets. Rotate by re-sealing:

```bash
kubectl create secret generic github-app -n arc-runners \
  --from-literal=github_app_id=5511128 \
  --from-literal=github_app_installation_id=<installation id> \
  --from-file=github_app_private_key=<path to .pem> \
  --dry-run=client -o yaml | kubeseal \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --scope namespace-wide -o yaml > github-app.sealed.yaml
```

## Runner pods

`runner-values.yaml` is shared by every scale set. Runners use the official
`ghcr.io/actions/actions-runner` image (pinned by digest) with a privileged
`docker:*-dind` sidecar, so `docker build`, `buildx` and GitHub service
containers work. The image is deliberately minimal: workflows install their own
toolchain (`setup-go`, `setup-node`, `python3`/`gh` via apt). The old custom
`arc-runner-aws` image and `runner-aws-image/` are gone.

Scale sets are idle at zero (`minRunners: 0`), cap at two pods, and each pod is
limited to 3Gi per container.

## Metrics

`podmonitor.yaml` scrapes the controller and every scale set listener. The
controller's `metrics:` block is undocumented (`helm show values` omits it, only
`templates/deployment.yaml` has it) and without it the chart hardcodes metrics
off. It lives in `arc-controller-values.yaml`.
