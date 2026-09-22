# Release ledger: Rauthy 0.36.2-patched.1

A downstream patched distribution of Rauthy. **Not an upstream release**, not endorsed by and not
supported by the upstream project. Upstream's sources, licence and authorship are carried
unchanged apart from the commits listed below.

## 1. Candidate identity

| | |
|---|---|
| Version | `0.36.2-patched.1` |
| Upstream base | `v0.36.2` = `dd61ac3c84d6b238108dc8438b53043b5177a662` |
| Source | https://github.com/bartekus/rauthy, branch `release/0.36.2-patched.1` |
| Release line | `patched/0.36.2` |
| Image | `ghcr.io/bartekus/rauthy-patched:0.36.2-patched.1` |
| Binary path in image | `/app/rauthy` (unchanged) |
| Executable name | `rauthy` (unchanged) |
| Supported topology | N = 1 |
| Publication status | **held** - see section 7 |

`patched.1` sits in the SemVer pre-release field because that is the only field a valid SemVer can
carry it in and still parse, order and satisfy rauthy's own `semver` checks. The consequence is
that `0.36.2-patched.1` orders *below* `0.36.2`; section 5 records what that does and does not
affect. An OCI tag cannot contain `+`, so build metadata was not an option.

## 2. Why this baseline

The choice was between a minimal patch on the consumer's supported upstream release (`v0.36.2`)
and adopting upstream's development line (`main`, `0.37.0-20260917`). The evidence:

- **The consumer already runs `v0.36.2`.** `rahi`'s `docker/Dockerfile` pins
  `ghcr.io/sebadob/rauthy:0.36.2` by digest and copies `/app/rauthy` out of it.
- **The development line carries breaking changes this release does not need.** Its unreleased
  changelog renames config values (`GEO_BLOCK_UNKONW`, `pasword_argon2id`) and reworks SMTP
  (`email.starttls_only` and `email.danger_insecure` removed, `email.smtp_tls_mode` added). None of
  that is required to consume a repaired Hiqlite.
- **The development line requires an unreleased Hiqlite API.** `main` pins hiqlite to a git commit
  and uses `get_remove()` / `get_remove_bytes()`, which the published `hiqlite 0.14.0` does not
  have. `v0.36.2` resolves `hiqlite 0.14.0` from crates.io and uses only its released surface.
- **The repairs backport with no source change.** A `cargo check --workspace --all-targets` of
  `v0.36.2` against the repaired Hiqlite line (`bartekus/hiqlite`, branch `spec-spine`, which is
  based on Hiqlite upstream `main`) compiles clean. The repairs there are behavioural, not API:
  the only public additions are `hiqlite_wal::AppendCompletion` and `Error::as_io_error`, neither
  of which Rauthy calls. Rauthy talks to `hiqlite::Client`, which is untouched.

So the smallest maintainable change set that can consume the repaired Hiqlite is `v0.36.2` plus
the fixes in section 3. Taking `main` would have imported a config migration for the consumer in
exchange for nothing.

## 3. Included fixes

Each is source-established: it was found by tracing a storage contract through Rauthy's caller, and
each has a test that fails without it. Nothing else from the fork's other branches is included.

