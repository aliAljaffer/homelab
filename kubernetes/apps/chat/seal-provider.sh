#!/usr/bin/env bash
set -euo pipefail
provider="${CHAT_PROVIDER_ID:-opencode-go}"
key="${OPENCODE_API_KEY:-$(jq -r --arg p "$provider" '.[$p].key // empty' "${HOME}/.local/share/opencode/auth.json")}"
if [ -z "$key" ]; then
  echo "no API key for ${provider}; set OPENCODE_API_KEY" >&2
  exit 1
fi
out="$(cd "$(dirname "$0")" && pwd)/chat-provider.sealed.yaml"
kubectl create secret generic chat-provider -n chat \
  --from-literal=api-key="$key" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml \
  > "$out"
echo "wrote ${out}"
echo "add it to kustomization.yaml and commit"
