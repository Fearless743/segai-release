#!/usr/bin/env bash
# sekai 一键安装 / 升级 / 卸载脚本（machine 模式，支持 systemd 与 OpenRC）
#
#   curl -fsSL https://raw.githubusercontent.com/Fearless743/sekai-release/main/install.sh \
#     | sudo bash -s -- --panel https://panel.example.com --token TOKEN --machine-id 1
#
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} ${BOLD}$1${NC}"; }

APP_NAME="sekai"
REPO="Fearless743/sekai-release"
INSTALL_ROOT="/etc/${APP_NAME}"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
DATA_DIR="${INSTALL_ROOT}/data"
BINARY_PATH="/usr/local/bin/${APP_NAME}"
SERVICE_NAME="${APP_NAME}"
SERVICE_PATH=""
LOG_FILE="/var/log/${APP_NAME}.log"
ERR_LOG_FILE="/var/log/${APP_NAME}.err.log"

DEFAULT_VERSION="latest"
DEFAULT_LOG_LEVEL="silent"

ACTION="install"
PANEL_URLS=()
TOKENS=()
MACHINE_IDS=()
LICENSE_KEY=""
RELEASE_VERSION="$DEFAULT_VERSION"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
PURGE=0
YES=0
TMP_DIR=""
BACKUP_DIR=""
SERVICE_EXISTED=0
CLEANUP_DONE=0

INIT=""
ASSET=""
LIBC=""
RC_SERVICE_BIN=""
RC_UPDATE_BIN=""

usage() {
    cat <<'HELP'

  sekai Installer (machine mode)

  ACTIONS:
    install      安装或调整当前部署（默认）
    upgrade      升级二进制并重启服务
    uninstall    卸载服务与二进制（默认保留配置，--purge 一并删除）
    status       查看当前安装状态
    logs         实时跟随服务日志（Ctrl+C 退出）
    help         显示帮助

  REQUIRED (install):
    --panel, -a       面板地址，如 https://panel.example.com（可重复，每个面板一组）
    --token, -t       面板 machine token（与 --panel 一一对应，可重复）
    --machine-id      面板 machine ID（正整数，与 --panel 一一对应，可重复）
    --license-key     License Key（必填；写入配置并启用商业授权校验）

  OPTIONAL:
    --version         版本号或 latest（默认 latest）
    --purge           uninstall 时删除 /etc/sekai
    --yes, -y         非交互确认
    --help, -h        显示帮助

  支持：glibc（systemd）、Alpine/musl（OpenRC）。Alpine 需先安装 bash。

  EXAMPLES:
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1 --license-key FBN-XXXX-XXXX
    # 多面板：重复三组参数，共用一个进程与 license
    sudo bash install.sh --panel https://a.example.com --token TOKEN_A --machine-id 1 \
      --panel https://b.example.com --token TOKEN_B --machine-id 2 --license-key FBN-XXXX-XXXX
    sudo bash install.sh upgrade
    sudo bash install.sh uninstall --purge --yes
HELP
}

cleanup() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then return 0; fi
    CLEANUP_DONE=1
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
    return 0
}

service_mode() {
    if [ "$INIT" = "systemd" ]; then echo 644; else echo 755; fi
}

