#!/usr/bin/env bash
#
# Prune old timestamped `rpn-*` tags from Docker Hub, keeping the newest
# KEEP_RPN_TAGS of them. Only `rpn-*` tags are touched - `latest`, `main`,
# `sha-*` and the toolchain tag are never deleted.
#
# Failures here are non-fatal by design: the workflow step is marked
# `continue-on-error`, so a missing delete scope can never break a release.

set -euo pipefail

REPO="${IMAGE:?IMAGE env var is required}"
KEEP="${KEEP_RPN_TAGS:-10}"
HUB_API="https://hub.docker.com/v2"
LAST_STATUS=""

log() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

# fetch <method> <url> <out_file> [bearer_token]
# Echoes the HTTP status code. Returns non-zero on transport failure.
fetch() {
  local method="$1" url="$2" out="$3" token="${4:-}"
  local -a args=(-sS -X "$method" -o "$out" -w '%{http_code}')
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  curl "${args[@]}" "$url"
}

# "Create access token": exchanges username + PAT for a bearer token.
hub_token() {
  [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]] || return 0
  curl -sS -X POST "${HUB_API}/users/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "$DOCKERHUB_USERNAME" --arg p "$DOCKERHUB_TOKEN" '{username:$u,password:$p}')" \
    | jq -r '.token // empty' 2>/dev/null || true
}

body_file=$(mktemp)
tags_file=$(mktemp)
trap 'rm -f "$body_file" "$tags_file"' EXIT

token="$(hub_token)"
if [[ -z "$token" ]]; then
  warn "Could not obtain a Docker Hub bearer token - pruning will be skipped."
  exit 0
fi

# List every rpn-* tag with its last update time.
#
# The listing endpoint is tried unauthenticated first: for a public repository
# it works without credentials, and it avoids the permission-scoped view that
# an authenticated request can return (an empty result set rather than an
# error, which would otherwise look like "nothing to prune").
list_all() {
  local url="${HUB_API}/repositories/${REPO}/tags?page_size=100&name=rpn-"
  local status next
  local page_num=0
  : > "$tags_file"
  while [[ -n "$url" ]] && (( page_num < 50 )); do
    page_num=$(( page_num + 1 ))
    status=$(fetch GET "$url" "$body_file" "${1:-}") || status="000"
    LAST_STATUS="$status"
    [[ "$status" == "200" ]] || return 1
    jq -c '.results[]? | {name, last_updated}' "$body_file" >> "$tags_file"
    next=$(jq -r '.next // empty' "$body_file" 2>/dev/null || true)
    url="${next}"
  done
  return 0
}

if ! list_all ""; then
  warn "Unauthenticated tag listing failed (HTTP ${LAST_STATUS}) - retrying with a bearer token."
  if ! list_all "$token"; then
    warn "Could not list tags on ${REPO} (HTTP ${LAST_STATUS}) - skipping prune."
    exit 0
  fi
fi

total=$(grep -c . "$tags_file" || true)
log "Found ${total} rpn-* tag(s) on ${REPO}."

if [[ "$total" -le "$KEEP" ]]; then
  log "Nothing to prune (keeping ${KEEP})."
  exit 0
fi

# Newest first, then drop everything past the retention window.
mapfile -t stale < <(
  jq -r '[.last_updated, .name] | @tsv' "$tags_file" \
    | sort -r \
    | awk -v keep="$KEEP" 'NR > keep { print $2 }'
)

if [[ "${#stale[@]}" -eq 0 ]]; then
  log "Nothing to prune."
  exit 0
fi

failed=0
for tag in "${stale[@]}"; do
  log "Deleting ${REPO}:${tag}"
  status=$(fetch DELETE "${HUB_API}/repositories/${REPO}/tags/${tag}/" "$body_file" "$token") || status="000"
  if [[ "$status" != "200" && "$status" != "204" && "$status" != "202" ]]; then
    warn "Could not delete ${tag} (HTTP ${status}). The token may lack delete scope."
    failed=$(( failed + 1 ))
  fi
done

log "Pruned $(( ${#stale[@]} - failed )) tag(s), ${failed} failed."
