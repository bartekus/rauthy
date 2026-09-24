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
#
# ACCEPTANCE_STOP_ON_FAIL=1 ends the run at the first failed assertion, keeping its directories.
# RAUTHY_FAULT names a test build with Hiqlite's `__upgrade-fault-points` feature, for leg J's
# interruption cases; without it they are skipped. J_EXPECT=published turns leg J into a negative
# control for a build on the published Hiqlite 0.15.0-patched.1 (see leg J).

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
         printf '  \033[31mFAIL\033[0m %s\n    %s\n' "$1" "${2:-}";
         # A bounded local run stops at the first unexpected failure and keeps its directories.
         if [ "${ACCEPTANCE_STOP_ON_FAIL:-0}" = "1" ]; then finish; fi; }
skip() { SKIP=$((SKIP + 1)); RESULTS+=("SKIP  $1: ${2:-}")
         printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "${2:-}"; }

assert() { # assert <name> <condition-result> <detail>
  if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# finish: the summary, the machine-readable result, and the exit code. Also reached from `bad`
# when ACCEPTANCE_STOP_ON_FAIL=1.
finish() {
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
  exit 0
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

# storage_state <http-port> - prints the `storage` field of /health, or nothing.
storage_state() {
  curl -s "http://127.0.0.1:$1/auth/v1/health" | grep -o '"storage":"[a-z]*"' | cut -d'"' -f4
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
#
# Hiqlite 035 (the N=1 upgrade exclusion) against the real upstream v0.36.2 binary. Every case
# gets its own copy of a data directory the upstream binary wrote, and its own ports where two
# processes share a directory, so that a refusal is about the storage locks and never about a
# port. The cases are a fixed list; each runs once.
#
# J_EXPECT=published runs the same cases as a negative control against a build on the published
# Hiqlite 0.15.0-patched.1: each `jcontrol` assertion is one that build is known to fail, and
# must fail; every other case assertion is recorded, not counted. RAUTHY_FAULT names a test build
# with Hiqlite's `__upgrade-fault-points` feature, which case J-F needs; it is never an image.

J_EXPECT="${J_EXPECT:-repaired}"
case "$J_EXPECT" in repaired|published) ;;
  *) echo "J_EXPECT must be repaired or published, not '$J_EXPECT'" >&2; exit 2 ;; esac
J_KEY_JSON='{"name":"acceptance","exp":null,"access":[{"group":"Users","access_rights":["read"]},{"group":"Groups","access_rights":["read","create"]},{"group":"Clients","access_rights":["read"]},{"group":"Blacklist","access_rights":["read","create"]}]}'
J_KEY_B64="$(printf '%s' "$J_KEY_JSON" | base64 | tr -d '\n')"
J_BAN_IP="192.0.2.77"

record() { RESULTS+=("RECORD $1: $2"); printf '  \033[36mRECORD\033[0m %s: %s\n' "$1" "$2"; }

# jassert: a case assertion. Asserted for the repaired build, recorded for the published one.
jassert() {
  if [ "$J_EXPECT" = "published" ]; then
    record "$1" "$([ "$2" = "0" ] && echo holds || echo "does not hold") on the published build"
  else
    assert "$@"
  fi
}

# jcontrol: an assertion the published build is known to fail. For it, the failure is the pass.
jcontrol() {
  if [ "$J_EXPECT" = "published" ]; then
    if [ "$2" != "0" ]; then ok "negative control fails on the published build: $1"
    else bad "negative control did not fail on the published build: $1" "${3:-}"; fi
  else
    assert "$@"
  fi
}

j_get() { curl -s -m 10 -H "Authorization: API-Key ${API_KEY_NAME}\$${API_KEY_SECRET}" \
  "http://127.0.0.1:$1/auth/v1/$2"; }
j_users()   { j_get "$1" users   | grep -o '"email":"[^"]*"' | sort -u | tr '\n' ' '; }
j_clients() { j_get "$1" clients | grep -o '"id":"[^"]*"'    | sort -u | tr '\n' ' '; }
j_groups()  { j_get "$1" groups  | grep -o '"name":"[^"]*"'  | sort -u | tr '\n' ' '; }
j_bans()    { j_get "$1" blacklist | grep -o '"ip":"[^"]*"'  | sort -u | tr '\n' ' '; }
# What must survive an upgrade: signing keys, users, clients, and rows written by upstream.
j_identity() { printf 'kid=%s|users=%s|clients=%s' "$(jwks_kid "$1")" "$(j_users "$1")" \
  "$(j_clients "$1")"; }
j_ban() {
  curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
    -H "Authorization: API-Key ${API_KEY_NAME}\$${API_KEY_SECRET}" -H 'Content-Type: application/json' \
    -d "{\"ip\":\"$J_BAN_IP\",\"exp\":$(( $(date +%s) + 86400 ))}" "http://127.0.0.1:$1/auth/v1/blacklist"
}
j_inode() { ls -di "$1" 2>/dev/null | awk '{print $1}'; }
# A lock file is held when it exists and a non-blocking flock on it fails. Existence first,
# because flock(1) creates a missing file.
j_held() { [ -e "$1" ] && ! flock -n "$1" true; }
j_pre_upgrade() { find "$1" -maxdepth 1 -type d -name 'pre-upgrade-*' | sort; }
# j_case <name> <gold>: a fresh case directory holding a copy of a gold data directory.
j_case() {
  local d="$WORK/j-$1"; rm -rf "$d"; mkdir -p "$d"; cp "$CONFIG_TEMPLATE" "$d/config.toml"
  cp -a "$2" "$d/data"; echo "$d"
}
# The one-upgrade-start state a case ends in: exactly one final pre-upgrade directory, nothing
# partial or staged, and the legacy cache in it byte-identical to what upstream left.
j_moved_once() {
  local data="$1" gold="$2" moved
  moved="$(j_pre_upgrade "$data")"
  [ "$(printf '%s\n' "$moved" | grep -c .)" = "1" ] || return 1
  case "$moved" in *.partial) return 1 ;; esac
  [ ! -e "$data/logs_cache.hiqlite-next" ] || return 1
  diff -r -x lock.hql "$gold/logs_cache" "$moved/logs_cache" > /dev/null || return 1
  diff -r "$gold/state_machine_cache" "$moved/state_machine_cache" > /dev/null || return 1
  [ "$(cat "$data/logs_cache/hiqlite-cache-log-format" 2>/dev/null)" = "2" ]
}
JP="8099 8109 8209"   # the ports the directory's own node uses
JQ="8098 8108 8208"   # a second process on the same directory
JENV=(BOOTSTRAP_API_KEY="$J_KEY_B64")

