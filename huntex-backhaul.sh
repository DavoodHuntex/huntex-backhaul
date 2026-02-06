#!/usr/bin/env bash
# Huntex Backhaul Panel
# A minimal, operator-friendly TUI to install Backhaul core, generate configs, and manage systemd instances.
#
# Special thanks to:
# Backhaul project developers
# for creating an efficient and powerful reverse tunnel core.
#
# GitHub:    https://github.com/DavoodHuntex/huntex-backhaul
# Developer: @BiG_BanG
#
# Notes:
# - Designed for ANSI 256-color terminals (stable across most terminals).
# - Uses systemd template: /etc/systemd/system/backhaul@.service
# - Config naming:
#     Client (Kharej): conf_<ip>_<port>.toml
#     Server (IRAN):  conf_iran_<port>.toml
#
# Safety:
# - This script should be run as root.
# - Uses GitHub API to fetch latest official core release.

set -Eeuo pipefail

# ---------------------------
# Theme (ANSI 256 colors)
# ---------------------------
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_TITLE=$'\033[38;5;178m'   # mustard/gold
C_LINE=$'\033[38;5;39m'     # cyan-ish line
C_GRAY=$'\033[38;5;252m'    # true light gray (avoid pink tint)
C_DIM=$'\033[38;5;245m'
C_OK=$'\033[38;5;82m'       # green
C_BAD=$'\033[38;5;196m'     # red
C_WARN=$'\033[38;5;214m'    # amber

APP_NAME="Huntex Backhaul Panel"
APP_VER="v0.1.0"

# Official Backhaul repo for core releases
GITHUB_CORE_REPO="Musixal/Backhaul"

INSTALL_DIR="/root/backhaul"
BIN_PATH="${INSTALL_DIR}/backhaul"
LOG_JSON="/root/log.json"

SYSTEMD_TEMPLATE="/etc/systemd/system/backhaul@.service"

