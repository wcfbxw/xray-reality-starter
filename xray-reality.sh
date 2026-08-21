#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_XRAY_VERSION="v26.3.27"
readonly INSTALLER_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
readonly INSTALLER_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
readonly INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${INSTALLER_COMMIT}/install-release.sh"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly STATE_DIR="/usr/local/etc/xray-reality"
readonly STATE_FILE="${STATE_DIR}/state.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly MANAGER_BIN="/usr/local/sbin/xray-reality"

COMMAND="install"
PORT="${PORT:-443}"
SNI="${SNI:-learn.microsoft.com}"
ADDRESS="${ADDRESS:-}"
LISTEN="${LISTEN:-}"
UUID="${UUID:-}"
XRAY_VERSION="${XRAY_VERSION:-${DEFAULT_XRAY_VERSION}}"
FINGERPRINT="${FINGERPRINT:-chrome}"
ASSUME_YES=0
ENABLE_BBR=0
BACKUP_CONFIG=""
DOWNLOADED_INSTALLER=""
TEMP_FILES=()

info() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  local path
  for path in "${TEMP_FILES[@]:-}"; do
    [[ -n "${path}" && -e "${path}" ]] && rm -f -- "${path}"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
用法：
  xray-reality.sh install [选项]
  xray-reality.sh update [--version VERSION] [--yes]
  xray-reality.sh show
  xray-reality.sh status
  xray-reality.sh uninstall [--yes]

安装选项：
  --port PORT          入站端口，默认 443
  --sni DOMAIN         REALITY 目标域名，默认 learn.microsoft.com
  --address ADDRESS    客户端连接的公网 IP 或域名，默认自动探测
  --listen ADDRESS     服务端监听地址，默认根据公网地址选择 0.0.0.0 或 ::
  --uuid UUID          指定 UUID，默认由 Xray 随机生成
  --version VERSION    Xray 版本，默认 v26.3.27
  --fingerprint NAME   客户端指纹，默认 chrome
  --enable-bbr         写入独立的 BBR sysctl 配置
  --yes                非交互确认
  -h, --help           显示帮助

环境变量也可以使用同名的大写变量，例如 PORT、SNI、ADDRESS、XRAY_VERSION。
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 权限运行。"
}

require_linux_systemd() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux。"
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "当前仅支持 Debian 和 Ubuntu，检测到：${ID:-unknown}" ;;
  esac

  command -v systemctl >/dev/null 2>&1 || die "系统没有 systemd。"
}

confirm() {
  local prompt="$1"
  (( ASSUME_YES == 1 )) && return 0
  [[ -t 0 ]] || die "非交互运行必须添加 --yes。"

  local answer
  read -r -p "${prompt} [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "操作已取消。"
}