| # | Defect | Why it is in this release |
|---|---|---|
| F1 | `GET /auth/v1/backup/local/{file}` and `/backup/s3/{object}` ended the response body on a read error exactly as on EOF, under an already-sent `200`. | The consumer's backup verb takes rauthy's snapshot through these routes and checks only the status and a non-empty body, so a truncated SQLite file was sealed into an archive as a good backup. Both routes now fail the stream instead of ending it, and the local route additionally serves a `Content-Length`, so a short body is detectable by any HTTP client on its own terms rather than only through the server dropping the connection. The S3 route has no length to declare, because it proxies a stream whose size it does not know in advance; there, the stream error is the whole guarantee. |
| F2 | Any error return after `DB::init()` skipped `DB::hql().shutdown()`. A listener that could not bind returned straight out of `run()`. | The WAL lock stayed held and the state-machine lock file stayed in place, so the next start read the directory as an ungraceful shutdown. With hiqlite's default `auto-heal` feature, which Rauthy enables, that rebuilds the state machine from the raft log. The post-init `expect`/`unwrap` calls became errors for the same reason: `panic = "abort"` runs no cleanup. |
| F3 | `GET /auth/v1/ready` answered `200` unconditionally. | It is the documented readiness probe for Kubernetes and Docker. An orchestrator kept routing to a node whose storage was unreachable. It now answers `503` on the health watcher's confirmed verdict, debounced through the watcher's existing re-check so a leader change does not flap a node out of service. |
| F4 | A config file that could not be read was replaced by an empty config with only a `warn!`. | A mistyped `--config-file` surfaced as "Missing `encryption.keys`", which sends an operator to the wrong place. Configuring entirely through environment variables stays supported: an absent file at the *default* path is still only a warning. A path the operator named, or a file that exists and cannot be read, is now a startup failure that names itself. |
| F5 | `zzd_handler_clients::test_clients` compared a global client count across its body while its neighbours in the same test binary created and deleted clients concurrently. | A test defect, repaired rather than tolerated: it made the suite fail on an unrelated schedule. It now asserts about the clients it owns. |
| F9 | The JWK-rotation and MaxMind-update schedulers parsed operator-supplied cron expressions with `Schedule::from_str(..).unwrap()`, and they are spawned after the storage layer is live. | Found by sweeping the class myself rather than waiting for a third review round to find it. A typo in `lifetimes.jwk_autorotate_cron` or `geo.maxmind_update_cron` aborted a process that already owned the data directory. Both expressions are now validated in `Vars::validate()`, which runs before `DB::init()`, so the failure happens while nothing is at stake and the message names the setting. Fixing it at the config layer rather than in the schedulers is deliberate: it fails early instead of after a full bootstrap, and it matches F4. |
| F8 | `load_tls()` and the self-signed certificate renewal task panicked in four places reached after `DB::init()`, and `tls_hot_reload::load_server_config` panics internally on material it cannot use. | Found by the second review round, which was right that this is the same defect class as F2 and F7 and that no leg exercised it: every scenario ran over plain HTTP. It is reachable in an ordinary production configuration, because rauthy falls back to generating self-signed material whenever the configured `cert_path`/`key_path` are simply missing, and the renewal task carries the panic into a long-running background task that can abort a healthy, serving node hours later. `load_tls()` is now fallible and its error reaches `run()`; the key and certificate are read and parsed before the hot-reload library sees them, which turns the reachable failures into errors instead of a panic inside a dependency; and the renewal task reports and retries instead of panicking, because an unrenewable certificate is survivable and an aborted node with a live storage layer is not. |
| F7 | `server_with_metrics()` still panicked in five places reached after `DB::init()`: two metrics-builder `unwrap`s, a `panic!` on a malformed `metrics_addr`, the metrics listener's `bind().unwrap()`, and the `block_on().unwrap()` around its run loop. | Found by the independent review, which correctly read this as a counterexample to F2's own claim of completeness rather than a separate issue. Under `panic = "abort"` these abort the process from any thread with no cleanup, so with `metrics_enable = true` a taken metrics port cost the next start its state machine, exactly the failure F2 exists to close. The configuration is now validated and the metrics port bound in the async function, where a failure is an error `run()` can act on, and only an already-bound listener is handed to the thread. The run loop's own failure is logged rather than fatal: metrics are opt-in and auxiliary, and losing them does not justify aborting an identity provider, least of all in the one way that skips the storage shutdown. |
| F6 | The device grant (RFC 8628) had no test. The well-known document advertised the endpoint and nothing exercised it. | A coverage gap, not a code defect: the consumer drives this flow for its native clients, so the release could not claim it without a test. `test_device_code_flow` now covers the grant request, a poll before approval (`authorization_pending`), an unknown device code, the approval through an authenticated session, and the token set. No product change was needed; the flow works. |

