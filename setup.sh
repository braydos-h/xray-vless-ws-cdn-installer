#!/usr/bin/env bash

###############################################################################
# Automated VLESS over WebSocket + CDN-friendly setup for Ubuntu 22.04+
# - Installs Xray-core
# - Sets up Nginx as TLS terminator + fake cover website
# - Obtains certificates via certbot/acme.sh, or self-signed fallback
# - Configures VLESS+WS inbound and Nginx reverse proxy
###############################################################################

#--------------------------- Utility Functions -------------------------------#

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; } 1>&2
error(){ printf '[X] %s\n' "$*"; } 1>&2

usage() {
    cat <<'EOF'
Usage: setup.sh [options]
  --domain <domain>         Domain name for the deployment (required in non-interactive mode)
  --ws-path <path>          WebSocket path (e.g., /ws)
  --uuid <uuid>             UUID to use; auto-generated if omitted
  --cover-site <y|n>        Whether to generate the fake cover website
  --fresh-install <y|n>     Whether to run apt-get update/upgrade as a fresh install
  --setup-ufw <y|n>         Configure and enable UFW with 22/80/443 allowed
  --non-interactive|--yes   Accept defaults without prompts (domain is still required)
  --help                    Show this message
EOF
}

normalize_yn() {
    # Normalize y/n style inputs; returns empty string if invalid
    case "$(trim "$1" | tr 'A-Z' 'a-z')" in
        y|yes) echo "y" ;;
        n|no) echo "n" ;;
        *) echo "" ;;
    esac
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

format_duration() {
    # Format seconds into Hh Mm Ss
    local secs=$1
    local h=$((secs / 3600))
    local m=$(((secs % 3600) / 60))
    local s=$((secs % 60))
    if [ "$h" -gt 0 ]; then
        printf '%02dh %02dm %02ds' "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then
        printf '%02dm %02ds' "$m" "$s"
    else
        printf '00m %02ds' "$s"
    fi
}

progress_init() {
    TOTAL_STEPS=$1
    CURRENT_STEP=0
    START_TS=$(date +%s)
}

progress_step() {
    # Increment progress and print a simple bar with ETA
    local desc="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local elapsed=$(( $(date +%s) - START_TS ))
    local avg_per_step=0
    if [ "$CURRENT_STEP" -gt 0 ]; then
        avg_per_step=$(( elapsed / CURRENT_STEP ))
    fi
    local remaining=$(( TOTAL_STEPS - CURRENT_STEP ))
    if [ "$remaining" -lt 0 ]; then
        remaining=0
    fi
    local eta=$(( remaining * avg_per_step ))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar_len=26
    local filled=$(( percent * bar_len / 100 ))
    local bar=""
    local i=1
    while [ "$i" -le "$bar_len" ]; do
        if [ "$i" -le "$filled" ]; then
            bar="${bar}#"
        else
            bar="${bar}."
        fi
        i=$((i + 1))
    done
    printf '\n[%d/%d] %s\n[%s] %3d%% | elapsed %s | ETA %s\n' \
        "$CURRENT_STEP" "$TOTAL_STEPS" "$desc" \
        "$bar" "$percent" "$(format_duration "$elapsed")" "$(format_duration "$eta")"
}

prompt_yes_no() {
    # $1 = prompt, $2 = default (y/n or empty)
    local prompt default reply
    prompt=$1
    default=$2
    local input_tty="/dev/tty"
    while :; do
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$prompt" "$default" >&2
        else
            printf '%s ' "$prompt" >&2
        fi
        if [ -r "$input_tty" ]; then
            read -r reply <"$input_tty"
        else
            read -r reply
        fi
        reply=$(printf '%s' "$reply" | tr 'A-Z' 'a-z')
        if [ -z "$reply" ] && [ -n "$default" ]; then
            reply=$default
        fi
        case "$reply" in
            y|yes) printf 'y\n'; return 0 ;;
            n|no)  printf 'n\n'; return 0 ;;
            *)     echo "Please answer y or n." ;;
        esac
    done
}

validate_domain() {
    local d="$1"
    local old_ifs label tld

    [ -n "$d" ] || return 1
    [ "${#d}" -le 253 ] || return 1
    case "$d" in
        *[!A-Za-z0-9.-]*|.*|*.|*..*|*.-*|*-.*) return 1 ;;
    esac
    case "$d" in
        *.*) : ;;
        *) return 1 ;;
    esac

    old_ifs=$IFS
    IFS=.
    set -- $d
    IFS=$old_ifs
    for label do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        case "$label" in
            -*|*-) return 1 ;;
        esac
    done

    tld=${d##*.}
    if [ "${#tld}" -lt 2 ] || ! printf '%s' "$tld" | grep -Eq '[A-Za-z]'; then
        return 1
    fi
    return 0
}

