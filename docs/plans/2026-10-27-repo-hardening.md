# Repo hardening: make the image usable, make the factory trustworthy

Date: 2026-10-27
Branch: main
Status: approved as-is at the final approval gate (2026-10-27); implemented and
verified locally (2026-10-28).

## Context

`kevotz/rust_python_node` publishes a weekly Docker image with Rust, Node.js and
Python (via uv). This is a small repo: a Dockerfile, one workflow, one prune
script, a README. The maintainer is effectively the only user; Docker Hub shows
modest lifetime pulls and no issue traffic.

Evidence gathered against a local build of HEAD (`rpn-review:fixed`, docker
29.9.2) and the GitHub Actions API:

| Probe | Result |
| --- | --- |
| `cargo new && cargo build` | passes (base ships gcc + libc6-dev) |
| `cargo add openssl-sys && cargo build` | **fails**: `pkg-config could not be found` |
| `command -v make g++ pkg-config` | **all missing** |
| `python -m venv` + `pip` | passes (pip 26.2.2) |
| `uv sync` with a real project | passes |
| `python3`, `rust-analyzer`, `rustfmt`, `cargo-clippy` | present on PATH |
| `bash -lc` PATH | works because of HEAD's `/etc/profile.d` fix |
| Dockerfile encoding | **CRLF, no trailing newline** |
| Last 25 scheduled runs | **58-80 seconds each** (GitHub Actions API) |
| Last cold multi-arch push | 15m17s |
| Workflow order | build+push all tags, **then** smoke test |
| Image size (HEAD build) | 1.95 GB uncompressed, 498,205,407 bytes compressed amd64 |
| Cost of the full package set below | **89,156 KB installed** (measured in a HEAD container) |
| arm64 coverage | built under QEMU, **never executed** in CI |
| `docker run -v "$PWD:/workspace"` as root | `git status` fails: "detected dubious ownership"; files owned `0:0` |
| `--user "$(id -u):$(id -g)" -e HOME=/tmp` | verified: `git status`, `cargo build`, `uv venv`, `python3` all pass; files owned by the host UID |
| `COPY --from=node:${NODE_VERSION}-trixie-slim` | **fails**: `variable expansion is not supported for --from` (docker 29.9.2) |
| Global `ARG` before `FROM`, not redeclared in the stage | expands empty (verified) |
| `imagetools create -t a -t b IMAGE@digest` | every tag keeps the **same index digest** (verified against a local registry) |
| `command -v a b c` under `dash` | checks only the first name (verified) |
| `type=sha` on `schedule` | reuses the default-branch `github.sha`, so the same `sha-*` tag is rebuilt weekly |

Four facts change the shape of the original plan:

1. **The pipeline publishes before it verifies.** `push: true` runs in the build
   step; the smoke test runs afterwards against the pushed digest. A broken
   image reaches `latest`, `main` and a timestamped tag before any test runs.
2. **The weekly "rebuild" is a cache hit.** 25 consecutive scheduled runs finish
   in about a minute. The `apt-get upgrade` layer is cached, so the weekly job
   re-pushes the same bytes under a new `rpn-*` tag. The README claim that the
   weekly job refreshes patches is false as implemented.
3. **The `sha-*` tag is not immutable as published.** A scheduled run reuses the
   default branch's `github.sha`, so the weekly cache-bust rebuild pushes new
   bytes under the same `sha-*` tag. If that smoke fails, the previously
   verified `sha-*` tag is replaced by broken bytes.
4. **Promotion is not atomic.** `imagetools create` pushes tags sequentially. A
   failure partway through can move `latest` but not `main`/`rpn-*`. The plan
   needs digest verification, a promotion order with `latest` last, and a retry.

Eng-review corrections, verified locally:

- The `node-base` stage must stay: `COPY --from` does not expand
  `$NODE_VERSION`. Only its dead `apt-get upgrade` is removed.
- The final-stage `apt-get upgrade` is the patch mechanism and must stay. The
  dead upgrades are in the throwaway `uv-base` and `node-base` stages.
- A global `ARG APT_CACHE_BUST` before `FROM` is invisible in the final stage; it
  must be declared inside the stage.
- `command -v ssh jq less unzip vi` silently checks only `ssh` under `dash`; use
  a bash loop.

Prior reviews (2026-10-26) already fixed the login-shell PATH reset and the
Docker Hub tag substring filter. Two items were deliberately skipped there and
stay skipped: SHA-pinning GitHub Actions, and digest-pinning base images.

Correction carried from the CEO review: the 3.15.2 incident was not a
Dockerfile/README mismatch. `ff5e02c` changed both together; `6b7df2b` reverted
both. `uv python install 3.15.2` simply failed, and the build caught it. A
README drift guard would have passed the whole time and is cut from this plan.

## Implementation plan

### 1. Dockerfile: add the native build toolchain (P1, correctness)

File: `Dockerfile`

Add to the final-stage apt install list, keeping `--no-install-recommends`:

```
build-essential pkg-config libssl-dev zlib1g-dev
openssh-client jq less unzip vim-tiny
```

Rationale:
- `build-essential` adds `make` and `g++` to the `gcc` the Rust base already
  carries. Without `make`, node-gyp source builds and many `-sys` crates fail.
  Without `g++`, C++ dependencies fail.
- `pkg-config` + `libssl-dev` unblock `openssl-sys` and every crate that probes
  system OpenSSL. This is the most common real failure for a Rust dev image.
- `zlib1g-dev` covers `libz-sys` and other common `-sys` crates.
- `openssh-client` makes `git clone git@...` work. Private repos are core to
  development; without it the image cannot fetch them.
- `jq`, `less`, `unzip`, `vim-tiny` remove daily papercuts (JSON in CI,
  pagers, archives, `git commit` without `-m` needs an editor).

Measured cost of the full set: **89 MB installed** in a HEAD container.
`cmake` is deliberately excluded (+30 MB); the README says so.

Rejected alternative, recorded so it is not re-litigated: switching the base to
`rust:${RUST_VERSION}-trixie` (non-slim) would add buildpack-deps and cost
roughly +275 MB compressed versus roughly +45 MB for this package set.

Acceptance: in the built image, `cargo build` of a crate with `openssl-sys`
succeeds; `make`, `g++`, `pkg-config` resolve; a C program that includes
`<openssl/ssl.h>` compiles and links with `-lssl -lcrypto`.

### 2. Dockerfile: hygiene fixes (P2)

File: `Dockerfile`

- Convert CRLF line endings to LF and add the missing trailing newline.
- Keep the `node-base` stage, which exists only to make the Node version an
  ARG. Remove its dead `apt-get upgrade` and keep
  `COPY --from=node-base /usr/local /usr/local`. Direct
  `COPY --from=node:${NODE_VERSION}-trixie-slim` is a build error: `COPY --from`
  does not expand variables (verified with docker 29.9.2).
- Delete the `apt-get upgrade` in the `uv-base` stage. Only `$HOME/.local` is
  copied out, so the upgraded system packages are discarded. Keep
  `apt-get update` and the `curl` install, and clean `/var/lib/apt/lists/*`.
- Keep the final-stage `apt-get upgrade`: it is the mechanism that actually
  ships patched system packages on the weekly cache-busted rebuild. Removing it
  would make the cache-bust pointless.
- Add `WORKDIR /workspace` so `docker run -it <image>` does not land in `/`.
  The directory is root-owned (0755); the documented non-root recipe works
  because a bind mount and explicit `-w /workspace` override it.
- Fix the doubled slash in `PATH` (`/home/.local//bin` to `/home/.local/bin`),
  using a literal path so derived images keep the same layout.
- Keep `ENV DEBIAN_FRONTEND=noninteractive` and `ENV UV_HOME`. Both are
  observable in the current image and changing them can break derived images.
  Add a comment that `UV_HOME` is a copy path, not a uv setting.

Explicitly not changed (behavior compatibility): `HOME=/home`, root user,
`ENV DEBIAN_FRONTEND`, `ENV UV_HOME`, `CMD ["bash"]`.