Downstream identity, not a defect fix: the version marker, the startup log line naming distributor
and upstream base, the `patched.N` marker being recognised instead of warned about as an upstream
pre-release, and the image labels.

### F2, measured against the upstream binary

The same scenario, run twice in the same container image, once with upstream's own `v0.36.2`
binary taken out of `ghcr.io/sebadob/rauthy:0.36.2` and once with this release's `linux/arm64`
artefact. The port is occupied first, so the listener cannot bind; the node is then started again
normally on the same data directory.

| | upstream `v0.36.2` | `0.36.2-patched.1` |
|---|---|---|
| Exit code of the failed start | 1 | 1 |
| `Shutdown complete` during that start | **0** | 3 |
| Unclean-shutdown markers on the next start | **3** | 0 |

Upstream's third marker is `Node did not shut down gracefully - auto-rebuilding State Machine`: a
failed bind costs it the state machine, which is then rebuilt from the raft log. This is the
defect, not an inference about it.

### F8, measured against the upstream binary

The same shape as F2, run in the same container image, with `scheme = https` and a certificate and
key that exist but are not usable.

| | upstream `v0.36.2` | `0.36.2-patched.1` |
|---|---|---|
| Exit code | **134** (`SIGABRT`) | 1 |
| `Shutdown complete` during that start | **0** | 3 |
| Last line of output | a panic backtrace note | `The TLS key <path> is not a usable PEM private key: no items found` |

### The rest of the class, in the startup and scheduler paths

After two review rounds each found one more post-`DB::init()` panic, the remaining sites in the
paths those two findings came from were enumerated rather than left to a third round.

The scope of that enumeration matters, and the fourth review round was right to push on how it
was first worded here. `panic = "abort"` is a workspace-wide profile setting, so *any* panic
anywhere aborts without running the shutdown, including one inside a request handler on a live
node. What follows covers the startup path and the long-running background tasks, which is where
F2, F7 and F8 lived. It does not cover the per-request surface in `src/api`, `src/service` and
`src/data`. That surface carries the same exposure in upstream `v0.36.2`, unchanged by this
release, and a spot check of it during review found the `unwrap`s guarded; auditing it in full is
a larger piece of work than this release, and it is listed as an unresolved limitation rather than
quietly implied to be done.

- `server.rs` and `tls.rs` have none left.
- `init_static_vars.rs`, `logging.rs` and `main.rs` panic in several places, and all of them run
  *before* `DB::init()` (lines 67 and 89 against 112 in `run()`), so nothing is at stake.
- `utils/stdin.rs` and `utils/gen_config.rs` belong to the `generate-config` and `hash-password`
  subcommands, which never start the storage layer.
- In the schedulers, which are the long-running tasks and therefore the F8 shape, two sites took
  operator-supplied cron expressions: those are F9. The rest are infallible by construction and
  were left alone: `Schedule::from_str` on hardcoded literals, `Version::parse(RAUTHY_VERSION)` on
  a compile-time constant that a unit test already parses, `get(pos)` immediately after
  `position()` returned `Some`, and `last()` immediately after `push()` (including the one at
  `backchannel_logout.rs:104`, where the `debug_assert!` above it documents exactly that).

The one remaining known hole is inside a dependency: `tls_hot_reload::load_server_config` panics
on material it cannot use, and a call site cannot catch that under `panic = "abort"`. F8's
pre-flight parse closes the reachable inputs; material that parses and is then rejected deeper
inside the library would still abort.

### Contracts traced that needed no change

- **Ownership refusal.** `hiqlite_wal::LogStore::start` takes a real `flock` before
  `StateMachineSqlite::new` runs, so a second process is refused before it can reach the
  `auto-heal` path that deletes the state-machine database. Verified with two real processes.
- **Error conversion.** `From<hiqlite::Error> for ErrorResponse` keeps each variant's `Display`
  text. No credential reaches it; the acceptance run asserts a failed database start does not echo
  the password.
