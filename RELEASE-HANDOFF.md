# Consumer handoff: Rauthy 0.36.2-patched.1

For the session that adopts this build in `rahi`. The decisions and the evidence behind them are in
`RELEASE-LEDGER.md`; this file is what a consumer needs to act.

> **Publication is held.** The image and the GitHub release do not exist yet, because the patched
> Hiqlite packages this release must resolve are not published. Section "What is still missing"
> says exactly what unblocks it. Everything below is final except the concrete artefact values,
> which no one can write down before a publish run produces them: pin from the
> `RELEASE-PROVENANCE.md` that run attaches, never from this file.

## What this is

A downstream patched build of upstream Rauthy `v0.36.2`, the release `rahi` already runs. It is
**not an upstream release**, is not endorsed by or supported by the upstream project, and carries
upstream's licence and authorship unchanged.

| | |
|---|---|
| Version | `0.36.2-patched.1` |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Source | https://github.com/bartekus/rauthy |
| Release branch | `release/0.36.2-patched.1` on release line `patched/0.36.2` |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1` |
| Binary path in image | `/app/rauthy`, executable named `rauthy` |
| Supported topology | N = 1 |

## Artefacts

These values do not exist until something is published, so they are not written down here by hand.
The publish run generates `RELEASE-PROVENANCE.md` from what it actually published and attaches it
to the GitHub release, carrying:

- the tag, the source commit, and the upstream base;
- the image index digest and every per-platform manifest digest;
- the sha256 of each binary;
- every resolved Hiqlite package with its version, registry source and checksum;
- the toolchain, the publish run, and the candidate run whose bytes were promoted.

Pin from that file, not from this one. The tag will be `v0.36.2-patched.1` and the image
`ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1`, pinned by the index digest recorded there.

## Hiqlite packages

The release will resolve `hiqlite-patched`, `hiqlite-wal-patched` and `hiqlite-derive-patched`
from crates.io, at versions selected when they are published, with their checksums recorded in
`RELEASE-PROVENANCE.md`. The publish workflow refuses to run at all if any package matching
`hiqlite*` resolves to anything but a registry, so a path dependency, a git branch or an inherited
`[patch.crates-io]` override cannot reach a release by accident.

The candidate as it stands resolves upstream `hiqlite 0.14.0` from crates.io
(`8711815c093414290a5fcbc0bf74e1e70e3d6ef37e21735000178d25cee6fcf0`) and its two siblings. That is
the provisional graph, not the release graph.

## Pin updates for rahi

Two files must carry the identical pin; `image.yml` fails the build when they drift. `live.yml`
only requires a `@sha256:` pin, so the namespace change passes its gate unchanged.

`docker/Dockerfile:12` and `docker/runtime.Dockerfile:22`, both currently:

```dockerfile
ARG RAUTHY_IMAGE=ghcr.io/sebadob/rauthy:0.36.2@sha256:f7d3c501402165e023edbd958b032b41c9cfdac5ea7f8ca7d62217327145577e
```

become, with the index digest from the table above:

```dockerfile
ARG RAUTHY_IMAGE=ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1@sha256:<index-digest>
```

The comment above the line in `docker/Dockerfile` says "rauthy 0.36.2, pinned by the digest of its
multi-architecture index"; update it to name the patched build and its upstream base.

Nothing else in `rahi` changes. `RAHI_RAUTHY_BIN` stays `/usr/local/bin/rauthy`, the `COPY --from=rauthy
/app/rauthy` line is unchanged, and `rauthy --version` still prints a parseable SemVer
(`rauthy 0.36.2-patched.1`).

## Configuration and migration

Nothing to do. No schema change, no migration, no renamed or removed config value, and no new
required value. The upgrade is in place on the existing data directory: stop, swap the image,
start.

One behaviour change worth knowing: a config file that cannot be read now fails the start instead
of being silently replaced by an empty config. An absent file at the default `./config.toml` is
still only a warning, so an environment-variable-only deployment is unaffected.

The build stamps `0.36.2-patched.1` into the `config` table's `db_version` row.

## Backup, restore and downgrade

- **Backup.** `POST /auth/v1/backup`, `GET /auth/v1/backup`, `GET /auth/v1/backup/local/{name}`
  behave as before, except that a download which cannot be completed now fails instead of ending
  early under a `200`. `rahi`'s `RauthyApi::fetch` checks only the status and a non-empty body, so
  before this fix a truncated snapshot would have been sealed into an archive. No `rahi` change is
  needed to benefit: the failed read surfaces through `reqwest` as a transport error.
- **Two hiqlite contracts your backup verb depends on, unchanged here but worth naming.** `rahi`
  parses the unix timestamp out of the snapshot file name (`backup_node_<id>_<seconds>.sqlite`) to
  decide which snapshot its own trigger produced, and it models a suppression window during which
  hiqlite ignores a fresh backup request. Both belong to hiqlite, not to rauthy, and neither is
  touched by this release: snapshots still arrive as `backup_node_1_<seconds>.sqlite`. They are
  exactly the kind of thing a Hiqlite package swap could change silently, so re-check them when
  this release moves onto the patched packages.
- **Restore.** Unchanged: hiqlite's `HQL_BACKUP_RESTORE` into a fresh data directory. The restored
  instance keeps the original signing keys, so tokens and sessions issued before the backup stay
  verifiable. A truncated or missing restore input is refused and the last recoverable state is
  left intact.
- **Rollback.** Upstream `ghcr.io/sebadob/rauthy:0.36.2` starts again on a data directory this
  build has written. Nothing below `v0.36.2` is supported.
- **The ownership lock is not the consumer's to move, and it is not moved.** Checked while tracing
  this: `rahi`'s restore probes `rauthy/state_machine/lock` for existence and nothing else, and
  the paths it resets (`APP_RESET_PATHS`) are its own node's, not rauthy's. Worth knowing that this
  file is an existence marker rather than an OS lock, so it survives an ungraceful exit: a restore
  gated on it refuses after a crash as well as while rauthy runs. That is the conservative
  direction, so no change was made anywhere. The real ownership lock, the one that stops a second
  process, is the `flock` on `logs/lock.hql`.
- **Not supported.** Running this build and any other Rauthy version in one raft cluster.

## Test results

All of the following ran in CI against the candidate's own artefacts.

| Leg | Result |
|---|---|
| Frontend check (`svelte-check`, warnings fatal) | pass |
| Style and unit checks (`cargo fmt --check`, `cargo clippy --workspace -D warnings`) | pass |
| Integration suite, Hiqlite backend | pass |
| Integration suite, Postgres backend | pass |
| Release binary, `linux/amd64` and `linux/arm64` | built, checksummed |
| Acceptance against the `linux/amd64` release binary | **0 failed, 0 skipped** |
| Acceptance against the `linux/arm64` release binary | **0 failed, 0 skipped** |
| Independent review | ran; one finding, fixed and covered by a new acceptance leg |

Both architectures get the same acceptance, on their own native runner, against the binary that
ships. That includes the upgrade and rollback legs, which run against the real upstream `v0.36.2`
binary taken out of `ghcr.io/sebadob/rauthy:0.36.2` rather than a rebuild of it, and the
storage-failure leg, which takes a real database away from a running instance.

Measured, not assumed: both binaries require at most `GLIBC_2.34`, and `debian:bookworm-slim`
provides 2.36. The consumer's own pattern was exercised directly - the image built from these
binaries, `/app/rauthy` copied out of it into `debian:bookworm-slim` exactly as `docker/Dockerfile`
does, and the result runs and reports `rauthy 0.36.2-patched.1`. That was done in an isolated
workspace; the `rahi` checkout was not touched, and it is not a statement about published `rahi`
compatibility.

Skipped and why: passkey-only backup administrator with MFA (a consumer-side configuration this
release does not change; no rauthy change was made for it); terminal Hiqlite storage failure
injected from outside the process (no external injection point - the Postgres equivalent is
covered); N = 3 (not attempted, not claimed); bit-for-bit reproducibility (not claimed;
`BUILD_TIME` is stamped from the wall clock).

## Fixes in this build

`RELEASE-LEDGER.md` section 3 has the full reasoning.

1. Backup downloads fail instead of truncating silently.
2. The storage layer is shut down on every exit path after it starts, including a listener that
   cannot bind.
3. `/auth/v1/ready` answers `503` when storage is confirmed unreachable.
4. An unreadable config file fails the start and names itself.
5. A metrics listener that cannot start is now an error rather than a process abort, so it does
   not cost the next start its state machine either. Found by the independent review.
6. A shared-state defect in upstream's own client handler test.

And one coverage gap closed without a product change: the device grant (RFC 8628) had no test in
rauthy's own suite, although `rahi` drives it for native clients. `test_device_code_flow` now
covers it end to end on both backends, including a poll before approval and an unknown device
code. The flow itself needed no fix.

## Unresolved limitations

- Qualified at N = 1 only.
- A terminal Hiqlite storage failure is observable only through the health watcher's periodic
  sample, so `/ready` turns over within roughly one to two minutes rather than immediately.
- Config errors abort the process rather than exiting cleanly. That is upstream's established
  mechanism throughout the config layer; the messages are actionable, but a supervisor sees an
  abort, not a clean non-zero exit. Changing it is a repo-wide refactor this release did not take
  on.

## What is still missing

**Package visibility may need one owner action.** A GHCR package pushed by a workflow token is
private by default, and a private package is not consumable however correct the release is. The
publish run checks this the way an outside consumer would, with an anonymous pull token and no
credentials, and says in its job summary whether the image is publicly pullable. If it is not, the
remaining step is:

> https://github.com/users/bartekus/packages/container/rauthy-patched/settings
> -> Change package visibility -> Public

No workflow token can do that. Until it is done, do not treat the image as consumable.

**The patched Hiqlite packages.** `hiqlite-patched`, `hiqlite-wal-patched` and
`hiqlite-derive-patched` do not exist on crates.io, and `bartekus/hiqlite` has no tags or releases.
The release must resolve published registry packages, so it cannot be published until they are.

When they land: swap the three dependencies to the aliased patched packages in `Cargo.toml`,
confirm through `cargo tree`/`cargo metadata` that no upstream copy remains in the graph, re-run
`release-candidate.yaml` in full, and publish from that run. Section 7 of the ledger has the exact
shape.

## Explicitly outside this release

- `rahi` must adopt and publish the new image pin and its own dependency configuration. Publishing
  rauthy does not do that.
- `rahi`'s application-side Hiqlite dependency is a separate thing from the copy embedded in
  rauthy. Adopting this image does not change it.
- Aicortex and Statecraft need their own governed dependency adoption and acceptance.
- Statecraft's object-store writer fencing is not addressed here.
- Local `statecraft-cli` functionality does not depend on this release.
- Nothing here is deployed. Production deployment is not part of this work.
