# f5-cli

Connect to the HMCTS F5 VPN from the terminal on Linux or macOS — no webtop
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

On **Linux**:

- bash 3.2+, `curl`, `python3`, `openssl` and `iproute2`
- the **f5vpn-ng** client — download the Linux package from the webtop at
  <https://portal.platform.hmcts.net/> and install it
  (`sudo apt install ./linux_f5vpn.x86_64.deb`)

On **macOS**:

- the stock `/bin/bash`, `curl` and `openssl` are enough; `python3` comes with
  the Command Line Tools (`xcode-select --install`)
- the **F5 VPN** and **F5 Endpoint Inspector** apps, in `/Applications` —
  the webtop at <https://portal.platform.hmcts.net/> offers the macOS package
  the first time you connect from it. Keep them up to date: when the portal
  has a newer client, F5 VPN asks before connecting, and `up` waits on that
  dialog

On both, a Chromium-family browser for the sign-in: Google Chrome, Chromium,
Microsoft Edge or Brave.

## Install

```sh
git clone https://github.com/hmcts/f5-cli.git
cd f5-cli
./install.sh               # installs ~/.local/bin/f5-cli
./install.sh --autostart   # ...and connects automatically when you log in
./install.sh --bridge      # ...and lets a container on this machine drive it
```

`--autostart` and `--bridge` are independent: use either, both or neither.
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

On Linux, `./install.sh --autostart` installs a systemd user unit, `f5-cli.service`,
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

On macOS it installs a LaunchAgent,
`~/Library/LaunchAgents/net.hmcts.f5-cli.plist`, which runs `f5-cli up` when
you log in, with the same three-minute network wait and three tries a minute
apart. Its output goes to `~/Library/Logs/f5-cli.log`.

```sh
launchctl kickstart -k gui/$(id -u)/net.hmcts.f5-cli   # reconnect
```

F5 VPN disconnects when the Mac sleeps, and the agent only runs at login, so
after a sleep run `f5-cli up` again.

### From a container

The F5 client runs on your machine, so a container — a devcontainer, say —
can't start it. With the bridge, f5-cli inside the container sends `status`,
`up`, `down`, `login`, `session` and `dns` to the host, which runs them and
streams the output and exit status back. Everything else about them is the
same: a sign-in window opens on the host's screen.

**On the host**, once:

```sh
./install.sh --bridge          # --bridge-port N if 47153 is taken
f5-cli bridge status           # bridge: http://127.0.0.1:47153 — host runs f5-cli …
```

That installs and starts a LaunchAgent (`net.hmcts.f5-cli.bridge`, log in
`~/Library/Logs/f5-cli-bridge.log`) or a systemd user unit
(`f5-cli-bridge.service`), and writes a fresh random token to
`~/.config/f5-cli/bridge` (mode 0600).

**In the container**, f5-cli needs `curl`, the f5-cli script itself (copy or
clone it; nothing else from the install is needed), and the host's
`~/.config/f5-cli` mounted at `~/.config/f5-cli` under the container's home.
For a devcontainer:

```jsonc
// devcontainer.json
"initializeCommand": "mkdir -p ~/.config/f5-cli",
"mounts": [
  "source=${localEnv:HOME}/.config/f5-cli,target=/home/<container-user>/.config/f5-cli,type=bind,readonly"
]
```

f5-cli knows it's in a container from `/.dockerenv`, `/run/.containerenv`,
`REMOTE_CONTAINERS` or `CODESPACES` (`F5_IN_CONTAINER=0|1` overrides that),
and `f5-cli bridge mode` prints `container` or `host` accordingly. Tools that
need to know whether f5-cli will forward should ask it with `f5-cli bridge
mode` rather than repeat the detection. It reaches the host at
`host.docker.internal` when that resolves and the bridge answers there, as on
Docker Desktop, and otherwise at `127.0.0.1`, which is the host's own loopback
for a container on the host's network (`--network=host`, as Linux
devcontainers often are). `F5_BRIDGE_HOST` overrides it.

```sh
f5-cli bridge status   # in the container: 0 answers, 1 set up but not answering, 2 not set up
```

**DNS.** On a Linux host, `svpn` points the host's `/etc/resolv.conf` at the
VPN's DNS servers, but a container on the host's network that resolves through
systemd-resolved's stub (`127.0.0.53`) never learns them, so internal names
fail there even with the tunnel up. `f5-cli dns` prints the host's
`nameserver`, `search`, `domain` and `options` lines, and in the container
`f5-cli dns --apply` writes them to its `/etc/resolv.conf` — in place, since
Docker bind-mounts that file — as root or with `sudo` that needs no password.
Set `F5_BRIDGE_SYNC_DNS=1` in the container's environment to do that after
every `up` and `down`; `up` exits 0 when already connected, so it also repairs
stale DNS. It is off by default because copying the host's DNS only makes
sense with `--network=host`, and f5-cli ignores it in the config file, which
every container with the mount shares. In a devcontainer:

```jsonc
"containerEnv": { "F5_BRIDGE_SYNC_DNS": "1" }
```

