# Producer responses: Rahi R-1 to R-5, Hiqlite's N3 items 1 to 7, and the repaired-image plan

Answers from the Rauthy patched line (`patched/0.36.2`) to Rahi's
`docs/design/04-patched-adoption-producer-requests.md` (version 2, rahi `c2c7c72`) and Hiqlite's
`standards/spec/n3-rauthy-request.md` (hiqlite `8e4ec4b`, and its third pass at `7c64b8a`).
Written 2026-09-23; the repaired-image section and the owner decisions revised 2026-09-24 after
the candidate integration. Each answer says
whether it is implemented, locally tested, released, or a proposal. Nothing here is released:
the work is on the unpublished branch `work/0.36.2-patched.3`, the candidate integration on the
unpublished branch `integ/0.36.2-patched.3-hq035`, and publication needs its own approval.

## Rahi's requests

**R-1, terminal-storage signal: implemented, locally tested, not released.** `GET /auth/v1/health`
gains `storage`: `ok`, `degraded`, `terminal` or `unknown` (source: `src/api/src/generic.rs`,
`get_health`; `src/data/src/events/health_watch.rs`, `storage_terminal`).

- `terminal` is Hiqlite's own lifecycle record, `Client::node_failure()`: set once, never
  cleared, read without a storage operation. It is answered before anything else, so it holds
  inside `HEALTH_CHECK_DELAY_SECS`, and it is read again after a check.
- `degraded` is a failed check with nothing terminal recorded. An unreachable Postgres is always
  `degraded`.
- `unknown` is an answer inside the window, where nothing is checked and `db_healthy` and
  `cache_healthy` stay `true` for compatibility.
- Existing fields and status codes are unchanged, except that a terminal node answers `500`
  inside the window where it answered `200`. The endpoint stays unauthenticated; the body holds
  the enum only.

Acceptance legs K, P and the new U assert every step R-1 lists, with the recoverable fault being
a real Postgres outage and recovery (the embedded node has no recoverable storage fault to inject
from outside at N=1). Evidence and limits: `RELEASE-LEDGER.md` section 11.

**R-2, cache-only state: answered from source.** `RELEASE-STATE-INVENTORY.md`, read at `513bcc98`.
It corrects one premise: a plain restart of a release build loses none of the cache-only items
on a disk-backed cache (only `Html` and `App` are cleared). They are new losses at the upgrade.

**R-3, release assets: verified, closed.** Anonymous reads at 2026-09-23T20:38:05Z:

- The release (id `394484695`) lists all eight assets. GitHub's recorded digests match the
  anonymously downloaded bytes, and the handoff, ledger and licence assets are byte-identical to
  the tagged tree `17132b94`.
- The tag `v0.36.2-patched.2` points to `17132b9451912cf45d33c99990f21678b75e2e26`, the commit
  `RELEASE-PROVENANCE.md` names.
- An anonymous registry token resolves the tag to index
  `sha256:ea114a8bb743d578dea6d7800916ee43550939c749a2cf586f9abdc0d0c52478`; the downloaded
  bytes hash to it. It lists `linux/amd64`
  `sha256:6774d28c9f611777dc4ad2243a8f4cb1fa0df3d94caca1aeaf052cc10d9e5658` and `linux/arm64`
  `sha256:6ae9225a9243a7e660f6c407d07f81258d06f456470dfb4b6c899a6db13146f8` plus two
  attestation manifests; each platform manifest hashes to its digest.
- `/app/rauthy` from the image with that index digest hashes to
  `742b18ba3717a92577a2ae0d517546a64ef6967c86e2847b50b10a22ab8dfc59` (amd64) and
  `5e498c31ef23ebc27a6d2dbdbf73f6d6f48129f541fced92d48a53b87d61e312` (arm64), equal to
  `SHA256SUMS`; each prints `rauthy 0.36.2-patched.2` (amd64 under emulation). The image was the
  local copy pulled earlier by that digest; content addressing ties it to the registry's.
- `v0.36.2-patched.3` exists as no git tag, no release and no image tag.

**R-4, an older Rauthy on an upgraded directory: route 2 taken, route 1 not attempted.** The
handoff now states the unsupported-downgrade boundary (`RELEASE-HANDOFF.md`, correction C-4):
upstream `v0.36.2` on a directory any patched build has written is unsupported, the pre-upgrade
archive restored into a fresh volume is the only way back, and a manual move-aside is not shown
safe. A check inside the patched build was not added: the old image never runs it. A layout
fence would need a Hiqlite layout change and a demonstration against the real upstream image on
both architectures; it is not proposed for the N1 repair image.