### 3. Workflow: verify before publishing (P1, critical)

File: `.github/workflows/build-push-action.yml`

Current order on a push: build multi-arch, push every tag, run smoke test. New
order:

1. Build multi-arch and push **only** the internal `rpn-staging` tag. This tag
   is documented as unsupported and may point at an unverified build. Record the
   manifest digest.
2. Run the smoke test against `IMAGE@digest` on amd64, then a reduced smoke test
   under `--platform linux/arm64` that asserts `uname -m` is `aarch64`, builds a
   hello-world crate, and imports `ssl` from Python. This is the first time
   arm64 bytes are ever executed before release.
3. Compute the release tag list from `docker/metadata-action` output, then drop
   `sha-*` on schedule/dispatch and whenever that tag already exists. On a push,
   promote `sha-*` only if it is absent.
4. Promote the non-latest tags with one `docker buildx imagetools create` call
   (`sha-*` if new, `rpn-*`, `v<toolchain>`, `main`), verify every digest, then
   promote `latest` in a second call and verify it. Retry each call up to 3
   times. `latest` cannot move unless every earlier tag is digest-verified.
5. A single `imagetools create` with multiple tags is the closest thing to an
   atomic promotion the registry offers; it is still sequential internally.
   Splitting `latest` into the last call gives the strongest ordering guarantee
   available. The retry plus digest check makes a partial promotion visible and
   recoverable without a rebuild. If promotion still fails, the workflow fails
   and the job summary lists which tags moved; re-running the promote step
   converges.

This supersedes the earlier "push only `sha-<short>`" mechanism. The obligation
is preserved and strengthened: **no release tag moves before the smoke gate**.
Because `sha-*` is now published after verification and never overwritten, it
becomes a genuine immutable, verified reference for a commit.

PR runs keep today's behavior: build amd64 with `load: true`, smoke test, no
push. The verify-before-publish sequence applies to push, schedule and manual
dispatch.

Drills (manual, default-branch only) are `workflow_dispatch` inputs:

- `drill=fail-smoke` makes the smoke step exit 1 after the real checks. The run
  must fail and `latest`/`main`/`rpn-*`/`v<toolchain>` must keep their old
  digests.
- `drill=repeat-promote` runs the promotion twice. Every tag must keep the same
  digest, proving idempotency.

Acceptance: a `drill=fail-smoke` run leaves every release tag unchanged and
fails; `drill=repeat-promote` leaves every tag digest-equal to the built digest.

### 4. Workflow: make the weekly rebuild real (P1)

File: `Dockerfile`, `.github/workflows/build-push-action.yml`

Add `ARG APT_CACHE_BUST=0` **inside the final stage**, immediately before the
cache-busted `RUN`. A global ARG declared before `FROM` is not visible in the
stage (verified: it expands empty). Reference it in the same `RUN` and write it
to a file:

```
RUN set -euxo pipefail; \
    echo "apt cache bust: ${APT_CACHE_BUST}"; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ...; \
    rm -rf /var/lib/apt/lists/*; \
    install -d /etc/rpn; \
    printf '%s\n' "${APT_CACHE_BUST}" > /etc/rpn/apt-cache-bust
```

Keep the final-stage `apt-get upgrade`; remove the dead upgrades only from
`uv-base` and `node-base`. Move `rustup component add rustfmt clippy rust-analyzer`
into its own `RUN` **before** the cache-busted apt layer, so the weekly rebuild
does not re-run it.

Pass `APT_CACHE_BUST=${{ github.run_id }}` only on `schedule` runs. Every other
event passes `0` and keeps cache reuse.

Smoke asserts the baked value: equals `github.run_id` on schedule, `0` on push.
A misplaced ARG yields an empty value and fails the smoke instead of only
printing a log line.

Update the README: the weekly job performs a real apt refresh; pushes do not.

Acceptance: a scheduled run executes the apt layer, the baked value equals the
run id, and the run takes materially longer than a minute.

### 5. Workflow: smoke test what actually breaks (P1)

File: `.github/workflows/build-push-action.yml`, `scripts/dx-smoke.sh` (new)

Deterministic checks (no network) on every build:

- `cargo new --bin --vcs none /tmp/hi && cargo build` and run the binary.
- `make --version`, `g++ --version`, `pkg-config --version`.
- `pkg-config --exists openssl`.
- Compile and link a C program against `-lssl -lcrypto`, and a C++ program with
  `g++`, then run both. This proves headers and linking, not just command
  presence.
- `python3 --version`, `python -m venv /tmp/venv`, and
  `/tmp/venv/bin/python -c 'import ssl, sqlite3, zlib'`.
- `uv venv /tmp/uvenv` (no dependency resolution, no network).
- `rust-analyzer --version`, `rustfmt --version`, `cargo clippy --version`.
- For each of `ssh jq less unzip vi`, run `command -v` separately in a bash
  loop. A single multi-name `command -v` under `dash` checks only the first.
- Keep the existing `bash -leo` login-shell PATH check for
  `rustc cargo uv python node`.
- Assert behavior compatibility: `id -u` is `0`, `HOME=/home`,
  `UV_HOME=/home/.local/`, `pwd` is `/workspace`, `PATH` has no `//`, and
  `docker inspect` reports `Cmd=["bash"]`.
- Assert `/etc/rpn/apt-cache-bust` is `0` on push (run id on schedule).
- Execute the README quickstart as a non-root user via
  `scripts/dx-smoke.sh "$IMAGE"`: create a temp git repo with `mktemp -d` and a
  trap, run the documented recipe with `-i` (not `-it`; CI has no TTY), then
  `git status`, `cargo new && cargo build`, `uv venv`, and assert the files are
  owned by the calling UID. Use a `stat -c %u` / `stat -f %u` fallback and a
  bash loop for the tool checks.
- Record compressed size by summing the registry manifest's layer sizes
  (`docker buildx imagetools inspect --raw` + `jq`), not `docker image inspect`
  (which is uncompressed). Record pull-to-hello-world after removing the local
  image and timing a real pull; label it runner-measured. Warn above 600 MB /
  8 minutes; hard gating is deferred (shared runner timing is noisy).

Network checks, only on `schedule` and `workflow_dispatch`:

- Build a scratch crate that depends on `openssl-sys` (real crates.io fetch) to
  prove the end-to-end native build path.

Acceptance: removing `build-essential`, `pkg-config` or `libssl-dev` from the
Dockerfile fails the smoke test.

### 6. Workflow: hardening (P2)

File: `.github/workflows/build-push-action.yml`

- Add `permissions: contents: read` at workflow level.
- Add `timeout-minutes: 90` to the job.
- Skip QEMU setup on PRs, where only `linux/amd64` is built.
- Change `concurrency.cancel-in-progress` to cancel PR runs only. Pushes and
  schedules queue in the same group: a push must not cancel a weekly rebuild
  mid-apt, and two promotions must not race. Cancellation between the staging
  push and promotion would otherwise leave an unreferenced staging digest.

Not changed: action SHA pinning and base-image digest pinning (settled
decisions, recorded as skipped in prior reviews).

### 7. Workflow: lint (P2)

Files: `.github/workflows/build-push-action.yml`, `.hadolint.yaml` (new)

Add a `lint` job on PRs and pushes:

- `shellcheck .github/scripts/*.sh scripts/*.sh` (the new smoke script must be
  covered by the same glob, not left unlinted).
- `hadolint --failure-threshold error Dockerfile` (via the `hadolint/hadolint`
  image), with `.hadolint.yaml` ignoring `DL3008` (unpinned apt packages are
  deliberate; the weekly cache-bust is the patch mechanism) and documenting any
  other accepted warning.
- `actionlint` via `rhysd/actionlint`.
- Fail if `Dockerfile` contains CR (`grep -q $'\r'`) or lacks a trailing
  newline.

The lint job is blocking for errors only. Warnings stay visible without
blocking a release.

### 8. README (P2)

File: `README.md`

