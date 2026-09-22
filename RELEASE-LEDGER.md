# Release ledger: Rauthy 0.36.2-patched.1

A downstream patched distribution of Rauthy. **Not an upstream release**, not endorsed by and not
supported by the upstream project. Upstream's sources, licence and authorship are carried
unchanged apart from the commits listed below.

This file states facts that were measured, and says where a value does not exist yet. Section 7
is the publication state; it is the section to read first.

## 1. Candidate identity

| | |
|---|---|
| Version | `0.36.2-patched.1` (no release or tag of this version has ever been published, so the number is not reused) |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Source | https://github.com/bartekus/rauthy, work branch `release/0.36.2-patched.1-hiqlite` |
| Release line | `patched/0.36.2` (first merge: PR #2 at `119131b2`, against upstream `hiqlite 0.14.0`) |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1` |
| Binary path in image | `/app/rauthy` (unchanged) |
| Executable name | `rauthy` (unchanged) |
| Storage dependency | `hiqlite-patched`, `hiqlite-wal-patched`, `hiqlite-derive-patched` `0.15.0-patched.1` |
| Supported topology | N = 1 |
| Publication status | **held**: the Hiqlite packages are not on crates.io. Section 7 |

`patched.1` sits in the SemVer pre-release field because that is the only field a valid SemVer can
carry it in and still parse, order and satisfy rauthy's own `semver` checks. The consequence is
that `0.36.2-patched.1` orders *below* `0.36.2`; section 5 records what that does and does not
affect. An OCI tag cannot contain `+`, so build metadata was not an option.

**What changed since PR #2.** PR #2 qualified the repairs against upstream `hiqlite 0.14.0`,
because the patched packages did not exist. Nothing it measured covers the patched Hiqlite: the
dependency changed, so every earlier acceptance result is historical evidence only. This ledger
carries the integration, the repairs it forced, and the evidence taken against the patched graph.

## 2. Why this baseline

Unchanged from PR #2. The consumer (`rahi`) runs upstream `v0.36.2`, pinned by digest; upstream's
development line (`0.37.0-*`) carries config renames and an SMTP rework the consumer does not need
and depends on an unreleased Hiqlite API. `v0.36.2` plus the fixes below is the smallest change
set that consumes the repaired Hiqlite.

The patched Hiqlite's own baseline is upstream `v0.14.0` plus 19 commits. Its public API changed
(new error variants, `Client::node_failure`, bounded health waits, `ServerTlsConfig::from_env`
returns a `Result`), which is why it is `0.15.0-patched.1`. Rauthy `v0.36.2` compiles against it
**with no source change**; the changes below are behavioural adaptations, not compile fixes.

## 3. Included changes

Each product change was found by tracing a storage contract through Rauthy's caller or by a run
that failed, and each has an assertion that was observed failing without it, except where the
row says otherwise.

### 3.1 Defects in upstream v0.36.2 (runtime behaviour)

| # | Defect | Evidence it is real |
|---|---|---|
| F1 | `GET /auth/v1/backup/local/{file}` and `/backup/s3/{object}` ended the response body on a read error exactly as on EOF, under an already-sent `200`. Both now fail the stream; the local route also serves a `Content-Length` and treats it as a bound in both directions. | `api::backup::tests`; `handler_generic::test_backup_download_is_complete` |
| F2 | An error return after `DB::init()` skipped the storage shutdown (a listener that could not bind returned straight out of `run()`), so the next start rebuilt the state machine. | Measured against the upstream binary: 0 shutdowns and 3 unclean markers upstream, 3 shutdowns and 0 markers patched. Acceptance D |
| F3 | `GET /auth/v1/ready` answered `200` unconditionally. | Acceptance K (Postgres) and P (Hiqlite) |
| F4 | An unreadable config file became an empty config with a warning. | Acceptance C |
| F7 | Five `panic = "abort"` sites in `server_with_metrics()` reached after `DB::init()`. | Acceptance L |
| F8 | Four more in TLS load and self-signed renewal; the renewal task could abort a serving node. | Measured against the upstream binary: exit 134 upstream, exit 1 with 3 shutdowns patched. Acceptance M |
| F9 | The JWK-rotation and MaxMind schedulers `unwrap()`ed operator-supplied cron expressions after the storage layer was live. | Acceptance C |
| F10 | **New.** `DB::init()` itself: when connecting to Postgres, waiting for a healthy Raft, or reading the membership failed after `hiqlite::start_node_with_cache()` had returned a running node, the client was dropped unstopped. F2 did not cover it, because `run()` only shuts down a client that was stored. The `PG_*` `expect()`s ran in the same window. | Acceptance C, "a backend failure inside DB::init shut the embedded storage down": observed failing with the fix reverted |
| F11 | **New, found by the integration.** `/ready` answered from the health watcher's debounced sample, so after a terminal storage failure it kept answering `200` for up to 90 s. It now also consults `Client::node_failure()` and answers `503` at once. | Acceptance P, "readiness reports the embedded storage failure within seconds": observed failing (`200`) with the fix reverted |
| F12 | **New, found by the integration.** The IP-blacklist middleware looks every client up in the cache ahead of every handler. On a failed node that lookup is refused, so the probes answered `500` from the middleware and `/ready`'s `503` never ran. When that lookup fails on one of the three probe paths only, the request proceeds; a blacklisted client is still refused whenever the lookup succeeds. | Acceptance P on the `d45826cd` tree answered `500`; `503` after the fix |
| F13 | **New.** `hiqlite::Error::NodeFailed` carries an account naming internal components and file paths, and fell through to a catch-all that put it in the response body. The account now goes to the log; the client gets "The storage layer of this node is out of service". | Acceptance P, "the refusal does not expose the storage path to the client" (meaningful only on a Hiqlite tree that refuses reads, see 3.4) |

### 3.2 Test defects and coverage gaps (no product change)

| # | What | Why it is here |
|---|---|---|
| F5 | `zzd_handler_clients::test_clients` compared a global client count while neighbours in the same binary created and deleted clients. | Test defect. PR #2's repair kept one global check (every client present at the start is present at the end), which the neighbours still broke in CI run `35770325131` by deleting their own clients. The file's tests are now serialized, which is what that check assumed. |
| F6 | The device grant (RFC 8628) had no test, and Rahi drives it for native clients. `test_device_code_flow` covers it. | Coverage gap; the flow needed no fix. |
| F14 | **New.** All four `handler_users` tests log in as the one shared user, and every login path saves the whole user row it read. Run concurrently, a login saved a stale copy over `test_user_picture`'s new `picture_id`, which then failed with `400`. Observed in CI on both backends in one run, not in twelve local runs. The tests are now serialized. | Test defect. The lost update underneath it is upstream product behaviour and is **not** changed; see 3.5. |

### 3.3 Release engineering

- **The publish workflow trusted the run id it was given.** It checked the binaries against
  checksums from the same artifact, so any green run with matching artifact names, including a
  rerun that turned a red job green, would have been promoted. Its graph guard only asked whether
  each `hiqlite*` package came from a registry, so upstream's `hiqlite 0.14.0` passed it: PR #2's
  candidate could have been published on the graph it was meant to replace. Section 8.
- **Upstream's `code_style.yaml` declared no `permissions`,** so on this fork (default `write`) a
  pull-request job held a token that could push. It now declares `contents: read`.
- **The image ships `LICENSE`.** Apache-2.0 requires a copy with every redistribution.

Downstream identity, not a defect fix: the version marker, the startup log line naming distributor
and upstream base, the `patched.N` marker being recognised instead of warned about as an upstream
pre-release, and the image labels.

### 3.4 Found in the patched Hiqlite by this integration, repaired there

Reported to the Hiqlite release owner with evidence; repaired in `bartekus/hiqlite`, not here.

- **F-110.** `Client::ensure_node_available()` was documented as guarding "every local
  operation" and was called only by the health checks and the network API. Found by a
  negative-control run: with Rauthy's `NodeFailed` mapping reverted, the path-leak assertion still
  passed, because a failed node's writes were refused by openraft's own fatal error and reads were
  not refused at all. Repaired: writes, queries, cache operations, locks and listen now refuse with
  `NodeFailed`.
- **Upgrade abort.** Started on a data directory upstream `v0.36.2` left behind, the patched build
  exited `134` (`SIGABRT`) on both architectures (CI run `35764291279`, leg J; reproduced in a
  Linux container). Root cause, per the Hiqlite owner: the replicated cache command layout changed
  after `hiqlite 0.14.0` (upstream PR #362), so a 0.14 cache raft log is unreadable by any later
  build, and some entries decode as the *wrong* command; the start then failed, the teardown
  dropped the WAL reader's receiver, and `reader.rs` `unwrap()`ed the send, hiding the error behind
  an abort. Repaired as a contract (section 5): the cache raft is not carried across the upgrade,
  a legacy cache is refused with an error that changes nothing, `HQL_CACHE_LEGACY_MOVE_ASIDE=true`
  moves it aside, and the reader no longer panics.

### 3.5 Known upstream defects, not changed here

- **Lost update on the user row.** The picture upload and every login path (`authorize`, password
  grant, WebAuthn, upstream providers) read the user and save the whole row. A login that read the
  user before a concurrent picture upload saves it back without the picture. Present in upstream
  `v0.36.2`, unrelated to storage, and outside this release's scope; a candidate for upstream.
- **The per-request `panic = "abort"` surface** in `src/api`, `src/service` and `src/data` was
  spot-checked, not audited (unchanged from PR #2).
- **Config-layer aborts.** Config errors abort the process before `DB::init()`; nothing is at
  stake, but a supervisor sees an abort, not a clean exit.

### Contracts traced that needed no change

- **Ownership refusal.** The patched Hiqlite takes an OS advisory lock on the data directory before
  anything touches it, and a second process is refused with `StorageInUse: ... owned by another
  live process ... has changed nothing`. Acceptance E and R, two real processes.
- **Restore ownership.** `HQL_BACKUP_RESTORE` is processed after the ownership lock
  (`start.rs:252` before `:267` in the traced tree), so a restore aimed at a directory a live node
  owns is refused before any restore step. Acceptance R.
- **Shutdown.** `Client::shutdown()` is bounded at 15 s and now returns the sequence's own result;
  both Rauthy call sites already log an `Err` and exit non-zero. At N = 1 the whole storage
  shutdown takes about 30 ms (measured), so the 9.5 s multi-node delay does not apply.
- **F-107** (Hiqlite): `membership_change_allowed` refuses a node that is shutting down, has no
  leader, is not the leader, or is the leader but not a voter, each as `LeaderChange` (`409`), and
  in the final tree runs under the same gate as the shutdown. Not reachable at N = 1.
- **Consumer-read Hiqlite contracts.** The snapshot name `backup_node_<id>_<seconds>.sqlite` and
  the 60 s duplicate-backup suppression are unchanged from `0.14.0` (source, and acceptance G for
  the name).

## 4. Dependency graph

| Package | Selected | Source in the current candidate |
|---|---|---|
| `hiqlite-patched` | `=0.15.0-patched.1` via `hiqlite = { package = "hiqlite-patched", ... }` | crates.io, `456c1c117e5c581f6638572f26d9ef7cd567738c578e42ff0c8e09300534e7ca` |
| `hiqlite-wal-patched` | pulled in by the above | crates.io, `024992a08719a870bcef79192ed392cbef758b39caf0a60167541df379a05a9b` |
| `hiqlite-derive-patched` | pulled in by the above | crates.io, `e2380bba9eb80f5d7ecb5a59097b91bed1a3600f9d6e659ad37362e6cb2df077` |

Provenance, checked independently of the Hiqlite owner's report: the crates.io API returns these
three checksums, none yanked, published by `bartekus` on 2026-09-22; each downloaded `.crate`
hashes to its checksum and its `.cargo_vcs_info.json` records commit
`3392c12033f42f571b806d9ec24c5c5c9c40999a`, not dirty; that commit is the target of the annotated
tag `v0.15.0-patched.1` in `bartekus/hiqlite`
(https://github.com/bartekus/hiqlite/releases/tag/v0.15.0-patched.1). Against the last git
candidate this release was exercised on (`e1e91355`), the published tree changes WAL rollover and
flush failure handling, S3 retention filtering, the cache-format check on a reset start, and a
dlock handler; acceptance P injects exactly the rollover failure.
| `openraft` | `0.9.25` | crates.io, `a97014fb78acb77be3a40ac2da305f6dd3a6b243f3a908ace87d29b3972eaafd` |

The alias keeps the dependency key `hiqlite`, so no `use hiqlite::...` moves and the derive
macros' absolute `::hiqlite::` paths resolve. `cargo check`, clippy with `-D warnings`, and the
whole build pass with no Rauthy source change for the swap itself.

Against PR #2's lock, the graph changes only in the three Hiqlite packages and in
`constant_time_eq 0.6.0`, which the patched Hiqlite adds. `openraft` stays at `0.9.25`, the version
the Hiqlite release was qualified against after its own F-108 (local and CI resolving different
openraft versions); the published `hiqlite-patched` pins `=0.9.25`.

`assets/release/check_graph.py` is the single definition of a release graph, used by both
workflows: exactly one copy of each patched package, all from crates.io with a checksum, none of
upstream's `hiqlite*` packages, one `openraft`. The graph passes both its shape check and its release check.

## 5. Compatibility

**API.** No change except that `/auth/v1/ready` can answer `503`, which is what a readiness probe
is for. The `ErrorResponse` type is unchanged.

**Configuration.** No renames, no removals, no new required values. A config file that cannot be
read now fails the start unless it is the default `./config.toml` and simply absent.

**Database.** No schema change and no migration. This build stamps `0.36.2-patched.1` into the
`config` table's `db_version` row.

**Upgrade from upstream v0.36.2, in place.**

1. Stop the node.
2. Swap the image.
3. Start **once** with `HQL_CACHE_LEGACY_MOVE_ASIDE=true`. Hiqlite moves `logs_cache` and
   `state_machine_cache` into `{data_dir}/pre-upgrade-<unix seconds>/` (moved, never deleted),
   writes its format marker, and starts with an empty cache.
4. Remove the variable. Every later start runs without it.

Started without the variable, the node refuses with an error that names both directories, the
variable and the manual alternative, and exits `1`. That is the designed failure, not a crash.
Measured on a directory upstream left behind: the database's raft log is byte-identical afterwards
and the database content is identical, but the file's bytes are not, because the refusal comes
after the SQLite group has opened the database, which checkpoints its WAL and adds one
`sqlite_stat1` statistics row. The message's closing "Nothing was changed." is therefore stronger
than what holds; reported to the Hiqlite owner. With `HQL_CACHE_STORAGE_DISK=false` there is
nothing to move.

What an empty cache costs: in-flight authorization codes, device codes, WebAuthn challenges, PoW
challenges, rate-limit counters and IP-blacklist entries. **Sessions are not lost**: Rauthy
persists them in the `sessions` table and uses the cache only as a read-through. The SQLite
database, its raft log and the signing keys carry across unchanged.

**Recovery path.** Hiqlite's `HQL_BACKUP_RESTORE` into a fresh data directory, unchanged in use.
The patched Hiqlite stages the image before replacing anything and refuses a restore into a
directory a live process owns. The restored instance keeps the original signing keys.

**Rollback to upstream v0.36.2.** Stop the node, move `logs_cache` and `state_machine_cache` out
of the data directory **by hand**, then start upstream. This step is mandatory: upstream `0.14`
has no format marker check and could decode a patched cache entry as the wrong command. The
database, its raft log and everything the patched build wrote are readable by upstream (acceptance
J; the Hiqlite owner verified both directions separately). `LOWEST_COMPATIBLE_VERSION` in
`v0.36.2` is `0.35.0`, so the stamped version locks nothing out. Limit: no SQLite *snapshot* was
written during either check, so snapshot readability across versions rests on source (naming
unchanged; the patched build keeps two snapshots where `0.14.0` kept one).

**Not supported.** Mixed versions in one raft cluster. Downgrade below `v0.36.2`. Multi-node
topologies, including a multi-node restore (the patched Hiqlite states N = 1 for restore too).

## 6. Acceptance matrix

`assets/release/acceptance.sh <rauthy> [<upstream-rauthy>]` runs the process-level legs against a
release binary. With `ACCEPTANCE_STRICT=1`, which the candidate workflow sets, a skipped leg fails
the run, and every run writes `acceptance-result.json` for the publish gate. Each scenario has its
own data directory and ports.

| Requirement | Leg / test | Backend | Covers |
|---|---|---|---|
| Release identity, version output | A | n/a | `--version`, marker handling |
| First boot, production frontend | B | Hiqlite | ready, health, JWKS, identity; the served index references a built bundle and the bundle and `/account` are served |
| Bad configuration, bind failure with cleanup | C, D | both | F4, F9, F10, F2 |
| Real competing processes | E | Hiqlite | `StorageInUse`, first node unharmed |
| Normal shutdown, restart | F | Hiqlite | clean exit `0`, no unclean markers, keys survive |
| Interrupted run, recovery | Q | Hiqlite | SIGKILL under write load; the next start must report the unclean shutdown; acknowledged writes, keys and identity survive; the recovered node shuts down cleanly |
| Fresh backup, restore, bad restore input | G, `handler_generic::test_backup_download_is_complete`, `api::backup::tests` | Hiqlite | F1; restore with original keys and identity; truncated and missing input refused without loss; snapshot name |
| Restore into an owned directory | R | Hiqlite | refused before any restore step; owner's data intact in memory and on disk |
| Live storage failure, Postgres | K | Postgres | the database container is stopped under a live node: `/ready` `503`, `/health` `500` |
| Live storage failure, embedded Hiqlite | P | Hiqlite | the Raft log directory is made read-only and writes are driven until the WAL writer cannot rotate: `/ready` `503` within seconds, `/health` `500`, writes and reads refused with no storage path in the body, no abort, SIGTERM exit without a kill, recovery with every acknowledged write |
| Upgrade and rollback against the real baseline | J | Hiqlite | the upstream `v0.36.2` binary from its own image writes data; the raw upgrade is refused with its raft log byte-identical and its database content unchanged; the opt-in upgrade keeps keys, identity and upstream-written data and moves the cache aside; a later start needs no opt-in; the rollback reads patched-written data |
| TLS and metrics exit paths | M, L | Hiqlite | F8, F7 |
| Login, session, logout | `handler_auth`, `handler_users`, `handler_sessions` | both | |
| Native clients, device grant, refresh, revocation, bearer writes | `handler_auth::{test_device_code_flow, test_token_revocation, test_password_flow, test_dpop, test_client_credentials_flow}`, `handler_api_keys` | both | F6 |
| Audience and scope negative cases | `zzf_handler_resource_indicators`, `zzg_handler_token_exchange`, `handler_scopes` | both | |
| Passkey-only backup administrator with MFA | consumer job: Rahi's own `rauthy_backup_admin` test inside its whole live suite, `RAHI_REQUIRE_RAUTHY=1` | Hiqlite | the consumer's existing flow, unchanged; nothing invented here |
| The consumer's whole live suite | consumer job, `statecrafting/rahi` @ `b815b18c` | Hiqlite | an image built from the candidate bytes, run as Rahi's `live.yml` runs its pin |

Every new assertion was checked for the ability to fail: F10's and F11's were observed failing
with their fixes reverted; F13's was found **unable** to fail on a Hiqlite tree without F-110, was
removed, and was restored only once F-110 made it observable. Q's first design tried to kill the
node during its storage shutdown, which at N = 1 lasts about 30 ms; its own "was actually
interrupted" assertion caught that, and it was redesigned.

### Results

Evidence taken against the git-sourced Hiqlite candidate is scratch evidence: it guided the work
and cannot qualify publication.

| Tree | Where | Result |
|---|---|---|
| Hiqlite `c7d0d6a9` | CI run `35764291279`, amd64 and arm64 | 99 passed, 3 failed (J: the upgrade abort, 3.4), 0 skipped; integration suites green on both backends |
| Hiqlite `d45826cd` | CI run `35767263504`, amd64 and arm64 | 101 passed, 3 failed (J, same cause); integration suites failed on F14 on both backends |
| Hiqlite `d45826cd` + F12 | local, macOS arm64 | 98 passed, 0 failed, 2 skipped (J needs the Linux upstream binary) |
| Hiqlite `34641b0a` | CI run `35771464936`, amd64 and arm64 | 113 passed, 1 failed (the refused upgrade's byte-level database check, which found the checkpoint described in section 5), 0 skipped; integration suites green on both backends |
| Hiqlite `e1e91355` (tip `ae2408c8`) | CI run `35783026757`, every job | the same figures after the leg E fix, now counting a leg E assertion that can fail: acceptance 117/0/0 strict on amd64 and arm64; both integration suites; Rahi 606 passed, 0 failed, 1 ignored by Rahi |
| Hiqlite `e1e91355` (tip `f5323a2c`) | CI run `35775723599`, every job | acceptance **117 passed, 0 failed, 0 skipped, strict** on amd64 and on arm64; integration suites green on both backends; Rahi's whole live suite 606 passed, 0 failed, 1 ignored by Rahi itself, no skips, passkey-only backup administrator proof passing. The last scratch run: the graph is git-sourced, so it cannot qualify publication |
| Hiqlite `c7d0d6a9` | CI run `35764291279`, consumer job | Rahi's whole live suite: 606 passed, 0 failed, 1 ignored by Rahi itself, no skips; the passkey-only backup administrator proof ran and passed |

The qualifying run is the one section 7 names, on the merge commit, against the published graph.

### Limits

- **N = 3** not attempted, not claimed.
- **Architectures.** Acceptance runs natively on amd64 and arm64. The consumer suite runs on amd64
  only.
- **Hiqlite snapshots across versions:** from source only (section 5).
- **Bit-for-bit reproducibility:** not claimed; `BUILD_TIME` is stamped from the wall clock.
- **A backup download cancelled by the client** is not separately asserted (unchanged from PR #2).

## 7. Publication status

**Held.** The one remaining condition is outside this repository:

> `hiqlite-patched`, `hiqlite-wal-patched` and `hiqlite-derive-patched` `0.15.0-patched.1` are not
> on crates.io (checked against the crates.io API), and `bartekus/hiqlite` has no release tag for
> them. Their tree is `release/downstream-packaging` @ `e1e91355`, with its PRs #25 to #30 open.

When they are published, the change here is one line in `Cargo.toml` (git source to
`version = "=0.15.0-patched.1"`) and the lock, then:

1. `check_graph.py Cargo.lock` must pass as a release graph, and the published checksums and
   source commit must be the ones the Hiqlite owner reports.
2. The candidate workflow runs on the branch, a pull request into `patched/0.36.2` gets the
   independent review, findings are addressed, and the pull request is merged.
3. The candidate workflow runs again **on the merge commit**; that run, strict, first attempt, is
   the only one the publish gate accepts.
4. `release-publish.yaml` is dispatched from `patched/0.36.2` with that run's id.
5. If the GHCR package is private after the first push, making it public is an owner action no
   workflow token can perform:
   https://github.com/users/bartekus/packages/container/rauthy-patched/settings -> Change package
   visibility -> Public.

`.cargo/config.toml` sets `global-min-publish-age = '10 days'` under `[unstable]`; only nightly
cargo honours it, and this release builds on stable `1.95.0`, so a freshly published package is
not blocked.

## 8. Publication design

Three workflows, and no job holds a credential another job's step needs.

- `release-candidate.yaml` (push to `release/**` or `patched/**`, or dispatch) holds
  `contents: read` only. It builds the frontend and wasm once, records and checks the dependency
  graph, runs style and unit checks, runs the integration suite on both backends, builds the
  release binary per architecture inside `rust:1.95.0-bookworm` (glibc floor at most `GLIBC_2.34`,
  measured; `debian:bookworm-slim` provides 2.36), writes a manifest per architecture (commit,
  `Cargo.lock` sha256, registry-graph verdict, `rustc -vV`, binary sha256, glibc floor), runs
  acceptance strict on native amd64 and arm64 against the real upstream baseline binary, and runs
  the consumer's live suite against an image built from the candidate bytes.
- `release-review.yaml` (`pull_request` into `patched/**`, never `pull_request_target`) holds
  `contents: read` and `pull-requests: write` and the review credential, nothing else, and
  publishes the reviewer's verdict itself.
- `release-publish.yaml` (dispatch, from `patched/*` only) builds nothing:
  - **gate** (read-only) refuses unless the commit is the merge of a pull request into
    `patched/*` whose reviewed head has the same tree and a successful review run; the candidate
    run is `release-candidate.yaml` in this repository, on this exact commit, first attempt, every
    expected job green; both architectures' acceptance ran strict with nothing failed or skipped;
    both manifests name this commit and this `Cargo.lock` and a registry-only graph; the graph
    passes `check_graph.py`; and the tag does not exist.
  - **image** is the only job with `packages: write`. It pushes the multi-architecture image from
    the tested binaries and attests it.
  - **verify** pulls by digest on native amd64 and arm64, compares the binary byte for byte with
    the tested one, checks the labels and the licence, starts the image until `/ready` answers
    `200`, and checks a clean shutdown.
  - **release** is the only job with `contents: write`. It creates the tag and the release only
    after both verifications, with the binaries, `SHA256SUMS`, `LICENSE`, the image index, a
    generated `RELEASE-PROVENANCE.md`, this ledger and the handoff.

`CARGO_REGISTRY_TOKEN` is a repository secret referenced by no workflow: this release publishes
binaries and an OCI image, not a Rust package. `CLAUDE_CODE_OAUTH_TOKEN` is referenced only by the
review workflow.

## 9. Independent review

PR #2's seven rounds reviewed the tree against `hiqlite 0.14.0`; rounds 2, 4 and 6 found real
defects (F7, F8, and two acceptance assertions that could not fail), all fixed. That evidence
stands for the code it reviewed and unchanged since.

**Round 8** (PR #3, review run `35781889615`, head `1c856af5`, git-sourced graph) reviewed the
integration diff in full. Verdict: nothing in authentication, readiness, ownership, backup,
provenance or the publication gate; one real defect in the harness. Leg E's "the first node still
serves its signing keys" compared with leg B's node, fell back to "the JWKS is not empty", and so
could not fail. It dated from PR #2 and was counted in every pass figure since. Fixed: the leg
now compares the node's own keys, taken before the second process's attempt. One statement in the
review is inaccurate and changes nothing: it calls `/health` unconditional, but it answers `500`
when storage is unhealthy (acceptance K and P assert that).

**Round 9** (review run `35782723382`, head `43aa3aeb`) concluded `success` and produced no
verdict: the reviewer's final answer was that it was still running and would wait for
notifications. That exposed a gap in the gate, which accepted any successful review run. The
review workflow now requires the final line to be `VERDICT: no blocking findings` or
`VERDICT: blocking findings` and fails the run on a missing or blocking verdict, so a successful
run means a non-blocking verdict. Round 9 counts as no review.

**Round 10** (review run `35783029980`, head `ae2408c8`, git-sourced graph) read the full diff
against `v0.36.2` and the diff since round 8, cloned the patched Hiqlite at the pinned commit to
check every API Rauthy relies on, confirmed the leg E fix and the verdict gate, and traced
`check_graph.py` to confirm the gate refuses this git-sourced graph. `VERDICT: no blocking
findings`. The same head's candidate run `35783026757` is green in every job: acceptance
117/0/0 strict on amd64 and arm64, both integration suites, Rahi 606 passed, 0 failed.

The final head, carrying the registry graph, gets its own review round before merge; the publish
gate requires a successful review run on that exact head.

## 10. Upstream return path and maintenance

F1 to F4 and F7 to F13 are candidates for upstream pull requests against upstream's development
line; nothing in this release touches the upstream repository. The Hiqlite findings in 3.4 belong
to the Hiqlite fork's own record.

`CHANGELOG.md` is deliberately untouched; this ledger is this distribution's changelog.

This line tracks upstream `v0.36.x`. An upstream patch release becomes `0.36.<z>-patched.1` on a new
`release/` branch cut from that tag, with this ledger and the acceptance matrix re-run in full.
Patch levels within one base increment. Published tags never move.
