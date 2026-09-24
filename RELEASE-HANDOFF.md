# Consumer handoff: Rauthy 0.36.2-patched.3

For the session that adopts this build in `rahi`. The evidence is in `RELEASE-LEDGER.md` (section
12 for this release); this file is what a consumer needs to act. Pin from the release's own
`RELEASE-PROVENANCE.md`, which the publish run writes from what it actually published.

> **Never pin `0.36.2-patched.1`.** An image with that tag exists in the registry from a publish
> run whose arm64 verification failed on a harness defect; it was never released and has no
> provenance. The ledger's section 7 has the account.

## What this is

A downstream patched build of upstream Rauthy `v0.36.2`, the release `rahi` already runs, on the
patched Hiqlite `0.15.0-patched.2`. It is **not an upstream release**, is not endorsed or
supported by the upstream project, and carries upstream's licence and authorship unchanged.

| | |
|---|---|
| Version | `0.36.2-patched.3` |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Previous patched release | `v0.36.2-patched.2`, tag at `17132b9451912cf45d33c99990f21678b75e2e26` |
| Source | https://github.com/bartekus/rauthy, release line `patched/0.36.2` |
| Tag | `v0.36.2-patched.3` (created by the publish run) |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.3` |
| Binary path in image | `/app/rauthy`, executable named `rauthy`, `LICENSE` beside it |
| Hiqlite | `hiqlite-patched`, `hiqlite-wal-patched`, `hiqlite-derive-patched`, all `=0.15.0-patched.2` from crates.io |
| Supported topology | N = 1 |

## What changed since `0.36.2-patched.2`

1. **DPoP nonces are enforced.** With `DPOP_FORCE_NONCE=true` (the default), a DPoP proof is
   accepted only when its `nonce` is one this server issued and that has not expired. Before, any
   value was accepted. A client that echoes the `DPoP-Nonce` header it was given is unaffected; a
   client that sent anything else now receives the `400 use_dpop_nonce` challenge it should have
   received. The current nonce is also renewed once fewer than 15 s of it remain, so a client is
   never handed one that expires before its retry. The upstream project has been notified
   privately.
2. **`GET /auth/v1/health` reports `storage`**: `ok`, `degraded`, `terminal` or `unknown`.
   `terminal` means the embedded Hiqlite node has failed permanently and only a restart recovers
   it; it is read from Hiqlite's own record, which is set once and never cleared. `degraded`
   means a storage layer failed this request's check with nothing terminal recorded (an
   unreachable Postgres is always `degraded`). `unknown` is answered inside
   `HEALTH_CHECK_DELAY_SECS`, where nothing is checked. `ok` means both layers answered. The
   existing `db_healthy` and `cache_healthy` fields and the status codes are unchanged, except
   that a terminal node now answers `500` inside the startup window too, where it answered `200`.
   The body carries only the enum. `/ready` is unchanged.
3. **The upgrade from upstream excludes a live node.** Built on Hiqlite `0.15.0-patched.2`, a start
   on a directory a live Hiqlite node of either version (upstream `0.14` or patched `0.15`) is
   using is refused with `StorageInUse`, naming that node's `lock.hql`, **before anything is
   renamed**, with or without `HQL_CACHE_LEGACY_MOVE_ASIDE`.
4. **The consent move is one resumable operation.** It works in `pre-upgrade-<secs>.partial/`
   until it completes. A start interrupted in the middle of it is refused without the variable and
   resumed with it; the half-finished state `0.36.2-patched.2` can leave is refused and finished,
   never restored.
5. **A refusal says what it created** (`hiqlite-owner.lock`, and the data directory if it was
   absent) instead of "Nothing was changed.". No data file is moved or written.
6. **WAL locks** are held from before the first write until the last one, and their files are
   removed at a clean stop.

## Status of the six corrections to `0.36.2-patched.2`

`RELEASE-CORRECTION-NOTICE-0.36.2-patched.2.md` corrected six statements in the previous handoff.
For this release:

| | subject | status in `0.36.2-patched.3` |
|---|---|---|
| C-1 | persistent `503` from `/ready` as a restart signal | **closed**: restart on `/health` `storage: "terminal"`; still never on `503` from `/ready` alone |
| C-2 | a live upstream node is not excluded | **closed**: change 3 above; qualified against the real upstream `v0.36.2` binary (leg J) |
| C-3 | the refusal is not side-effect free | **superseded**: change 5 above says exactly what it created |
| C-4 | going back to upstream | **stands**: downgrade is unsupported; see "Backup, restore and downgrade" |
| C-5 | an interrupted first start | **closed**: change 4 above; every interruption point resumed into one operation (leg J-F) |
| C-6 | the upgrade loses more than a restart | **stands**: see "Upgrading from upstream v0.36.2" |

## Pin updates for rahi

Two files must carry the identical pin; `image.yml` fails the build when they drift. `live.yml`
only requires a `@sha256:` pin.

`docker/Dockerfile:12` and `docker/runtime.Dockerfile:22` become:

```dockerfile
ARG RAUTHY_IMAGE=ghcr.io/bartekus/rauthy-patched:0.36.2-patched.3@sha256:<index digest from RELEASE-PROVENANCE.md>
```

Update the comment above the line in `docker/Dockerfile` to name the patched build and its
upstream base. `RAHI_RAUTHY_BIN` stays `/usr/local/bin/rauthy`, the `COPY --from=rauthy
/app/rauthy` line stays, and `rauthy --version` prints a parseable SemVer
(`rauthy 0.36.2-patched.3`).

## Upgrading from upstream v0.36.2

The patched Hiqlite cannot read the cache raft log upstream `v0.36.2` wrote (the cache command
layout changed after `hiqlite 0.14.0`), and it refuses rather than guess.

1. Stop upstream Rauthy and **archive the whole data directory**. This archive is the only
   supported way back.
2. Swap the image.
3. Start **once** with `HQL_CACHE_LEGACY_MOVE_ASIDE=true`.
4. Remove the variable after that start's first `200` from `/ready`.

Step 3 moves `logs_cache` and `state_machine_cache` into `<data_dir>/pre-upgrade-<unix seconds>/`
(nothing is deleted) and starts with an empty cache. Without the variable the start exits `1`
with a message naming the variable and the owner lock it created; that is the designed refusal,
not a crash. If an old node is still live on the directory, the start is refused before anything
is renamed; stop that node and start again. If step 3 is interrupted, start again with the
variable: the move resumes.

Scope the variable to the upgrade start. Left set, it is harmless on an already upgraded
directory (leg V), but it authorizes any later start to move a legacy cache it finds, such as a
restored upstream archive, without an operator's decision.

**What the upgrade loses:** a plain restart keeps the disk-backed cache (only the `Html` and `App`
caches are cleared); the upgrade empties it. That drops in-flight authorization and device codes,
WebAuthn and proof-of-work challenges, DPoP nonces, upstream-provider and ATProto login state, PAM
tokens, **every IP ban, manual ones included**, failed-login counters, credential-stuffing
windows, rate limits, and the grace entry that keeps a just-rotated client secret valid. The full
list, with the source function for each, is `RELEASE-STATE-INVENTORY.md`. Sessions, refresh tokens
and token revocations are in the database and are kept. Active IP bans can be carried across with
the existing API: `GET /auth/v1/blacklist` before the upgrade, then `POST /auth/v1/blacklist` with
the same address and expiry for each after it.

Rahi's restore probes `rauthy/state_machine/lock` for existence; the upgrade does not change that
file's meaning.

## Upgrading from 0.36.2-patched.2

Stop, swap the image, start. No variable is needed: the directory is already in the new cache
format, and nothing is moved again (leg V: keys, users, clients and rows written by upstream, by
`0.36.2-patched.2` and by this build survive, with and without the variable set). If a
`0.36.2-patched.2` upgrade start was interrupted and its directory never started since, start this
build once with `HQL_CACHE_LEGACY_MOVE_ASIDE=true`; it finishes that move.

## Configuration and migration

Otherwise nothing: no schema change, no migration, no renamed, removed or newly required value. A
config file that cannot be read fails the start, except an absent default `./config.toml`, so an
environment-only deployment is unaffected. The build stamps `0.36.2-patched.3` into the `config`
table's `db_version` row.

## Caller-visible behaviour, carried from 0.36.2-patched.2

- `/auth/v1/ready` answers `503` when storage is confirmed unreachable, and immediately after a
  terminal storage failure on the embedded node. It does not say which; `/health`'s `storage`
  does.
- A node whose storage has failed terminally refuses every request that touches storage (`500`
  with "The storage layer of this node is out of service"), stays up, and is not restarted by
  Rauthy or Hiqlite. Restarting the process is the recovery path, when `/health` reports
  `storage: "terminal"`.
- Backup downloads that cannot be completed fail instead of ending early under a `200`, and the
  local route declares `Content-Length`.
- A second process on the same data directory, including a restore aimed at a live node's
  directory, is refused with `StorageInUse` before anything is touched.
- Startup and background failures after the storage layer is live exit `1` after a storage
  shutdown, where upstream aborted with `134`: a listener or metrics port that cannot bind,
  unusable TLS material, a `PUB_URL` host that cannot name a self-signed certificate, an
  incomplete SMTP configuration or an unparsable `SMTP_FROM`, an unusable `PG_TLS_ROOT_CA`, and
  exhausted SMTP connection retries. Any other panic still exits `134`, but only after the
  storage layer has been shut down.

## Backup, restore and downgrade

- **Backup.** `POST /auth/v1/backup`, `GET /auth/v1/backup`, `GET /auth/v1/backup/local/{name}` as
  before. The snapshot name `backup_node_<id>_<seconds>.sqlite` that rahi parses and the 60 s
  window in which Hiqlite ignores a repeated backup request are unchanged. Retention never
  deletes the newest backup.
- **Restore.** `HQL_BACKUP_RESTORE` into a fresh data directory, as before. The restore stages the
  image before replacing anything, validates it, and an interrupted restore is rolled forward at
  the next start. The restored instance keeps the original signing keys. N = 1 only.
- **Downgrade is unsupported.** Starting upstream `v0.36.2`, or anything built on Hiqlite `0.14`,
  on a directory any patched build has written is not safe, with or without moving the cache by
  hand, and nothing makes such a binary refuse. To go back, restore the pre-upgrade archive from
  step 1 into a fresh volume and start upstream there; everything written after the upgrade is
  then lost. Going back from this release to `0.36.2-patched.2` on the same directory is not
  qualified either; keep an archive taken before this upgrade.

## Test results

The qualifying run is the candidate run on the merge commit, against the published Hiqlite; the
release's `RELEASE-PROVENANCE.md` names it, and the publish gate refuses anything else. What it
covers, on native amd64 and arm64, strict (a skip fails it):

- both integration suites (Hiqlite and Postgres backends), including the DPoP nonce cases;
- the process-level legs A to V, among them: the `/health` storage states under a real Postgres
  outage (K), a real embedded-storage failure (P) and one inside the startup window (U); the
  upgrade from the real upstream `v0.36.2` binary from its own image, with a live old node,
  a killed old node, every interruption point of the move, and the previous release's
  half-finished move (J); and the upgrade from the published `0.36.2-patched.2` image (V);
- rahi's own whole live suite at `b815b18c`, with `RAHI_REQUIRE_RAUTHY=1`, against an image built
  from the candidate bytes, including rahi's passkey-only backup administrator proof. amd64
  only, from a pinned checkout of the public repository. This is not a statement that a rahi
  release has adopted anything.

## Unresolved limitations

- Qualified at N = 1 only.
- Hiqlite snapshot readability across the upgrade rests on source, because no snapshot existed
  during the check.
- `panic = "abort"` is workspace-wide and the remaining panic surface is not audited site by site.
  A panic after the storage layer started exits `134` after a bounded storage shutdown; on a
  single-CPU runtime that shutdown cannot run and times out after 20 s.
- Config errors abort the process before storage starts, including settings upstream only failed
  on later: a zero scheduler interval, a cron that never fires again, a Matrix user without a room
  or credentials, an unknown `TZ_FALLBACK`, incomplete S3 picture settings.
- Upstream's lost update on the user row (a login concurrent with a profile-picture upload can drop
  the picture) is present and not changed.
- DPoP proofs carry no `jti` replay tracking, as upstream; a proof stays usable for about 60 s.

## Explicitly outside this release

- `rahi` must adopt and publish the new image pin. Publishing rauthy does not do that.
- `rahi`'s application-side Hiqlite dependency is a separate dependency path from the copy embedded
  in rauthy. Carrying the patched Hiqlite there means the aliased declaration
  (`hiqlite = { package = "hiqlite-patched", version = "=0.15.0-patched.2", default-features =
  false, features = [...] }`), removing the workspace's `[patch.crates-io]` entry, and publishing
  a new `rahi-store` and `rahi`, as the Hiqlite handoff sets out. Its disk-backed cache needs the
  same one-time `HQL_CACHE_LEGACY_MOVE_ASIDE=true` start, and its `dlock` is a lease, not a fence
  (Hiqlite F-026).
- Aicortex and Statecraft need their own dependency adoption and acceptance.
- Statecraft's object-store writer fencing is not addressed by this release.
- Nothing here is deployed. This is not a production deployment.
