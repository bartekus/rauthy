# State inventory: what lives where, and what a cache loss or a stale restore does

For Rauthy `0.36.2-patched.2` and this line's next patch level. Answers Rahi's R-2 and Hiqlite's
N3 request items 4, 5 and 6. Read from source at `513bcc98` (the tree of `v0.36.2-patched.2` plus
documentation), with the embedded storage at `hiqlite-patched 0.15.0-patched.1` as published.
Nothing here was measured unless it says so. Functions are named, not line numbers.

## 1. The two storage layers

- **SQL** (Hiqlite's SQLite raft group, or Postgres): the authority for users, clients, sessions,
  refresh tokens, `issued_tokens` and its `revoked` column, signing keys (`jwks`), magic links,
  dynamic clients, ToS, API keys, events. A backup and a restore concern this layer only.
- **Cache** (Hiqlite's cache raft group, `Cache` in `src/data/src/database.rs`, 22 variants). It
  is used with the Postgres backend too. Disk-backed by default (`HQL_CACHE_STORAGE_DISK`, default
  `true`). A TTL is stored as an absolute expiry, so it survives a restart. Counters have no TTL.

What a whole-cache loss is, per event:

| event | cache | SQL |
|---|---|---|
| plain restart, release build | only `Html` and `App` cleared (`server.rs::run`); the rest survives on a disk-backed cache | unchanged |
| plain restart, `HQL_CACHE_STORAGE_DISK=false` | all lost | unchanged |
| upgrade from `v0.36.2` with `HQL_CACHE_LEGACY_MOVE_ASIDE=true` | all lost (moved to `pre-upgrade-<secs>/`) | unchanged |
| `HQL_BACKUP_RESTORE` into the **same** data directory | **kept**, and newer than the restored SQL | replaced by the backup (Hiqlite `backup.rs::finish_staged_restore` removes the SQLite raft logs, snapshots, the state-machine lock and the database's WAL files; nothing of the cache) |
| restore into a fresh volume, migration into a new cell | all lost | the backup's |

Debug builds clear 16 more variants at start; that is not the released behaviour.

## 2. Cache-only authority and cached copies

"Only here" means the cache is the only copy. "Copy" means a read-through or write-through copy
of SQL. Move-aside and a fresh-volume restore lose every "only here" item.

| state | source | layer | TTL | a stale in-place restore | loss means |
|---|---|---|---|---|---|
| authorization codes, ToS-await codes | `auth_codes.rs::AuthCode::save`, `AuthCodeToSAwait::save` | only here | client code lifetime; ToS accept timeout | codes outlive the SQL they refer to | logins in progress restart |
| device codes (RFC 8628) | `devices.rs::DeviceAuthCode::save` | only here (issued devices are SQL `devices`) | device code lifetime | kept | pending device logins restart |
| WebAuthn registration and login challenges, login and service requests, MFA-modification tokens | `webauthn.rs::reg_start`, `WebauthnData::save`, `WebauthnLoginReq::save`, `WebauthnServiceReq::save`; `mfa_mod_token.rs::MfaModToken::new` | only here | `webauthn.req_exp`, `webauthn.data_exp`, 121 s | kept | the step restarts |
| passkey lists | `webauthn.rs::PasskeyEntity::find*` | copy | `webauthn.req_exp` | stale for that long | none |
| PoW challenges (anti-replay) | `pow.rs::PowEntity::create`, `check_prevent_reuse` | only here | `pow.exp` | kept | a solved challenge is refused, the form resubmits |
| DPoP nonces | `dpop_proof.rs::DPoPNonce::new_value` | only here | `dpop.nonce_exp` | kept | clients receive a new nonce challenge |
| IP bans: automatic and **manual** | `ip_blacklist.rs::IpBlacklist::put`; writers `api/blacklist.rs::post_blacklist` (manual), `login_delay.rs`, `cred_stuff_detect.rs`, `generic.rs::catch_all` | only here | the ban's own `exp` | kept | **every banned address is let back in** |
| failed-login counters | `failed_login_counter.rs::FailedLoginCounter` | only here (a counter) | none; reset by a successful login from that address | kept | the escalation ladder restarts at 0 |
| credential-stuffing windows | `cred_stuff_detect.rs::CredStuffDetect::handle_trigger` | only here | `cred_stuff_detect.scan_window` | kept | detection window restarts |
| device-grant and dynamic-registration rate limits | `ip_rate_limit.rs::DeviceIpRateLimit`, `clients_dyn.rs::ClientDyn::rate_limit_ip` | only here | the configured limits | kept | limits reset |
| registration mail rate limit | `email_rate_limit.rs::EmailRateLimit` | only here | 3600 s | kept | a duplicate mail can be sent |
| upstream-provider callback state (PKCE verifier, xsrf) | `auth_providers.rs::AuthProviderCallback::save` | only here | 300 s | kept | upstream logins restart |
| ATProto state and sessions | `atproto.rs` (`Store` impls for `DB`) | only here | 300 s; 14400 s | kept | ATProto logins restart |
| PAM remote passwords and tokens | `pam/remote_password.rs`, `pam/tokens.rs::PamToken::new` | only here | `pam.remote_password_ttl`; 300 s | kept | PAM re-authenticates |
| previous client secret after rotation | `clients.rs::Client::cache_current_secret` | only here | see 6, O-2 | kept | clients still on the old secret fail |
| sessions | `sessions.rs::Session::find`, `upsert` | copy of SQL `sessions` | 14400 s | **cached rows win for up to 4 h** | none |
| users, user values, attributes, WebIDs | `users.rs::User::find`, `save` and neighbours | copy | 600 s | cached rows win for up to 10 min | none |
| ToS, latest and per user | `tos.rs::ToS::find_latest`, `tos_user_accept.rs` | copy | none for the latest; 600 s | **the cached latest ToS wins until it is replaced** | none |
| clients, scopes, roles, groups, JWKs, API keys, providers, policies, well-known, and more in `App` | the entities' `find` and `save_cache` | copy | 43200 s | cleared at start | none |
| dynamic clients | `clients_dyn.rs::ClientDyn::find` | copy of SQL `clients_dyn` | the rate-limit window | stale briefly | none |
| remote JWKs, ephemeral client documents | `jwk.rs` remote fetch; `clients.rs::find_maybe_ephemeral` | copy of a remote document | 3600 s; configured | not affected | refetched |
| average login time | `service/login_delay.rs::handle_login_delay` | only here (`App`) | none | cleared at start | recalibrates |

Found no cache entry for: MFA cookies (stateless, encrypted: `webauthn.rs::WebauthnCookie`); magic
links, password resets and email changes (SQL `magic_links`); refresh tokens and `issued_tokens`
(SQL only); FedCM (uses the session). No Hiqlite `dlock` is used. Listen and notify carry events
to SSE subscribers; each event is written to SQL `events` first (`events/listener.rs`).

**Export.** The only listing of cache contents is `GET /auth/v1/blacklist` (address and expiry).
Nothing else in the cache can be exported or imported.

## 3. Sessions, refresh tokens, revocation, and a stale restore

- Sessions: SQL `sessions`, with the cache copy above. Refresh tokens: SQL `refresh_tokens` and
  `refresh_tokens_devices`. Revocation: SQL `issued_tokens.revoked`
  (`migrations/hiqlite/24_token_revocation.sql`, `migrations/postgres/V19__revoked_tokens.sql`),
  read only by `IssuedToken::validate_not_revoked` from userinfo, token introspection and token
  exchange.
- Restoring a database that is older than the state it replaces **revives** what was removed
  after the backup was taken: deleted or expired sessions, deleted refresh tokens (and so the
  ability to mint new access tokens from them), revocations, disabled users and clients, deleted
  API keys and upstream providers, and superseded client secrets and passwords. It also forgets
  users, clients and keys created after the backup.
- An access-token floor at a consumer (Rahi's bearer floor) bounds the access tokens that
  consumer accepts. It cannot stop a revived refresh token from minting new access tokens at
  Rauthy, and it does not protect any other relying party.
- Today's bulk operations (`src/api/src/sessions.rs`): `DELETE /auth/v1/sessions` (API key or
  admin, `Sessions:Delete`) runs `Session::invalidate_all`, `RefreshToken::invalidate_all` and
  `IssuedToken::revoke_all`. It does **not** invalidate `refresh_tokens_devices`
  (`RefreshTokenDevice::invalidate_all` exists and has no caller). It needs a serving node.

## 4. Proposed: invalidation before a restored instance serves

Proposal only. Not implemented; it waits for the owner's acceptance of the policy.

- **Shape.** A CLI subcommand, `rauthy restore-invalidate`, run against the data directory with
  the same configuration as `serve`, which starts the storage layer with no listener and exits.
  Not an HTTP endpoint: its purpose is to finish before anything can be served, and an endpoint
  would exist on every serving node. Hiqlite always binds its raft and API listeners (Hiqlite 035
  section 3), so it runs with `HQL_NODES` bound to loopback on the one node.
- **What it invalidates, in one SQL transaction per backend:** every session (`exp` set to now);
  every row of `refresh_tokens` and `refresh_tokens_devices` deleted; every `issued_tokens` row
  revoked; every unused magic link expired. Then the whole cache is cleared, counters included,
  so that no cached session or user survives it.
- **What it records.** A row in a new table (hence a migration) holding the run's start and end,
  the backup name the operator passed, and the counts; one `events` entry; the same on stdout.
- **Idempotence and crash recovery.** Every statement is an absolute assignment, so a second run
  changes nothing further and a run killed before its commit left nothing. The table row is
  written in the same transaction; its absence is how the next `serve` knows the step did not
  complete, and `serve` then refuses to start until it has run (only when the operator armed it,
  for example with `RESTORE_REQUIRES_INVALIDATION=true`, so that nothing changes for others).
- **Authorization.** Access to the data directory and the configuration, as for `serve`.
- **Not reversed by it, and left to the operator:** users, clients, groups, roles, scopes,
  providers and API keys as they stood at the backup (disabled ones enabled again, deleted ones
  back, new ones gone); client secrets and password hashes as they were; signing keys as they
  were (see 5); outstanding access tokens issued before the restore, which stay valid at every
  relying party until they expire; and every cache-only item in section 2.
- **Signing keys**, optionally: a rotation after the invalidation, so that tokens minted after
  the backup do not validate against the restored keys. See section 5 for what that does not do.

## 5. Signing-key rotation

- Keys are in SQL `jwks`. `JWKS::rotate` adds a new key per algorithm; it runs from
  `jwks_auto_rotate` (cron, default `0 30 3 1 * * *`), from `POST /auth/v1/oidc/rotate_jwk`
  (API key or admin, `Secrets:Update`), and from an encryption-key migration.
- Retired public keys stay in `/oidc/certs` until `jwks_cleanup` deletes them. It deletes a key
  **90 days after its creation**, not after its retirement, and it keeps the first key it meets
  per algorithm. It meets them oldest first (`ORDER BY created_at ASC`) while its comment assumes
  newest first, so the **oldest** key per algorithm is kept indefinitely, and after 90 days
  without a rotation the **active** key is deleted and signing falls back to the oldest (O-3).
- The JWKS answer carries `cache-control: no-store` (`server.rs::default_headers`). A relying
  party may still cache keys by its own policy.
- **Rotation is not immediate invalidation.** A token signed by a retired key stays valid at any
  relying party that still trusts that key, until the token expires or the key leaves every
  cached copy of the JWKS. Removing the retired key from `jwks` stops Rauthy publishing it; it
  does not reach a relying party's cache, and nothing does.

## 6. Manual IP bans

- A ban is `IpBlacklist { ip: String, exp: DateTime<Utc> }`. The request that makes one is
  `IpBlacklistRequest { ip: IpAddr, exp: i64 }` (a Unix time, at least `1719784800`; no maximum is
  enforced). **Nothing records whether a ban is manual or automatic, and there is no reason
  field.** There is no indefinite ban; a far-future `exp` stands in for one. A past `exp` is
  silently not stored.
- **Proposed export and import**, not implemented. `GET /auth/v1/blacklist` already lists every
  active ban as address and expiry, which is everything a ban holds; an export needs no new
  endpoint. An import is a loop of `POST /auth/v1/blacklist` with the same expiry, which is
  idempotent (a second `put` replaces the entry with the same values). Automatic bans come out
  with manual ones: they cannot be told apart, and re-applying them preserves the state as it
  was rather than inventing a provenance. Distinguishing them needs a `source` and a `reason` on
  the entry, which is a data-model change and is not proposed for this line.
- **For the N=1 upgrade image.** The move-aside lifts every ban. Preserving them is an export
  before the upgrade and an import after the first start, both through the existing API; no code
  change is needed for that, only an operator step. Recommendation: document the step, and accept
  the loss of failed-login counters, which have no export and no expiry.

## 7. Observations beyond the requests

Read from source, not measured, and not changed here. Each is also present on upstream `main` at
`989f9ff9` unless it says otherwise.

- **O-1.** `ClientDyn::delete_from_cache` deletes from `Cache::App`; the entry lives in
  `Cache::ClientDynamic`.
- **O-2.** `Client::cache_current_secret` passes its `cache_current_hours` argument to Hiqlite as
  a TTL, which Hiqlite reads in seconds.
- **O-3.** `jwks_cleanup` keeps the oldest key per algorithm indefinitely and deletes the active
  key once it is 90 days old with no newer key (section 5). Holding `jwks_auto_rotate` for that
  long, as section 8 allows, triggers it.
- **O-4.** `DELETE /auth/v1/sessions` leaves device refresh tokens valid (section 3).
- **O-5.** Failed-login counters never expire, and an unban does not reset them.

## 8. Background writers (Hiqlite N3 item 2)

All are spawned unconditionally by `src/schedulers/src/lib.rs::spawn`; no configuration holds them
as a group. Most run on the cache leader only, which at N=1 is always this node.

| task | writes | can a setting hold it today |
|---|---|---|
| `jwks_auto_rotate` | new `jwks` rows | only by a far cron; a cron that never fires is refused at start |
| `jwks_cleanup`, `refresh_tokens_cleanup`, `sessions_cleanup`, `devices_cleanup`, `cleanup_issued_tokens`, `user_login_states_cleanup`, `events_cleanup`, `cleanup_authorized_keys` | deletes of expired rows | no |
| `magic_link_cleanup` | deletes expired links **and users** who never set a password or passkey | no |
| `user_expiry_checker` | disables, optionally deletes, expired users | deletion only |
| `dyn_client_cleanup` | deletes unused dynamic clients | only by disabling dynamic registration |
| `orphaned_email_jobs`, `password_expiry_checker` | sends mail, updates `email_jobs` | no |
| `backchannel_logout_retry`, `scim_task_retry` | outbound calls, deletes failure rows; **every node** | no |
| `app_version_check` | `App` cache, an event | yes, `events.disable_app_version_check` |
| `update_ip_geo_db` | a local file | yes, without MaxMind credentials |

Each delete is of state that has expired by the clock, so on an idle target cell it is disposable
before activation **only** if the source's clock and the target's agree; `magic_link_cleanup` and
`user_expiry_checker` change user rows and are not disposable. A hold is proposed in
`RELEASE-PRODUCER-RESPONSES.md`, item N3-2.