- Add "What's included": Rust + rustfmt/clippy/rust-analyzer, Node/npm/npx,
  Python via uv, uv/uvx, git, curl, ssh, jq, less, unzip, vi, and the exact
  native package set. State that `cmake` is not included.
- Add "Build locally" and the exact smoke command used by CI.
- Add a usage example that actually works on Linux. The root bind-mount recipe
  fails (`git` dubious ownership, root-owned files), so the documented quickstart
  is:
  `docker run --rm -it --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/workspace" -w /workspace kevotz/rust_python_node`
  This recipe is verified: `git status`, `cargo build`, `uv venv` and `python3`
  all pass, and created files are owned by the calling UID.
- State the default user is root with `HOME=/home`, and that the non-root recipe
  above is the supported way to work on a bind mount. `WORKDIR /workspace` is
  root-owned; the mount plus `-w` is what makes the non-root recipe work.
- Add a troubleshooting table with the exact strings and fixes:
  uv `No download found for request: cpython-...`, git `detected dubious
  ownership`, uv `Failed to initialize cache at ...: Permission denied`.
- Keep the tag table and digest-pinning note. Clarify:
  - `v<toolchain>` is mutable (rebuilt weekly).
  - `sha-*` is promoted only after the smoke gate and is never overwritten once
    it exists; it is immutable and verified.
  - `rpn-staging` is internal, unsupported and may point at an unverified build.
  - Only promoted tags passed verification.
- Correct the weekly-rebuild claim and record the measured compressed and
  uncompressed size (estimate before measurement: ~530-540 MB compressed,
  ~2.04 GB uncompressed).

### 9. CHANGELOG.md (P2)

File: `CHANGELOG.md` (new)

Add an `Unreleased` entry that lists the consumer-visible changes: new native
packages, `WORKDIR /workspace`, verify-then-promote tag behavior, `sha-*` now
verified and immutable, the internal `rpn-staging` tag, and the real weekly
rebuild. This is the release note a team reads before upgrading; without it the
behavior changes are invisible.

### 10. TODOS.md (P3)

File: `TODOS.md` (new)

Short list of deferred work, each one line with the trigger that would promote
it:

- Native arm64 runners (`ubuntu-24.04-arm`) instead of QEMU. Trigger: two
  consecutive weekly builds exceed 45 minutes after the cache-bust lands.
- Renovate regex managers for the four Dockerfile ARGs. Trigger: the bump
  commit loop stays manual for another month. (132 of 178 commits are bumps.)
- Non-root `dev` user baked into the image. Trigger: a team adopts the image, or
  the `--user` recipe proves insufficient in reports.
- Pruner integration test against a mocked Docker Hub API (retention,
  pagination, auth failure, `KEEP=0`). Trigger: first prune bug or retention
  report. Shellcheck covers syntax now.
- Promotion atomicity across tags. Trigger: the first partial promotion despite
  the retry/digest check. The registry has no multi-tag transaction primitive.
- GitHub Releases automation keyed to `sha-*` / toolchain tags. Trigger: the
  CHANGELOG has three or more entries.
- Sync the Docker Hub full description from the README. Trigger: next manual
  Docker Hub visit (the current text describes a different project).
- Hard TTHW and compressed-size gates in CI. Trigger: the warn-only metrics show
  stable runner timing.
- SBOM and max provenance. Trigger: a consumer asks for attestations.
- Verify the uv installer script itself (currently fetched and executed over
  TLS; the binary checksums are embedded in that script). Trigger: supply-chain
  review.

## Out of scope

- Toolchain version bumps. Versions are the maintainer's choice; this plan only
  makes the factory trustworthy.
- Changing the tag scheme, retention count or publish triggers.
- Multi-stage size reduction (dropping npm docs, rust docs).
- A README/Dockerfile version drift checker. The premise was wrong: both files
  changed together in `ff5e02c`, and the build already rejects an uninstallable
  CPython.
- `.dockerignore`. There is no build-context `COPY`; adding one has no effect.
- A pruner integration test in this change. The pruner is unchanged, shellcheck
  covers it, and a mock Docker Hub API is a separate harness; recorded in
  TODOS.
- `cmake` and a full devcontainer. Deferred; both are additive and independent.

## Acceptance criteria

1. `docker build -t rpn:test .` succeeds.
2. In the built image: `cargo new && cargo build`, a C program linked with
   `-lssl -lcrypto`, a C++ program, `make`, `pkg-config`, `python3 -m venv`,
   `uv venv`, `rust-analyzer`, `ssh`, `jq` all succeed.
3. `bash -lc` sees `cargo`, `uv`, `python3`, `node`.
4. No release tag (`latest`, `main`, `rpn-*`, `v<toolchain>`) moves until the
   amd64 and arm64 smoke tests pass. `sha-*` is promoted only after the smoke
   gate and only if absent; schedules and re-runs never overwrite it.
5. A scheduled run does real apt work: the final layer is not cached and
   `/etc/rpn/apt-cache-bust` equals the run id; push builds see `0`.
6. `shellcheck` is clean; hadolint reports no errors; actionlint passes; the
   Dockerfile has no CR and ends with a newline.
7. The README quickstart runs green in CI as a non-root user against a mounted
   git repo, and created files keep the caller's UID.
8. Root/default behavior is unchanged: UID 0, `HOME=/home`,
   `UV_HOME=/home/.local/`, `CMD ["bash"]`, no `//` in `PATH`, and
   `pwd` is `/workspace`.
9. `drill=fail-smoke` leaves every release tag at its prior digest and fails the
   run; `drill=repeat-promote` leaves every tag digest-equal to the built digest.
10. Image size delta is measured from the registry manifest's compressed layer
    sizes and written into the review record.

## Implementation verification (2026-10-28)

Host: docker 29.9.2, buildx 0.38.1.

- `docker build -t rpn:test .` succeeded.
- The exact amd64 smoke heredoc from the workflow was extracted and run against
  the local image: cargo hello-world build/run, `make`/`g++`/`pkg-config`,
  C and C++ OpenSSL compile+link+run, `python -m venv` and `uv venv` imports,
  rust-analyzer/rustfmt/clippy, the bash tool loop, and the root/`HOME`/
  `UV_HOME`/`WORKDIR`/`PATH`/`CMD`/cache-bust assertions all passed.
- `scripts/dx-smoke.sh rpn:test` passed as uid 1000; the file created through
  the bind mount was owned by uid 1000.
- The schedule-only `openssl-sys` network check was run manually (`cargo add
  openssl-sys@0.9` then `cargo build`); it compiled against the system OpenSSL.
