#!/bin/bash
# ===========================================
# VPS 流量监控系统 — VTL 安装器 v5.0
# 自包含安装脚本，从自身所在目录读取引擎文件
# 依赖: 同目录下的 bin/ lib/ config
# ===========================================

set -e

# ─── 颜色定义 ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── 全局变量 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/vps-traffic-limit"
GITHUB_RAW="https://raw.githubusercontent.com/guihuatu2022/vps-traffic-limit/main/src"
BIN_DIR="${INSTALL_DIR}/bin"
LIB_DIR="${INSTALL_DIR}/lib"
CONF_DIR="${INSTALL_DIR}/conf"

# 默认值
INTERFACE=""
SSH_PORTS=""
LIMIT_GB=""
DIRECTION="egress"
MODE="strict"
EXTRA_PORTS=""
IPV6_POLICY="dual"
PROVIDER_TIMEZONE="UTC"
RESET_DAY=1
NOTIFY_CHANNEL="none"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
WECHAT_WEBHOOK_URL=""
EMAIL_SMTP_SERVER=""
EMAIL_SMTP_PORT="465"
EMAIL_SMTP_USER=""
EMAIL_SMTP_PASS=""
EMAIL_FROM=""
EMAIL_TO=""
SERVERCHAN_KEY=""
CMD_LLCX="llcx"
DRY_RUN=false
AUTO_YES=false

# ─── 辅助输出函数 ──────────────────────────────────────────

install_echo() {
    echo -e "$1"
}

# 渲染水平线
_hr() {
    local ch="${1:-─}"
    local width=60
    local i
    for ((i = 0; i < width; i++)); do
        echo -n "$ch"
    done
    echo
}

