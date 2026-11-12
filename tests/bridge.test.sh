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
# TEST_CONFIG gives it a config file.
container() {
  local file=$1
  shift
  env HOME="$T/home" F5_CLI_CONFIG="${TEST_CONFIG:-/dev/null}" F5_IN_CONTAINER=1 F5_BRIDGE_FILE="$file" \
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
# F5_RESOLV_CONF stands in for /etc/resolv.conf: $T/host-resolv on the host,
# $T/target in the container. A hard link to the target shows it was written
# in place, as a bind-mounted /etc/resolv.conf has to be.

STUB='nameserver 127.0.0.53'
reset_target() { printf '%s\n' "$STUB" >"$T/target"; rm -f "$T/target-link"; ln "$T/target" "$T/target-link"; }

CASE="dns --apply on the host"
env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 /bin/bash "$F5" dns --apply >"$T/out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q 'into a container' "$T/out" && ok "$CASE is refused" || no "expected a refusal"

if [ "$(uname -s)" = Linux ]; then
  cat >"$T/host-resolv-file" <<'EOF'
# Generated by F5 Networks
nameserver 10.11.75.4
nameserver 168.63.129.16
search platform.hmcts.net
options timeout:2
sortlist 10.0.0.0
EOF
  ln -s host-resolv-file "$T/host-resolv"
  grep -E '^(nameserver|search|options)' "$T/host-resolv-file" >"$T/expected"

  CASE="dns on the host"
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 F5_RESOLV_CONF="$T/host-resolv" \
    /bin/bash "$F5" dns >"$T/out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/expected" && ok "$CASE prints the resolver lines, through the symlink" \
    || no "expected the nameserver, search and options lines"

  CASE="bridged dns"
  container "$T/bridge" dns
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$T/out" "$T/expected" && ok "$CASE brings back the host's lines" || no "expected the host's lines"

  CASE="dns --apply"
  reset_target
  F5_RESOLV_CONF="$T/target" container "$T/bridge" dns --apply
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$T/target-link" "$T/expected" && grep -q 'copied the host' "$T/out" \
    && ok "$CASE writes the host's lines in place" || no "expected the target rewritten in place"

  CASE="dns --apply again"
  F5_RESOLV_CONF="$T/target" container "$T/bridge" dns --apply
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'already has' "$T/out" && cmp -s "$T/target" "$T/expected" \
    && ok "$CASE changes nothing" || no "expected a no-op"

  CASE="dns --apply, unwritable"
  : >"$T/notadir"
  F5_RESOLV_CONF="$T/notadir/resolv.conf" container "$T/bridge" dns --apply
  rc=$?
  [ "$rc" -eq 1 ] && grep -q 'could not write' "$T/out" && ok "$CASE exits 1" || no "expected exit 1"

  CASE="dns with extra arguments"
  F5_RESOLV_CONF="$T/target" container "$T/bridge" dns --apply extra
  rc=$?
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 /bin/bash "$F5" dns --apply extra >/dev/null 2>&1
  rc2=$?
  [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ] && ok "$CASE shows usage on both sides" || no "expected exit 2 on both sides"

  # A second bridge, on a host where `up` runs to the end against fakes: an `ip`
  # that shows tun0 with ten routes once the fake client has made $T/tun0, a
  # portal that answers every question, and a client that writes svpn's
  # resolv.conf two seconds later, unless $T/no-dns says not to.
  mkdir -p "$T/upbin" "$T/run" "$T/home/.local/state/f5-cli"
  printf 'fake-session-id\n' >"$T/home/.local/state/f5-cli/sid"
  cat >"$T/upbin/ip" <<EOF
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
EOF
  cat >"$T/upbin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *http_code*) printf 200 ;;
  *" -D "*) printf 'x-access-session-token: fake-otc\r\n' ;;
esac
EOF
  cat >"$T/upbin/f5vpn-ng" <<EOF
#!/bin/sh
touch "$T/tun0"
[ -f "$T/no-dns" ] || { sleep 2; cp "$T/vpn-resolv" "$T/up-resolv"; } </dev/null >/dev/null 2>&1 &
EOF
  chmod +x "$T/upbin/ip" "$T/upbin/curl" "$T/upbin/f5vpn-ng"
  cat >"$T/vpn-resolv" <<'EOF'