**R-5, DPoP nonce: confirmed, fixed locally, not released.** `DPoPNonce::is_valid` accepted any
nonce for which the cache lookup did not fail, including one never issued, and also the fixed
key `latest`. Every caller (password, client credentials, authorization code, token exchange, and
the DPoP-bound refresh path) reaches it through `DPoPProof::validate_nonce`; none checks the nonce
independently. With the default `DPOP_FORCE_NONCE=true` the token endpoint answered `200` with a
token to a proof carrying a made-up nonce; measured against a local backend, before and after the
fix. Signature, `htm`, `htu` and the 60-second `iat` window were still enforced, which bounds what
the nonce was meant to add. No severity is assigned here. The fix and its tests are one commit;
disclosure wording is an owner decision (section "Owner decisions").

## Hiqlite's N3 request

| # | item | state | answer |
|---|---|---|---|
| 1 | tombstone before storage opens | contract | below |
| 2 | background-writer inventory and hold | inventory done; hold is a contract | `RELEASE-STATE-INVENTORY.md` section 8, and below |
| 3 | authenticated barrier access | contract, gated on Hiqlite 034 B-6 | below |
| 4 | restore-time invalidation | proposal | `RELEASE-STATE-INVENTORY.md` section 4 |
| 5 | manual IP ban export and import | answered | the existing API suffices; no provenance exists (inventory section 6) |
| 6 | confirmed cache inventory | answered | `RELEASE-STATE-INVENTORY.md` sections 1 and 2; the premise about restarts is corrected there |
| 7 | rebuild on a release carrying 035 | candidate integration, locally tested | below; not published, not qualified |

**N3-1, tombstone (contract, not implemented).** Checked in `rauthy`'s own startup, before
`DB::init` and before anything creates the data directory, so every entry path meets it: the image
entrypoint (which is the binary), a direct invocation, and a debugging container on the volume
that runs the binary. If `<HQL_DATA_DIR>/<name>` exists, exit non-zero naming the migration id it
contains, and change nothing. The file name and format are Rahi's to define and must be fixed
before implementation. The check cannot protect against a binary that predates it; a published
image without it must be named as unprotected.

**N3-2, background-writer hold (contract, not implemented).** A setting read at start,
`SCHEDULERS_HOLD=true`, under which `schedulers::spawn` starts no task until an authenticated
admin call releases them, logged at both ends. Tasks that change user rows (`magic_link_cleanup`,
`user_expiry_checker`) are never disposable and must be held; the pure expiry deletes are
disposable only with agreeing clocks.

**N3-3, barrier (contract, gated).** Only if Hiqlite ships 034 B-6 and the owner adopts D-12: an
admin-only endpoint that commits a Hiqlite barrier with a caller nonce through Rauthy's client
and returns the committed log id. It proves the exported state as of that commit; it does not
prove that nothing acknowledged earlier was lost, and it is not a transaction across stores.

These three are separate changes from the N1 repair image and from each other; none belongs in
the image that adopts the repaired Hiqlite.

## The repaired Hiqlite (A1, 035) and the N1 repair image

**State: candidate integration, locally tested on Linux arm64 only.** Not registry-published, not
qualified, not released. The earlier statement here, that the candidate existed only as
uncommitted work at `8e4ec4b`, is superseded.

**Three states, kept apart:**

| state | what it needs | where it stands |
|---|---|---|
| *candidate* | an exact Hiqlite commit; Rauthy built against it on an unpublished branch | **reached**: below |
| *registry-published* | the same code as `hiqlite-patched` on crates.io under a new version, re-resolved into a graph `check_graph.py` accepts | not reached: nothing published |
| *qualified* | the candidate workflow on that graph: strict acceptance on native amd64 and arm64, both integration suites, Rahi's suite, on the merge commit | not reached |

**Candidate identity.**

- Hiqlite commit `26e2fa0a15b8b94dcc0ef2b733f6cec70922f9df` (PR #37 as handed over; tree
  `00a27200`), repair `048fcecd5bdab7d4d12b2207b69f46bf31aa9c99`. After PR #37 was rebased onto
  Hiqlite `main`, its head is `7c64b8a` (2026-09-24T00:33Z): the `hiqlite/`, `hiqlite-wal/`,
  `hiqlite-derive/` trees, `Cargo.toml` and `Cargo.lock` are identical at all three commits;
  later commits change documentation only. GitHub serves `26e2fa0a` by id, although no branch
  holds it any more.
