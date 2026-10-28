#!/usr/bin/env bash
#
# Reproduce the README quickstart as a non-root user against a bind mount.
# This is the documented way to use the image on a Linux host: git, cargo and
# uv must all work and created files must keep the caller's UID/GID.
#
# Usage: scripts/dx-smoke.sh <image-reference>

set -euo pipefail

IMAGE="${1:?usage: scripts/dx-smoke.sh <image-reference>}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

repo="${tmpdir}/repo"
mkdir -p "$repo"
git -C "$repo" init -q
printf 'dx-smoke repository\n' > "${repo}/README.md"

# -i, not -it: CI has no TTY. HOME must be writable for cargo and uv caches.
docker run --rm -i \
  --user "${HOST_UID}:${HOST_GID}" \
  -e HOME=/tmp \
  -v "${repo}:/workspace" \
  -w /workspace \
  "${IMAGE}" bash -lse <<'CONTAINER_SCRIPT'
set -euo pipefail
printf 'container user: %s:%s home: %s\n' "$(id -u)" "$(id -g)" "${HOME}"
git status --short
printf 'created by dx-smoke\n' > dx-smoke-file.txt
cargo new --bin --vcs none /tmp/dx-hi
cd /tmp/dx-hi
cargo build
./target/debug/dx-hi
uv venv /tmp/dx-venv
/tmp/dx-venv/bin/python -c 'import ssl, sqlite3, zlib'
for tool in ssh jq less unzip vi; do
  command -v "$tool" > /dev/null
done
CONTAINER_SCRIPT

created="${repo}/dx-smoke-file.txt"
if [[ ! -f "$created" ]]; then
  echo "dx-smoke: container did not create ${created}" >&2
  exit 1
fi

if [[ "$(cat "$created")" != "created by dx-smoke" ]]; then
  echo "dx-smoke: ${created} has unexpected contents" >&2
  exit 1
fi

owner="$(stat -c %u "$created" 2>/dev/null || stat -f %u "$created")"
if [[ "$owner" != "$HOST_UID" ]]; then
  echo "dx-smoke: ${created} is owned by uid ${owner}, expected ${HOST_UID}" >&2
  exit 1
fi

# The host-side repo must still be usable as the calling user.
git -C "$repo" status --short > /dev/null

printf 'dx-smoke: OK (image=%s, uid=%s)\n' "$IMAGE" "$HOST_UID"