validate_uuid() {
    printf '%s' "$1" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

validate_ws_path() {
    local p="$1"
    [ -n "$p" ] || return 1
    [ "$p" != "/" ] || return 1
    case "$p" in
        /*) : ;;
        *) return 1 ;;
    esac
    case "$p" in
        *//*|*/../*|*/..|*/./*|*/.) return 1 ;;
    esac
    printf '%s' "$p" | grep -Eq '^/[A-Za-z0-9._~/-]+$'
}

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root."
        if command -v sudo >/dev/null 2>&1; then
            log "Re-running script with sudo..."
            exec sudo bash "$0" "$@"
        else
            error "sudo not available. Please run as root."
            exit 1
        fi
    fi
}

url_encode() {
    # Use python3 for robust URL encoding of arbitrary characters
    if command -v python3 >/dev/null 2>&1; then
        if python3 - "$1" 2>/dev/null <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
        then
            return 0
        fi
    fi

    if command -v jq >/dev/null 2>&1; then
        if printf '%s' "$1" | jq -sRr @uri; then
            return 0
        fi
    fi

    # Best-effort fallback (encodes spaces and slashes)
    printf '%s\n' "$(printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s,/,%2F,g')"
}

ensure_apt_update() {
    if [ "$APT_UPDATED" -eq 1 ]; then
        return 0
    fi
    log "Updating package lists (apt-get update)."
    if DEBIAN_FRONTEND=noninteractive apt-get update -y; then
        APT_UPDATED=1
        return 0
    fi
    warn "apt-get update failed; continuing with existing package lists."
    return 1
}

apt_install() {
    # Install packages with one retry using --fix-broken
    # Usage: apt_install pkg1 pkg2 ...
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    ensure_apt_update
    log "Installing packages: $*"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
        return 0
    fi
    warn "apt-get install failed for: $*. Attempting 'apt-get --fix-broken install' and retry."
    DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y || warn "--fix-broken failed (continuing)."
    ensure_apt_update
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
        return 0
    fi
    warn "Package installation still failing for: $*. Continuing with warnings."
    return 1
}

check_environment() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "apt-get not found. This script supports Ubuntu 22.04+ or other apt-based systems."
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        error "systemctl not found. A systemd-based host is required."
        exit 1
    fi
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" != "ubuntu" ]; then
            warn "Detected ${NAME:-unknown}; script is tested on Ubuntu 22.04+. Continuing anyway."
        else
            local major
            major=${VERSION_ID%%.*}
            if [ "${major:-0}" -lt 22 ]; then
                warn "Ubuntu ${VERSION_ID:-unknown} detected; this script expects 22.04 or newer."
            fi
        fi
    fi
}

#------------------------------ Globals --------------------------------------#

DOMAIN="${DOMAIN:-}"
WS_PATH="${WS_PATH:-}"
UUID="${UUID:-}"
COVER_SITE="${COVER_SITE:-y}"
NGINX_AVAILABLE=0
CERT_TOOL="none"   # certbot | acme | none
CERT_DIR=""
CERT_FILE=""
KEY_FILE=""
XRAY_BIN=""
XRAY_CONFIG_PATH=""
FRESH_INSTALL="${FRESH_INSTALL:-y}"
SETUP_UFW="${SETUP_UFW:-y}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
TOTAL_STEPS=12 # Keep in sync with progress_step calls in main
CURRENT_STEP=0
START_TS=0
APT_UPDATED=0

#--------------------------- Interactive Input -------------------------------#

require_option_value() {
    local opt="$1" value="${2-}"
    if [ -z "$value" ]; then
        error "$opt requires a value."
        usage
        exit 2
    fi
    case "$value" in
        --*)
            error "$opt requires a value."
            usage
            exit 2
            ;;
    esac
}

parse_yn_option() {
    local opt="$1" value="$2" normalized
    normalized=$(normalize_yn "$value")
    if [ -z "$normalized" ]; then
        error "$opt must be y/yes or n/no."
        return 1
    fi
    printf '%s\n' "$normalized"
}

