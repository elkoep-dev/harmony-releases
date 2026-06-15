#!/usr/bin/env bash
# iNELS Harmony — Smart Installer
# Usage:  curl -sL https://raw.githubusercontent.com/elkoep-dev/harmony-releases/main/install.sh | sudo bash
#    or:  sudo bash install-harmony.sh [OPTIONS]
#
# Options:
#   --version VERSION         Install specific version (e.g. 1.28.3)
#   --tarball PATH            Use local tarball (skip download)
#   --non-interactive         No TUI prompts, use defaults + flags
#   --hotel-name NAME         Hotel name (default: My Hotel)
#   --password PASSWORD       Database password (default: webmodul)
#   --interface IFACE         Network interface (default: auto-detect)
#   --landing-port PORT       Landing page port (default: 80)
#   --admin-port PORT         Administration port (default: 81)
#   --reception-port PORT     Reception port (default: 82)
set -euo pipefail

# ---------------------------------------------------------------------------
# Section 1: Constants & defaults
# ---------------------------------------------------------------------------

readonly INSTALLER_VERSION="1.0.0"
readonly GITHUB_OWNER="elkoep-dev"
readonly GITHUB_REPO="harmony-releases"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases"
readonly INSTALL_DIR="/opt/hrs-container"
readonly METADATA_DIR="${INSTALL_DIR}/.harmony"
readonly LOG_FILE="/var/log/harmony-install.log"
readonly MIN_DISK_MB=3000

HOTEL_NAME="My Hotel"
ADMIN_PASSWORD=""
LANDING_PORT=80
ADMIN_PORT=81
RECEPTION_PORT=82
NET_INTERFACE=""
SERVER_IP=""
SELECTED_VERSION=""
TARBALL_PATH=""
NON_INTERACTIVE=0

# Harmony Cloud Portal integration
PORTAL_URL="https://harmony-portal.onrender.com"
REGISTRATION_TOKEN=""
SKIP_PORTAL=0
AUTO_UPDATE="false"
PORTAL_REGISTERED=0

TUI_CMD=""
TUI_MODE="tui"

INSTALL_STARTED=0
CONTAINERS_STARTED=0
TARBALL_EXTRACTED=0
HAD_EXISTING_INSTALL=0

# ---------------------------------------------------------------------------
# Section 2: Utility functions
# ---------------------------------------------------------------------------

log_info()  { printf '[%s] INFO:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
log_warn()  { printf '[%s] WARN:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
log_error() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

run_logged() { "$@" >>"$LOG_FILE" 2>&1; }

die() {
  log_error "$1"
  if [ "$TUI_MODE" = "tui" ] && [ -n "$TUI_CMD" ]; then
    $TUI_CMD --title "Error" --msgbox "$1\n\nCheck log: $LOG_FILE" 12 60
  fi
  exit 1
}

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ $INSTALL_STARTED -eq 1 ]; then
    log_error "Installation failed (exit code $exit_code). Cleaning up..."
    if [ $CONTAINERS_STARTED -eq 1 ]; then
      cd "$INSTALL_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    fi
    if [ $TARBALL_EXTRACTED -eq 1 ] && [ "$HAD_EXISTING_INSTALL" -eq 0 ]; then
      rm -rf "$INSTALL_DIR" 2>/dev/null || true
    fi
  fi
  rm -f /tmp/harmony-*.tar.gz.tmp 2>/dev/null || true
}
trap cleanup EXIT

check_command() { command -v "$1" >/dev/null 2>&1; }

generate_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true
}

# ---------------------------------------------------------------------------
# Section 3: TUI functions (whiptail wrappers with plain-text fallback)
# ---------------------------------------------------------------------------

tui_init() {
  if check_command whiptail; then
    TUI_CMD="whiptail"
    TUI_MODE="tui"
    return
  fi
  if check_command dialog; then
    TUI_CMD="dialog"
    TUI_MODE="tui"
    return
  fi
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    TUI_MODE="plain"
    return
  fi
  if check_command apt-get; then
    log_info "Installing whiptail for interactive installer..."
    apt-get update -qq >>"$LOG_FILE" 2>&1 || true
    apt-get install -y -qq whiptail >>"$LOG_FILE" 2>&1 || true
  fi
  if check_command whiptail; then
    TUI_CMD="whiptail"
    TUI_MODE="tui"
  else
    TUI_MODE="plain"
  fi
}

tui_msgbox() {
  local title="$1" text="$2"
  if [ "$TUI_MODE" = "tui" ]; then
    $TUI_CMD --title "$title" --msgbox "$text" 18 70
  else
    echo ""
    echo "=== $title ==="
    echo "$text"
    echo ""
  fi
}

tui_yesno() {
  local title="$1" text="$2"
  if [ "$TUI_MODE" = "tui" ]; then
    if $TUI_CMD --title "$title" --yesno "$text" 14 70; then
      return 0
    else
      return 1
    fi
  else
    echo ""
    echo "=== $title ==="
    echo "$text"
    printf "Proceed? [Y/n] "
    read -r answer
    case "$answer" in
      [nN]*) return 1 ;;
      *) return 0 ;;
    esac
  fi
}