Even then, f5-cli copies only when it reached the bridge at `127.0.0.1`, which
means the container shares the host's network, or at an `F5_BRIDGE_HOST` you
set; over `host.docker.internal` it leaves DNS alone. It also skips the copy
after an `up` or `down` that failed, and the host passes on nothing while its
`/etc/resolv.conf` still names the VPN's servers after `svpn` has died.

A macOS host has nothing to copy — Docker Desktop resolves through the host
itself — so there `dns` prints nothing and `--apply` leaves the file alone.

The bridge listens on the host's `127.0.0.1` only, runs nothing but those
commands (and `version`), with no arguments, and only for a caller with the
token. Any process on the host — and, on Docker Desktop, any container — can
reach the port, which is what the token is for: treat the file like a
password. `./install.sh --uninstall` removes the bridge and the token, and
re-running `--bridge` replaces the token.

## Configuration

`~/.config/f5-cli/config` holds `KEY=value` lines; environment variables of the
same name override it. Everything is optional — see
[`config.example`](config.example).

| Setting | Default |
| --- | --- |
| `F5_PORTAL` | `portal.platform.hmcts.net` |
| `F5_RESOURCE` | the network-access resource the portal grants you |
| `F5_BROWSER` | first Chromium-family browser on `PATH` (macOS: in `/Applications`) |
| `F5_BROWSER_PROFILE` | `~/.local/share/f5-cli/browser` (`~/snap/<name>/common/f5-cli` for a snap browser) |
| `F5_CLIENT` | `f5vpn-ng` on `PATH` (macOS: `/Applications/F5 VPN.app`) |
| `F5_EPI` | macOS only: `/Applications/F5 Endpoint Inspector.app` |
| `F5_BRIDGE_HOST` | in a container: `host.docker.internal` if the bridge answers there, else `127.0.0.1` |
| `F5_BRIDGE_FILE` | `~/.config/f5-cli/bridge` — the bridge's port and token |
| `F5_BRIDGE_SYNC_DNS` | `0` — in a container, `1` copies the host's DNS after `up` and `down`; environment only |
| `F5_CLI_NETWORK_WAIT` | `0` — seconds `up` waits for the portal to resolve |

## How it works

1. **The sign-in.** The portal hands off to Entra ID over SAML, which can't be
   scripted. f5-cli keeps a browser profile of its own; after one interactive
   sign-in, the persistent Entra cookie in it lets a headless instance of the
   same browser complete the SAML round trip with no interaction. On Linux
   the profile uses a fixed cookie key (`--password-store=basic`), so f5-cli
   reads the portal session cookie back from the profile's cookie store. On
   macOS Chromium won't keep that session cookie on disk, so f5-cli runs the
   browser under a small helper that asks it for the cookie over the DevTools
   pipe instead; `--use-mock-keychain` keeps the Keychain out of it.
2. **The endpoint inspection.** After the SAML step the portal's access policy
   waits for the native client to inspect the machine, which the browser
   normally hands over as an `f5-epi://` link. Headless browsers won't open
   external protocols, so f5-cli runs that link through `f5vpn-ng` itself —
   or, on macOS, through the F5 Endpoint Inspector app — and the client's own
   inspectors do the checks, exactly as they would from the webtop.
3. **The launch.** With a live portal session, f5-cli asks the portal for a
   one-time code and builds the `f5-vpn://` launch link the way the webtop
   does, then starts `f5vpn-ng` with it. With no display available the client
   runs headless. On macOS the link goes to the F5 VPN app through `open`;
   that client has no headless mode, so its window opens in the background.
4. **Routes and DNS** are the client's own: `svpn` installs the split-tunnel
   routes and points `/etc/resolv.conf` at the VPN's DNS servers — on macOS,
   the system resolver configuration. On macOS the tunnel is whichever `utun`
   interface appears during `up`; f5-cli remembers which.

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

The Docker and `/etc/resolv.conf` problems above are specific to the Linux
client.

**`up` times out on macOS with no tunnel.** Look for a dialog from F5 VPN — an
offer to update the client is the usual one. Answer it and run `f5-cli up`
again.

**In a container: `no answer from the f5-cli bridge`.** The bridge isn't
running on the host, or something else holds its port. On the host, run
`f5-cli bridge status`, check its log (`~/Library/Logs/f5-cli-bridge.log`, or
`journalctl --user -u f5-cli-bridge`), and re-run `./install.sh --bridge`.

**In a container: `bad token`.** The container's token isn't the one the
bridge was started with. Check that the container mounts the host's
`~/.config/f5-cli` (and that `F5_BRIDGE_FILE` isn't set), then re-run
`./install.sh --bridge` on the host, which writes a new token and restarts the
bridge with it.

**Logs.** `$XDG_RUNTIME_DIR/f5-cli/` holds the client and browser output from
the last run; the client also logs to `~/.F5Networks/f5vpn.log`, and `svpn` to
`/var/log/svpn.log`. On macOS the run directory is `$TMPDIR/f5-cli/`, and the
F5 apps log to `~/Library/Logs/F5Networks/`.

