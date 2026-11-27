#!/usr/bin/env bash
# One-shot migration: fboard-node (Go) → sekai (Rust), machine mode.
# The name/path "fboard-node" is kept only because it is the external binary
# and config directory this script detects and replaces.
#
# What it does:
#   1. stop/disable + back up fboard-node
#   2. translate /etc/fboard-node/config.yml (incl. instances + token_env)
#      into /etc/sekai/config.yml, carrying panel.url / machine_id / token_env
#      and copying credentials.env verbatim
#   3. install the sekai binary + service unit, uninstall fboard-node,
#      validate the new config and start sekai
#
# Usage (as root):
#   sudo bash migrate-from-fboard-node.sh
#   sudo bash migrate-from-fboard-node.sh --license-key FBN-XXXX-XXXX
#   sudo bash migrate-from-fboard-node.sh --binary ./target/release/sekai
#   sudo bash migrate-from-fboard-node.sh --version v0.1.2
#   sudo bash migrate-from-fboard-node.sh --keep-old --no-start
#   sudo bash migrate-from-fboard-node.sh --dry-run
#
# Requires: awk (POSIX), plus curl + tar when downloading a release binary.
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} ${BOLD}$*${NC}"; }

# fboard-node (source)
OLD_ROOT="/etc/fboard-node"
OLD_BIN="/usr/local/bin/fboard-node"
OLD_CLI="/usr/local/bin/fbctl"
OLD_UNIT="/etc/systemd/system/fboard-node.service"
OLD_OPENRC="/etc/init.d/fboard-node"

# sekai (destination)
NEW_ROOT="/etc/sekai"
NEW_BIN="/usr/local/bin/sekai"
NEW_UNIT="/etc/systemd/system/sekai.service"
NEW_OPENRC="/etc/init.d/sekai"

DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/Fearless743/sekai-release/releases}"
VERSION="latest"
BINARY=""
LICENSE_KEY="${LICENSE_KEY:-}"
KEEP_OLD=0
DRY_RUN=0
START_SERVICE=1
BACKUP_ROOT=""
LICENSE_PLACEHOLDER=0

usage() {
  cat <<'EOF'
migrate-from-fboard-node.sh — migrate fboard-node to sekai (machine mode)

Options:
  --binary PATH      Install a local sekai binary (skip download)
  --version VER      Release tag or "latest" (default: latest)
  --download-base U  GitHub releases base URL
  --license-key KEY  License key for sekai (or set LICENSE_KEY env).
                     If omitted, a placeholder is written and the service is
                     NOT started until you fill in license.key.
  --keep-old         Keep /etc/fboard-node and old binaries after migration
  --no-start         Install + migrate but do not start sekai
  --dry-run          Print actions only
  -h, --help         Show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --binary) BINARY="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-latest}"; shift 2 ;;
    --download-base) DOWNLOAD_BASE="${2:-}"; shift 2 ;;
    --license-key) LICENSE_KEY="${2:-}"; shift 2 ;;
    --keep-old) KEEP_OLD=1; shift ;;
    --no-start) START_SERVICE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} $*"
    return 0
  fi
  "$@"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run as root (sudo bash $0 ...)"
    exit 1
  fi
}

require_tools() {
  # Config translation uses awk only — no Python / PyYAML dependency.
  command -v awk >/dev/null 2>&1 || { log_error "Missing required tool: awk"; exit 1; }
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    echo systemd
  elif command -v rc-service >/dev/null 2>&1 || [ -d /etc/init.d ]; then
    echo openrc
  else
    echo none
  fi
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) log_error "Unsupported arch: $m"; exit 1 ;;
  esac
}

stop_unit() {
  local name="$1"
  local init
  init="$(detect_init)"
  case "$init" in
    systemd)
      if [ -f "/etc/systemd/system/${name}.service" ] \
        || systemctl list-unit-files "${name}.service" 2>/dev/null | grep -q "${name}.service"; then
        systemctl stop "${name}" 2>/dev/null || true
        systemctl disable "${name}" 2>/dev/null || true
      fi
      ;;
    openrc)
      if [ -f "/etc/init.d/${name}" ]; then
        rc-service "${name}" stop 2>/dev/null || true
        rc-update del "${name}" default 2>/dev/null || true
      fi
      ;;
  esac
  pkill -x "$name" 2>/dev/null || true
}

