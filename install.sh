#!/usr/bin/env bash
# sekai 一键安装 / 升级 / 卸载脚本（machine 模式）
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
SERVICE_PATH="/etc/systemd/system/${APP_NAME}.service"

DEFAULT_VERSION="latest"
DEFAULT_HEALTH_PORT="65530"
DEFAULT_LOG_LEVEL="info"

ACTION="install"
PANEL_URL=""
TOKEN=""
MACHINE_ID=""
LICENSE_KEY=""
RELEASE_VERSION="$DEFAULT_VERSION"
HEALTH_PORT="$DEFAULT_HEALTH_PORT"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
PURGE=0
YES=0
TMP_DIR=""
BACKUP_DIR=""
SERVICE_EXISTED=0
CLEANUP_DONE=0

usage() {
    cat <<'HELP'

  sekai Installer (machine mode)

  ACTIONS:
    install      安装或调整当前部署（默认）
    upgrade      升级二进制并重启服务
    uninstall    卸载服务与二进制（默认保留配置，--purge 一并删除）
    status       查看当前安装状态
    help         显示帮助

  REQUIRED (install):
    --panel, -a       面板地址，如 https://panel.example.com
    --token, -t       面板 machine token
    --machine-id      面板 machine ID（正整数）

  OPTIONAL:
    --license-key     License Key（可选；提供则启用商业授权校验）
    --version         版本号或 latest（默认 latest）
    --health-port     本地探活端口（默认 65530，0 关闭）
    --log-level       日志级别（默认 info）
    --purge           uninstall 时删除 /etc/sekai
    --yes, -y         非交互确认
    --help, -h        显示帮助

  EXAMPLES:
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1 --license-key FBN-XXXX-XXXX
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
                if [ -f "$BACKUP_DIR/service" ]; then install -m 644 "$BACKUP_DIR/service" "$SERVICE_PATH"; fi
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
            else
                systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "$SERVICE_PATH"
                systemctl daemon-reload >/dev/null 2>&1 || true
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
            install|upgrade|uninstall|status|help) ACTION="$1"; shift ;;
            --panel|-a|--api)      PANEL_URL="${2:-}"; shift 2 ;;
            --token|-t)            TOKEN="${2:-}"; shift 2 ;;
            --machine-id)          MACHINE_ID="${2:-}"; shift 2 ;;
            --license-key)         LICENSE_KEY="${2:-}"; shift 2 ;;
            --version)             RELEASE_VERSION="${2:-}"; shift 2 ;;
            --health-port)         HEALTH_PORT="${2:-}"; shift 2 ;;
            --log-level)           LOG_LEVEL="${2:-}"; shift 2 ;;
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

check_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || {
        log_error "未检测到 systemd；本脚本目前仅支持 systemd 系统"; exit 1;
    }
}

detect_asset() {
    local os arch
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in
        Linux)  os=linux  ;;
        Darwin) log_error "macOS 请用手动下载方式（本脚本面向 systemd 服务器）"; exit 1 ;;
        *) log_error "不支持的操作系统: $os"; exit 1 ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch=x86_64  ;;
        aarch64|arm64) arch=aarch64 ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac
    case "${os}-${arch}" in
        linux-x86_64)  ASSET="sekai-x86_64-unknown-linux-gnu.tar.gz" ;;
        linux-aarch64) ASSET="sekai-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) log_error "无匹配的安装包: ${os}-${arch}"; exit 1 ;;
    esac
}

validate_install() {
    [ -n "$PANEL_URL" ] || { log_error "缺少 --panel"; exit 1; }
    [ -n "$TOKEN" ] || { log_error "缺少 --token"; exit 1; }
    case "$MACHINE_ID" in
        ''|*[!0-9]*) log_error "--machine-id 必须是正整数"; exit 1 ;;
    esac
    [ "$MACHINE_ID" -gt 0 ] || { log_error "--machine-id 必须是正整数"; exit 1; }
    case "$PANEL_URL" in
        http://*|https://*) ;;
        *) PANEL_URL="https://${PANEL_URL}" ;;
    esac
    case "$HEALTH_PORT" in
        ''|*[!0-9]*) log_error "--health-port 必须是 0-65535 的整数"; exit 1 ;;
    esac
}