validate_port() {
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  PORT=$((10#${PORT}))
  (( PORT >= 1 && PORT <= 65535 )) || die "端口必须在 1-65535 之间。"
}

validate_domain() {
  [[ ${#SNI} -le 253 && "${SNI}" != *..* ]] || die "SNI 域名格式错误。"
  local label
  local labels=()
  local old_ifs="${IFS}"
  IFS='.' read -r -a labels <<<"${SNI}"
  IFS="${old_ifs}"
  ((${#labels[@]} >= 2)) || die "SNI 必须是完整域名。"
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || \
      die "SNI 域名标签无效：${label}"
  done
}

validate_uuid() {
  [[ -z "${UUID}" ]] && return 0
  [[ "${UUID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || \
    die "UUID 格式错误。"
}

validate_version() {
  [[ "${XRAY_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本格式应类似 v26.3.27。"
}

validate_address() {
  [[ -z "${ADDRESS}" ]] && return 0
  [[ "${ADDRESS}" != *[[:space:]/\?\&\#]* ]] || die "公网地址包含不允许的字符。"
}

validate_listen() {
  [[ -z "${LISTEN}" ]] && return 0
  [[ "${LISTEN}" =~ ^[0-9A-Fa-f:.]+$ ]] || die "监听地址必须是 IPv4 或 IPv6 地址。"
}

validate_fingerprint() {
  case "${FINGERPRINT}" in
    chrome|firefox|safari|edge|random|randomized) ;;
    *) die "不支持的指纹：${FINGERPRINT}" ;;
  esac
}

validate_install_options() {
  validate_port
  validate_domain
  validate_uuid
  validate_version
  validate_address
  validate_listen
  validate_fingerprint
}

install_dependencies() {
  info "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl jq openssl qrencode iproute2
}

download_installer() {
  local target
  target="$(mktemp)"
  TEMP_FILES+=("${target}")

  info "下载固定提交的 Xray 官方安装器" >&2
  curl --fail --location --silent --show-error --retry 3 \
    "${INSTALLER_URL}" --output "${target}"
  printf '%s  %s\n' "${INSTALLER_SHA256}" "${target}" | sha256sum --check --status || \
    die "官方安装器 SHA-256 校验失败。"
  DOWNLOADED_INSTALLER="${target}"
}

install_xray_core() {
  download_installer
  info "安装 Xray ${XRAY_VERSION}"
  bash "${DOWNLOADED_INSTALLER}" install --version "${XRAY_VERSION}"
  [[ -x "${XRAY_BIN}" ]] || die "Xray 安装失败。"
}

detect_public_address() {
  [[ -n "${ADDRESS}" ]] && return 0

  ADDRESS="$(curl -4 --fail --silent --show-error --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ADDRESS}" ]]; then
    ADDRESS="$(curl -6 --fail --silent --show-error --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
  fi
  [[ -n "${ADDRESS}" ]] || die "无法自动探测公网地址，请使用 --address 指定。"
  validate_address
}

select_listen_address() {
  [[ -n "${LISTEN}" ]] && return 0
  if [[ "${ADDRESS}" == *:* ]]; then
    LISTEN="::"
  else
    LISTEN="0.0.0.0"
  fi
}

check_target() {
  info "检查 REALITY 目标 ${SNI}:443"
  if ! timeout 10 openssl s_client -brief -tls1_3 -alpn h2 \
    -connect "${SNI}:443" -servername "${SNI}" </dev/null >/dev/null 2>&1; then
    warn "目标的 TLS 1.3/h2 检查没有成功；部署可以继续，但应确认目标可从服务器直连。"
  fi
}

warn_if_port_is_busy() {
  local listeners
  listeners="$(ss -ltnH 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {print}' || true)"
  if [[ -n "${listeners}" ]]; then
    warn "端口 ${PORT} 已有监听："
    printf '%s\n' "${listeners}" >&2
    confirm "仍然继续并尝试重启 Xray？"
  fi
}

generate_credentials() {
  if [[ -z "${UUID}" ]]; then
    UUID="$("${XRAY_BIN}" uuid)"
  fi
  validate_uuid

  local key_output
  key_output="$("${XRAY_BIN}" x25519)"
  PRIVATE_KEY="$(awk -F': *' 'tolower($1) ~ /private/ {print $NF; exit}' <<<"${key_output}")"
  PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /password|public/ {print $NF; exit}' <<<"${key_output}")"
  SHORT_ID="$(openssl rand -hex 8)"

  [[ "${PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43,44}$ ]] || die "无法解析 X25519 私钥。"
  [[ "${PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]{43,44}$ ]] || die "无法解析 X25519 公钥。"
  [[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die "Short ID 生成失败。"
}

backup_existing_config() {
  [[ -f "${XRAY_CONFIG}" ]] || return 0
  install -d -m 0700 "${BACKUP_DIR}"
  BACKUP_CONFIG="${BACKUP_DIR}/config.json.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a -- "${XRAY_CONFIG}" "${BACKUP_CONFIG}"
  info "原配置已备份到 ${BACKUP_CONFIG}"
}

build_config() {
  local target="$1"
  jq -n \
    --arg listen "${LISTEN}" \
    --argjson port "${PORT}" \
    --arg uuid "${UUID}" \
    --arg sni "${SNI}" \
    --arg private_key "${PRIVATE_KEY}" \
    --arg short_id "${SHORT_ID}" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        listen: $listen,
        port: $port,
        protocol: "vless",
        settings: {
          clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
          decryption: "none"
        },
        streamSettings: {
          network: "tcp",
          security: "reality",
          realitySettings: {
            show: false,
            dest: ($sni + ":443"),
            xver: 0,
            serverNames: [$sni],
            privateKey: $private_key,
            shortIds: [$short_id]
          }
        },
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls", "quic"],
          routeOnly: true
        }
      }],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ],
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: [{type: "field", ip: ["geoip:private"], outboundTag: "block"}]
      }
    }' >"${target}"
}

config_group() {
  local service_user
  service_user="$(systemctl show xray.service --property=User --value 2>/dev/null || true)"
  [[ -n "${service_user}" ]] || service_user="root"
  id -gn "${service_user}" 2>/dev/null || printf 'root\n'
}

activate_config() {
  local candidate group
  candidate="$(mktemp)"
  TEMP_FILES+=("${candidate}")
  build_config "${candidate}"

  info "校验 Xray 配置"
  "${XRAY_BIN}" run -test -config "${candidate}"

  backup_existing_config
  install -d -m 0755 "$(dirname "${XRAY_CONFIG}")"
  group="$(config_group)"
  install -o root -g "${group}" -m 0640 "${candidate}" "${XRAY_CONFIG}"

  systemctl daemon-reload
  systemctl enable xray.service >/dev/null
  if ! systemctl restart xray.service; then
    warn "Xray 启动失败，正在恢复旧配置。"
    if [[ -n "${BACKUP_CONFIG}" && -f "${BACKUP_CONFIG}" ]]; then
      cp -a -- "${BACKUP_CONFIG}" "${XRAY_CONFIG}"
      systemctl restart xray.service || true
    else
      rm -f -- "${XRAY_CONFIG}"
    fi
    journalctl -u xray.service --no-pager -n 50 >&2 || true
    die "部署失败。"
  fi
  systemctl is-active --quiet xray.service || die "Xray 服务未进入 active 状态。"
}

enable_bbr() {
  (( ENABLE_BBR == 1 )) || return 0
  info "启用 BBR + fq"
  cat >/etc/sysctl.d/99-xray-reality-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  printf 'tcp_bbr\n' >/etc/modules-load.d/xray-reality-bbr.conf
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null
}

write_state() {
  local candidate
  candidate="$(mktemp)"
  TEMP_FILES+=("${candidate}")
  install -d -m 0700 "${STATE_DIR}"

  jq -n \
    --arg address "${ADDRESS}" \
    --argjson port "${PORT}" \
    --arg sni "${SNI}" \
    --arg listen "${LISTEN}" \
    --arg uuid "${UUID}" \
    --arg public_key "${PUBLIC_KEY}" \
    --arg short_id "${SHORT_ID}" \
    --arg fingerprint "${FINGERPRINT}" \
    --arg xray_version "${XRAY_VERSION}" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson bbr "$([[ ${ENABLE_BBR} -eq 1 ]] && printf true || printf false)" \
    '{address: $address, port: $port, sni: $sni, listen: $listen,
      uuid: $uuid, public_key: $public_key, short_id: $short_id,
      fingerprint: $fingerprint, xray_version: $xray_version,
      installed_at: $installed_at, bbr: $bbr}' >"${candidate}"
  install -o root -g root -m 0600 "${candidate}" "${STATE_FILE}"
}

install_manager() {
  local source_path="${BASH_SOURCE[0]}"
  if [[ -r "${source_path}" ]]; then
    install -o root -g root -m 0755 "${source_path}" "${MANAGER_BIN}"
  else
    warn "无法安装管理命令；请保留当前脚本。"
  fi
}

state_value() {
  local key="$1"
  jq -er ".${key}" "${STATE_FILE}"
}

client_uri() {
  [[ -r "${STATE_FILE}" ]] || die "没有找到部署状态：${STATE_FILE}"
  local address port sni uuid public_key short_id fingerprint host
  address="$(state_value address)"
  port="$(state_value port)"
  sni="$(state_value sni)"
  uuid="$(state_value uuid)"
  public_key="$(state_value public_key)"
  short_id="$(state_value short_id)"
  fingerprint="$(state_value fingerprint)"
  host="${address}"
  [[ "${address}" == *:* && "${address}" != \[*\] ]] && host="[${address}]"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s#My-Reality\n' \
    "${uuid}" "${host}" "${port}" "${sni}" "${fingerprint}" "${public_key}" "${short_id}"
}

show_config() {
  require_root
  command -v jq >/dev/null 2>&1 || die "缺少 jq。"
  [[ -r "${STATE_FILE}" ]] || die "尚未安装或状态文件不存在。"
  local uri
  uri="$(client_uri)"
  printf '\n地址: %s\n端口: %s\nSNI: %s\nUUID: %s\n公钥: %s\nShort ID: %s\n版本: %s\n\n%s\n\n' \
    "$(state_value address)" "$(state_value port)" "$(state_value sni)" \
    "$(state_value uuid)" "$(state_value public_key)" "$(state_value short_id)" \
    "$(state_value xray_version)" "${uri}"
  command -v qrencode >/dev/null 2>&1 && qrencode -t UTF8 "${uri}"
}

show_status() {
  require_root
  systemctl status xray.service --no-pager
}

update_xray() {
  require_root
  require_linux_systemd
  [[ -r "${STATE_FILE}" ]] || die "没有找到现有安装状态。"
  validate_version
  confirm "将 Xray 更新/切换到 ${XRAY_VERSION}，继续？"
  install_dependencies
  install_xray_core
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"
  systemctl restart xray.service
  systemctl is-active --quiet xray.service || die "更新后 Xray 未正常运行。"

  local candidate
  candidate="$(mktemp)"
  TEMP_FILES+=("${candidate}")
  jq --arg version "${XRAY_VERSION}" '.xray_version = $version' "${STATE_FILE}" >"${candidate}"
  install -o root -g root -m 0600 "${candidate}" "${STATE_FILE}"
  install_manager
  info "Xray 已更新到 ${XRAY_VERSION}"
}

uninstall_all() {
  require_root
  require_linux_systemd
  confirm "将卸载 Xray 并删除本项目的配置与状态，继续？"
  install_dependencies
  download_installer
  bash "${DOWNLOADED_INSTALLER}" remove --purge

  local preserved_state=""
  if [[ -d "${STATE_DIR}" ]]; then
    preserved_state="/root/xray-reality-state-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a -- "${STATE_DIR}" "${preserved_state}"
    chmod -R go-rwx "${preserved_state}"
  fi
  rm -f -- /etc/sysctl.d/99-xray-reality-bbr.conf
  rm -f -- /etc/modules-load.d/xray-reality-bbr.conf
  rm -rf -- "${STATE_DIR}"
  rm -f -- "${MANAGER_BIN}"
  info "卸载完成。"
  [[ -n "${preserved_state}" ]] && info "原状态和备份保存在 ${preserved_state}"
}

run_install() {
  require_root
  require_linux_systemd
  validate_install_options

  [[ -f "${XRAY_CONFIG}" ]] && warn "现有 ${XRAY_CONFIG} 将先备份，再由新配置替换。"
  printf '\n将部署：Xray %s / VLESS + TCP + REALITY + Vision\n端口：%s\nSNI：%s\n\n' \
    "${XRAY_VERSION}" "${PORT}" "${SNI}"
  confirm "继续安装？"

  install_dependencies
  check_target
  warn_if_port_is_busy
  install_xray_core
  detect_public_address
  select_listen_address
  generate_credentials
  activate_config
  enable_bbr
  write_state
  install_manager

  info "部署完成。管理命令：xray-reality show|status|update|uninstall"
  warn "脚本不会自动修改防火墙，请确认 TCP ${PORT} 已放行。"
  show_config
}

parse_args() {
  if (($# > 0)) && [[ "$1" != -* ]]; then
    COMMAND="$1"
    shift
  fi

  while (($# > 0)); do
    case "$1" in
      --port) [[ $# -ge 2 ]] || die "--port 缺少值"; PORT="$2"; shift 2 ;;
      --sni) [[ $# -ge 2 ]] || die "--sni 缺少值"; SNI="$2"; shift 2 ;;
      --address) [[ $# -ge 2 ]] || die "--address 缺少值"; ADDRESS="$2"; shift 2 ;;
      --listen) [[ $# -ge 2 ]] || die "--listen 缺少值"; LISTEN="$2"; shift 2 ;;
      --uuid) [[ $# -ge 2 ]] || die "--uuid 缺少值"; UUID="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || die "--version 缺少值"; XRAY_VERSION="$2"; shift 2 ;;
      --fingerprint) [[ $# -ge 2 ]] || die "--fingerprint 缺少值"; FINGERPRINT="$2"; shift 2 ;;
      --enable-bbr) ENABLE_BBR=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "${COMMAND}" in
    install) run_install ;;
    show) show_config ;;
    status) show_status ;;
    update) update_xray ;;
    uninstall) uninstall_all ;;
    help) usage ;;
    *) usage >&2; die "未知命令：${COMMAND}" ;;
  esac
}

main "$@"
