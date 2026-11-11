# f5-cli

Connect to the HMCTS F5 VPN from the terminal on Linux — no GUI, no webtop
clicking. Sign in once in a browser window; after that `f5-cli up` connects in
about ten seconds, re-authenticating headlessly when the portal session has
expired.

```console
$ f5-cli up
[+] portal session OK (…3fa1c2)
[+] starting f5vpn-ng (/Common/netacl_mojvpn)
[+] tun0 up: 10.99.3.34
[+] connected: 149 routes, DNS via 10.11.75.4 168.63.129.16
```

This is an unofficial tool. It drives the same portal endpoints the webtop's
own JavaScript uses, so a change to the portal's access policy can break it.

## Requirements

- Linux with bash 4+, `curl`, `python3`, `openssl` and `iproute2`
- the **f5vpn-ng** client — download the Linux package from the webtop at
  <https://portal.platform.hmcts.net/> and install it
  (`sudo apt install ./linux_f5vpn.x86_64.deb`)
- a Chromium-family browser for the sign-in: Google Chrome, Chromium,
  Microsoft Edge or Brave

## Install

```sh
git clone https://github.com/hmcts/f5-cli.git
cd f5-cli
./install.sh               # installs ~/.local/bin/f5-cli
./install.sh --autostart   # ...and connects automatically when you log in
```

`--prefix DIR` installs somewhere other than `~/.local`.
`./install.sh --uninstall` removes it; add `--purge` to also delete the browser
profile, saved session and config.

## Usage

```sh
f5-cli login    # once: sign in, and tick "Stay signed in"
f5-cli up       # connect
f5-cli status   # tunnel address, route count and DNS; non-zero when down
f5-cli down     # disconnect
f5-cli session  # check the portal session, refreshing it if needed
```

`login` opens a browser window on the portal. Sign in as usual, including MFA,
and tick **Stay signed in** — that leaves a persistent Entra cookie in
f5-cli's own browser profile, which is what lets later connects sign in without
a window. The window closes itself once the portal session is live. When the
Entra sign-in eventually lapses, `up` opens the window again if there's a
display, or tells you to run `login`.

### Connecting automatically

`./install.sh --autostart` installs a systemd user unit, `f5-cli.service`,
which runs `f5-cli up` when your user session starts and `f5-cli down` when it
stops. It waits up to three minutes for the network, and tries three times, a
minute apart, before giving up — if it does, the Entra sign-in has probably
lapsed and needs `f5-cli login`.

```sh
systemctl --user restart f5-cli   # reconnect
journalctl --user -u f5-cli       # what happened
```

With `loginctl enable-linger` the user session — and the VPN — starts at boot
instead of at login. If you disconnect with `f5-cli down` while the unit is
active, `systemctl --user restart f5-cli` puts the two back in step.

## Configuration

`~/.config/f5-cli/config` holds `KEY=value` lines; environment variables of the
same name override it. Everything is optional — see
[`config.example`](config.example).

| Setting | Default |
| --- | --- |
| `F5_PORTAL` | `portal.platform.hmcts.net` |
| `F5_RESOURCE` | the network-access resource the portal grants you |
| `F5_BROWSER` | first Chromium-family browser on `PATH` |
| `F5_BROWSER_PROFILE` | `~/.local/share/f5-cli/browser` (`~/snap/<name>/common/f5-cli` for a snap browser) |
| `F5_CLIENT` | `f5vpn-ng` on `PATH` |
| `F5_CLI_NETWORK_WAIT` | `0` — seconds `up` waits for the portal to resolve |

## How it works

1. **The sign-in.** The portal hands off to Entra ID over SAML, which can't be
   scripted. f5-cli keeps a browser profile of its own; after one interactive
   sign-in, the persistent Entra cookie in it lets a headless instance of the
   same browser complete the SAML round trip with no interaction.
2. **The endpoint inspection.** After the SAML step the portal's access policy
   waits for the native client to inspect the machine, which the browser
   normally hands over as an `f5-epi://` link. Headless browsers won't open
   external protocols, so f5-cli runs that link through `f5vpn-ng` itself —
   the client's own inspectors do the checks, exactly as they would from the
   webtop.
3. **The launch.** With a live portal session, f5-cli asks the portal for a
   one-time code and builds the `f5-vpn://` launch link the way the webtop
   does, then starts `f5vpn-ng` with it. With no display available the client
   runs headless.
4. **Routes and DNS** are the client's own: `svpn` installs the split-tunnel
   routes and points `/etc/resolv.conf` at the VPN's DNS servers.

The portal session is cached in `~/.local/state/f5-cli/sid` (mode 0600) and
re-checked on every `up`.

## Troubleshooting

**`tun0` comes up but there are no routes** (`f5-cli status` shows 1 route,
nothing internal is reachable). The client's `svpn` only looks at the first
ten network interfaces that have an IPv4 address, and `tun0` is always last —
so if nine or more others exist, it never sees the tunnel, and installs no
routes and no DNS. Docker is the usual cause: every compose project leaves a
bridge behind. Count them with `ip -4 -o addr show | wc -l` and clear the
unused ones with `docker network prune`. `f5-cli up` warns when you are close.

**Internal names don't resolve.** Check the route count first — DNS is only
configured after the routes. `resolvectl status tun0` showing
`Current Scopes: none` is normal: the client sets DNS globally through
`/etc/resolv.conf`, not on the interface.

**`/etc/resolv.conf` is a plain file after disconnecting.** `svpn` restores a
copy of systemd-resolved's stub instead of the symlink. `f5-cli down` relinks
it when it can run `sudo` without a password, and otherwise prints the command.

**Nothing resolves after a reboot or crash.** If `svpn` was killed rather
than disconnected — at shutdown, say — it never puts `/etc/resolv.conf` back,
and the VPN's nameservers are left in it with no tunnel to reach them.
`f5-cli up` and `f5-cli down` spot the `#F5 Networks` file with no `svpn`
running and relink resolved's stub; `f5-cli status` warns about it.

**Logs.** `$XDG_RUNTIME_DIR/f5-cli/` holds the client and browser output from
the last run; the client also logs to `~/.F5Networks/f5vpn.log`, and `svpn` to
`/var/log/svpn.log`.

