#!/usr/bin/env bash
# Emergency local rebuild. The normal path is .github/workflows/build-runner-image.yml.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/versions.env"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for repo in grooszy chat-gateway fai; do
  git clone --depth 1 "git@github.com:aliAljaffer/$repo.git" "$tmp/apps/$repo"
done
mkdir -p "$tmp/context"/{go/grooszy,go/chat,root,web}
cp "$tmp/apps/grooszy/go.mod" "$tmp/apps/grooszy/go.sum" "$tmp/context/go/grooszy/"
cp "$tmp/apps/chat-gateway/go.mod" "$tmp/apps/chat-gateway/go.sum" "$tmp/context/go/chat/"
cp "$tmp/apps/grooszy/package.json" "$tmp/apps/grooszy/package-lock.json" "$tmp/context/root/"
cp "$tmp/apps/grooszy/web/package.json" "$tmp/apps/grooszy/web/package-lock.json" "$tmp/context/web/"
docker build --platform linux/amd64 --provenance=false --sbom=false \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg GO_VERSION="$GO_VERSION" \
  --build-arg NODE_VERSION="$NODE_VERSION" \
  --build-arg GH_VERSION="$GH_VERSION" \
  -t "$IMAGE_REPO:local" "$tmp/context" -f "$here/Dockerfile"
echo "Built $IMAGE_REPO:local"