- **Cache, counter, notification and session operations.** The package swap changes no API, so
  these are covered by the existing integration suite on both backends.

## 4. Dependency readiness

| Package | Wanted | Present in this candidate |
|---|---|---|
| `hiqlite` | `hiqlite-patched`, selected version | `hiqlite 0.14.0`, crates.io, `8711815c093414290a5fcbc0bf74e1e70e3d6ef37e21735000178d25cee6fcf0` |
| `hiqlite-wal` | `hiqlite-wal-patched`, selected version | `hiqlite-wal 0.14.0`, crates.io, `247fc29e082f38fdf25270f6a5d7148284c9710384c3bce21636608dc104fddf` |
| `hiqlite-derive` | `hiqlite-derive-patched`, selected version | `hiqlite-derive 0.14.0`, crates.io, `262ec752546b183ecab006d9a34e2a0811a7141ad0b575cc68c7ac61f30de53e` |

The candidate resolves published registry packages only. There is **no** `[patch.crates-io]`
section, no path dependency and no git dependency in this tree: upstream `v0.36.2` ships that
section commented out and it stays that way, so nothing can silently keep selecting upstream git.

The patched packages **are not published**. Checked against the crates.io API and against
`bartekus/hiqlite`, which has no tags and no releases. Until they exist this release line cannot be
published: see section 7.

## 5. Compatibility

**API.** No change. Every route, request and response shape is upstream `v0.36.2`, except that
`/auth/v1/ready` gained a `503` response, which is what a readiness probe is for.

**Configuration.** No renames, no removals, no new required values. One behaviour change: a config
file that cannot be read now fails the start unless it is the default `./config.toml` and simply
absent. A deployment that passes an explicit `--config-file` pointing at a file that does not exist
was already broken and now says so.

**Database.** No schema change and no migration. This build stamps `0.36.2-patched.1` into the
`config` table's `db_version` row.

**Upgrade path.** Upstream `v0.36.2` -> `0.36.2-patched.1`, in place, on the existing data
directory. No export, no downtime beyond the restart. Exercised end to end against the real
upstream binary taken from its own published image.

**Recovery path.** Unchanged: hiqlite's `HQL_BACKUP_RESTORE` into a fresh data directory. The
restore keeps the original signing keys, so tokens and sessions issued before the backup remain
verifiable.

**Rollback.** Upstream `v0.36.2` starts again on a data directory this build has written.
`LOWEST_COMPATIBLE_VERSION` in `v0.36.2` is `0.35.0` and `0.36.2-patched.1 > 0.35.0`, so the
stamped version locks nothing out. Covered by a unit test and by the acceptance run.

**Not supported.** Mixed-version deployment of this build with any other Rauthy version in one raft
cluster. Downgrade to anything below `v0.36.2`. Multi-node topologies: this release is qualified at
N = 1 only, and single-node results say nothing about N = 3.

## 6. Acceptance matrix

`assets/release/acceptance.sh` runs the process-level legs against the release binary; the cargo
suites run against a live backend on both database backends. Every repair maps to a test.

Run it by hand with `assets/release/acceptance.sh <rauthy> [<upstream-rauthy>]`. The second binary
enables the upgrade and rollback legs and is expected to be the upstream release this build is
based on, taken out of its own published image; without it those two legs report as skipped rather
than quietly passing. Each scenario gets its own data directory and its own ports, so a failure
leaves its logs behind to read.

Result on the candidate's own artefacts: the whole harness passes with **zero failures and zero
skips** on `linux/amd64` and on `linux/arm64`, each on its own native runner, alongside both
integration suites and the style checks. Every run prints its own assertion count, which grows as
legs are added, so the count is read off the run rather than copied here. The upgrade and rollback
legs run against the real upstream `v0.36.2` binary taken out of `ghcr.io/sebadob/rauthy:0.36.2`,
not a rebuild of it.