log "J. Upgrade from the upstream baseline (expecting: $J_EXPECT)"
if [ -z "$UPSTREAM" ]; then
  skip "upgrade from the upstream baseline" "no upstream binary given"
  skip "rollback to the upstream baseline" "no upstream binary given"
else
  # Gold: a directory upstream v0.36.2 initialized, wrote to, banned an address in, and stopped
  # cleanly. Every case copies it; nothing runs on it.
  JG="$WORK/j-gold"; rm -rf "$JG"
  BIN="$UPSTREAM" start_node "$JG" $JP "${JENV[@]}"
  wait_ready "$JG" 8099 120
  assert "J: the upstream baseline boots and populates a data directory" $? "see $JG/rauthy.log"
  [ "$(create_group 8099 j_written_by_upstream)" = "200" ]
  assert "J: the upstream baseline accepts a write" $?
  [ "$(j_ban 8099)" = "200" ] && [ -n "$(j_bans 8099)" ]
  assert "J: the upstream baseline holds a manual IP ban (cache-only state)" $? "$(j_bans 8099)"
  J_ID_UP="$(j_identity 8099)"
  [ -n "$(jwks_kid 8099)" ] && [ -n "$(j_users 8099)" ] && [ -n "$(j_clients 8099)" ]
  assert "J: keys, users and clients are readable for comparison" $? "$J_ID_UP"
  stop_node "$JG"
  [ "$(cat "$JG/rc" 2>/dev/null)" = "0" ]
  assert "J: the upstream baseline stops cleanly" $? "exit $(cat "$JG/rc" 2>/dev/null)"
  J_GOLD="$WORK/j-gold-data"; rm -rf "$J_GOLD"; cp -a "$JG/data" "$J_GOLD"

  # Gold, killed: the same directory, one more acknowledged write, then SIGKILL, which leaves
  # the WAL lock files and `state_machine/lock`.
  JK="$(j_case gold-killed-run "$J_GOLD")"
  BIN="$UPSTREAM" start_node "$JK" $JP "${JENV[@]}"
  wait_ready "$JK" 8099 60
  assert "J: the upstream baseline restarts on its own directory" $? "see $JK/rauthy.log"
  [ "$(create_group 8099 j_written_before_the_kill)" = "200" ]
  assert "J: the upstream baseline acknowledges a write before the kill" $?
  kill -KILL "$(cat "$JK/pid")"; sleep 2; rm -f "$JK/pid"
  [ -e "$JK/data/state_machine/lock" ]
  assert "J: the killed upstream node left its unclean-stop marker" $? "$(ls "$JK/data/state_machine")"
  J_GOLD_KILLED="$WORK/j-gold-killed-data"; rm -rf "$J_GOLD_KILLED"; cp -a "$JK/data" "$J_GOLD_KILLED"

  # J-A. No consent: a refusal that says what it created, and nothing else changed.
  log "J-A. Upgrade without consent"
  JA="$(j_case a "$J_GOLD")"
  run_until_exit "$JA" $JP 60 "${JENV[@]}"; RC=$?
  [ "$RC" -ne 0 ] && [ "$RC" -ne 134 ] && [ "$RC" -ne 124 ]
  jassert "J-A: an upgrade without consent is refused, not aborted" $? "exit code was $RC"
  grep -q "logs_cache" "$JA/rauthy.log" && grep -q "HQL_CACHE_LEGACY_MOVE_ASIDE=true" "$JA/rauthy.log"
  jassert "J-A: the refusal names the cache log and the consent variable" $? "$(tail -3 "$JA/rauthy.log")"
  ! grep -q "Nothing was changed" "$JA/rauthy.log" \
    && grep -q "this start created .*hiqlite-owner.lock" "$JA/rauthy.log"
  jcontrol "J-A: the refusal names the owner lock it created instead of claiming nothing changed" $? \
    "$(grep -o 'Nothing was changed.*\|No data was changed.*' "$JA/rauthy.log" | head -1)"
  diff -r -x hiqlite-owner.lock "$JA/data" "$J_GOLD" > /dev/null
  jassert "J-A: apart from the owner lock, every file is byte-identical" $? \
    "$(diff -rq -x hiqlite-owner.lock "$JA/data" "$J_GOLD" | head -5)"

  # J-B and J-C. A live upstream node on the directory. The candidate is refused before any
  # rename, with and without consent, and the upstream node goes on, stops cleanly, restarts.
  for jc in B C; do
    # Without consent the published build also refuses and renames nothing; only which lock it
    # names tells the two apart there.
    if [ "$jc" = "B" ]; then JCON=(HQL_CACHE_LEGACY_MOVE_ASIDE=true); jw="with"; jb=jcontrol
    else JCON=(); jw="without"; jb=jassert; fi
    log "J-$jc. A live upstream node, candidate $jw consent"
    JL="$(j_case "$jc-live" "$J_GOLD")"
    BIN="$UPSTREAM" start_node "$JL" $JP "${JENV[@]}"
    wait_ready "$JL" 8099 60
    assert "J-$jc: the upstream node serves the directory" $? "see $JL/rauthy.log"
    INODE_BEFORE="$(j_inode "$JL/data/logs_cache")"
    JS="$WORK/j-$jc-second"; rm -rf "$JS"; mkdir -p "$JS"; cp "$CONFIG_TEMPLATE" "$JS/config.toml"
    run_until_exit "$JS" $JQ 60 "${JENV[@]}" HQL_DATA_DIR="$JL/data" "${JCON[@]}"; RC=$?
    [ "$RC" -ne 0 ] && [ "$RC" -ne 134 ] && [ "$RC" -ne 124 ]
    $jb "J-$jc: the candidate is refused, not aborted" $? "exit code was $RC"
    grep -q "lock.hql is locked by another live process" "$JS/rauthy.log"
    jcontrol "J-$jc: the refusal is the live node's WAL lock" $? "$(tail -3 "$JS/rauthy.log")"
    [ -z "$(j_pre_upgrade "$JL/data")" ] && [ "$(j_inode "$JL/data/logs_cache")" = "$INODE_BEFORE" ]
    $jb "J-$jc: nothing was renamed under the live node" $? \
      "pre-upgrade: $(j_pre_upgrade "$JL/data") inode $INODE_BEFORE -> $(j_inode "$JL/data/logs_cache")"
    [ "$(create_group 8099 "j_written_after_refusal_$jc")" = "200" ]
    jassert "J-$jc: the upstream node still accepts writes" $?
    stop_node "$JL"
    [ "$(cat "$JL/rc" 2>/dev/null)" = "0" ]
    jassert "J-$jc: the upstream node stops cleanly" $? "exit $(cat "$JL/rc" 2>/dev/null)"
    mv "$JL/rauthy.log" "$JL/upstream-first.log"
    BIN="$UPSTREAM" start_node "$JL" $JP "${JENV[@]}"
    wait_ready "$JL" 8099 60
    jassert "J-$jc: the upstream node restarts" $? "see $JL/rauthy.log"
    group_exists 8099 j_written_by_upstream && group_exists 8099 "j_written_after_refusal_$jc"
    jassert "J-$jc: the restarted upstream node has every row" $?
    # A plain restart of the same version keeps the disk-backed cache (correction C-6).
    [ -n "$(j_bans 8099)" ]
    jassert "J-$jc: a plain upstream restart keeps the manual IP ban" $? "$(j_bans 8099)"
    stop_node "$JL"
  done

  # J-D. Upstream was killed. Rauthy builds Hiqlite with `auto-heal`, so the unclean-stop marker
  # is the rebuild policy, not a refusal: the move and the rebuild run under the held locks.
  log "J-D. A killed upstream node, candidate with consent (auto-heal)"
  JD="$(j_case d "$J_GOLD_KILLED")"
  start_node "$JD" $JP "${JENV[@]}" HQL_CACHE_LEGACY_MOVE_ASIDE=true
  wait_ready "$JD" 8099 90
  jassert "J-D: the candidate starts over the killed node's directory" $? "$(tail -3 "$JD/rauthy.log")"
  j_moved_once "$JD/data" "$J_GOLD_KILLED"
  jassert "J-D: the move completed once, the legacy cache byte-identical" $? "$(ls "$JD/data")"
  [ "$(j_identity 8099)" = "$J_ID_UP" ] && group_exists 8099 j_written_by_upstream \
    && group_exists 8099 j_written_before_the_kill
  jassert "J-D: keys, users, clients and every acknowledged row survive the rebuild" $? \
    "$(j_identity 8099)"
  record "J-D: unclean-stop messages in the candidate's log" "$(unclean_markers "$JD")"
  j_held "$JD/data/logs/lock.hql" && j_held "$JD/data/logs_cache/lock.hql" \
    && j_held "$JD/data/hiqlite-owner.lock"
  jassert "J-D: the owner lock and both WAL locks are held while it serves" $?
  stop_node "$JD"
  [ "$(cat "$JD/rc" 2>/dev/null)" = "0" ]
  jassert "J-D: the rebuilt node stops cleanly" $? "exit $(cat "$JD/rc" 2>/dev/null)"

  # J-E. The upgrade itself, as the handoff states it, with the archive an operator takes first.
  log "J-E. The consent upgrade"
  JE="$(j_case e "$J_GOLD")"
  cp -a "$JE/data" "$JE/archive-before-upgrade"
  start_node "$JE" $JP "${JENV[@]}" HQL_CACHE_LEGACY_MOVE_ASIDE=true
  wait_ready "$JE" 8099 90
  jassert "J-E: the candidate starts with consent" $? "$(tail -3 "$JE/rauthy.log")"
  j_moved_once "$JE/data" "$J_GOLD"
  jassert "J-E: the move completed once, the legacy cache byte-identical" $? "$(ls "$JE/data")"
  [ "$(j_identity 8099)" = "$J_ID_UP" ] && group_exists 8099 j_written_by_upstream
  jassert "J-E: keys, users, clients and upstream rows survive" $? "$(j_identity 8099)"
  [ "$(unclean_markers "$JE")" = "0" ]
  jassert "J-E: the upgrade did not rebuild the state machine" $?
  # The list is read successfully and is empty; a failed read must not pass as "no bans".
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: API-Key ${API_KEY_NAME}\$${API_KEY_SECRET}" \
    http://127.0.0.1:8099/auth/v1/blacklist)" = "200" ] && [ -z "$(j_bans 8099)" ]
  jassert "J-E: the cache starts empty: the manual IP ban is gone (C-6)" $? "$(j_bans 8099)"
  j_held "$JE/data/logs/lock.hql" && j_held "$JE/data/logs_cache/lock.hql" \
    && j_held "$JE/data/hiqlite-owner.lock"
  jassert "J-E: the owner lock and both WAL locks are held while it serves" $?
  [ "$(create_group 8099 j_written_by_the_candidate)" = "200" ]
  jassert "J-E: the upgraded node accepts writes" $?
  stop_node "$JE"
  [ "$(cat "$JE/rc" 2>/dev/null)" = "0" ] && [ ! -e "$JE/data/logs/lock.hql" ] \
    && [ ! -e "$JE/data/logs_cache/lock.hql" ]
  jassert "J-E: a clean stop removes both WAL lock files" $? "exit $(cat "$JE/rc" 2>/dev/null)"
  mv "$JE/rauthy.log" "$JE/upgrade-run.log"
  start_node "$JE" $JP "${JENV[@]}"
  wait_ready "$JE" 8099 60
  jassert "J-E: the upgraded node restarts without consent" $? "see $JE/rauthy.log"
  group_exists 8099 j_written_by_the_candidate && [ "$(unclean_markers "$JE")" = "0" ]
  jassert "J-E: the restart is clean and keeps the candidate's row" $?
  stop_node "$JE"

  # J-H. The supported way back (C-4): the archive taken before the upgrade, restored into a
  # fresh volume, started by upstream. What was written after the upgrade is lost, as stated.
  # It runs straight after J-E, before J-F and J-G kill nodes on these ports: a raft port a
  # killed node held can stay unbindable for a while, and hiqlite 0.14 then panics with
  # AddrInUse (seen against the published build, where J-G's refusal does not happen).
  log "J-H. Rollback from the pre-upgrade archive into a fresh volume"
  JH="$(j_case h "$JE/archive-before-upgrade")"
  BIN="$UPSTREAM" start_node "$JH" $JP "${JENV[@]}"
  wait_ready "$JH" 8099 60
  jassert "J-H: upstream starts from the restored archive" $? "$(tail -3 "$JH/rauthy.log")"
  [ "$(j_identity 8099)" = "$J_ID_UP" ] && group_exists 8099 j_written_by_upstream \
    && ! group_exists 8099 j_written_by_the_candidate
  jassert "J-H: the archive's state, without what the upgraded node wrote" $? "$(j_groups 8099)"
  stop_node "$JH"
  [ "$(cat "$JH/rc" 2>/dev/null)" = "0" ]
  jassert "J-H: upstream stops cleanly" $? "exit $(cat "$JH/rc" 2>/dev/null)"

  # J-F. The candidate killed at each of Hiqlite's documented fault points (035 B-5).
  log "J-F. Interrupted consent moves"
  if [ "$J_EXPECT" = "published" ]; then
    record "J-F" "not applicable: the published build has no fault points (J-G is its control)"
  elif [ -z "${RAUTHY_FAULT:-}" ]; then
    skip "J-F: interrupted consent moves" "no RAUTHY_FAULT build given"
  else
    for point in after-db-lock after-cache-lock after-partial-created after-snapshots-moved \
                 after-staged after-legacy-log-moved after-log-moved; do
      JF="$(j_case "f-$point" "$J_GOLD")"
      BIN="$RAUTHY_FAULT" run_until_exit "$JF" $JP 60 "${JENV[@]}" \
        HQL_CACHE_LEGACY_MOVE_ASIDE=true HQL_TEST_UPGRADE_FAULT="$point"; RC=$?
      [ "$RC" = "134" ] && grep -q "HQL_TEST_UPGRADE_FAULT: aborting at $point" "$JF/rauthy.log"
      assert "J-F $point: the fault build aborted at that point" $? "exit $RC"
      mv "$JF/rauthy.log" "$JF/fault.log"
      run_until_exit "$JF" $JP 60 "${JENV[@]}"; RC=$?
      [ "$RC" -ne 0 ] && [ "$RC" -ne 134 ] && [ "$RC" -ne 124 ] \
        && grep -q "HQL_CACHE_LEGACY_MOVE_ASIDE=true" "$JF/rauthy.log"
      assert "J-F $point: the next start without consent is refused, naming it" $? \
        "exit $RC: $(tail -2 "$JF/rauthy.log")"
      mv "$JF/rauthy.log" "$JF/refused.log"
      start_node "$JF" $JP "${JENV[@]}" HQL_CACHE_LEGACY_MOVE_ASIDE=true
      wait_ready "$JF" 8099 90
      assert "J-F $point: the next start with consent completes" $? "$(tail -3 "$JF/rauthy.log")"
      j_moved_once "$JF/data" "$J_GOLD"
      assert "J-F $point: one operation, legacy cache byte-identical, nothing staged" $? \
        "$(ls "$JF/data")"
      [ "$(j_identity 8099)" = "$J_ID_UP" ] && group_exists 8099 j_written_by_upstream
      assert "J-F $point: keys, users, clients and rows survive" $? "$(j_identity 8099)"
      stop_node "$JF"
      [ "$(cat "$JF/rc" 2>/dev/null)" = "0" ]
      assert "J-F $point: the resumed node stops cleanly" $? "exit $(cat "$JF/rc" 2>/dev/null)"
    done
  fi

  # J-G. What the published build leaves after a crash between its two renames: the legacy log
  # moved, the 0.14 snapshots still in place, no format marker (Hiqlite F-130). Constructed.
  log "J-G. The published build's interrupted move"
  JGS="$(j_case g "$J_GOLD")"
  mkdir "$JGS/data/pre-upgrade-1700000000"
  mv "$JGS/data/logs_cache" "$JGS/data/pre-upgrade-1700000000/"
  run_until_exit "$JGS" $JP 60 "${JENV[@]}"; RC=$?
  [ "$RC" -ne 0 ] && [ "$RC" -ne 134 ] && [ "$RC" -ne 124 ] \
    && grep -q "interrupted between its two renames" "$JGS/rauthy.log"
  jcontrol "J-G: without consent the start is refused, not the 0.14 snapshot restored" $? \
    "exit $RC: $(tail -2 "$JGS/rauthy.log")"
  mv "$JGS/rauthy.log" "$JGS/refused.log"
  start_node "$JGS" $JP "${JENV[@]}" HQL_CACHE_LEGACY_MOVE_ASIDE=true
  wait_ready "$JGS" 8099 90
  jassert "J-G: with consent the start finishes the move" $? "$(tail -3 "$JGS/rauthy.log")"
  j_moved_once "$JGS/data" "$J_GOLD"
  jassert "J-G: the snapshots joined the log in the one directory, byte-identical" $? \
    "$(ls "$JGS/data" "$JGS/data/pre-upgrade-1700000000")"
  [ "$(j_identity 8099)" = "$J_ID_UP" ] && group_exists 8099 j_written_by_upstream
  jassert "J-G: keys, users, clients and rows survive" $? "$(j_identity 8099)"
  stop_node "$JGS"

  # J-I. Upstream started over the upgraded directory. Unsupported (C-4, Hiqlite B-4): recorded,
  # never passed or failed. It runs on its own copy, so nothing above depends on it.
  log "J-I. Upstream over the upgraded directory (recorded, unsupported)"
  JI="$(j_case i "$JE/data")"
  BIN="$UPSTREAM" run_until_exit "$JI" $JP 60 "${JENV[@]}"; RC=$?
  record "J-I: upstream exit code over an upgraded directory" "$RC (124 = still running at 60 s)"
  record "J-I: its last log line" "$(tail -1 "$JI/rauthy.log" | cut -c1-200)"
  record "J-I: meta.hql sizes afterwards (logs, logs_cache)" \
    "$(wc -c < "$JI/data/logs/meta.hql" 2>/dev/null | tr -d ' '), $(wc -c < "$JI/data/logs_cache/meta.hql" 2>/dev/null | tr -d ' ')"
  record "J-I: state_machine/lock left behind" "$([ -e "$JI/data/state_machine/lock" ] && echo yes || echo no)"
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
  for k_leg in "readiness reports a storage failure" "health reports a storage failure" \
    "a Postgres failure is reported degraded, not terminal" \
    "health returns to storage ok once Postgres is back, without a restart" \
    "readiness returns once Postgres is back, without a restart"; do
    skip "$k_leg" "no container runtime for the failure injection"
  done
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
    for k_leg in "readiness reports a storage failure" "health reports a storage failure" \
      "a Postgres failure is reported degraded, not terminal" \
      "health returns to storage ok once Postgres is back, without a restart" \
      "readiness returns once Postgres is back, without a restart"; do
      skip "$k_leg" "the node never came up"
    done
  else
    ok "the Postgres-backed node comes up"
    K_STATE="$(storage_state 8090)"
    [ "$K_STATE" = "ok" ]
    assert "health reports storage ok on a healthy Postgres-backed node" $? "storage: $K_STATE"
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
    # An unreachable Postgres is recoverable: it must never be labelled terminal, which is the
    # embedded node's state alone.
    K_STATE="$(storage_state 8090)"
    [ "$K_STATE" = "degraded" ]
    assert "a Postgres failure is reported degraded, not terminal" $? "storage: $K_STATE"

    # The same process, with the database back: no restart.
    "$DOCKER" start "$PGC" >/dev/null 2>&1
    for _ in $(seq 1 60); do
      "$DOCKER" exec "$PGC" pg_isready -U rauthy >/dev/null 2>&1 && break
      sleep 1
    done
    K_STATE=""
    for _ in $(seq 1 30); do
      K_STATE="$(storage_state 8090)"
      [ "$K_STATE" = "ok" ] && break
      sleep 2
    done
    [ "$K_STATE" = "ok" ]
    assert "health returns to storage ok once Postgres is back, without a restart" $? \
      "storage: $K_STATE"
    READY_CODE=503
    for _ in $(seq 1 45); do
      READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8090/auth/v1/ready")"
      [ "$READY_CODE" = "200" ] && break
      sleep 2
    done
    [ "$READY_CODE" = "200" ]
    assert "readiness returns once Postgres is back, without a restart" $? \
      "/ready still answered $READY_CODE"
    [ -f "$K/rc" ]
    [ $? -ne 0 ]
    assert "the Postgres-backed node was not restarted" $? "exit code $(cat "$K/rc" 2>/dev/null)"
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
  P_STATE="$(storage_state 8084)"
  [ "$P_STATE" = "ok" ]
  assert "health reports storage ok on a fresh node" $? "storage: $P_STATE"
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
  P_STATE="$(storage_state 8084)"
  [ "$P_STATE" = "terminal" ]
  assert "health reports the embedded storage failure as terminal" $? "storage: $P_STATE"
  # Terminal is final for the process. Rahi's R-1 asks for three more samples; each is taken at
  # least one health-watcher interval (30 s) after the last, so that every sample follows a
  # watcher tick. Nothing in the watcher is expected to clear it: this checks the contract end to
  # end rather than a known way for it to fail.
  P_PERSIST=0
  for i in 1 2 3; do
    sleep 31
    P_STATE="$(storage_state 8084)"
    [ "$P_STATE" = "terminal" ] || { P_PERSIST=1; break; }
  done
  assert "terminal persists across three more watcher intervals" $P_PERSIST \
    "sample $i answered storage: $P_STATE"
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
  P_STATE="$(storage_state 8084)"
  [ "$P_STATE" = "ok" ]
  assert "a restart after the fault is cleared reports storage ok" $? "storage: $P_STATE"
  group_exists 8084 acceptance_before_failure
  assert "a write acknowledged before the failure survives it" $?
  [ "$(jwks_kid 8084)" = "$KID_P" ]
  assert "the signing key survives the storage failure" $?
  [ "$(create_group 8084 acceptance_after_recovery)" = "200" ]
  assert "the recovered node accepts writes again" $?
  stop_node "$P"