#F5 Networks Inc. :File modified by VPN process
nameserver 10.11.75.4
nameserver 168.63.129.16
search platform.hmcts.net
EOF
  grep -E '^(nameserver|search)' "$T/vpn-resolv" >"$T/vpn-expected"
  UPORT=$(free_port)
  printf 'PORT=%s\nTOKEN=%s\n' "$UPORT" right-token >"$T/bridge-up"
  env HOME="$T/home" F5_CLI_CONFIG=/dev/null F5_IN_CONTAINER=0 F5_BRIDGE_FILE="$T/bridge-up" \
    F5_RESOLV_CONF="$T/up-resolv" F5_CLIENT="$T/upbin/f5vpn-ng" F5_PORTAL=localhost F5_RESOURCE=/Common/fake \
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
  F5_BRIDGE_SYNC_DNS=1 F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'connected: 10 routes, DNS via 10.11.75.4 168.63.129.16' "$T/out" \
    && cmp -s "$T/target-link" "$T/vpn-expected" \
    && ok "$CASE waits for svpn's resolv.conf, and the sync copies the VPN's DNS" || no "expected the VPN's DNS"

  CASE="up, svpn never sets DNS"
  connected no
  touch "$T/no-dns"
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'has not set the VPN' "$T/out" && ok "$CASE warns" || no "expected exit 0 and a warning"

  CASE="up with F5_BRIDGE_SYNC_DNS=1"
  connected yes
  reset_target
  F5_BRIDGE_SYNC_DNS=1 F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'already connected' "$T/out" && cmp -s "$T/target-link" "$T/vpn-expected" \
    && ok "$CASE, already connected, copies the host's DNS afterwards" || no "expected exit 0 and the target synced"

  CASE="up without F5_BRIDGE_SYNC_DNS"
  reset_target
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/target")" = "$STUB" ] && ok "$CASE leaves DNS alone" || no "expected the target untouched"

  CASE="F5_BRIDGE_SYNC_DNS in the config file"
  printf 'F5_BRIDGE_SYNC_DNS=1\n' >"$T/config"
  reset_target
  TEST_CONFIG="$T/config" F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/target")" = "$STUB" ] && ok "$CASE is ignored" || no "expected the target untouched"

  CASE="up with a failed sync"
  F5_BRIDGE_SYNC_DNS=1 F5_RESOLV_CONF="$T/notadir/resolv.conf" container "$T/bridge-up" up
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'could not write' "$T/out" && ok "$CASE keeps up's exit status and warns" \
    || no "expected exit 0 and a warning"

  CASE="up that fails, with F5_BRIDGE_SYNC_DNS=1"
  reset_target
  chmod -x "$T/upbin/f5vpn-ng"
  F5_BRIDGE_SYNC_DNS=1 F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  chmod +x "$T/upbin/f5vpn-ng"
  [ "$rc" -eq 1 ] && grep -q 'f5vpn-ng not found' "$T/out" && cmp -s "$T/target" "$T/vpn-expected" \
    && ok "$CASE keeps its exit status and still syncs" || no "expected exit 1 and the target synced"

  CASE="dns --apply with no nameserver from the host"
  printf 'search platform.hmcts.net\n' >"$T/up-resolv"
  reset_target
  F5_BRIDGE_SYNC_DNS=1 F5_RESOLV_CONF="$T/target" container "$T/bridge-up" up
  rc=$?
  F5_RESOLV_CONF="$T/target" container "$T/bridge-up" dns --apply
  rc2=$?
  [ "$rc" -eq 0 ] && [ "$rc2" -eq 1 ] && [ "$(cat "$T/target")" = "$STUB" ] && grep -q 'no nameserver' "$T/out" \
    && ok "$CASE is refused, and a sync only warns" || no "expected the target untouched"
else
  echo "skip dns on the host (Linux only; macOS prints nothing)"
fi

# Empty: what a macOS host returns.
CASE="dns --apply with nothing from the host"
rm -f "$T/host-resolv"
: >"$T/host-resolv"
reset_target
F5_RESOLV_CONF="$T/target" container "$T/bridge" dns --apply
rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$T/target")" = "$STUB" ] && grep -q 'left alone' "$T/out" \
  && ok "$CASE leaves the target untouched" || no "expected the target untouched"

# The server of a bridge from before dns, with its command list.
CASE="dns against an older bridge"
OPORT=$(free_port)
printf 'PORT=%s\nTOKEN=%s\n' "$OPORT" right-token >"$T/bridge-old"
python3 -I -c "$(sed -n "/^BRIDGE_SERVER='/,/^'$/p" "$F5" | sed '1d;$d')" \
  "$T/bridge-old" "$F5" "status up down login session version" __f5_cli_bridge_exit__ 2>"$T/server-old.log" &
SERVERS="$SERVERS $!"
wait_for "$OPORT" || { echo "the older bridge never started:"; cat "$T/server-old.log"; exit 1; }
F5_RESOLV_CONF="$T/target" container "$T/bridge-old" dns --apply
rc=$?
[ "$rc" -eq 1 ] && grep -q 'too old for dns' "$T/out" && ok "$CASE says the host needs updating" || no "expected 'too old'"

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