normalize_non_interactive() {
    case "$(trim "$NON_INTERACTIVE" | tr 'A-Z' 'a-z')" in
        1|true|y|yes) NON_INTERACTIVE=1 ;;
        0|false|n|no|"") NON_INTERACTIVE=0 ;;
        *)
            error "NON_INTERACTIVE must be 0/1, true/false, or y/n."
            exit 2
            ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --domain)
                require_option_value "$1" "${2-}"
                DOMAIN="$2"; shift 2 ;;
            --domain=*)
                DOMAIN="${1#*=}"; shift ;;
            --ws-path)
                require_option_value "$1" "${2-}"
                WS_PATH="$2"; shift 2 ;;
            --ws-path=*)
                WS_PATH="${1#*=}"; shift ;;
            --uuid)
                require_option_value "$1" "${2-}"
                UUID="$2"; shift 2 ;;
            --uuid=*)
                UUID="${1#*=}"; shift ;;
            --cover-site)
                require_option_value "$1" "${2-}"
                COVER_SITE=$(parse_yn_option "$1" "$2") || exit 2; shift 2 ;;
            --cover-site=*)
                COVER_SITE=$(parse_yn_option "--cover-site" "${1#*=}") || exit 2; shift ;;
            --fresh-install)
                require_option_value "$1" "${2-}"
                FRESH_INSTALL=$(parse_yn_option "$1" "$2") || exit 2; shift 2 ;;
            --fresh-install=*)
                FRESH_INSTALL=$(parse_yn_option "--fresh-install" "${1#*=}") || exit 2; shift ;;
            --setup-ufw)
                require_option_value "$1" "${2-}"
                SETUP_UFW=$(parse_yn_option "$1" "$2") || exit 2; shift 2 ;;
            --setup-ufw=*)
                SETUP_UFW=$(parse_yn_option "--setup-ufw" "${1#*=}") || exit 2; shift ;;
            --non-interactive|--yes)
                NON_INTERACTIVE=1; shift ;;
            --help)
                usage
                exit 0 ;;
            --)
                shift; break ;;
            *)
                error "Unknown option: $1"
                usage
                exit 2 ;;
        esac
    done
    normalize_non_interactive
}

