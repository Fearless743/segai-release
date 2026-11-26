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
# Requires: python3 + PyYAML (apt install python3-yaml / pip install pyyaml),
# curl + tar for downloading a release binary.
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
  local missing=0
  for t in python3; do
    command -v "$t" >/dev/null 2>&1 || { log_error "Missing required tool: $t"; missing=1; }
  done
  if [ "$DRY_RUN" -eq 0 ] && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    log_error "PyYAML is required for config translation: apt install python3-yaml (or pip install pyyaml)"
    missing=1
  fi
  [ "$missing" -eq 0 ] || exit 1
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

  SEKAI_LICENSE_KEY="$LICENSE_KEY" python3 - "$src" "$dst" <<'PY'
import copy, os, sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
license_key = os.environ.get("SEKAI_LICENSE_KEY", "").strip() or "FBN-XXXXXXXX-XXXXXXXX"
text = src.read_text(encoding="utf-8", errors="replace").replace("/etc/fboard-node", "/etc/sekai")
import yaml  # required, checked by the shell wrapper

warnings = []

def pick(d, keys):
    if not isinstance(d, dict):
        return {}
    return {k: d[k] for k in keys if k in d and d[k] not in (None, "")}

def norm_url(u):
    u = str(u).strip().rstrip("/")
    if u.startswith("http://"):
        host = u.split("/", 3)[2].split(":")[0].lower()
        if host not in ("localhost", "127.0.0.1", "::1"):
            warnings.append(
                f"panel.url 使用 http://{host}，sekai 强制要求 https；已自动改为 https://，请确认面板已开启 TLS"
            )
            u = "https://" + u[len("http://"):]
    return u

def clean_panel(p):
    out = pick(p, ("url",))
    if "url" in out:
        out["url"] = norm_url(out["url"])
    return out

def clean_machine(m, panel):
    out = pick(m, ("machine_id", "token", "token_env"))
    panel = panel if isinstance(panel, dict) else {}
    if not out.get("machine_id") and panel.get("node_id"):
        out["machine_id"] = panel["node_id"]   # legacy xboard/fboard node_id
    if not out.get("token") and not out.get("token_env") and panel.get("token"):
        out["token"] = panel["token"]          # legacy panel.token
    return out

def clean_log(l):
    return pick(l, ("level",))

def clean_ws(w):
    return pick(w, ("url", "status_interval", "handshake_timeout", "backoff_initial", "backoff_max"))

def clean_node(n):
    if not isinstance(n, dict):
        return {}
    # fboard-node: push_interval (REST report) / pull_interval (reconcile)
    # sekai:       report_interval / pull_interval
    mapping = {"push_interval": "report_interval", "report_interval": "report_interval",
               "pull_interval": "pull_interval"}
    return {mapping[k]: v for k, v in n.items() if k in mapping}

def clean_limits(x):
    return pick(x, ("device_limit", "speed_limit"))

def clean_cert(c):
    return pick(c, ("dir", "acme_email", "acme_dns_provider"))

def clean_instance(raw, base):
    panel = raw.get("panel") if isinstance(raw.get("panel"), dict) else {}
    out = {}
    for key, fn in (("panel", clean_panel), ("machine", None), ("log", clean_log),
                    ("ws", clean_ws), ("node", clean_node), ("limits", clean_limits),
                    ("cert", clean_cert)):
        if key == "machine":
            val = clean_machine(raw.get("machine"), panel)
        else:
            val = fn(raw.get(key))
        if val:
            out[key] = val
    # Fall back to top-level defaults when an instance omits them (mirrors
    # the reference node's inheritance); sekai does the same at load time,
    # but doing it here keeps the generated file self-contained.
    for key in ("panel", "machine", "ws", "node", "limits", "cert"):
        if key not in out and key in base:
            out[key] = copy.deepcopy(base[key])  # avoid YAML anchors/aliases
    return out

data = yaml.safe_load(text)
if not isinstance(data, dict):
    data = {}

base = {}
for key, fn in (("panel", clean_panel), ("log", clean_log), ("ws", clean_ws),
                ("node", clean_node), ("limits", clean_limits), ("cert", clean_cert)):
    val = fn(data.get(key))
    if val:
        base[key] = val
machine = clean_machine(data.get("machine"), data.get("panel"))
if machine:
    base["machine"] = machine
if not base.get("cert"):
    base["cert"] = {"dir": "/etc/sekai/data/certs"}

out = dict(base)
out["license"] = {
    "enabled": True,  # compat field; ignored when the license feature is compiled in
    "key": license_key,
    "cache_path": "/etc/sekai/data/license.cache",
    "grace_hours": 72,
    "renew_hours": 24,
    "timeout_secs": 15,
}

instances = data.get("instances")
if isinstance(instances, list):
    cleaned = [clean_instance(i, base) for i in instances if isinstance(i, dict)]
    cleaned = [i for i in cleaned if i.get("machine", {}).get("machine_id")]
    if cleaned:
        out["instances"] = cleaned

dst.write_text(yaml.safe_dump(out, sort_keys=False, allow_unicode=True), encoding="utf-8")
for w in warnings:
    print(w, file=sys.stderr)
PY
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