on_error() {
    local code=$? line=${1:-unknown}
    if [ "$code" -ne 0 ]; then
        log_error "安装失败（第 ${line} 行，exit=${code}）"
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
            log_warn "正在回滚..."
            [ -f "$BACKUP_DIR/config.yml" ] && install -m 600 "$BACKUP_DIR/config.yml" "$CONFIG_FILE" || rm -f "$CONFIG_FILE"
            [ -f "$BACKUP_DIR/credentials.env" ] && install -m 600 "$BACKUP_DIR/credentials.env" "$CREDENTIALS_FILE" || rm -f "$CREDENTIALS_FILE"
            [ -f "$BACKUP_DIR/binary" ] && install -m 755 "$BACKUP_DIR/binary" "$BINARY_PATH" || rm -f "$BINARY_PATH"
            if [ "$SERVICE_EXISTED" -eq 1 ]; then
                if [ -f "$BACKUP_DIR/service" ]; then
                    install -m "$(service_mode)" "$BACKUP_DIR/service" "$SERVICE_PATH"
                fi
                daemon_reload || true
                service_restart >/dev/null 2>&1 || true
            else
                service_stop >/dev/null 2>&1 || true
                service_disable >/dev/null 2>&1 || true
                rm -f "$SERVICE_PATH"
                daemon_reload || true
            fi
        fi
    fi
    cleanup
    exit "$code"
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            install|upgrade|uninstall|status|logs|help) ACTION="$1"; shift ;;
            --panel|-a|--api)      PANEL_URLS+=("${2:-}"); shift 2 ;;
            --token|-t)            TOKENS+=("${2:-}"); shift 2 ;;
            --machine-id)          MACHINE_IDS+=("${2:-}"); shift 2 ;;
            --license-key)         LICENSE_KEY="${2:-}"; shift 2 ;;
            --version)             RELEASE_VERSION="${2:-}"; shift 2 ;;
            --purge)               PURGE=1; shift ;;
            --yes|-y)              YES=1; shift ;;
            --help|-h)             ACTION="help"; shift ;;
            *) log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done
}

check_root() {
    [ "$(id -u)" -eq 0 ] || { log_error "请用 root 或 sudo 运行"; exit 1; }
}

find_rc() {
    RC_SERVICE_BIN=""; RC_UPDATE_BIN=""
    local c
    for c in rc-service /sbin/rc-service /usr/sbin/rc-service; do
        if command -v "$c" >/dev/null 2>&1; then RC_SERVICE_BIN="$c"; break; fi
    done
    for c in rc-update /sbin/rc-update /usr/sbin/rc-update; do
        if command -v "$c" >/dev/null 2>&1; then RC_UPDATE_BIN="$c"; break; fi
    done
}

detect_init() {
    INIT=""
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        INIT="systemd"
        SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
        log_info "检测到 init 系统: systemd"
        return
    fi
    find_rc
    if [ -n "$RC_SERVICE_BIN" ] && [ -n "$RC_UPDATE_BIN" ]; then
        INIT="openrc"
        SERVICE_PATH="/etc/init.d/${SERVICE_NAME}"
        log_info "检测到 init 系统: OpenRC"
        return
    fi
    log_error "未检测到 systemd 或 OpenRC（找不到 systemctl / rc-service）"
    exit 1
}

daemon_reload() {
    if [ "$INIT" = "systemd" ]; then systemctl daemon-reload; fi
}

service_start() {
    case "$INIT" in
        systemd) systemctl start "$SERVICE_NAME" ;;
        openrc)  "$RC_SERVICE_BIN" "$SERVICE_NAME" start ;;
    esac
}

service_stop() {
    case "$INIT" in
        systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc)  "$RC_SERVICE_BIN" "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
    esac
}

service_restart() {
    case "$INIT" in
        systemd) systemctl restart "$SERVICE_NAME" ;;
        openrc)  "$RC_SERVICE_BIN" "$SERVICE_NAME" restart ;;
    esac
}

service_enable() {
    case "$INIT" in
        systemd) systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc)  "$RC_UPDATE_BIN" add "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
    esac
}

service_disable() {
    case "$INIT" in
        systemd) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc)  "$RC_UPDATE_BIN" del "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
    esac
}

service_is_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" ;;
        openrc)  "$RC_SERVICE_BIN" "$SERVICE_NAME" status >/dev/null 2>&1 ;;
    esac
}

service_status() {
    case "$INIT" in
        systemd) systemctl status "${SERVICE_NAME}.service" --no-pager || true ;;
        openrc)  "$RC_SERVICE_BIN" "$SERVICE_NAME" status || true ;;
    esac
}

show_logs() {
    if [ "$INIT" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager || true
    else
        if [ -f "$LOG_FILE" ]; then
            echo "--- ${LOG_FILE} ---"
            tail -n 30 "$LOG_FILE" 2>/dev/null || true
        fi
        if [ -f "$ERR_LOG_FILE" ]; then
            echo "--- ${ERR_LOG_FILE} ---"
            tail -n 30 "$ERR_LOG_FILE" 2>/dev/null || true
        fi
    fi
}

download() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url"
    else
        log_error "需要 curl 或 wget 才能下载"; return 1
    fi
}

