# xclient

Turn a proxy share link into a local SOCKS5 and HTTP proxy on your Linux server, run it as a systemd service, and point `apt`, `git`, `curl`, `wget` and Docker at it with one command.

xclient bundles [Xray-core](https://github.com/XTLS/Xray-core) with a small converter and an interactive menu.

- Paste a `vless://`, `vmess://`, `ss://` or `trojan://` link and it is ready to use
- Save several configs, check their latency, switch to the fastest
- Runs as a systemd service that starts on boot
- Toggle system proxy for apt, shell environment, curl, wget, Docker and Git

Local proxy ports (changeable):

| Protocol | Address |
| --- | --- |
| SOCKS5 | `127.0.0.1:10808` |
| HTTP | `127.0.0.1:10809` |

## Requirements

- Linux `amd64` or `arm64` with systemd
- Root access
- `curl`
- Debian or Ubuntu for the apt proxy option (everything else works on any distro)

## Download

Pick the latest version from the [releases page](https://github.com/ReturnFI/xclient/releases).

```
VERSION=0.0.3
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -fLO https://github.com/ReturnFI/xclient/releases/download/v$VERSION/xclient-$VERSION-linux-$ARCH.tar.gz
```

Release files:

- `xclient-0.0.3-linux-amd64.tar.gz`
- `xclient-0.0.3-linux-arm64.tar.gz`
- `SHA256SUMS`

Optional checksum check:

```
curl -fLO https://github.com/ReturnFI/xclient/releases/download/v$VERSION/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
```

### If the server cannot reach GitHub

Download the archive on another machine and copy it over:

```
scp xclient-0.0.3-linux-amd64.tar.gz root@your-server:/root/
```

## Install

```
sudo mkdir -p /opt/xclient
sudo tar xzf xclient-$VERSION-linux-$ARCH.tar.gz --strip-components=1 -C /opt/xclient
sudo /opt/xclient/menu.sh
```

In the menu choose **Install service** (option 11). This creates the systemd service, enables it at boot and adds the `xclient` command, so from now on you can run `xclient` from anywhere.

## Quick start

1. Run `xclient`
2. Choose **Add config** and paste your link
3. Answer `Y` to use it now
4. Choose **Test connection** to confirm the proxy works
5. Choose **System proxy** and enable what you need

The same from the command line:

```
sudo xclient add "vless://..."
sudo xclient start
sudo xclient test
sudo xclient proxy on
```

## Using the proxy

```
curl -x socks5h://127.0.0.1:10808 https://ifconfig.me
curl -x http://127.0.0.1:10809 https://ifconfig.me
```

Use `socks5h://` with the `h` so DNS is resolved through the proxy.

## Commands

| Command | Description |
| --- | --- |
| `xclient` | Interactive menu |
| `xclient add [URI...]` | Save links as configs |
| `xclient import [FILE]` | Save every link found in a file |
| `xclient list` | List saved configs |
| `xclient use [N\|NAME]` | Activate a config |
| `xclient remove [N\|NAME]` | Delete a config |
| `xclient check` | Measure latency of every config |
| `xclient best` | Activate the fastest working config |
| `xclient test` | Show your IP and timing through the proxy |
| `xclient doctor` | Full health report |
| `xclient status` | Short status |
| `xclient start` `stop` `restart` | Control the service |
| `xclient enable` `disable` | Start at boot or not |
| `xclient logs [-f]` | Service logs |
| `xclient proxy on\|off [PART...]` | System proxy |
| `xclient proxy status` | Show system proxy state |
| `xclient ports [SOCKS HTTP]` | Change local ports |
| `xclient install` | Install service and command |
| `xclient uninstall` | Remove service and command |

Add `-y` before a command to answer yes to every question.

## System proxy

`xclient proxy on` configures all of these. Name one or more to change only those:

```
sudo xclient proxy on apt git
sudo xclient proxy off docker
```

| Part | What it changes |
| --- | --- |
| `apt` | `/etc/apt/apt.conf.d/80proxy` |
| `env` | `/etc/profile.d/proxy.sh` for new login shells |
| `curl` | `~/.curlrc` |
| `wget` | `~/.wgetrc` |
| `docker` | Docker daemon drop-in, restarts Docker |
| `git` | `git config --global http.proxy` |

Notes:

- If the proxy is stopped, tools configured to use it will fail. Run `sudo xclient proxy off` to restore them.
- Docker only covers the daemon, such as image pulls. Running containers do not use it.
- `env` applies to new login shells. For the current shell run `source /etc/profile.d/proxy.sh`.

## Changing ports

```
sudo xclient ports 10808 57167
```

This rewrites the active config, restarts the service and saves the ports. Run `sudo xclient proxy on` afterwards so system tools use the new HTTP port.

## Upgrade

Extract the new archive over the same folder. Your configs are kept.

```
sudo tar xzf xclient-$VERSION-linux-$ARCH.tar.gz --strip-components=1 -C /opt/xclient
sudo xclient restart
```

## Uninstall

```
sudo xclient uninstall
sudo rm -rf /opt/xclient
```

Uninstall asks whether to remove the system proxy settings too. Answer yes unless you want them to stay.

## Files

Everything lives in the install folder, `/opt/xclient` in the steps above.

| Path | Purpose |
| --- | --- |
| `configs/` | Saved configs, one JSON file per link |
| `current.json` | Config used by the service |
| `xclient.conf` | Saved ports |
| `xray` | Xray-core binary |
| `uri2xray` | Link to Xray JSON converter |

Saved configs contain your server credentials. They are stored with `0600` permissions inside a `0700` folder. Do not share or commit them.

## Troubleshooting

Run `sudo xclient doctor` first. It checks the config, the service, the ports, the system clock and the connection.

- **Service does not start:** `sudo xclient logs`
- **Connection works for some links but not others:** `sudo xclient check`
- **VMess or REALITY fails randomly:** check that the server clock is synchronized, since these protocols break on time skew
- **Port already in use:** `sudo xclient ports 20808 20809`

## Build from source

Requires Go 1.22 or newer.

```
git clone https://github.com/ReturnFI/xclient.git
cd xclient
go build -trimpath -ldflags "-s -w" -o uri2xray .
```

Releases are built by GitHub Actions. Changing the `VERSION` file on `main` publishes a new release for `amd64` and `arm64`, bundled with Xray-core.

`uri2xray` can also be used on its own:

```
./uri2xray "vless://..."
./uri2xray -o out/ -i links.txt
./uri2xray --outbound-only "vmess://..."
```

Put flags before the links.
