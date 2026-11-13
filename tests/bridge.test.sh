#!/usr/bin/env bash
# The bridge, end to end: f5-cli as the host-side server and as the container-side client.
#
#   bash tests/bridge.test.sh
#
# F5_IN_CONTAINER picks the side, so it runs the same on a laptop, in a container and in CI.
# The server runs the real f5-cli, but only commands that change nothing: `status` and
# `version` (with no VPN up, `status` reports no tunnel and exits 1 on every machine), `dns`
# on a fake resolv.conf, and, on Linux, `up` against a faked client, tunnel and portal.
# On Linux it also runs `install.sh --bridge` with systemctl faked. Needs python3 and curl. Written for
# bash 3.2, like f5-cli.

# ok and no always succeed, so `test && ok || no` never runs both.
# shellcheck disable=SC2015
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
F5=$ROOT/bin/f5-cli
T=$(cd "$(mktemp -d)" && pwd -P)
SERVERS=
cleanup() {
  local p
  for p in $SERVERS; do kill "$p" && wait "$p"; done 2>/dev/null
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
# TEST_CONFIG gives it a config file; TEST_BRIDGE_HOST= leaves the bridge host to it.
container() {
  local file=$1
  shift
  env HOME="$T/home" F5_CLI_CONFIG="${TEST_CONFIG:-/dev/null}" F5_IN_CONTAINER=1 F5_BRIDGE_FILE="$file" \
    F5_BRIDGE_HOST="${TEST_BRIDGE_HOST-127.0.0.1}" /bin/bash "$F5" "$@" >"$T/out" 2>&1
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
  F5_RESOLV_CONF="$T/host-resolv" /bin/bash "$F5" bridge serve 2>"$T/server.log" &
SERVERS=$!
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

# ── dns ──────────────────────────────────────────────────────────────────────
#
# F5_RESOLV_CONF stands in for /etc/resolv.conf on each side: the host's
# fixture on the host, $T/target in the container. A hard link to the target shows it was written in place, as a
# bind-mounted /etc/resolv.conf has to be.

STUB='nameserver 127.0.0.53'
reset_target() { printf '%s\n' "$STUB" >"$T/target"; rm -f "$T/target-link"; ln "$T/target" "$T/target-link"; }

if [ "$(uname -s)" = Linux ]; then
  cat >"$T/host-resolv-file" <<'RESOLV'
# Generated by NetworkManager
nameserver 10.11.75.4
search platform.hmcts.net
sortlist 10.0.0.0
RESOLV
  ln -s host-resolv-file "$T/host-resolv"
  grep -E '^(nameserver|search)' "$T/host-resolv-file" >"$T/expected"

  CASE="dns on the host"
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 F5_RESOLV_CONF="$T/host-resolv" \
    /bin/bash "$F5" dns >"$T/out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/expected" && ok "$CASE prints the resolver lines" || no "expected the resolver lines"

  CASE="bridged dns"
  container "$T/bridge" dns
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/expected" && ok "$CASE brings back the host's lines" || no "expected the host's lines"

  # A second bridge, on a host where `up` runs to the end against fakes: an `ip`
  # that shows tun0 with ten routes once the fake client has made $T/tun0, a
  # portal that answers every question, and a client that writes svpn's
  # resolv.conf a second later, unless $T/no-dns says not to.
  mkdir -p "$T/upbin" "$T/run" "$T/home/.local/state/f5-cli"
  printf 'fake-session-id\n' >"$T/home/.local/state/f5-cli/sid"
  cat >"$T/upbin/ip" <<IP
#!/bin/sh
case "\$*" in
  *tun0*) [ -f "$T/tun0" ] || exit 1 ;;
esac
case "\$*" in
  "-4 -o addr show tun0") echo "9: tun0    inet 10.9.9.9/32 scope global tun0" ;;
  "-4 -br addr show tun0") echo "tun0 UNKNOWN 10.9.9.9/32" ;;
  "route show") [ -f "$T/tun0" ] && for n in 1 2 3 4 5 6 7 8 9 10; do echo "10.\$n.0.0/16 dev tun0"; done ;;
esac
exit 0
IP
  cat >"$T/upbin/curl" <<'CURL'
#!/bin/sh
case "$*" in
  *http_code*) printf 200 ;;
  *" -D "*) printf 'x-access-session-token: fake-otc\r\n' ;;
esac
CURL
  cat >"$T/upbin/f5vpn-ng" <<CLIENT