| Requirement | Test | Covers |
|---|---|---|
| First boot, valid config | acceptance A, B | identity, readiness, health, JWKS |
| Missing / malformed / conflicting config | acceptance C | F4, and F9: an invalid cron is refused before the storage layer starts at all |
| Listener bind failure with complete cleanup | acceptance D | F2 |
| Two processes, one data directory | acceptance E | ownership refusal, first node unharmed |
| Shutdown, restart, storage recovery | acceptance F | F2, signing-key continuity |
| Login, session, logout, protected routes | `handler_auth`, `handler_users`, `handler_sessions` | both backends |
| Native public client, refresh timing, revocation, bearer-protected writes | `handler_auth::test_token_revocation`, `test_password_flow`, `test_dpop`, `test_client_credentials_flow`, `handler_api_keys` | both backends |
| Device grant (RFC 8628), including its negative cases | `handler_auth::test_device_code_flow` | **new in this release**, both backends |
| Audience and scope enforcement, negative cases | `zzf_handler_resource_indicators`, `zzg_handler_token_exchange`, `handler_scopes` | both backends |
| Fresh backups, rapid repeated requests | `handler_generic::test_backup_download_is_complete` | F1 end to end: the declared `Content-Length`, the received length, and the listing's size must all agree |
| Backup read failure reaches the client | `api::backup::tests` | F1 directly |
| Restore into fresh storage, identity and key continuity | acceptance G | restore correctness |
| Invalid / truncated / missing restore input | acceptance G | refusal without destroying the last recoverable state |
| Observable unavailability after storage failure | acceptance K | F3, with real failure injection |
| Upgrade from the upstream baseline | acceptance J | in-place upgrade and rollback |
| Release identity and version parsing | acceptance A, `db_version::tests` | `--version`, marker handling, rollback safety |
| Identity survives restore and upgrade | acceptance B, G, J | the bootstrapped credential authenticates and the original admin is readable, on a first boot, after a restore, and after an upgrade |
| A metrics listener that cannot start | acceptance L | F7: the failure is an error, not an abort, and the data directory stays clean |
| Serving HTTPS, with generated and with unusable TLS material | acceptance M | F8: the generated path comes up and serves over TLS; unusable material is an error that names the file, and the data directory stays clean |

### Legs not covered, and why

- **Passkey-only backup administrator with MFA enabled.** This is a consumer-side configuration
  (`rahi` spec 037): rauthy enforces it through `ADMIN_FORCE_MFA` and the admin-session check on
  the backup routes, neither of which this release changes. Verifying the flow end to end needs a
  WebAuthn authenticator and the consumer's own harness. **No rauthy change was made for it**, per
  the rule that a change needs an actual failing requirement behind it.
- **Terminal Hiqlite storage failure injected from outside the process.** Acceptance K injects a
  real storage failure on the Postgres backend, where stopping the database is deterministic. The
  Hiqlite backend has no equivalent external injection point; that leg lands in Hiqlite's own
  repaired append-completion path, which is the other session's scope.
- **A backup download cancelled by the client.** The consumer takes its backups under a deadline
  and can abandon a download. The code path is there and is the one silent exit `pump_reader`
  keeps: a send into a closed channel ends the pump, because the client already knows it did not
  get the file. It is not separately asserted, because provoking a mid-download hang-up through
  the real handler needs a client that can be made to stop reading at a chosen byte, which this
  suite has no way to build. The suppression window and the snapshot naming that the consumer's
  deadline logic actually reads are hiqlite's, not rauthy's; section 7 lists them as things to
  re-check when the packages are swapped.
- **N = 3.** Not attempted. Not claimed.
- **Bit-for-bit reproducibility.** Not claimed and not verified. `src/common/build.rs` stamps
  `BUILD_TIME` from the wall clock, so two builds of the same tree differ by construction.

## 7. Publication status

**Held.** The one remaining requirement is the published patched Hiqlite.