- `bash -lc` sees `rustc`, `cargo`, `uv`, `python`, and `node`; the login
  `PATH` is `/home/.local/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- `docker build --build-arg APT_CACHE_BUST=12345 -t rpn:test-bust .` rebuilt
  the apt layer (the log shows package setup), baked `12345` into
  `/etc/rpn/apt-cache-bust`, and the smoke assertion passed.
- Size from a local registry manifest: 527,473,967 bytes compressed amd64
  (527 MB / 503 MiB), 2,070,056,973 bytes uncompressed (2.07 GB). Delta versus
  498,205,407 bytes: +29,268,560 bytes compressed (+29.3 MB), below the 600 MB
  warning threshold.
- Lint: shellcheck clean; hadolint exit 0 (DL4006/SC3040/SC2016 warnings are
  documented as accepted in `.hadolint.yaml`); actionlint clean; Dockerfile is
  LF-only and ends with a newline.
- The promotion shell was extracted and run against a local registry with a
  single- and a multi-arch index, including `drill=repeat-promote`: every tag
  kept the built index digest across both promotions, `sha-*` was promoted only
  when absent, and `sha-*` was dropped on a dispatch. The `fail-smoke` step
  exits before promotion, so release tags cannot move in that drill.
- arm64: `docker buildx build --builder default --platform linux/arm64
  --load -t rpn:test-arm64 .` succeeded. The reduced workflow arm smoke and the
  full amd64 assertion script both passed under QEMU (`uname -m` was `aarch64`,
  cargo hello-world built and ran, Python imported `ssl`, Node ran, and the
  OpenSSL C/C++ link tests passed).

The GitHub Actions drills themselves were not run from this host; the promotion
logic and drill sequence were exercised locally as described above.

## Review record

### CEO review (Phase 1)

Mode: SELECTIVE EXPANSION (autoplan override).

Premise challenge: the usability premise is confirmed by probes. The
"regressions catchable" premise was **not** true as written: the pipeline
publishes before testing, and the weekly rebuild is a cache hit. Both are now
P1 items. The original "README drift" premise was wrong and is cut.

Alternatives considered: `rust:trixie` base (+275 MB compressed), two image
variants, non-root by default, digest pinning. Chosen: slim base plus the
measured 89 MB package set; single variant; non-root supported via a documented
`--user` recipe, not a default change.

Auto-decisions:
- Cut `.dockerignore` (no build-context COPY).
- Cut README version-drift check (premise false).
- Cut `DEBIAN_FRONTEND`/`UV_HOME` removals (breaking for derived images).
- Keep `TODOS.md` (deferral record required by the pipeline) instead of moving
  everything to GitHub issues.
- Defer native arm64 runners (separate job matrix, higher risk in the same PR).

Accepted obligations:
<!-- autoplan-accepted:ceo -->
- Verify-before-publish: on push, only `sha-<short>` is pushed before the smoke
  test; `latest`, `main`, `rpn-*` and the toolchain tag are promoted only after
  the smoke test passes on the pushed digest.
- Weekly cache-bust: `APT_CACHE_BUST` is set from `github.run_id` on `schedule`
  only, referenced inside the final apt layer, and a scheduled run must show
  real apt work.
- Toolchain: `build-essential pkg-config libssl-dev zlib1g-dev` in the final
  image; verified by compile+link tests against OpenSSL and by `pkg-config`.
- Deterministic smoke tests on every build: cargo hello-world, C and C++ compile
  and link, `pkg-config --exists openssl`, `python3 -m venv` with `import ssl,
  sqlite3, zlib`, `uv venv`, `rust-analyzer`/`rustfmt`/`clippy`, login-shell
  PATH.
- Network-dependent `openssl-sys` crate build runs only on `schedule` and
  `workflow_dispatch`.
- CRLF to LF, trailing newline, single `node-base` removal by copying Node
  directly, dead `apt-get upgrade` removed from both build stages, `WORKDIR
  /workspace`, `PATH` double-slash fix.
- `permissions: contents: read`, job timeout, QEMU skipped on PRs.
- Lint job: shellcheck, hadolint (errors only, DL3008 ignored with rationale),
  actionlint.
- README: what's included, local build, smoke command, usage example, root
  limitation, corrected weekly-rebuild claim, measured size.
- TODOS.md with the five deferred items and their promotion triggers.
- Behavior-compatible: `HOME=/home`, root user, `ENV DEBIAN_FRONTEND`,
  `ENV UV_HOME`, `CMD ["bash"]` stay.
<!-- /autoplan-accepted:ceo -->

Eng supersession (Phase 3): the sha-only pre-smoke mechanism is replaced by an
internal `rpn-staging` tag, and `node-base` is kept (only its dead upgrade is
removed). The obligation itself is unchanged: no release tag moves before the
smoke gate. `sha-*` is now promoted after verification and never overwritten.
See the Eng accepted obligations below.

CEO completion summary:

```
  +====================================================================+
  |            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
  +====================================================================+
  | Mode selected        | SELECTIVE EXPANSION                         |
  | System Audit         | 4-file infra repo; 25/25 scheduled runs are  |
  |                      | cache hits; publish happens before smoke    |
  | Step 0               | premises amended; 3 items cut, 2 added      |
  | Section 1  (Arch)    | 1 issue: publish/test ordering              |
  | Section 2  (Errors)  | 6 error paths mapped, 2 GAPS                |
  | Section 3  (Security)| 1 issue (default perms), 0 High            |
  | Section 4  (Data/UX) | 4 edge cases mapped, 1 unhandled            |
  | Section 5  (Quality) | 3 issues found                              |
  | Section 6  (Tests)   | Diagram produced, 4 gaps                    |
  | Section 7  (Perf)    | 2 issues (cache-bust, QEMU arm64)           |
  | Section 8  (Observ)  | 1 gap (no build provenance of apt refresh)  |
  | Section 9  (Deploy)  | 2 risks (tag rollback, staging window)      |
  | Section 10 (Future)  | Reversibility: 4/5, debt items: 3           |
  | Section 11 (Design)  | SKIPPED (no UI scope)                       |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (5 items)                           |
  | What already exists  | written                                     |
  | Dream state delta    | written                                     |
  | Error/rescue registry| 6 rows, 2 CRITICAL GAPS                     |
  | Failure modes        | 6 total, 2 CRITICAL GAPS                    |
  | TODOS.md updates     | 5 items proposed                            |
  | Scope proposals      | 4 proposed, 1 accepted, 3 deferred/cut      |
  | CEO plan             | written (this file)                         |
  | Outside voice        | codex unavailable (not installed)           |
  | Lake Score           | 2/2 scored choices took the complete option |
  | Diagrams produced    | 2 (pipeline, data flow)                     |
  | Stale diagrams found | 0                                           |
  | Unresolved decisions | 1 (native arm64 runners)                    |
  +====================================================================+
```

Error & Rescue Registry:

```
  CODEPATH                     | WHAT CAN GO WRONG            | CLASS
  -----------------------------|------------------------------|------------------
  docker build (final apt)     | package rename/removal       | apt exit 100
                               | base image tag moved         | digest drift
  uv python install            | version not in uv index      | exit 2
  rustup component add         | network flake               | rustup error
  smoke: cargo build           | no linker / no cc            | exit 101
  smoke: openssl link          | headers/lib missing          | cc exit 1
  promote (imagetools create)  | registry auth expired        | exit 1
  prune script                 | token lacks delete scope     | HTTP 401/403

  CLASS            | RESCUED? | RESCUE ACTION              | USER SEES
  -----------------|----------|----------------------------|-------------------
  apt exit 100     | Y        | build fails, no tags move  | failed CI, no image
  uv exit 2        | Y        | build fails, no tags move  | failed CI, no image
  rustup error     | N ← GAP  | retry once, then fail      | failed CI
  cargo/cc exit    | Y        | no promote; latest intact  | failed CI
  promote exit 1   | N ← GAP  | re-run job; sha tag exists | stale latest
  prune 401/403    | Y        | warn + continue-on-error   | nothing
```

Failure Modes Registry:

```
  CODEPATH            | FAILURE MODE        | RESCUED? | TEST? | USER SEES   | LOGGED?
  --------------------|---------------------|----------|-------|-------------|--------
  push build          | broken image tagged | Y (new)  | Y     | old latest  | Y
  scheduled build     | cache hit, no patch | Y (new)  | Y     | fresh layer | Y
  smoke               | missing tool        | Y        | Y     | failed CI   | Y
  promote             | partial tags        | N ← GAP  | N     | stale tag   | Y
  prune               | tag left behind     | Y        | N     | nothing     | Y
  PR build            | leaks secret        | Y        | N     | nothing     | N
```

Dream state delta:

```
  CURRENT                        THIS PLAN                 12-MONTH IDEAL
  image lacks dev toolchain ---> usable toolchain   --->   "pull and build"
  publish before test       ---> verify then promote --->  every tag trustworthy
  weekly cache hit          ---> real weekly rebuild --->  patches actually ship
  manual version bumps      ---> unchanged (TODO)    --->  automated bump PRs
```

Diagrams:

```
  PR:     build amd64 (load) --> smoke --> done (no push)
  PUSH:   build multi-arch --> push sha-<sha> --> smoke
                                                   |
                                      fail <-------+----> pass --> promote
                                      (latest unchanged)          latest/main/
                                                                  rpn-*/toolchain
  SCHEDULE: same as push, plus APT_CACHE_BUST=run_id