http_ok() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS "$url" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null "$url" 2>/dev/null
    else
        return 1
    fi
}

detect_asset() {
    local os arch line
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in
        Linux)  os=linux  ;;
        *) log_error "不支持的操作系统: $os（本脚本仅支持 Linux 服务器）"; exit 1 ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch=x86_64  ;;
        aarch64|arm64) arch=aarch64 ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac

    LIBC="gnu"
    if [ -f /etc/alpine-release ]; then
        LIBC="musl"
    elif grep -qi '^ID=alpine' /etc/os-release 2>/dev/null; then
        LIBC="musl"
    elif ldd --version 2>&1 | grep -qi musl; then
        LIBC="musl"
    fi

    case "${os}-${LIBC}-${arch}" in
        linux-gnu-x86_64)   ASSET="sekai-x86_64-unknown-linux-gnu.tar.gz" ;;
        linux-gnu-aarch64)  ASSET="sekai-aarch64-unknown-linux-gnu.tar.gz" ;;
        linux-musl-x86_64)  ASSET="sekai-x86_64-unknown-linux-musl.tar.gz" ;;
        linux-musl-aarch64) ASSET="sekai-aarch64-unknown-linux-musl.tar.gz" ;;
        *) log_error "无匹配的安装包: ${os}-${LIBC}-${arch}"; exit 1 ;;
    esac
    log_info "平台: ${os}/${arch}，libc: ${LIBC}"
}

validate_install() {
    local n=${#PANEL_URLS[@]} i url id
    [ "$n" -gt 0 ] || { log_error "缺少 --panel"; exit 1; }
    [ "${#TOKENS[@]}" -eq "$n" ] || { log_error "--token 数量必须与 --panel 一致（${n} 个面板，${#TOKENS[@]} 个 token）"; exit 1; }
    [ "${#MACHINE_IDS[@]}" -eq "$n" ] || { log_error "--machine-id 数量必须与 --panel 一致（${n} 个面板，${#MACHINE_IDS[@]} 个 ID）"; exit 1; }
    [ -n "$LICENSE_KEY" ] || { log_error "缺少 --license-key（未授权的节点无法运行）"; exit 1; }
    for ((i = 0; i < n; i++)); do
        url="${PANEL_URLS[$i]}"
        case "$url" in
            http://*|https://*) ;;
            *) PANEL_URLS[$i]="https://${url}" ;;
        esac
        id="${MACHINE_IDS[$i]}"
        case "$id" in
            ''|*[!0-9]*) log_error "--machine-id[$i] 必须是正整数"; exit 1 ;;
        esac
        [ "$id" -gt 0 ] || { log_error "--machine-id[$i] 必须是正整数"; exit 1; }
    done
}

yaml_quote() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

env_quote() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '"%s"' "$s"
}

ensure_dirs() {
    mkdir -p "$INSTALL_ROOT" "$DATA_DIR" "$TMP_DIR"
    chmod 700 "$INSTALL_ROOT"
}

stage_binary() {
    local url path
    if [ "$RELEASE_VERSION" = "latest" ]; then
        url="https://github.com/${REPO}/releases/latest/download/${ASSET}"
    else
        url="https://github.com/${REPO}/releases/download/${RELEASE_VERSION}/${ASSET}"
    fi
    path="${TMP_DIR}/${ASSET}"
    log_step "下载 ${RELEASE_VERSION} (${ASSET})"
    download "$url" "$path" || { log_error "下载失败: $url"; exit 1; }
    tar tzf "$path" >/dev/null 2>&1 || { log_error "压缩包损坏: $ASSET"; exit 1; }
    tar xzf "$path" -C "$TMP_DIR"
    [ -f "${TMP_DIR}/${APP_NAME}" ] || { log_error "压缩包内未找到 ${APP_NAME}"; exit 1; }
    chmod 755 "${TMP_DIR}/${APP_NAME}"
}

