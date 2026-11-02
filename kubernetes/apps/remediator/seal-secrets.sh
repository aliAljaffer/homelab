#!/usr/bin/env bash
# Usage: DISCORD_WEBHOOK_URL=... [RECEIVER_TOKEN=...] [OPENCODE_API_KEY=...] seal-secrets.sh
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
token="${RECEIVER_TOKEN:-$(openssl rand -hex 32)}"
key="${OPENCODE_API_KEY:-$(jq -r '.["opencode-go"].key // empty' "${HOME}/.local/share/opencode/auth.json")}"
seal() { kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml; }
kubectl create secret generic remediator-receiver -n remediator \
  --from-literal=token="$token" \
  --from-literal=discord-webhook-url="${DISCORD_WEBHOOK_URL:?set DISCORD_WEBHOOK_URL}" \
  --dry-run=client -o yaml | seal > "$dir/remediator-receiver.sealed.yaml"
kubectl create secret generic remediator-provider -n remediator \
  --from-literal=api-key="${key:?set OPENCODE_API_KEY}" \
  --dry-run=client -o yaml | seal > "$dir/remediator-provider.sealed.yaml"
kubectl create secret generic grafana-remediator-token -n monitoring \
  --from-literal=REMEDIATOR_TOKEN="$token" \
  --dry-run=client -o yaml | seal > "$dir/../../infrastructure/monitoring/grafana-remediator-token.sealed.yaml"
echo "Add grafana-remediator-token.sealed.yaml to the monitoring kustomization.yaml"
echo "Receiver token for Grafana: $token"
