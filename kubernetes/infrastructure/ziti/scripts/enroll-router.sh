#!/usr/bin/env bash
# Enroll the in-cluster Ziti edge router for the ArgoCD-managed ziti chart.
#
# Why this exists: the ziti-router chart enrolls from a one-time JWT on first
# start, then persists its identity on a PVC. GitOps cannot mint that JWT (it is
# Ziti API state), so this script creates the bootstrap Secret out-of-band. It
# is intentionally NOT tracked by ArgoCD, so pruning never deletes it and the
# router can re-enroll on a fresh volume.
#
# Run once after the `ziti` Argo application has synced and the controller is
# healthy. Re-run any time the router's PVC is lost and it needs to re-enroll.
#
#   ./scripts/enroll-router.sh
#
# See the README in this directory for the operator-native alternative.

set -euo pipefail

NS="${ZITI_NS:-ziti}"
ROUTER_NAME="${ROUTER_NAME:-router1}"
CONTROLLER_DEPLOY="${CONTROLLER_DEPLOY:-ziti-controller}"
SECRET_NAME="${ROUTER_SECRET_NAME:-ziti-router-enrollment}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH" >&2
  exit 1
fi

if ! kubectl -n "$NS" get deployment "$CONTROLLER_DEPLOY" >/dev/null 2>&1; then
  echo "controller deployment $CONTROLLER_DEPLOY not found in namespace $NS; sync the ziti app first" >&2
  exit 1
fi

echo "Waiting for the controller to become ready..."
kubectl -n "$NS" rollout status "deployment/$CONTROLLER_DEPLOY" --timeout=300s

if kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "Secret $NS/$SECRET_NAME already exists; leaving it as is."
  echo "Delete it first if you need to re-issue an enrollment JWT."
  exit 0
fi

echo "Creating edge router $ROUTER_NAME and issuing a one-time JWT..."
# zitiLogin is a controller-image helper that logs in with the admin secret and
# the ctrl-plane CA. It writes the JWT to the requested file inside the pod.
kubectl -n "$NS" exec "deployment/$CONTROLLER_DEPLOY" -c ziti-controller -- \
  bash -c "zitiLogin && ziti edge create edge-router '${ROUTER_NAME}' --tunneler-enabled --jwt-output-file /tmp/${ROUTER_NAME}.jwt"

echo "Copying the JWT into Secret $NS/$SECRET_NAME (key enrollmentJwt)..."
kubectl -n "$NS" exec "deployment/$CONTROLLER_DEPLOY" -c ziti-controller -- \
  cat "/tmp/${ROUTER_NAME}.jwt" \
  | kubectl -n "$NS" create secret generic "$SECRET_NAME" --from-file=enrollmentJwt=/dev/stdin

echo "Done. Argo will (re)create the router pod, which will enroll with this JWT."
echo "Watch:  kubectl -n $NS get pods -l app.kubernetes.io/component=ziti-router -w"