#!/bin/sh
touch "$T/tun0"
[ -f "$T/no-dns" ] || { sleep 1; cp "$T/vpn-resolv" "$T/up-resolv"; } </dev/null >/dev/null 2>&1 &
CLIENT
  cat >"$T/upbin/pgrep" <<PGREP
#!/bin/sh
[ "\$*" = "-x svpn" ] && [ -f "$T/tun0" ]
PGREP
  chmod +x "$T/upbin/ip" "$T/upbin/curl" "$T/upbin/f5vpn-ng" "$T/upbin/pgrep"
  cat >"$T/vpn-resolv" <<'RESOLV'
#F5 Networks Inc. :File modified by VPN process
nameserver 10.11.75.4
search platform.hmcts.net
RESOLV
  grep -E '^(nameserver|search)' "$T/vpn-resolv" >"$T/vpn-expected"
  UPORT=$(free_port)
  printf 'PORT=%s\nTOKEN=%s\n' "$UPORT" right-token >"$T/bridge-up"
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 F5_BRIDGE_FILE="$T/bridge-up" \
    F5_RESOLV_CONF="$T/up-resolv" F5_CLIENT="$T/upbin/f5vpn-ng" F5_PORTAL=localhost F5_RESOURCE=/Common/fake F5_CLI_DNS_WAIT=3 \
    XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/home/.local/state" PATH="$T/upbin:$PATH" \
    /bin/bash "$F5" bridge serve 2>"$T/server-up.log" &
  SERVERS="$SERVERS $!"
  wait_for "$UPORT" || { echo "the second bridge never started:"; cat "$T/server-up.log"; exit 1; }
  # connected <yes|no>: tun0 there and svpn's DNS in place, or neither.
  connected() {
    rm -f "$T/tun0" "$T/no-dns"
    printf '%s\n' "$STUB" >"$T/up-resolv"
    [ "$1" = yes ] || return 0
    touch "$T/tun0"
    cp "$T/vpn-resolv" "$T/up-resolv"
  }

  CASE="up"
  connected no
  reset_target
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'DNS via 10.11.75.4' "$T/out" && cmp -s "$T/target-link" "$T/vpn-expected" \
    && ok "$CASE waits for svpn's resolv.conf, then copies it into the container" || no "expected the VPN's DNS"

  CASE="up, already connected"
  connected yes
  reset_target
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'already connected' "$T/out" && cmp -s "$T/target" "$T/vpn-expected" \
    && ok "$CASE still copies the host's DNS" || no "expected exit 0 and the target synced"

  CASE="up, svpn never sets DNS"
  connected no
  touch "$T/no-dns"
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'has not set the VPN' "$T/out" && ok "$CASE warns" || no "expected exit 0 and a warning"

  CASE="up that fails"
  connected no
  reset_target
  chmod -x "$T/upbin/f5vpn-ng"
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  chmod +x "$T/upbin/f5vpn-ng"
  [ "$rc" -eq 1 ] && [ "$(cat "$T/target")" = "$STUB" ] && ok "$CASE keeps its exit status and copies nothing" \
    || no "expected exit 1 and the target untouched"

  CASE="up, container can't write resolv.conf"
  connected yes
  : >"$T/notadir"
  F5_RESOLV_CONF="$T/notadir/resolv.conf" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'could not write' "$T/out" && ok "$CASE keeps up's exit status and warns" \
    || no "expected exit 0 and a warning"

  CASE="up, host DNS with no nameserver"
  connected yes
  printf 'search platform.hmcts.net\n' >"$T/up-resolv"
  reset_target
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/target")" = "$STUB" ] && ok "$CASE leaves the container's DNS alone" \
    || no "expected exit 0 and the target untouched"

  # A curl shim takes host.docker.internal to 127.0.0.1, where the bridge answers.
  mkdir -p "$T/hdibin"
  cat >"$T/hdibin/curl" <<SHIM
#!/bin/sh
for a in "\$@"; do
  shift
  set -- "\$@" "\$(printf '%s' "\$a" | sed 's/host\.docker\.internal/127.0.0.1/')"
done
exec "$(command -v curl)" "\$@"
SHIM
  chmod +x "$T/hdibin/curl"

  CASE="up over host.docker.internal"
  connected yes
  reset_target
  PATH="$T/hdibin:$PATH" TEST_BRIDGE_HOST=host.docker.internal F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/target")" = "$STUB" ] && ok "$CASE copies nothing: the container isn't on the host's network" \
    || no "expected exit 0 and the target untouched"
else
  echo "skip dns on the host (Linux only; macOS prints nothing)"
fi

# host.docker.internal "resolves" through a fake getent but nothing answers there.
CASE="host.docker.internal not answering"
if getent hosts host.docker.internal >/dev/null 2>&1; then
  echo "skip $CASE (it really resolves here)"
