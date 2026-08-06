# VLESS WebSocket + CDN Tunnel Setup

Automated Bash installer that deploys an **Xray VLESS-over-WebSocket** endpoint behind **Nginx** plus a CDN-friendly cover site. It provisions TLS certificates, writes the Xray config, registers systemd services, and prints a ready-to-import VLESS URI so you can connect through a CDN-backed domain in under three minutes.

## Quick Install

```bash
git clone https://github.com/braydos-h/xray-vless-ws-cdn-installer
cd xray-vless-ws-cdn-installer
chmod +x setup.sh
sudo ./setup.sh
```

> Ensure DNS for your domain already points at the server before running, so certificate issuance succeeds on the first try. See [Quick Start](#quick-start) for the interactive prompts and [CLI Reference](#cli-reference) for non-interactive flags.

---

## Table of Contents
- [At a Glance](#at-a-glance)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Installation Flow (What happens under the hood)](#installation-flow-what-happens-under-the-hood)
- [Output & Connection Details](#output--connection-details)
- [Client Setup](#client-setup)
- [CDN Fronting (Cloudflare)](#cdn-fronting-cloudflare)
- [Demo Videos](#demo-videos)
- [How It Slips Past Basic DPI](#how-it-slips-past-basic-dpi)
- [Troubleshooting](#troubleshooting)

---

## At a Glance

**What you get**
- Nginx TLS terminator with an optional generated cover website to blend with normal HTTPS traffic
- Xray VLESS inbound bound to `127.0.0.1:10000` with a customizable WebSocket path
- Automatic certificate provisioning (prefers Certbot, falls back to acme.sh, then self-signed)
- Optional UFW rules that allow SSH (22), HTTP (80), and HTTPS (443)
- Clear post-install summary with domain, path, UUID, and an import-ready VLESS link

**What to expect**
- Full run takes about **2 minutes 41 seconds** on a 1 vCPU / 1 GB RAM VPS
- Services (Nginx, Xray, and optionally UFW) are started automatically
- CDN fronting (e.g., Cloudflare) works immediately once DNS is pointed at the server
- A 12-step progress bar with elapsed time and ETA is shown during installation

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Architecture

```
                    +-------------------+         +-----------------------+
  Client (VLESS) -->|  CDN (Cloudflare) |  HTTPS  |   Your VPS (Nginx)    |
                    |   terminates TLS   |-------->|   :443  TLS terminate |
                    +-------------------+         |          |            |
                                                  |   cover site (HTML)  |
                                                  |   /ws  -> 127.0.0.1:10000
                                                  +----------|------------+
                                                             v
                                                  +-----------------------+
                                                  |  Xray (127.0.0.1:10000)|
                                                  |  VLESS + WS, no TLS    |
                                                  +-----------------------+
```

- **Nginx** listens on `:443`, terminates TLS, serves the cover site, and reverse-proxies the WebSocket path to Xray.
- **Xray** listens only on `127.0.0.1:10000` (loopback) so it is never exposed directly to the internet.
- **CDN** (optional) sits in front of Nginx, terminates public TLS, and forwards WebSocket frames to the origin.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Requirements
- **System:** Ubuntu 22.04+ (requires `apt` and `systemd`); other apt-based distros may work but are untested
- **Access:** Root privileges (`sudo` or root shell; the script re-execs itself with sudo if needed)
- **Networking:** A domain pointing to the server's public IP (update DNS before running)

**Optional but recommended**
- CDN in front (Cloudflare or similar) after DNS is set
- Static IPv4 address on the VPS to avoid DNS churn

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Quick Start

1. Clone or download this repository on your VPS.
   ```bash
   git clone https://github.com/braydos-h/xray-vless-ws-cdn-installer
   cd xray-vless-ws-cdn-installer
   ```
2. Make the script executable and run it as root:
   ```bash
   chmod +x setup.sh
   sudo ./setup.sh
   ```
3. When prompted, provide:
   - **Domain name** (required, e.g., `example.com`)
   - **Fresh install?** (controls whether `apt-get update`/`upgrade` runs)
   - **Auto-generate cover site?** (`y` recommended)
   - **WebSocket path** (default `/ws`, leading slash enforced)
   - **UUID** (paste your own or let the script generate one)
   - **UFW rules** for ports 22/80/443

**Tip:** Ensure DNS is resolving to this server **before** running so certificate issuance succeeds on the first try. The script checks DNS health and compares the resolved IP against the server's public IPv4, warning you if they don't match.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## CLI Reference

Run `sudo ./setup.sh --help` to see this in the shell:

```
Usage: setup.sh [options]
  --domain <domain>         Domain name for the deployment (required in non-interactive mode)
  --ws-path <path>          WebSocket path (e.g., /ws)
  --uuid <uuid>             UUID to use; auto-generated if omitted
  --cover-site <y|n>        Whether to generate the fake cover website
  --fresh-install <y|n>     Whether to run apt-get update/upgrade as a fresh install
  --setup-ufw <y|n>         Configure and enable UFW with 22/80/443 allowed
  --non-interactive|--yes   Accept defaults without prompts (domain is still required)
  --help                    Show this message
```

Options accept either `--flag value` or `--flag=value` form.

**Non-interactive example** (for automation/CI):

```bash
sudo ./setup.sh \
  --domain example.com \
  --ws-path /edge \
  --uuid 550e8400-e29b-41d4-a716-446655440000 \
  --cover-site y \
  --fresh-install n \
  --setup-ufw y \
  --non-interactive
```

**Environment variables** with the same names are also honored (useful for CI secrets):
`DOMAIN`, `WS_PATH`, `UUID`, `COVER_SITE`, `FRESH_INSTALL`, `SETUP_UFW`, `NON_INTERACTIVE`.

| Variable         | Default | Notes                                                  |
|------------------|---------|-------------------------------------------------------|
| `DOMAIN`         | (none)  | Required in non-interactive mode                       |
| `WS_PATH`        | `/ws`   | Leading slash auto-added; `/` alone is rejected        |
| `UUID`           | auto    | Validated against RFC 4122 format; lowercased          |
| `COVER_SITE`     | `y`     | Generates a business-style HTML cover page             |
| `FRESH_INSTALL`  | `y`     | Runs `apt-get update` + `upgrade`                      |
| `SETUP_UFW`      | `y`     | Opens 22/80/443 and enables UFW                        |
| `NON_INTERACTIVE`| `0`     | Accepts `0/1`, `true/false`, `y/n`                     |

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Installation Flow (What happens under the hood)

The script runs 12 steps with a live progress bar:

1. **Collecting user inputs** - validates domain, UUID, WS path, and y/n answers
2. **Preparing system packages** - installs `curl wget unzip jq socat openssl cron` and Nginx
3. **Checking DNS and fallbacks** - resolves the domain via system resolver, then `1.1.1.1`/`8.8.8.8`/`9.9.9.9` as fallback; warns on DNS/IP mismatch
4. **Selecting certificate client** - tries certbot, then acme.sh, then self-signed
5. **Obtaining certificates** - standalone HTTP challenge (Nginx is stopped briefly); cert files land in `/etc/ssl/<domain>/`
6. **Building fake cover website** - writes a minimal HTML page to `/var/www/html/index.html`
7. **Installing Xray core** - downloads the latest release from `XTLS/Xray-core` for the detected arch (`64`, `arm64-v8a`, `arm32-v7a`)
8. **Writing Xray configuration** - generates `config.json` and validates it with `jq` before installing
9. **Registering Xray systemd service** - creates `/etc/systemd/system/xray.service` and enables it
10. **Configuring Nginx reverse proxy** - writes the site file, tests with `nginx -t`, and rolls back on failure
11. **Configuring UFW firewall** - opens 22/80/443 and enables UFW
12. **Starting services** - restarts Nginx and Xray (retries once with `daemon-reload` on failure)

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Output & Connection Details

At the end you'll see a summary similar to:

```
-------------------- SETUP SUMMARY --------------------
Domain       : your.domain
WebSocket WS : /ws
Encoded path : %2Fws
UUID         : <generated-or-custom-uuid>

VLESS URI (URL-encoded path):
  vless://UUID@DOMAIN:443?encryption=none&security=tls&type=ws&host=DOMAIN&path=%2Fws

Key paths:
  Xray config : /usr/local/etc/xray/config.json (or /etc/xray/config.json fallback)
  Website root: /var/www/html/
  Nginx site  : /etc/nginx/sites-enabled/<domain>
  Cert dir    : /etc/ssl/<domain>/
  Firewall    : UFW enabled for ports 22, 80, 443 (if install succeeded)
Elapsed time : 00h 02m 41s
-------------------------------------------------------
```

Copy the VLESS URI into your client; the path is URL-encoded (`/` -> `%2F`).

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Client Setup
- Import the generated VLESS URI into the [InvisibleMan XRay client](https://github.com/InvisibleManVPN/InvisibleMan-XRayClient) (or any VLESS-aware client such as v2rayN, Nekoray, or V2RayXS).
- Ensure **domain**, **UUID**, **WebSocket path**, and **TLS** match the summary above.
- The WebSocket **Host** header must equal your domain (the installer bakes this into both the Xray and Nginx configs).

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## CDN Fronting (Cloudflare)

This setup is designed to sit behind a CDN. With Cloudflare:

1. Point your domain's DNS A/AAAA record at the VPS IP (the installer checks this).
2. Enable Cloudflare proxying (orange cloud) on that record.
3. Set SSL/TLS mode to **Full** (or **Full (strict)** if using a CA-issued cert via certbot/acme.sh).
4. Make sure **WebSocket** is enabled under Network settings (it's on by default).

The CDN terminates public TLS and forwards WebSocket frames to Nginx on your origin. Because the cover site serves normal HTML on `/`, shallow inspection sees only a typical CDN-fronted website.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Demo Videos

**before.mp4** - Live run showing the full automated setup and timing (2m41s on 1vCPU/1GB RAM).

https://github.com/user-attachments/assets/1fc29b93-b1f5-465b-b416-b6fe3db50c06

<video src="https://github.com/braydos-h/xray-vless-ws-cdn-installer/raw/main/before.mp4" controls muted width="100%"></video>

**after.mp4** - Example of connecting and using the deployed endpoint.

https://github.com/user-attachments/assets/f055a043-8f10-4b8f-bd05-72cfdd860af0

<video src="https://github.com/braydos-h/xray-vless-ws-cdn-installer/raw/main/after.mp4" controls muted width="100%"></video>

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## How It Slips Past Basic DPI
- Traffic rides over HTTPS (TLS) with a normal-looking host and WebSocket path, so shallow packet inspection only sees standard web traffic.
- Optional cover site content on port 443 keeps the TLS SNI/ALPN negotiation indistinguishable from typical CDN-fronted sites.
- CDN fronting (e.g., Cloudflare) terminates TLS and forwards WebSocket frames, hiding the origin and making the flow look like regular proxied HTTPS.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Troubleshooting

**Fast checks**
- `systemctl status xray`
- `systemctl status nginx`
- `nginx -t` (validates the site config)

**Log locations**
- Xray access: `/var/log/xray/access.log`
- Xray errors: `/var/log/xray/error.log`
- Nginx logs: `/var/log/nginx/`
- acme.sh issue log: `/tmp/acme_issue.log` (only if certbot failed and acme.sh was tried)

**Common issues**
- **Certificates fail**: confirm DNS points at the server and rerun once DNS has propagated. The installer warns if the resolved IP doesn't match the server's public IPv4.
- **Port 80/443 already in use**: the installer warns about existing listeners that may block the standalone HTTP challenge. Stop the conflicting service (e.g., an old Nginx) before rerunning.
- **Nginx fails to install**: the script continues without it, but TLS termination and the cover site will be unavailable. In interactive mode it offers a retry prompt.
- **Nginx config test fails**: the installer rolls back to the previous config automatically; inspect `/etc/nginx/sites-available/<domain>` if it persists.
- **WebSocket 403/404**: verify the WebSocket path in your client matches the one set during installation (and the `Host` header equals your domain).
- **Xray service won't start**: run `journalctl -u xray --no-pager | tail -n 50`; the installer validates the JSON config with `jq` before enabling the service, so a syntax error is rare.
- **DNS won't resolve**: the installer can write fallback resolvers (`1.1.1.1`, `8.8.8.8`) into `/etc/resolv.conf`; a backup is saved as `/etc/resolv.conf.bak.<timestamp>`.

[Back to top](#vless-websocket--cdn-tunnel-setup)