```

<!-- autoplan-accepted:design -->
None: Phase 2 skipped, no UI scope.
<!-- /autoplan-accepted:design -->

### DX review (Phase 2.5)

Product type: **Platform** (a prebuilt development environment). Mode: DX POLISH.

TARGET DEVELOPER PERSONA
========================
Who:       A backend or platform developer who needs Rust, Node and Python in
           one environment without maintaining three toolchains.
Context:   Pulls the image for local work on a polyglot repo, or as the base for
           a CI job. Finds it through Docker Hub or a teammate.
Tolerance: About 5 minutes from discover to a successful build; will not read
           source, will read the README example and copy it.
Expects:   `docker pull`, `docker run`, tools on PATH, and enough build tooling
           that common crates compile. Assumes git works on a bind mount.

Developer empathy narrative:

> "I need one image with Rust, Node and Python. The README gives me a pull
> command and a list of versions, so I pull it. About 500 MB later I run it,
> land in `/`, and start a Rust project. A hello-world builds, which is a good
> sign. Then I add a crate that touches OpenSSL and the build dies telling me
> `pkg-config` is missing. I install it with apt, then `make` is missing for a
> node dependency. I am now debugging the image instead of my project. The
> README has no `docker run` example and no troubleshooting, so I am reading
> error text from three different toolchains. If I mount my repo, git refuses
> to touch it because of dubious ownership and every file comes back owned by
> root. At that point I am 15 minutes in and still not building."

Competitive benchmark (evidence: README, image config, measured pulls):

| Tool | Start -> result | Evidence | DX choice |
| --- | --- | --- | --- |
| This image (HEAD) | pull -> hello world ~3-5 min; real project 8-15 min | observed locally, 498 MB compressed | missing native toolchain, no run example |
| This image (after plan) | pull -> real project 5-7 min | measured toolchain probes | toolchain + quickstart + smoke gate |
| `rust:1.99.1-trixie` | pull -> hello world ~2-4 min | Docker Hub compressed size 602 MB | fatter base, no Node/Python |
| `mcr.microsoft.com/devcontainers/universal` | pull -> hello world ~5-10 min | published docs (multi-GB) | kitchen-sink, slow pull |
| `oven/bun` / `python:3.15-slim` single-runtime | ~1-2 min | 100-200 MB compressed | fastest, wrong problem |

TTHW: today 3-5 minutes for hello world and 8-15 minutes for a real project on a
50 Mbps link. After the plan: 3-5 and 5-7. Target: **<= 4 min p50 / <= 8 min p95**
pull-to-`cargo run` with a mounted repo, and <= 600 MB compressed. A 2-minute
champion tier needs a smaller variant, which is out of scope.

Magical moment: `docker pull` then `cargo run` with no apt-get and no debugging,
including a real crate that links OpenSSL. Delivery vehicle: the verified
non-root quickstart plus the compile/link smoke gate; no hosted service.

Developer journey map:

```
STAGE           | DEVELOPER DOES                      | FRICTION                  | STATUS
----------------|-------------------------------------|---------------------------|--------
1. Discover     | Docker Hub / README                 | Hub text describes a      | deferred
                |                                     | different project         |
2. Install      | docker pull                         | 498 MB, no size stated    | fixed
3. Hello World  | docker run, cargo new/build         | lands in /, no example    | fixed
4. Real Usage   | add openssl-sys, mount a repo       | no pkg-config/make/g++;   | fixed
                |                                     | git ownership as root     |
5. Debug        | read error, search README           | no troubleshooting table  | fixed
6. Upgrade      | toolchain tag moves weekly          | no changelog, no digest   | fixed
                |                                     | example                   |
```

First-time developer confusion report (grounded in captured output):

```
T+0:00  docker pull ... (498 MB)
T+1:40  docker run -it image -> prompt in /, no hint where to work
T+2:10  cargo new hi && cargo build -> works
T+3:00  add openssl-sys -> "pkg-config could not be found" (no fix in README)
T+4:30  apt-get install pkg-config -> next crate needs make -> missing
T+6:00  mount repo -> git status -> "detected dubious ownership"
T+7:30  files created as 0:0 on the host
T+9:00  gives up, or reconstructs the image by hand
```

DX DUAL VOICES — CONSENSUS TABLE:

```
  Dimension                            in-host subagent     Codex   Consensus
  1. Getting started < 5 min?          partial (3-5 hw)     N/A     N/A
  2. Interface naming guessable?       no (root/env/PATH)   N/A     N/A
  3. Error messages actionable?        no (no runbook)      N/A     N/A
  4. Docs findable & complete?         no (no run/trouble)  N/A     N/A
  5. Upgrade path safe?                no (no changelog)    N/A     N/A
  6. Dev environment friction-free?    no (root, no arm64)  N/A     N/A
  7. Community & ecosystem healthy?    no                   N/A     N/A
  8. DX measured over time?            partial              N/A     N/A
CONFIRMED = native + outside; outside unavailable (codex not installed).
```

DX scorecard (primary review; independent voice in parentheses where it differs):

```
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      | 6/10   | 3/10   | up     |
| Interface Design     | 6/10   | 4/10   | up     |
| Error Messages       | 5/10   | 3/10   | up     |
| Documentation        | 7/10   | 2/10   | up     |
| Upgrade Path         | 5/10   | 3/10   | up     |
| Dev Environment      | 6/10   | 4/10   | up     |
| Community            | 2/10   | 2/10   | flat   |
| DX Measurement       | 6/10   | 3/10   | up     |
+--------------------------------------------------------------------+
| TTHW                 | 5-7 min real project (3-5 hello world)      |
| Competitive Rank     | Competitive                                  |
| Magical Moment       | designed via verified non-root quickstart    |
| Product Type         | Platform                                     |
| Mode                 | DX POLISH                                    |
| Overall DX           | 5/10   | 3/10   | up     |
+====================================================================+
| DX PRINCIPLE COVERAGE                                               |
| Zero Friction      | partial (500 MB pull)                         |
| Learn by Doing     | covered (quickstart runs in CI)               |
| Fight Uncertainty  | partial (troubleshooting table, no in-image)  |
| Opinionated + Escape Hatches | covered (root default + --user recipe)|
| Code in Context    | covered (real crate + OpenSSL link test)      |
| Magical Moments    | partial (works, not delightful)               |
+====================================================================+
```

DX implementation checklist:

```
DX IMPLEMENTATION CHECKLIST
============================
[x] Installation is one command (docker pull)
[x] First run produces meaningful output (WORKDIR /workspace, working example)
[x] Every documented example is executed in CI as a non-root user
[x] Native build toolchain proven by compile+link, not --version
[x] Error troubleshooting table with exact strings
[x] Digest-pinning instructions and immutable/mutable tag distinction
[x] arm64 executed before promotion
[x] Size and TTHW metrics recorded in the job summary
[ ] Hard TTHW / size gate (deferred, runner timing noise)
[ ] Changelog entries for every release (CHANGELOG started)
[ ] Community channel / CONTRIBUTING (deferred)
```

Auto-decisions:
- Document and test `--user "$(id -u):$(id -g)" -e HOME=/tmp` instead of baking a
  non-root user into the image (additive, non-breaking). Dev user deferred.
- Add `openssh-client jq less unzip vim-tiny` (measured +~10 MB, removes daily
  papercuts). `cmake` deferred.
- Run the quickstart as a CI gate; hard TTHW/size gates deferred because shared
  runner timing is noisy. Warn-only metrics in the job summary.
- Execute arm64 under QEMU before promotion; native arm runners still deferred.

Accepted obligations:
<!-- autoplan-accepted:dx -->
- The README quickstart must be the verified non-root recipe (`--user
  "$(id -u):$(id -g)" -e HOME=/tmp`) and must pass in CI against a mounted git
  repo, with created files owned by the calling UID.
- `scripts/dx-smoke.sh <image>` must reproduce the quickstart: temp git repo,
  `git status`, `cargo new && cargo build`, `uv venv`, and a UID ownership check.
- The smoke gate must run on amd64 and on `--platform linux/arm64` before any
  tag promotion.
- README must include the troubleshooting table with exact strings for the uv
  Python-version error, git dubious ownership, and uv cache permission denial.
- `CHANGELOG.md` must document the consumer-visible changes (packages, WORKDIR,
  sha-before-verify, verify-then-promote, weekly rebuild).
- README must clarify that `v<toolchain>` is mutable and `sha-*` is produced
  before the smoke gate.
- Job summary must record compressed size and elapsed pull-to-hello-world
  seconds (warn-only thresholds 600 MB / 8 min).
<!-- /autoplan-accepted:dx -->

Eng supersession (Phase 3): `sha-*` is now published only after the smoke gate
and never overwritten, so the README says it is verified and immutable. The
internal `rpn-staging` tag is the only pre-verification tag, and it is documented
as unsupported. `CHANGELOG.md` records that corrected contract.

### Eng review (Phase 3)

Mode: HOLD SCOPE. The plan's shape is right; the mechanism needed correction.

Scope Challenge:

- A. Target assessment: 7 changed/new files (`Dockerfile`, workflow, `README.md`,
  `CHANGELOG.md`, `TODOS.md`, `.hadolint.yaml`, `scripts/dx-smoke.sh`), 0 new
  classes/services. No shared-code extraction: the Dockerfile and the two shell
  scripts have different contracts and runtimes, and there are no authored
  callers to prove a shared helper. The existing pruner is reused unchanged.
- B. Complexity selectors: skipped. 7 files is below the 8-file threshold and
  there are no new services.
- C. Findings:

```
  #  SEV  FINDING                                              DISPOSITION
  1  P0   COPY --from=node:${NODE_VERSION} is a build error    fixed: keep
          (verified docker 29.9.2)                             node-base stage
  2  P1   schedule rebuilds overwrite the same sha-* tag       fixed: staging tag;
                                                               sha promoted once
  3  P1   promotion is non-atomic and unverified               fixed: digest check,
                                                               retry, latest last
  4  P1   arm64 smoke does not prove the architecture          fixed: assert
                                                               uname -m + build
  5  P2   cancel-in-progress can kill a schedule mid-promote   fixed: cancel PRs
                                                               only; queue rest
  6  P2   global APT_CACHE_BUST ARG is invisible in stage      fixed: declare in
                                                               final stage + file
  7  P2   removing the final apt upgrade would stop patches    fixed: keep it;
                                                               remove only dead
                                                               throwaway upgrades
  8  P2   dx-smoke would be unlinted and uses -it/stat -c      fixed: lint glob,
                                                               -i, stat fallback
  9  P2   multi-name command -v under dash checks one name     fixed: bash loop
 10  P2   pruner and partial-promotion paths untested          pruner -> TODO;
                                                               promotion drill