# ─────────────────────────────────────
# 自动检测并安装所有系统依赖
# 检查: vnstat, python3, curl, iptables
# 缺失则自动 apt install
# ─────────────────────────────────────
install_auto_deps() {
    local deps_install_list=()
    local dep_items=(
        "vnstat:vnstat"
        "python3:python3"
        "curl:curl"
        "iptables:iptables"
    )

    install_echo "    ├─ apt-get update..."
    apt-get update -qq > /dev/null 2>&1 || \
        install_echo "    ${YELLOW}│  ⚠️  apt-get update 失败，继续尝试${NC}"

    for item in "${dep_items[@]}"; do
        local name="${item%%:*}"
        local cmd="${item##*:}"
        if command -v "$cmd" >/dev/null 2>&1; then
            install_echo "    ${GREEN}├─ ✅ $name 已存在${NC}"
        else
            install_echo "    ${YELLOW}├─ ⚠️  $name 未安装，正在安装...${NC}"
            if apt-get install -y "$name" > /dev/null 2>&1; then
                install_echo "    ${GREEN}│  ✅ $name 安装成功${NC}"
            else
                install_echo "    ${RED}│  ❌ $name 安装失败${NC}"
                deps_install_list+=("$name")
            fi
        fi
    done

    if [ ${#deps_install_list[@]} -gt 0 ]; then
        install_echo ""
        install_echo "${YELLOW}⚠️  以下依赖安装失败，部分功能可能受限:${NC}"
        for dep in "${deps_install_list[@]}"; do
            install_echo "    - apt-get install $dep"
        done
        install_echo ""
        install_echo "${YELLOW}⚠️  请手动安装后重新运行脚本${NC}"
    fi
}

# ─────────────────────────────────────
# 安装前置检查: root + OS + 架构
# ─────────────────────────────────────
install_precheck() {
    install_echo ""
    install_echo "  ${CYAN}┌─ 前置检查 ─────────────────────────────┐${NC}"

    # 检查 root
    install_echo "    ├─ 检查 root 权限..."
    if [ "$(id -u)" -ne 0 ]; then
        install_echo "    ${RED}│  ❌ 请使用 root 用户运行此脚本 (sudo su)${NC}"
        install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
        exit 1
    fi
    install_echo "    ${GREEN}│  ✅ root 权限正常${NC}"

    # 检查 OS
    install_echo "    ├─ 检查操作系统..."
    local os_ok=0
    if [ -f /etc/os-release ]; then
        local os_id
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        case "$os_id" in
            debian|ubuntu) os_ok=1 ;;
        esac
    fi
    if [ "$os_ok" -eq 0 ]; then
        install_echo "    ${YELLOW}│  ⚠️  当前系统可能不是 Debian/Ubuntu${NC}"
        install_echo "    ${YELLOW}│     脚本可能在 apt-get 步骤失败${NC}"
    else
        install_echo "    ${GREEN}│  ✅ 操作系统支持${NC}"
    fi

    # 检查架构
    install_echo "    ├─ 检查系统架构..."
    local arch
    arch=$(uname -m)
    install_echo "    ${GREEN}│  ✅ 架构: $arch${NC}"

    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 选择网卡
# ─────────────────────────────────────
install_select_interface() {
    [ -n "$INTERFACE" ] && return 0

    install_echo "  ${CYAN}┌─ 检测网卡 ─────────────────────────────┐${NC}"
    install_echo "    ├─ 检测主网卡..."

    # 检测默认路由网卡
    local detected_iface
    detected_iface=$(ip route | grep '^default' | head -1 | awk '{print $5}')
    if [ -z "$detected_iface" ]; then
        # 兜底：列出所有非 lo 网卡
        detected_iface=$(ip link show | grep -v 'lo' | grep -E '^[0-9]+:' | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    fi
    install_echo "    ${GREEN}│  ✅ 检测到: ${detected_iface:-未知}${NC}"

    # 列出所有网卡
    install_echo "    │"
    install_echo "    ├─ 可用网卡:"
    local ifaces
    ifaces=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | awk '{print $1}')
    local count=0
    local iface_list=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        count=$((count + 1))
        iface_list+=("$line")
        local marker="  "
        [ "$line" = "$detected_iface" ] && marker="→"
        install_echo "    │     ${count}) ${marker} $line"
    done <<< "$ifaces"

    if [ "$count" -eq 0 ]; then
        install_echo "    ${RED}│  ❌ 未检测到任何网卡${NC}"
        install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
        exit 1
    fi

    install_echo "    │"
    install_echo -n "    └─ 选择网卡编号 [默认 1]: "
    read -r iface_choice || true
    [ -z "$iface_choice" ] && iface_choice=1

    # 检查选择是否在范围内 (bash if 条件)
    if [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "$count" ] 2>/dev/null; then
        local idx=$((iface_choice - 1))
        INTERFACE="${iface_list[$idx]}"
    else
        install_echo "    ${YELLOW}│  ⚠️  输入无效，使用默认: ${detected_iface}${NC}"
        INTERFACE="$detected_iface"
    fi

    install_echo "    ${GREEN}│  ✅ 已选择网卡: ${INTERFACE}${NC}"
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 检测 SSH 端口
# ─────────────────────────────────────
install_detect_ssh() {
    [ -n "$SSH_PORTS" ] && return 0

    install_echo "  ${CYAN}┌─ 检测 SSH 端口 ────────────────────────┐${NC}"

    local detected_ssh=""
    # 方法1: sshd -T 获取实际生效端口
    if command -v sshd >/dev/null 2>&1; then
        detected_ssh=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi

    # 方法2: 读取配置文件
    if [ -z "$detected_ssh" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_ssh=$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    fi

    # 兜底
    [ -z "$detected_ssh" ] && detected_ssh="22"

    install_echo "    ${GREEN}│  ✅ 检测到 SSH 端口: ${detected_ssh}${NC}"
    install_echo -n "    └─ 确认或修改 [${detected_ssh}]: "
    read -r ssh_input || true
    [ -z "$ssh_input" ] && ssh_input="$detected_ssh"

    # 校验端口
    local saved_ifs="$IFS"
    local port_valid=1
    IFS=','
    for p in $ssh_input; do
        IFS="$saved_ifs"
        p=$(echo "$p" | xargs)
        if ! echo "$p" | grep -qE '^[0-9]+$' || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            port_valid=0
            break
        fi
    done
    IFS="$saved_ifs"

    if [ "$port_valid" -eq 1 ]; then
        SSH_PORTS="$ssh_input"
        install_echo "    ${GREEN}│  ✅ SSH 端口已确认: ${SSH_PORTS}${NC}"
    else
        install_echo "    ${YELLOW}│  ⚠️  输入无效，使用: ${detected_ssh}${NC}"
        SSH_PORTS="$detected_ssh"
    fi
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 配置流量限额
# ─────────────────────────────────────
install_configure_limit() {
    [ -n "$LIMIT_GB" ] && return 0

    install_echo "  ${CYAN}┌─ 流量限额配置 ────────────────────────┐${NC}"
    install_echo "    ├─ 请输入您的 VPS 每月流量限额"
    install_echo "    │   (通常可以在云厂商控制台查看)"
    install_echo -n "    └─ 每月流量限额 (GB): "
    read -r limit_input || true

    # 校验正整数
    if echo "$limit_input" | grep -qE '^[1-9][0-9]*$'; then
        LIMIT_GB="$limit_input"
    else
        install_echo "    ${YELLOW}│  ⚠️  输入无效，使用默认: 170GB${NC}"
        LIMIT_GB=170
    fi
    install_echo "    ${GREEN}│  ✅ 流量限额: ${LIMIT_GB} GB${NC}"
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 选择锁定模式
# ─────────────────────────────────────
install_select_mode() {
    [ -n "$MODE" ] && [ "$MODE" = "strict" ] && [ "$#" -ge 1 ] && [ "$1" = "non-interactive" ] && return 0

    install_echo "  ${CYAN}┌─ 锁定模式选择 ────────────────────────┐${NC}"
    install_echo "    │"
    install_echo "    │  1) strict — 仅放行 SSH 和 DNS"
    install_echo "    │     超限后仅保留 SSH 连接和 DNS 解析"
    install_echo "    │"
    install_echo "    │  2) custom — 放行 SSH + DNS + 自定义端口"
    install_echo "    │     如需要保留 Web 服务(80/443)等"
    install_echo "    │"
    install_echo -n "    └─ 选择 [1] strict / [2] custom [默认 1]: "
    read -r mode_choice || true

    case "$mode_choice" in
        2|custom)
            MODE="custom"
            ;;
        1|strict|"")
            MODE="strict"
            ;;
        *)
            install_echo "    ${YELLOW}│  ⚠️  输入无效，使用默认: strict${NC}"
            MODE="strict"
            ;;
    esac
    install_echo "    ${GREEN}│  ✅ 锁定模式: ${MODE}${NC}"
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 配置自定义端口 (仅 custom 模式)
# ─────────────────────────────────────
install_configure_ports() {
    [ "$MODE" != "custom" ] && return 0
    [ -n "$EXTRA_PORTS" ] && return 0

    install_echo "  ${CYAN}┌─ 自定义放行端口 ──────────────────────┐${NC}"
    install_echo "    ├─ 请输入需要放行的端口"
    install_echo "    │  格式: 80,443,30000-50000"
    install_echo "    │  支持逗号分隔的单端口和范围"
    install_echo -n "    └─ 放行端口: "
    read -r ports_input || true

    # 校验端口
    local port_valid=1
    local saved_ifs="$IFS"
    IFS=','
    for item in $ports_input; do
        IFS="$saved_ifs"
        item=$(echo "$item" | xargs)
        if echo "$item" | grep -qE '^[0-9]+-[0-9]+$'; then
            local s e
            s=$(echo "$item" | cut -d- -f1)
            e=$(echo "$item" | cut -d- -f2)
            if [ "$s" -lt 1 ] || [ "$s" -gt 65535 ] || [ "$e" -lt 1 ] || [ "$e" -gt 65535 ] || [ "$s" -ge "$e" ]; then
                port_valid=0
                break
            fi
        elif echo "$item" | grep -qE '^[0-9]+$'; then
            if [ "$item" -lt 1 ] || [ "$item" -gt 65535 ]; then
                port_valid=0
                break
            fi
        else
            port_valid=0
            break
        fi
    done
    IFS="$saved_ifs"

    if [ "$port_valid" -eq 1 ] && [ -n "$ports_input" ]; then
        EXTRA_PORTS="$ports_input"
        install_echo "    ${GREEN}│  ✅ 放行端口: ${EXTRA_PORTS}${NC}"
    else
        if [ "$port_valid" -eq 1 ] && [ -z "$ports_input" ]; then
            install_echo "    ${YELLOW}│  ⚠️  未输入端口，仅放行 SSH+DNS${NC}"
        else
            install_echo "    ${YELLOW}│  ⚠️  端口格式无效，跳过${NC}"
        fi
        EXTRA_PORTS=""
    fi
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 选择计费方向
# ─────────────────────────────────────
install_select_direction() {
    [ -n "$DIRECTION" ] && [ "$DIRECTION" != "egress" ] && [ "$#" -ge 1 ] && [ "$1" = "non-interactive" ] && return 0

    install_echo "  ${CYAN}┌─ 计费方向 ────────────────────────────┐${NC}"
    install_echo "    │"
    install_echo "    │  1) egress  — 上行流量 (多数云厂商)"
    install_echo "    │  2) total   — 合计流量 (部分厂商)"
    install_echo "    │  3) ingress — 下行流量 (少见)"
    install_echo "    │"
    install_echo -n "    └─ 选择计费方向 [默认 1]: "
    read -r dir_choice || true

    case "$dir_choice" in
        2|total)
            DIRECTION="total"
            ;;
        3|ingress)
            DIRECTION="ingress"
            ;;
        1|egress|"")
            DIRECTION="egress"
            ;;
        *)
            install_echo "    ${YELLOW}│  ⚠️  输入无效，使用默认: egress${NC}"
            DIRECTION="egress"
            ;;
    esac
    install_echo "    ${GREEN}│  ✅ 计费方向: ${DIRECTION}${NC}"
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 防火墙检测
# ─────────────────────────────────────
install_detect_firewall() {
    install_echo "  ${CYAN}┌─ 防火墙检测 ──────────────────────────┐${NC}"
    install_echo "    ├─ 检测 iptables/ip6tables..."

    local ipt_avail=0
    local ip6_avail=0
    command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1 && ipt_avail=1
    command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1 && ip6_avail=1

    if [ "$ipt_avail" -eq 1 ]; then
        install_echo "    ${GREEN}│  ✅ iptables 可用${NC}"
    else
        install_echo "    ${RED}│  ❌ iptables 不可用${NC}"
    fi

    if [ "$ip6_avail" -eq 1 ]; then
        install_echo "    ${GREEN}│  ✅ ip6tables 可用${NC}"
    else
        install_echo "    ${YELLOW}│  ⚠️  ip6tables 不可用 (IPv6 放行将受限)${NC}"
    fi

    if [ "$ipt_avail" -eq 0 ]; then
        install_echo "    ${RED}│  ❌ iptables 不可用，无法使用锁定功能！${NC}"
        install_echo "    ${YELLOW}│     请安装 iptables: apt-get install iptables${NC}"
    fi

    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 配置通知渠道
# ─────────────────────────────────────
install_configure_notify() {
    [ "$NOTIFY_CHANNEL" != "none" ] && return 0

    install_echo "  ${CYAN}┌─ 通知渠道配置 ────────────────────────┐${NC}"
    install_echo "    │"
    install_echo "    │  0) none      — 不配置通知"
    install_echo "    │  1) telegram  — Telegram Bot"
    install_echo "    │  2) wechat    — 企业微信机器人"
    install_echo "    │  3) email     — SMTP 邮件"
    install_echo "    │  4) serverchan — Server酱"
    install_echo "    │"
    install_echo -n "    └─ 选择通知渠道 [默认 0]: "
    read -r notify_choice || true

    case "$notify_choice" in
        1|telegram)
            NOTIFY_CHANNEL="telegram"
            install_echo ""
            install_echo "    ${CYAN}├─ Telegram 配置${NC}"
            echo -n "    ├─ Bot Token: "
            read -r token || true
            TELEGRAM_BOT_TOKEN="$token"
            echo -n "    ├─ Chat ID: "
            read -r chat_id || true
            TELEGRAM_CHAT_ID="$chat_id"
            install_echo "    ${GREEN}│  ✅ Telegram 已配置${NC}"
            ;;
        2|wechat)
            NOTIFY_CHANNEL="wechat"
            install_echo ""
            install_echo "    ${CYAN}├─ 企业微信配置${NC}"
            echo -n "    ├─ Webhook URL: "
            read -r webhook || true
            WECHAT_WEBHOOK_URL="$webhook"
            install_echo "    ${GREEN}│  ✅ 企业微信已配置${NC}"
            ;;
        3|email)
            NOTIFY_CHANNEL="email"
            install_echo ""
            install_echo "    ${CYAN}├─ 邮件 SMTP 配置${NC}"
            echo -n "    ├─ SMTP 服务器:端口 [smtp.example.com:465]: "
            read -r smtp || true
            if [ -n "$smtp" ]; then
                local smtp_server="${smtp%%:*}"
                local smtp_port="${smtp##*:}"
                EMAIL_SMTP_SERVER="$smtp_server"
                echo "$smtp_port" | grep -qE '^[0-9]+$' && EMAIL_SMTP_PORT="$smtp_port"
            fi
            echo -n "    ├─ SMTP 用户名: "
            read -r smtp_user || true
            EMAIL_SMTP_USER="$smtp_user"
            echo -n "    ├─ SMTP 密码: "
            read -r smtp_pass || true
            EMAIL_SMTP_PASS="$smtp_pass"
            echo -n "    ├─ 发件人地址 [${EMAIL_SMTP_USER}]: "
            read -r from || true
            [ -z "$from" ] && from="$EMAIL_SMTP_USER"
            EMAIL_FROM="$from"
            echo -n "    ├─ 收件人地址: "
            read -r to || true
            EMAIL_TO="$to"
            install_echo "    ${GREEN}│  ✅ 邮件已配置${NC}"
            ;;
        4|serverchan)
            NOTIFY_CHANNEL="serverchan"
            install_echo ""
            install_echo "    ${CYAN}├─ Server酱配置${NC}"
            echo -n "    ├─ SendKey: "
            read -r sckey || true
            SERVERCHAN_KEY="$sckey"
            install_echo "    ${GREEN}│  ✅ Server酱已配置${NC}"
            ;;
        0|none|"")
            NOTIFY_CHANNEL="none"
            install_echo "    ${GREEN}│  ✅ 未配置通知，可在安装后修改${NC}"
            ;;
        *)
            install_echo "    ${YELLOW}│  ⚠️  输入无效，跳过通知配置${NC}"
            NOTIFY_CHANNEL="none"
            ;;
    esac
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 配置快捷命令名
# ─────────────────────────────────────
install_configure_cmd() {
    install_echo "  ${CYAN}┌─ 快捷命令 ────────────────────────────┐${NC}"
    install_echo -n "    └─ 命令名称 [${CMD_LLCX}]: "
    read -r cmd_input || true
    [ -n "$cmd_input" ] && CMD_LLCX="$cmd_input"
    install_echo "    ${GREEN}│  ✅ 快捷命令: ${CMD_LLCX}${NC}"
    install_echo "    ${CYAN}└──────────────────────────────────────────┘${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 显示安装摘要
# ─────────────────────────────────────
install_show_summary() {
    install_echo ""
    install_echo "  ${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    install_echo "  ${BOLD}${CYAN}         VTL 安装配置摘要${NC}"
    install_echo "  ${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    install_echo ""
    install_echo "    ${BOLD}目标路径:${NC}"
    install_echo "    ├─ 安装目录:    ${INSTALL_DIR}"
    install_echo "    ├─ 配置文件:    ${CONF_DIR}/config"
    install_echo "    ├─ 快捷命令:    /usr/local/bin/${CMD_LLCX}"
    install_echo "    ├─ 日志文件:    /var/log/vtl-core.log"
    install_echo "    └─ 运行状态:    /run/vps-traffic-limit/"
    install_echo ""
    install_echo "    ${BOLD}基础配置:${NC}"
    install_echo "    ├─ 监控网卡:    ${INTERFACE}"
    install_echo "    ├─ SSH 端口:    ${SSH_PORTS}"
    install_echo "    ├─ 流量限额:    ${LIMIT_GB} GB (${DIRECTION})"
    install_echo "    ├─ 锁定模式:    ${MODE}"
    [ -n "$EXTRA_PORTS" ] && install_echo "    ├─ 额外放行:    ${EXTRA_PORTS}"
    install_echo "    └─ IPv6 策略:    ${IPV6_POLICY}"
    install_echo ""
    install_echo "    ${BOLD}通知:${NC}"
    case "$NOTIFY_CHANNEL" in
        telegram)
            install_echo "    ├─ 渠道:        Telegram"
            local masked="${TELEGRAM_BOT_TOKEN:0:8}...${TELEGRAM_BOT_TOKEN: -4}"
            install_echo "    ├─ Bot Token:   ${masked}"
            install_echo "    └─ Chat ID:     ${TELEGRAM_CHAT_ID}"
            ;;
        wechat)
            local masked="${WECHAT_WEBHOOK_URL:0:20}..."
            install_echo "    ├─ 渠道:        企业微信"
            install_echo "    └─ Webhook:     ${masked}"
            ;;
        email)
            install_echo "    ├─ 渠道:        邮件 SMTP"
            install_echo "    ├─ SMTP:        ${EMAIL_SMTP_SERVER}:${EMAIL_SMTP_PORT}"
            install_echo "    ├─ 发件人:      ${EMAIL_FROM}"
            install_echo "    └─ 收件人:      ${EMAIL_TO}"
            ;;
        serverchan)
            local masked="${SERVERCHAN_KEY:0:8}..."
            install_echo "    ├─ 渠道:        Server酱"
            install_echo "    └─ SendKey:     ${masked}"
            ;;
        *)
            install_echo "    └─ 渠道:        未配置"
            ;;
    esac
    install_echo ""
    install_echo "  ${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 生成 config 文件内容