else
  mkdir -p "$T/getentbin"
  printf '#!/bin/sh\nexit 0\n' >"$T/getentbin/getent"
  chmod +x "$T/getentbin/getent"
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=1 F5_BRIDGE_FILE="$T/bridge" \
    PATH="$T/getentbin:$PATH" /bin/bash "$F5" bridge status >"$T/out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && grep -q "http://127.0.0.1:$PORT " "$T/out" && ok "$CASE falls back to 127.0.0.1" \
    || no "expected the bridge at 127.0.0.1"
fi

# ── the server's framing, with a stand-in for f5-cli ─────────────────────────────
# The embedded server, its read timeout cut to 1s, runs a script whose commands
# misbehave in the ways a real one can.

PORT2=$(free_port)
printf 'PORT=%s\nTOKEN=%s\n' "$PORT2" right-token >"$T/bridge2"
awk "/^BRIDGE_SERVER='/{f=1;next} f&&/^'\$/{exit} f" "$F5" | sed 's/^\( *timeout = \)30$/\11/' >"$T/server.py"
grep -q "^ *timeout = 1$" "$T/server.py" || { echo "could not cut the read timeout in the server"; exit 1; }
cat >"$T/fake-f5" <<'EOF'
#!/usr/bin/env bash
case $1 in
  status)  printf 'no newline'; exit 3 ;;
  session) kill -TERM $$ ;;
  up)      sleep 2; echo done ;;
  login)   echo "display=${DISPLAY:-none}" ;;
esac
EOF
mkdir -p "$T/envbin"
printf '#!/bin/sh\nprintf "DISPLAY=:42\\n"\n' >"$T/envbin/systemctl"
chmod +x "$T/fake-f5" "$T/envbin/systemctl"
PATH="$T/envbin:$PATH" python3 -I "$T/server.py" "$T/bridge2" "$T/fake-f5" "status up down login session version" \
  __f5_cli_bridge_exit__ 2>"$T/server2.log" &
SERVERS="$SERVERS $!"
wait_for "$PORT2" || { echo "the second bridge never started:"; cat "$T/server2.log"; exit 1; }

CASE="output without a final newline"
container "$T/bridge2" status
rc=$?
[ "$rc" -eq 3 ] && [ "$(cat "$T/out")" = "no newline" ] && ok "$CASE still brings back the exit status" \
  || no "expected 'no newline' and exit 3, got $rc"

CASE="command killed by a signal"
container "$T/bridge2" session
rc=$?
[ "$rc" -eq 143 ] && ok "$CASE exits 128+15" || no "expected exit 143, got $rc"

CASE="command quiet for longer than the read timeout"
container "$T/bridge2" up
rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "done" ] && ok "$CASE runs to the end" || no "expected 'done' and exit 0, got $rc"

CASE="idle connection"
python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.settimeout(5)
sys.exit(0 if s.recv(1) == b"" else 1)
' "$PORT2" >"$T/out" 2>&1 && ok "$CASE is closed by the server" || no "expected the server to close it"

CASE="display"
if [ "$(uname -s)" = Linux ]; then
  container "$T/bridge2" login
  [ "$(cat "$T/out")" = "display=:42" ] && ok "$CASE comes from the user manager" || no "expected DISPLAY=:42"
else
  echo "skip $CASE (Linux only)"
fi

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
  F5_IN_CONTAINER=0 F5_BRIDGE_FILE= "$T/prefix/bin/f5-cli" bridge serve >>"$T/installed.log" 2>&1 &
  echo \$! >"$T/installed.pid"
fi
exit 0
EOF
  chmod +x "$T/fakebin/systemctl"
  # The caller's own F5_BRIDGE_FILE mustn't mislead the check that the bridge answers.
  env HOME="$T/ihome" XDG_CONFIG_HOME="$T/ihome/.config" PATH="$T/fakebin:$PATH" F5_IN_CONTAINER=0 \
    F5_BRIDGE_FILE="$T/elsewhere" /bin/bash "$ROOT/install.sh" --prefix "$T/prefix" --bridge --bridge-port "$IPORT" >"$T/out" 2>&1
  rc=$?
  unit="$T/ihome/.config/systemd/user/f5-cli-bridge.service"
  file="$T/ihome/.config/f5-cli/bridge"
  if [ "$rc" -eq 0 ] && grep -qx "ExecStart=$T/prefix/bin/f5-cli bridge serve" "$unit" \
    && grep -qx KillMode=process "$unit" \
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