- The candidate still calls itself `0.15.0-patched.1`, the published version. Only the lock
  file's `source` line distinguishes it. Its registry release must carry a new version, or a
  registry graph cannot tell the two apart.
- Rauthy: branch `integ/0.36.2-patched.3-hq035` (local, never to be pushed or merged), from the
  reviewed head `51e73280`. Commit `004d537f` changes only the workspace dependency to
  `git = "https://github.com/bartekus/hiqlite.git", rev = "26e2fa0a..."`; `Cargo.lock` changes
  only the three Hiqlite packages' `source` and `checksum` lines. `check_graph.py`: the shape
  check passes, the release check refuses (no registry checksum), as intended.
- Resolved features: `hiqlite-patched` `default` (`auto-heal`, `backup`, `sqlite`, `toml`) plus
  `cache`, `cast_ints`, `counters`, `dashboard`, `listen_notify_local`, `macros`;
  `hiqlite-wal-patched` `auto-heal`. `__upgrade-fault-points` is **not** in the candidate. The
  test build adds it and nothing else (one line in the workspace manifest, built from a copy of
  the tree; never an image).

**Binaries** (native Linux arm64, `rust:1.95.0-bookworm`, rustc 1.95.0 `59807616e`, release
profile, `--locked`; build time 11 min 52 s and 13 min 0 s, separate from the run budget):

| binary | sha256 |
|---|---|
| candidate, `004d537f` | `fd745715883bfce2bb8d315f30dff880301ae2e718dfaffdb507b1cf1ff3e6ce` |
| candidate + `__upgrade-fault-points` | `ca3cf24eb740af41599367b49113267d908b5a5bf314ea038ea7632e51830331` |
| upstream `v0.36.2`, `/app/rauthy` from `ghcr.io/sebadob/rauthy@sha256:f7d3c501...` | `a9a5020839148fb0f10e59b4c7f2a7f1d813306ff5a0eea8e32f9d09f12e7d63` |
| published `0.36.2-patched.2` (Hiqlite `0.15.0-patched.1`), from index `sha256:ea114a8b...` | `5e498c31ef23ebc27a6d2dbdbf73f6d6f48129f541fced92d48a53b87d61e312` (equals `SHA256SUMS`) |

**Leg J, as run** (`assets/release/acceptance.sh` at `2468da7f`, leg J only, native Linux arm64
in Docker Desktop's VM, data directories on the container's own filesystem, strict, stopping at
the first failure, one pass, no retry, each case bounded by its own 60 to 120 s waits):

| run | binary | result | wall time |
|---|---|---|---|
| candidate, `J_EXPECT=repaired` | `fd745715`, fault build `ca3cf24e` | **94 passed, 0 failed, 0 skipped** | 2 min 25 s |
| negative control, `J_EXPECT=published` | `5e498c31` | 16 passed: 10 setup assertions and all 6 declared controls failed as expected | 2 min 39 s |

Total runtime 5 min 4 s against the 30 min allowance.

What the candidate run established, each against the real upstream binary:

- **J-A** without consent: refused (exit 1), naming `logs_cache` and the variable; the message
  says it created `hiqlite-owner.lock` and removed every WAL lock file it created; every other
  file byte-identical.
- **J-B, J-C** a live upstream node, with and without consent: refused with "lock.hql is locked
  by another live process" before any rename (no `pre-upgrade-*`, `logs_cache` inode unchanged);
  the upstream node went on writing, stopped with exit 0, restarted with every row and kept its
  manual IP ban across that plain restart.
- **J-D** upstream killed (`state_machine/lock` left): under `auto-heal` the start proceeded, the
  move completed once with the legacy cache byte-identical, the state machine was rebuilt (2
  unclean-stop messages, recorded) with every acknowledged row, users, clients and keys; the
  owner lock and both WAL locks were held while it served (non-blocking `flock` refused); clean
  stop.
- **J-E** the consent upgrade: one final `pre-upgrade-<secs>/`, legacy cache byte-identical,
  format marker `2`, keys, users, clients and upstream rows kept, no rebuild, the upstream
  node's manual IP ban **gone** (C-6), locks held while serving, both WAL lock files removed at a
  clean stop, a clean restart without consent.
- **J-F** each of `after-db-lock`, `after-cache-lock`, `after-partial-created`,
  `after-snapshots-moved`, `after-staged`, `after-legacy-log-moved`, `after-log-moved`: the fault
  build aborted there (exit 134); the next start without consent was refused naming the
  variable; the next with consent completed into one operation, nothing partial or staged,
  legacy cache byte-identical, identity and rows kept; clean stop.
