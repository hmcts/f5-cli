#!/usr/bin/env bash
# The bridge, end to end: f5-cli as the host-side server and as the container-side client.
#
#   bash tests/bridge.test.sh
#
# F5_IN_CONTAINER picks the side, so it runs the same on a laptop, in a container and in CI.
# The server runs the real f5-cli, but only `status` and `version`, which change nothing:
# with no VPN up, `status` reports no tunnel and exits 1 on every machine. On Linux it also
# runs `install.sh --bridge` with systemctl faked. Needs python3 and curl. Written for
# bash 3.2, like f5-cli.

# ok and no always succeed, so `test && ok || no` never runs both.
# shellcheck disable=SC2015
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
F5=$ROOT/bin/f5-cli
T=$(cd "$(mktemp -d)" && pwd -P)
SERVER=
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  [ -f "$T/installed.pid" ] && kill "$(cat "$T/installed.pid")" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$CASE" "$1"
  [ -s "$T/out" ] && sed 's/^/     | /' "$T/out"
}

command -v python3 >/dev/null && command -v curl >/dev/null || { echo "skip: needs python3 and curl"; exit 0; }

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

wait_for() {
  local _
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$1/" && return 0
    sleep 0.1
  done
  return 1
}

# container <bridge-file> args... — f5-cli on the container side, with nothing of the host's.
container() {
  local file=$1
  shift
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=1 F5_BRIDGE_FILE="$file" \
    F5_BRIDGE_HOST=127.0.0.1 /bin/bash "$F5" "$@" >"$T/out" 2>&1
}

mkdir -p "$T/home"
PORT=$(free_port)
printf 'PORT=%s\nTOKEN=%s\n' "$PORT" right-token >"$T/bridge"
printf 'PORT=%s\nTOKEN=%s\n' "$PORT" wrong-token >"$T/bridge-wrong"
printf 'PORT=%s\nTOKEN=%s\n' 1 right-token >"$T/bridge-down"

# ── no bridge ────────────────────────────────────────────────────────────────

CASE="no bridge"
container "$T/nope" status
rc=$?
[ "$rc" -eq 1 ] && grep -q 'no f5-cli bridge is set up' "$T/out" && ok "$CASE: status says how to set one up" \
  || no "expected a refusal"

CASE="no bridge"
container "$T/nope" bridge status
rc=$?
[ "$rc" -eq 2 ] && grep -q 'not set up' "$T/out" && ok "$CASE: bridge status exits 2" || no "expected exit 2"

CASE="bridge serve in a container"
container "$T/bridge" bridge serve
rc=$?
[ "$rc" -eq 1 ] && grep -q 'runs on the host' "$T/out" && ok "$CASE is refused" || no "expected a refusal"

# ── with the bridge ──────────────────────────────────────────────────────────

env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 F5_BRIDGE_FILE="$T/bridge" \
  /bin/bash "$F5" bridge serve 2>"$T/server.log" &
SERVER=$!
wait_for "$PORT" || { echo "the bridge never started:"; cat "$T/server.log"; exit 1; }

CASE="bridged status"
container "$T/bridge" status
rc=$?
[ "$rc" -eq 1 ] && grep -q '^tunnel: absent' "$T/out" && ! grep -q __f5_cli_bridge_exit__ "$T/out" \
  && ok "$CASE runs on the host and brings back its output and exit status" || no "expected the host's 'tunnel: absent' and exit 1"

CASE="bridge status"
container "$T/bridge" bridge status
rc=$?
[ "$rc" -eq 0 ] && grep -q "host runs f5-cli " "$T/out" && ok "$CASE answers with the host's version" || no "expected exit 0"

CASE="version"
container "$T/bridge" version
[ "$(cat "$T/out")" = "f5-cli $(sed -n 's/^VERSION=//p' "$F5")" ] && ok "$CASE stays local" || no "expected the local version"

CASE="bad token"
container "$T/bridge-wrong" up
rc=$?
[ "$rc" -eq 2 ] && grep -q 'bad token' "$T/out" && ok "$CASE is turned away before anything runs" || no "expected a 401"

CASE="command outside the list"
code=$(printf 'header = "Authorization: Bearer right-token"\n' \
  | curl -s -o "$T/out" -w '%{http_code}' --config - --data-raw 'status; reboot' "http://127.0.0.1:$PORT/run")
[ "$code" = 400 ] && ok "$CASE is refused by the server" || no "expected a 400, got $code"

CASE="bridge down"
container "$T/bridge-down" status
rc=$?
[ "$rc" -eq 1 ] && grep -q 'no answer from the f5-cli bridge' "$T/out" && ok "$CASE is reported" || no "expected 'no answer'"
container "$T/bridge-down" bridge status
rc=$?
[ "$rc" -eq 1 ] && grep -q 'not answering' "$T/out" && ok "$CASE: bridge status exits 1" || no "expected exit 1"

CASE="server log"
grep -q right-token "$T/server.log" && no "the token appeared in the server log" || ok "$CASE never shows the token"

# ── install.sh --bridge (Linux, systemctl faked) ───────────────────────────────

CASE="install.sh --bridge"
if [ "$(uname -s)" = Linux ]; then
  IPORT=$(free_port)
  mkdir -p "$T/fakebin"
  # The fake starts the installed bridge on `restart`, as systemd would.
  cat >"$T/fakebin/systemctl" <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"$T/systemctl.log"
if [ "\$2" = restart ]; then
  F5_IN_CONTAINER=0 "$T/prefix/bin/f5-cli" bridge serve >>"$T/installed.log" 2>&1 &
  echo \$! >"$T/installed.pid"
fi
exit 0
EOF
  chmod +x "$T/fakebin/systemctl"
  env HOME="$T/ihome" XDG_CONFIG_HOME="$T/ihome/.config" PATH="$T/fakebin:$PATH" F5_IN_CONTAINER=0 \
    /bin/bash "$ROOT/install.sh" --prefix "$T/prefix" --bridge --bridge-port "$IPORT" >"$T/out" 2>&1
  rc=$?
  unit="$T/ihome/.config/systemd/user/f5-cli-bridge.service"
  file="$T/ihome/.config/f5-cli/bridge"
  if [ "$rc" -eq 0 ] && grep -qx "ExecStart=$T/prefix/bin/f5-cli bridge serve" "$unit" \
    && grep -qx "PORT=$IPORT" "$file" && grep -Eqx 'TOKEN=[0-9a-f]{64}' "$file" \
    && [ -n "$(find "$file" -perm 600)" ] \
    && grep -q 'restart f5-cli-bridge.service' "$T/systemctl.log" \
    && grep -q "bridge listening on 127.0.0.1:$IPORT" "$T/out"; then
    ok "$CASE writes the unit and a private token, starts it, and checks it answers"
  else
    no "expected the unit, a 0600 token file and a bridge that answers"
  fi

  env HOME="$T/ihome" XDG_CONFIG_HOME="$T/ihome/.config" PATH="$T/fakebin:$PATH" \
    /bin/bash "$ROOT/install.sh" --prefix "$T/prefix" --uninstall >"$T/out" 2>&1
  [ ! -e "$unit" ] && [ ! -e "$file" ] && ok "install.sh --uninstall removes the unit and the token" \
    || no "expected both gone"
else
  echo "skip $CASE (Linux only)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
