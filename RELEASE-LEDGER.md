# Release ledger: Rauthy 0.36.2-patched.2 and 0.36.2-patched.3

A downstream patched distribution of Rauthy. **Not an upstream release**, not endorsed by and not
supported by the upstream project. Upstream's sources, licence and authorship are carried
unchanged apart from the commits listed below.

This file states facts that were measured, and says where a value does not exist yet. Sections 1
to 10 are the record of `0.36.2-patched.2`, and section 7 is its publication state. Section 11 is
the work after it; **section 12 is `0.36.2-patched.3`**, and the section to read first for it. The copy attached to a release is the
one in the tagged tree, written before the publish run existed: the artefact digests are in that
release's `RELEASE-PROVENANCE.md`, and the ledger on `patched/0.36.2` records them afterwards.

## 1. Candidate identity

| | |
|---|---|
| Version | `0.36.2-patched.2`. `patched.1` is burnt: see "The `0.36.2-patched.2` image" in section 7 |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Source | https://github.com/bartekus/rauthy, work branch `release/0.36.2-patched.1-hiqlite` |
| Release line | `patched/0.36.2` (first merge: PR #2 at `119131b2`, against upstream `hiqlite 0.14.0`) |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.2` |
| Binary path in image | `/app/rauthy` (unchanged) |
| Executable name | `rauthy` (unchanged) |
| Storage dependency | `hiqlite-patched`, `hiqlite-wal-patched`, `hiqlite-derive-patched` `0.15.0-patched.1` |
| Supported topology | N = 1 |
| Publication status | **published 2026-09-23**: release `v0.36.2-patched.2`, image index `sha256:ea114a8b...`. Section 7 |

`patched.N` sits in the SemVer pre-release field because that is the only field a valid SemVer can
carry it in and still parse, order and satisfy rauthy's own `semver` checks. The consequence is
that `0.36.2-patched.2` orders *below* `0.36.2`; section 5 records what that does and does not
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
| F8 | Four more in TLS load and self-signed renewal; the renewal task could abort a serving node. This row covers the sites in `tls.rs` only; the certificate generation it calls was still panicking, which is F15. | Measured against the upstream binary: exit 134 upstream, exit 1 with 3 shutdowns patched. Acceptance M2 |
| F9 | The JWK-rotation and MaxMind schedulers `unwrap()`ed operator-supplied cron expressions after the storage layer was live. | Acceptance C |
| F10 | `DB::init()` itself: when connecting to Postgres, waiting for a healthy Raft, or reading the membership failed after `hiqlite::start_node_with_cache()` had returned a running node, the client was dropped unstopped. F2 did not cover it, because `run()` only shuts down a client that was stored. The `PG_*` `expect()`s ran in the same window. | Acceptance C, "a backend failure inside DB::init shut the embedded storage down": observed failing with the fix reverted |
| F11 | Found by the integration. `/ready` answered from the health watcher's debounced sample, so after a terminal storage failure it kept answering `200` for up to 90 s. It now also consults `Client::node_failure()` and answers `503` at once. | Acceptance P, "readiness reports the embedded storage failure within seconds": observed failing (`200`) with the fix reverted |
| F12 | Found by the integration. The IP-blacklist middleware looks every client up in the cache ahead of every handler. On a failed node that lookup is refused, so the probes answered `500` from the middleware and `/ready`'s `503` never ran. When that lookup fails on one of the three probe paths only, the request proceeds; a blacklisted client is still refused whenever the lookup succeeds. | Acceptance P on the `d45826cd` tree answered `500`; `503` after the fix |
| F13 | `hiqlite::Error::NodeFailed` carries an account naming internal components and file paths, and fell through to a catch-all that put it in the response body. The account now goes to the log; the client gets "The storage layer of this node is out of service". | Acceptance P, "the refusal does not expose the storage path to the client" (meaningful only on a Hiqlite tree that refuses reads, see 3.4) |
| F15 | **New, found by review round 11.** Self-signed certificate generation (`SelfSignedCA`), which runs at startup and on every renewal of a serving node, after `DB::init()`, `unwrap()`ed eight results: the stored CA row's decoding, key generation and parsing, both signatures, and the certificate name taken from `PUB_URL`. A `PUB_URL` host that is not a valid DNS name (non-ASCII, for one) aborted the start. Each is now an error; at startup that fails the start through the storage shutdown, and in the renewal task it is logged and retried. | Measured: `PUB_URL=bücher.localhost:8448` with self-signed TLS exits 134 on the unfixed tree, and the next start reports 3 unclean-shutdown markers; exit 1 and a clean next start with the fix. Acceptance M3, observed failing (3 of 4 assertions) without the fix |
| F16 | **New, found tracing the shutdown contract.** The mail sender connects to SMTP after `DB::init()`. An incomplete configuration (`SMTP_URL` without `SMTP_USERNAME` or `SMTP_PASSWORD`, an unusable `SMTP_URL` or `SMTP_ROOT_CA`, an unparsable `SMTP_FROM`) hit an `expect()` and aborted with the storage layer live. Exhausted connection retries called `shutdown().await.unwrap()` and then `panic!`: under the patched Hiqlite `shutdown()` reports a failed stop, so the `unwrap()` became a second abort site. All of these now shut the storage layer down and exit `1` with the reason logged; a failed shutdown is logged, not unwrapped. | Measured: `SMTP_URL` without `SMTP_USERNAME` exits 134 on the unfixed tree and the next start reports 3 unclean-shutdown markers. Acceptance S (three cases, 12 assertions): 5 of them fail on the unfixed tree |
| F17 | **New, found by review round 12.** `DB::connect_postgres` runs inside `DB::init()` after the Hiqlite node has started. A `PG_TLS_ROOT_CA` with a PEM block that does not decode `panic!`ed, and a certificate rustls refuses hit an `expect()`: both aborted with the node live, past the shutdown F10 put around that window. Both are now errors. | Acceptance C, two cases: exit 134 and an unclean next start on the unfixed tree (4 of 6 assertions fail), exit 1 and a clean next start fixed |
| F18 | **New, found by a sweep after round 12.** Settings upstream only acts on after `DB::init()`, where an invalid value panicked: a zero user-expiry, email-job or dynamic-client cleanup interval, a cron expression that parses but never fires again, a Matrix user without a room or credentials, an unknown `TZ_FALLBACK`, S3 picture storage without its settings or with an unparsable URL, file picture storage on more than one node, `MIGRATE_DB_FROM` naming Postgres without `MIGRATE_PG_*`. Config validation now refuses each before a data directory exists. | Acceptance T, five of them: on the unfixed tree each starts the storage layer and then aborts |
| F19 | **New, the safety net for the rest.** The sweep also found panics after `DB::init()` that validation cannot decide: bootstrap file contents, a database older than `0.35.0`, `MIGRATE_DB_FROM` contents, Matrix and S3 reachability at boot, plus the unaudited per-request surface. A panic hook installed once `DB::init()` succeeds now asks for a bounded (20 s) storage shutdown from its own thread, then lets the abort proceed: the exit code stays `134`, because a panic is a bug, but the data directory is left clean. A second panic aborts at once. | Acceptance T: an invalid `BOOTSTRAP_API_KEY`, still an `expect()`, exits 134 after "The storage layer was shut down after the panic", and the next start reports no unclean shutdown; both assertions fail on the unfixed tree |

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

- **The publish gate accepted the best review, not every review.** It took any successful review
  run on the reviewed head, so a blocking verdict followed by a rerun or a dispatched second run
  that happened to pass would have been accepted. Every review run on that head must now be a
  first-attempt `pull_request` run that succeeded; a head with a blocking verdict needs a new
  commit.
- **The acceptance harness let its defaults override a scenario's environment.** `start_node`
  passed the caller's assignments to `env` before its own, so a scenario could not set `PUB_URL`.
  No existing leg set a conflicting variable; M3 needed to.

- **The publish verification failed on a pipe, not on the image** (section 7): `docker logs |
  grep -q` under `pipefail` exited 141 on arm64 and stopped the `patched.1` publication after its
  image was pushed. Every `| grep -q` in the publish workflow and the two negated ones in the
  harness now read a file or a here-string.

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
- **The remaining `panic = "abort"` surface.** Not audited site by site. What configuration can
  reach at startup is an error (F2, F7 to F10, F15 to F17) or refused before storage starts (F18).
  Everything else, including the per-request code, the Microsoft Graph sender's token `expect()`,
  the SMTP sender's recipient `unwrap()`s, bootstrap file contents and a too-old database, still
  aborts with `134`, now after a bounded storage shutdown (F19). Limit of F19: the shutdown runs on
  the runtime's other workers, so on a single-worker runtime (one CPU, where the panicking thread
  is that worker) it times out after 20 s and the data directory is left as upstream would leave
  it.
