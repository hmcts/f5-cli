#!/usr/bin/env bash
# Install f5-cli for the current user.
#
#   ./install.sh [--prefix DIR] [--autostart]   install (default prefix ~/.local)
#   ./install.sh --uninstall [--purge]          remove; --purge also deletes the
#                                               browser profile, session and config
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=$HOME/.local
AUTOSTART=0
UNINSTALL=0
PURGE=0
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/f5-cli
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
UNIT=f5-cli.service

msg()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --prefix)    PREFIX=${2:?--prefix needs a directory}; shift ;;
    --prefix=*)  PREFIX=${1#--prefix=} ;;
    --autostart) AUTOSTART=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge)     PURGE=1 ;;
    -h|--help)   sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
  shift
done
BIN=$PREFIX/bin/f5-cli

[ "$(uname -s)" = Linux ] || die "f5-cli supports Linux only"

uninstall() {
  if [ -f "$UNIT_DIR/$UNIT" ]; then
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    msg "removed $UNIT_DIR/$UNIT"
  fi
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

check_deps() {
  local missing=() cmd
  for cmd in curl python3 openssl ip getent setsid timeout md5sum pkill flock; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing required commands: ${missing[*]}"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 or newer is required"

  if ! command -v f5vpn-ng >/dev/null; then
    warn "f5vpn-ng is not installed — download the Linux client from your VPN portal's webtop and install it"
  fi
  for cmd in google-chrome google-chrome-stable chromium chromium-browser \
             microsoft-edge microsoft-edge-stable brave-browser; do
    command -v "$cmd" >/dev/null && return 0
  done
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

if [ "$UNINSTALL" = 1 ]; then
  uninstall
  exit 0
fi

check_deps
install -D -m 755 "$SRC/bin/f5-cli" "$BIN"
msg "installed $BIN"

if [ ! -e "$CONFIG_DIR/config" ]; then
  install -D -m 600 "$SRC/config.example" "$CONFIG_DIR/config"
  msg "wrote $CONFIG_DIR/config"
fi

[ "$AUTOSTART" = 1 ] && install_unit

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) warn "$PREFIX/bin is not on your PATH — add it, or run $BIN directly" ;;
esac

echo
msg "next: run 'f5-cli login' once, then 'f5-cli up'"