# ─────────────────────────────────────
_generate_config() {
    cat <<-EOF
# /opt/vps-traffic-limit/conf/config
# ===========================================
# VTL 核心配置 v5.0
# 权限: 600 (root only)
# 由 install.sh 自动生成
# ===========================================

# [ 网络 ]
INTERFACE="${INTERFACE}"
SSH_PORTS="${SSH_PORTS}"

# [ 流量与计费 ]
LIMIT_GB=${LIMIT_GB}
DIRECTION="${DIRECTION}"

# [ 锁定策略 ]
MODE="${MODE}"
EXTRA_PORTS="${EXTRA_PORTS}"
IPV6_POLICY="${IPV6_POLICY}"

# [ 计费周期同步 ]
PROVIDER_TIMEZONE="${PROVIDER_TIMEZONE}"
RESET_DAY=${RESET_DAY}

# [ 通知 ]
NOTIFY_CHANNEL="${NOTIFY_CHANNEL}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
WECHAT_WEBHOOK_URL="${WECHAT_WEBHOOK_URL}"
EMAIL_SMTP_SERVER="${EMAIL_SMTP_SERVER}"
EMAIL_SMTP_PORT="${EMAIL_SMTP_PORT}"
EMAIL_SMTP_USER="${EMAIL_SMTP_USER}"
EMAIL_SMTP_PASS="${EMAIL_SMTP_PASS}"
EMAIL_FROM="${EMAIL_FROM}"
EMAIL_TO="${EMAIL_TO}"
SERVERCHAN_KEY="${SERVERCHAN_KEY}"

# [ 阈值 ]
WARN_PERCENT=80
CRIT_PERCENT=95

# [ 运行时常量 ]
VTL_CHAIN_NAME="VTL-LOCK"
LOCK_STATE_FILE="/run/vps-traffic-limit/locked.state"
LOCK_FILE="/run/vps-traffic-limit/vtl.lock"
LOG_FILE="/var/log/vtl-core.log"
CONF_DIR="${CONF_DIR}"
LIB_DIR="${LIB_DIR}"
EOF
}

