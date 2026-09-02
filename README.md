# Ubuntu Server Bootstrap

Interactive bootstrap installer for a headless Ubuntu Server.

The installer asks separately about each feature. A feature that is answered
`no` is not installed or started. Required dependencies are surfaced as an
additional confirmation; they are never silently added.

## Included options

- Ubuntu version detection
- Choose one desktop: lightweight XFCE, standard Ubuntu GNOME, or no desktop
- GitHub CLI (`gh`) and Git
- XRDP remote desktop access
- Docker Engine and Docker Compose v2
- OpenSSH and UFW basics
- Rocket.Chat
- Nextcloud
- Frigate
- Shinobi
- Optional local graphical boot with the selected desktop
- Timestamped logging and safe re-runs

Logging and safe re-runs are always enabled. They are not a service selection.

## Run

Because this repository is private, clone it once with an authenticated GitHub
CLI session. On a completely new Ubuntu Server, install and authenticate the
CLI first:

```bash
sudo apt-get update && sudo apt-get install -y gh git
gh auth login
gh repo clone caloulou1948/ubuntu-server-bootstrap ~/ubuntu-server-bootstrap
cd ~/ubuntu-server-bootstrap
less install.sh
sudo ./install.sh
```

After that, the short repeat command is:

```bash
sudo ~/ubuntu-server-bootstrap/install.sh
```

The installer itself asks for a fixed Rocket.Chat release tag and preserves
that selection in its local service configuration.

The installer also offers GitHub CLI as a selectable component. It defaults to
yes because this private-repository workflow uses `gh`; answer `no` if that
server should not have GitHub CLI installed.

The script also supports a non-mutating plan mode:

```bash
bash install.sh --plan
```

`--dry-run` requires Ubuntu detection and prints commands instead of changing
the host. Run it with `sudo` when testing a real Ubuntu host so all detection
paths match the real run:

```bash
sudo bash install.sh --dry-run
```

## Design and safety

- The script detects `/etc/os-release`; it does not assume an Ubuntu release.
- Existing service `.env` files and camera configuration files are preserved.
- Existing service data is not deleted, pruned, or migrated.
- Container ports bind to `127.0.0.1` by default. This avoids exposing new
  services to the LAN or Internet before a reverse proxy, VPN, or scoped
  firewall rule is configured.
- The Docker group grants root-equivalent access. The script adds the selected
  login user to that group only when Docker is selected.
- UFW allows the detected SSH port(s). If XRDP and UFW are both selected, the
  installer asks for a trusted source CIDR; leaving it blank leaves port 3389
  closed.
- No service is removed when it is later answered `no` during a re-run.
- If local graphical boot is selected, the matching display manager is
  configured after the other selected components. XFCE uses LightDM; Ubuntu
  GNOME uses GDM3. The installer explicitly selects the desktop session,
  disables a conflicting display manager, starts and verifies the selected
  manager, verifies `graphical.target`, configures the GUI before optional
  services, automatically reboots after all selected components finish, and
  does not enable automatic user login. Only one desktop environment can be
  selected.
- The script never asks for camera passwords and does not configure a camera
  without an RTSP/ONVIF model and stream path.

## Service details

The applications are independent Docker Compose projects under:

```text
/opt/ubuntu-headless-bootstrap/services/
```

Default local endpoints are:

| Service | Local endpoint | Notes |
|---|---|---|
| Rocket.Chat | `http://127.0.0.1:3000` | Uses the official Rocket.Chat Compose repository; first-run setup is in the browser. |
| Nextcloud | `http://127.0.0.1:8081` | Community Docker image with MariaDB and Redis. |
| Shinobi | `http://127.0.0.1:8080` | Uses the official Shinobi container and persistent local data. |
| Frigate | `http://127.0.0.1:8971` | Starts without a camera; add RTSP inputs later. |

When local graphical boot is selected, the next reboot shows the selected
desktop's graphical login screen. XFCE uses LightDM and Ubuntu GNOME uses GDM3;
this is independent from XRDP remote login.

The endpoints are intentionally local-only. From another computer, use an SSH
tunnel, for example:

```bash
ssh -L 3000:127.0.0.1:3000 \
    -L 8080:127.0.0.1:8080 \
    -L 8081:127.0.0.1:8081 \
    -L 8971:127.0.0.1:8971 \
    USER@SERVER
```

For permanent remote access, use a VPN or a deliberately configured reverse
proxy with HTTPS and authentication. Do not publish camera RTSP ports directly
to the Internet.

## Camera compatibility

Frigate and Shinobi need a local camera stream, normally RTSP. ONVIF can help
discover cameras and provide controls, but wired IP does not automatically mean
RTSP or ONVIF is available. HonestView-associated hardware may still be tied to
its vendor cloud or NVR.

The Frigate starter configuration is intentionally empty. After the camera
model and NVR are known, add the correct RTSP URL to:

```text
/opt/ubuntu-headless-bootstrap/services/frigate/config/config.yml
```

## Rocket.Chat note

Rocket.Chat is installed from its official Compose repository so its current
dependency files are not re-created here. The script asks for a release tag and
preserves the resulting `.env`. Use a fixed release tag for a serious
deployment. The current Rocket.Chat documentation warns that its bundled
MongoDB 8.x may fail on Ubuntu 26.04; the installer stops for confirmation on
that host version instead of pretending the combination is safe.

## Verification

The installer validates generated Compose files before starting them and prints
the Compose status afterward. Logs are written to:

```text
/var/log/ubuntu-headless-bootstrap/install-*.log
```

The included static test checks Bash syntax and required menu/dependency markers
without installing anything:

```bash
bash tests/test-static.sh
```
