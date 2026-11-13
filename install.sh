#!/usr/bin/env bash
# Install f5-cli for the current user, on Linux or macOS.
#
#   ./install.sh [--prefix DIR] [--autostart] [--bridge [--bridge-port N]]
#       install (default prefix ~/.local). --autostart connects when you log in;
#       --bridge lets a container (a devcontainer, say) drive f5-cli on this
#       host. Either, both or neither.
#   ./install.sh --uninstall [--purge]
#       remove; --purge also deletes the browser profile, session and config
#
# Or without a checkout:
#   curl -fsSL https://raw.githubusercontent.com/hmcts/f5-cli/master/install.sh | bash -s -- --bridge
set -euo pipefail

# Piped from curl, the script has no path of its own and no checkout beside it: fetch the repo
# (F5_CLI_REF picks a branch, tag or commit) and run that copy's install.sh.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  URL=https://github.com/hmcts/f5-cli/archive/${F5_CLI_REF:-master}.tar.gz
  curl -fsSL "$URL" | tar -xz -C "$TMP" --strip-components=1 \
    || { echo "install.sh: could not download f5-cli from $URL" >&2; exit 1; }
  bash "$TMP/install.sh" "$@" </dev/null
  exit
fi

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

OS=$(uname -s)
PREFIX=$HOME/.local
AUTOSTART=0
BRIDGE=0
BRIDGE_PORT=47153
UNINSTALL=0
PURGE=0
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/f5-cli
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
UNIT=f5-cli.service
AGENT_LABEL=net.hmcts.f5-cli
AGENT=$HOME/Library/LaunchAgents/$AGENT_LABEL.plist
AGENT_LOG=$HOME/Library/Logs/f5-cli.log
BRIDGE_FILE=$CONFIG_DIR/bridge
BRIDGE_UNIT=f5-cli-bridge.service
BRIDGE_LABEL=net.hmcts.f5-cli.bridge
BRIDGE_AGENT=$HOME/Library/LaunchAgents/$BRIDGE_LABEL.plist
BRIDGE_LOG=$HOME/Library/Logs/f5-cli-bridge.log

msg()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --prefix)    PREFIX=${2:?--prefix needs a directory}; shift ;;
    --prefix=*)  PREFIX=${1#--prefix=} ;;
    --autostart) AUTOSTART=1 ;;
    --bridge)    BRIDGE=1 ;;
    --bridge-port)   BRIDGE_PORT=${2:?--bridge-port needs a number}; shift ;;
    --bridge-port=*) BRIDGE_PORT=${1#--bridge-port=} ;;
    --uninstall) UNINSTALL=1 ;;
    --purge)     PURGE=1 ;;
    -h|--help)   sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
  shift
done
BIN=$PREFIX/bin/f5-cli
case $BRIDGE_PORT in
  '' | *[!0-9]*) die "--bridge-port needs a number" ;;
esac

case $OS in
  Linux|Darwin) ;;
  *) die "f5-cli supports Linux and macOS only" ;;
esac

uninstall() {
  if [ -f "$UNIT_DIR/$UNIT" ]; then
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    msg "removed $UNIT_DIR/$UNIT"
  fi
  if [ -f "$AGENT" ]; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    msg "removed $AGENT"
  fi
  if [ -f "$UNIT_DIR/$BRIDGE_UNIT" ]; then
    systemctl --user disable --now "$BRIDGE_UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$BRIDGE_UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    msg "removed $UNIT_DIR/$BRIDGE_UNIT"
  fi
  if [ -f "$BRIDGE_AGENT" ]; then
    launchctl bootout "gui/$(id -u)/$BRIDGE_LABEL" 2>/dev/null || true
    rm -f "$BRIDGE_AGENT"
    msg "removed $BRIDGE_AGENT"
  fi
  rm -f "$BRIDGE_FILE"
  rm -f "$BIN" && msg "removed $BIN"
  if [ "$PURGE" = 1 ]; then
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/f5-cli" \
           "${XDG_STATE_HOME:-$HOME/.local/state}/f5-cli" \
           "$CONFIG_DIR"
    msg "removed the browser profile, saved session and config"
  else
    msg "kept the browser profile, saved session and config — add --purge to remove them"
  fi
}

have_app() {
  local d
  for d in /Applications "$HOME/Applications"; do
    [ -d "$d/$1.app" ] && return 0
  done
  return 1
}

check_deps() {
  local missing=() cmd b
  if [ "$OS" = Darwin ]; then
    set -- curl python3 openssl ifconfig netstat scutil open pgrep pkill launchctl
  else
    set -- curl python3 openssl ip setsid timeout pgrep pkill
  fi
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing required commands: ${missing[*]}"
  # macOS's /usr/bin/python3 is a stub until the Command Line Tools are in.
  python3 -c 'import sqlite3' 2>/dev/null \
    || die "python3 does not run — on macOS, install the Command Line Tools with: xcode-select --install"

  if [ "$OS" = Darwin ]; then
    if ! have_app "F5 VPN" || ! have_app "F5 Endpoint Inspector"; then
      warn "F5 VPN and F5 Endpoint Inspector are not both installed — install the macOS client from your VPN portal's webtop"
    fi
    for b in "Google Chrome" Chromium "Microsoft Edge" "Brave Browser"; do
      have_app "$b" && return 0
    done
  else
    if ! command -v f5vpn-ng >/dev/null; then
      warn "f5vpn-ng is not installed — download the Linux client from your VPN portal's webtop and install it"
    fi
    for cmd in google-chrome google-chrome-stable chromium chromium-browser \
               microsoft-edge microsoft-edge-stable brave-browser; do
      command -v "$cmd" >/dev/null && return 0
    done
  fi
  warn "no Chromium-family browser found — install Google Chrome or Chromium, or set F5_BROWSER in the config"
}