# ─────────────────────────────────────
# 生成 systemd service 单元文件
# ─────────────────────────────────────
_generate_service() {
    cat <<-EOF
[Unit]
Description=VTL Core Defense Engine
After=network.target vnstat.service netfilter-persistent.service
Requires=vnstat.service

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/bin/${CMD_LLCX} cron-check
ExecStartPre=/bin/sleep 5
StandardOutput=null
StandardError=journal
PrivateDevices=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

_generate_timer() {
    cat <<-EOF
[Unit]
Description=VTL Periodic Check (every 3 minutes)

[Timer]
OnBootSec=1min
OnUnitActiveSec=3min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
}

_generate_logrotate() {
    cat <<-EOF
/var/log/vtl-core.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

# ─────────────────────────────────────
# 执行安装（9步）
# ─────────────────────────────────────
install_execute() {
    local install_start
    install_start=$(date +%s)

    install_echo ""
    install_echo "  ${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    install_echo "  ${BOLD}${CYAN}           开始安装 VTL v5.0${NC}"
    install_echo "  ${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    install_echo ""

    # ── [1/9] 自动检测并安装所有依赖 ──
    install_echo "  [1/9] 安装系统依赖..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] 跳过依赖安装${NC}"
    else
        install_auto_deps
    fi
    install_echo "    ${GREEN}╰─ ✅ 所有依赖已就绪${NC}"

    # ── [2/9] 创建目录结构 ──
    install_echo ""
    install_echo "  [2/9] 创建目录结构..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] mkdir -p ${BIN_DIR}${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] mkdir -p ${LIB_DIR}${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] mkdir -p ${CONF_DIR}${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] mkdir -p /run/vps-traffic-limit${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] mkdir -p /var/log${NC}"
    else
        mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONF_DIR" /run/vps-traffic-limit /var/log
        install_echo "    ├─ ${BIN_DIR}"
        install_echo "    ├─ ${LIB_DIR}"
        install_echo "    ├─ ${CONF_DIR}"
        install_echo "    ├─ /run/vps-traffic-limit"
        install_echo "    └─ /var/log"
    fi
    install_echo "    ${GREEN}╰─ ✅ 目录已创建${NC}"

    # ── [3/9] 复制引擎脚本 ──
    install_echo ""
    install_echo "  [3/9] 复制引擎脚本..."
    local src_files=(
        "bin/llcx:${BIN_DIR}/${CMD_LLCX}"
        "lib/common.sh:${LIB_DIR}/common.sh"
        "lib/engine_firewall.sh:${LIB_DIR}/engine_firewall.sh"
        "lib/engine_check.sh:${LIB_DIR}/engine_check.sh"
        "lib/engine_notify.sh:${LIB_DIR}/engine_notify.sh"
        "lib/engine_ui.sh:${LIB_DIR}/engine_ui.sh"
    )

    for entry in "${src_files[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        local src_path="${SCRIPT_DIR}/${src}"


        if [ ! -f "$src_path" ]; then
            # 本地不存在，尝试从 GitHub 下载
            local dl_url="${GITHUB_RAW}/${src}"
            install_echo "    ${YELLOW}├─ ⚠️  本地未找到 ${src}，尝试从 GitHub 下载...${NC}"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL -o "/tmp/vtl_$(echo "$src" | tr '/' '_')" "$dl_url" 2>/dev/null && {
                    mkdir -p "$(dirname "$src_path")"
                    cp "/tmp/vtl_$(echo "$src" | tr '/' '_')" "$src_path"
                    rm -f "/tmp/vtl_$(echo "$src" | tr '/' '_')"
                    install_echo "    ${GREEN}├─ ✅ 下载成功: ${src}${NC}"
                } || {
                    install_echo "    ${RED}├─ ❌ 下载失败: ${dl_url}${NC}"
                    install_echo "    ${RED}│   请检查网络或使用 git clone 方式安装${NC}"
                    exit 1
                }
            else
                install_echo "    ${RED}├─ ❌ 没有 curl 也无法找到本地 ${src}${NC}"
                install_echo "    ${RED}│   请先安装 curl 或使用 git clone 方式安装${NC}"
                exit 1
            fi
        fi
        if $DRY_RUN; then
            install_echo "    ${YELLOW}│  [DRY-RUN] cp ${src_path} → ${dst}${NC}"
        else
            cp "$src_path" "$dst"
            chmod 755 "$dst"
            install_echo "    ${GREEN}├─ ✅ ${src} → ${dst}${NC}"
        fi
    done

    # 如果 llcx 入口被重命名并且 bin/llcx 不是源文件，需额外处理
    if [ "$CMD_LLCX" != "llcx" ]; then
        # 如果源文件也改了名，上面的 cp 已经处理了
        # 否则 llcx 已作为 bin/llcx 复制到 BIN_DIR
        true
    fi

    install_echo "    ${GREEN}╰─ ✅ 引擎脚本已部署${NC}"

    # ── [4/9] 生成配置 ──
    install_echo ""
    install_echo "  [4/9] 生成配置文件..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] 生成: ${CONF_DIR}/config${NC}"
    else
        _generate_config > "${CONF_DIR}/config"
        chmod 600 "${CONF_DIR}/config"
        install_echo "    ${GREEN}├─ ✅ ${CONF_DIR}/config${NC}"
    fi
    install_echo "    ${GREEN}╰─ ✅ 配置已生成${NC}"

    # ── [5/9] 部署 systemd 单元 ──
    install_echo ""
    install_echo "  [5/9] 部署 systemd 单元..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] systemd: vtl-check.service${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] systemd: vtl-check.timer${NC}"
    else
        _generate_service > /etc/systemd/system/vtl-check.service
        _generate_timer > /etc/systemd/system/vtl-check.timer
        chmod 644 /etc/systemd/system/vtl-check.service
        chmod 644 /etc/systemd/system/vtl-check.timer
        systemctl daemon-reload 2>/dev/null || true
        install_echo "    ${GREEN}├─ ✅ /etc/systemd/system/vtl-check.service${NC}"
        install_echo "    ${GREEN}├─ ✅ /etc/systemd/system/vtl-check.timer${NC}"
    fi
    install_echo "    ${GREEN}╰─ ✅ systemd 单元已部署${NC}"

    # ── [6/9] 配置 logrotate ──
    install_echo ""
    install_echo "  [6/9] 配置日志轮转..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] logrotate: /etc/logrotate.d/vtl${NC}"
    else
        _generate_logrotate > /etc/logrotate.d/vtl
        chmod 644 /etc/logrotate.d/vtl
        install_echo "    ${GREEN}├─ ✅ /etc/logrotate.d/vtl${NC}"
    fi
    install_echo "    ${GREEN}╰─ ✅ 日志轮转已配置${NC}"

    # ── [7/9] 创建快捷命令 ──
    install_echo ""
    install_echo "  [7/9] 创建快捷命令..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] ln -sf ${BIN_DIR}/${CMD_LLCX} /usr/local/bin/${CMD_LLCX}${NC}"
    else
        if [ -L "/usr/local/bin/${CMD_LLCX}" ] || [ -f "/usr/local/bin/${CMD_LLCX}" ]; then
            install_echo "    ${YELLOW}│  ⚠️  已存在 /usr/local/bin/${CMD_LLCX}，将覆盖${NC}"
        fi
        ln -sf "${BIN_DIR}/${CMD_LLCX}" "/usr/local/bin/${CMD_LLCX}"
        install_echo "    ${GREEN}├─ ✅ /usr/local/bin/${CMD_LLCX} → ${BIN_DIR}/${CMD_LLCX}${NC}"
    fi
    install_echo "    ${GREEN}╰─ ✅ 快捷命令已创建${NC}"

    # ── [8/9] 启用并启动服务 ──
    install_echo ""
    install_echo "  [8/9] 启用并启动定时器..."
    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] systemctl enable vtl-check.timer${NC}"
        install_echo "    ${YELLOW}│  [DRY-RUN] systemctl start vtl-check.timer${NC}"
    else
        systemctl enable vtl-check.timer 2>/dev/null && \
            install_echo "    ${GREEN}├─ ✅ 定时器已启用${NC}" || \
            install_echo "    ${YELLOW}│  ⚠️  定时器启用失败，可稍后手动执行${NC}"
        systemctl start vtl-check.timer 2>/dev/null && \
            install_echo "    ${GREEN}├─ ✅ 定时器已启动${NC}" || \
            install_echo "    ${YELLOW}│  ⚠️  定时器启动失败，可稍后手动执行${NC}"
    fi
    install_echo "    ${GREEN}╰─ ✅ 服务已配置${NC}"

    # ── [9/9] 验证安装 ──
    install_echo ""
    install_echo "  [9/9] 验证安装..."
    local verify_ok=true

    if $DRY_RUN; then
        install_echo "    ${YELLOW}│  [DRY-RUN] 跳过验证${NC}"
    else
        # 验证文件存在
        local verify_files=(
            "${BIN_DIR}/${CMD_LLCX}"
            "${LIB_DIR}/common.sh"
            "${LIB_DIR}/engine_firewall.sh"
            "${LIB_DIR}/engine_check.sh"
            "${LIB_DIR}/engine_notify.sh"
            "${LIB_DIR}/engine_ui.sh"
            "${CONF_DIR}/config"
            "/etc/systemd/system/vtl-check.service"
            "/etc/systemd/system/vtl-check.timer"
            "/etc/logrotate.d/vtl"
        )
        for vf in "${verify_files[@]}"; do
            if [ -f "$vf" ]; then
                install_echo "    ${GREEN}├─ ✅ $vf${NC}"
            else
                install_echo "    ${RED}├─ ❌ $vf 不存在${NC}"
                verify_ok=false
            fi
        done

        # 验证快捷命令
        if [ -L "/usr/local/bin/${CMD_LLCX}" ] || [ -f "/usr/local/bin/${CMD_LLCX}" ]; then
            install_echo "    ${GREEN}├─ ✅ /usr/local/bin/${CMD_LLCX}${NC}"
        else
            install_echo "    ${RED}├─ ❌ /usr/local/bin/${CMD_LLCX} 不存在${NC}"
            verify_ok=false
        fi

        # 验证定时器状态
        if systemctl is-enabled vtl-check.timer >/dev/null 2>&1; then
            install_echo "    ${GREEN}├─ ✅ vtl-check.timer 已启用${NC}"
        else
            install_echo "    ${YELLOW}│  ⚠️  vtl-check.timer 未启用${NC}"
        fi
    fi

    if $verify_ok && ! $DRY_RUN; then
        install_echo "    ${GREEN}╰─ ✅ 验证完成，全部正常${NC}"
    elif $DRY_RUN; then
        install_echo "    ${YELLOW}╰─ [DRY-RUN] 验证跳过${NC}"
    else
        install_echo "    ${RED}╰─ ⚠️  部分文件缺失，请检查${NC}"
    fi

    local install_end
    install_end=$(date +%s)
    local duration=$((install_end - install_start))

    install_echo ""
    install_echo "  ${BOLD}${GREEN}═══ 安装 ${GREEN}${BOLD}阶段完成${NC} ${BOLD}${GREEN}(${duration}秒)${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 安装完成摘要
# ─────────────────────────────────────
install_finish() {
    if $DRY_RUN; then
        install_echo ""
        install_echo "  ${BOLD}${YELLOW}══════════════════════════════════════════${NC}"
        install_echo "  ${BOLD}${YELLOW}          Dry-Run 完成，无实际修改${NC}"
        install_echo "  ${BOLD}${YELLOW}══════════════════════════════════════════${NC}"
        return
    fi

    install_echo ""
    install_echo "  ${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
    install_echo "  ${BOLD}${GREEN}║       🎉 VTL v5.0 安装成功！              ║${NC}"
    install_echo "  ${BOLD}${GREEN}╠══════════════════════════════════════════════╣${NC}"
    install_echo "  ${BOLD}${GREEN}║  使用方式:                                  ║${NC}"
    install_echo "  ${BOLD}${GREEN}║                                             ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX}              → 交互菜单          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX} -c            → 本月流量          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX} -r            → 历史汇总          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX} lock          → 手动锁定          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX} unlock        → 手动解锁          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  ${CMD_LLCX} test-notify   → 测试通知          ║${NC}"
    install_echo "  ${BOLD}${GREEN}║                                             ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  定时器每 3 分钟自动检查流量                 ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  日志文件: /var/log/vtl-core.log            ║${NC}"
    install_echo "  ${BOLD}${GREEN}║  配置文件: ${CONF_DIR}/config          ║${NC}"
    install_echo "  ${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 卸载
# ─────────────────────────────────────
install_uninstall() {
    install_echo ""
    install_echo "  ${BOLD}${YELLOW}╔══════════════════════════════════════════╗${NC}"
    install_echo "  ${BOLD}${YELLOW}║      ⚠️  卸载 VPS 流量监控系统${NC}"
    install_echo "  ${BOLD}${YELLOW}╚══════════════════════════════════════════╝${NC}"
    install_echo ""
    install_echo "    ${YELLOW}即将执行以下操作:${NC}"
    install_echo "    • 停止并禁用 systemd 服务"
    install_echo "    • 清除防火墙规则"
    install_echo "    • 删除 ${INSTALL_DIR}"
    install_echo "    • 删除快捷命令"
    install_echo "    • 删除日志/状态文件"
    install_echo "    (保留 vnstat 数据库)"
    install_echo ""

    echo -n "  确认卸载? [y/N]: "
    read -r confirm1
    case "$confirm1" in
        y|Y)
            echo -n '  再次确认？输入 "YES": '
            read -r confirm2
            if [ "$confirm2" != "YES" ]; then
                install_echo "  ${GREEN}❌ 卸载已取消${NC}"
                return
            fi
            ;;
        *)
            install_echo "  ${GREEN}❌ 卸载已取消${NC}"
            return
            ;;
    esac

    install_echo ""
    install_echo "  ⏳ 正在卸载..."

    # 1. 停止并禁用服务
    install_echo "    ├─ 停止 systemd 服务..."
    local services="vtl-check.timer vtl-check.service"
    local svc
    for svc in $services; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    install_echo "    ${GREEN}│  ✅ systemd 服务已停止${NC}"

    # 2. 清除防火墙规则
    install_echo "    ├─ 清除防火墙规则..."
    # 尝试加载引擎配置
    VTL_CHAIN_NAME="VTL-LOCK"
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C OUTPUT -j "$VTL_CHAIN_NAME" &>/dev/null; do
            iptables -D OUTPUT -j "$VTL_CHAIN_NAME" 2>/dev/null || true
        done
        iptables -F "$VTL_CHAIN_NAME" 2>/dev/null || true
        iptables -X "$VTL_CHAIN_NAME" 2>/dev/null || true
        install_echo "    ${GREEN}│  ✅ iptables 规则已清除${NC}"
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C OUTPUT -j "$VTL_CHAIN_NAME" &>/dev/null; do
            ip6tables -D OUTPUT -j "$VTL_CHAIN_NAME" 2>/dev/null || true
        done
        ip6tables -F "$VTL_CHAIN_NAME" 2>/dev/null || true
        ip6tables -X "$VTL_CHAIN_NAME" 2>/dev/null || true
    fi

    # 3. 删除文件
    install_echo "    ├─ 删除安装文件..."
    rm -rf "$INSTALL_DIR" 2>/dev/null && \
        install_echo "    ${GREEN}│  ✅ ${INSTALL_DIR} 已删除${NC}" || \
        install_echo "    ${YELLOW}│  ⚠️  ${INSTALL_DIR} 删除失败${NC}"

    # 4. 删除快捷命令
    install_echo "    ├─ 删除快捷命令..."
    rm -f "/usr/local/bin/${CMD_LLCX}" 2>/dev/null || true
    install_echo "    ${GREEN}│  ✅ 快捷命令已删除${NC}"

    # 5. 删除 systemd 单元文件
    install_echo "    ├─ 删除 systemd 单元文件..."
    for svc in $services; do
        rm -f "/etc/systemd/system/$svc" 2>/dev/null || true
    done
    install_echo "    ${GREEN}│  ✅ systemd 单元文件已删除${NC}"

    # 6. 删除 logrotate
    install_echo "    ├─ 删除 logrotate 配置..."
    rm -f /etc/logrotate.d/vtl 2>/dev/null || true
    install_echo "    ${GREEN}│  ✅ logrotate 已删除${NC}"

    # 7. 删除运行时文件
    install_echo "    ├─ 删除运行时文件..."
    rm -f /run/vps-traffic-limit/locked.state 2>/dev/null || true
    rm -f /run/vps-traffic-limit/vtl.lock 2>/dev/null || true
    rmdir /run/vps-traffic-limit 2>/dev/null || true
    install_echo "    ${GREEN}│  ✅ 运行时文件已删除${NC}"

    # 8. 删除日志（可选）
    install_echo "    ├─ 日志保留 /var/log/vtl-core.log"
    install_echo "    │  (如需删除可手动执行: rm -f /var/log/vtl-core.log)"

    # 9. 重载 systemd
    systemctl daemon-reload 2>/dev/null || true

    install_echo ""
    install_echo "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    install_echo "  ${GREEN}  ✅ 已完全卸载，感谢使用！${NC}"
    install_echo "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    install_echo ""
}

# ─────────────────────────────────────
# 参数解析
# ─────────────────────────────────────
install_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --interface)
                shift; INTERFACE="$1" ;;
            --limit)
                shift; LIMIT_GB="$1" ;;
            --mode)
                shift; MODE="$1" ;;
            --allow-ports)
                shift; EXTRA_PORTS="$1" ;;
            --direction)
                shift; DIRECTION="$1" ;;
            --ssh-port)
                shift; SSH_PORTS="$1" ;;
            --cmd-llcx)
                shift; CMD_LLCX="$1" ;;
            --notify)
                shift; NOTIFY_CHANNEL="$1" ;;
            --telegram-bot)
                shift; TELEGRAM_BOT_TOKEN="$1" ;;
            --telegram-chat)
                shift; TELEGRAM_CHAT_ID="$1" ;;
            --wechat-webhook)
                shift; WECHAT_WEBHOOK_URL="$1" ;;
            --email-smtp)
                shift
                local smtp="$1"
                EMAIL_SMTP_SERVER="${smtp%%:*}"
                local port="${smtp##*:}"
                echo "$port" | grep -qE '^[0-9]+$' && EMAIL_SMTP_PORT="$port"
                ;;
            --email-auth)
                shift
                EMAIL_SMTP_USER="${1%%:*}"
                EMAIL_SMTP_PASS="${1##*:}"
                ;;
            --email-from)
                shift; EMAIL_FROM="$1" ;;
            --email-to)
                shift; EMAIL_TO="$1" ;;
            --serverchan-key)
                shift; SERVERCHAN_KEY="$1" ;;
            --yes|-y)
                AUTO_YES=true ;;
            --dry-run)
                DRY_RUN=true ;;
            --uninstall)
                install_uninstall
                exit 0
                ;;
            --help|-h)
                install_echo "用法: $0 [选项]"
                install_echo ""
                install_echo "选项:"
                install_echo "  --interface <名称>         网卡名称"
                install_echo "  --limit <GB>               流量限额"
                install_echo "  --mode <strict|custom>     锁定模式"
                install_echo "  --allow-ports <列表>       custom 模式放行端口"
                install_echo "  --direction <方向>         计费方向 (egress/total/ingress)"
                install_echo "  --ssh-port <端口>          SSH 端口 (逗号分隔)"
                install_echo "  --cmd-llcx <名称>          快捷命令名"
                install_echo "  --notify <channel>         通知渠道"
                install_echo "  --telegram-bot <TOKEN>     Telegram Bot Token"
                install_echo "  --telegram-chat <ID>       Telegram Chat ID"
                install_echo "  --wechat-webhook <URL>     企业微信 Webhook URL"
                install_echo "  --email-smtp <服务器:端口> SMTP 服务器"
                install_echo "  --email-auth <用户:密码>   SMTP 认证"
                install_echo "  --email-from <地址>        发件人地址"
                install_echo "  --email-to <地址>          收件人地址"
                install_echo "  --serverchan-key <KEY>     Server酱 SendKey"
                install_echo "  --yes, -y                  跳过确认"
                install_echo "  --dry-run                  只展示不安装"
                install_echo "  --uninstall                卸载"
                install_echo "  --help, -h                 显示此帮助"
                exit 0
                ;;
            *)
                install_echo "${RED}❌ 未知参数: $1${NC}"
                install_echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
        shift
    done
}

