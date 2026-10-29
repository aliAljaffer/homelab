# arc

GitHub Actions self-hosted runners for `chat-gateway`, `grooszy`, and `fai`
(fai's `build-images` CI; fai's `release` workflow stays on GitHub-hosted
runners because it needs macOS/Windows).

- `arc` Application: the `gha-runner-scale-set-controller` 0.14.2 chart from
  `ghcr.io`, the namespaces, the GitHub App credential, the PodMonitors and the
  toolchain warmer.
- `arc-runner-chat-gateway`, `arc-runner-grooszy`, `arc-runner-fai`: one
  `gha-runner-scale-set` each. The release name is also the `runs-on:` label.
- Auth is the `update-manifests-homelab` GitHub App
  (`github-app.sealed.yaml`); it needs **Administration: Read and write** and
  must be installed on the repo.
- `arc-runners` is labelled `pod-security.kubernetes.io/enforce: privileged`
  because the dind sidecar is privileged.

## Toolchain image

`runner-image/` holds the Dockerfile, `versions.env` and the build script.
The image is based on the mirrored `actions-runner` digest and adds Go, Node,
Python, gcc/libc6-dev, `gh`, Playwright Chromium + deps, fakeroot/rpm for fai's
future Linux release packaging, and warm Go/npm caches. It also creates the
writable `/opt/hostedtoolcache` the runner expects.

The runner apps reference the image **by digest** (Harbor tags are not relied
on). `toolchain-warmer.yaml` runs the same image/digest with `sleep` on every
worker so a fresh runner pod never pulls 6.5 GB on demand.

### Updating it

`.github/workflows/build-runner-image.yml` (GitHub-hosted, not ARC) runs on
`runner-image/**` changes, weekly, or manually:

1. Checks out the homelab + the three app repos (GitHub App token).
2. Resolves the desired versions/hashes into `desired.env`: `versions.env`, the
   Dockerfile hash, the base image digest, and the app `go.mod`/`go.sum`/
   `package-lock.json` hashes.
3. Compares `desired.env` with `versions.lock`. If nothing changed, the build is
   skipped — no aimless weekly rebuild.
4. Otherwise builds/pushes, smoke-tests the image, updates `versions.lock` and
   every `runner-toolchain@sha256:*` reference (three runner apps + warmer),
   and commits with `[skip ci]`.

Toolchain/OS bumps come from Renovate (or manual `versions.env` edits); app
lockfile changes trigger the cache rebuild through the hash. A stale cache
never breaks a run, it only makes `npm ci`/`go` download more.

The repo's `go` directive must be <= the image's Go (`check` fails otherwise);
the image's Go is 1.27.3, covering fai/grooszy/chat. A Node `engines` bump or a
Playwright lock change also needs an image rebuild.

Each app workflow has a `Verify runner toolchain` step that fails fast if the
image is missing the expected Go/Node/Playwright/gh/gcc.

### Rollout / rollback

The build workflow's commit changes the digest in the runner apps + warmer;
ArgoCD syncs and the ASR rolls. Roll back by reverting that commit — the old
digest stays in Harbor and on the nodes. Do it while the scale sets are idle;
the image change recreates the EphemeralRunnerSet and the listener.