The final release must resolve published registry packages, and `hiqlite-patched`,
`hiqlite-wal-patched` and `hiqlite-derive-patched` do not exist on crates.io. Everything else is
ready: the tree, the fixes, the acceptance harness, and both workflows.

When the packages are published, the change to this tree is confined to `Cargo.toml` and
`Cargo.lock`:

```toml
hiqlite = { package = "hiqlite-patched", version = "<selected>", features = [
    "cache", "cast_ints", "counters", "dashboard", "listen_notify_local", "macros"
] }
```

with the matching `package` aliases for `hiqlite-wal` and `hiqlite-derive` where they appear as
direct dependencies inside the patched `hiqlite` package itself.

**The alias mechanism was verified, provisionally.** In an isolated scratch checkout, the repaired
Hiqlite tree was renamed to the three `-patched` package names, its internal dependencies aliased
back, and this candidate pointed at it through `hiqlite = { package = "hiqlite-patched", ... }`:

- `cargo check --workspace --all-targets` compiles clean with **no source change**. Not one `use
  hiqlite::...` has to move, and the derive macros keep resolving, because the alias restores the
  name `hiqlite` inside the consuming crate, which is what the generated `::hiqlite` paths need.
- `cargo tree` and `cargo metadata` resolve exactly three packages matching `hiqlite*`:
  `hiqlite-patched`, `hiqlite-wal-patched` and `hiqlite-derive-patched`. No upstream `hiqlite`
  copy survives anywhere in the graph.

That result is **provisional**: it used a local path to a rename of the repaired tree, not the
published packages, and the published versions and their contents may differ. It de-risks the
mechanism; it does not qualify a release.

After the real swap:

1. `cargo tree -i hiqlite-patched` and `cargo metadata` must again show the patched packages
   selected for every storage path, with no second upstream copy in the graph. The publish
   workflow enforces this on its own: it refuses to run if any package matching `hiqlite*`
   resolves to anything but a registry, or if `Cargo.toml` still carries an active
   `[patch.crates-io]` entry for one. That guard was exercised against the path-based experiment
   above, which it correctly refuses.
2. Re-run the full candidate workflow. The dependency changed, so every earlier result is void.
3. Re-check the two hiqlite contracts the consumer's backup verb reads rather than calls: the
   snapshot file name (`backup_node_<id>_<seconds>.sqlite`, whose timestamp the consumer parses)
   and the window during which a fresh backup request is suppressed. Neither is a rauthy API, so
   nothing in rauthy's own suite would notice them changing.
4. Publish from the run that tested the new graph.

Note for whoever does the swap: `.cargo/config.toml` sets `global-min-publish-age = '10 days'`
under `[unstable]`. It is only honoured by nightly cargo, and this release builds on stable
`1.95.0`, so a freshly published package is not blocked. A `just update` run on nightly inside that
window would be.

## 8. Publication design

Two workflows, and neither shares a credential with the other's job.

- `release-candidate.yaml` builds the frontend and wasm once, runs style and unit checks, runs the
  integration suite on both backends, builds the release binary per architecture inside a
  `rust:1.95.0-bookworm` container, and runs the acceptance harness against those binaries on
  native runners for both architectures. Every job declares `contents: read` and nothing else, and
  no job references a registry token.
- `release-review.yaml` is the independent review, and it is a separate file for an empirical
  reason: `claude-code-action` refuses a `push` event outright ("Unsupported event type: push"),
  which the first candidate run established rather than assumed. It therefore hangs off the pull
  request that opens the release line. It is `pull_request`, never `pull_request_target`, so a
  fork's code gets no secrets and a read-only token. The job holds `contents: read` and
  `pull-requests: write`, and no publication credential.
- `release-publish.yaml` builds no code. It takes the binaries a named candidate run produced,
  verifies them against their recorded checksums, packages them, pushes the multi-architecture
  image, attests it, pulls it back by digest, compares the shipped binary against the tested bytes,
  and only then creates the release. It refuses to run if the tag already exists in the registry
  and refuses if the version asked for does not match `Cargo.toml`.

