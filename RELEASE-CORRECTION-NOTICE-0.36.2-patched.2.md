# Correction notice: Rauthy 0.36.2-patched.2

Dated 2026-09-23. Prepared for the release `v0.36.2-patched.2` as an additional asset or an
addition to its release notes, **awaiting the owner's approval; not sent**. It changes none of
the release's existing assets, digests or the tag: the `RELEASE-HANDOFF.md` attached to the
release stays as published, and this notice says which of its statements no longer stand.

The image, binaries and checksums are unchanged and correct. Six statements in the attached
handoff are too strong. Current advice, in short (full text: `RELEASE-HANDOFF.md` on
`patched/0.36.2`, section "Corrections, 2026-09-23"):

1. **`/ready` answering `503` persistently is not a reason to restart.** It does not distinguish
   a Postgres outage or an election from a terminal storage failure.
2. **A live upstream Rauthy is not excluded.** Before the one start with
   `HQL_CACHE_LEGACY_MOVE_ASIDE=true`, the upstream container must be stopped and removed, and
   no process may hold `logs/lock.hql` or `logs_cache/lock.hql` in the data directory (check
   from the host's PID namespace, or with a non-blocking `flock` on each existing file). With it
   live, that start moves its cache and damages the directory. Set the variable for that one
   start only and remove it after its first `/ready`.
3. **The legacy-cache refusal, without the variable, is not side-effect free.** It creates `hiqlite-owner.lock` in the
   data directory, although its message says "Nothing was changed."
4. **Going back to upstream `v0.36.2`:** restore the archive taken before the upgrade into a fresh
   volume. Starting upstream on the upgraded directory is unsupported, with or without moving the
   cache by hand.
5. **If the first start with the variable ends before `logs_cache/hiqlite-cache-log-format`
   exists,** start nothing on the volume, with or without the variable; restore the pre-upgrade
   archive into a fresh volume and repeat. An interruption between the cache move's two renames
   is not shown recoverable.
6. **The upgrade loses more than a restart does.** A restart keeps the disk-backed cache; the
   upgrade empties it, including every IP ban (manual ones too), failed-login counters and
   in-flight logins. Sessions, refresh tokens and revocations are kept.