install_unit() {
  command -v systemctl >/dev/null || die "--autostart needs systemd"
  mkdir -p "$UNIT_DIR"
  sed "s|@BIN@|$BIN|g" "$SRC/systemd/$UNIT" >"$UNIT_DIR/$UNIT"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT"
  msg "installed and enabled $UNIT_DIR/$UNIT"
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
    msg "lingering is on for $USER, so the VPN will connect at boot"
  else
    msg "the VPN will connect when you log in ('loginctl enable-linger' makes it connect at boot)"
  fi
}

# Like the systemd unit, the agent is enabled rather than started: it runs at
# the next login, or now with the launchctl bootstrap command printed below.
install_agent() {
  mkdir -p "$(dirname "$AGENT")" "$(dirname "$AGENT_LOG")"
  sed -e "s|@BIN@|$BIN|g" -e "s|@LOG@|$AGENT_LOG|g" -e "s|@LABEL@|$AGENT_LABEL|g" \
    "$SRC/launchd/f5-cli.plist" >"$AGENT"
  plutil -lint "$AGENT" >/dev/null || die "generated $AGENT does not parse"
  msg "installed $AGENT — the VPN will connect when you log in"
  msg "to connect now through it: launchctl bootstrap gui/$(id -u) $AGENT"
}

# The bridge's token: a container holding it can run status, up, down, login
# and session on this host, so it's private to you. A new one every install.
write_bridge_file() {
  local token
  token=$(openssl rand -hex 32)
  mkdir -p "$CONFIG_DIR"
  (umask 077 && printf 'PORT=%s\nTOKEN=%s\n' "$BRIDGE_PORT" "$token" >"$BRIDGE_FILE")
  chmod 600 "$BRIDGE_FILE"
}

# Unlike --autostart, the bridge starts now: it listens, but connects nothing
# until a container asks it to.
install_bridge_unit() {
  command -v systemctl >/dev/null || die "--bridge needs systemd"
  mkdir -p "$UNIT_DIR"
  sed "s|@BIN@|$BIN|g" "$SRC/systemd/$BRIDGE_UNIT" >"$UNIT_DIR/$BRIDGE_UNIT"
  systemctl --user daemon-reload
  systemctl --user enable "$BRIDGE_UNIT" >/dev/null 2>&1
  systemctl --user restart "$BRIDGE_UNIT" || die "the bridge did not start — see: journalctl --user -u $BRIDGE_UNIT"
  msg "installed and started $UNIT_DIR/$BRIDGE_UNIT"
}

install_bridge_agent() {
  mkdir -p "$(dirname "$BRIDGE_AGENT")" "$(dirname "$BRIDGE_LOG")"
  sed -e "s|@BIN@|$BIN|g" -e "s|@LOG@|$BRIDGE_LOG|g" -e "s|@LABEL@|$BRIDGE_LABEL|g" \
    "$SRC/launchd/f5-cli-bridge.plist" >"$BRIDGE_AGENT"
  plutil -lint "$BRIDGE_AGENT" >/dev/null || die "generated $BRIDGE_AGENT does not parse"
  local i
  launchctl bootout "gui/$(id -u)/$BRIDGE_LABEL" 2>/dev/null || true
  # bootout returns before the job is gone, and bootstrapping it again before
  # then fails with "Bootstrap failed: 5".
  for i in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$(id -u)/$BRIDGE_LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  launchctl bootstrap "gui/$(id -u)" "$BRIDGE_AGENT" || die "launchctl could not load $BRIDGE_AGENT"
  msg "installed and started $BRIDGE_AGENT (log: $BRIDGE_LOG)"
}

install_bridge() {
  local i
  write_bridge_file
  if [ "$OS" = Darwin ]; then install_bridge_agent; else install_bridge_unit; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    F5_BRIDGE_FILE=$BRIDGE_FILE "$BIN" bridge status >/dev/null 2>&1 && break
    [ "$i" = 10 ] && { warn "the bridge isn't answering yet — check it with: f5-cli bridge status"; return 0; }
    sleep 1
  done
  msg "bridge listening on 127.0.0.1:$BRIDGE_PORT; token in $BRIDGE_FILE"
  msg "in the container, mount $CONFIG_DIR at the same place under its home (read-only) — see the README"
}

if [ "$UNINSTALL" = 1 ]; then
  uninstall
  exit 0
fi

check_deps
mkdir -p "$(dirname "$BIN")"
install -m 755 "$SRC/bin/f5-cli" "$BIN"
msg "installed $BIN"

if [ ! -e "$CONFIG_DIR/config" ]; then
  mkdir -p "$CONFIG_DIR"
  install -m 600 "$SRC/config.example" "$CONFIG_DIR/config"
  msg "wrote $CONFIG_DIR/config"
fi

if [ "$AUTOSTART" = 1 ]; then
  if [ "$OS" = Darwin ]; then install_agent; else install_unit; fi
fi

if [ "$BRIDGE" = 1 ]; then
  install_bridge
fi

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) warn "$PREFIX/bin is not on your PATH — add it, or run $BIN directly" ;;
esac

echo
msg "next: run 'f5-cli login' once, then 'f5-cli up'"