# ---------------------------
# Utilities
# ---------------------------
die() { echo -e "${C_BAD}${C_BOLD}ERROR:${C_RESET} ${C_GRAY}$*${C_RESET}" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
ensure_dir() { mkdir -p "$1"; }

hr() { echo -e "${C_LINE}====================================================${C_RESET}"; }

# Strong clear: works better than `clear` in many terminals
clear_screen() { printf '\033[2J\033[H' || true; }
# Alias with user's typo request
clear_screan() { clear_screen; }

pause() { echo; read -r -p "$(echo -e "${C_GRAY}Press Enter to continue...${C_RESET}")" _; }

require_tools() {
  has_cmd curl || die "curl is required."
  has_cmd systemctl || die "systemd (systemctl) is required."
  has_cmd journalctl || die "journalctl is required."
  has_cmd uname || die "uname is required."
  has_cmd file || die "file is required."
  has_cmd install || die "install is required."
  # Optional but recommended
  has_cmd gzip || true
}

# Spinner (small + safe)
_spinner_run() {
  local pid="$1" msg="$2" i=0
  local frames=('|' '/' '-' '\')
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${C_DIM}%s... %s${C_RESET}" "$msg" "${frames[i%4]}"
    i=$((i+1))
    sleep 0.12
  done
  printf "\r${C_DIM}%s... done${C_RESET}\n" "$msg"
}

# ---------------------------
# Core detection / version
# ---------------------------
core_installed() { [[ -x "$BIN_PATH" ]]; }

core_version_str() {
  if core_installed; then
    local out
    out="$("$BIN_PATH" -v 2>/dev/null || true)"
    [[ -n "$out" ]] && echo "$out" && return 0
    out="$("$BIN_PATH" version 2>/dev/null || true)"
    [[ -n "$out" ]] && echo "$out" && return 0
    echo "installed"
  else
    echo "not installed"
  fi
}

# ---------------------------
# GitHub latest release helpers
# ---------------------------
github_latest_json() {
  curl -fsSL "https://api.github.com/repos/${GITHUB_CORE_REPO}/releases/latest"
}

github_latest_tag() {
  github_latest_json | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n1
}

_os_arch() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7" ;;
  esac
  echo "${os}_${arch}"
}

github_pick_asset_url() {
  # Pick linux/<arch> tar.gz asset from latest release JSON (Musixal/Backhaul).
  local arch_kw
  arch_kw="$(uname -m)"
  case "$arch_kw" in
    x86_64|amd64) arch_kw="amd64" ;;
    aarch64|arm64) arch_kw="arm64" ;;
    armv7l|armv7) arch_kw="armv7" ;;
    *) echo "Unsupported arch: $arch_kw" >&2; return 1 ;;
  esac

  github_latest_json \
    | grep -oE "\"browser_download_url\":[[:space:]]*\"[^\"]+\"" \
    | sed -E "s/.*\"(https:[^\"]+)\"/\1/" \
    | grep -E "backhaul_linux_${arch_kw}\.tar\.gz$" \
    | head -n1
}
_install_binary_from_download() {
  # Handles raw binary OR gzip-compressed binary OR tar.gz (best-effort)
  local tmp="$1"
  local ftype
  ftype="$(file -b "$tmp" || true)"

  ensure_dir "$INSTALL_DIR"

  if echo "$ftype" | grep -qi 'gzip compressed'; then
    has_cmd gzip || die "gzip is required to install this release (gzip file detected)."
    # Most common: gzip of the binary itself
    if gzip -t "$tmp" 2>/dev/null; then
      gzip -dc "$tmp" > "${BIN_PATH}.new"
      install -m 0755 "${BIN_PATH}.new" "$BIN_PATH"
      rm -f "${BIN_PATH}.new"
      return 0
    fi
    die "Downloaded gzip file is not valid."
  fi

  # If it's a tar archive, try extracting backhaul from it
  if echo "$ftype" | grep -qi 'tar archive'; then
    has_cmd tar || die "tar is required to install this release (tar detected)."
    local d
    d="$(mktemp -d -t backhaul.XXXXXX)"
    tar -xf "$tmp" -C "$d"
    if [[ -f "$d/backhaul" ]]; then
      install -m 0755 "$d/backhaul" "$BIN_PATH"
      rm -rf "$d"
      return 0
    fi
    # try search
    local found
    found="$(find "$d" -maxdepth 2 -type f -name 'backhaul' | head -n1 || true)"
    if [[ -n "$found" ]]; then
      install -m 0755 "$found" "$BIN_PATH"
      rm -rf "$d"
      return 0
    fi
    rm -rf "$d"
    die "Could not find 'backhaul' inside tar archive."
  fi

  # Otherwise assume it's a raw binary
  install -m 0755 "$tmp" "$BIN_PATH"
}

download_and_install_core() {
  ensure_dir "$INSTALL_DIR"

  echo -e "${C_GRAY}Resolving latest official GitHub release...${C_RESET}"
  local tag url tmp work found

  tag="$(github_latest_tag || true)"
  [[ -n "$tag" ]] || die "Failed to resolve latest release tag."

  url="$(github_pick_asset_url || true)"
  [[ -n "$url" ]] || die "Failed to find linux tar.gz asset for this CPU arch."

  tmp="$(mktemp -t backhaul.XXXXXX.tar.gz)"
  work="$(mktemp -d -t backhaul.XXXXXX)"

  echo -e "${C_GRAY}Downloading core (${C_TITLE}${tag}${C_GRAY})...${C_RESET}"
  curl -fL "$url" -o "$tmp"

  echo -e "${C_GRAY}Extracting and installing to ${BIN_PATH}...${C_RESET}"
  tar -xzf "$tmp" -C "$work"

  found="$(find "$work" -type f -name backhaul | head -n1 || true)"
  [[ -n "$found" ]] || { rm -rf "$work" "$tmp"; die "backhaul binary not found inside tar archive"; }

  install -m 0755 "$found" "$BIN_PATH"
  rm -rf "$work" "$tmp"

  if has_cmd file; then
    local ft
    ft="$(file -b "$BIN_PATH" 2>/dev/null || true)"
    echo -e "${C_GRAY}file:${C_RESET} ${C_GRAY}${ft}${C_RESET}"
    echo "$ft" | grep -qi "ELF" || die "Installed file is not an ELF executable (bad download/extract)."
  fi

  echo -e "${C_OK}${C_BOLD}Installed:${C_RESET} ${C_GRAY}${BIN_PATH}${C_RESET}"
  echo -e "${C_GRAY}Core version:${C_RESET} ${C_TITLE}$(core_version_str)${C_RESET}"
}
remove_core() {
  if core_installed; then
    rm -f "$BIN_PATH"
    echo -e "${C_OK}${C_BOLD}Removed:${C_RESET} ${C_GRAY}${BIN_PATH}${C_RESET}"
  else
    echo -e "${C_WARN}${C_BOLD}Notice:${C_RESET} ${C_GRAY}Core is not installed.${C_RESET}"
  fi
}

