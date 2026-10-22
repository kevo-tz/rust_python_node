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
API="https://hub.docker.com/v2"

log() { printf '%s\n' "$*"; }

if [[ -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" ]]; then
  log "::warning::Docker Hub credentials missing - skipping prune."
  exit 0
fi

# Docker Hub login returns a JWT used by the tag management API.
token=$(curl -fsS -X POST "${API}/users/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$DOCKERHUB_USERNAME" --arg p "$DOCKERHUB_TOKEN" '{username:$u,password:$p}')" \
  | jq -r '.token // empty' || true)

if [[ -z "$token" ]]; then
  log "::warning::Could not authenticate with Docker Hub - skipping prune."
  exit 0
fi

# Collect every rpn-* tag together with its last update time.
tags_file=$(mktemp)
trap 'rm -f "$tags_file"' EXIT

url="${API}/repositories/${REPO}/tags?page_size=100&name=rpn="
page_num=0
while [[ -n "$url" ]] && (( page_num < 50 )); do
  page_num=$(( page_num + 1 ))
  page=$(curl -fsS "$url" -H "Authorization: JWT ${token}" || true)
  [[ -n "$page" ]] || break
  printf '%s' "$page" | jq -c '.results[]? | {name, last_updated}' >> "$tags_file"
  next=$(printf '%s' "$page" | jq -r '.next // empty' || true)
  url="${next}"
done

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

for tag in "${stale[@]}"; do
  log "Deleting ${REPO}:${tag}"
  if ! curl -fsS -X DELETE "${API}/repositories/${REPO}/tags/${tag}/" \
    -H "Authorization: JWT ${token}" >/dev/null; then
    log "::warning::Could not delete ${tag} (token may lack delete scope)."
  fi
done

log "Pruned ${#stale[@]} tag(s)."
