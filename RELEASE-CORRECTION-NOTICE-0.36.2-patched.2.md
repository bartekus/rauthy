# Correction notice: Rauthy 0.36.2-patched.2

Dated 2026-09-23. This notice is self-contained. It adds to the release `v0.36.2-patched.2`
(tag at `17132b9451912cf45d33c99990f21678b75e2e26`) and replaces none of its assets. The image
`ghcr.io/bartekus/rauthy-patched:0.36.2-patched.2@sha256:ea114a8bb743d578dea6d7800916ee43550939c749a2cf586f9abdc0d0c52478`,
the binaries and `SHA256SUMS` are unchanged and correct.

Six statements in the attached `RELEASE-HANDOFF.md` are too strong. Where they conflict, follow
this notice.

1. **`/ready` answering `503` persistently is not a reason to restart.** `/ready` answers `503`
   for any unconfirmed storage sample: a Postgres outage, a slow Raft election, or a terminal
   failure of the embedded node. Only the last needs a restart, and `503` does not say which. In
   this release the only terminal indications are the log line naming the node "out of service"
   and a `500` saying "The storage layer of this node is out of service" on requests that touch
   storage. The handoff's "treat a persistent `503` from `/ready` as restart this cell" is
   withdrawn.
2. **A live upstream Rauthy on the same directory is not excluded.** `StorageInUse` comes from a
   lock only patched builds take; upstream `v0.36.2` holds only its WAL locks. With
   `HQL_CACHE_LEGACY_MOVE_ASIDE=true` set and an upstream node live on the directory, this
   release moves that node's cache aside before it fails, and the directory then needs manual
   repair. Before the one start with the variable:
   1. stop **and remove** the upstream container, so no restart policy can bring it back;
   2. make sure no process holds `<data_dir>/logs/lock.hql` or `<data_dir>/logs_cache/lock.hql`.
      `fuser` and `lsof` see only their own PID namespace: run them on the host, or in a
      container started with `--pid=host`. Alternatively take a non-blocking `flock` on each
      file from any container on the same host, which is authoritative. Check that the file
      exists first: `flock(1)` creates a missing file, and the next start reads a `lock.hql` it
      did not expect as an unclean stop;
   3. start exactly once with the variable, from a supervisor that cannot start the old image on
      the same volume at the same time, and remove the variable after that start's first `200`
      from `/ready`. A variable left set lets every later start move a legacy cache it finds
      without an operator's decision.
3. **The refusal without the variable is not side-effect free.** Its message ends "Nothing was
   changed.", but it has created `<data_dir>/hiqlite-owner.lock` (and the data directory, if it
   was absent). No data file is moved or written. With the variable set and a live upstream
   node, see item 2.
4. **Going back to upstream `v0.36.2`:** stop upstream Rauthy and archive the whole data
   directory **before** upgrading. To go back, restore that archive into a fresh volume and start
   upstream there; everything written after the upgrade is then lost. Starting upstream on a
   directory this release has written is unsupported, with or without moving the cache by hand:
   in Hiqlite's own probes, Hiqlite 0.14 over a cache written by this release's Hiqlite panicked
   every time and in some runs left Raft metadata torn, and a manual move before the start has
   not been shown safe.
5. **An interrupted first start.** If the first start with the variable ends (crash, kill, out
   of memory, power loss) before `<data_dir>/logs_cache/hiqlite-cache-log-format` exists, start
   nothing on that volume, with or without the variable: the next start can restore an old cache
   snapshot without refusing. Restore the pre-upgrade archive into a fresh volume and repeat the
   upgrade.
6. **The upgrade loses more than a restart.** A plain restart keeps the disk-backed cache (only
   the `Html` and `App` caches are cleared). The upgrade empties it: in-flight authorization and
   device codes, WebAuthn and proof-of-work challenges, DPoP nonces, upstream-provider and ATProto
   login state, PAM tokens, **every IP ban, manual ones included**, failed-login counters,
   credential-stuffing windows, rate limits, and the grace entry that keeps a just-rotated client
   secret valid. Sessions, refresh tokens and token revocations are in the database and are kept.
   Active IP bans can be carried across with the existing API: `GET /auth/v1/blacklist` before the
   upgrade, and `POST /auth/v1/blacklist` with the same address and expiry for each after it.