# ---------------------------
# systemd template
# ---------------------------
ensure_systemd_template() {
  if [[ -f "$SYSTEMD_TEMPLATE" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  cat > "$SYSTEMD_TEMPLATE" <<'EOF'
[Unit]
Description=Backhaul (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/backhaul
ExecStart=/root/backhaul/backhaul -c /root/backhaul/%i.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

unit_name_from_instance() {
  local inst="$1"
  echo "backhaul@${inst}.service"
}

is_enabled() { systemctl is-enabled "$1" 2>/dev/null || echo "disabled"; }
is_active()  { systemctl is-active  "$1" 2>/dev/null || echo "inactive"; }

# ---------------------------
# Config discovery
# ---------------------------
list_conf_files() {
  find "/root/backhaul" -maxdepth 1 -type f -name "conf_*.toml" -print 2>/dev/null | sort
}

conf_to_instance() {
  basename "$1" .toml
}

# ---------------------------
# Status summary
# ---------------------------
status_summary() {
  ensure_dir "$INSTALL_DIR"
  local files=() f inst unit a e
  mapfile -t files < <(list_conf_files)

  local total=${#files[@]}
  local active=0 inactive=0 failed=0 changing=0
  local enabled=0 disabled=0 other_enabled=0

  for f in "${files[@]}"; do
    inst="$(conf_to_instance "$f")"
    unit="$(unit_name_from_instance "$inst")"

    a="$(is_active "$unit")"
    e="$(is_enabled "$unit")"

    case "$a" in
      active) ((active++)) ;;
      inactive) ((inactive++)) ;;
      failed) ((failed++)) ;;
      activating|deactivating) ((changing++)) ;;
      *) ((inactive++)) ;;
    esac

    case "$e" in
      enabled) ((enabled++)) ;;
      disabled) ((disabled++)) ;;
      *) ((other_enabled++)) ;;
    esac
  done

  echo "${total}|${active}|${inactive}|${failed}|${changing}|${enabled}|${disabled}|${other_enabled}"
}

# ---------------------------
# Input helpers
# ---------------------------
read_nonempty() {
  local prompt="$1" var
  while true; do
    read -r -p "$(echo -e "${C_GRAY}${prompt}${C_RESET}")" var
    [[ -n "$var" ]] && { echo "$var"; return 0; }
  done
}

read_int_default() {
  local prompt="$1" def="$2" v
  read -r -p "$(echo -e "${C_GRAY}${prompt} (default: ${def})${C_RESET} ")" v
  if [[ -z "$v" ]]; then
    echo "$def"; return 0
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || die "Invalid number."
  echo "$v"
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    ((o>=0 && o<=255)) || return 1
  done
  return 0
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  ((p>=1 && p<=65535)) || return 1
  return 0
}

# ---------------------------
# Config generation
# ---------------------------
write_client_conf() {
  local ip="$1" port="$2" token="$3" pool="$4"
  ensure_dir "$INSTALL_DIR"

  local name="conf_${ip}_${port}.toml"
  local path="${INSTALL_DIR}/${name}"

  cat > "$path" <<EOF
[client]
remote_addr = "${ip}:${port}"
transport = "tcpmux"
token = "${token}"
connection_pool = ${pool}
aggressive_pool = true
keepalive_period = 30
nodelay = true
retry_interval = 3
dial_timeout = 10
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
sniffer_log ="${LOG_JSON}"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 2097152
so_sndbuf = 4194304
EOF

  echo -e "${C_OK}${C_BOLD}Created:${C_RESET} ${C_GRAY}${path}${C_RESET}"
}

