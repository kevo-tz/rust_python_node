# Rust Python Node

A Docker image with Rust, Python (via [uv](https://docs.astral.sh/uv/)), and
Node.js for multi-language development. Published for `linux/amd64` and
`linux/arm64`.

- Slim Trixie base
- Rust 1.99.1
- Node.js 26.12.1
- Python 3.15.1 (managed by uv)
- uv 0.13.5

## What's included

| Component | Included |
| --- | --- |
| Rust | `rustc`, `cargo`, `rustfmt`, `clippy`, `rust-analyzer` |
| Node.js | `node`, `npm`, `npx` |
| Python | uv-managed CPython, `python`, `python3`, `venv`, `pip` in a venv |
| uv | `uv`, `uvx` |
| Version control | `git`, `openssh-client` (for `git@...` remotes) |
| Build tooling | `build-essential` (`gcc`, `g++`, `make`), `pkg-config`, `libssl-dev`, `zlib1g-dev` |
| Utilities | `curl`, `jq`, `less`, `unzip`, `vim-tiny` |

`cmake` is intentionally not included. It adds roughly 30 MB and the common
Rust/Python/Node build paths do not need it; install it in a derived image if
your project does.

The native toolchain is present so common crates compile without an `apt-get`
detour. In particular, `openssl-sys`, `libz-sys`, node-gyp source builds, and
C++ dependencies work out of the box.

## Quickstart

Pull the image:

```bash
docker pull kevotz/rust_python_node
```

Run it against a repository on a Linux host. This is the supported non-root
recipe; it keeps created files owned by your host UID and avoids git's
"dubious ownership" check:

```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/workspace" \
  -w /workspace \
  kevotz/rust_python_node
```

Inside the container:

```bash
git status
cargo new --bin --vcs none hello
(cd hello && cargo build && ./target/debug/hello)
uv venv .venv
.venv/bin/python -c 'import ssl, sqlite3, zlib'
```

The image defaults to UID 0 with `HOME=/home` and `WORKDIR /workspace`. That
default is kept for compatibility with derived images. `/workspace` itself is
root-owned; the `--user` plus bind-mount plus `-w /workspace` recipe above is
what makes non-root work. If you run as root against a bind mount, git will
report `detected dubious ownership` and created files will be owned by root.

## Build locally

```bash
docker build -t rpn:test .
scripts/dx-smoke.sh rpn:test
```

The CI smoke gate also checks the native toolchain end to end. The important
checks are:

```bash
docker run --rm rpn:test bash -lc 'pkg-config --exists openssl'
docker run --rm rpn:test bash -lc 'cargo new --bin --vcs none /tmp/hi && cd /tmp/hi && cargo build'
```

`scripts/dx-smoke.sh` is the exact non-root quickstart gate CI runs. It checks
`git status` against a bind mount, `cargo build`, `uv venv`, and that files keep
the caller's UID.

## Tags

| Tag | Description |
| --- | --- |
| `latest` | Most recent verified build |
| `main` | Most recent verified build from the `main` branch |
| `rpn-YYYYMMDD-HHMMSS` | Timestamped snapshot in UTC; the 10 most recent are kept |
| `sha-<short-sha>` | Verified build for a commit; promoted once and never overwritten |
| `v<rust>-node<node>-py<python>-uv<uv>` | Exact toolchain versions; mutable, rebuilt weekly |
| `rpn-staging` | Internal pre-verification pointer; unsupported, may be broken |

Pin the toolchain tag for approximate reproducibility:

```bash
docker pull kevotz/rust_python_node:v1.99.1-node26.12.1-py3.15.1-uv0.13.5
```

`v<toolchain>` is mutable: the weekly rebuild can move it when Debian or the
base image changes. `sha-*` is different: it is promoted only after the amd64
and arm64 smoke tests pass, and once it exists it is never overwritten. For
exact bytes, pin a digest:

```bash
docker pull kevotz/rust_python_node@sha256:...
```

Only tags promoted after verification are safe release references.
`rpn-staging` is internal and may point at an unverified build; do not use it.

## Weekly updates

The weekly scheduled workflow performs a real apt refresh. It passes
`github.run_id` as `APT_CACHE_BUST`, which invalidates the final apt layer and
re-runs `apt-get update`, `apt-get upgrade`, and the package install. Push
builds pass `0` and reuse the layer cache. In other words: scheduled builds
ship Debian security updates; ordinary pushes do not.

## Image size

Measured from the built image's amd64 registry manifest: about 527 MB
compressed. The local uncompressed image is about 2.07 GB. The
workflow records both compressed size and pull-to-hello-world time in the job
summary and warns above 600 MB or 8 minutes; those thresholds do not block a
release.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `error: No download found for request: cpython-3.15.2-linux-x86_64-gnu` | The requested Python version is not available for this platform in the uv index. | Use a supported `PYTHON_VERSION` and rebuild. This is a build-time failure, not a runtime one. |
| `fatal: detected dubious ownership in repository at '/workspace'` | A root container is using a bind mount owned by your host user. | Use the `--user "$(id -u):$(id -g)"` recipe above. As a fallback, run `git config --global --add safe.directory /workspace`. |
| `error: Failed to initialize cache at /home/.cache/uv: Permission denied` | Running as a non-root UID without a writable `HOME`. | Pass `-e HOME=/tmp` (as in the quickstart), or mount a writable home directory. |

## Contributing

Contributions are welcome. Before opening a pull request:

```bash
shellcheck .github/scripts/*.sh scripts/*.sh
docker run --rm -v "$PWD:/mnt" -w /mnt hadolint/hadolint:v2.14.0 \
  hadolint --failure-threshold error Dockerfile
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7
```

The workflow runs the same checks, builds the image, smoke-tests amd64 and
arm64, and only then promotes release tags.

## License

This project is licensed under the MIT License.
