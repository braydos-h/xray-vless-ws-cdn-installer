# VLESS WebSocket + CDN Tunnel Setup

> [!WARNING]
> ## ⚠️ Project Status: Archived (Read-Only)
> This repository is now in **read-only archived mode** and is no longer actively maintained.
>
> For all new deployments, use the maintained replacement project:
>
> ## 👉 [vless-xtls-vision-installer](https://github.com/braydos-h/vless-xtls-vision-installer)
>
> The newer installer provides:
> - `VLESS + REALITY + XTLS Vision`
> - simpler deployment flow with fewer moving parts
> - no requirement to manage TLS certificates or reverse proxies
> - no requirement to own/configure a domain for standard setups
> - integrated diagnostics, repair, update, and status commands
> - built-in firewall and SSH hardening options
> - automatic client config + QR export generation
> - active maintenance and ongoing improvements
>
> Existing deployments from this repository may continue working, but all future development and support has moved to the new project.
>
> **Migration recommendation:** keep current nodes online until your new `vless-xtls-vision-installer` node is fully validated, then rotate clients in batches to minimize downtime.

Automated Bash installer that deploys an Xray VLESS-over-WebSocket endpoint behind Nginx plus a CDN-friendly cover site. It handles TLS certificates, writes an Xray config, and prints a ready-to-import VLESS URI so you can connect through a CDN-backed domain quickly.

---

## Table of Contents
- [At a Glance](#at-a-glance)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Installation Flow (What happens under the hood)](#installation-flow-what-happens-under-the-hood)
- [Output & Connection Details](#output--connection-details)
- [Client Setup](#client-setup)
- [Demo Videos](#demo-videos)
- [How It Slips Past Basic DPI](#how-it-slips-past-basic-dpi)
- [Troubleshooting](#troubleshooting)

---

## At a Glance

**What you get**
- Nginx TLS terminator with an optional generated cover website to blend with normal HTTPS traffic
- Xray VLESS inbound bound to `127.0.0.1` with a customizable WebSocket path
- Automatic certificate provisioning (prefers Certbot, falls back to acme.sh, then self-signed)
- Optional UFW rules that allow SSH, HTTP, and HTTPS
- Clear post-install summary with domain, path, UUID, and an import-ready VLESS link

**What to expect**
- Full run takes about **2 minutes 41 seconds** on a 1 vCPU / 1 GB RAM VPS
- Services (Nginx, Xray, and optionally UFW) are started automatically
- CDN fronting (e.g., Cloudflare) works immediately once DNS is pointed to the server

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Requirements
- **System:** Ubuntu 22.04+ (requires `apt` and `systemd`)
- **Access:** Root privileges (`sudo` or root shell)
- **Networking:** A domain pointing to the server's public IP (update DNS before running)

**Optional but recommended**
- CDN in front (Cloudflare or similar) after DNS is set
- Static IPv4 address on the VPS to avoid DNS churn

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Quick Start
1. Clone or download this repository on your VPS.
   ```bash
   git clone https://github.com/braydos-h/vless-ws-cdn-tunnel-setup
   cd vless-ws-cdn-tunnel-setup
   ```
2. Make the script executable and run it as root:
   ```bash
   chmod +x setup.sh
   sudo ./setup.sh
   ```
4. When prompted, provide:
   - **Domain name** (required, e.g., `example.com`)
   - **Fresh install?** (controls whether `apt-get upgrade` runs)
   - **Auto-generate cover site?** (`y` recommended)
   - **WebSocket path** (default `/ws`, leading slash enforced)
   - **UUID** (paste your own or let the script generate one)
   - **UFW rules** for ports 22/80/443

**Non-interactive example**

You can also pre-seed answers (for automation/CI) using flags and `--non-interactive`:

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

Environment variables with the same names (e.g., `DOMAIN`, `WS_PATH`, `UUID`, `COVER_SITE`, `FRESH_INSTALL`, `SETUP_UFW`) are also honored.

**Tip:** Ensure DNS is resolving to this server **before** running so certificate issuance succeeds on the first try.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Installation Flow (What happens under the hood)
1. Installs base packages (Nginx, Xray, Certbot/acme.sh, dependencies).
2. Requests TLS certificates (Certbot first, acme.sh second, self-signed as last resort).
3. Writes Xray config for VLESS-over-WS on `127.0.0.1`.
4. Configures Nginx as TLS terminator and reverse proxy to Xray.
5. (Optional) Generates a lightweight cover site to blend TLS handshakes.
6. Enables UFW rules if selected and starts services.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Output & Connection Details
At the end you'll see a summary similar to:
```
Domain       : your.domain
WebSocket WS : /ws
UUID         : <generated-or-custom-uuid>
VLESS URI    : vless://UUID@DOMAIN:443?encryption=none&security=tls&type=ws&host=DOMAIN&path=%2Fws
Key paths:
  Xray config : /usr/local/etc/xray/config.json (or /etc/xray/config.json fallback)
  Website root: /var/www/html/
  Nginx site  : /etc/nginx/sites-enabled/<domain>
  Cert dir    : /etc/ssl/<domain>/
```
Copy the VLESS URI into your client; the path is URL-encoded.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Client Setup
- Import the generated VLESS URI into the [InvisibleMan XRay client](https://github.com/InvisibleManVPN/InvisibleMan-XRayClient).
- Ensure **domain**, **UUID**, **WebSocket path**, and **TLS** match the summary above.
- CDN fronting with Cloudflare works out of the box as long as DNS points to your server.

[Back to top](#vless-websocket--cdn-tunnel-setup)

---

## Demo Videos
- **before.mp4**: Live run showing the full automated setup and timing (2m41s on 1vCPU/1GB RAM).  
  [https://github.com/user-attachments/assets/1fc29b93-b1f5-465b-b416-b6fe3db50c06](https://github.com/user-attachments/assets/1fc29b93-b1f5-465b-b416-b6fe3db50c06)

- **after.mp4**: Example of connecting and using the deployed endpoint.  
  [https://github.com/user-attachments/assets/f055a043-8f10-4b8f-bd05-72cfdd860af0](https://github.com/user-attachments/assets/f055a043-8f10-4b8f-bd05-72cfdd860af0)

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

**Log locations**
- Xray access: `/var/log/xray/access.log`
- Xray errors: `/var/log/xray/error.log`
- Nginx logs: `/var/log/nginx/`

**Common issues**
- Certificates fail: confirm DNS points to the server and rerun once DNS has propagated.
- Nginx fails to install: the script continues without it, but TLS termination and the cover site will be unavailable.
- WebSocket 403/404: verify the WebSocket path matches the one you set during installation.

[Back to top](#vless-websocket--cdn-tunnel-setup)