write_iran_conf() {
  local port="$1" token="$2"
  ensure_dir "$INSTALL_DIR"

  local name="conf_iran_${port}.toml"
  local path="${INSTALL_DIR}/${name}"

  cat > "$path" <<EOF
[server]
bind_addr = "0.0.0.0:${port}"
transport = "tcpmux"
accept_udp = false
token = "${token}"
keepalive_period = 75
nodelay = false
channel_size = 2048
heartbeat = 40
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
sniffer_log ="${LOG_JSON}"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 4194304
so_sndbuf = 2097152
EOF

  echo -e "${C_OK}${C_BOLD}Created:${C_RESET} ${C_GRAY}${path}${C_RESET}"
}

# ---------------------------
# Selection (FIXED)
# IMPORTANT: Menu/prints go to STDERR, only selected instance prints to STDOUT.
# ---------------------------
select_instance_from_list() {
  local files=() insts=() f inst
  mapfile -t files < <(list_conf_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo -e "${C_WARN}${C_BOLD}No configs found.${C_RESET} ${C_GRAY}Create configs first.${C_RESET}" >&2
    return 1
  fi

  echo >&2
  echo -e "${C_TITLE}${C_BOLD}Available configs:${C_RESET}" >&2
  echo -e "${C_GRAY}Select by number.${C_RESET}" >&2
  echo >&2

  local i=1
  for f in "${files[@]}"; do
    inst="$(conf_to_instance "$f")"
    insts+=("$inst")

    local unit a e
    unit="$(unit_name_from_instance "$inst")"
    a="$(is_active "$unit")"
    e="$(is_enabled "$unit")"

    local a_txt e_txt
    case "$a" in
      active) a_txt="${C_OK}${C_BOLD}ACTIVE${C_RESET}" ;;
      failed) a_txt="${C_BAD}${C_BOLD}FAILED${C_RESET}" ;;
      activating|deactivating) a_txt="${C_WARN}${C_BOLD}CHANGING${C_RESET}" ;;
      *) a_txt="${C_DIM}${C_BOLD}STOPPED${C_RESET}" ;;
    esac
    case "$e" in
      enabled) e_txt="${C_OK}enabled${C_RESET}" ;;
      disabled) e_txt="${C_WARN}disabled${C_RESET}" ;;
      *) e_txt="${C_WARN}${e}${C_RESET}" ;;
    esac

    echo -e "  ${C_TITLE}${i})${C_RESET} ${C_GRAY}${inst}${C_RESET}  ${C_GRAY}[${a_txt}${C_GRAY} | ${e_txt}${C_GRAY}]${C_RESET}" >&2
    ((i++))
  done

  echo >&2
  local pick
  read -r -p "$(echo -e "${C_GRAY}Select number (0 to cancel): ${C_RESET}")" pick >&2
  [[ "${pick:-}" =~ ^[0-9]+$ ]] || return 1
  ((pick==0)) && return 1
  ((pick>=1 && pick<=${#insts[@]})) || return 1

  # Only stdout output:
  echo "${insts[$((pick-1))]}"
}

# ---------------------------
# systemd actions
# ---------------------------
show_configs() {
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}Configs:${C_RESET} ${C_GRAY}(conf_*.toml)${C_RESET}"
  hr

  local files=()
  mapfile -t files < <(list_conf_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo -e "${C_WARN}${C_BOLD}No configs found.${C_RESET}"
    return 0
  fi

  local f
  for f in "${files[@]}"; do
    echo -e "${C_GRAY}- $(basename "$f")${C_RESET}"
  done
}

enable_start_instance() {
  ensure_systemd_template
  local inst unit
  inst="$(select_instance_from_list)" || return 0
  unit="$(unit_name_from_instance "$inst")"
  systemctl enable --now "$unit"
  echo -e "${C_OK}${C_BOLD}Enabled + Started:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
}

disable_stop_instance() {
  local inst unit
  inst="$(select_instance_from_list)" || return 0
  unit="$(unit_name_from_instance "$inst")"
  systemctl disable --now "$unit" 2>/dev/null || systemctl stop "$unit" 2>/dev/null || true
  echo -e "${C_OK}${C_BOLD}Disabled + Stopped:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
}

delete_config_instance() {
  local inst unit cfg
  inst="$(select_instance_from_list)" || return 0

  unit="$(unit_name_from_instance "$inst")"
  cfg="${INSTALL_DIR}/${inst}.toml"

  echo
  echo -e "${C_WARN}${C_BOLD}Warning:${C_RESET} ${C_GRAY}This will delete:${C_RESET} ${C_TITLE}${cfg}${C_RESET}"
  read -r -p "$(echo -e "${C_GRAY}Type 'yes' to confirm: ${C_RESET}")" ans
  [[ "${ans:-}" == "yes" ]] || { echo -e "${C_DIM}Canceled.${C_RESET}"; return 0; }

  # Stop/disable service if exists
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true

  # Remove config file
  if [[ -f "$cfg" ]]; then
    rm -f "$cfg"
    echo -e "${C_OK}${C_BOLD}Deleted:${C_RESET} ${C_GRAY}${cfg}${C_RESET}"
  else
    echo -e "${C_WARN}${C_BOLD}Notice:${C_RESET} ${C_GRAY}Config file not found: ${cfg}${C_RESET}"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
}

restart_instance() {
  local inst unit
  inst="$(select_instance_from_list)" || return 0
  unit="$(unit_name_from_instance "$inst")"

  # visual spinner for restart
  (systemctl restart "$unit") &
  local pid=$!
  _spinner_run "$pid" "Restarting ${unit}"
  wait "$pid" 2>/dev/null || true

  local a
  a="$(is_active "$unit")"
  if [[ "$a" == "active" ]]; then
    echo -e "${C_OK}${C_BOLD}Restarted:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
  else
    echo -e "${C_WARN}${C_BOLD}Restart attempted:${C_RESET} ${C_GRAY}${unit} (state: ${a})${C_RESET}"
  fi
}

view_logs_instance() {
  local inst unit
  inst="$(select_instance_from_list)" || return 0
  unit="$(unit_name_from_instance "$inst")"
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}Recent logs:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
  hr
  journalctl -u "$unit" -n 80 --no-pager || true
}

detailed_systemd_view() {
  local inst unit
  inst="$(select_instance_from_list)" || return 0
  unit="$(unit_name_from_instance "$inst")"
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}systemd status:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
  hr
  systemctl status "$unit" --no-pager -l || true
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}Recent logs:${C_RESET} ${C_GRAY}${unit}${C_RESET}"
  hr
  journalctl -u "$unit" -n 120 --no-pager || true
}

