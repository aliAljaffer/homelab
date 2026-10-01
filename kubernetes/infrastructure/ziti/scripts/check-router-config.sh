#!/usr/bin/env bash
# Guards the local ziti-router config override against chart drift.
#
# router-config.yaml replaces the config the openziti/ziti-router chart
# generates, to add a metrics web listener the chart does not support. If the
# chart changes its config template, the override can silently drop a setting.
# This renders the chart and fails if the override is no longer the chart's
# config plus the metrics listener.
#
# Run before bumping the ziti-router chart in kubernetes/argocd/apps/workloads/ziti.yaml.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ZITI_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

CHART_VERSION="${1:-3.0.3}"
OVERRIDE="$ZITI_DIR/router-config.yaml"
VALUES="$ZITI_DIR/router-values.yaml"

helm repo add openziti https://openziti.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update openziti >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

helm template ziti-router openziti/ziti-router --version "$CHART_VERSION" -n ziti \
  -f "$VALUES" --set enrollmentJwt=x >"$tmp/router.yaml"

python3 - "$tmp/router.yaml" "$OVERRIDE" "$CHART_VERSION" <<'PY'
import sys, yaml

rendered = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
chart_cfg = yaml.safe_load(
    [d for d in rendered if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "ziti-router-config"][0]
    ["data"]["ziti-router.yaml"]
)
override_cfg = yaml.safe_load(
    [d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d.get("kind") == "ConfigMap"][0]
    ["data"]["ziti-router.yaml"]
)

if "web" not in override_cfg:
    sys.exit("the override no longer adds a web listener")
compare = {k: v for k, v in override_cfg.items() if k != "web"}

def normalize(v):
    if v is None:
        return []
    if isinstance(v, dict):
        return {k: normalize(x) for k, x in v.items()}
    if isinstance(v, list):
        return [normalize(x) for x in v if x is not None]
    return v

if normalize(compare) != normalize(chart_cfg):
    print(f"the override and the ziti-router {sys.argv[3]} config have diverged:", file=sys.stderr)
    for k in sorted(set(compare) | set(chart_cfg)):
        if normalize(compare.get(k)) != normalize(chart_cfg.get(k)):
            print(f"  {k}:", file=sys.stderr)
            print(f"    override: {compare.get(k)}", file=sys.stderr)
            print(f"    chart:    {chart_cfg.get(k)}", file=sys.stderr)
    sys.exit(1)

print(f"OK: the override matches the ziti-router {sys.argv[3]} config plus the metrics listener")
PY
