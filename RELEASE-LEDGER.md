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
| F1 | `GET /auth/v1/backup/local/{file}` and `/backup/s3/{object}` ended the response body on a read error exactly as on EOF, under an already-sent `200`. | The consumer's backup verb takes rauthy's snapshot through these routes and checks only the status and a non-empty body, so a truncated SQLite file was sealed into an archive as a good backup. Now the stream fails and the client's read fails with it. |
| F2 | Any error return after `DB::init()` skipped `DB::hql().shutdown()`. A listener that could not bind returned straight out of `run()`. | The WAL lock stayed held and the state-machine lock file stayed in place, so the next start read the directory as an ungraceful shutdown. With hiqlite's default `auto-heal` feature, which Rauthy enables, that rebuilds the state machine from the raft log. The post-init `expect`/`unwrap` calls became errors for the same reason: `panic = "abort"` runs no cleanup. |
| F3 | `GET /auth/v1/ready` answered `200` unconditionally. | It is the documented readiness probe for Kubernetes and Docker. An orchestrator kept routing to a node whose storage was unreachable. It now answers `503` on the health watcher's confirmed verdict, debounced through the watcher's existing re-check so a leader change does not flap a node out of service. |
| F4 | A config file that could not be read was replaced by an empty config with only a `warn!`. | A mistyped `--config-file` surfaced as "Missing `encryption.keys`", which sends an operator to the wrong place. Configuring entirely through environment variables stays supported: an absent file at the *default* path is still only a warning. A path the operator named, or a file that exists and cannot be read, is now a startup failure that names itself. |
| F5 | `zzd_handler_clients::test_clients` compared a global client count across its body while its neighbours in the same test binary created and deleted clients concurrently. | A test defect, repaired rather than tolerated: it made the suite fail on an unrelated schedule. It now asserts about the clients it owns. |

Downstream identity, not a defect fix: the version marker, the startup log line naming distributor
and upstream base, the `patched.N` marker being recognised instead of warned about as an upstream
pre-release, and the image labels.

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

| Requirement | Test | Covers |
|---|---|---|
| First boot, valid config | acceptance A, B | identity, readiness, health, JWKS |
| Missing / malformed / conflicting config | acceptance C | F4 |
| Listener bind failure with complete cleanup | acceptance D | F2 |
| Two processes, one data directory | acceptance E | ownership refusal, first node unharmed |
| Shutdown, restart, storage recovery | acceptance F | F2, signing-key continuity |
| Login, session, logout, protected routes | `handler_auth`, `handler_users`, `handler_sessions` | both backends |
| Native public client, device grant, refresh timing, revocation, bearer writes | `handler_auth::test_token_revocation`, `test_password_flow`, `test_dpop`, `test_client_credentials_flow`, `handler_api_keys` | both backends |
| Audience and scope enforcement, negative cases | `zzf_handler_resource_indicators`, `zzg_handler_token_exchange`, `handler_scopes` | both backends |
| Fresh backups, rapid repeated requests | `handler_generic::test_backup_download_is_complete` | F1 end to end, length against the listing |
| Backup read failure reaches the client | `api::backup::tests` | F1 directly |
| Restore into fresh storage, identity and key continuity | acceptance G | restore correctness |
| Invalid / truncated / missing restore input | acceptance G | refusal without destroying the last recoverable state |
| Observable unavailability after storage failure | acceptance K | F3, with real failure injection |
| Upgrade from the upstream baseline | acceptance J | in-place upgrade and rollback |
| Release identity and version parsing | acceptance A, `db_version::tests` | `--version`, marker handling, rollback safety |

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
   selected for every storage path, with no second upstream copy in the graph.
2. Re-run the full candidate workflow. The dependency changed, so every earlier result is void.
3. Publish from the run that tested the new graph.

Note for whoever does the swap: `.cargo/config.toml` sets `global-min-publish-age = '10 days'`
under `[unstable]`. It is only honoured by nightly cargo, and this release builds on stable
`1.95.0`, so a freshly published package is not blocked. A `just update` run on nightly inside that
window would be.

## 8. Publication design

Two workflows, and neither shares a credential with the other's job.

- `release-candidate.yaml` builds the frontend and wasm once, runs style and unit checks, runs the
  integration suite on both backends, builds the release binary per architecture inside a
  `rust:1.95.0-bookworm` container, runs the acceptance harness against those binaries on native
  runners for both architectures, and runs the independent review. Every job declares
  `contents: read`; the review job adds `pull-requests: write` and nothing else. No job references
  a registry token, and the review is deliberately not wired to `pull_request_target`.
- `release-publish.yaml` builds no code. It takes the binaries a named candidate run produced,
  verifies them against their recorded checksums, packages them, pushes the multi-architecture
  image, attests it, pulls it back by digest, compares the shipped binary against the tested bytes,
  and only then creates the release. It refuses to run if the tag already exists in the registry
  and refuses if the version asked for does not match `Cargo.toml`.

The bookworm build container is not cosmetic: it puts a glibc 2.36 floor under the artifact.
Building on the runner's own glibc would raise that floor above what `distroless/cc-debian12` and
the consumer's `debian:bookworm-slim` runtime provide, and the binary would not run where it has
to.

`CARGO_REGISTRY_TOKEN` is present as a repository secret and is referenced by no workflow. This
release publishes binaries and an OCI image; it publishes no Rust package, so it needs no crates.io
credential. A cargo token would not grant GHCR permission in any case.

## 9. Upstream return path and maintenance

F1 through F4 are defects in upstream `v0.36.2` and are candidates for upstream pull requests
against upstream's development line, where the same code paths are unchanged. That is a separate
piece of work in the upstream repository and nothing in this release touches it.

Downstream security maintenance: this line tracks upstream `v0.36.x`. An upstream patch release
becomes `0.36.<z>-patched.1` on a new `release/` branch cut from that tag, with this ledger and the
acceptance matrix re-run in full. Patch levels within one base increment: `-patched.2` and onward.
Published tags never move.