tui_inputbox() {
  local title="$1" text="$2" default="$3" result
  if [ "$TUI_MODE" = "tui" ]; then
    result=$($TUI_CMD --title "$title" --inputbox "$text" 10 70 "$default" 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$result"
  else
    printf '%s [%s]: ' "$text" "$default"
    read -r result
    printf '%s' "${result:-$default}"
  fi
}

tui_passwordbox() {
  local title="$1" text="$2" result
  if [ "$TUI_MODE" = "tui" ]; then
    result=$($TUI_CMD --title "$title" --passwordbox "$text" 10 70 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$result"
  else
    printf '%s: ' "$text"
    read -rs result
    echo ""
    printf '%s' "$result"
  fi
}

tui_menu() {
  local title="$1" text="$2"
  shift 2
  if [ "$TUI_MODE" = "tui" ]; then
    local items=()
    while [ $# -ge 2 ]; do
      items+=("$1" "$2")
      shift 2
    done
    local count=$(( ${#items[@]} / 2 ))
    local height=$(( count + 8 ))
    [ $height -gt 22 ] && height=22
    local result
    result=$($TUI_CMD --title "$title" --menu "$text" $height 70 $count "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$result"
  else
    echo ""
    echo "=== $title ==="
    echo "$text"
    echo ""
    local idx=1
    local first_key=""
    while [ $# -ge 2 ]; do
      [ -z "$first_key" ] && first_key="$1"
      printf '  %d) %s — %s\n' "$idx" "$1" "$2"
      idx=$(( idx + 1 ))
      shift 2
    done
    printf 'Selection [1]: '
    read -r choice
    choice="${choice:-1}"
    printf '%s' "$first_key"
  fi
}

tui_gauge() {
  local title="$1" text="$2" percent="$3"
  if [ "$TUI_MODE" = "tui" ]; then
    echo "$percent" | $TUI_CMD --title "$title" --gauge "$text" 8 70 "$percent"
  else
    printf '\r  [%-50s] %d%%  %s' \
      "$(printf '#%.0s' $(seq 1 $(( percent / 2 )) ) )" "$percent" "$text"
    [ "$percent" -eq 100 ] && echo ""
  fi
}

tui_gauge_cmd() {
  local title="$1"
  shift
  local steps=("$@")
  local total=${#steps[@]}
  local i=0
  for step in "${steps[@]}"; do
    i=$(( i + 1 ))
    local pct=$(( i * 100 / total ))
    if [ "$TUI_MODE" = "tui" ]; then
      echo "$pct"
    else
      printf '\r  [%-50s] %d%%  %s' \
        "$(printf '#%.0s' $(seq 1 $(( pct / 2 )) ) )" "$pct" "$step"
    fi
  done | if [ "$TUI_MODE" = "tui" ]; then
    $TUI_CMD --title "$title" --gauge "" 8 70 0
  else
    cat >/dev/null
  fi
  [ "$TUI_MODE" = "plain" ] && echo ""
}

# ---------------------------------------------------------------------------
# Section 4: Pre-flight checks
# ---------------------------------------------------------------------------

preflight_checks() {
  log_info "Running pre-flight checks..."

  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This installer must be run as root (use sudo)." >&2
    exit 1
  fi

  if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: This installer requires bash. Run with: curl -sL URL | sudo bash" >&2
    exit 1
  fi

  if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS (/etc/os-release not found). This installer supports Ubuntu and Debian."
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Unsupported OS: ${ID:-unknown}. This installer supports Ubuntu and Debian only." ;;
  esac
  log_info "OS: ${PRETTY_NAME:-$ID}"

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|arm64) ;;
    *) die "Unsupported architecture: $arch. Harmony requires x86_64 or aarch64." ;;
  esac
  log_info "Architecture: $arch"

  local avail_mb
  avail_mb=$(df --output=avail -m /opt 2>/dev/null | tail -1 | tr -d ' ')
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$MIN_DISK_MB" ]; then
    die "Insufficient disk space: ${avail_mb} MB available, ${MIN_DISK_MB} MB required."
  fi
  log_info "Disk space: ${avail_mb:-unknown} MB available"

  if ! curl -sfL --max-time 5 https://api.github.com >/dev/null 2>&1; then
    if [ -z "$TARBALL_PATH" ]; then
      log_warn "Cannot reach GitHub API. Use --tarball for offline install."
    fi
  fi

  log_info "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# Section 5: Docker installation
# ---------------------------------------------------------------------------

ensure_docker() {
  if check_command docker && docker compose version >/dev/null 2>&1; then
    log_info "Docker already installed: $(docker --version)"
    return
  fi

  log_info "Installing Docker Engine..."

  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    tui_msgbox "Docker Required" \
      "Docker is not installed on this system.\n\nThe installer will now install Docker Engine and Docker Compose automatically.\n\nThis may take a few minutes."
  fi

  (
    echo 10
    apt-get update -qq >>"$LOG_FILE" 2>&1
    echo 20
    apt-get install -y -qq ca-certificates curl gnupg >>"$LOG_FILE" 2>&1
    echo 35
    install -m 0755 -d /etc/apt/keyrings
    # shellcheck source=/dev/null
    . /etc/os-release
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc >>"$LOG_FILE" 2>&1
    chmod a+r /etc/apt/keyrings/docker.asc
    echo 50
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq >>"$LOG_FILE" 2>&1
    echo 70
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$LOG_FILE" 2>&1
    echo 85
    systemctl enable --now docker >>"$LOG_FILE" 2>&1
    echo 100
  ) | if [ "$TUI_MODE" = "tui" ]; then
    $TUI_CMD --title "Installing Docker" --gauge "Preparing package manager..." 8 70 0
  else
    while read -r pct; do
      printf '\r  Installing Docker... %d%%' "$pct"
    done
    echo ""
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "Docker installation failed. Check $LOG_FILE for details.\n\nYou can install Docker manually:\n  https://docs.docker.com/engine/install/"
  fi

  log_info "Docker installed: $(docker --version)"
}

# ---------------------------------------------------------------------------
# Section 6: User input collection
# ---------------------------------------------------------------------------

detect_network_interfaces() {
  ip -o -4 addr show 2>/dev/null \
    | awk '{split($4,a,"/"); if ($2 != "lo") print $2, a[1]}' \
    | head -10
}

collect_network_interface() {
  local ifaces
  ifaces=$(detect_network_interfaces)

  if [ -z "$ifaces" ]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    SERVER_IP="${SERVER_IP:-127.0.0.1}"
    NET_INTERFACE=""
    log_warn "No network interfaces detected, using IP: $SERVER_IP"
    return
  fi

  if [ -n "$NET_INTERFACE" ]; then
    SERVER_IP=$(echo "$ifaces" | awk -v iface="$NET_INTERFACE" '$1 == iface {print $2}')
    if [ -z "$SERVER_IP" ]; then
      SERVER_IP=$(echo "$ifaces" | head -1 | awk '{print $2}')
      NET_INTERFACE=$(echo "$ifaces" | head -1 | awk '{print $1}')
    fi
    return
  fi

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    NET_INTERFACE=$(echo "$ifaces" | head -1 | awk '{print $1}')
    SERVER_IP=$(echo "$ifaces" | head -1 | awk '{print $2}')
    return
  fi

  local menu_args=()
  while IFS=' ' read -r iface ip; do
    menu_args+=("$iface" "$ip")
  done <<< "$ifaces"

  local selected
  selected=$(tui_menu "Network Configuration" \
    "Select the network interface for Harmony:" \
    "${menu_args[@]}") || true

  if [ -z "$selected" ]; then
    selected=$(echo "$ifaces" | head -1 | awk '{print $1}')
  fi

  NET_INTERFACE="$selected"
  SERVER_IP=$(echo "$ifaces" | awk -v iface="$selected" '$1 == iface {print $2}')
}

collect_hotel_name() {
  [ "$NON_INTERACTIVE" -eq 1 ] && return

  local result
  result=$(tui_inputbox "Hotel Name" \
    "Enter the name of the hotel:" \
    "$HOTEL_NAME") || true
  [ -n "$result" ] && HOTEL_NAME="$result"
}

collect_admin_password() {
  [ "$NON_INTERACTIVE" -eq 1 ] && return

  local suggested
  suggested=$(generate_password)

  while true; do
    local pass1 pass2

    pass1=$(tui_passwordbox "Database Password" \
      "Choose a password for the Harmony database.\nThis password is used by all internal services.\n\nLeave blank for default (webmodul).\nSuggested strong password: $suggested") || true

    if [ -z "$pass1" ]; then
      ADMIN_PASSWORD=""
      return
    fi

    if [ ${#pass1} -lt 6 ]; then
      tui_msgbox "Password Too Short" "Password must be at least 6 characters."
      continue
    fi

    pass2=$(tui_passwordbox "Confirm Password" \
      "Re-enter the password to confirm:") || true

    if [ "$pass1" != "$pass2" ]; then
      tui_msgbox "Password Mismatch" "Passwords do not match. Please try again."
      continue
    fi

    if [ ${#pass1} -lt 8 ]; then
      if ! tui_yesno "Weak Password" \
        "Password is shorter than 8 characters.\n\nContinue with this password anyway?"; then
        continue
      fi
    fi

    ADMIN_PASSWORD="$pass1"
    break
  done
}

validate_port() {
  local port="$1" label="$2"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    tui_msgbox "Invalid Port" "$label must be a number between 1 and 65535."
    return 1
  fi
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    if ! tui_yesno "Port In Use" \
      "Port $port is currently in use by another process.\n\nContinue anyway? (The other process may need to be stopped.)"; then
      return 1
    fi
  fi
  return 0
}

collect_ports() {
  [ "$NON_INTERACTIVE" -eq 1 ] && return

  while true; do
    local result
    result=$(tui_inputbox "Landing Page Port" \
      "Port for the landing page (main menu):" \
      "$LANDING_PORT") || true
    [ -n "$result" ] && LANDING_PORT="$result"
    validate_port "$LANDING_PORT" "Landing port" && break
  done

  while true; do
    local result
    result=$(tui_inputbox "Administration Port" \
      "Port for the Administration dashboard:" \
      "$ADMIN_PORT") || true
    [ -n "$result" ] && ADMIN_PORT="$result"
    if [ "$ADMIN_PORT" = "$LANDING_PORT" ]; then
      tui_msgbox "Duplicate Port" "Administration port must differ from the landing port ($LANDING_PORT)."
      continue
    fi
    validate_port "$ADMIN_PORT" "Administration port" && break
  done

  while true; do
    local result
    result=$(tui_inputbox "Reception Port" \
      "Port for the Reception dashboard:" \
      "$RECEPTION_PORT") || true
    [ -n "$result" ] && RECEPTION_PORT="$result"
    if [ "$RECEPTION_PORT" = "$LANDING_PORT" ] || [ "$RECEPTION_PORT" = "$ADMIN_PORT" ]; then
      tui_msgbox "Duplicate Port" "Reception port must differ from landing ($LANDING_PORT) and admin ($ADMIN_PORT)."
      continue
    fi
    validate_port "$RECEPTION_PORT" "Reception port" && break
  done
}

collect_version() {
  if [ -n "$SELECTED_VERSION" ]; then
    return
  fi

  if [ -n "$TARBALL_PATH" ]; then
    SELECTED_VERSION="local"
    return
  fi

  log_info "Fetching available versions from GitHub..."
  local releases
  releases=$(curl -sfL --max-time 10 "${GITHUB_API}?per_page=10" 2>/dev/null \
    | grep -oP '"tag_name":\s*"\K[^"]+' \
    | sed 's/^v//' \
    | head -10) || true

  if [ -z "$releases" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      die "Cannot fetch releases from GitHub and no --version specified."
    fi
    tui_msgbox "GitHub Unreachable" \
      "Cannot fetch release list from GitHub.\n\nUse --tarball for offline install,\nor --version to specify a version directly."
    die "Cannot fetch release list from GitHub."
  fi

  local latest
  latest=$(echo "$releases" | head -1)

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    SELECTED_VERSION="$latest"
    return
  fi

  local menu_args=()
  local first=1
  while IFS= read -r ver; do
    if [ $first -eq 1 ]; then
      menu_args+=("$ver" "(latest)")
      first=0
    else
      menu_args+=("$ver" "")
    fi
  done <<< "$releases"

  local selected
  selected=$(tui_menu "Version Selection" \
    "Select the Harmony version to install:" \
    "${menu_args[@]}") || true

  SELECTED_VERSION="${selected:-$latest}"
}

show_confirmation_summary() {
  [ "$NON_INTERACTIVE" -eq 1 ] && return 0

  local pw_display="webmodul (default)"
  [ -n "$ADMIN_PASSWORD" ] && pw_display="******** (custom)"

  local summary
  summary=$(cat <<EOF
  Hotel name:         $HOTEL_NAME
  Version:            $SELECTED_VERSION
  Install path:       $INSTALL_DIR

  Network interface:  ${NET_INTERFACE:-auto}
  Server IP:          $SERVER_IP

  Landing page:       http://${SERVER_IP}:${LANDING_PORT}/
  Administration:     http://${SERVER_IP}:${ADMIN_PORT}/
  Reception:          http://${SERVER_IP}:${RECEPTION_PORT}/

  DB password:        $pw_display

Proceed with installation?
EOF
  )

  if ! tui_yesno "Installation Summary" "$summary"; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Section 7: Download & extract
# ---------------------------------------------------------------------------

download_tarball() {
  if [ -n "$TARBALL_PATH" ]; then
    if [ ! -f "$TARBALL_PATH" ]; then
      die "Tarball not found: $TARBALL_PATH"
    fi
    log_info "Using local tarball: $TARBALL_PATH"
    return
  fi

  local tag="v${SELECTED_VERSION}"
  local url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/harmony-${SELECTED_VERSION}.tar.gz"
  local checksum_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/SHA256SUMS"
  TARBALL_PATH="/tmp/harmony-${SELECTED_VERSION}.tar.gz"

  log_info "Downloading Harmony ${SELECTED_VERSION}..."

  if [ "$TUI_MODE" = "tui" ]; then
    curl -fL -o "${TARBALL_PATH}.tmp" "$url" 2>&1 | \
      stdbuf -oL tr '\r' '\n' | \
      grep -oP '[0-9]+(?=\.[0-9]%)' | \
      tail -1 | \
      while read -r pct; do echo "$pct"; done | \
      $TUI_CMD --title "Downloading Harmony ${SELECTED_VERSION}" \
        --gauge "Downloading harmony-${SELECTED_VERSION}.tar.gz..." 8 70 0 || true

    if [ ! -f "${TARBALL_PATH}.tmp" ] || [ ! -s "${TARBALL_PATH}.tmp" ]; then
      curl -fL --progress-bar -o "${TARBALL_PATH}.tmp" "$url" >>"$LOG_FILE" 2>&1 || \
        die "Download failed. Check your internet connection.\n\nURL: $url"
    fi
  else
    curl -fL --progress-bar -o "${TARBALL_PATH}.tmp" "$url" 2>&1 || \
      die "Download failed. Check your internet connection.\n\nURL: $url"
  fi

  mv "${TARBALL_PATH}.tmp" "$TARBALL_PATH"

  local expected actual
  expected=$(curl -sfL --max-time 10 "$checksum_url" 2>/dev/null | awk '{print $1}') || true
  if [ -n "$expected" ]; then
    actual=$(sha256sum "$TARBALL_PATH" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
      rm -f "$TARBALL_PATH"
      die "Checksum verification failed.\nExpected: $expected\nActual:   $actual"
    fi
    log_info "Checksum verified."
  else
    log_warn "Could not download checksum file; skipping verification."
  fi
}

extract_tarball() {
  log_info "Extracting to $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"
  tar xzf "$TARBALL_PATH" -C "$INSTALL_DIR" --strip-components=1
  TARBALL_EXTRACTED=1
  log_info "Extraction complete."
}

# ---------------------------------------------------------------------------
# Section 8: Configuration generation
# ---------------------------------------------------------------------------

generate_env() {
  log_info "Generating configuration..."

  local password="${ADMIN_PASSWORD:-webmodul}"

  umask 077
  cat > "${INSTALL_DIR}/.env" <<EOF
# iNELS Harmony — generated by installer on $(date '+%Y-%m-%d %H:%M:%S')
HARMONY_DB_PASSWORD=${password}
DB_USER=webmodul
DB_NAME=hrs
MARIADB_ROOT_PASSWORD=${password}
DB_PASSWORD=${password}

HARMONY_APP_VERSION=${SELECTED_VERSION}

ADMIN_PORT=${ADMIN_PORT}
RECEPTION_PORT=${RECEPTION_PORT}

PATCH_GIT_REPO=https://github.com/${GITHUB_OWNER}/harmony.git
PATCH_GIT_BRANCH=main
GITHUB_TOKEN=

MQTT_HOST=hrs-mosquitto
EOF
  umask 022

  if [ "$LANDING_PORT" != "80" ]; then
    sed -i "s/listen 80;/listen ${LANDING_PORT};/" "${INSTALL_DIR}/nginx/landing.conf" 2>/dev/null || true
  fi
  if [ "$ADMIN_PORT" != "81" ]; then
    sed -i "s/listen 81;/listen ${ADMIN_PORT};/" "${INSTALL_DIR}/nginx/admin.conf" 2>/dev/null || true
  fi
  if [ "$RECEPTION_PORT" != "82" ]; then
    sed -i "s/listen 82;/listen ${RECEPTION_PORT};/" "${INSTALL_DIR}/nginx/reception.conf" 2>/dev/null || true
  fi

  if [ -f "${INSTALL_DIR}/nginx/html/index.html" ]; then
    sed -i \
      -e "s/:81/:${ADMIN_PORT}/g" \
      -e "s/:82/:${RECEPTION_PORT}/g" \
      "${INSTALL_DIR}/nginx/html/index.html" 2>/dev/null || true
  fi

  log_info "Configuration written to ${INSTALL_DIR}/.env"
}

# ---------------------------------------------------------------------------
# Section 9: Service orchestration
# ---------------------------------------------------------------------------

start_services() {
  log_info "Starting Harmony services..."
  INSTALL_STARTED=1

  cd "$INSTALL_DIR"

  # Source db-defaults for any env resolution
  if [ -f "${INSTALL_DIR}/scripts/db-defaults.sh" ]; then
    # shellcheck source=/dev/null
    . "${INSTALL_DIR}/scripts/db-defaults.sh"
    harmony_db_load_dotenv "${INSTALL_DIR}/.env"
    harmony_db_export_env
  fi

  if [ "$TUI_MODE" = "tui" ]; then
    (
      echo 5
      echo "XXX"
      echo "Pulling base images..."
      echo "XXX"
      docker compose pull --ignore-pull-failures >>"$LOG_FILE" 2>&1 || true
      echo 20
      echo "XXX"
      echo "Building containers (this may take a few minutes)..."
      echo "XXX"
      docker compose build >>"$LOG_FILE" 2>&1 || true
      echo 60
      echo "XXX"
      echo "Starting containers..."
      echo "XXX"
      sudo -E docker compose up -d --remove-orphans >>"$LOG_FILE" 2>&1
      echo 70
      echo "XXX"
      echo "Waiting for MariaDB to be healthy..."
      echo "XXX"
    ) | $TUI_CMD --title "Starting Harmony Services" --gauge "Preparing..." 8 70 0
  else
    echo "  Pulling base images..."
    docker compose pull --ignore-pull-failures >>"$LOG_FILE" 2>&1 || true
    echo "  Building containers (this may take a few minutes)..."
    docker compose build >>"$LOG_FILE" 2>&1 || true
    echo "  Starting containers..."
    sudo -E docker compose up -d --remove-orphans >>"$LOG_FILE" 2>&1
  fi

  CONTAINERS_STARTED=1

  wait_for_healthy

  # Drivers (BUS + eLAN) run inside the app container from the prebuilt
  # binaries in the release tree (start_all.sh) — no separate driver build.

  # Apply SQL schema (same logic as install.sh)
  if docker compose exec -T hrs-mariadb test -f /docker-entrypoint-initdb.d/01-bootstrap.sh 2>/dev/null; then
    log_info "Applying SQL schema..."
    docker compose exec -T hrs-mariadb bash /docker-entrypoint-initdb.d/01-bootstrap.sh >>"$LOG_FILE" 2>&1 || true
    for webdir in WEB_Automation WEB_Devices WEB_Rooms WEB_Zones WEB_Users WEB_Settings WEB_Readers WEB_Gateways; do
      docker compose exec -T hrs-mariadb bash -c \
        "for f in /docker-entrypoint-initdb.d/sql/${webdir}/*.sql; do [ -f \"\$f\" ] && mariadb -u root -p\"\$MARIADB_ROOT_PASSWORD\" \"\$MARIADB_DATABASE\" < \"\$f\" || true; done" \
        >>"$LOG_FILE" 2>&1 || true
    done
  fi

  # Start Python apps
  log_info "Starting application processes..."
  docker compose exec -T hrs-app /opt/hrs-container/scripts/restart-apps.sh >>"$LOG_FILE" 2>&1 || true

  log_info "All services started."
}

wait_for_healthy() {
  log_info "Waiting for services to be healthy..."
  local timeout=120
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' hrs-mariadb 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
      log_info "MariaDB is healthy."
      break
    fi

    if [ "$TUI_MODE" = "tui" ]; then
      local pct=$(( 70 + (elapsed * 25 / timeout) ))
      echo "$pct" | $TUI_CMD --title "Starting Harmony Services" \
        --gauge "Waiting for MariaDB... (${elapsed}s / ${timeout}s)" 8 70 "$pct" || true
    else
      printf '\r  Waiting for MariaDB... %ds / %ds' "$elapsed" "$timeout"
    fi

    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  [ "$TUI_MODE" = "plain" ] && echo ""

  if [ $elapsed -ge $timeout ]; then
    log_warn "MariaDB health check timed out after ${timeout}s. Continuing anyway..."
  fi

  # Quick check that nginx is responding
  local nginx_ok=0
  for i in $(seq 1 12); do
    if curl -sf --max-time 2 "http://127.0.0.1:${ADMIN_PORT}/" >/dev/null 2>&1; then
      nginx_ok=1
      break
    fi
    sleep 5
  done

  if [ $nginx_ok -eq 1 ]; then
    log_info "Nginx is responding on port ${ADMIN_PORT}."
  else
    log_warn "Nginx not yet responding on port ${ADMIN_PORT}. It may need more time to start."
  fi
}

# ---------------------------------------------------------------------------
# Section 10: Post-install
# ---------------------------------------------------------------------------

post_install() {
  cd "$INSTALL_DIR"

  # Apply firewall rules
  if [ -x "${INSTALL_DIR}/scripts/lan-firewall.sh" ]; then
    log_info "Applying LAN firewall rules..."
    "${INSTALL_DIR}/scripts/lan-firewall.sh" >>"$LOG_FILE" 2>&1 || true
  fi

  # Install systemd service
  if [ -d "${INSTALL_DIR}/systemd" ] && check_command systemctl; then
    log_info "Installing systemd service..."
    cp "${INSTALL_DIR}/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    for svc in "${INSTALL_DIR}/systemd/"*.service; do
      local svc_name
      svc_name=$(basename "$svc")
      systemctl enable "$svc_name" 2>/dev/null || true
      systemctl start "$svc_name" 2>/dev/null || true
    done
  fi

  # Set hotel name in database
  local password="${ADMIN_PASSWORD:-webmodul}"
  local max_retries=6
  local i=0
  while [ $i -lt $max_retries ]; do
    if docker compose exec -T hrs-mariadb mariadb -u root -p"${password}" hrs \
      -e "UPDATE config SET value='${HOTEL_NAME}' WHERE key_name='hotel_name';" >>"$LOG_FILE" 2>&1; then
      log_info "Hotel name set to: $HOTEL_NAME"
      break
    fi
    i=$(( i + 1 ))
    sleep 5
  done

  # Write install metadata
  mkdir -p "$METADATA_DIR"
  local docker_ver
  docker_ver=$(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  # shellcheck source=/dev/null
  . /etc/os-release 2>/dev/null || true
  cat > "${METADATA_DIR}/metadata.json" <<EOF
{
  "hotel_name": "${HOTEL_NAME}",
  "version": "${SELECTED_VERSION}",
  "installed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "installer_version": "${INSTALLER_VERSION}",
  "network_interface": "${NET_INTERFACE}",
  "server_ip": "${SERVER_IP}",
  "ports": {
    "landing": ${LANDING_PORT},
    "admin": ${ADMIN_PORT},
    "reception": ${RECEPTION_PORT}
  },
  "os": "${PRETTY_NAME:-${ID:-unknown}}",
  "docker_version": "${docker_ver}"
}
EOF
  log_info "Install metadata written to ${METADATA_DIR}/metadata.json"
}

# ---------------------------------------------------------------------------
# Section 10b: Harmony Cloud Portal registration & heartbeat agent
# ---------------------------------------------------------------------------

register_with_portal() {
  if [ "$SKIP_PORTAL" -eq 1 ]; then
    log_info "Portal registration skipped (--skip-portal)."
    return
  fi
  if [ -z "$REGISTRATION_TOKEN" ]; then
    log_info "No registration token provided — skipping portal registration."
    log_info "Register later: ${INSTALL_DIR}/portal-agent/register-portal.sh --registration-token <TOKEN>"
    return
  fi

  log_info "Registering with Harmony Cloud Portal at ${PORTAL_URL}..."
  . /etc/os-release 2>/dev/null || true
  local docker_ver
  docker_ver=$(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

  local payload
  payload=$(cat <<JSON
{
  "hotel_name": "${HOTEL_NAME}",
  "version": "${SELECTED_VERSION}",
  "server_ip": "${SERVER_IP}",
  "os": "${PRETTY_NAME:-${ID:-unknown}}",
  "docker_version": "${docker_ver}",
  "ports": {"landing": ${LANDING_PORT}, "admin": ${ADMIN_PORT}, "reception": ${RECEPTION_PORT}}
}
JSON
  )

  local response http_code body api_key
  response=$(curl -sS -w '\n%{http_code}' \
    -X POST "${PORTAL_URL%/}/api/v1/register" \
    -H "Content-Type: application/json" \
    -H "X-Harmony-Registration-Token: ${REGISTRATION_TOKEN}" \
    --data "$payload" 2>>"$LOG_FILE") || {
      log_warn "Could not reach the portal. Harmony is installed and running; registration can be retried later."
      return
    }
  http_code=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')

  if [ "$http_code" != "200" ]; then
    log_warn "Portal registration failed (HTTP ${http_code}). Harmony is running; you can retry registration later."
    log_warn "Response: ${body}"
    return
  fi

  api_key=$(printf '%s' "$body" | grep -oE '"api_key"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"api_key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  if [ -z "$api_key" ]; then
    log_warn "Portal response did not contain an API key. Skipping heartbeat setup."
    return
  fi

  mkdir -p "$METADATA_DIR"
  cat > "${METADATA_DIR}/portal.json" <<JSON
{
  "portal_url": "${PORTAL_URL%/}",
  "api_key": "${api_key}",
  "auto_update": ${AUTO_UPDATE},
  "registered_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
  chmod 600 "${METADATA_DIR}/portal.json"
  PORTAL_REGISTERED=1
  log_info "Registered with portal. Credentials saved to ${METADATA_DIR}/portal.json"

  # Expose portal creds to the app container (for in-app license activation).
  if [ -f "${INSTALL_DIR}/.env" ]; then
    sed -i '/^PORTAL_URL=/d;/^PORTAL_HRS_API_KEY=/d' "${INSTALL_DIR}/.env" 2>/dev/null || true
    {
      echo "PORTAL_URL=${PORTAL_URL%/}"
      echo "PORTAL_HRS_API_KEY=${api_key}"
    } >> "${INSTALL_DIR}/.env"
    ( cd "$INSTALL_DIR" && docker compose up -d hrs-app >>"$LOG_FILE" 2>&1 ) || true
  fi

  apply_portal_license "$body"
  install_heartbeat_agent
}

# Apply the license returned in the registration response into the app's
# config table, so a portal-first install boots already licensed.
apply_portal_license() {
  local body="$1"
  local lic_key lic_name max_gw
  lic_key=$(printf '%s' "$body" | grep -oE '"license_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')
  lic_name=$(printf '%s' "$body" | grep -oE '"tier_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')
  max_gw=$(printf '%s' "$body" | grep -oE '"max_gateways"[[:space:]]*:[[:space:]]*(null|[0-9]+)' | head -1 | sed -E 's/.*:[[:space:]]*//')

  if [ -z "$lic_key" ] || [ -z "$lic_name" ]; then
    log_info "No license assigned to this project yet — server is UNLICENSED until activated."
    return
  fi
  [ "$max_gw" = "null" ] && max_gw="no limit"

  local password="${ADMIN_PASSWORD:-webmodul}"
  local sql="UPDATE config SET license_key='${lic_key}', license_name='${lic_name}', max_gateways='${max_gw}', max_rooms='no limit', license_valid_from=NOW(), license_valid_to='no limit time' WHERE ID>0;"
  if docker compose exec -T hrs-mariadb mariadb -u root -p"${password}" hrs -e "$sql" >>"$LOG_FILE" 2>&1; then
    log_info "License activated: ${lic_name} (${max_gw} gateways)."
  else
    log_warn "Could not write license to the database; activate it later from Administration > Licensing."
  fi
}

install_heartbeat_agent() {
  local agent_src="${INSTALL_DIR}/portal-agent"
  if [ ! -f "${agent_src}/harmony-heartbeat.py" ]; then
    log_warn "Heartbeat agent not found in package (${agent_src}); skipping timer setup."
    return
  fi

  cp "${agent_src}/harmony-heartbeat.py" "${METADATA_DIR}/harmony-heartbeat.py"
  chmod +x "${METADATA_DIR}/harmony-heartbeat.py"

  if check_command systemctl; then
    cp "${agent_src}/harmony-heartbeat.service" /etc/systemd/system/ 2>/dev/null || true
    cp "${agent_src}/harmony-heartbeat.timer" /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now harmony-heartbeat.timer 2>/dev/null || true
    # Fire one heartbeat immediately so the portal shows the hotel online.
    systemctl start harmony-heartbeat.service 2>/dev/null || true
    log_info "Heartbeat timer installed (every 15 min)."
  else
    log_warn "systemd not available — heartbeat agent installed but not scheduled."
  fi
}

# ---------------------------------------------------------------------------
# Section 11: Success screen
# ---------------------------------------------------------------------------

show_success() {
  local pw_display="webmodul"
  [ -n "$ADMIN_PASSWORD" ] && pw_display="(as configured)"

  local portal_status="not registered (run with --registration-token to enable)"
  [ "$SKIP_PORTAL" -eq 1 ] && portal_status="skipped"
  [ "$PORTAL_REGISTERED" -eq 1 ] && portal_status="registered, heartbeat every 15 min"

  local message
  message=$(cat <<EOF
Harmony ${SELECTED_VERSION} is running.

  Landing page:      http://${SERVER_IP}:${LANDING_PORT}/
  Administration:    http://${SERVER_IP}:${ADMIN_PORT}/
  Reception:         http://${SERVER_IP}:${RECEPTION_PORT}/

  Hotel name:        ${HOTEL_NAME}
  Database user:     webmodul
  Database password: ${pw_display}

Next steps:
  1. Open Administration and configure the hotel
  2. Add automation gateways when hardware is ready
  3. For updates: Administration > Settings > Firmware

  Cloud Portal:      ${portal_status}

Logs:  cd ${INSTALL_DIR} && docker compose logs -f
Log file: ${LOG_FILE}
EOF
  )

  tui_msgbox "Installation Complete!" "$message"
  log_info "Installation complete. Harmony ${SELECTED_VERSION} running at http://${SERVER_IP}:${ADMIN_PORT}/"
}

# ---------------------------------------------------------------------------
# Section 12: Main flow & CLI argument parsing
# ---------------------------------------------------------------------------

show_welcome() {
  tui_msgbox "iNELS Harmony — Hotel Automation" \
    "Welcome to the Harmony installer (v${INSTALLER_VERSION}).\n\nThis will install the Harmony hotel automation platform on this server.\n\nThe installer will:\n  - Install Docker if needed\n  - Download the latest Harmony release\n  - Configure and start all services\n\nPress OK to continue."
}

detect_existing_install() {
  if [ ! -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    return
  fi

  HAD_EXISTING_INSTALL=1
  local current_ver
  current_ver=$(cat "${INSTALL_DIR}/VERSION.txt" 2>/dev/null || echo "unknown")

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    die "Existing Harmony installation found (v${current_ver}) at ${INSTALL_DIR}.\nUse upgrade.sh for upgrades, or remove the directory first."
  fi

  if tui_yesno "Existing Installation Detected" \
    "Harmony v${current_ver} is already installed at\n${INSTALL_DIR}\n\nWould you like to upgrade to the latest version?\nYour database and hotel data will be preserved.\n\nSelect Yes to upgrade, No to abort."; then

    collect_version
    download_tarball

    log_info "Delegating to upgrade.sh..."
    if [ -x "${INSTALL_DIR}/upgrade.sh" ]; then
      exec "${INSTALL_DIR}/upgrade.sh" "$TARBALL_PATH"
    else
      die "upgrade.sh not found at ${INSTALL_DIR}/upgrade.sh"
    fi
  else
    echo "Installation aborted."
    exit 0
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)        SELECTED_VERSION="$2"; shift 2 ;;
      --tarball)        TARBALL_PATH="$2"; shift 2 ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --hotel-name)     HOTEL_NAME="$2"; shift 2 ;;
      --password)       ADMIN_PASSWORD="$2"; shift 2 ;;
      --interface)      NET_INTERFACE="$2"; shift 2 ;;
      --landing-port)   LANDING_PORT="$2"; shift 2 ;;
      --admin-port)     ADMIN_PORT="$2"; shift 2 ;;
      --reception-port) RECEPTION_PORT="$2"; shift 2 ;;
      --portal-url)         PORTAL_URL="$2"; shift 2 ;;
      --registration-token) REGISTRATION_TOKEN="$2"; shift 2 ;;
      --skip-portal)        SKIP_PORTAL=1; shift ;;
      --auto-update)        AUTO_UPDATE="true"; shift ;;
      --help|-h)
        head -14 "$0" 2>/dev/null | tail -12 || true
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  log_info "Harmony installer v${INSTALLER_VERSION} started."

  parse_args "$@"
  preflight_checks
  tui_init

  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    show_welcome
  fi

  detect_existing_install
  ensure_docker

  # Collect user input (loops back on "No" at confirmation)
  while true; do
    collect_network_interface
    collect_hotel_name
    collect_admin_password
    collect_ports
    collect_version
    if show_confirmation_summary; then
      break
    fi
  done

  download_tarball
  extract_tarball
  generate_env
  start_services
  post_install
  register_with_portal
  show_success
}

main "$@"