# ---------------------------
# Make command like x-ui: hx-bh
# ---------------------------
install_command_link() {
  local target="$0"
  # If run via bash <(curl ...), $0 might be "bash". In that case user must place script somewhere.
  if [[ ! -f "$target" ]] || [[ "$target" == "bash" ]]; then
    echo -e "${C_WARN}${C_BOLD}Notice:${C_RESET} ${C_GRAY}You are running via pipe. Save script to a file first (e.g. /opt/huntex-backhaul/huntex-backhaul.sh).${C_RESET}"
    echo -e "${C_GRAY}Then run: ln -sf /opt/huntex-backhaul/huntex-backhaul.sh /usr/bin/hx-bh${C_RESET}"
    return 0
  fi
  ln -sf "$target" /usr/bin/hx-bh
  chmod +x "$target" || true
  echo -e "${C_OK}${C_BOLD}OK:${C_RESET} ${C_GRAY}Command installed: hx-bh${C_RESET}"
}

# ---------------------------
# Menus
# ---------------------------
print_banner() {
  clear_screen
  hr
  echo -e "${C_TITLE}${C_BOLD}=== ${APP_NAME} ===${C_RESET}"
  echo -e "${C_GRAY}Special thanks to:${C_RESET}"
  echo -e "${C_GRAY}Backhaul project developers${C_RESET}"
  echo -e "${C_GRAY}for creating an efficient and powerful reverse tunnel core.${C_RESET}"
  hr

  local core_state
  if core_installed; then
    core_state="${C_OK}Installed${C_RESET}"
  else
    core_state="${C_BAD}Not Installed${C_RESET}"
  fi

  local sum total active inactive failed changing enabled disabled other_enabled
  sum="$(status_summary)"
  IFS='|' read -r total active inactive failed changing enabled disabled other_enabled <<<"$sum"

  echo
  echo -e "${C_TITLE}Version:${C_RESET} ${C_GRAY}${APP_VER}${C_RESET} ${C_GRAY}|${C_RESET} ${C_TITLE}Core:${C_RESET} ${core_state}"
  echo -e "${C_TITLE}Tunnels:${C_RESET} "\
"${C_OK}${C_BOLD}ACTIVE${C_RESET}${C_GRAY}:${C_RESET} ${C_GRAY}${active}${C_RESET}  "\
"${C_GRAY}|${C_RESET} "\
"${C_DIM}${C_BOLD}STOPPED${C_RESET}${C_GRAY}:${C_RESET} ${C_GRAY}${inactive}${C_RESET}  "\
"${C_GRAY}|${C_RESET} "\
"${C_BAD}${C_BOLD}FAILED${C_RESET}${C_GRAY}:${C_RESET} ${C_GRAY}${failed}${C_RESET}  "\
"${C_GRAY}|${C_RESET} "\
"${C_WARN}${C_BOLD}CHANGING${C_RESET}${C_GRAY}:${C_RESET} ${C_GRAY}${changing}${C_RESET}"

  echo
  echo -e "${C_GRAY}GitHub: https://github.com/DavoodHuntex/huntex-backhaul${C_RESET}"
  echo -e "${C_GRAY}Developer: @BiG_BanG${C_RESET}"
echo -e "Run panel: hx-bh | huntex-backhaul"
  hr
  echo
}