# YAML 双引号转义
yaml_quote() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# systemd EnvironmentFile 值转义（双引号内）
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
    curl -fSL --retry 3 -o "$path" "$url" || { log_error "下载失败: $url"; exit 1; }
    tar tzf "$path" >/dev/null 2>&1 || { log_error "压缩包损坏: $ASSET"; exit 1; }
    tar xzf "$path" -C "$TMP_DIR"
    [ -f "${TMP_DIR}/${APP_NAME}" ] || { log_error "压缩包内未找到 ${APP_NAME}"; exit 1; }
    chmod 755 "${TMP_DIR}/${APP_NAME}"
}

render_config() {
    local panel_yaml health license_block=""
    panel_yaml="$(yaml_quote "$PANEL_URL")"
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
    cat >"${TMP_DIR}/config.yml" <<EOF
# ${APP_NAME} configuration — managed by install.sh (machine mode)
panel:
  url: ${panel_yaml}

machine:
  machine_id: ${MACHINE_ID}
  token: ""                 # token 读取自 credentials.env 的 MACHINE_TOKEN
  token_env: MACHINE_TOKEN

log:
  level: $(yaml_quote "$LOG_LEVEL")

ws:
  url: ""
  status_interval: 10
  handshake_timeout: 15
  backoff_initial: 1
  backoff_max: 60

node:
  report_interval: 60
  health_port: ${HEALTH_PORT}

limits:
  device_limit: true
  speed_limit: true

cert:
  dir: "${DATA_DIR}/certs"
${license_block}
EOF
    printf 'MACHINE_TOKEN=%s\n' "$(env_quote "$TOKEN")" >"${TMP_DIR}/credentials.env"
    chmod 600 "${TMP_DIR}/credentials.env"
}

render_service() {
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
    install -m 644 "${TMP_DIR}/service" "$SERVICE_PATH"
    systemctl daemon-reload
}

wait_for_health() {
    if [ "$HEALTH_PORT" = "0" ]; then return 0; fi
    local i=0
    while [ "$i" -lt 30 ]; do
        if systemctl is-active --quiet "$SERVICE_NAME" && \
           curl -fsS "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

start_service() {
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    if ! wait_for_health; then
        log_error "服务健康检查失败"
        journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager || true
        return 1
    fi
}

perform_install() {
    check_root; check_systemd; validate_install; detect_asset
    TMP_DIR="$(mktemp -d)"; BACKUP_DIR="${TMP_DIR}/backup"
    ensure_dirs
    stage_binary
    render_config
    render_service
    backup_existing
    install_files
    start_service
    log_info "安装完成"
    log_info "服务: systemctl status ${SERVICE_NAME}"
    log_info "配置: ${CONFIG_FILE}（权限 600）"
    log_info "凭证: ${CREDENTIALS_FILE}（权限 600）"
    if [ "$HEALTH_PORT" != "0" ]; then
        log_info "健康检查: http://127.0.0.1:${HEALTH_PORT}/healthz"
    fi
    if [ -z "$LICENSE_KEY" ]; then
        log_warn "未提供 --license-key，配置中未启用商业授权校验"
    fi
}

perform_upgrade() {
    check_root; check_systemd; detect_asset
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
    check_root; check_systemd
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH" "$BINARY_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$INSTALL_ROOT"
        log_info "已卸载（含配置目录 ${INSTALL_ROOT}）"
    else
        log_info "已卸载（配置保留在 ${INSTALL_ROOT}）"
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
    if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        systemctl status "${SERVICE_NAME}.service" --no-pager || true
    else
        log_warn "未找到服务单元"
    fi
}

main() {
    parse_args "$@"
    case "$ACTION" in
        install)   perform_install   ;;
        upgrade)   perform_upgrade   ;;
        uninstall) perform_uninstall ;;
        status)    perform_status    ;;
        help)      usage             ;;
        *) log_error "未知操作: $ACTION"; usage; exit 1 ;;
    esac
}

main "$@"
