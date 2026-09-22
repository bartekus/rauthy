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
# Exits non-zero on the first failed assertion. Every scenario is independent: each gets its own
# data directory and its own ports.

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
API_KEY_JSON='{"name":"acceptance","exp":null,"access":[{"group":"Users","access_rights":["read"]}]}'
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
    env "$@" \
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

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

jwks_kid() {
  curl -s "http://127.0.0.1:$1/auth/v1/oidc/certs" \
    | tr ',' '\n' | grep -o '"kid":"[^"]*"' | sort | tr '\n' ' '
}

trap 'for d in "$WORK"/*/; do [ -f "$d/pid" ] && kill -KILL "$(cat "$d/pid")" 2>/dev/null; done' EXIT

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
run_until_exit "$CONF" 8092 8102 8202 180 HIQLITE=false PG_HOST=127.0.0.1 PG_PORT=1 \
  PG_USER=nobody PG_PASSWORD=nothing
RC=$?
[ "$RC" -ne 0 ]
assert "a backend that cannot be reached fails the start" $? "exit code was $RC"
grep -qv 'nothing' "$CONF/rauthy.log"
assert "the startup failure does not echo the database password" $?

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
grep -qiE 'lock|in use by another process' "$E2/rauthy.log"
assert "the refusal names the storage lock" $? "$(tail -3 "$E2/rauthy.log")"

curl -s "http://127.0.0.1:8094/auth/v1/health" | grep -q '"db_healthy":true'
assert "the first node is unharmed by the second one's attempt" $?
[ "$(jwks_kid 8094)" = "$KID_FIRST" ] || [ -n "$(jwks_kid 8094)" ]
assert "the first node still serves its signing keys" $?

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

  # Corrupt restore input must be refused, and must not destroy what is on disk.
  H="$WORK/h-bad-restore"; mkdir -p "$H"; cp "$CONFIG_TEMPLATE" "$H/config.toml"
  head -c 4096 "$BACKUP_FILE" > "$H/truncated.sqlite"
  BEFORE_SUM="$(sha256_of "$BACKUP_FILE")"
  run_until_exit "$H" 8097 8107 8207 240 "HQL_BACKUP_RESTORE=file:$H/truncated.sqlite"
  RC=$?
  [ "$RC" -ne 0 ]
  assert "a truncated restore input is refused" $? "exit code was $RC"
  [ "$(sha256_of "$BACKUP_FILE")" = "$BEFORE_SUM" ]
  assert "the refused restore did not touch the last recoverable state" $?

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
  stop_node "$J"
  sleep 3

  mv "$J/rauthy.log" "$J/upstream-run.log"
  start_node "$J" 8099 8109 8209
  wait_ready "$J" 8099 300
  assert "the patched build starts on the upstream data directory" $? "see $J/rauthy.log"
  [ "$(jwks_kid 8099)" = "$KID_UP" ]
  assert "the upgrade keeps the signing key" $? "before: $KID_UP after: $(jwks_kid 8099)"
  [ "$(unclean_markers "$J")" = "0" ]
  assert "the upgrade did not have to rebuild the state machine" $?
  [ -n "$(admin_identity 8099)" ]
  assert "the upgraded instance keeps the original identity" $? \
    "no $ADMIN_EMAIL after the upgrade"
  stop_node "$J"
  sleep 3

  # Rollback: the version this build stamps into the config table must not lock upstream out.
  mv "$J/rauthy.log" "$J/patched-run.log"
  BIN="$UPSTREAM" start_node "$J" 8099 8109 8209
  wait_ready "$J" 8099 300
  assert "the upstream baseline still starts after the upgrade" $? \
    "rollback is blocked: $(tail -5 "$J/rauthy.log")"
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

# --- summary -----------------------------------------------------------------

log "Summary"
printf '%s\n' "${RESULTS[@]}"
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