# Translate fboard-node config → sekai config.
# Drops node-mode leftovers (panel.node_id is mapped, kernel/id/nodes/etc. are
# ignored) and preserves instances + token_env so credentials.env keeps working.
transform_config() {
  local src="$1"
  local dst="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Would translate $src → $dst"
    return 0
  fi

  # Pure awk transformer: no Python / PyYAML needed. Handles both the flat
  # config and the "instances:" form, keeps token_env, maps legacy fields,
  # and appends the license/cert sections sekai requires.
  local tmp awkf
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "'"$tmp"'"' RETURN
  awkf="${tmp}/transform.awk"
  cat >"$awkf" <<'AWK'
function indent_of(s,   t) {
  t = s
  match(t, /^ */)
  return RLENGTH
}
function eff_indent(s,   t, i) {
  t = s
  match(t, /^ */)
  i = RLENGTH
  sub(/^ */, "", t)
  if (t ~ /^- /) i += 2
  return i
}
function key_of(s,   t) {
  t = s
  sub(/^ */, "", t)
  sub(/^- /, "", t)
  sub(/:.*$/, "", t)
  return t
}
function value_of(s,   t) {
  t = s
  sub(/^[^:]*:[[:space:]]*/, "", t)
  sub(/[[:space:]]+#.*$/, "", t)
  sub(/^"/, "", t)
  sub(/"$/, "", t)
  return t
}
function is_block(s,   t) {
  t = s
  sub(/^[^:]*:[[:space:]]*/, "", t)
  return (t == "" || t ~ /^#/)
}
function norm_url(u,   h) {
  sub(/\/+$/, "", u)
  if (u ~ /^http:\/\//) {
    h = u
    sub(/^http:\/\//, "", h)
    sub(/\/.*$/, "", h)
    sub(/:.*$/, "", h)
    if (h != "localhost" && h != "127.0.0.1" && h != "::1") {
      print "WARN: panel.url uses http://" h "; rewriting to https (sekai requires https)" > "/dev/stderr"
      u = "https://" substr(u, 8)
    }
  }
  return u
}
BEGIN {
  skip = -1
  sp = 0
  saw_machine = 0
  saw_cert = 0
  legacy_token = ""
  legacy_node = ""
  lk = LICENSE_KEY
  if (lk == "") lk = "FBN-XXXXXXXX-XXXXXXXX"
}
{
  line = $0
  gsub(/\/etc\/fboard-node/, "/etc/sekai", line)
  i = indent_of(line)

  if (skip >= 0) {
    if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) { print line; next }
    if (i > skip) next
    skip = -1
  }
  if (line ~ /^[[:space:]]*(#|$)/) { print line; next }

  ei = eff_indent(line)
  t = line
  sub(/^ */, "", t)
  isitem = (t ~ /^- /)
  iskey = (t ~ /^[A-Za-z_][A-Za-z0-9_-]*:/ || t ~ /^- [A-Za-z_][A-Za-z0-9_-]*:/)
  if (!iskey) { print line; next }

  while (sp > 0 && sind[sp] >= ei) sp--
  key = key_of(line)
  section = (sp > 0 ? skey[sp] : "")
  block = is_block(line)
  rest = value_of(line)
  allow = 1

  if (key == "kernel" || key == "nodes" || key == "runtime" || key == "standalone") {
    allow = 0
    if (isitem) print substr(line, 1, i) "-"
    if (block) skip = ei
  } else if (key == "id" || key == "node_type" || key == "data_dir" || key == "health_port" || key == "track_interval" || key == "type" || key == "config_dir" || key == "log_level" || key == "output") {
    allow = 0
    # A denied "- id:" is the first key of an instance: keep the list marker
    # so the following indented keys still form that sequence item.
    if (isitem) print substr(line, 1, i) "-"
    if (block) skip = ei
  } else if (section == "panel") {
    if (key == "url") {
      nu = norm_url(rest)
      if (nu != rest) {
        p = index(line, rest)
        if (p > 0) line = substr(line, 1, p - 1) nu substr(line, p + length(rest))
      }
    } else {
      if (sp == 1 && skey[1] == "panel") {
        if (key == "token") legacy_token = rest
        if (key == "node_id") legacy_node = rest
      }
      allow = 0
    }
  } else if (section == "machine") {
    if (key != "machine_id" && key != "token" && key != "token_env") allow = 0
  } else if (section == "node") {
    if (key == "push_interval") {
      sub(/push_interval/, "report_interval", line)
    } else if (key != "report_interval" && key != "pull_interval") {
      allow = 0
    }
  } else if (section == "ws") {
    if (key != "url" && key != "status_interval" && key != "handshake_timeout" && key != "backoff_initial" && key != "backoff_max") allow = 0
  } else if (section == "log") {
    if (key != "level") allow = 0
  } else if (section == "limits") {
    if (key != "device_limit" && key != "speed_limit") allow = 0
  } else if (section == "cert") {
    if (key != "dir" && key != "acme_email" && key != "acme_dns_provider") allow = 0
  }

  if (allow && block) {
    sp++
    skey[sp] = key
    sind[sp] = ei
    if (key == "machine" && ei == 0) saw_machine = 1
    if (key == "cert" && ei == 0) saw_cert = 1
  }
  if (allow) print line
}
END {
  if (!saw_machine && (legacy_token != "" || legacy_node != "")) {
    print ""
    print "machine:"
    if (legacy_node != "") print "  machine_id: " legacy_node
    if (legacy_token != "") print "  token: \"" legacy_token "\""
  }
  if (!saw_cert) {
    print ""
    print "cert:"
    print "  dir: /etc/sekai/data/certs"
  }
  print ""
  print "license:"
  print "  enabled: true"
  print "  key: \"" lk "\""
  print "  cache_path: /etc/sekai/data/license.cache"
  print "  grace_hours: 72"
  print "  renew_hours: 24"
  print "  timeout_secs: 15"
}
AWK
  awk -v LICENSE_KEY="$LICENSE_KEY" -f "$awkf" "$src" >"$dst"
  chmod 600 "$dst"
}

filter_credentials() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Would copy $src → $dst"
    return 0
  fi
  # Keep every KEY=VALUE line (token_env names stay valid); drop only
  # obvious node-mode leftovers.
  grep -Ev '^(NODE_ID|nodeID|NODE_TYPE|nodeType)=' "$src" >"$dst" || true
  chmod 600 "$dst"
}

resolve_binary() {
  local arch tmp url target found
  arch="$(detect_arch)"

  if [ -n "$BINARY" ]; then
    [ -x "$BINARY" ] || { log_error "--binary is not executable: $BINARY"; exit 1; }
    log_info "Using local binary: $BINARY"
    run install -m 755 "$BINARY" "$NEW_BIN"
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  for candidate in "$script_dir/sekai" "$script_dir/target/release/sekai"; do
    if [ -n "$script_dir" ] && [ -x "$candidate" ]; then
      log_info "Using binary next to script: $candidate"
      run install -m 755 "$candidate" "$NEW_BIN"
      return
    fi
  done

  log_step "Downloading sekai ${VERSION} (${arch})"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} download sekai-${arch}-unknown-linux-gnu.tar.gz → $NEW_BIN"
    return 0
  fi

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "'"$tmp"'"' RETURN

  if [ "$VERSION" = "latest" ]; then
    url="${DOWNLOAD_BASE}/latest/download"
  else
    url="${DOWNLOAD_BASE}/download/${VERSION}"
  fi

  for target in "${arch}-unknown-linux-gnu" "${arch}-unknown-linux-musl"; do
    if curl -fsSL "${url}/sekai-${target}.tar.gz" -o "${tmp}/pkg" 2>/dev/null; then
      log_info "Downloaded sekai-${target}.tar.gz"
      tar -xzf "${tmp}/pkg" -C "$tmp"
      found="$(find "$tmp" -type f -name 'sekai' | head -1 || true)"
      [ -n "$found" ] && break
    fi
  done

  if [ -z "${found:-}" ] || [ ! -x "$found" ]; then
    log_error "Failed to obtain sekai binary from ${url}"
    log_error "Hint: cargo build --release && sudo bash $0 --binary ./target/release/sekai"
    exit 1
  fi
  install -m 755 "$found" "$NEW_BIN"
}

migrate_config() {
  run mkdir -p "$NEW_ROOT" "${NEW_ROOT}/backups" "${NEW_ROOT}/data/certs"

  if [ ! -d "$OLD_ROOT" ] && [ ! -f "${NEW_ROOT}/config.yml" ]; then
    log_error "No ${OLD_ROOT} and no ${NEW_ROOT}/config.yml"
    exit 1
  fi
  if [ ! -d "$OLD_ROOT" ]; then
    log_warn "No ${OLD_ROOT}; keeping existing ${NEW_ROOT}"
    BACKUP_ROOT="none"
    return
  fi

  BACKUP_ROOT="${NEW_ROOT}/backups/fboard-migrate-$(date +%Y%m%d-%H%M%S)"
  log_step "Backing up ${OLD_ROOT} → ${BACKUP_ROOT}"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} cp -a ${OLD_ROOT} ${BACKUP_ROOT}"
  else
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    cp -a "$OLD_ROOT/." "$BACKUP_ROOT/" 2>/dev/null || true
    [ -x "$OLD_BIN" ] && cp -a "$OLD_BIN" "$BACKUP_ROOT/fboard-node" || true
    [ -x "$OLD_CLI" ] && cp -a "$OLD_CLI" "$BACKUP_ROOT/fbctl" || true
    [ -f "$OLD_UNIT" ] && cp -a "$OLD_UNIT" "$BACKUP_ROOT/fboard-node.service" || true
    [ -f "$OLD_OPENRC" ] && cp -a "$OLD_OPENRC" "$BACKUP_ROOT/fboard-node.openrc" || true
    chmod -R go-rwx "$BACKUP_ROOT" 2>/dev/null || true
  fi

  log_step "Copying data files to ${NEW_ROOT}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Would copy ${OLD_ROOT}/ → ${NEW_ROOT}/ (excluding config/credentials/backups/instances)"
  else
    shopt -s dotglob nullglob
    for item in "$OLD_ROOT"/*; do
      base="$(basename "$item")"
      case "$base" in
        backups|config.yml|credentials.env|instances) continue ;;
      esac
      [ -e "${NEW_ROOT}/${base}" ] && continue
      cp -a "$item" "${NEW_ROOT}/"
    done
    shopt -u dotglob nullglob
  fi

  if [ -f "${OLD_ROOT}/credentials.env" ]; then
    log_step "Copying credentials.env → ${NEW_ROOT}/credentials.env"
    filter_credentials "${OLD_ROOT}/credentials.env" "${NEW_ROOT}/credentials.env"
  else
    log_warn "No ${OLD_ROOT}/credentials.env — if token_env is used, fill it in ${NEW_ROOT}/credentials.env"
  fi

  if [ -f "${OLD_ROOT}/config.yml" ]; then
    log_step "Writing sekai config → ${NEW_ROOT}/config.yml"
    transform_config "${OLD_ROOT}/config.yml" "${NEW_ROOT}/config.yml"
  elif [ ! -f "${NEW_ROOT}/config.yml" ]; then
    log_error "No source config.yml to migrate"
    exit 1
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    printf 'migrated from fboard-node at %s\n' "$(date -u +%FT%TZ)" >"${NEW_ROOT}/MIGRATED_FROM"
  fi
}

uninstall_old() {
  if [ "$KEEP_OLD" -eq 1 ]; then
    log_info "Keeping fboard-node files (--keep-old)"
    return
  fi
  log_step "Removing fboard-node"
  run rm -f "$OLD_BIN" "$OLD_CLI" /usr/bin/fbctl 2>/dev/null || true
  run rm -f "$OLD_UNIT" "$OLD_OPENRC"
  if [ "$(detect_init)" = "systemd" ]; then
    run systemctl daemon-reload || true
  fi
  if [ -d "$OLD_ROOT" ]; then
    run rm -rf "$OLD_ROOT"
    log_info "Removed ${OLD_ROOT} (backup: ${BACKUP_ROOT:-n/a})"
  fi
}

install_systemd_unit() {
  cat >"$NEW_UNIT" <<EOF
[Unit]
Description=sekai Node
Documentation=https://github.com/Fearless743/sekai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${NEW_ROOT}
EnvironmentFile=-${NEW_ROOT}/credentials.env
ExecStart=${NEW_BIN} -c ${NEW_ROOT}/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sekai 2>/dev/null || true
}

install_openrc_unit() {
  cat >"$NEW_OPENRC" <<EOF
#!/sbin/openrc-run

description="sekai Node"
command="${NEW_BIN}"
command_args="-c ${NEW_ROOT}/config.yml"
command_background=true
pidfile="/run/sekai.pid"
output_log="/var/log/sekai.log"
error_log="/var/log/sekai.log"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ -f ${NEW_ROOT}/credentials.env ]; then
        set -a
        . ${NEW_ROOT}/credentials.env
        set +a
    fi
    touch "\$output_log"
}
EOF
  chmod 755 "$NEW_OPENRC"
  rc-update add sekai default 2>/dev/null || true
}

validate_and_start() {
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -x "$NEW_BIN" ]; then
      log_error "Missing ${NEW_BIN}"
      exit 1
    fi
    if [ ! -f "${NEW_ROOT}/config.yml" ]; then
      log_error "Missing ${NEW_ROOT}/config.yml"
      exit 1
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} ${NEW_BIN} check -c ${NEW_ROOT}/config.yml"
  else
    log_step "Validating config"
    # token_env is resolved from the process environment, which systemd will
    # populate from credentials.env — do the same for the offline check.
    (
      set -a
      # shellcheck disable=SC1090
      . "${NEW_ROOT}/credentials.env" 2>/dev/null || true
      set +a
      "$NEW_BIN" check -c "${NEW_ROOT}/config.yml"
    )
  fi

  local init
  init="$(detect_init)"
  if [ "$init" = "none" ]; then
    log_warn "No init system detected; start manually: ${NEW_BIN} -c ${NEW_ROOT}/config.yml"
    return
  fi
  log_step "Installing sekai service (${init})"
  case "$init" in
    systemd) run install_systemd_unit ;;
    openrc)  run install_openrc_unit ;;
  esac

  if [ "$START_SERVICE" -eq 0 ]; then
    log_info "Service installed, not started (--no-start)"
    return
  fi
  if [ "$LICENSE_PLACEHOLDER" -eq 1 ]; then
    log_warn "license.key is a placeholder — sekai will refuse to start until you fill it in:"
    log_warn "  sudoedit ${NEW_ROOT}/config.yml   # license.key"
    log_warn "  sudo sekai start"
    return
  fi

  log_step "Starting sekai"
  case "$init" in
    systemd)
      run systemctl restart sekai
      sleep 1
      [ "$DRY_RUN" -eq 0 ] && systemctl --no-pager --full status sekai || true
      ;;
    openrc)
      run rc-service sekai restart
      ;;
  esac
}

print_summary() {
  echo
  echo -e "${BOLD}Migration complete${NC}"
  echo "  binary:  ${NEW_BIN}"
  echo "  config:  ${NEW_ROOT}/config.yml"
  echo "  creds:   ${NEW_ROOT}/credentials.env"
  echo "  backup:  ${BACKUP_ROOT:-none}"
  echo "  service: sekai"
  echo
  echo "  systemctl status sekai"
  echo "  journalctl -u sekai -f"
  echo "  sekai check -c ${NEW_ROOT}/config.yml"
  if [ "$LICENSE_PLACEHOLDER" -eq 1 ]; then
    echo
    log_warn "Remember: set license.key in ${NEW_ROOT}/config.yml, then: sudo sekai start"
  fi
}

main() {
  require_root
  require_tools
  log_step "fboard-node → sekai"

  if [ -z "$LICENSE_KEY" ]; then
    if [ -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      read -rsp "License Key（留空则写入占位符，稍后手动填写）: " LICENSE_KEY
      echo
    fi
    if [ -z "$LICENSE_KEY" ]; then
      LICENSE_PLACEHOLDER=1
      log_warn "No license key provided; a placeholder will be written and sekai will not be started."
    fi
  fi

  log_step "Stopping fboard-node"
  run stop_unit fboard-node

  resolve_binary
  migrate_config
  uninstall_old
  validate_and_start
  print_summary
}

main
