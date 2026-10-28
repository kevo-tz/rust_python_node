# TODOS

Deferred work with the trigger that would promote it into a planned change.

- [ ] Native arm64 runners (`ubuntu-24.04-arm`) instead of QEMU. Trigger: two
      consecutive weekly builds exceed 45 minutes after the cache-bust lands.
- [ ] Renovate regex managers for the four Dockerfile `ARG`s. Trigger: the bump
      commit loop stays manual for another month (132 of 178 commits are bumps).
- [ ] A non-root `dev` user baked into the image. Trigger: a team adopts the
      image, or the documented `--user` recipe proves insufficient in reports.
- [ ] Pruner integration test against a mocked Docker Hub API (retention,
      pagination, auth failure, `KEEP=0`). Trigger: first prune bug or retention
      report. Shellcheck covers syntax now.
- [ ] Promotion atomicity across tags. Trigger: the first partial promotion
      despite the retry/digest check. The registry has no multi-tag transaction
      primitive.
- [ ] GitHub Releases automation keyed to `sha-*` and toolchain tags. Trigger:
      the CHANGELOG has three or more entries.
- [ ] Sync the Docker Hub full description from the README. Trigger: the next
      manual Docker Hub visit (the current text describes a different project).
- [ ] Hard TTHW and compressed-size gates in CI. Trigger: the warn-only metrics
      show stable runner timing.
- [ ] SBOM and maximum provenance attestations. Trigger: a consumer asks for
      attestations.
- [ ] Verify the uv installer script itself (currently fetched and executed over
      TLS; the binary checksums are embedded in that script). Trigger: a
      supply-chain review.
