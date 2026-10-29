# arc

Staged self-hosted runner, currently only for `aliAljaffer/chat-gateway`.

- `arc` Application (in `kubernetes/argocd/apps/workloads/arc.yaml`): the
  `gha-runner-scale-set-controller` 0.14.2 chart from `ghcr.io`. The chart's
  CRDs are managed by ArgoCD with server-side apply (client-side apply hits the
  256 KB last-applied annotation limit).
- `arc-runner-chat-gateway` Application: one `gha-runner-scale-set` 0.14.2
  release; its name is also the `runs-on:` label.
- Auth is the `update-manifests-homelab` GitHub App (`github-app.sealed.yaml`,
  `github_app_id` / `github_app_installation_id` / `github_app_private_key`).
  It needs **Administration: Read and write** and must be installed on the repo.
- `arc-runners` is labelled `pod-security.kubernetes.io/enforce: privileged`
  because the dind sidecar is privileged.
- Both the runner and dind images are pushed to Harbor's `mirror` project and
  pre-pulled on the workers, so runner pods start without a GHCR cold pull:
  `harbor.alialjaffer.com/mirror/actions-runner@sha256:0ce3288e...` and
  `.../mirror/dind@sha256:97545b7...`. Harbor did not persist the pushed tags,
  so the scale set uses digest-only refs. Use a current runner image: 2.334.0
  exits with code 7 ("outdated") and sends ARC into its outdated loop.
- The `chat-gateway` workflow installs `gcc`/`libc6-dev` because the official
  image has no C compiler for `go test -race`; `setup-go` also downloads the Go
  toolchain per ephemeral runner (the bulk of the 4-minute test job). A thin
  image with Go/gcc preinstalled would cut that, at the cost of maintaining an
  image.

To add another repo: add an Application like
`arc-runner-chat-gateway.yaml` with a different release name and
`githubConfigUrl`, pre-pull the images, then use that name as `runs-on:` in the
repo's workflow.