# ─────────────────────────────────────
# 主流程
# ─────────────────────────────────────
main() {
    # 解析参数
    install_parse_args "$@"

    # 如果是 --uninstall 会在 install_parse_args 中直接 exit
    # 这里处理正常安装流程

    # ─── 欢迎页 ───
    clear 2>&1 || true
    install_echo ""
    install_echo "  ${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
    install_echo "  ${BOLD}${CYAN}║         🛡️  VPS 流量监控系统${NC}"
    install_echo "  ${BOLD}${CYAN}║          VTL v5.0 安装程序${NC}"
    install_echo "  ${BOLD}${CYAN}╠══════════════════════════════════════════╣${NC}"
    install_echo "  ${BOLD}${CYAN}║  超限自动锁定 | 多渠道通知 | 双保险${NC}"
    install_echo "  ${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
    install_echo ""

    # ─── 安装前检查：自动安装依赖 ───
    install_echo "  ${BOLD}--- 步骤 1: 安装前置依赖 ---${NC}"
    install_auto_deps
    install_echo ""

    # ─── 前置检查 ───
    install_echo "  ${BOLD}--- 步骤 2: 前置检查 ---${NC}"
    install_precheck
    install_echo ""

    # ─── 交互配置 ───
    # 如果所有参数都已通过命令行提供，则跳过交互式提问
    $AUTO_YES && exec < /dev/null
    install_echo "  ${BOLD}--- 步骤 3: 配置信息收集 ---${NC}"
    install_echo ""

    install_select_interface
    install_detect_ssh
    install_configure_limit
    install_select_mode
    install_configure_ports
    install_select_direction
    install_detect_firewall
    install_configure_notify
    install_configure_cmd

    # ─── 显示摘要并确认 ───
    install_show_summary

    if ! $AUTO_YES && ! $DRY_RUN; then
        echo -n "  确认安装以上配置? [Y/n]: "
        read -r confirm || true
        case "$confirm" in
            n|N|no|NO)
                install_echo ""
                install_echo "  ${YELLOW}安装已取消${NC}"
                exit 0
                ;;
        esac
    fi

    # ─── 执行安装 ───
    install_execute

    # ─── 完成 ───
    install_finish
}

# ─── 启动主流程 ────────────────────────────────────────────
main "$@"