render_config() {
    local license_block=""
    if [ -n "$LICENSE_KEY" ]; then
        license_block=$(cat <<EOF

license:
  enabled: true
  key: $(yaml_quote "$LICENSE_KEY")
  cache_path: "${DATA_DIR}/license.cache"
  grace_hours: 72
  renew_hours: 24
  timeout_secs: 15
EOF
        )
    fi

    local n=${#PANEL_URLS[@]} i panels_block=""
    if [ "$n" -eq 1 ]; then
        # Single panel: keep the original flat layout.
        panels_block=$(cat <<EOF
panel:
  url: $(yaml_quote "${PANEL_URLS[0]}")

machine:
  machine_id: ${MACHINE_IDS[0]}
  token: ""                 # token 读取自 credentials.env 的 MACHINE_TOKEN
  token_env: MACHINE_TOKEN
EOF
        )
    else
        # Multi-panel: one process, one instance per panel/machine pair.
        panels_block="instances:"
        for ((i = 0; i < n; i++)); do
            panels_block+="
  - panel:
      url: $(yaml_quote "${PANEL_URLS[$i]}")
    machine:
      machine_id: ${MACHINE_IDS[$i]}
      token: \"\"
      token_env: SEKAI_TOKEN_${i}
"
        done
    fi

    cat >"${TMP_DIR}/config.yml" <<EOF
# ${APP_NAME} configuration — managed by install.sh (machine mode)
${panels_block}

log:
  # 默认 silent（完全不输出日志）；需要日志时请手动修改本文件为 info/debug/warn/error
  level: $(yaml_quote "$LOG_LEVEL")

ws:
  url: ""
  status_interval: 10
  handshake_timeout: 15
  backoff_initial: 1
  backoff_max: 60

node:
  report_interval: 60

limits:
  device_limit: true
  speed_limit: true

cert:
  dir: "${DATA_DIR}/certs"
${license_block}
EOF
    if [ "$n" -eq 1 ]; then
        printf 'MACHINE_TOKEN=%s\n' "$(env_quote "${TOKENS[0]}")" >"${TMP_DIR}/credentials.env"
    else
        : >"${TMP_DIR}/credentials.env"
        for ((i = 0; i < n; i++)); do
            printf 'SEKAI_TOKEN_%d=%s\n' "$i" "$(env_quote "${TOKENS[$i]}")" >>"${TMP_DIR}/credentials.env"
        done
    fi
    chmod 600 "${TMP_DIR}/credentials.env"
}

render_service() {
    if [ "$INIT" = "systemd" ]; then
        cat >"${TMP_DIR}/service" <<EOF
[Unit]
Description=sekai Fboard Node
Documentation=https://github.com/Fearless743/sekai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=-${CREDENTIALS_FILE}
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    else
        cat >"${TMP_DIR}/service" <<EOF
#!/sbin/openrc-run

description="sekai Fboard Node"
command="${BINARY_PATH}"
command_args="-c ${CONFIG_FILE}"
command_background=true
pidfile="/run/${APP_NAME}.pid"
output_log="${LOG_FILE}"
error_log="${ERR_LOG_FILE}"
# Graceful shutdown: allow 10s for connection drain before SIGKILL.
retry="TERM/10/KILL/5"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ -f ${CREDENTIALS_FILE} ]; then
        set -a
        . ${CREDENTIALS_FILE}
        set +a
    fi
    mkdir -p ${DATA_DIR}
    touch ${LOG_FILE} ${ERR_LOG_FILE}
}
EOF
    fi
}

backup_existing() {
    mkdir -p "$BACKUP_DIR"
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_DIR/config.yml" || true
    [ -f "$CREDENTIALS_FILE" ] && cp "$CREDENTIALS_FILE" "$BACKUP_DIR/credentials.env" || true
    [ -x "$BINARY_PATH" ] && cp "$BINARY_PATH" "$BACKUP_DIR/binary" || true
    [ -f "$SERVICE_PATH" ] && cp "$SERVICE_PATH" "$BACKUP_DIR/service" || true
    if [ -f "$SERVICE_PATH" ]; then SERVICE_EXISTED=1; fi
}

