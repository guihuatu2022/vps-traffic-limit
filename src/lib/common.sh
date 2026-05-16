# ===========================================
# VTL 公共函数库 — 输入校验 + 日志
# 被所有引擎 source
# ===========================================

# ─── 日志写入 ───
# 格式: [2026-05-16 14:30:00] [LEVEL] 消息
# LEVEL: CHECK | LOCK | UNLOCK | WARN | NOTIFY | ERROR | FIX | SKIP | RESET
log_write() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# ─── 输入校验 ───
# 所有用户输入的入口必须经过以下函数

# 校验端口格式: 80 / 80,443 / 30000-50000
# 返回值: 0=合法, 1=非法
validate_ports() {
    local input="$1"
    [ -z "$input" ] && return 1
    local saved_ifs="$IFS"
    IFS=','
    for item in $input; do
        IFS="$saved_ifs"
        item=$(echo "$item" | xargs)  # 去首尾空格
        if echo "$item" | grep -qE '^[0-9]+-[0-9]+$'; then
            local s e
            s=$(echo "$item" | cut -d- -f1)
            e=$(echo "$item" | cut -d- -f2)
            [ "$s" -ge 1 ] && [ "$s" -le 65535 ] && \
            [ "$e" -ge 1 ] && [ "$e" -le 65535 ] && \
            [ "$s" -lt "$e" ] || { IFS="$saved_ifs"; return 1; }
        elif echo "$item" | grep -qE '^[0-9]+$'; then
            [ "$item" -ge 1 ] && [ "$item" -le 65535 ] || { IFS="$saved_ifs"; return 1; }
        else
            IFS="$saved_ifs"
            return 1
        fi
    done
    IFS="$saved_ifs"
    return 0
}

# 校验接口名: 字母开头，字母数字
validate_interface() {
    echo "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9]+$'
}

# 校验命令名: 字母开头，字母数字下划线连字符
validate_cmd_name() {
    echo "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'
}

# 校验正整数
validate_number() {
    [ -n "$1" ] && echo "$1" | grep -qE '^[1-9][0-9]*$'
}

# 校验百分比 (1-99)
validate_percent() {
    echo "$1" | grep -qE '^[1-9][0-9]?$' && [ "$1" -ge 1 ] && [ "$1" -le 99 ]
}

# 校验 IANA 时区
validate_timezone() {
    TZ="$1" date +%Z >/dev/null 2>&1
}

# ─── 系统检测 ───

# 检测操作系统是否为 Debian/Ubuntu
# 返回值: 0=是, 1=否
detect_os() {
    [ -f /etc/os-release ] || return 1
    local id
    id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$id" in
        debian|ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

# 检测是否 root
# 返回值: 0=root, 1=非root
detect_root() {
    [ "$(id -u)" -eq 0 ]
}

# 检测 iptables/ip6tables 是否可用
# 设置: IPTABLES_AVAIL, IP6TABLES_AVAIL
detect_firewall() {
    IPTABLES_AVAIL=0
    IP6TABLES_AVAIL=0
    command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1 && IPTABLES_AVAIL=1
    command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1 && IP6TABLES_AVAIL=1
}

# 检测主网卡（默认路由接口）
detect_interface() {
    ip route | grep '^default' | head -1 | awk '{print $5}'
}

# 检测 SSH 端口（用 sshd -T 获取实际生效端口）
detect_ssh_ports() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | sort -u | tr '\n' ',' | sed 's/,$//'
    fi
    # 如果 sshd -T 不工作，兜底 22
    [ -z "$SSH_PORTS" ] && echo "22"
}