- **J-G** the published build's interrupted rename state (constructed): refused without
  consent, finished with it into the same directory, identity and rows kept.
- **J-H** rollback: the pre-upgrade archive restored into a fresh volume and started by upstream
  has the archive's state, without what the upgraded node wrote; clean stop.
- **J-I**, recorded only: upstream over the upgraded directory was still running and reported
  healthy at 60 s in both runs, with both `meta.hql` at 32 bytes. Hiqlite's own run of this
  case aborted every time. One observation does not make a downgrade safe; C-4 stands.

The negative control, on the published build: J-A's message claimed "Nothing was changed."; in
J-B the published build aborted (exit 134), did not name the WAL lock and renamed the live
node's cache, after which the upstream node failed to stop cleanly (exit 134) and could not
restart (`InitializeError`), which is F-126; in J-C it refused on the legacy cache, not the
lock; in J-G it started without consent over the old snapshot. Recorded, not counted: in J-D,
J-E and J-C's other assertions the published build behaved as the candidate did.

**Limits of this evidence.** Linux arm64 only; native amd64 not run. A git-sourced graph, so it
cannot qualify anything. Leg J only: the other legs and the Rahi suite were not run on the
candidate. A process abort at a fault point, not a kernel crash or power loss. J-H failed in
the negative control, not on the published build's behaviour: J-G's unrefused start was killed
at 60 s and upstream's start a minute later panicked with `AddrInUse` on the raft port. The
harness now runs J-H before any case that kills a node (`ffb63777`); that order has not run.

**Integration suites on the candidate** (macOS arm64, debug): see ledger section 11.4.

## Owner decisions

1. **Next version: recommended, one combined `0.36.2-patched.3`.** The DPoP fix (F20), the
   `/health` storage signal (F21) and a rebuild on the repaired Hiqlite, once that is published
   under a new version. `0.36.2-patched.3` is unused (no tag, release or image tag). The earlier
   recommendation, ship `.3` now on the current Hiqlite and reserve `.4` for the repin, assumed no
   repaired Hiqlite source existed; one now exists and passes leg J on Linux arm64. What changed:
   - *Combined:* one full qualification (both native architectures, both suites, Rahi's suite)
     and one consumer repin; the upgrade hazards C-2 and C-5 close in the same release that ships
     the DPoP fix. It waits on the Hiqlite registry release and its own qualification.
   - *Independent DPoP release first:* available if the DPoP fix is judged urgent. It keeps the
     N1 upgrade defects of `0.15.0-patched.1` (C-2, C-5 stay open), and it costs a second full
     qualification and a second consumer repin when the repaired Hiqlite lands.
   No label is bumped until the owner selects one; the evidence for either is above and in
   ledger section 11.
2. **DPoP disclosure.** The defect is also on upstream `main` at `989f9ff9` and, from source, in
   every release since `v0.18.0`. Commit `40187dbe`'s message and ledger section 11.3 describe it,
   so pushing this branch, or any pull request containing it (a Draft included), discloses it.
   A private report for upstream's GitHub private vulnerability reporting is prepared outside
   this repository; sending it is the owner's act.
3. **Correction notice.** `RELEASE-CORRECTION-NOTICE-0.36.2-patched.2.md` is now self-contained
   (it no longer points at `patched/0.36.2`, whose public head `513bcc98` does not carry the
   corrections). Proposed operation: attach it to release `v0.36.2-patched.2` as a ninth asset,
   and append two sentences to the release notes pointing at it. The eight assets, the tag and
   the digests stay as they are. Needs approval to send.
4. **Restore invalidation.** `RELEASE-STATE-INVENTORY.md` section 4 now orders it by operation
   id and phase, so that neither a crash between the SQL and the cache step nor an earlier run's
   completion can let a restored instance serve. Implementation (restore command, migration,
   startup gate) waits for its own policy authorization.
5. **N3 items stay separate** from the N1 image and from each other: the tombstone (it cannot
   constrain a binary that predates it), the scheduler hold, and the barrier (per store; it cannot
   prove that nothing acknowledged earlier was lost).
6. **Manual IP bans.** Two separate choices. (a) An operator step using today's API: export the
   active bans with `GET /auth/v1/blacklist` before the upgrade and re-apply each with
   `POST /auth/v1/blacklist` after it; manual and automatic bans come out together, since nothing
   records which is which. (b) Accepting the loss of failed-login counters, which have no export.
   Neither needs a new data model.