configure_client() {
  ensure_dir "$INSTALL_DIR"
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}Configure (Kharej / Client)${C_RESET} ${C_GRAY}- create conf_<ip>_<port>.toml${C_RESET}"
  hr
  echo

  local ip port token pool
  ip="$(read_nonempty "Remote IP: ")" || return 0
  validate_ip "$ip" || die "Invalid IP format."

  port="$(read_nonempty "Remote port: ")" || return 0
  validate_port "$port" || die "Invalid port."

  token="$(read_nonempty "Token: ")" || return 0
  pool="$(read_int_default "Connection pool" "8")"

  write_client_conf "$ip" "$port" "$token" "$pool"
}

configure_iran() {
  ensure_dir "$INSTALL_DIR"
  echo
  hr
  echo -e "${C_TITLE}${C_BOLD}Configure (IRAN / Server)${C_RESET} ${C_GRAY}- create conf_iran_<port>.toml${C_RESET}"
  hr
  echo

  local port token
  port="$(read_nonempty "Bind port: ")" || return 0
  validate_port "$port" || die "Invalid port."

  token="$(read_nonempty "Token: ")" || return 0
  write_iran_conf "$port" "$token"
}

tunnels_menu() {
  while true; do
    print_banner
    echo -e "${C_TITLE}1)${C_RESET} ${C_TITLE}Show configs${C_RESET} ${C_GRAY}(conf_*.toml)${C_RESET}"
    echo -e "${C_TITLE}2)${C_RESET} ${C_TITLE}Enable + Start${C_RESET} ${C_GRAY}(select by number)${C_RESET}"
    echo -e "${C_TITLE}3)${C_RESET} ${C_TITLE}Disable + Stop${C_RESET} ${C_GRAY}(select by number)${C_RESET}"
    echo -e "${C_TITLE}4)${C_RESET} ${C_TITLE}Restart${C_RESET} ${C_GRAY}(select by number)${C_RESET}"
    echo -e "${C_TITLE}5)${C_RESET} ${C_TITLE}Delete config (toml)${C_RESET} ${C_GRAY}(stop+disable + remove file)${C_RESET}"
    echo -e "${C_TITLE}6)${C_RESET} ${C_TITLE}View logs${C_RESET} ${C_GRAY}(tail 80)${C_RESET}"
    echo -e "${C_TITLE}7)${C_RESET} ${C_TITLE}Detailed systemd view${C_RESET} ${C_GRAY}(status + logs)${C_RESET}"
    echo -e "${C_TITLE}0)${C_RESET} ${C_GRAY}Back${C_RESET}"
    echo

    local ch
    read -r -p "$(echo -e "${C_GRAY}Select: ${C_RESET}")" ch
    case "${ch:-}" in
      1) show_configs; pause ;;
      2) enable_start_instance; pause ;;
      3) disable_stop_instance; pause ;;
      4) restart_instance; pause ;;
      5) delete_config_instance; pause ;;
      6) view_logs_instance; pause ;;
      7) detailed_systemd_view; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

