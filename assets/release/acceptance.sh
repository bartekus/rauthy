#!/usr/bin/env bash
#
# Release acceptance for a downstream patched Rauthy build.
#
# Covers the lifecycle legs the cargo suite cannot reach, because they are about processes, data
# directories and exit codes rather than HTTP handlers: first boot, bad configuration, a listener
# that cannot bind, two processes contending for one data directory, restart and recovery,
# backup and restore, and an upgrade from the upstream release this build is based on.
#
# Usage:  acceptance.sh <path-to-rauthy> [path-to-upstream-rauthy]
#
# The second binary, when given, is the upstream release this build is based on; it enables the
# upgrade and rollback legs. Without it those legs are reported as skipped.
#
# Exits non-zero if any assertion failed. Every scenario is independent: each gets its own data
# directory and its own ports.
#
# ACCEPTANCE_STRICT=1 also fails the run on any skipped leg. A publication candidate runs strict,
# because a leg that could not run is a leg that was not qualified, however it is reported.

set -uo pipefail

RAUTHY="${1:?usage: acceptance.sh <path-to-rauthy> [path-to-upstream-rauthy]}"
UPSTREAM="${2:-}"
RAUTHY="$(cd "$(dirname "$RAUTHY")" && pwd)/$(basename "$RAUTHY")"
[ -n "$UPSTREAM" ] && UPSTREAM="$(cd "$(dirname "$UPSTREAM")" && pwd)/$(basename "$UPSTREAM")"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_TEMPLATE="$HERE/acceptance-config.toml"
WORK="${ACCEPTANCE_WORK:-$(mktemp -d)}"
ADMIN_EMAIL="admin@localhost"
ADMIN_PASSWORD="Acceptance123SuperSafe!"
# An API key bootstrapped alongside the admin, so that a scenario can read the identity data back
# out of a running instance without driving a browser login. `BOOTSTRAP_API_KEY` is base64 of an
# `ApiKeyRequest`; the secret has to be exactly `API_KEY_LENGTH` characters.
API_KEY_NAME="acceptance"
API_KEY_SECRET="AcceptanceApiKeySecret0123456789AcceptanceApiKeySecret0123456789"
API_KEY_JSON='{"name":"acceptance","exp":null,"access":[{"group":"Users","access_rights":["read"]},{"group":"Groups","access_rights":["read","create"]}]}'
API_KEY_B64="$(printf '%s' "$API_KEY_JSON" | base64 | tr -d '\n')"

PASS=0
FAIL=0
SKIP=0
declare -a RESULTS=()

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS + 1)); RESULTS+=("PASS  $1"); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS+=("FAIL  $1")
         printf '  \033[31mFAIL\033[0m %s\n    %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP + 1)); RESULTS+=("SKIP  $1: ${2:-}")
         printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "${2:-}"; }