- **Config-layer aborts.** Config errors, including F18's, abort the process before `DB::init()`;
  nothing is at stake, but a supervisor sees an abort, not a clean exit.

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
| `openraft` | `0.9.25`, pinned `=0.9.25` by `hiqlite-patched` | crates.io, `a97014fb78acb77be3a40ac2da305f6dd3a6b243f3a908ace87d29b3972eaafd` |

Provenance, checked independently of the Hiqlite owner's report: the crates.io API returns these
three checksums, none yanked, published by `bartekus` on 2026-09-22; each downloaded `.crate`
hashes to its checksum and its `.cargo_vcs_info.json` records commit
`3392c12033f42f571b806d9ec24c5c5c9c40999a`, not dirty; that commit is the target of the annotated
tag `v0.15.0-patched.1` in `bartekus/hiqlite`
(https://github.com/bartekus/hiqlite/releases/tag/v0.15.0-patched.1). Against the last git
candidate this release was exercised on (`e1e91355`), the published tree changes WAL rollover and
flush failure handling, S3 retention filtering, the cache-format check on a reset start, and a
dlock handler; acceptance P injects exactly the rollover failure.

The Hiqlite owner's evidence, checked here against the forge: the tag object is signed and GitHub
reports it `verified`; its CI `Check` run `35789836641` ran on `9fd491f0`, whose tree
(`fa07fcb1`) is identical to the tagged commit's; the publish run `35793410166` and the 33-block
acceptance run `35791749020` ran on the tagged commit itself, all first attempt, all `success`.
F-107 was read in the published source, not taken from the report: `Client::shutdown()` closes
membership admission first, a drain timeout returns `Err` before any component is stopped, the
sequence runs in its own task so a caller's timeout cannot cut it between two raft groups, and six
`start_paused` tests in `membership_gate.rs` drive the interleavings. None of that is reachable at
N = 1, where no membership change is ever admitted. Rauthy's shutdown call sites log an `Err` and
exit non-zero (the one that `unwrap()`ed it is F16), so the new result needs no other adaptation.

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

**Database.** No schema change and no migration. This build stamps `0.36.2-patched.2` into the
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
| Bad configuration, bind failure with cleanup | C, D, M3, S, T | both (M3, S, T: Hiqlite) | F4, F9, F10, F2, F15 to F18 |
| A panic after storage started | T | Hiqlite | F19: bounded storage shutdown, abort, clean next start |
| Real competing processes | E | Hiqlite | `StorageInUse`, first node unharmed |
| Normal shutdown, restart | F | Hiqlite | clean exit `0`, no unclean markers, keys survive |
| Interrupted run, recovery | Q | Hiqlite | SIGKILL under write load; the next start must report the unclean shutdown; acknowledged writes, keys and identity survive; the recovered node shuts down cleanly |
| Fresh backup, restore, bad restore input | G, `handler_generic::test_backup_download_is_complete`, `api::backup::tests` | Hiqlite | F1; restore with original keys and identity; truncated and missing input refused without loss; snapshot name |
| Restore into an owned directory | R | Hiqlite | refused before any restore step; owner's data intact in memory and on disk |
| Live storage failure, Postgres | K | Postgres | the database container is stopped under a live node: `/ready` `503`, `/health` `500` |
| Live storage failure, embedded Hiqlite | P | Hiqlite | the Raft log directory is made read-only and writes are driven until the WAL writer cannot rotate: `/ready` `503` within seconds, `/health` `500`, writes and reads refused with no storage path in the body, no abort, SIGTERM exit without a kill, recovery with every acknowledged write |
| Upgrade and rollback against the real baseline | J | Hiqlite | the upstream `v0.36.2` binary from its own image writes data; the raw upgrade is refused with its raft log byte-identical and its database content unchanged; the opt-in upgrade keeps keys, identity and upstream-written data and moves the cache aside; a later start needs no opt-in; the rollback reads patched-written data |
| TLS and metrics exit paths | M, L | Hiqlite | F8, F15, F7 |
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
| **published `0.15.0-patched.1`** (tip `00e411ed`) | CI run `35796064248`, every job, first attempt | acceptance **117 passed, 0 failed, 0 skipped, strict** on amd64 and on arm64; both integration suites; Rahi 606 passed, 0 failed, 1 ignored by Rahi. The registry graph, but not the final tree: review round 11 then found F15, and F16 was found tracing the shutdown contract, so it does not qualify publication |
| M3 and S only, published Hiqlite | local, macOS arm64, debug build | 16 passed, 0 failed with F15 and F16; 8 passed, 8 failed with both reverted (the unfixed tree exits 134 in all four cases) |
| published `0.15.0-patched.1` (tip `2227073f`) | CI run `35810812490` | acceptance green on amd64 and arm64 with M3 and S; superseded by round 12 |
| C's root CA cases and T, published Hiqlite | local, macOS arm64, debug build | 20 passed, 0 failed with F17 to F19; on `00e411ed` 9 passed, 11 failed |
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

**Published 2026-09-23.** Every value below was read back from GitHub and the registry after the
publish run, not copied from the run's own output. The copy of this file attached to the release
is the one from the tagged tree, written before these values existed; this section on
`patched/0.36.2` is where they are recorded, and the tag does not move.

| | |
|---|---|
| Release | https://github.com/bartekus/rauthy/releases/tag/v0.36.2-patched.2 |
| Tag | `v0.36.2-patched.2` -> `17132b9451912cf45d33c99990f21678b75e2e26` (the merge of PR #4) |
| Reviewed head | PR #4 at `7bb179350ebf4ece44a3be64b9b7ef6bb9127954`, same tree as the tag |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Image, pinned | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.2@sha256:ea114a8bb743d578dea6d7800916ee43550939c749a2cf586f9abdc0d0c52478` |
| `linux/amd64` manifest | `sha256:6774d28c9f611777dc4ad2243a8f4cb1fa0df3d94caca1aeaf052cc10d9e5658` |
| `linux/arm64` manifest | `sha256:6ae9225a9243a7e660f6c407d07f81258d06f456470dfb4b6c899a6db13146f8` |
| `rauthy_amd64` sha256 | `742b18ba3717a92577a2ae0d517546a64ef6967c86e2847b50b10a22ab8dfc59` |
| `rauthy_arm64` sha256 | `5e498c31ef23ebc27a6d2dbdbf73f6d6f48129f541fced92d48a53b87d61e312` |
| `Cargo.lock` sha256 | `923af1dcfe6181632ee79cf49082a6881bf0f20aed7a8c79b205762bcf7233c0` |
| Toolchain | `rust:1.95.0-bookworm`, `rustc 1.95.0 (59807616e 2026-04-14)`; glibc floor `GLIBC_2.34` |
| Candidate run (merge commit) | https://github.com/bartekus/rauthy/actions/runs/35835459954 |
| Candidate run (reviewed head) | https://github.com/bartekus/rauthy/actions/runs/35829275274 |
| Review run (round 15) | https://github.com/bartekus/rauthy/actions/runs/35829280152 |
| Publish run | https://github.com/bartekus/rauthy/actions/runs/35841596479 |

**What each run established.** The merge-commit candidate: first attempt, all 10 jobs green,
acceptance 153 passed, 0 failed, 0 skipped, strict, natively on amd64 and on arm64; both integration
suites (Hiqlite, Postgres); Rahi's live suite 606 passed, 0 failed, 1 ignored by Rahi. The publish
run, first attempt, every job green: the gate accepted that run, the image job pushed and attested
the index, native verification on each architecture pulled by digest, compared the binary byte
for byte with the tested one, checked labels and licence, reached `/ready` and shut down with exit
`0`, and only then the release was created with 8 assets.

**Checked independently afterwards,** from a Docker configuration with no credentials: the tag
`0.36.2-patched.2` resolves to the index digest above; the index lists exactly the two platform
manifests above plus their two attestation manifests; each platform's `/app/rauthy` hashes to the
release asset of the same name, which `SHA256SUMS` lists; `--version` prints
`rauthy 0.36.2-patched.2` on both; the labels name the fork as source, `Apache-2.0`, the upstream
base and commit, and the revision `17132b94`; `/app/LICENSE` is upstream's. Started from the image
with an empty config file and environment only: ready in 11 s on arm64 (native) and 15 s on amd64
(emulated on this host; the workflow ran it natively), both layers healthy, the downstream banner
logged, exit `0` on `docker stop`, no panic. The release assets download without authentication.

**Anonymous access:** the package is public; the registry serves the index to an anonymous pull
token. No owner action remains.

### The `0.36.2-patched.1` image: pushed, verified on amd64 only, never released

PR #3 merged as `60e0f28b`. Its candidate run `35819848674` was green on the first attempt
(acceptance 153 passed, 0 failed, 0 skipped, strict, on amd64 and arm64; both integration suites;
Rahi 606 passed, 0 failed). Publish run `35824160347` promoted it: the gate passed, the image job
pushed `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1` at index digest
`sha256:4260d9eb649ec59cb299143b8e87228ded78b77bd1518b2fc8f0fe9a5ee482dc` and attested it, amd64
verification passed, and **arm64 verification failed with exit 141**. The release job therefore
did not run: no git tag and no GitHub release exist for `patched.1`.

The failure was the harness, not the image. `docker logs smoke 2>&1 | grep -q "Shutdown complete"`
ran under `pipefail`; the first of three "Shutdown complete" lines is line 164 of 178, so `grep -q`
exited while `docker logs` was still writing, and the pipeline failed with SIGPIPE. Reproduced
outside CI on linux/arm64 from an anonymous pull of that digest: the binary hashes to the tested
arm64 binary (`b384ba53...`), `--version` prints `rauthy 0.36.2-patched.1`, `/ready` answered `200`
after 10 s, `/health` reported both layers healthy, and the container stopped with exit `0`.

Why a new version and not a rerun: re-running a failed job until it passes is the green-by-rerun
this release refuses for candidates and reviews, and a fresh publish of `patched.1` is refused by
the gate because the image tag already exists. Published tags never move, so `patched.1` is
burnt. **Do not pin `0.36.2-patched.1`**: it has no release, no provenance file, and its arm64
verification never passed in the workflow. It is left in the registry rather than deleted, so
that nothing that may have pulled it finds it gone.

### Also found by that attempt

- `workflow_dispatch` resolves the workflow on the default branch, which is `main` and carries
  upstream's tree, so `release-publish.yaml` could not be dispatched by name. GitHub assigns a
  workflow id the first time any event runs a workflow; one run on a throwaway branch whose copy
  also listened to a push there, with every job skipped, registered it (run `35824125018`, id
  `364850805`). The branch was deleted. The publish run is dispatched by that id with
  `ref=patched/0.36.2`, so it runs the file as merged there. `main` is unchanged.
- The same `| grep -q` shape appeared in the `[patch.crates-io]` guard, where a SIGPIPE inside the
  `if` would have read as "no entry" and let the guard pass, and in two negated acceptance
  assertions in leg P, where it would have read as "not leaked". All are file or here-string reads
  now.

### How the publish run is dispatched

`release-publish.yaml` is dispatched by workflow id `364850805` with `ref=patched/<line>`, because
dispatch by name resolves on the default branch. A later patch level follows the same sequence:
release graph, green candidate and clean first-attempt review on the pull request's head, merge,
candidate on the merge commit, dispatch with that run's id.

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

**Round 11** (review run `35796068651`, head `00e411ed`, the first head on the registry graph):
`VERDICT: blocking findings`, two of them, both real.

1. The ledger's section 1 and 7 and the whole handoff still said publication was held on the
   Hiqlite packages, after section 4 recorded them as published. Both files ship with the
   release. Rewritten.
2. F8's claim was broader than its fix: `tls.rs` no longer panicked, but the certificate
   generation it calls still `unwrap()`ed, reachable from `PUB_URL`, at startup and on every
   renewal. Reproduced (exit 134, 3 unclean markers on the next start), fixed as F15, with
   acceptance M3 observed failing without the fix.

Following the second finding through the patched Hiqlite's changed `shutdown()` result found F16
in the mail sender, and the gate's acceptance of the best review rather than every review
(section 3.3). The candidate run on the same head, `35796064248`, was green in every job; it is
superseded because the tree changed.

**Round 12** (review run `35810816253`, head `2227073f`): `VERDICT: blocking findings`, one, real.
The Postgres root CA was still parsed with `expect()` and `panic!` inside the window F10 claimed
to have closed. Reproduced in both forms and fixed as F17. Because rounds 8, 11 and 12 each found
another panic site of the same class, the next step was a sweep of every operator-reachable panic
after `DB::init()`, not a third one-site fix. It listed about 25; F18 refuses the ones validation
can decide, and F19 is the safety net for the rest (section 3.5 states its limit).

**Round 13** (review run `35815196727`, head `e428b322`): `VERDICT: no blocking findings`. PR #3
merged as `60e0f28b`; section 7 records its publication attempt.

**Round 14** (review run `35824500935`, head `d3c57554`, PR #4): `VERDICT: blocking findings`, one,
real. The version bump to `patched.2` broke a unit test that asserted the patch level was the
literal `1`; the same head's candidate run `35824497305` failed its integration jobs on exactly
that test. The test now asserts a patch level of at least `1`. The candidate's style job had
passed because it does not run that crate's unit tests; the whole workspace's unit tests were run
locally before the fix was pushed.

**Round 15** (review run `35829280152`, head `7bb17935`, PR #4): `VERDICT: no blocking findings`,
the only review run on that head. PR #4 merged as `17132b94`, which is the published tag.

**Round 16** (review run `35842113862`, PR #5, docs only): `VERDICT: no blocking findings`; its one
note was that this section had no entry for round 15, which is the paragraph above.

## 10. Upstream return path and maintenance

F1 to F4 and F7 to F13 are candidates for upstream pull requests against upstream's development
line; nothing in this release touches the upstream repository. The Hiqlite findings in 3.4 belong
to the Hiqlite fork's own record.

`CHANGELOG.md` is deliberately untouched; this ledger is this distribution's changelog.

This line tracks upstream `v0.36.x`. An upstream patch release becomes `0.36.<z>-patched.1` on a new
`release/` branch cut from that tag, with this ledger and the acceptance matrix re-run in full.
Patch levels within one base increment. Published tags never move.

## 11. After publication: corrections and the next patch level (released as patched.3, section 12)

Recorded 2026-09-23 on the local branch `work/0.36.2-patched.3`, cut from `patched/0.36.2` at
`513bcc98`. **Nothing in this section is released, pushed or qualified.** Sections 1 to 10 stay
the record of `0.36.2-patched.2` and are not edited.

### 11.1 Corrections to the published handoff

`RELEASE-HANDOFF.md` keeps the text that shipped and marks six statements **[C-1]** to **[C-6]**
under a dated corrections section. The evidence each correction rests on:

| | corrects | evidence |
|---|---|---|
| C-1 | persistent `503` as a restart signal | `/ready` has one `503` for every unconfirmed sample (`health_watch.rs::storage_ready`); Rahi 043 rejects the heuristic |
| C-2 | `StorageInUse` "before anything is touched" | only patched builds take the owner lock; Rahi 043 D-P3, Hiqlite F-126 and 035 P-2 (the live node's cache moved, then damaged) |
| C-3 | "Nothing was changed." | `hiqlite-owner.lock` created (Rahi D-P2, Hiqlite 035 P-1); published `start.rs` checks the cache before opening SQLite, so the checkpoint in section 5 belongs to an earlier tree |
| C-4 | the manual-move rollback | leg J ran with no Raft snapshot (section 5, limits); Hiqlite F-129 and 035 P-6 (3 of 3 panics without the move); 035 B-4 |
| C-5 | "a no-op once the marker exists", "leave it set" | Hiqlite F-130 (defect, medium confidence, source-read); 035 B-5 unreleased; Hiqlite's third-pass notice on the lingering variable |
| C-6 | "a restart window already tolerates", "nothing missing" | `server.rs::run` clears only `Html` and `App` in a release build; `RELEASE-STATE-INVENTORY.md` |

A notice for the published release, changing none of its assets, is prepared in
`RELEASE-CORRECTION-NOTICE-0.36.2-patched.2.md` and awaits approval.

### 11.2 Release assets, re-verified

Anonymous reads at 2026-09-23T20:38:05Z: eight assets on release `394484695`, each matching
GitHub's recorded digest; the handoff, ledger and licence assets identical to the tagged tree;
the tag at `17132b94`; the registry index `sha256:ea114a8b...c0d0c52478` with the two platform
manifests of section 7; `/app/rauthy` per platform hashing to `SHA256SUMS` and printing
`rauthy 0.36.2-patched.2`. Detail in `RELEASE-PRODUCER-RESPONSES.md`, R-3.

### 11.3 Changes on the branch

| # | change | commit |
|---|---|---|
| F20 | DPoP: a nonce is accepted only when the cache holds an entry whose own value it is and whose expiry is in the future; `get_latest` issues a new nonce when fewer than 15 s remain | `40187dbe` |
| F21 | `/health` gains `storage`: `ok`, `degraded`, `terminal` (Hiqlite's `node_failure()`), `unknown` (inside `HEALTH_CHECK_DELAY_SECS`); acceptance K and P extended, leg U added | `d9ec502a` |
| | documentation: the corrections, `RELEASE-STATE-INVENTORY.md`, `RELEASE-PRODUCER-RESPONSES.md` | `d7d087aa` and later |

F20 was observed failing without the fix: against a local backend, `/oidc/token` answered `200`
with a token to a proof carrying a nonce the server never issued. Whether and how it is disclosed
before this branch leaves the machine is an owner decision (`RELEASE-PRODUCER-RESPONSES.md`).

### 11.4 Local evidence

| check | where | tree | result |
|---|---|---|---|
| `cargo fmt --all --check`, `cargo clippy --workspace -- -D warnings` | macOS arm64 | `d7d087aa` | clean |
| workspace unit tests (`--lib`) | macOS arm64 | `d7d087aa` | 88 passed, 0 failed |
| integration suite, Hiqlite backend | macOS arm64, debug | `d7d087aa` | 131 passed, 0 failed, 5 ignored |
| integration suite, Postgres backend | macOS arm64, debug, Postgres 17.2 | `d7d087aa` | 131 passed, 0 failed, 5 ignored |
| acceptance K, P, U only, strict | **native Linux arm64**, release build in `rust:1.95.0-bookworm`, binary `968207a6...5816` | `d7d087aa` | 36 passed, 0 failed, 0 skipped, 3 min 54 s |
| the same | native Linux amd64 | | **not executed**: no native amd64 host |

The Linux arm64 leg ran twice. The first run (24 passed, 12 failed) kept its data directories on
a macOS bind mount, where `chmod a-w` is not enforced, so leg P's injection never reached the
writer (3000 writes accepted). Probed separately: a write into a read-only directory succeeds on
that mount and is refused on the container's own filesystem. The second run kept them on the
container filesystem and changed nothing else. Both runs' logs are kept.

None of this is release qualification: the full acceptance matrix, both native architectures,
the registry-only graph and Rahi's suite run in the candidate workflow on the pull request, and
section 7's sequence applies.

### 11.5 Independent review

A local reviewer read the three commits at `bb803f27`: no defect in the fixes; blocking only
because this section did not yet exist. It also found `get_latest`'s inverted margin (now part
of F20), a flake risk in leg U's single read (now polled), missing skip entries in leg K, an
inaccurate restore-scope sentence and an understated `jwks_cleanup` observation (both corrected
in the inventory). This review does not replace the human review `AGENTS.md` requires before a
pull request.

### 11.6 Candidate integration on the repaired Hiqlite (2026-09-24, unpublished)

On the local branch `integ/0.36.2-patched.3-hq035`, cut from `51e73280`, which stays the reviewed
head of `work/0.36.2-patched.3`. **A candidate, not registry-published and not qualified.** The
integration commit `004d537f` points the workspace at Hiqlite `26e2fa0a` (PR #37, repair
`048fcecd`) from git; it must never be merged or released. Identities, binaries, the leg J
results and their limits are in `RELEASE-PRODUCER-RESPONSES.md`, "The repaired Hiqlite".

| check | where | tree | result |
|---|---|---|---|
| `cargo fmt --all --check`, `cargo clippy --workspace --locked -- -D warnings` | macOS arm64 | `004d537f` | clean |
| workspace unit tests (`--lib`) | macOS arm64 | `004d537f` | 88 passed, 0 failed, 3 ignored |
| integration suite, Hiqlite backend | macOS arm64, debug | `004d537f` | 131 passed, 0 failed, 5 ignored (second run, below) |
| integration suite, Postgres backend | macOS arm64, debug, Postgres 17.2 | `004d537f` | 131 passed, 0 failed, 5 ignored |
| leg J, candidate, strict, stop on first failure | native Linux arm64, release | harness `2468da7f`, binary `fd745715` | 94 passed, 0 failed, 0 skipped, 2 min 25 s |
| leg J, negative control on published `0.36.2-patched.2` | native Linux arm64 | harness `2468da7f`, binary `5e498c31` | all 6 declared controls fail, 2 min 39 s |
| the same on native Linux amd64, the other legs, Rahi's suite | | | **not executed** |

The first Hiqlite-backend suite run stopped inside `zzg_handler_token_exchange`, whose process
was sampled after 12 minutes with every sample in the dynamic loader (`_dyld_start`): it never
reached `main`, on a host loaded by other builds. It had passed every test before that (41 passed,
0 failed). The run was repeated once after that diagnosis; both logs are kept.

`check_graph.py` refuses this graph (git sources, no registry checksums), which is what it is for.
Before anything leaves this machine the dependency is replaced by the published packages under a
new version, the graph is regenerated and inspected with `check_graph.py`, and the release is
rebuilt. The internal-caret caveat of `0.15.0-patched.1` carries into that step:
`hiqlite-patched` requires its siblings `hiqlite-wal-patched` and `hiqlite-derive-patched` with a
caret (`version = "0.15.0-patched.1"`, no `=`), and the candidate keeps that form. Cargo can
therefore pair one release of `hiqlite-patched` with a later sibling release. `check_graph.py`
requires exactly one copy of each but not the same version for all three, so the regenerated
lock has to be read for that as well, or the check extended.

### 11.7 Corrections to section 11's own proposals

- The correction notice is now self-contained: `patched/0.36.2` on GitHub is still at `513bcc98`
  and does not carry the corrections it pointed to.
- The restore-invalidation proposal (`RELEASE-STATE-INVENTORY.md` section 4) wrote its
  completion row before clearing the cache and keyed completion on a row existing. A crash
  between the two, or a backup carrying an earlier run's row, would have let a restored instance
  serve a stale cached session. It now runs by operation id through durable phases. Not
  implemented.

**Independent review of `51e73280..b4adba04`** (local reviewer, 2026-09-24): `VERDICT: no
blocking findings`. Acted on: J-E's "the ban is gone" could pass on a failed read (it now
requires a `200`); `J_EXPECT` is validated; the notice now also states Rauthy's own observation
of upstream over an upgraded directory. Recorded, required before the harness reaches a branch
CI runs: `release-candidate.yaml` does not build a fault-point binary or set `RAUTHY_FAULT`, so a
strict run would skip J-F and fail; and leg J's default expectations fail on any build still on
`0.15.0-patched.1`, so the harness change belongs only with the repin. These fixes follow the
recorded runs and have not been run.

## 12. `0.36.2-patched.3`

Prepared 2026-09-24 on `release/0.36.2-patched.3`, cut from `patched/0.36.2` at `513bcc98`. The
owner chose one combined release (section 11, "Owner decisions" in
`RELEASE-PRODUCER-RESPONSES.md`): F20, F21 and the rebuild on the repaired Hiqlite.

### 12.1 Identity

| | |
|---|---|
| Version | `0.36.2-patched.3` |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Storage dependency | `hiqlite-patched`, `hiqlite-wal-patched`, `hiqlite-derive-patched` `=0.15.0-patched.2`, crates.io |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.3` |
| Supported topology | N = 1 |
| Publication status | **not published**. Digests, runs and the tag are recorded here after the publish run, as in section 7 |

### 12.2 Dependency graph

| package | version | checksum (crates.io) |
|---|---|---|
| `hiqlite-patched` | `0.15.0-patched.2` | `67ae1ca7cd5c601fc0176f5e6e15dfc480b088b048ed9d482add288f655c229d` |
| `hiqlite-wal-patched` | `0.15.0-patched.2` | `d65dd8c35c40f8204c64c62a549614da93078e12d290e7db48937bc6c828d290` |
| `hiqlite-derive-patched` | `0.15.0-patched.2` | `ce54d2189eadd47c368537b9a6687afef94df64a1eed0ae192614f350a57f2e2` |
| `openraft` | `0.9.25` | unchanged |

Hiqlite `0.15.0-patched.2` is tag `v0.15.0-patched.2` at `5c2cdef6` on `bartekus/hiqlite`. Its crate
sources are identical to `26e2fa0a`, the candidate section 11.6 tested from git: `git diff
26e2fa0a v0.15.0-patched.2` touches no `.rs` file, only the three versions, the README, and the
sibling requirements, which are now exact (`=0.15.0-patched.2`). That closes the caret caveat of
11.6 for this graph, and `check_graph.py` now also refuses patched packages at different versions
(checked against a lock with the WAL crate edited to a later version: refused). Apart from the
three Hiqlite packages and the workspace's own version, `Cargo.lock` is unchanged.

### 12.3 Changes against `0.36.2-patched.2`

| # | change | where |
|---|---|---|
| F20 | DPoP nonce enforcement and renewal margin | 11.3. Reported privately to the upstream maintainer before this branch was pushed (GitHub private vulnerability reporting, 2026-09-24) |
| F21 | `/health` `storage` | 11.3 |
| H-2 | Hiqlite `0.15.0-patched.2`: live-node exclusion before any rename, resumable consent move, refusals that name what they created, WAL locks held to the last write | 12.2 |
| | leg J rewritten for H-2 against the real upstream `v0.36.2`, including J-F's seven interruption points | 11.6 |
| | new leg V: upgrade from the published `0.36.2-patched.2` image, then this build without and with the variable | |
| | the candidate workflow builds a test-only fault-point binary per architecture (artifact `fault-build-<arch>`, outside the publish workflow's `rauthy-*` pattern) and passes it to leg J; it extracts the previous release's binary from its pinned image for leg V | |
| | `check_graph.py` refuses patched packages at different versions | |
| F22 | startup waits for the rebuilt state machine to apply its log before reading it | 12.5 |

### 12.4 Evidence before the pull request

| check | where | tree | result |
|---|---|---|---|
| `cargo fmt --all --check`, `cargo clippy --workspace --locked -- -D warnings` | macOS arm64 | this branch | clean |
| workspace unit tests (`--lib`) | macOS arm64 | this branch | 88 passed, 0 failed |
| `check_graph.py Cargo.lock` | | this branch | release graph |
| integration suites, leg J | | `26e2fa0a` from git | 11.6; same crate sources |

Leg V, the fault-point build in CI and native amd64 have not run before the pull request. The
qualifying evidence is the candidate run on the merge commit, as in section 7.

### 12.5 F22: a restart after an unclean stop bootstrapped a live database again

Found by the merge-commit candidate `35977264343` (acceptance arm64, leg Q), which therefore does
not qualify publication; amd64 and the PR head's run `35969384185` passed the same leg. After a
SIGKILL, Hiqlite's `auto-heal` rebuilds the state machine from the Raft log. The node reports
healthy once it is leader, before the replay has applied anything (`last_applied=None`, 191
entries), and Rauthy's startup reads the database at once: `migrate_init_prod` found `jwks` empty
7 ms after the election, deleted the initial admin and client rows, reset the admin from the
bootstrap values and generated a second key set. The replay then restored the old rows beside the
new ones. Nothing in Hiqlite `0.15.0-patched.2` touched this path; it is a race that predates this
release.

Fix: `DB::init_after_start` waits, on a leader, until `last_applied` reaches the log's last index
before startup reads anything (checking for a terminal failure while it waits). Local evidence,
macOS arm64 debug, 200 writes, SIGKILL, restart: with the fix, two of three restarts logged
"Waiting for the Raft DB to apply its log: None of 222" and read only after the replay; the unfixed
build did not lose the race in four tries on this host. Leg Q now also asserts that the restart
does not bootstrap its database. The proper place for the guarantee is Hiqlite's health (or its
start) not reporting ready before the replay; that is a follow-up there.