install_files() {
    install -m 755 "${TMP_DIR}/${APP_NAME}" "$BINARY_PATH"
    install -m 600 "${TMP_DIR}/config.yml" "$CONFIG_FILE"
    install -m 600 "${TMP_DIR}/credentials.env" "$CREDENTIALS_FILE"
    install -m "$(service_mode)" "${TMP_DIR}/service" "$SERVICE_PATH"
    daemon_reload
}

wait_for_service() {
    local i=0
    while [ "$i" -lt 30 ]; do
        if service_is_active; then
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

start_service() {
    service_enable
    service_restart
    if ! wait_for_service; then
        log_error "服务启动失败"
        show_logs
        return 1
    fi
}

perform_install() {
    check_root; detect_init; validate_install; detect_asset
    TMP_DIR="$(mktemp -d)"; BACKUP_DIR="${TMP_DIR}/backup"
    ensure_dirs
    stage_binary
    render_config
    render_service
    backup_existing
    install_files
    start_service
    log_info "安装完成"
    log_info "服务: ${SERVICE_NAME}（${INIT}）"
    log_info "配置: ${CONFIG_FILE}（权限 600）"
    log_info "凭证: ${CREDENTIALS_FILE}（权限 600）"
    log_info "授权: 已写入 license.key 并启用在线校验"
}

perform_upgrade() {
    check_root; detect_init; detect_asset
    [ -f "$CONFIG_FILE" ] || { log_error "未找到现有配置，请先执行 install"; exit 1; }
    TMP_DIR="$(mktemp -d)"; BACKUP_DIR="${TMP_DIR}/backup"
    ensure_dirs
    stage_binary
    render_service
    backup_existing
    install_files
    start_service
    log_info "升级完成"
}

perform_uninstall() {
    check_root; detect_init
    service_stop
    service_disable
    rm -f "$SERVICE_PATH" "$BINARY_PATH"
    daemon_reload || true
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$INSTALL_ROOT"
        rm -f "/var/log/${APP_NAME}.log"
        log_info "已卸载（含配置目录 ${INSTALL_ROOT}）"
    else
        log_info "已卸载（配置保留在 ${INSTALL_ROOT}）"
    fi
}

perform_logs() {
    detect_init
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "读取服务日志通常需要 root，建议加 sudo"
    fi
    if [ "$INIT" = "systemd" ]; then
        if ! command -v journalctl >/dev/null 2>&1; then
            log_error "未找到 journalctl"; exit 1
        fi
        journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager || true
        echo "--- 实时日志 (Ctrl+C 退出) ---"
        journalctl -u "${SERVICE_NAME}.service" -f || true
    else
        touch "$LOG_FILE" "$ERR_LOG_FILE" 2>/dev/null || true
        if [ -f "$LOG_FILE" ]; then
            echo "--- ${LOG_FILE} (最近 50 行) ---"
            tail -n 50 "$LOG_FILE" 2>/dev/null || true
        fi
        if [ -f "$ERR_LOG_FILE" ]; then
            echo "--- ${ERR_LOG_FILE} (最近 50 行) ---"
            tail -n 50 "$ERR_LOG_FILE" 2>/dev/null || true
        fi
        echo "--- 实时日志 (Ctrl+C 退出) ---"
        tail -F -n 0 "$LOG_FILE" "$ERR_LOG_FILE" 2>/dev/null \
            || tail -f -n 0 "$LOG_FILE" "$ERR_LOG_FILE" 2>/dev/null \
            || true
    fi
}

perform_status() {
    if [ -x "$BINARY_PATH" ]; then
        log_info "二进制: ${BINARY_PATH}"
        "$BINARY_PATH" --version 2>/dev/null || true
    else
        log_warn "未安装二进制"
    fi
    if [ -f "$CONFIG_FILE" ]; then log_info "配置: ${CONFIG_FILE}"; else log_warn "未找到配置"; fi
    detect_init
    service_status
}

main() {
    parse_args "$@"
    case "$ACTION" in
        install)   perform_install   ;;
        upgrade)   perform_upgrade   ;;
        uninstall) perform_uninstall ;;
        status)    perform_status    ;;
        logs)      perform_logs      ;;
        help)      usage             ;;
        *) log_error "未知操作: $ACTION"; usage; exit 1 ;;
    esac
}

main "$@"