assert() { # assert <name> <condition-result> <detail>
  if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# --- process helpers ---------------------------------------------------------

# start_node <dir> <http-port> <raft-port> <api-port> [extra env assignments...]
#
# Writes the node's pid to $dir/pid, its log to $dir/rauthy.log, and, once it exits, its real
# exit code to $dir/rc. The wrapper subshell exists for that last part: the node is started
# inside it so that something is left to `wait` on it. Reading `$?` from the caller would not
# work, because the node is not the calling shell's own child, and `wait` would answer 127.
start_node() {
  local dir="$1" http="$2" raft="$3" api="$4"; shift 4
  mkdir -p "$dir"
  [ -f "$dir/config.toml" ] || cp "$CONFIG_TEMPLATE" "$dir/config.toml"
  rm -f "$dir/rc" "$dir/pid"
  (
    cd "$dir"
    # The caller's assignments come last so that they override these defaults.
    env \
      HQL_DATA_DIR="$dir/data" \
      HQL_NODES="1 localhost:$raft localhost:$api" \
      LISTEN_ADDRESS=127.0.0.1 \
      LISTEN_PORT_HTTP="$http" \
      PUB_URL="localhost:$http" \
      RP_ORIGIN="http://localhost:$http" \
      BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" \
      BOOTSTRAP_ADMIN_PASSWORD_PLAIN="$ADMIN_PASSWORD" \
      BOOTSTRAP_API_KEY="$API_KEY_B64" \
      BOOTSTRAP_API_KEY_SECRET="$API_KEY_SECRET" \
      "$@" \
      "${BIN:-$RAUTHY}" serve -c config.toml >> "$dir/rauthy.log" 2>&1 &
    node=$!
    echo "$node" > "$dir/pid"
    wait "$node"
    echo $? > "$dir/rc"
  ) &
  # Give the inner start a moment to publish its pid, so a caller can signal it.
  for _ in $(seq 1 50); do [ -f "$dir/pid" ] && break; sleep 0.1; done
}

# wait_ready <dir> <http-port> <seconds>
#
# The budget has to cover a first boot, which generates the signing keys. That is seconds in a
# release build and minutes in a debug one, so it is set for the slow case.
wait_ready() {
  local dir="$1" http="$2" budget="${3:-90}" i=0
  while [ "$i" -lt "$budget" ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http/auth/v1/ready")" = "200" ]; then
      return 0
    fi
    # a node that has already exited is never going to become ready
    if [ -f "$dir/pid" ] && ! kill -0 "$(cat "$dir/pid")" 2>/dev/null; then return 1; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

# stop_node <dir> - graceful SIGTERM, then wait for the node to actually go.
stop_node() {
  local dir="$1" pid
  [ -f "$dir/pid" ] || return 0
  pid="$(cat "$dir/pid")"
  kill -TERM "$pid" 2>/dev/null || { rm -f "$dir/pid"; return 0; }
  local i=0
  while [ ! -f "$dir/rc" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
  if [ ! -f "$dir/rc" ]; then kill -KILL "$pid" 2>/dev/null; sleep 2; fi
  rm -f "$dir/pid"
  return 0
}

# run_until_exit <dir> <http-port> <raft-port> <api-port> <budget> [env...]
# Starts a node that is expected to fail, and returns the exit code it actually exited with
# (124 if it was still running when the budget ran out).
run_until_exit() {
  local dir="$1" http="$2" raft="$3" api="$4" budget="$5"; shift 5
  start_node "$dir" "$http" "$raft" "$api" "$@"
  local i=0
  while [ ! -f "$dir/rc" ] && [ "$i" -lt "$budget" ]; do sleep 1; i=$((i + 1)); done
  if [ ! -f "$dir/rc" ]; then
    [ -f "$dir/pid" ] && kill -KILL "$(cat "$dir/pid")" 2>/dev/null
    rm -f "$dir/pid"
    return 124
  fi
  local rc; rc="$(cat "$dir/rc")"
  rm -f "$dir/pid"
  return "$rc"
}

# A data directory is "clean" when a fresh start does not report an ungraceful shutdown.
# hiqlite says so on its WAL lock file and on its state-machine lock file, and reacts to the
# latter by rebuilding the state machine. Either message means the previous process did not
# shut its storage down.
unclean_markers() {
  # `grep -c` prints 0 and exits 1 when it matches nothing, so the count has to be captured
  # rather than chained with `||`, which would print a second 0.
  local n
  n="$(grep -ciE 'not a clean start|did not shut down gracefully|auto-rebuilding State Machine' \
    "$1/rauthy.log" 2>/dev/null)"
  echo "${n:-0}"
}

# Every `kid` the instance publishes, sorted. The whole set matters, not one of them: rauthy
# serves a key per algorithm and the JWKS order is not stable, so comparing a single entry would
# compare different keys on either side.
# The admin's email as the instance itself reports it, through an authenticated API call. Empty
# when the call fails, so a caller can tell "not there" from "there".
admin_identity() {
  curl -s -H "Authorization: API-Key ${API_KEY_NAME}\$${API_KEY_SECRET}" \
    "http://127.0.0.1:$1/auth/v1/users" \
    | grep -o "\"email\":\"$ADMIN_EMAIL\"" | head -1
}

API_KEY_HEADER="Authorization: API-Key ${API_KEY_NAME}\$${API_KEY_SECRET}"

# create_group <http-port> <name> - prints the HTTP status of one real database write.
create_group() {
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "$API_KEY_HEADER" \
    -H 'Content-Type: application/json' -d "{\"group\":\"$2\"}" \
    "http://127.0.0.1:$1/auth/v1/groups"
}

# group_exists <http-port> <name>
group_exists() {
  curl -s -H "$API_KEY_HEADER" "http://127.0.0.1:$1/auth/v1/groups" | grep -q "\"name\":\"$2\""
}

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

jwks_kid() {
  curl -s "http://127.0.0.1:$1/auth/v1/oidc/certs" \
    | tr ',' '\n' | grep -o '"kid":"[^"]*"' | sort | tr '\n' ' '
}

# Helpers that outlive a scenario if the run is killed: the port squatters and the Postgres
# container. Tracked here so a cancelled run does not leak either onto a reused runner and fail
# the next one for an unrelated reason.
HELPER_PIDS=""
HELPER_CONTAINERS=""

cleanup() {
  for d in "$WORK"/*/; do
    [ -f "$d/pid" ] && kill -KILL "$(cat "$d/pid")" 2>/dev/null
  done
  for pid in $HELPER_PIDS; do kill -KILL "$pid" 2>/dev/null; done
  for c in $HELPER_CONTAINERS; do
    "${DOCKER:-docker}" rm -f "$c" > /dev/null 2>&1
  done
  return 0
}
trap cleanup EXIT INT TERM

echo "acceptance work dir: $WORK"
echo "binary under test:   $RAUTHY"
[ -n "$UPSTREAM" ] && echo "upstream baseline:   $UPSTREAM"

# --- A: identity -------------------------------------------------------------

log "A. Release identity"
VERSION_OUT="$("$RAUTHY" --version 2>&1)"
echo "$VERSION_OUT" | grep -qE '0\.36\.2-patched\.[0-9]+'
assert "version output names the patched build" $? "got: $VERSION_OUT"

# --- B: first boot -----------------------------------------------------------

log "B. First boot with valid configuration"
B="$WORK/b-first-boot"
start_node "$B" 8091 8101 8201
wait_ready "$B" 8091 300
assert "first boot becomes ready" $? "see $B/rauthy.log"

curl -s "http://127.0.0.1:8091/auth/v1/health" | grep -q '"db_healthy":true'
assert "health reports a live database" $?

grep -q "Downstream distribution by" "$B/rauthy.log"
assert "startup log declares the downstream distribution" $?

! grep -q "you are using a pre-release version" "$B/rauthy.log"
assert "the patched marker is not treated as an upstream pre-release" $? \
  "$(grep 'pre-release' "$B/rauthy.log" | head -2)"
grep -q "from upstream v0.36.2" "$B/rauthy.log"
assert "the startup log names the upstream base it was built from" $?

KID_FIRST="$(jwks_kid 8091)"
[ -n "$KID_FIRST" ]
assert "the instance publishes a signing key" $? "empty JWKS"

[ -n "$(admin_identity 8091)" ]
assert "the bootstrapped identity authenticates and is readable" $? \
  "no $ADMIN_EMAIL behind the API key"

# The production frontend is embedded into the binary at build time. A binary built without it
# still starts and still passes every API leg, so it is checked here on its own: the index page
# the server renders must reference a built bundle, and that bundle must be served.
INDEX="$(curl -s "http://127.0.0.1:8091/auth/v1/")"
ENTRY="$(printf '%s' "$INDEX" | grep -o '_app/immutable/entry/start\.[A-Za-z0-9_-]*\.js' | head -1)"
[ -n "$ENTRY" ]
assert "the served index references the built frontend bundle" $? "no bundle in /auth/v1/"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8091/auth/v1/$ENTRY")" = "200" ]
assert "the frontend bundle is served" $? "GET /auth/v1/$ENTRY did not answer 200"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8091/auth/v1/account")" = "200" ]
assert "the account page is served" $?

# --- C: bad configuration ----------------------------------------------------

log "C. Missing, malformed and conflicting configuration"
C="$WORK/c-config"; mkdir -p "$C"

"$RAUTHY" serve -c "$C/does-not-exist.toml" > "$C/missing.log" 2>&1
[ $? -ne 0 ]
assert "a missing config file fails the start" $?
grep -qiE 'Cannot read the config file .*does-not-exist' "$C/missing.log"
assert "the missing-config failure names the file that is missing" $? "$(tail -3 "$C/missing.log")"

printf 'this is not = [valid toml\n' > "$C/malformed.toml"
"$RAUTHY" serve -c "$C/malformed.toml" > "$C/malformed.log" 2>&1
[ $? -ne 0 ]
assert "a malformed config file fails the start" $?
grep -qiE 'toml|parse|expected' "$C/malformed.log"
assert "the malformed-config failure names the problem" $? "$(tail -3 "$C/malformed.log")"

# A cron expression the schedulers would only choke on after the storage layer is live. It has to
# be refused during config validation, which runs before `DB::init()`.
CRON="$C/bad-cron"; mkdir -p "$CRON"; cp "$CONFIG_TEMPLATE" "$CRON/config.toml"
run_until_exit "$CRON" 8085 8115 8215 120 "JWK_AUTOROTATE_CRON=not a cron expression"
RC=$?
[ "$RC" -ne 0 ]
assert "an invalid cron expression fails the start" $? "exit code was $RC"
grep -qi 'jwk_autorotate_cron' "$CRON/rauthy.log"
assert "the invalid-cron failure names the setting" $? "$(tail -3 "$CRON/rauthy.log")"
[ ! -d "$CRON/data/state_machine" ]
assert "the invalid cron was caught before the storage layer started" $? \
  "a data directory was created at $CRON/data"

# Conflicting: Postgres selected as the backend, with no Postgres to connect to.
CONF="$C/conflicting"; mkdir -p "$CONF"; cp "$CONFIG_TEMPLATE" "$CONF/config.toml"
# A sentinel rather than a word: the point is to find it if it is printed, and 'nothing' would
# be indistinguishable from ordinary log prose.
PG_SENTINEL='Pa55word-SENTINEL-must-never-be-logged'
run_until_exit "$CONF" 8092 8102 8202 180 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=1 \
  PG_USER=nobody "PG_PASSWORD=$PG_SENTINEL"
RC=$?
[ "$RC" -ne 0 ]
assert "a backend that cannot be reached fails the start" $? "exit code was $RC"
# `grep -qv PATTERN` is not this assertion: it succeeds as soon as any one line lacks the
# pattern, which is true of every multi-line log whether the secret is in it or not.
! grep -q "$PG_SENTINEL" "$CONF/rauthy.log"
assert "the startup failure does not echo the database password" $? \
  "$(grep -n "$PG_SENTINEL" "$CONF/rauthy.log" | head -2)"
# The embedded node had already started when the Postgres connection failed, inside
# `DB::init()` and before `run()` held a client it could shut down. A second start on the same
# directory reads whether the first one shut its storage down.
mv "$CONF/rauthy.log" "$CONF/first-attempt.log"
run_until_exit "$CONF" 8092 8102 8202 180 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=1 \
  PG_USER=nobody "PG_PASSWORD=$PG_SENTINEL"
[ "$(unclean_markers "$CONF")" = "0" ]
assert "a backend failure inside DB::init shut the embedded storage down" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$CONF/rauthy.log" | head -3)"

# The Postgres root CA is read in the same window, after the embedded node has started. Upstream
# v0.36.2 panics on a PEM block it cannot decode (exit 134) and on a certificate rustls refuses.
# pg_root_ca_case <name> <dir> <pem>
pg_root_ca_case() {
  local name="$1" dir="$2" pem="$3" rc
  mkdir -p "$dir"; cp "$CONFIG_TEMPLATE" "$dir/config.toml"
  run_until_exit "$dir" 8078 8126 8226 180 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=1 \
    PG_USER=nobody PG_PASSWORD=nobody PG_TLS=require "PG_TLS_ROOT_CA=$pem"
  rc=$?
  [ "$rc" -eq 1 ]
  assert "$name fails the start with exit 1" $? "exit code was $rc"
  grep -q 'pg_tls_root_ca' "$dir/rauthy.log"
  assert "the failure names pg_tls_root_ca for $name" $? "$(tail -3 "$dir/rauthy.log")"
  mv "$dir/rauthy.log" "$dir/first-attempt.log"
  run_until_exit "$dir" 8078 8126 8226 180 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=1 \
    PG_USER=nobody PG_PASSWORD=nobody
  [ "$(unclean_markers "$dir")" = "0" ]
  assert "$name shut the embedded storage down" $? \
    "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$dir/rauthy.log" | head -3)"
}
pg_root_ca_case "a root CA that is not valid PEM" "$C/pg-ca-not-pem" \
  "$(printf -- '-----BEGIN CERTIFICATE-----\n!!! not base64 !!!\n-----END CERTIFICATE-----\n')"
pg_root_ca_case "a root CA that is not a certificate" "$C/pg-ca-not-der" \
  "$(printf -- '-----BEGIN CERTIFICATE-----\nAAAAAAAA\n-----END CERTIFICATE-----\n')"

# --- D: listener bind failure ------------------------------------------------

log "D. Listener bind failure leaves the data directory clean"
D="$WORK/d-bind"; mkdir -p "$D"
# Occupy the HTTP port with something that is not rauthy.
python3 -c "
import socket, time, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 8093)); s.listen(1)
sys.stderr.write('bound\n'); sys.stderr.flush()
time.sleep(600)
" 2> "$D/squatter.log" &
SQUATTER=$!
HELPER_PIDS="$HELPER_PIDS $SQUATTER"
sleep 2

run_until_exit "$D" 8093 8103 8203 240
RC=$?
[ "$RC" -ne 0 ]
assert "a listener that cannot bind fails the start" $? "exit code was $RC"

kill "$SQUATTER" 2>/dev/null; wait "$SQUATTER" 2>/dev/null
sleep 1

# The regression this guards: the storage layer used to be left running when the bind failed,
# so the next start found an ungraceful shutdown and rebuilt the state machine.
mv "$D/rauthy.log" "$D/bind-failure.log"
start_node "$D" 8093 8103 8203
wait_ready "$D" 8093 300
assert "the node starts again after a bind failure" $? "see $D/rauthy.log"
[ "$(unclean_markers "$D")" = "0" ]
assert "the bind failure shut the storage layer down cleanly" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$D/rauthy.log" | head -3)"
stop_node "$D"

# --- E: two processes, one data directory ------------------------------------

log "E. Two processes contending for one data directory"
E="$WORK/e-contend"
start_node "$E" 8094 8104 8204
wait_ready "$E" 8094 300
assert "the first node is serving" $?
KID_E_BEFORE="$(jwks_kid 8094)"

# The second process gets its own ports but the same data directory.
E2="$WORK/e-contend-second"; mkdir -p "$E2"; cp "$CONFIG_TEMPLATE" "$E2/config.toml"
(
  cd "$E2"
  env HQL_DATA_DIR="$E/data" HQL_NODES="1 localhost:8105 localhost:8205" \
    LISTEN_ADDRESS=127.0.0.1 LISTEN_PORT_HTTP=8095 PUB_URL=localhost:8095 \
    RP_ORIGIN=http://localhost:8095 \
    BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" BOOTSTRAP_ADMIN_PASSWORD_PLAIN="$ADMIN_PASSWORD" \
    "$RAUTHY" serve -c config.toml > "$E2/rauthy.log" 2>&1
  echo $? > "$E2/rc"
)
RC="$(cat "$E2/rc" 2>/dev/null || echo 124)"
[ "$RC" != "0" ]
assert "the second process refuses to open the data directory" $? "exit code was $RC"
# Hiqlite's typed refusal: it names the owner and says nothing in the directory was changed.
grep -qE 'StorageInUse: .*owned by another live process.*has changed nothing' "$E2/rauthy.log"
assert "the refusal is the storage-ownership error and changed nothing" $? \
  "$(tail -3 "$E2/rauthy.log")"

curl -s "http://127.0.0.1:8094/auth/v1/health" | grep -q '"db_healthy":true'
assert "the first node is unharmed by the second one's attempt" $?
# This node's own keys, taken before the second process tried. An earlier version compared with
# leg B's node, fell back to "not empty", and could not fail; the independent review found it.
[ -n "$KID_E_BEFORE" ] && [ "$(jwks_kid 8094)" = "$KID_E_BEFORE" ]
assert "the first node still serves its own signing keys" $? \
  "before: $KID_E_BEFORE after: $(jwks_kid 8094)"

# --- F: shutdown, restart, recovery ------------------------------------------

log "F. Shutdown, restart and recovery"
KID_E="$(jwks_kid 8094)"
stop_node "$E"
[ "$(cat "$E/rc" 2>/dev/null)" = "0" ]
assert "SIGTERM exits cleanly" $? "exit code was $(cat "$E/rc" 2>/dev/null || echo none)"
sleep 3
mv "$E/rauthy.log" "$E/first-run.log"
start_node "$E" 8094 8104 8204
wait_ready "$E" 8094 300
assert "the node restarts on its existing data" $? "see $E/rauthy.log"
[ "$(unclean_markers "$E")" = "0" ]
assert "a graceful shutdown leaves nothing to recover" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$E/rauthy.log" | head -3)"
[ "$(jwks_kid 8094)" = "$KID_E" ]
assert "the signing key survives a restart" $? "before: $KID_E after: $(jwks_kid 8094)"

# --- G: backup and restore ---------------------------------------------------

log "G. Backup, restore, and refusal of bad restore input"
BACKUP_DIR="$E/data/state_machine/backups"
# The acceptance config runs hiqlite's auto-backup every minute, so one appears on its own. The
# API route a consumer uses to take a backup on demand is covered by the cargo suite, which has
# the admin session this script does not.
#
# The backup has to be newer than the moment this instance finished bootstrapping, not merely the
# newest file present: the cron can fire while rauthy is still generating its signing keys, and
# such a backup holds an empty database. Restoring it would look like a broken restore.
touch "$E/bootstrapped.marker"
BACKUP_FILE=""
for _ in $(seq 1 100); do
  BACKUP_FILE="$(find "$BACKUP_DIR" -name '*.sqlite' -newer "$E/bootstrapped.marker" 2>/dev/null \
    | sort | tail -1)"
  [ -n "$BACKUP_FILE" ] && break
  sleep 2
done
if [ -z "$BACKUP_FILE" ]; then
  skip "a backup exists to restore from" "no backup newer than bootstrap in $BACKUP_DIR"
else
  ok "a backup exists to restore from"
fi

if [ -n "$BACKUP_FILE" ]; then
  head -c 16 "$BACKUP_FILE" | grep -q "SQLite format 3"
  assert "the backup is a SQLite database" $?
  # A consumer parses the node id and the unix timestamp out of this name to find the snapshot
  # its own trigger produced. It is Hiqlite's format, not Rauthy's, so a Hiqlite package swap is
  # exactly what could change it without anything in Rauthy's own suite noticing.
  basename "$BACKUP_FILE" | grep -qE '^backup_node_1_[0-9]{10}\.sqlite$'
  assert "the backup keeps the backup_node_<id>_<seconds>.sqlite name" $? \
    "got $(basename "$BACKUP_FILE")"

  stop_node "$E"
  sleep 3

  # Restore into fresh storage.
  G="$WORK/g-restore"; mkdir -p "$G"; cp "$CONFIG_TEMPLATE" "$G/config.toml"
  cp "$BACKUP_FILE" "$G/backup.sqlite"
  start_node "$G" 8096 8106 8206 "HQL_BACKUP_RESTORE=file:$G/backup.sqlite"
  wait_ready "$G" 8096 300
  assert "a restore into fresh storage comes up" $? "see $G/rauthy.log"
  ! grep -q "Initializing empty production database" "$G/rauthy.log"
  assert "the restored instance used the restored data instead of bootstrapping" $? \
    "$(grep -n 'Initializing empty production database' "$G/rauthy.log" | head -1)"
  [ "$(jwks_kid 8096)" = "$KID_E" ]
  assert "the restored instance keeps the original signing keys" $? \
    "before: $KID_E after: $(jwks_kid 8096)"
  curl -s "http://127.0.0.1:8096/auth/v1/health" | grep -q '"db_healthy":true'
  assert "the restored instance is healthy" $?
  # The identity itself, not just the keys: the original admin has to be there, and the credential
  # that was bootstrapped with it has to still authenticate against the restored data.
  [ -n "$(admin_identity 8096)" ]
  assert "the original identity authenticates against the restored data" $? \
    "no $ADMIN_EMAIL behind the API key after the restore"
  stop_node "$G"

  # Corrupt restore input must be refused, and must not destroy what the node already has.
  #
  # The state that has to survive is the *restoring node's own*, so this node is populated first
  # and the bad restore is aimed at the directory it owns. Pointing a doomed restore at an empty
  # directory and then checking some other node's file would pass no matter what happened.
  H="$WORK/h-bad-restore"; mkdir -p "$H"
  start_node "$H" 8097 8107 8207
  wait_ready "$H" 8097 300
  assert "the node that will refuse a bad restore is populated first" $? "see $H/rauthy.log"
  KID_H="$(jwks_kid 8097)"
  stop_node "$H"
  sleep 3

  head -c 4096 "$BACKUP_FILE" > "$H/truncated.sqlite"
  mv "$H/rauthy.log" "$H/first-run.log"
  run_until_exit "$H" 8097 8107 8207 300 "HQL_BACKUP_RESTORE=file:$H/truncated.sqlite"
  RC=$?
  [ "$RC" -ne 0 ]
  assert "a truncated restore input is refused" $? "exit code was $RC"

  mv "$H/rauthy.log" "$H/refused-restore.log"
  start_node "$H" 8097 8107 8207
  wait_ready "$H" 8097 300
  assert "the node still starts on its own data after refusing the restore" $? \
    "see $H/rauthy.log"
  ! grep -q "Initializing empty production database" "$H/rauthy.log"
  assert "the refused restore did not empty the node's database" $? \
    "$(grep -n 'Initializing empty production database' "$H/rauthy.log" | head -1)"
  [ "$(jwks_kid 8097)" = "$KID_H" ]
  assert "the refused restore did not touch the last recoverable state" $? \
    "before: $KID_H after: $(jwks_kid 8097)"
  stop_node "$H"

  I="$WORK/i-missing-restore"; mkdir -p "$I"; cp "$CONFIG_TEMPLATE" "$I/config.toml"
  run_until_exit "$I" 8098 8108 8208 240 "HQL_BACKUP_RESTORE=file:$I/does-not-exist.sqlite"
  RC=$?
  [ "$RC" -ne 0 ]
  assert "a missing restore input is refused" $? "exit code was $RC"
fi

# --- J: upgrade from the upstream baseline -----------------------------------

log "J. Upgrade from the upstream baseline"
if [ -z "$UPSTREAM" ]; then
  skip "upgrade from the upstream baseline" "no upstream binary given"
  skip "rollback to the upstream baseline" "no upstream binary given"
else
  J="$WORK/j-upgrade"
  BIN="$UPSTREAM" start_node "$J" 8099 8109 8209
  wait_ready "$J" 8099 300
  assert "the upstream baseline boots and populates a data directory" $? "see $J/rauthy.log"
  KID_UP="$(jwks_kid 8099)"
  [ "$(create_group 8099 acceptance_written_by_upstream)" = "200" ]
  assert "the upstream baseline accepts a write" $?
  stop_node "$J"
  sleep 3
  cp -a "$J/data" "$J/data-as-upstream-left-it"

  # The cache raft's log format changed after hiqlite 0.14.0 and is not readable across the
  # upgrade; the SQLite database and its raft log are. Started on the directory as upstream left
  # it, the patched build must refuse with an error that names the procedure, not abort, and must
  # leave the directory as it found it.
  mv "$J/rauthy.log" "$J/upstream-run.log"
  run_until_exit "$J" 8099 8109 8209 180
  RC=$?
  [ "$RC" -ne 0 ] && [ "$RC" -ne 134 ] && [ "$RC" -ne 124 ]
  assert "an upgrade without the cache procedure is refused, not aborted" $? "exit code was $RC"
  grep -q "logs_cache" "$J/rauthy.log" && grep -q "HQL_CACHE_LEGACY_MOVE_ASIDE=true" "$J/rauthy.log" \
    && grep -q "Nothing was changed" "$J/rauthy.log"
  assert "the refusal names the cache log, the opt-in, and that nothing changed" $? \
    "$(tail -3 "$J/rauthy.log")"
  # Byte for byte, apart from the ownership lock the refusing process takes first. An earlier
  # Hiqlite candidate refused only after opening the database, which checkpointed its WAL; this
  # is the assertion that caught it.
  diff -r -x hiqlite-owner.lock "$J/data" "$J/data-as-upstream-left-it" > /dev/null
  assert "the refused upgrade left every file byte-identical" $? \
    "$(diff -rq -x hiqlite-owner.lock "$J/data" "$J/data-as-upstream-left-it" | head -5)"
  diff -r "$J/data/logs" "$J/data-as-upstream-left-it/logs" > /dev/null
  assert "the refused upgrade left the database's raft log byte-identical" $?
  python3 - "$J/data-as-upstream-left-it/state_machine/db/hiqlite.db" \
    "$J/data/state_machine/db/hiqlite.db" <<'PYEOF'
import shutil, sqlite3, sys, tempfile
def dump(path):
    # Work on a copy, so that reading it cannot change the evidence either.
    d = tempfile.mkdtemp()
    for suffix in ("", "-wal", "-shm"):
        try:
            shutil.copy(path + suffix, f"{d}/db{suffix}")
        except FileNotFoundError:
            pass
    return [l for l in sqlite3.connect(f"{d}/db").iterdump() if "sqlite_stat1" not in l]
sys.exit(0 if dump(sys.argv[1]) == dump(sys.argv[2]) else 1)
PYEOF
  assert "the refused upgrade left the database's content unchanged" $?

  # The procedure, through Hiqlite's supported opt-in for the one upgrade start: it moves the
  # cache raft's log and snapshots into pre-upgrade-<unix seconds>/ and deletes nothing.
  mv "$J/rauthy.log" "$J/refused-upgrade.log"
  start_node "$J" 8099 8109 8209 HQL_CACHE_LEGACY_MOVE_ASIDE=true
  wait_ready "$J" 8099 300
  assert "the patched build starts on the upstream data directory" $? "see $J/rauthy.log"
  MOVED="$(find "$J/data" -maxdepth 1 -type d -name 'pre-upgrade-*' | head -1)"
  [ -n "$MOVED" ] && [ -d "$MOVED/logs_cache" ] && [ -d "$MOVED/state_machine_cache" ]
  assert "the legacy cache was moved aside, not deleted" $? "$(ls "$J/data")"
  [ "$(jwks_kid 8099)" = "$KID_UP" ]
  assert "the upgrade keeps the signing key" $? "before: $KID_UP after: $(jwks_kid 8099)"
  [ "$(unclean_markers "$J")" = "0" ]
  assert "the upgrade did not have to rebuild the state machine" $?
  [ -n "$(admin_identity 8099)" ]
  assert "the upgraded instance keeps the original identity" $? \
    "no $ADMIN_EMAIL after the upgrade"
  group_exists 8099 acceptance_written_by_upstream
  assert "data written by the upstream baseline survives the upgrade" $?
  [ "$(create_group 8099 acceptance_written_by_patched)" = "200" ]
  assert "the upgraded instance accepts writes" $?
  stop_node "$J"
  sleep 3
  # The opt-in is for one start. Every later start runs without it.
  mv "$J/rauthy.log" "$J/upgrade-run.log"
  start_node "$J" 8099 8109 8209
  wait_ready "$J" 8099 300
  assert "the upgraded node restarts without the opt-in" $? "see $J/rauthy.log"
  stop_node "$J"
  sleep 3

  # Rollback: the same procedure in the other direction, because upstream has no way to refuse a
  # cache log it cannot read. The version this build stamps into the config table must not lock
  # upstream out, and what the patched build wrote must be readable by upstream.
  mv "$J/rauthy.log" "$J/patched-run.log"
  mkdir -p "$J/data/pre-rollback"
  mv "$J/data/logs_cache" "$J/data/state_machine_cache" "$J/data/pre-rollback/"
  BIN="$UPSTREAM" start_node "$J" 8099 8109 8209
  wait_ready "$J" 8099 300
  assert "the upstream baseline still starts after the upgrade" $? \
    "rollback is blocked: $(tail -5 "$J/rauthy.log")"
  [ "$(jwks_kid 8099)" = "$KID_UP" ]
  assert "the rollback keeps the signing key" $?
  group_exists 8099 acceptance_written_by_patched
  assert "data written by the patched build survives the rollback" $?
  stop_node "$J"
fi

# --- M: TLS is an exit path too -----------------------------------------------

log "M. TLS material that cannot be used fails cleanly"
# Every scenario above runs over plain HTTP, so without this one nothing exercises the code that
# loads or generates TLS material - which runs after the storage layer is live and is therefore
# in exactly the class of exit path this release is about.

# M1: self-signed generation is the default path for a node told to serve HTTPS with no material.
M="$WORK/m-tls-self-signed"; mkdir -p "$M"
start_node "$M" 8087 8117 8217 LISTEN_SCHEME=https LISTEN_PORT_HTTPS=8447 TLS_GENERATE_SELF_SIGNED=true
# `wait_ready` speaks HTTP; this node serves HTTPS only, so poll it directly.
tls_ready=1
for _ in $(seq 1 300); do
  if [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:8447/auth/v1/ready")" = "200" ]; then
    tls_ready=0; break
  fi
  [ -f "$M/rc" ] && break
  sleep 1
done
assert "a node serving HTTPS with generated material comes up" $tls_ready "see $M/rauthy.log"
curl -sk "https://127.0.0.1:8447/auth/v1/health" | grep -q '"db_healthy":true'
assert "the HTTPS node is healthy over TLS" $?
stop_node "$M"

# M2: material that exists but cannot be used must be an error, not an abort, and must leave the
# data directory clean.
N="$WORK/n-tls-broken"; mkdir -p "$N/material"
printf 'this is not a certificate
' > "$N/material/tls.crt"
printf 'this is not a key
' > "$N/material/tls.key"
run_until_exit "$N" 8086 8116 8216 300 LISTEN_SCHEME=https LISTEN_PORT_HTTPS=8446   TLS_GENERATE_SELF_SIGNED=false "TLS_CERT=$N/material/tls.crt"   "TLS_KEY=$N/material/tls.key"
RC=$?
[ "$RC" -ne 0 ]
assert "unusable TLS material fails the start" $? "exit code was $RC"
grep -qiE 'TLS (key|certificate)' "$N/rauthy.log"
assert "the failure names the TLS material" $? "$(tail -3 "$N/rauthy.log")"

mv "$N/rauthy.log" "$N/tls-failure.log"
start_node "$N" 8086 8116 8216
wait_ready "$N" 8086 300
assert "the node starts over HTTP once the TLS material is out of the way" $? "see $N/rauthy.log"
[ "$(unclean_markers "$N")" = "0" ]
assert "the TLS failure shut the storage layer down cleanly" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$N/rauthy.log" | head -3)"
stop_node "$N"

# M3: self-signed generation that cannot succeed. The certificate is issued for the PUB_URL host,
# and a host that is not a valid DNS name is refused by the certificate library. Upstream v0.36.2
# unwraps that refusal after the storage layer is live and exits 134; the same generation runs
# again on every renewal of a serving node.
O="$WORK/o-tls-bad-name"; mkdir -p "$O"
run_until_exit "$O" 8088 8118 8218 300 LISTEN_SCHEME=https LISTEN_PORT_HTTPS=8448 \
  TLS_GENERATE_SELF_SIGNED=true "PUB_URL=bücher.localhost:8448"
RC=$?
[ "$RC" -eq 1 ]
assert "a PUB_URL host that cannot name a certificate fails the start with exit 1" $? "exit code was $RC"
grep -q 'certificate name' "$O/rauthy.log"
assert "the failure names the certificate problem" $? "$(tail -3 "$O/rauthy.log")"

mv "$O/rauthy.log" "$O/tls-failure.log"
start_node "$O" 8088 8118 8218
wait_ready "$O" 8088 300
assert "the node starts over HTTP after the failed generation" $? "see $O/rauthy.log"
[ "$(unclean_markers "$O")" = "0" ]
assert "the failed generation shut the storage layer down cleanly" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$O/rauthy.log" | head -3)"
stop_node "$O"

# --- S: the mail sender is an exit path too ----------------------------------

log "S. A mail configuration that cannot work fails cleanly"
# The sender connects to SMTP after the storage layer is live. Upstream v0.36.2 `expect()`s an
# incomplete configuration there (exit 134, and the next start rebuilds the state machine), and
# `panic!`s once its connection retries are exhausted (exit 134 after the storage shutdown).

# mail_exit_case <name> <dir> <log-pattern> [env...]
mail_exit_case() {
  local name="$1" dir="$2" pattern="$3"; shift 3
  mkdir -p "$dir"
  run_until_exit "$dir" 8079 8124 8224 300 SMTP_CONNECT_RETRIES=0 "$@"
  local rc=$?
  [ "$rc" -eq 1 ]
  assert "$name fails the start with exit 1" $? "exit code was $rc"
  grep -q "$pattern" "$dir/rauthy.log"
  assert "the failure names $name" $? "$(tail -3 "$dir/rauthy.log")"
  mv "$dir/rauthy.log" "$dir/mail-failure.log"
  start_node "$dir" 8079 8124 8224
  wait_ready "$dir" 8079 300
  assert "the node starts without the mail configuration after $name" $? "see $dir/rauthy.log"
  [ "$(unclean_markers "$dir")" = "0" ]
  assert "$name shut the storage layer down cleanly" $? \
    "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$dir/rauthy.log" | head -3)"
  stop_node "$dir"
}

mail_exit_case "an SMTP_URL without SMTP_USERNAME" "$WORK/s1-smtp-no-user" \
  'SMTP_USERNAME is not set' SMTP_URL=127.0.0.1
# Nothing listens on port 1, so every attempt is refused at once.
mail_exit_case "an SMTP relay that cannot be reached" "$WORK/s2-smtp-unreachable" \
  'SMTP connection retries exceeded' SMTP_URL=127.0.0.1 SMTP_PORT=1 SMTP_USERNAME=user \
  SMTP_PASSWORD=password
mail_exit_case "an SMTP_FROM that is not a mailbox" "$WORK/s3-smtp-bad-from" \
  'SMTP_FROM could not be parsed' SMTP_URL=127.0.0.1 SMTP_PORT=1 SMTP_USERNAME=user \
  SMTP_PASSWORD=password "SMTP_FROM=not a mailbox"

# --- T: settings refused before storage, and the panic safety net -------------

log "T. Settings that upstream acts on after the storage layer starts are refused before it"
# Each of these reached a panic after `DB::init()` in upstream v0.36.2. They are now refused by
# config validation, before a data directory exists.
t_refused() {
  local name="$1" dir="$2"; shift 2
  local rc
  mkdir -p "$dir"
  run_until_exit "$dir" 8077 8127 8227 120 "$@"
  rc=$?
  [ "$rc" -ne 0 ]
  assert "$name fails the start" $? "exit code was $rc"
  [ ! -d "$dir/data/state_machine" ] && [ ! -d "$dir/data/logs" ]
  assert "$name is refused before the storage layer starts" $? "a data directory exists at $dir/data"
}
t_refused "a zero user-expiry interval" "$WORK/t1-sched" SCHED_USER_EXP_MINS=0
t_refused "a cron expression that never fires again" "$WORK/t2-cron" \
  "JWK_AUTOROTATE_CRON=0 0 0 1 1 * 2020"
t_refused "a Matrix user without a room" "$WORK/t3-matrix" "EVENT_MATRIX_USER_ID=@bot:localhost" \
  EVENT_MATRIX_ACCESS_TOKEN=token
t_refused "an unknown fallback time zone" "$WORK/t4-tz" TZ_FALLBACK=Mars/Olympus_Mons
t_refused "S3 picture storage without its settings" "$WORK/t5-pic" PICTURE_STORAGE_TYPE=s3

# A panic that is still reachable after `DB::init()`: an API key bootstrapped with an invalid
# name is validated with `expect()` during the first start's bootstrap. The process still aborts,
# because a panic is a bug, but the panic hook shuts the storage layer down first.
log "T. A panic after the storage layer started shuts it down before the abort"
TP="$WORK/t6-panic"; mkdir -p "$TP"
BAD_KEY="$(printf '%s' '{"name":"not a valid name","exp":null,"access":[]}' | base64 | tr -d '\n')"
run_until_exit "$TP" 8076 8128 8228 300 "BOOTSTRAP_API_KEY=$BAD_KEY"
RC=$?
[ "$RC" -eq 134 ]
assert "the panic still aborts the process" $? "exit code was $RC"
grep -q 'The storage layer was shut down after the panic' "$TP/rauthy.log"
assert "the panic hook shut the storage layer down" $? "$(tail -4 "$TP/rauthy.log")"
mv "$TP/rauthy.log" "$TP/panic.log"
start_node "$TP" 8076 8128 8228
wait_ready "$TP" 8076 300
assert "the node starts after the panic" $? "see $TP/rauthy.log"
[ "$(unclean_markers "$TP")" = "0" ]
assert "the next start after the panic is clean" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$TP/rauthy.log" | head -3)"
stop_node "$TP"

# --- L: the metrics listener is an exit path too ------------------------------

log "L. A metrics listener that cannot start fails cleanly"
L="$WORK/l-metrics"; mkdir -p "$L"
# Occupy the metrics port before the node is asked to bind it.
python3 -c "
import socket, time, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 9090)); s.listen(1)
sys.stderr.write('bound\n'); sys.stderr.flush()
time.sleep(600)
" 2> "$L/squatter.log" &
SQUATTER=$!
HELPER_PIDS="$HELPER_PIDS $SQUATTER"
sleep 2

run_until_exit "$L" 8089 8119 8219 240 METRICS_ENABLE=true METRICS_ADDR=127.0.0.1 METRICS_PORT=9090
RC=$?
[ "$RC" -ne 0 ]
assert "a metrics listener that cannot bind fails the start" $? "exit code was $RC"
grep -qi 'metrics listener' "$L/rauthy.log"
assert "the failure names the metrics listener" $? "$(tail -3 "$L/rauthy.log")"

kill "$SQUATTER" 2>/dev/null; wait "$SQUATTER" 2>/dev/null
sleep 1

# The point of the leg: this exit path must also have gone through the storage shutdown, or the
# next start inherits an ungraceful one.
mv "$L/rauthy.log" "$L/metrics-failure.log"
start_node "$L" 8089 8119 8219 METRICS_ENABLE=true METRICS_ADDR=127.0.0.1 METRICS_PORT=9090
wait_ready "$L" 8089 300
assert "the node starts once the metrics port is free" $? "see $L/rauthy.log"
[ "$(unclean_markers "$L")" = "0" ]
assert "the metrics failure shut the storage layer down cleanly" $? \
  "$(grep -iE 'not a clean start|did not shut down gracefully|auto-rebuilding' "$L/rauthy.log" | head -3)"
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:9090/metrics" | grep -q 200
assert "metrics are served once the port is free" $?
stop_node "$L"

# --- K: observable unavailability after a storage failure --------------------

log "K. Observable unavailability after a critical storage failure"
DOCKER="$(command -v docker || command -v podman || true)"
if [ -z "$DOCKER" ]; then
  skip "readiness reports a storage failure" "no container runtime for the failure injection"
  skip "health reports a storage failure" "no container runtime for the failure injection"
else
  # Postgres is the backend that can be taken away from a running rauthy deterministically: stop
  # the container and every database call fails, which is what a terminal storage failure looks
  # like from the caller's side. The Hiqlite backend has no equivalent injection point from
  # outside the process.
  PGC="rauthy-acceptance-pg"
  HELPER_CONTAINERS="$HELPER_CONTAINERS $PGC"
  "$DOCKER" rm -f "$PGC" >/dev/null 2>&1
  "$DOCKER" run -d --name "$PGC" -e POSTGRES_USER=rauthy -e POSTGRES_PASSWORD=123SuperSafe \
    -e POSTGRES_DB=rauthy -p 5439:5432 docker.io/library/postgres:17.2-alpine >/dev/null 2>&1
  for _ in $(seq 1 60); do
    "$DOCKER" exec "$PGC" pg_isready -U rauthy >/dev/null 2>&1 && break
    sleep 1
  done

  K="$WORK/k-storage-failure"
  start_node "$K" 8090 8110 8210 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=5439 \
    PG_USER=rauthy PG_PASSWORD=123SuperSafe
  wait_ready "$K" 8090 300
  RC=$?
  if [ "$RC" -ne 0 ]; then
    bad "the Postgres-backed node comes up" "see $K/rauthy.log"
    skip "readiness reports a storage failure" "the node never came up"
    skip "health reports a storage failure" "the node never came up"
  else
    ok "the Postgres-backed node comes up"
    "$DOCKER" stop "$PGC" >/dev/null 2>&1

    # The health watcher confirms a failed probe before acting on it, so give it its first tick
    # plus the re-check plus one interval.
    READY_CODE=200
    for _ in $(seq 1 75); do
      READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8090/auth/v1/ready")"
      [ "$READY_CODE" = "503" ] && break
      sleep 2
    done
    [ "$READY_CODE" = "503" ]
    assert "readiness reports a storage failure" $? "/ready still answered $READY_CODE"

    HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8090/auth/v1/health")"
    [ "$HEALTH_CODE" = "500" ]
    assert "health reports a storage failure" $? "/health answered $HEALTH_CODE"
  fi
  stop_node "$K"
  "$DOCKER" rm -f "$PGC" >/dev/null 2>&1
fi

# --- Q: an interrupted run ----------------------------------------------------

log "Q. A node killed under write load, then restart and recovery"
# The graceful path is leg F. This is the other one: the process is killed outright, which is what
# an orchestrator does when a grace period runs out. Killing it *during* its storage shutdown
# cannot be scheduled from outside: at N = 1 that shutdown takes tens of milliseconds. Killing it
# while writes are in flight is deterministic and leaves the same thing behind, a data directory
# that was not shut down. The storage layer must recover on its own at the next start and keep
# everything that was acknowledged before.
Q="$WORK/q-interrupted"
start_node "$Q" 8081 8111 8211
wait_ready "$Q" 8081 300
assert "the node to be killed is serving" $? "see $Q/rauthy.log"
[ "$(create_group 8081 acceptance_before_kill)" = "200" ]
assert "a write is acknowledged before the kill" $?
KID_Q="$(jwks_kid 8081)"
( for i in $(seq 1 400); do create_group 8081 "acceptance_inflight_$i" > /dev/null; done ) &
LOAD=$!
HELPER_PIDS="$HELPER_PIDS $LOAD"
sleep 1
kill -KILL "$(cat "$Q/pid")" 2>/dev/null
kill "$LOAD" 2>/dev/null; wait "$LOAD" 2>/dev/null
for _ in $(seq 1 30); do [ -f "$Q/rc" ] && break; sleep 1; done
rm -f "$Q/pid"
[ "$(cat "$Q/rc" 2>/dev/null)" = "137" ]
assert "the node was killed, not shut down" $? "exit code was $(cat "$Q/rc" 2>/dev/null)"
mv "$Q/rauthy.log" "$Q/killed-run.log"
start_node "$Q" 8081 8111 8211
wait_ready "$Q" 8081 300
assert "the node recovers after being killed" $? "see $Q/rauthy.log"
# Without this the leg could pass on a directory that happened to be clean, and would then not
# have exercised recovery at all.
[ "$(unclean_markers "$Q")" != "0" ]
assert "the next start recognised the unclean shutdown" $?
group_exists 8081 acceptance_before_kill
assert "the write acknowledged before the kill survives it" $?
[ "$(jwks_kid 8081)" = "$KID_Q" ]
assert "the signing key survives the kill" $? "before: $KID_Q after: $(jwks_kid 8081)"
[ -n "$(admin_identity 8081)" ]
assert "the identity survives the kill" $?
[ "$(create_group 8081 acceptance_after_kill)" = "200" ]
assert "the recovered node accepts writes" $?
stop_node "$Q"
[ "$(cat "$Q/rc" 2>/dev/null)" = "0" ]
assert "the recovered node shuts down cleanly" $? "exit code was $(cat "$Q/rc" 2>/dev/null)"

# --- R: a restore aimed at a directory another process owns -------------------

log "R. A restore aimed at a data directory another process owns"
# A restore replaces the database, so it is the most destructive thing a start can do. Aimed at a
# directory a running node owns, it must be refused before anything is touched, and the running
# node must not notice.
if [ -z "${BACKUP_FILE:-}" ]; then
  skip "a restore into an owned directory is refused" "no backup file from leg G"
else
  R="$WORK/r-owned-restore"
  start_node "$R" 8082 8112 8212
  wait_ready "$R" 8082 300
  assert "the owning node is serving" $? "see $R/rauthy.log"
  [ "$(create_group 8082 acceptance_owned)" = "200" ]
  assert "the owning node has data of its own" $?
  KID_R="$(jwks_kid 8082)"
  R2="$WORK/r-owned-restore-second"; mkdir -p "$R2"; cp "$CONFIG_TEMPLATE" "$R2/config.toml"
  cp "$BACKUP_FILE" "$R2/backup.sqlite"
  (
    cd "$R2"
    env HQL_DATA_DIR="$R/data" HQL_NODES="1 localhost:8113 localhost:8213" \
      HQL_BACKUP_RESTORE="file:$R2/backup.sqlite" \
      LISTEN_ADDRESS=127.0.0.1 LISTEN_PORT_HTTP=8083 PUB_URL=localhost:8083 \
      RP_ORIGIN=http://localhost:8083 \
      BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" BOOTSTRAP_ADMIN_PASSWORD_PLAIN="$ADMIN_PASSWORD" \
      "$RAUTHY" serve -c config.toml > "$R2/rauthy.log" 2>&1
    echo $? > "$R2/rc"
  )
  RC="$(cat "$R2/rc" 2>/dev/null || echo 124)"
  [ "$RC" != "0" ]
  assert "a restore into an owned directory is refused" $? "exit code was $RC"
  grep -qE 'StorageInUse: .*owned by another live process.*has changed nothing' "$R2/rauthy.log"
  assert "the refused restore is the storage-ownership error" $? "$(tail -3 "$R2/rauthy.log")"
  ! grep -qE 'Found backup restore request|Starting database restore' "$R2/rauthy.log"
  assert "the refused restore did not start restoring" $? \
    "$(grep -iE 'restor' "$R2/rauthy.log" | head -3)"
  curl -s "http://127.0.0.1:8082/auth/v1/health" | grep -q '"db_healthy":true'
  assert "the owning node is unharmed by the refused restore" $?
  group_exists 8082 acceptance_owned
  assert "the owning node still has its own data" $?
  [ "$(jwks_kid 8082)" = "$KID_R" ]
  assert "the owning node kept its signing keys" $?
  stop_node "$R"
  mv "$R/rauthy.log" "$R/first-run.log"
  start_node "$R" 8082 8112 8212
  wait_ready "$R" 8082 300
  assert "the owning node restarts on its own data" $? "see $R/rauthy.log"
  group_exists 8082 acceptance_owned
  assert "the refused restore replaced nothing on disk" $?
  stop_node "$R"
fi

# --- P: a terminal failure of the embedded Hiqlite storage --------------------

log "P. A terminal failure of the embedded Hiqlite storage"
# Leg K takes Postgres away, which says nothing about the embedded backend. Here the Raft log
# directory of a running node stops accepting new files, so the next WAL rotation fails inside
# the log writer. That is a real I/O failure in the real writer, injected from outside the
# process: Hiqlite takes the node out of service and refuses operations, and Rauthy has to make
# that visible and must not keep answering as though it were healthy.
if [ "$(id -u)" = "0" ]; then
  skip "embedded storage failure is observable" "running as root, a read-only directory is not enforced"
else
  P="$WORK/p-hiqlite-failure"
  # A small log file so that a few hundred writes reach a rotation.
  start_node "$P" 8084 8114 8214 HQL_WAL_SIZE=262144
  wait_ready "$P" 8084 300
  assert "the node whose storage will fail is serving" $? "see $P/rauthy.log"
  [ "$(create_group 8084 acceptance_before_failure)" = "200" ]
  assert "a write succeeds before the failure" $?
  KID_P="$(jwks_kid 8084)"
  P_LOGS="$P/data/logs"
  [ -d "$P_LOGS" ]
  assert "the Raft log directory is where the injection expects it" $? "$(ls "$P/data")"
  chmod a-w "$P_LOGS"

  P_FAILED=1
  for i in $(seq 1 3000); do
    P_BODY="$(curl -s -w '\n%{http_code}' -X POST -H "$API_KEY_HEADER" \
      -H 'Content-Type: application/json' -d "{\"group\":\"acceptance_fill_$i\"}" \
      "http://127.0.0.1:8084/auth/v1/groups")"
    if [ "$(printf '%s' "$P_BODY" | tail -1)" != "200" ]; then P_FAILED=0; break; fi
  done
  assert "the injected storage failure reaches the writer" $P_FAILED "3000 writes were all accepted"
  # The write that meets the failure is refused on a different path from every later one: it is
  # the append the writer failed on, answered with the writer's own account, which names the log
  # directory. That must not reach the client either.
  echo "  INFO the write that met the failure: $(printf '%s' "$P_BODY" | tail -1)" \
    "$(printf '%s' "$P_BODY" | sed '$d' | head -c 200)"
  # A here-string, not a pipe: under pipefail a SIGPIPE in `printf | grep -q` would be negated
  # into a pass.
  ! grep -q "$P_LOGS" <<< "$P_BODY"
  assert "the write that meets the failure does not expose the storage path" $? \
    "$(printf '%s' "$P_BODY" | head -c 300)"

  READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8084/auth/v1/ready")"
  for _ in $(seq 1 10); do
    [ "$READY_CODE" = "503" ] && break
    sleep 1
    READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8084/auth/v1/ready")"
  done
  [ "$READY_CODE" = "503" ]
  assert "readiness reports the embedded storage failure within seconds" $? \
    "/ready answered $READY_CODE"
  HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8084/auth/v1/health")"
  [ "$HEALTH_CODE" = "500" ]
  assert "health reports the embedded storage failure" $? "/health answered $HEALTH_CODE"
  [ "$(create_group 8084 acceptance_after_failure)" != "200" ]
  assert "a write after the failure is refused" $?
  kill -0 "$(cat "$P/pid")" 2>/dev/null
  assert "the storage failure did not abort the process" $? "exit code $(cat "$P/rc" 2>/dev/null)"
  grep -q "out of service" "$P/rauthy.log"
  assert "the log names the node as out of service" $?
  # A failed node refuses its embedded client with `NodeFailed`, reads included, so a request
  # that has to touch storage is refused rather than answered from the last applied state. The
  # failure account names internal paths; the client gets a message without them.
  READ_BODY="$(curl -s -H "$API_KEY_HEADER" -w '\n%{http_code}' "http://127.0.0.1:8084/auth/v1/groups")"
  [ "$(printf '%s' "$READ_BODY" | tail -1)" != "200" ]
  assert "a read after the failure is refused" $? "the read answered 200"
  printf '%s' "$READ_BODY" | grep -q "storage layer of this node is out of service"
  assert "the refusal says the storage is out of service" $? "$(printf '%s' "$READ_BODY" | head -c 300)"
  # A here-string, not a pipe: under pipefail a SIGPIPE in `printf | grep -q` would be negated
  # into a pass.
  ! grep -q "$P_LOGS" <<< "$READ_BODY"
  assert "the refusal does not expose the storage path to the client" $?

  stop_node "$P"
  P_RC="$(cat "$P/rc" 2>/dev/null || echo none)"
  [ "$P_RC" != "none" ] && [ "$P_RC" != "137" ]
  assert "the failed node exits on SIGTERM without being killed" $? "exit code was $P_RC"
  chmod u+w "$P_LOGS"
  mv "$P/rauthy.log" "$P/failed-run.log"
  start_node "$P" 8084 8114 8214 HQL_WAL_SIZE=262144
  wait_ready "$P" 8084 300
  assert "the node recovers once its storage is writable again" $? "see $P/rauthy.log"
  group_exists 8084 acceptance_before_failure
  assert "a write acknowledged before the failure survives it" $?
  [ "$(jwks_kid 8084)" = "$KID_P" ]
  assert "the signing key survives the storage failure" $?
  [ "$(create_group 8084 acceptance_after_recovery)" = "200" ]
  assert "the recovered node accepts writes again" $?
  stop_node "$P"
fi

# --- summary -----------------------------------------------------------------

log "Summary"
printf '%s\n' "${RESULTS[@]}"
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
# One machine-readable line, so that a publication step can check the result instead of the
# exit code of a job that might have been configured to tolerate a failure.
printf '{"passed":%d,"failed":%d,"skipped":%d,"strict":%s}\n' "$PASS" "$FAIL" "$SKIP" \
  "$([ "${ACCEPTANCE_STRICT:-0}" = "1" ] && echo true || echo false)" > "$WORK/acceptance-result.json"
[ "$FAIL" -eq 0 ] || exit 1
if [ "${ACCEPTANCE_STRICT:-0}" = "1" ] && [ "$SKIP" -ne 0 ]; then
  echo "strict run: $SKIP leg(s) skipped, which a publication candidate does not allow" >&2
  exit 1
fi