core_menu() {
  while true; do
    print_banner

    local st
    if core_installed; then st="${C_OK}Installed${C_RESET}"; else st="${C_BAD}Not Installed${C_RESET}"; fi

    echo -e "${C_TITLE}${C_BOLD}Core management${C_RESET}"
    echo
    echo -e "${C_TITLE}Version:${C_RESET} ${C_GRAY}${APP_VER}${C_RESET} ${C_GRAY}|${C_RESET} ${C_TITLE}Core:${C_RESET} ${st}"
    echo -e "${C_TITLE}Core version:${C_RESET} ${C_GRAY}$(core_version_str)${C_RESET}"
    echo

    echo -e "${C_TITLE}1)${C_RESET} ${C_TITLE}Install/Update core${C_RESET} ${C_GRAY}(latest official GitHub release)${C_RESET}"
    echo -e "${C_TITLE}2)${C_RESET} ${C_TITLE}Remove core${C_RESET}"
    echo -e "${C_TITLE}3)${C_RESET} ${C_TITLE}Show latest release tag${C_RESET}"
    echo -e "${C_TITLE}4)${C_RESET} ${C_TITLE}Install command: hx-bh${C_RESET}"
    echo -e "${C_TITLE}0)${C_RESET} ${C_GRAY}Back${C_RESET}"
    echo

    local ch tag
    read -r -p "$(echo -e "${C_GRAY}Select: ${C_RESET}")" ch
    case "${ch:-}" in
      1) download_and_install_core; ensure_systemd_template; pause ;;
      2) remove_core; pause ;;
      3)
        tag="$(github_latest_tag || true)"
        if [[ -n "$tag" ]]; then
          echo -e "${C_OK}${C_BOLD}Latest tag:${C_RESET} ${C_GRAY}${tag}${C_RESET}"
        else
          echo -e "${C_BAD}${C_BOLD}Failed to fetch latest tag.${C_RESET}"
        fi
        pause
        ;;
      4) install_command_link; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

main_menu() {
  while true; do
    print_banner
    echo -e "${C_TITLE}1)${C_RESET} ${C_TITLE}Configure (Kharej / Client)${C_RESET} ${C_GRAY}- create conf_<ip>_<port>.toml${C_RESET}"
    echo -e "${C_TITLE}2)${C_RESET} ${C_TITLE}Configure (IRAN / Server)${C_RESET} ${C_GRAY}- create conf_iran_<port>.toml${C_RESET}"
    echo -e "${C_TITLE}3)${C_RESET} ${C_TITLE}Tunnels / systemd management${C_RESET}"
    echo -e "${C_TITLE}4)${C_RESET} ${C_TITLE}Core management${C_RESET}"
    echo -e "${C_TITLE}0)${C_RESET} ${C_GRAY}Exit${C_RESET}"
    echo

    local ch
    read -r -p "$(echo -e "${C_GRAY}Select: ${C_RESET}")" ch
    case "${ch:-}" in
      1) configure_client; pause ;;
      2) configure_iran; pause ;;
      3) tunnels_menu ;;
      4) core_menu ;;
      0) clear_screen; exit 0 ;;
      *) ;;
    esac
  done
}

# ---------------------------
# Entrypoint
# ---------------------------
main() {
  need_root
  require_tools
  ensure_dir "$INSTALL_DIR"

  # Clean start: show ONLY the panel
  clear_screen

  # On Ctrl+C: clear and exit cleanly.
  trap 'clear_screen; exit 0' SIGINT

  # Auto-install/refresh command alias when possible (local file execution)
  if [[ -f "$0" && "$0" != "bash" ]]; then
    target="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    ln -sf "$target" /usr/bin/hx-bh 2>/dev/null || true
    chmod +x "$target" 2>/dev/null || true
  fi

  ensure_systemd_template || true
  main_menu
}
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