The bookworm build container is not cosmetic: it puts a glibc floor under the artifact that the
consumer's runtime can meet. Measured on the candidate binaries: both require at most
`GLIBC_2.34`, and `debian:bookworm-slim` provides 2.36. Building on the runner's own glibc (2.39
on `ubuntu-24.04`) would raise that floor above what `distroless/cc-debian12` and the consumer's
`debian:bookworm-slim` runtime provide, and the binary would not run where it has to.

The consumer's consumption pattern was exercised directly against the candidate binaries, in an
isolated workspace and without touching the consumer's checkout: the image was built from them,
`/app/rauthy` copied out of it into `debian:bookworm-slim` exactly as `rahi`'s Dockerfile does,
and the result runs and reports `rauthy 0.36.2-patched.1`. The image labels were read back off the
built image and carry upstream's authorship and licence alongside the downstream source, vendor
and upstream-base labels.

`CARGO_REGISTRY_TOKEN` is present as a repository secret and is referenced by no workflow. This
release publishes binaries and an OCI image; it publishes no Rust package, so it needs no crates.io
credential. A cargo token would not grant GHCR permission in any case.

## 9. Independent review

`release-review.yaml` reviewed the candidate against `v0.36.2`. Its verdict was that nothing found
should block the release, with one concrete defect: the residual `panic = "abort"` exit paths in
`server_with_metrics()` described as F7 above, which it correctly identified as contradicting F2's
own claim rather than as a separate issue. The review also verified, by inspection rather than by
taking this ledger's word for it, that `[patch.crates-io]` is commented out, that all three
Hiqlite packages resolve to crates.io with the checksums section 4 lists, that no workflow
references `CARGO_REGISTRY_TOKEN`, and that the review workflow's `pull_request` trigger is the
safe one.

F7 was fixed rather than added to the disclosed limitations, and acceptance leg L was added to
hold it: the release now proves that exit path the same way it proves the listener one, instead of
asserting it.

The second round reviewed the tree with F7 in it and returned a blocking verdict on F8, the TLS
load and renewal paths. It was right, including about the reason it had gone unnoticed: the
acceptance config served plain HTTP throughout, so section 6's table claimed a defect class it did
not actually cover for TLS. F8 is fixed and acceptance leg M closes that hole. The same round also
noted that the new S3 error branch put a raw object-store error into the response body, bypassing
the conversion this ledger vetted for credential safety; the cause now goes to the log and the
client gets a message without it.

The pattern across both rounds is worth naming: each time, the review found a place where this
ledger claimed more completeness than the code had. That is the failure mode a release document
invites, and it is why the review reads the ledger as well as the diff.

Two earlier review attempts are part of the record because both failed in ways worth keeping:

- The first refused to run at all (`Unsupported event type: push`), which is why the review lives
  in its own `pull_request`-triggered workflow.
- The second ran to completion and left nothing behind: no comment, no job summary, and an
  execution log that stays on the runner. A review that evaporates is indistinguishable from an
  approval, so the workflow now extracts the verdict from the execution log itself and publishes
  it, rather than asking the reviewer to remember to.

## 10. Upstream return path and maintenance

F1 through F4 and F7 through F9 are defects in upstream `v0.36.2` and are candidates for upstream pull requests
against upstream's development line, where the same code paths are unchanged. That is a separate
piece of work in the upstream repository and nothing in this release touches it.

`CHANGELOG.md` is deliberately untouched. It is upstream's record of upstream's releases, and
editing it here would put downstream entries in the way of every future rebase onto a new upstream
patch release. This ledger is this distribution's changelog.

Downstream security maintenance: this line tracks upstream `v0.36.x`. An upstream patch release
becomes `0.36.<z>-patched.1` on a new `release/` branch cut from that tag, with this ledger and the
acceptance matrix re-run in full. Patch levels within one base increment: `-patched.2` and onward.
Published tags never move.
