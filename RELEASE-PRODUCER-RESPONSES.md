# Producer responses: Rahi R-1 to R-5, Hiqlite's N3 items 1 to 7, and the repaired-image plan

Answers from the Rauthy patched line (`patched/0.36.2`) to Rahi's
`docs/design/04-patched-adoption-producer-requests.md` (version 2, rahi `c2c7c72`) and Hiqlite's
`standards/spec/n3-rauthy-request.md` (hiqlite `8e4ec4b`). Written 2026-09-23. Each answer says
whether it is implemented, locally tested, released, or a proposal. Nothing here is released:
the work is on the unpublished branch `work/0.36.2-patched.3`, and publication needs its own
approval.

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
| 7 | rebuild on a release carrying 035 | blocked | no candidate exists; plan below |

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

**State.** Hiqlite 035 is a contract at `8e4ec4b` with implementation pending; no candidate source,
branch or interface exists on any ref (checked 2026-09-23). Nothing below has run.

**Evidence states, kept apart:**

1. *candidate*: an exact Hiqlite commit and interface handoff; Rauthy built against it with a git
   dependency on an unpublished integration branch only, never merged and never released;
2. *published*: the same code as `hiqlite-patched` on crates.io, re-resolved into a
   registry-only graph that `assets/release/check_graph.py` accepts;
3. *qualified*: the candidate workflow's strict acceptance on native amd64 and arm64 on that
   graph, plus Rahi's suite, on the merge commit.

**Leg J additions, against the real upstream `v0.36.2` binary** (each assertion must be observed
failing on `0.15.0-patched.1` before it counts):

- live upstream process, then a consent start: refused before any rename; the upstream node keeps
  serving, stops cleanly and restarts; only `hiqlite-owner.lock` added;
- upstream killed, leaving `state_machine/lock`: refused as an error, no move, `logs/` unchanged;
- a crash between the two renames (a test-build fault point, or `SIGKILL` timed by Hiqlite's own
  hook): the next start completes the move or refuses, and never restores a 0.14 snapshot;
- a successful upgrade keeps SQL rows, users, clients and signing keys (as leg J does today);
- the cache is empty after it (auth codes, bans and counters gone), as the handoff states;
- upstream started over the upgraded directory: **recorded, not passed or failed**, since no
  Hiqlite contract makes it safe (035 X-7); the handoff keeps route 2 of R-4;
- rollback by restoring the pre-upgrade archive into a fresh volume and running upstream there.

A startup check in the new build proves nothing about an old executable; no assertion of that
kind is planned.

## Owner decisions

1. **Next version.** `0.36.2-patched.3` is unused (no tag, no release, no image). Recommended for
   the DPoP fix and R-1 on the current Hiqlite, now, because 035 has no implementation yet; the
   rebuild on a repaired Hiqlite becomes `patched.4`. The alternative is to hold both for one
   repin.
2. **DPoP disclosure.** The defect is also on upstream `main` at `989f9ff9`. A fork pull request,
   its commit message and the ledger entry would make it public. Recommended: report it to the
   upstream maintainer privately first, then publish with neutral wording.
3. **Correction notice.** `RELEASE-CORRECTION-NOTICE-0.36.2-patched.2.md` is ready to attach to
   the published release as an additional asset or add to its notes. The existing assets stay as
   they are. Needs approval to send.
4. **Restore invalidation, the tombstone, the scheduler hold, ban export.** Each needs its policy
   accepted before implementation.
