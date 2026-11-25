#!/usr/bin/env bash
# Usage: mirror-image.sh [-p os/arch] [-j parts] [-d dir] [-n] <source-ref> <dest-ref>
#   -p  platform to copy (default linux/amd64)
#   -j  maximum open connections: range parts per large layer, batch size for small layers (default 8)
#   -d  work directory; kept, and reused to resume (default: temp dir, removed after push)
#   -n  download and verify only, do not push
# Needs crane, curl, jq. The source must allow anonymous pulls.
set -euo pipefail

platform=linux/amd64 parts=8 dir="" push=1 keep=0
while getopts p:j:d:n o; do
  case $o in p) platform=$OPTARG ;; j) parts=$OPTARG ;; d) dir=$OPTARG; keep=1 ;; n) push=0 ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
src=$1 dst=$2
for c in crane curl jq; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done

large=$((32 * 1024 * 1024))

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
size_of() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; }
log() { echo "$(date +%T) $*"; }

first=""
[ "${src#*/}" != "$src" ] && first=${src%%/*}
case $first in
  *.* | *:* | localhost) reg=$first api=$first rest=${src#*/} ;;
  *) reg=docker.io api=registry-1.docker.io rest=$src ;;
esac
[ "$reg" = docker.io ] && [ "${rest#*/}" = "$rest" ] && rest=library/$rest
repo=${rest%@*}
repo=${repo%:*}
blob_url() { echo "https://$api/v2/$repo/blobs/$1"; }

# ghcr omits the challenge header on HEAD, so probe with GET.
challenge=$(curl -s -o /dev/null -D - "https://$api/v2/" | tr -d '\r' | grep -i '^www-authenticate:' || true)
realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
auth_header() {
  local t=""
  [ -n "$realm" ] && t=$(curl -s "$realm?service=$service&scope=repository:$repo:pull" | jq -r '.token // .access_token // empty')
  if [ -n "$t" ]; then echo "Authorization: Bearer $t"; else echo "Accept: */*"; fi
}

# Appends bytes [start, end] of a blob to $out, resuming from what $out already holds.
fetch_range() {
  local digest=$1 start=$2 end=$3 out=$4 want=$(($3 - $2 + 1)) have code
  for attempt in $(seq 1 40); do
    have=$(size_of "$out")
    [ "$have" -ge "$want" ] && return 0
    code=$(curl -sS -L -H "$(auth_header)" -r "$((start + have))-$end" -o "$out.tmp" -w '%{http_code}' "$(blob_url "$digest")" 2>/dev/null) || true
    if [ "$code" = 206 ]; then
      cat "$out.tmp" >>"$out"
    elif [ "$code" = 200 ] && [ "$have" -eq 0 ] && [ "$start" -eq 0 ]; then
      head -c "$want" "$out.tmp" >"$out"
    else
      sleep 2
    fi
    rm -f "$out.tmp"
  done
  return 1
}

fetch_blob() {
  local digest=$1 size=$2 f="$dir/blobs/sha256/${1#sha256:}" n chunk s e i pids=()
  if [ -f "$f" ] && [ "sha256:$(sha256 "$f")" = "$digest" ]; then return 0; fi
  rm -f "$f"
  n=1
  [ "$size" -ge "$large" ] && n=$parts
  chunk=$(((size + n - 1) / n))
  for ((i = 0; i < n; i++)); do
    s=$((i * chunk)) e=$((s + chunk - 1))
    [ "$s" -ge "$size" ] && break
    [ "$e" -ge "$size" ] && e=$((size - 1))
    fetch_range "$digest" "$s" "$e" "$f.part$i" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || { echo "range download failed for $digest" >&2; return 1; }; done
  for ((i = 0; i < ${#pids[@]}; i++)); do cat "$f.part$i" >>"$f" && rm "$f.part$i"; done
  [ "sha256:$(sha256 "$f")" = "$digest" ] || { echo "checksum mismatch for $digest" >&2; rm -f "$f"; return 1; }
  log "ok $digest ($size bytes, $n parts)"
}

if [ -z "$dir" ]; then dir=$(mktemp -d "${TMPDIR:-/tmp}/mirror-image.XXXXXX"); fi
mkdir -p "$dir/blobs/sha256"

mdig=$(crane digest --platform "$platform" "$src")
mfile="$dir/blobs/sha256/${mdig#sha256:}"
crane manifest --platform "$platform" "$src" >"$mfile"
[ "sha256:$(sha256 "$mfile")" = "$mdig" ] || { echo "manifest digest mismatch" >&2; exit 1; }
total=$(jq '[.config.size, .layers[].size] | add' "$mfile")
log "$src ($platform): $(jq '.layers | length' "$mfile") layers, $((total / 1048576)) MB"

# Small blobs run in batches of $parts; each large blob runs alone with $parts ranges.
# Either way at most $parts connections are open, which stays under per-registry rate limits.
small=() large_blobs=()
while read -r digest size; do
  if [ "$size" -ge "$large" ]; then large_blobs+=("$digest $size"); else small+=("$digest $size"); fi
done < <(jq -r '[.config, .layers[]] | unique_by(.digest)[] | "\(.digest) \(.size)"' "$mfile")
for ((b = 0; b < ${#small[@]}; b += parts)); do
  pids=()
  for entry in "${small[@]:b:parts}"; do
    fetch_blob ${entry} &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || exit 1; done
done
for entry in "${large_blobs[@]+"${large_blobs[@]}"}"; do
  fetch_blob ${entry}
done

IFS=/ read -r os arch variant <<<"$platform"
echo '{"imageLayoutVersion":"1.0.0"}' >"$dir/oci-layout"
jq -n --arg mt "$(jq -r '.mediaType // "application/vnd.oci.image.manifest.v1+json"' "$mfile")" \
  --arg d "$mdig" --argjson s "$(size_of "$mfile")" --arg os "$os" --arg arch "$arch" --arg v "${variant:-}" \
  '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
    manifests: [{mediaType: $mt, digest: $d, size: $s,
                 platform: ({os: $os, architecture: $arch} + (if $v == "" then {} else {variant: $v} end))}]}' \
  >"$dir/index.json"

if [ "$push" -eq 1 ]; then
  crane push "$dir" "$dst"
  pushed=$(crane digest "$dst")
  [ "$pushed" = "$mdig" ] || { echo "pushed digest $pushed does not match source $mdig" >&2; exit 1; }
  log "pushed $dst@$pushed"
  [ "$keep" -eq 1 ] || rm -rf "$dir"
else
  log "verified layout at $dir (not pushed)"
fi
