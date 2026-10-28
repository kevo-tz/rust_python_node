# Changelog

All notable consumer-visible changes to this image are recorded here.

## Unreleased

### Added

- Native build toolchain in the final image: `build-essential` (`gcc`, `g++`,
  `make`), `pkg-config`, `libssl-dev`, and `zlib1g-dev`. Common crates such as
  `openssl-sys` and `libz-sys`, node-gyp source builds, and C++ dependencies now
  compile without installing packages at runtime.
- Developer utilities: `openssh-client` (for `git@...` remotes), `jq`, `less`,
  `unzip`, and `vim-tiny`.
- `WORKDIR /workspace`, so an interactive container no longer starts in `/`.
- `scripts/dx-smoke.sh`, which runs the documented non-root quickstart in CI.
- `.hadolint.yaml`, `CHANGELOG.md`, and `TODOS.md`.

### Changed

- Release tags are promoted only after amd64 and arm64 smoke tests pass. The
  build pushes only the internal `rpn-staging` tag first; `latest`, `main`,
  `rpn-*`, and `v<toolchain>` move afterwards, with digest verification and
  retries. `latest` moves last.
- `sha-*` is now a verified, immutable reference: it is promoted only after the
  smoke gate and is never overwritten by schedules, dispatches, or re-runs.
- The weekly scheduled build performs a real apt refresh through
  `APT_CACHE_BUST`; push builds reuse the cached apt layer.
- arm64 bytes are executed under QEMU in CI before promotion, not just built.
- The doubled slash in `PATH` (`/home/.local//bin`) is fixed.
- Dockerfile line endings are LF and the file ends with a newline.

### Compatibility

- The default user remains root, with `HOME=/home`, `UV_HOME=/home/.local/`,
  `DEBIAN_FRONTEND=noninteractive`, and `CMD ["bash"]`.
- `rpn-staging` is internal, unsupported, and may point at an unverified build.
  Do not use it as a release reference.

No breaking changes.