```

Scope result: **scope accepted as-is**. Findings 1-9 are corrections inside the
accepted scope; finding 10 defers the pruner harness to TODOS.

#### 1. Architecture review

Issues found: 4.

1. **P0, high - the Node copy as planned does not build.** `COPY --from` does not
   expand `$NODE_VERSION`; verified error: `variable expansion is not supported
   for --from`. Keep the `node-base` stage and remove only its dead upgrade.
2. **P1, high - pre-smoke publishing is not safe for `sha-*`.** A scheduled run
   reuses the default branch's `github.sha`, so `type=sha` resolves to the same
   tag each week. Cache-busted bytes plus a failed smoke would replace a verified
   `sha-*` with broken bytes. Fix: build to `rpn-staging`, promote `sha-*` only
   after smoke and only if absent.
3. **P1, high - promotion is sequential and unverified.** `imagetools create`
   pushes tags one at a time. The plan had no digest check and no retry. Fix:
   non-latest tags verified, then `latest` last, 3 retries, digest equality for
   every tag. Verified locally that a single-source `imagetools create` preserves
   the index digest across all target tags.
4. **P2, medium - cancellation windows.** `cancel-in-progress: true` can cancel a
   push between staging and promotion, or cancel the weekly schedule mid-apt.
   Fix: cancel PR runs only; pushes and schedules queue.

Distribution check: staging is a public but unsupported tag; release tags are
promoted only from a digest that passed both smoke tests. The registry has no
multi-tag transaction; the residual split-tag risk is recorded in TODOS.

Pipeline diagram (updated):

```
  PR:       build amd64 (load) --> smoke amd64 + dx-smoke --> done (no push)

  PUSH/SCHEDULE:
    build multi-arch --> push rpn-staging@digest
                              |
                              v
                    smoke amd64 --> smoke arm64 (assert aarch64)
                              |
                     fail <---+---> pass
                (no release tag)     |
                                     v
                    promote in order: sha (if absent) -> rpn-* ->
                    v<toolchain> -> main -> latest
                                     |
                              verify each tag digest == built digest
                                     |
                              retry x3 on failure
