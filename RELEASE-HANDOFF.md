# Consumer handoff: Rauthy 0.36.2-patched.1

For the session that adopts this build in `rahi`. The evidence is in `RELEASE-LEDGER.md`; this file
is what a consumer needs to act.

> **Pin from the release's `RELEASE-PROVENANCE.md`, never from this file.** This copy is the one
> in the tagged tree, written before the publish run produced the artefacts. Everything below is
> final except those values: the image digests, the binary checksums and the run links. The copy
> on `patched/0.36.2` records them once the release exists.

## What this is

A downstream patched build of upstream Rauthy `v0.36.2`, the release `rahi` already runs, on the
patched Hiqlite `0.15.0-patched.1`. It is **not an upstream release**, is not endorsed or
supported by the upstream project, and carries upstream's licence and authorship unchanged.

| | |
|---|---|
| Version | `0.36.2-patched.1` |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Source | https://github.com/bartekus/rauthy, release line `patched/0.36.2` |
| Tag | `v0.36.2-patched.1` (created by the publish run) |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1` |
| Binary path in image | `/app/rauthy`, executable named `rauthy`, `LICENSE` beside it |
| Supported topology | N = 1 |

## Artefacts

The publish run writes `RELEASE-PROVENANCE.md` from what it actually published and attaches it to
the release: the tag, source commit and upstream base; the reviewed pull request and review run;
the image index digest and every per-platform manifest digest; the sha256 of each binary; the
resolved Hiqlite packages with version, registry and checksum; the `Cargo.lock` hash, toolchain,
publish run and the candidate run whose bytes were promoted. Pin from that file.

## Pin updates for rahi

Two files must carry the identical pin; `image.yml` fails the build when they drift. `live.yml`
only requires a `@sha256:` pin, so the namespace change passes its gate unchanged.

`docker/Dockerfile:12` and `docker/runtime.Dockerfile:22`, both currently:

```dockerfile
ARG RAUTHY_IMAGE=ghcr.io/sebadob/rauthy:0.36.2@sha256:f7d3c501402165e023edbd958b032b41c9cfdac5ea7f8ca7d62217327145577e
```

become, with the index digest from `RELEASE-PROVENANCE.md`:

```dockerfile
ARG RAUTHY_IMAGE=ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1@sha256:<index-digest>
```

Update the comment above the line in `docker/Dockerfile` ("rauthy 0.36.2, pinned by the digest of
its multi-architecture index") to name the patched build and its upstream base.

Unchanged: `RAHI_RAUTHY_BIN` stays `/usr/local/bin/rauthy`, the `COPY --from=rauthy /app/rauthy`
line stays, and `rauthy --version` prints a parseable SemVer (`rauthy 0.36.2-patched.1`).

## The one required operational change: the first start after the upgrade

The patched Hiqlite cannot read the cache raft log upstream `v0.36.2` wrote (the cache command
layout changed after `hiqlite 0.14.0`), and it refuses rather than guess. The upgrade is:

1. Stop rauthy.
2. Swap the image.
3. Start **once** with `HQL_CACHE_LEGACY_MOVE_ASIDE=true`.
4. Remove the variable; later starts run without it.

Step 3 moves `logs_cache` and `state_machine_cache` into
`<data_dir>/pre-upgrade-<unix seconds>/` (nothing is deleted) and starts with an empty cache.
Without it the start exits `1` with a message naming the variable and ending "Nothing was
changed."; that is the designed refusal, not a crash, and nothing on disk has moved.

**Effect on rahi:** sessions survive (Rauthy keeps them in its database). In-flight authorization
codes, device codes, WebAuthn challenges, rate-limit counters and blacklist entries do not, which a
restart window already tolerates. Rahi's restore probes `rauthy/state_machine/lock` for existence;
the upgrade does not change that file's meaning. If rahi's cell supervisor starts rauthy with a
fixed environment, the variable has to reach that one start: set it for the upgrade boot only, or
leave it set if your supervisor cannot scope it; it is a no-op once the marker exists, and any
value other than `true`/`false` is a startup error.

## Configuration and migration

Otherwise nothing: no schema change, no migration, no renamed, removed or newly required value. A
config file that cannot be read now fails the start, except an absent default `./config.toml`, so
an environment-only deployment is unaffected. The build stamps `0.36.2-patched.1` into the
`config` table's `db_version` row.

## Caller-visible behaviour changes

- `/auth/v1/ready` answers `503` when storage is confirmed unreachable, and **immediately** after a
  terminal storage failure on the embedded node. Rahi's own readiness gating benefits without
  change.
- A node whose storage has failed terminally refuses every request that touches storage (500 with
  "The storage layer of this node is out of service"), stays up, and **is not restarted by
  Rauthy or Hiqlite**. Restarting the process is the recovery path; rahi's supervisor should treat
  a persistent `503` from `/ready` as "restart this cell".
- Backup downloads that cannot be completed fail instead of ending early under a `200`, and the
  local route declares `Content-Length`. `RauthyApi::fetch` sees a transport error through
  `reqwest`; no rahi change is needed.
- A second process on the same data directory, including a restore aimed at a live node's
  directory, is refused with `StorageInUse` before anything is touched.
- Startup and background failures after the storage layer is live exit `1` after a storage
  shutdown, where upstream aborted with `134` and the next start rebuilt the state machine:
  a listener or metrics port that cannot bind, unusable TLS material, a `PUB_URL` host that
  cannot name a self-signed certificate, an incomplete SMTP configuration or an unparsable
  `SMTP_FROM`, and exhausted SMTP connection retries (which upstream also ended, with `134`, after
  its own shutdown). A supervisor that restarts on any non-zero exit sees no difference; one that
  inspects the code sees `1`.

## Backup, restore and downgrade

- **Backup.** `POST /auth/v1/backup`, `GET /auth/v1/backup`, `GET /auth/v1/backup/local/{name}` as
  before. The snapshot name `backup_node_<id>_<seconds>.sqlite` that rahi parses and the 60 s
  window in which Hiqlite ignores a repeated backup request are unchanged (source, and acceptance G
  for the name). Retention now never deletes the newest backup.
- **Restore.** `HQL_BACKUP_RESTORE` into a fresh data directory, as before. The restore stages the
  image before replacing anything, validates it (`quick_check`, metadata decodes), and an
  interrupted restore is rolled forward at the next start. The restored instance keeps the
  original signing keys. N = 1 only.
- **Downgrade to upstream `ghcr.io/sebadob/rauthy:0.36.2`.** Stop, move `logs_cache` and
  `state_machine_cache` out of the data directory **by hand**, start upstream. Upstream has no way
  to refuse a cache log it cannot read, so skipping the move is unsafe. The database and
  everything the patched build wrote are readable by upstream. Nothing below `v0.36.2` is
  supported.

## Test results

The qualifying run is the candidate run on the merge commit, against the published Hiqlite; the
release's `RELEASE-PROVENANCE.md` names it, and the publish gate refuses anything else. Earlier
results in ledger section 6 are history: some ran against a git-sourced Hiqlite, and the last one
on the registry graph ran on a tree that has since changed. What the qualifying run covers, on
native amd64 and arm64, strict (a skip fails it):

- both integration suites (Hiqlite and Postgres backends);
- the process-level legs A to S, including the self-signed certificate and mail exit paths (M3,
  S), a real embedded-storage failure (P), a real Postgres failure (K), a kill under write load
  (Q), a restore aimed at an owned directory (R), and the upgrade and rollback against the real upstream `v0.36.2` binary from its own image (J);
- rahi's own whole live suite at `b815b18c`, with `RAHI_REQUIRE_RAUTHY=1`, against an image built
  from the candidate bytes, which includes rahi's passkey-only backup administrator proof. amd64
  only. It was run in CI from a pinned checkout of the public repository; the rahi working copy was
  not touched, and this is not a statement that a rahi release has adopted anything.

## Unresolved limitations

- Qualified at N = 1 only.
- Hiqlite snapshot readability across the upgrade and the rollback rests on source, because no
  snapshot existed during either check.
- `panic = "abort"` is workspace-wide; the per-request surface is spot-checked, not audited.
- Config errors abort the process before storage starts.
- Upstream's lost update on the user row (a login concurrent with a profile-picture upload can drop
  the picture) is present and not changed.

## What is still missing

**Possibly one owner action:** if the GHCR package is private after the first push,
https://github.com/users/bartekus/packages/container/rauthy-patched/settings -> Change package
visibility -> Public. The publish run checks anonymously and says so. Nothing else outside this
repository blocks publication.

## Explicitly outside this release

- `rahi` must adopt and publish the new image pin and the one-time upgrade variable. Publishing
  rauthy does not do that.
- `rahi`'s application-side Hiqlite dependency is a separate dependency path from the copy embedded
  in rauthy. Adopting this image does not change it. Carrying the patched Hiqlite there means
  changing `rahi-store`'s manifest to the aliased declaration (`hiqlite = { package =
  "hiqlite-patched", version = "=0.15.0-patched.1", default-features = false, features = [...] }`),
  removing the workspace's `[patch.crates-io]` entry, and publishing a new `rahi-store` and `rahi`,
  as the Hiqlite handoff's section 10 sets out. Its disk-backed cache needs the same one-time
  `HQL_CACHE_LEGACY_MOVE_ASIDE=true` start, and its `dlock` is a lease, not a fence (Hiqlite
  F-026).
- Aicortex and Statecraft need their own dependency adoption and acceptance.
- Statecraft's object-store writer fencing is not addressed by this release.
- Nothing here is deployed. This is not a production deployment.