fi

# --- U: a terminal failure inside the startup health window -------------------

log "U. A terminal failure inside HEALTH_CHECK_DELAY_SECS"
# Inside the window /health does not check storage and reports both layers healthy, so a
# terminal failure there has to come from Hiqlite's own record, not from a check. Same injection
# as leg P.
if [ "$(id -u)" = "0" ]; then
  skip "a terminal failure inside the startup window is reported" \
    "running as root, a read-only directory is not enforced"
else
  U="$WORK/u-early-terminal"
  start_node "$U" 8075 8125 8225 HQL_WAL_SIZE=262144 HEALTH_CHECK_DELAY_SECS=3600
  wait_ready "$U" 8075 300
  assert "the node with a one-hour health window is serving" $? "see $U/rauthy.log"
  U_STATE="$(storage_state 8075)"
  U_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8075/auth/v1/health")"
  [ "$U_STATE" = "unknown" ] && [ "$U_CODE" = "200" ]
  assert "inside the window health answers 200 and storage unknown" $? \
    "/health answered $U_CODE, storage: $U_STATE"
  chmod a-w "$U/data/logs"
  U_FAILED=1
  for i in $(seq 1 3000); do
    [ "$(create_group 8075 "acceptance_fill_$i")" != "200" ] && { U_FAILED=0; break; }
  done
  assert "the injected storage failure reaches the writer inside the window" $U_FAILED \
    "3000 writes were all accepted"
  # Hiqlite records the failure from its own watcher task, so allow it a moment, as leg P does.
  for _ in $(seq 1 10); do
    U_STATE="$(storage_state 8075)"
    [ "$U_STATE" = "terminal" ] && break
    sleep 1
  done
  U_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8075/auth/v1/health")"
  [ "$U_STATE" = "terminal" ] && [ "$U_CODE" = "500" ]
  assert "inside the window a terminal failure is reported terminal with 500" $? \
    "/health answered $U_CODE, storage: $U_STATE"
  U_READY="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8075/auth/v1/ready")"
  [ "$U_READY" = "503" ]
  assert "inside the window readiness answers 503 after a terminal failure" $? \
    "/ready answered $U_READY"
  # The body carries the state and nothing of the failure's account.
  U_BODY="$(curl -s "http://127.0.0.1:8075/auth/v1/health")"
  ! grep -q "$U/data" <<< "$U_BODY"
  assert "health exposes no storage path" $? "$U_BODY"
  stop_node "$U"
  chmod u+w "$U/data/logs"
fi

# --- summary -----------------------------------------------------------------

finish