```

#### 2. Code quality review

Issues found: 5 (all folded into the plan sections above).

1. **P1 - ARG scope.** A global `ARG APT_CACHE_BUST` before `FROM` expands empty
   in the final stage (verified). Declare it inside the final stage and bake the
   value into `/etc/rpn/apt-cache-bust` so smoke can assert it.
2. **P1 - keep the final upgrade.** The final-stage `apt-get upgrade` is the
   patch mechanism. Only the throwaway `uv-base` and `node-base` upgrades are
   dead. Removing the final one would make the cache-bust cosmetic.
3. **P2 - rustup layer ordering.** Move `rustup component add` before the
   cache-busted apt layer so the weekly rebuild does not redo it.
4. **P2 - dx-smoke quality.** Use `mktemp -d` + trap, `-i` not `-it` (no TTY in
   CI), bash loops for `command -v`, and a `stat -c`/`stat -f` fallback. Add
   `scripts/*.sh` to the shellcheck glob.
5. **P2 - tag-list drift.** Derive the promotion list once from the metadata
   output and reject empty or unexpected counts; do not re-glob tags with
   `grep ':sha-'`.

Shared-code rubric: no extraction. The pruner, dx-smoke and workflow shell have
different inputs, failure modes and runtimes; a shared helper would add coupling
without removing a proven duplicate. Existing reuse retained: `metadata-action`
for tags, `buildx imagetools` for promotion, the pruner for retention.

#### 3. Test review

Framework: none (Docker/CI shell assertions). Verification is the smoke gate,
lint job and the manual drills; no unit-test framework is introduced.

```
CODE PATHS
├─ Dockerfile build (stages, LF)            [★★★ TESTED] CI build + lint CR check
├─ native toolchain (make/g++/pkg-config)   [★★★ TESTED] new smoke
├─ OpenSSL headers + C/C++ link             [★★★ TESTED] new smoke
├─ openssl-sys real crate (network)         [★★ TESTED]  schedule/dispatch only
├─ node/npm copied via node-base            [★★ TESTED]  --version only
├─ uv-base/node-base upgrade removal        [GAP]        unobservable, no test
├─ WORKDIR /workspace                       [★★★ TESTED] pwd assertion
├─ PATH double slash                        [★★★ TESTED] exact PATH assertion
├─ CRLF / trailing newline                  [★★★ TESTED] lint job
├─ root/default behavior (HOME, UV_HOME)    [★★★ TESTED] new regression asserts
├─ staging build + digest                   [★★★ TESTED] build guard
├─ amd64 verify-before-publish              [★★★ TESTED] smoke before promote
├─ arm64 QEMU smoke + arch assertion        [★★★ TESTED] planned
├─ promote all tags                         [★★★ TESTED] digest equality
├─ smoke-fail blocks promotion              [★★★ TESTED] drill=fail-smoke
├─ repeat promotion idempotency             [★★★ TESTED] drill=repeat-promote
├─ weekly APT_CACHE_BUST                    [★★★ TESTED] baked run-id assertion
├─ schedule vs push concurrency             [GAP]        serialized by design
├─ lint (shellcheck/hadolint/actionlint)    [★★★ TESTED] new lint job
├─ dx-smoke non-root + UID                  [★★★ TESTED] new script
├─ pruner retention/pagination/auth         [GAP]        unchanged; TODO
└─ size/TTHW metrics                        [→EVAL]      warn-only, no gate

USER FLOWS
├─ pull latest → run bash                   [→E2E]       CI smoke on built image
├─ non-root bind mount → git/cargo/uv       [★★★ TESTED] dx-smoke
├─ pull promoted tag → digest pin           [★★★ TESTED] post-promote digest check
└─ weekly tag upgrade                       [→EVAL]      changelog review

COVERAGE: 19/26 automated (73%); critical gaps: pruner harness only.
QUALITY: ★★★ happy + failure paths for the release gate; pruner is ★.
```

Test requirements added to the plan: the two drills, digest equality, arch
assertion, baked cache-bust value, root/default regression, CRLF/trailing-newline
lint, and non-root UID ownership. The pruner integration harness is deferred with
a named trigger. Regression contract: existing `latest`/`main`/`v<toolchain>`
pullability and the image's default root behavior are asserted, not assumed.

Test plan artifact:
`~/.gstack/projects/kevo-tz-rust_python_node/cevor-main-eng-review-test-plan-20261027-*.md`

#### 4. Performance review

Issues found: 3.

1. **P2 - cache-bust cost.** Re-running the final apt layer re-runs
   `apt-get update/upgrade/install` on both architectures. Estimate +5-12 min
   for the schedule (arm64 under QEMU is the tail), plus 3-6 min for the arm
   smoke. Cold push ~20-27 min; schedule ~25-40 min. The 90-minute timeout is
   adequate. Moving rustup before the apt layer removes its re-run; the TODO
   trigger for native arm runners is raised to "two consecutive weekly runs over
   45 minutes".
2. **P3 - size.** +89 MB installed in the final layer; image ~1.95 GB -> ~2.04 GB
   uncompressed, compressed ~498 MB -> ~530-540 MB (under the 600 MB warn).
   Layer order keeps the uv and Node copy layers cached; the new packages do not
   invalidate the base Rust install.
3. **P2 - metric methodology.** `docker image inspect` reports uncompressed size
   and a pull on the build runner is warm. Sum compressed layer sizes from the
   registry manifest and time a pull after removing the local image; label it
   runner-measured and keep it warn-only.

No N+1/database concerns. No additional cache opportunity beyond the rustup
split; the weekly GHA cache gains one final layer per run, well under the 10 GB
budget for the foreseeable future.

ENG DUAL VOICES - CONSENSUS TABLE:

```
  Dimension                         in-host subagent       Codex   Consensus
  1. Architecture sound?            no (P0 node copy,      N/A     N/A
                                    promotion safety)
  2. Failure paths covered?         partial (gaps listed)  N/A     N/A
  3. Tests prove the gate?          partial (drills added) N/A     N/A
  4. Performance acceptable?        yes (90 min adequate)  N/A     N/A
  5. Behavior compatibility?        yes with assertions   N/A     N/A
  6. Shared-code opportunity?       none justified         N/A     N/A
CONFIRMED = native + outside; outside unavailable (codex not installed).
```

Eng completion summary:

```
  +====================================================================+
  |              ENG PLAN REVIEW — COMPLETION SUMMARY                  |
  +====================================================================+
  | Mode selected        | HOLD SCOPE                                  |
  | Scope Challenge      | 7 files, 0 services; B skipped; 10 findings |
  | Section 1 (Arch)     | 4 issues (1 P0, 2 P1, 1 P2)                 |
  | Section 2 (Quality)  | 5 issues (2 P1, 3 P2)                       |
  | Section 3 (Tests)    | diagram produced; 7 new checks; 1 gap kept  |
  | Section 4 (Perf)     | 3 issues (2 P2, 1 P3)                       |
  | NOT in scope         | written (4 items)                           |
  | What already exists  | metadata-action, buildx, pruner, QEMU       |
  | Failure modes        | 1 critical gap (pruner), else covered       |
  | Unresolved decisions | 0 in this phase                             |
  | Outside voice        | codex unavailable (not installed)           |
  | Parallelization      | 1 lane, sequential                          |
  | Lake Score           | N/A (no scored coverage choices)            |
  +====================================================================+
```

Failure modes for the new paths:

```
  PATH                    | FAILURE MODE              | RESCUED? | TEST? | USER SEES
  ------------------------|---------------------------|----------|-------|-----------
  staging build           | build fails               | Y        | Y     | old tags
  amd64 smoke             | tool/header missing       | Y        | Y     | failed CI
  arm64 smoke             | wrong arch / QEMU crash   | Y        | Y     | failed CI
  promotion (partial)     | some tags moved           | Y (retry)| Y     | old latest,
                          |                           |          |       | new main
  promotion (auth)        | 401/403                   | N        | N     | failed CI,
                          |                           |          |       | old latest
  schedule cache-bust     | layer still cached        | Y        | Y     | old patches
  pruner                  | retention/pagination bug  | N <- GAP | N     | extra tags
  staging tag             | consumer pulls it         | N        | N     | unsupported
```

The only critical gap is the pruner: it is silent by design (`continue-on-error`)
and untested. Promotion auth failures fail the run loudly and leave `latest`
last; the pruner is unchanged and its harness is a TODO. The staging tag is
explicitly unsupported in the README.

What already exists (reuse, not rebuild):

- `docker/metadata-action` already computes `latest`, `main`, `rpn-*`, `sha-*`
  and the toolchain tag; the plan reuses that list.
- `docker/buildx imagetools` already provides digest-addressed tag creation; the
  plan adds verification, not a new promotion service.
- The pruner already handles Docker Hub auth, pagination and retention; it is
  reused unchanged.
- QEMU setup is already in the workflow; arm64 execution is added, not a new
  runner.
- The existing login-shell PATH fix and non-root recipe are retained.

NOT in scope (deferred):

- Native arm64 runners: separate job matrix; the QEMU smoke is the gate for now.
- Pruner integration harness: unchanged code, separate mock-registry harness.
- Promotion atomicity primitive: the registry has none; retry + digest check and
  a TODO cover the residual.
- Hard TTHW/size gates: runner timing is noisy; warn-only metrics.
- `cmake` and devcontainer: additive, independent.

Worktree parallelization: **Sequential implementation, no parallelization
opportunity.** The Dockerfile, workflow, scripts and README are one delivery
unit; splitting them would create overlapping edits to the same workflow.

Implementation tasks:

- [x] **T1 (P1, human: ~1h / CC: ~10min)** - Dockerfile - Keep `node-base`, add
  the native package set, LF/newline, WORKDIR, PATH, keep final upgrade.
  - Surfaced by: Code Quality 1-2 and Architecture 1.
  - Files: `Dockerfile`
  - Verify: `docker build -t rpn:test .`; `make`, `g++`, `pkg-config` resolve.
- [x] **T2 (P1, human: ~2h / CC: ~20min)** - Dockerfile - Add final-stage
  `APT_CACHE_BUST`, bake `/etc/rpn/apt-cache-bust`, move rustup before apt.
  - Surfaced by: Architecture 5 and Code Quality 1-3.
  - Files: `Dockerfile`
  - Verify: scheduled-style build with a non-zero arg bakes that value.
- [x] **T3 (P1, human: ~1h / CC: ~15min)** - Workflow - Build to
  `rpn-staging`, run amd64 + arm64 smoke, promote with digest verification,
  retry and `latest` last; publish `sha-*` only when absent.
  - Surfaced by: Architecture 2-3.
  - Files: `.github/workflows/build-push-action.yml`
  - Verify: `drill=fail-smoke` and `drill=repeat-promote`.
- [x] **T4 (P1, human: ~1h / CC: ~10min)** - Workflow - Expand smoke:
  OpenSSL C/C++ link, venv imports, tool loop, root/default regression, arm
  `uname -m`, cache-bust value.
  - Surfaced by: Test review.
  - Files: `.github/workflows/build-push-action.yml`
  - Verify: removing a package fails the smoke.
- [x] **T5 (P1, human: ~45min / CC: ~8min)** - Scripts - Add
  `scripts/dx-smoke.sh` (mktemp+trap, `-i`, UID ownership, stat fallback).
  - Surfaced by: DX obligations and Code Quality 4.
  - Files: `scripts/dx-smoke.sh`
  - Verify: run locally against `rpn-review:fixed`.
- [x] **T6 (P2, human: ~30min / CC: ~5min)** - CI - Add lint job
  (shellcheck both globs, hadolint, actionlint, CRLF/newline) and
  `.hadolint.yaml`.
  - Surfaced by: Code Quality 4 and tests.
  - Files: `.github/workflows/build-push-action.yml`, `.hadolint.yaml`
  - Verify: `shellcheck`/`hadolint`/`actionlint` green.
- [x] **T7 (P2, human: ~30min / CC: ~5min)** - Workflow - Permissions, 90-min
  timeout, PR-only QEMU, PR-only cancel-in-progress.
  - Surfaced by: Architecture 4.
  - Files: `.github/workflows/build-push-action.yml`
  - Verify: workflow lint + a queued push/schedule run.
- [x] **T8 (P2, human: ~1h / CC: ~10min)** - Docs - README, CHANGELOG, TODOS.
  - Surfaced by: DX obligations and Eng decisions.
  - Files: `README.md`, `CHANGELOG.md`, `TODOS.md`
  - Verify: README quickstart command matches dx-smoke.

Effort ratios: docs ~50x, CI ~30x, Dockerfile feature ~30x, bug-fix-with-drill
~20x, per the default task-type ratios, adjusted for shell/YAML work.

<!-- autoplan-accepted:eng -->
- Pre-smoke publication uses the internal `rpn-staging` tag only; no release
  tag moves before amd64 and arm64 smoke pass.
- `sha-*` is promoted after smoke and only if absent; schedules, dispatches and
  re-runs never overwrite it.
- Promotion verifies every tag's digest against the built digest, retries three
  times, and orders `latest` last.
- `APT_CACHE_BUST` is declared in the final stage, baked into
  `/etc/rpn/apt-cache-bust`, and asserted by smoke; the final `apt-get upgrade`
  stays.
- Concurrency cancels PRs only; pushes and schedules queue.
- arm64 smoke asserts `uname -m` and builds/runs a hello-world crate.
- `scripts/dx-smoke.sh` uses `-i`, `mktemp`+trap, a bash tool loop and a
  portable stat fallback; it is included in the shellcheck glob.
- Manual drills `fail-smoke` and `repeat-promote` prove the gate and
  idempotency.
- Root/default behavior is asserted, not assumed.
<!-- /autoplan-accepted:eng -->

<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|-----------|-----------|----------|----------|
| 1 | CEO | Add verify-before-publish (build sha tag, smoke, promote) | User Challenge | P1 completeness | Pipeline currently ships `latest` before any test | Original push-then-test order |
| 2 | CEO | Add weekly APT_CACHE_BUST | User Challenge | P1 completeness | 25/25 scheduled runs are 1-minute cache hits; README claim is false | Leaving the weekly job as-is |
| 3 | CEO | Cut `.dockerignore` | Mechanical | P3 pragmatic | No build-context COPY; zero effect | Adding an inert file |
| 4 | CEO | Cut README drift checker | Mechanical | P5 explicit | Premise false: both files changed together; build already catches bad CPython | Second source of truth |
| 5 | CEO | Keep `DEBIAN_FRONTEND` and `UV_HOME` env vars | Taste | P3 pragmatic | Removing them can break derived images for no user gain | Scoping them to build only |
| 6 | CEO | Defer native arm64 runners | Taste | P3 pragmatic | Needs a separate job matrix; same-PR risk too high | Two-arch matrix in this PR |
| 7 | CEO | Include `zlib1g-dev` | Mechanical | P1 completeness | ~1 MB; common `-sys` crates | Waiting for a bug report |
| 8 | CEO | Keep TODOS.md | Mechanical | P3 pragmatic | Pipeline requires a durable deferral record | GitHub issues only |
| 9 | Eng | Keep `node-base`, remove only its dead upgrade | Mechanical | P1 explicit | `COPY --from` cannot expand `$NODE_VERSION`; build fails otherwise (verified) | Direct `COPY --from=node:${NODE_VERSION}` |
| 10 | Eng | Replace sha-only pre-push with `rpn-staging` | User Challenge | P1 completeness | Schedule reuses `github.sha`, so sha tags are overwritten weekly with unverified bytes | Keeping the CEO mechanism as written |
| 11 | Eng | Promote `sha-*` after smoke, only if absent | User Challenge | P1 completeness | Makes sha immutable and verified; first verified build wins | Overwriting sha on schedule/re-run |
| 12 | Eng | Digest-verify promotion, retry 3x, `latest` last | User Challenge | P1 completeness | `imagetools create` is sequential; no registry multi-tag transaction exists | Fire-and-forget promotion |
| 13 | Eng | Keep the final-stage `apt-get upgrade` | Mechanical | P1 explicit | It is the patch mechanism the weekly cache-bust exists to rerun | Removing every upgrade |
| 14 | Eng | Declare `APT_CACHE_BUST` in the final stage and bake it | Mechanical | P5 explicit | A global ARG is invisible in the stage (verified); log-only acceptance is weak | Relying on a build log line |
| 15 | Eng | Move `rustup component add` before the cache-busted apt layer | Taste | P3 pragmatic | Avoids re-running rustup on every weekly rebuild | One monolithic RUN |
| 16 | Eng | Cancel PRs only; queue pushes and schedules | Taste | P3 pragmatic | Prevents cancelling a weekly rebuild mid-apt or a promotion mid-tag | Cancel every run in the ref group |
| 17 | Eng | arm64 smoke asserts `uname -m` and builds a crate | Mechanical | P1 completeness | A `--version` check can silently test the amd64 image | Reduced smoke without an arch assertion |
| 18 | Eng | dx-smoke: `-i`, mktemp+trap, stat fallback, lint glob | Mechanical | P3 pragmatic | CI has no TTY; `-it` fails; `stat -c` is GNU-only; new script would be unlinted | Leaving the script outside the lint glob |
| 19 | Eng | Add `fail-smoke` and `repeat-promote` drills | User Challenge | P1 completeness | The gate and idempotency were only manual acceptance claims | Trusting the happy path |
| 20 | Eng | Defer the pruner integration harness | Taste | P3 pragmatic | Pruner is unchanged; a mock Hub API is a separate harness with no current bug | Building a mock registry in this change |
| 21 | Eng | Measure compressed size from the registry manifest | Mechanical | P5 explicit | `docker image inspect` is uncompressed; a runner pull is warm | Reporting uncompressed size |
| 22 | Eng | Assert root/default behavior in smoke | Mechanical | P1 explicit | The plan claims compatibility; assertions make it regression-proof | Assuming unchanged defaults |

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | issues_open (mapped) | 3 cut, 2 P1 added, 2 critical paths fixed |
| Outside Review | codex (unavailable) | Independent 2nd opinion | 0 | unavailable | none (CLI not installed) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open (mapped) | 12 issues + 7 test gaps; 1 deferred gap |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | skipped | no UI scope |
| DX Review | `/plan-devex-review` | Developer experience gaps | 1 | issues_open (mapped) | 5/10 (from 3/10); TTHW 5-7 min |

- **OUTSIDE COVERAGE:** codex, all phases, unavailable (CLI not installed). No
  completed external review; all consensus cells are N/A, never CONFIRMED.
- **CROSS-MODEL:** not available; no completed outside review.
- **VERDICT:** CEO + DX + ENG COMPLETED — all findings are mapped into the plan
  or TODOS; 1 deferred gap (pruner harness); ready for the final approval gate.

NO UNRESOLVED DECISIONS