prompt_inputs() {
    local use_custom_uuid

    # 1. Domain
    while :; do
        if [ -n "$DOMAIN" ]; then
            DOMAIN=$(trim "$DOMAIN" | tr 'A-Z' 'a-z')
            if validate_domain "$DOMAIN"; then
                break
            fi
            echo "Invalid domain format provided."
            [ "$NON_INTERACTIVE" -eq 1 ] && exit 1
            DOMAIN=""
        fi
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            error "--domain is required in non-interactive mode."
            exit 1
        fi
        printf 'Enter your domain (e.g. example.com): '
        read -r DOMAIN
        DOMAIN=$(trim "$DOMAIN" | tr 'A-Z' 'a-z')
        if [ -z "$DOMAIN" ]; then
            echo "Domain cannot be empty."
            continue
        fi
        if validate_domain "$DOMAIN"; then
            break
        else
            echo "Invalid domain format. Please try again."
        fi
    done

    # 2. Fresh install?
    if [ -n "$FRESH_INSTALL" ]; then
        FRESH_INSTALL=$(normalize_yn "$FRESH_INSTALL")
    fi
    if [ -z "$FRESH_INSTALL" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            FRESH_INSTALL="y"
        else
            FRESH_INSTALL=$(prompt_yes_no "Is this a fresh VPS install? (y/n)" "y")
        fi
    fi

    # 3. Fake cover website?
    if [ -n "$COVER_SITE" ]; then
        COVER_SITE=$(normalize_yn "$COVER_SITE")
    fi
    if [ -z "$COVER_SITE" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            COVER_SITE="y"
        else
            COVER_SITE=$(prompt_yes_no "Would you like to auto-generate a fake cover website? (y/n)" "y")
        fi
    fi

    # 4. WebSocket path
    while :; do
        if [ -z "$WS_PATH" ]; then
            if [ "$NON_INTERACTIVE" -eq 1 ]; then
                WS_PATH="/ws"
            else
                printf 'Enter WebSocket path (default /ws): '
                read -r WS_PATH
            fi
        fi

        WS_PATH=$(trim "$WS_PATH")
        [ -z "$WS_PATH" ] && WS_PATH="/ws"
        case "$WS_PATH" in
            /*) : ;;
            *)  WS_PATH="/$WS_PATH" ;;
        esac
        if validate_ws_path "$WS_PATH"; then
            break
        fi

        echo "Invalid WebSocket path. Use a path like /ws or /edge-1; only letters, numbers, '.', '_', '-', '~', and '/' are allowed, and '/' alone is not allowed."
        [ "$NON_INTERACTIVE" -eq 1 ] && exit 1
        WS_PATH=""
    done

    # 5. UUID
    if [ -n "$UUID" ]; then
        UUID=$(trim "$UUID" | tr 'A-F' 'a-f')
        if ! validate_uuid "$UUID"; then
            echo "Invalid UUID format provided."
            [ "$NON_INTERACTIVE" -eq 1 ] && exit 1
            UUID=""
        fi
    fi
    if [ -z "$UUID" ]; then
        use_custom_uuid="n"
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            use_custom_uuid="n"
        else
            use_custom_uuid=$(prompt_yes_no "Would you like to provide a UUID? (y/n)" "n")
        fi
        if [ "$use_custom_uuid" = "y" ]; then
            while :; do
                printf 'Enter UUID (e.g. 550e8400-e29b-41d4-a716-446655440000): '
                read -r UUID
                UUID=$(trim "$UUID" | tr 'A-F' 'a-f')
                if validate_uuid "$UUID"; then
                    break
                else
                    echo "Invalid UUID format. Please try again."
                fi
            done
        else
            if command -v uuidgen >/dev/null 2>&1; then
                UUID=$(uuidgen)
            elif [ -r /proc/sys/kernel/random/uuid ]; then
                UUID=$(cat /proc/sys/kernel/random/uuid)
            else
                warn "Unable to auto-generate UUID (uuidgen and /proc unavailable), falling back to fixed placeholder (NOT recommended for production)."
                UUID="550e8400-e29b-41d4-a716-446655440000"
            fi
            UUID=$(trim "$UUID" | tr 'A-F' 'a-f')
        fi
    fi

    # 6. Firewall
    if [ -n "$SETUP_UFW" ]; then
        SETUP_UFW=$(normalize_yn "$SETUP_UFW")
    fi
    if [ -z "$SETUP_UFW" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            SETUP_UFW="y"
        else
            SETUP_UFW=$(prompt_yes_no "Configure UFW to allow SSH/HTTP/HTTPS and enable it? (y/n)" "y")
        fi
    fi
}

#--------------------------- System Preparation ------------------------------#

system_prepare() {
    if [ "$FRESH_INSTALL" = "y" ]; then
        log "Updating package lists and upgrading system (fresh install)."
        if DEBIAN_FRONTEND=noninteractive apt-get update -y; then
            APT_UPDATED=1
        else
            warn "apt-get update failed."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || warn "apt-get upgrade failed."
    fi

    log "Installing base dependencies (curl, wget, unzip, jq, socat, openssl, cron)."
    apt_install curl wget unzip jq socat openssl cron

    log "Installing / checking Nginx."
    if apt_install nginx; then
        NGINX_AVAILABLE=1
    else
        NGINX_AVAILABLE=0
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            warn "Nginx installation failed. Proceeding without web server in non-interactive mode."
            return 0
        fi
        local retry
        retry=$(prompt_yes_no "Nginx installation failed. Retry? (y/n)" "n")
        if [ "$retry" = "y" ]; then
            if apt_install nginx; then
                NGINX_AVAILABLE=1
            else
                warn "Nginx still failing to install. Proceeding without web server."
            fi
        else
            warn "Proceeding without web server as requested."
        fi
    fi
}

install_acme() {
    # Attempt to install acme.sh if not already available
    if command -v acme.sh >/dev/null 2>&1; then
        return 0
    fi
    if [ -x /root/.acme.sh/acme.sh ]; then
        PATH="/root/.acme.sh:$PATH"
        export PATH
        return 0
    fi

    log "Installing acme.sh as fallback certificate client."
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL https://get.acme.sh -o /tmp/acme.sh; then
            if sh /tmp/acme.sh --install --home /root/.acme.sh >/tmp/acme_install.log 2>&1; then
                if [ -x /root/.acme.sh/acme.sh ]; then
                    PATH="/root/.acme.sh:$PATH"
                    export PATH
                    return 0
                fi
            else
                warn "acme.sh installation script failed. Check /tmp/acme_install.log if needed."
            fi
        else
            warn "Failed to download acme.sh installation script."
        fi
    else
        warn "curl missing; cannot install acme.sh automatically."
    fi
    return 1
}

select_cert_tool() {
    # Prefer certbot, fall back to acme.sh, then self-signed
    log "Attempting to install certbot."
    if apt_install certbot; then
        CERT_TOOL="certbot"
        log "Using certbot for certificate management."
    else
        CERT_TOOL="none"
        warn "certbot installation failed; trying acme.sh as fallback."
        if install_acme; then
            CERT_TOOL="acme"
            log "Using acme.sh for certificate management."
        else
            CERT_TOOL="none"
            warn "acme.sh installation also failed; will fall back to self-signed certificates."
        fi
    fi
}

#---------------------------- DNS Resilience ---------------------------------#

check_dns_health() {
    log "Checking DNS resolution for $DOMAIN."
    local resolved
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$resolved" ] && resolved=$(getent hosts "$DOMAIN" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ {print $1; exit}')
    if [ -n "$resolved" ]; then
        log "System resolver OK: $DOMAIN -> $resolved"
    else
        warn "System resolver could not resolve $DOMAIN. Trying fallback DNS servers."
        apt_install dnsutils >/dev/null 2>&1 || warn "Failed to install dnsutils; continuing with available tools."

        local resolver found_ip
        for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
            found_ip=$(dig +short A @"$resolver" "$DOMAIN" 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
            [ -z "$found_ip" ] && found_ip=$(nslookup -type=A "$DOMAIN" "$resolver" 2>/dev/null | awk '/^Address: / && $2 !~ /#/ {print $2; exit}')
            if [ -n "$found_ip" ]; then
                resolved="$found_ip"
                log "Resolved via fallback DNS $resolver: $found_ip"
                local update_dns
                if [ "$NON_INTERACTIVE" -eq 1 ]; then
                    update_dns="n"
                else
                    update_dns=$(prompt_yes_no "Use fallback resolvers ($resolver, 8.8.8.8, 1.1.1.1) in /etc/resolv.conf? (y/n)" "y")
                fi
                if [ "$update_dns" = "y" ]; then
                    local resolv_bak="/etc/resolv.conf.bak.$(date +%s)"
                    cp /etc/resolv.conf "$resolv_bak" 2>/dev/null || true
                    {
                        echo "nameserver $resolver"
                        echo "nameserver 8.8.8.8"
                        echo "nameserver 1.1.1.1"
                    } > /etc/resolv.conf 2>/dev/null || warn "Failed to write fallback resolvers to /etc/resolv.conf."
                    log "Fallback resolvers written. Original copy (if any): $resolv_bak"
                fi
                break
            fi
        done
    fi

    if [ -z "$resolved" ]; then
        warn "Unable to resolve $DOMAIN with any resolver. Certificate issuance may fail until DNS propagates."
        return 1
    fi

    local public_ip=""
    if command -v curl >/dev/null 2>&1; then
        public_ip=$(curl -4s --max-time 5 https://api.ipify.org || true)
        [ -z "$public_ip" ] && public_ip=$(curl -4s --max-time 5 https://ifconfig.me || true)
    fi

    if [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
        warn "DNS for $DOMAIN resolves to $resolved but this server's public IPv4 is $public_ip. Certificates may fail until DNS points here."
        if [ "$NON_INTERACTIVE" -ne 1 ]; then
            local continue_anyway
            continue_anyway=$(prompt_yes_no "Continue despite DNS mismatch? (y/n)" "n")
            [ "$continue_anyway" = "n" ] && exit 1
        fi
    fi

    return 0
}

check_port_conflicts() {
    # Warn if something else is already listening on 80/443
    if ! command -v ss >/dev/null 2>&1; then
        return 0
    fi
    local conflicts
    conflicts=$(ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /:443$/')
    if [ -n "$conflicts" ]; then
        warn "Detected listeners on ports 80/443 that may block certificate issuance:"
        echo "$conflicts"
    fi
}

setup_certificates() {
    CERT_DIR="/etc/ssl/$DOMAIN"
    if ! mkdir -p "$CERT_DIR" 2>/dev/null; then
        warn "Failed to create $CERT_DIR on first attempt. Retrying with sudo."
        if ! sudo mkdir -p "$CERT_DIR" 2>/dev/null; then
            error "Could not create certificate directory $CERT_DIR."
            return 1
        fi
    fi

    CERT_FILE="$CERT_DIR/fullchain.cer"
    KEY_FILE="$CERT_DIR/privkey.key"

    local got_cert=0
    check_port_conflicts
    systemctl stop nginx 2>/dev/null || true

    # 1. Try certbot standalone
    if [ "$CERT_TOOL" = "certbot" ]; then
        log "Attempting certificate issuance via certbot (standalone HTTP challenge)."
        if certbot certonly --standalone --agree-tos --register-unsafely-without-email \
            --non-interactive -d "$DOMAIN"; then
            local le_dir="/etc/letsencrypt/live/$DOMAIN"
            if [ -f "$le_dir/fullchain.pem" ] && [ -f "$le_dir/privkey.pem" ]; then
                if cp "$le_dir/fullchain.pem" "$CERT_FILE" 2>/dev/null && \
                   cp "$le_dir/privkey.pem" "$KEY_FILE" 2>/dev/null; then
                    got_cert=1
                    log "Certificates copied to $CERT_DIR from certbot."
                else
                    warn "Failed to copy certbot certificates into $CERT_DIR."
                fi
            else
                warn "certbot did not produce expected files in $le_dir."
            fi
        else
            warn "certbot certificate issuance failed."
        fi
    fi

    if [ "$got_cert" -eq 0 ] && [ "$CERT_TOOL" != "acme" ]; then
        warn "Trying acme.sh as fallback certificate client."
        if install_acme; then
            CERT_TOOL="acme"
        else
            CERT_TOOL="none"
            warn "acme.sh fallback is unavailable; will use self-signed certificate."
        fi
    fi

    # 2. Fallback to acme.sh
    if [ "$got_cert" -eq 0 ] && [ "$CERT_TOOL" = "acme" ]; then
        log "Attempting certificate issuance via acme.sh (standalone)."
        if [ -x "/root/.acme.sh/acme.sh" ]; then
            PATH="/root/.acme.sh:$PATH"
            export PATH
        fi
        if command -v acme.sh >/dev/null 2>&1; then
            acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
            if acme.sh --issue --standalone -d "$DOMAIN" >/tmp/acme_issue.log 2>&1; then
                if acme.sh --install-cert -d "$DOMAIN" \
                    --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" >/tmp/acme_install_cert.log 2>&1; then
                    got_cert=1
                    log "Certificates installed to $CERT_DIR via acme.sh."
                else
                    warn "acme.sh failed to install certificate files into $CERT_DIR."
                fi
            else
                warn "acme.sh certificate issuance failed. See /tmp/acme_issue.log if needed."
            fi
        else
            warn "acme.sh binary not found in PATH despite installation attempt."
        fi
    fi

    # 3. Self-signed fallback
    if [ "$got_cert" -eq 0 ]; then
        warn "All automated certificate methods failed. Generating self-signed certificate."
        if ! command -v openssl >/dev/null 2>&1; then
            apt_install openssl || warn "openssl still missing; self-signed generation may fail."
        fi
        if openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1; then
            got_cert=2
            warn "Self-signed certificate generated in $CERT_DIR. It will not be trusted by browsers/CDN without additional configuration."
        else
            error "Failed to generate self-signed certificate. TLS will not function correctly."
            return 1
        fi
    fi

    if [ "$got_cert" -eq 1 ]; then
        log "Certificate obtained successfully for $DOMAIN."
    fi
}

#--------------------------- Fake Website Setup ------------------------------#

setup_fake_website() {
    if [ "$COVER_SITE" != "y" ]; then
        log "Skipping fake cover website generation as per user choice."
        return 0
    fi

    local web_root="/var/www/html"
    mkdir -p "$web_root" 2>/dev/null || warn "Could not create $web_root on first attempt."

    local html_file="$web_root/index.html"

    log "Creating minimal business-style HTML cover page at $html_file."
    if ! cat > "$html_file" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$(printf '%s' "$DOMAIN") - Business Solutions</title>
    <style>
        body { font-family: Arial, sans-serif; margin:0; padding:0; background:#f5f5f5; }
        header { background:#1f2933; color:#fff; padding:20px; text-align:center; }
        main { max-width:960px; margin:40px auto; background:#fff; padding:30px; box-shadow:0 0 10px rgba(0,0,0,0.05); }
        h1 { margin-top:0; }
        footer { text-align:center; padding:20px; font-size:12px; color:#666; }
    </style>
</head>
<body>
    <header>
        <h1>$(printf '%s' "$DOMAIN")</h1>
        <p>Secure &amp; Reliable Online Services</p>
    </header>
    <main>
        <h2>Enterprise-Grade Web Solutions</h2>
        <p>We provide scalable, secure, and high-performance web platforms tailored for modern businesses.</p>
        <p>Our infrastructure is built with reliability and security at its core, ensuring consistent uptime and performance.</p>
    </main>
    <footer>
        &copy; $(date +%Y) $(printf '%s' "$DOMAIN"). All rights reserved.
    </footer>
</body>
</html>
EOF
    then
        warn "Failed to write cover website. Attempting to adjust permissions and retry."
        chown -R www-data:www-data "$web_root" 2>/dev/null || warn "Failed to chown $web_root."
        if ! cat > "$html_file" <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>$(printf '%s' "$DOMAIN")</title></head><body><h1>$(printf '%s' "$DOMAIN")</h1><p>Placeholder site.</p></body></html>
EOF
        then
            warn "Still failed to write cover website at $html_file. Continuing without it."
        fi
    fi
}

#----------------------------- Xray Installation -----------------------------#

detect_xray_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l|armv7) echo "arm32-v7a" ;;
        *) echo "64" ;;
    esac
}

install_xray() {
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl is required to download Xray; attempting to install."
        apt_install curl || true
    fi

    local arch
    arch=$(detect_xray_arch)
    local api_json url

    log "Fetching latest Xray-core release information."
    api_json=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null || true)
    if [ -n "$api_json" ] && command -v jq >/dev/null 2>&1; then
        url=$(printf '%s' "$api_json" | jq -r ".assets[] | select(.name | test(\"Xray-linux-${arch}\\.zip\")) | .browser_download_url" | head -n 1)
    fi

    if [ -z "$url" ]; then
        url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    fi

    local tmp_zip="/tmp/xray.zip" tmp_dir="/tmp/xray_extracted"
    rm -rf "$tmp_dir" 2>/dev/null || true
    mkdir -p "$tmp_dir" 2>/dev/null || true

    local attempt=1 success=0
    while [ "$attempt" -le 2 ] && [ "$success" -eq 0 ]; do
        log "Downloading Xray-core archive (attempt $attempt)..."
        if curl -fSL "$url" -o "$tmp_zip" 2>/dev/null; then
            if unzip -t "$tmp_zip" >/dev/null 2>&1; then
                success=1
            else
                warn "Xray archive integrity check failed (unzip -t)."
            fi
        else
            warn "Failed to download Xray from $url."
        fi
        attempt=$((attempt + 1))
    done

    if [ "$success" -eq 0 ]; then
        error "Unable to download or verify Xray archive. Please install Xray manually."
        XRAY_BIN=""
        return 1
    fi

    if ! unzip -oq "$tmp_zip" -d "$tmp_dir" >/dev/null 2>&1; then
        error "Failed to extract Xray archive."
        XRAY_BIN=""
        return 1
    fi

    if [ -f "$tmp_dir/xray" ]; then
        if install -m 755 "$tmp_dir/xray" /usr/local/bin/xray 2>/dev/null; then
            XRAY_BIN="/usr/local/bin/xray"
        elif install -m 755 "$tmp_dir/xray" /usr/bin/xray 2>/dev/null; then
            XRAY_BIN="/usr/bin/xray"
        else
            error "Failed to install Xray binary to /usr/local/bin or /usr/bin."
            XRAY_BIN=""
            return 1
        fi
    else
        error "xray binary not found in extracted archive."
        XRAY_BIN=""
        return 1
    fi

    log "Xray installed at $XRAY_BIN."
}

write_xray_config() {
    local output_path="$1"
    cat > "$output_path" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "",
            "email": "$DOMAIN"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH",
          "headers": {
            "Host": "$DOMAIN"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF
}

configure_xray() {
    # Determine preferred config path
    XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
    local config_dir
    config_dir=$(dirname "$XRAY_CONFIG_PATH")

    if ! mkdir -p "$config_dir" 2>/dev/null; then
        warn "Failed to create $config_dir; falling back to /etc/xray."
        XRAY_CONFIG_PATH="/etc/xray/config.json"
        config_dir=$(dirname "$XRAY_CONFIG_PATH")
        mkdir -p "$config_dir" 2>/dev/null || warn "Failed to create $config_dir as well."
    fi

    # Ensure jq is available for validation
    if ! command -v jq >/dev/null 2>&1; then
        apt_install jq || warn "jq not available; JSON validation will be skipped."
    fi

    local tmp_config="/tmp/xray-config.json"
    if ! mkdir -p /var/log/xray 2>/dev/null; then
        warn "Failed to create /var/log/xray; log files may not be written."
    else
        touch /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
        chmod 640 /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
    fi

    if ! write_xray_config "$tmp_config"; then
        error "Failed to write temporary Xray config at $tmp_config."
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        if ! jq . "$tmp_config" >/dev/null 2>&1; then
            error "Generated Xray config JSON is invalid. Please review $tmp_config manually."
            return 1
        fi
    fi

    if ! mv "$tmp_config" "$XRAY_CONFIG_PATH" 2>/dev/null; then
        warn "Failed to move config to $XRAY_CONFIG_PATH; retrying with /etc/xray path."
        XRAY_CONFIG_PATH="/etc/xray/config.json"
        config_dir=$(dirname "$XRAY_CONFIG_PATH")
        mkdir -p "$config_dir" 2>/dev/null || true
        if ! mv "$tmp_config" "$XRAY_CONFIG_PATH" 2>/dev/null; then
            error "Failed to write Xray config to both /usr/local/etc and /etc/xray."
            return 1
        fi
    fi

    log "Xray configuration written to $XRAY_CONFIG_PATH."
}

setup_xray_service() {
    if [ -z "$XRAY_BIN" ]; then
        warn "Xray binary path is empty; skipping service setup."
        return 1
    fi

    local service_path="/etc/systemd/system/xray.service"

    cat > "$service_path" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_PATH
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload >/dev/null 2>&1; then
        warn "systemctl daemon-reload failed after creating Xray service file."
    fi

    local attempt=1 ok=0
    while [ "$attempt" -le 2 ] && [ "$ok" -eq 0 ]; do
        if systemctl enable xray >/dev/null 2>&1; then
            ok=1
        else
            warn "Failed to enable xray service (attempt $attempt). Retrying after daemon-reload."
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        attempt=$((attempt + 1))
    done

    if [ "$ok" -eq 0 ]; then
        warn "Unable to enable xray service automatically. You can enable it manually with:"
        echo "  systemctl enable xray"
        echo "  systemctl start xray"
        return 1
    fi

    log "Xray systemd service installed as xray.service."
}

#------------------------------ Nginx Config ---------------------------------#

configure_nginx() {
    if [ "$NGINX_AVAILABLE" -ne 1 ]; then
        warn "Skipping Nginx configuration because Nginx is not installed."
        return 0
    fi

    local nginx_conf_dir="/etc/nginx"
    local sites_available="$nginx_conf_dir/sites-available"
    local sites_enabled="$nginx_conf_dir/sites-enabled"
    local nginx_conf="$sites_available/$DOMAIN"
    local nginx_conf_enabled="$sites_enabled/$DOMAIN"
    local backup_conf=""

    mkdir -p "$sites_available" "$sites_enabled" 2>/dev/null || true

    if [ -f "$nginx_conf" ]; then
        backup_conf="${nginx_conf}.bak.$(date +%s)"
        cp "$nginx_conf" "$backup_conf" 2>/dev/null || backup_conf=""
    fi

    cat > "$nginx_conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /var/www/html;
    index index.html index.htm;

    # WebSocket VLESS path
    location = $WS_PATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    # Normal website
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    if [ ! -L "$nginx_conf_enabled" ]; then
        ln -sf "$nginx_conf" "$nginx_conf_enabled" 2>/dev/null || warn "Failed to create symlink in sites-enabled for $DOMAIN."
    fi

    if ! nginx -t >/dev/null 2>&1; then
        warn "Nginx configuration test failed. Rolling back to previous config."
        if [ -n "$backup_conf" ] && [ -f "$backup_conf" ]; then
            mv "$backup_conf" "$nginx_conf" 2>/dev/null || warn "Failed to restore previous Nginx config from backup."
        else
            rm -f "$nginx_conf" "$nginx_conf_enabled" 2>/dev/null || true
        fi
        nginx -t >/dev/null 2>&1 || warn "Nginx still failing configuration test after rollback. Please inspect manually."
        return 1
    fi

    # Cleanup backup on success
    if [ -n "$backup_conf" ] && [ -f "$backup_conf" ]; then
        rm -f "$backup_conf" 2>/dev/null || true
    fi

    log "Nginx configuration for $DOMAIN written to $nginx_conf."
}

#---------------------------- Firewall Setup --------------------------------#

setup_firewall() {
    if [ "$SETUP_UFW" != "y" ]; then
        log "Skipping UFW configuration as requested."
        return 0
    fi

    log "Configuring UFW firewall (allow SSH/HTTP/HTTPS and enable)."
    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw || warn "Failed to install ufw; firewall configuration will be skipped."
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw not available; skipping firewall setup."
        return 1
    fi

    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true

    if ufw --force enable >/dev/null 2>&1; then
        log "UFW enabled with rules for SSH (22), HTTP (80), and HTTPS (443)."
    else
        warn "Failed to enable UFW automatically. You may need to review firewall rules manually."
    fi
}

#--------------------------- Service Management ------------------------------#

manage_service() {
    # $1 service name, $2 action (start|restart)
    local svc="$1" action="$2" attempt=1 ok=0
    while [ "$attempt" -le 2 ] && [ "$ok" -eq 0 ]; do
        if systemctl "$action" "$svc" >/dev/null 2>&1; then
            ok=1
        else
            warn "systemctl $action $svc failed (attempt $attempt)."
            if [ "$attempt" -eq 1 ]; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [ "$ok" -eq 0 ]; then
        warn "Service $svc failed to $action. Showing last 20 log lines:"
        journalctl -u "$svc" --no-pager 2>/dev/null | tail -n 20 || true
    fi
}

enable_and_start_services() {
    if [ "$NGINX_AVAILABLE" -eq 1 ]; then
        systemctl enable nginx >/dev/null 2>&1 || warn "Could not enable nginx service (might already be enabled)."
        manage_service nginx restart
    fi

    if [ -n "$XRAY_BIN" ]; then
        systemctl enable xray >/dev/null 2>&1 || warn "Could not enable xray service (might already be enabled)."
        manage_service xray restart
    fi
}

#--------------------------------- Main --------------------------------------#

main() {
    parse_args "$@"
    ensure_root "$@"
    check_environment

    progress_init "$TOTAL_STEPS"

    progress_step "Collecting user inputs"
    prompt_inputs

    progress_step "Preparing system packages"
    system_prepare

    progress_step "Checking DNS and fallbacks"
    check_dns_health

    progress_step "Selecting certificate client"
    select_cert_tool

    progress_step "Obtaining certificates (certbot/acme/self-signed)"
    setup_certificates

    progress_step "Building fake cover website"
    setup_fake_website

    progress_step "Installing Xray core"
    install_xray

    progress_step "Writing Xray configuration"
    configure_xray

    progress_step "Registering Xray systemd service"
    setup_xray_service

    progress_step "Configuring Nginx reverse proxy"
    configure_nginx

    progress_step "Configuring UFW firewall"
    setup_firewall

    progress_step "Starting services"
    enable_and_start_services

    # URL-encode the WebSocket path for the VLESS URI
    local encoded_path
    encoded_path=$(url_encode "$WS_PATH")

    local vless_uri
    vless_uri="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_path"

    echo
    echo "-------------------- SETUP SUMMARY --------------------"
    echo "Domain       : $DOMAIN"
    echo "WebSocket WS : $WS_PATH"
    echo "Encoded path : $encoded_path"
    echo "UUID         : $UUID"
    echo
    echo "VLESS URI (URL-encoded path):"
    echo "  $vless_uri"
    echo
    echo "Key paths:"
    echo "  Xray config : $XRAY_CONFIG_PATH"
    echo "  Website root: /var/www/html/"
    if [ "$NGINX_AVAILABLE" -eq 1 ]; then
        echo "  Nginx site  : /etc/nginx/sites-enabled/$DOMAIN"
    else
        echo "  Nginx site  : (Nginx not installed)"
    fi
    echo "  Cert dir    : $CERT_DIR/"
    if [ "$SETUP_UFW" = "y" ]; then
        echo "  Firewall    : UFW enabled for ports 22, 80, 443 (if install succeeded)"
    else
        echo "  Firewall    : UFW skipped"
    fi

    local total_elapsed=$(( $(date +%s) - START_TS ))
    echo "Elapsed time : $(format_duration "$total_elapsed")"
    echo "-------------------------------------------------------"
}

main "$@"
