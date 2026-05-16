#!/bin/bash
# ===========================================
# VTL-LOCK 沙盒防火墙引擎
# 使用 iptables / ip6tables 实现沙盒锁定
# 依赖: conf/config（提供 VTL_CHAIN_NAME 等变量）
# 可选依赖: common.sh（提供 log_write / detect_firewall）
# 独立 fallback: 若 common.sh 未加载则使用内建实现
# ===========================================

# ─── 内建 fallback ────────────────────────────────────────────
# 若 common.sh 已加载则使用其 log_write/detect_firewall，
# 否则使用内建版本保持独立

if ! type log_write &>/dev/null 2>&1; then
    # log_write: 统一日志格式
    # $1 = LEVEL, $2 = 消息
    log_write() {
        local level="$1"
        local msg="$2"
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$level] $msg" >> "${LOG_FILE:-/dev/null}"
    }
fi

if ! type detect_firewall &>/dev/null 2>&1; then
    # detect_firewall: 检测 iptables/ip6tables 是否可用
    # 设置: IPTABLES_AVAIL, IP6TABLES_AVAIL
    detect_firewall() {
        IPTABLES_AVAIL=0
        IP6TABLES_AVAIL=0
        command -v iptables &>/dev/null && iptables -L &>/dev/null && IPTABLES_AVAIL=1
        command -v ip6tables &>/dev/null && ip6tables -L &>/dev/null && IP6TABLES_AVAIL=1
    }
fi

# ─── fw_detect ────────────────────────────────────────────────
# 检测 iptables/ip6tables 是否可用
# 输入: 无
# 设置: IPTABLES_AVAIL, IP6TABLES_AVAIL
# 返回: 0=至少一个可用, 1=都不可用
function fw_detect() {
    detect_firewall
    if [ "$IPTABLES_AVAIL" -eq 1 ] || [ "$IP6TABLES_AVAIL" -eq 1 ]; then
        log_write "CHECK" "防火墙检测: iptables=$IPTABLES_AVAIL ip6tables=$IP6TABLES_AVAIL"
        return 0
    fi
    log_write "ERROR" "防火墙检测失败: iptables 和 ip6tables 均不可用"
    return 1
}

# ─── 内部: 注入 IPv4 VTL-LOCK ────────────────────────────────
# 复用 IPv6 的相同逻辑
__fw_apply_v4() {
    local tool="$1"          # iptables
    local chain="$2"         # VTL_CHAIN_NAME
    local ssh_ports="$3"     # SSH_PORTS
    local mode="$4"          # MODE
    local extra_ports="$5"   # EXTRA_PORTS

    # 1. 创建链（幂等：存在则清空，不存在则新建）
    $tool -N "$chain" 2>/dev/null || $tool -F "$chain" || true

    # 2. SSH 端口放行（sport 回应客户端，dport 主动出站）
    local old_ifs="$IFS"
    IFS=','
    for port in $ssh_ports; do
        IFS="$old_ifs"
        port="${port## }"
        port="${port%% }"
        [ -z "$port" ] && continue
        $tool -A "$chain" -p tcp --sport "$port" -j ACCEPT || true
        $tool -A "$chain" -p tcp --dport "$port" -j ACCEPT || true
    done
    IFS="$old_ifs"

    # 3. DNS 放行
    $tool -A "$chain" -p udp --dport 53 -j ACCEPT || true
    $tool -A "$chain" -p tcp --dport 53 -j ACCEPT || true

    # 4. DHCP 放行（udp sport 68 → dport 67）
    $tool -A "$chain" -p udp --sport 68 --dport 67 -j ACCEPT || true

    # 5. custom 模式 — 额外端口
    if [ "$mode" = "custom" ] && [ -n "$extra_ports" ]; then
        IFS=','
        for item in $extra_ports; do
            IFS="$old_ifs"
            item="${item## }"
            item="${item%% }"
            [ -z "$item" ] && continue
            if echo "$item" | grep -qE '^[0-9]+-[0-9]+$'; then
                # 端口范围: 30000-50000
                local start end
                start="${item%%-*}"
                end="${item##*-}"
                $tool -A "$chain" -p tcp --dport "$start:$end" -j ACCEPT || true
                $tool -A "$chain" -p udp --dport "$start:$end" -j ACCEPT || true
            else
                $tool -A "$chain" -p tcp --dport "$item" -j ACCEPT || true
                $tool -A "$chain" -p udp --dport "$item" -j ACCEPT || true
            fi
        done
        IFS="$old_ifs"
    fi

    # 6. 兜底拒绝
    $tool -A "$chain" -j REJECT --reject-with icmp-port-unreachable || true

    # 7. 置顶劫持 OUTPUT 链
    $tool -I OUTPUT 1 -j "$chain" || true
}

# ─── 内部: 注入 IPv6 VTL-LOCK ────────────────────────────────
__fw_apply_v6() {
    local tool="$1"          # ip6tables
    local chain="$2"
    local ssh_ports="$3"
    local mode="$4"
    local extra_ports="$5"

    # 1. 创建链（幂等）
    $tool -N "$chain" 2>/dev/null || $tool -F "$chain" || true

    # 2. SSH 端口放行
    local old_ifs="$IFS"
    IFS=','
    for port in $ssh_ports; do
        IFS="$old_ifs"
        port="${port## }"
        port="${port%% }"
        [ -z "$port" ] && continue
        $tool -A "$chain" -p tcp --sport "$port" -j ACCEPT || true
        $tool -A "$chain" -p tcp --dport "$port" -j ACCEPT || true
    done
    IFS="$old_ifs"

    # 3. DNS 放行
    $tool -A "$chain" -p udp --dport 53 -j ACCEPT || true
    $tool -A "$chain" -p tcp --dport 53 -j ACCEPT || true

    # 4. DHCPv6 放行（udp sport 546 → dport 547）
    $tool -A "$chain" -p udp --sport 546 --dport 547 -j ACCEPT || true

    # 5. custom 模式
    if [ "$mode" = "custom" ] && [ -n "$extra_ports" ]; then
        IFS=','
        for item in $extra_ports; do
            IFS="$old_ifs"
            item="${item## }"
            item="${item%% }"
            [ -z "$item" ] && continue
            if echo "$item" | grep -qE '^[0-9]+-[0-9]+$'; then
                local start end
                start="${item%%-*}"
                end="${item##*-}"
                $tool -A "$chain" -p tcp --dport "$start:$end" -j ACCEPT || true
                $tool -A "$chain" -p udp --dport "$start:$end" -j ACCEPT || true
            else
                $tool -A "$chain" -p tcp --dport "$item" -j ACCEPT || true
                $tool -A "$chain" -p udp --dport "$item" -j ACCEPT || true
            fi
        done
        IFS="$old_ifs"
    fi

    # 6. 兜底拒绝（IPv6 REJECT 不需要 --reject-with 参数，默认 icmp6-port-unreachable）
    $tool -A "$chain" -j REJECT || true

    # 7. 置顶劫持 OUTPUT 链
    $tool -I OUTPUT 1 -j "$chain" || true
}

# ─── 内部: 解锁 IPv4 VTL-LOCK ────────────────────────────────
__fw_remove_v4() {
    local tool="$1"
    local chain="$2"
    # 移除 OUTPUT 劫持（可能多次插入，循环删除确保干净）
    while $tool -C OUTPUT -j "$chain" &>/dev/null; do
        $tool -D OUTPUT -j "$chain" || true
    done
    # 清空链
    $tool -F "$chain" 2>/dev/null || true
    # 删除链
    $tool -X "$chain" 2>/dev/null || true
}

# ─── 内部: 解锁 IPv6 VTL-LOCK ────────────────────────────────
__fw_remove_v6() {
    local tool="$1"
    local chain="$2"
    while $tool -C OUTPUT -j "$chain" &>/dev/null; do
        $tool -D OUTPUT -j "$chain" || true
    done
    $tool -F "$chain" 2>/dev/null || true
    $tool -X "$chain" 2>/dev/null || true
}

# ─── fw_lock ──────────────────────────────────────────────────
# 注入 VTL-LOCK 规则
# 输入: 读取全局变量 SSH_PORTS, MODE, EXTRA_PORTS, IPV6_POLICY, VTL_CHAIN_NAME
# 输出: iptables 操作
# 返回: 0=成功, 1=失败
# 注意: 幂等——重复执行不会重复创建链
function fw_lock() {
    local ret=0

    # 先检测可用性
    fw_detect || return 1

    # ── IPv4 ──
    if [ "$IPTABLES_AVAIL" -eq 1 ]; then
        __fw_apply_v4 "iptables" "$VTL_CHAIN_NAME" "$SSH_PORTS" "$MODE" "$EXTRA_PORTS"
        log_write "LOCK" "IPv4 VTL-LOCK 注入完成 | SSH:${SSH_PORTS} | 模式:${MODE}"
    else
        log_write "WARN" "iptables 不可用，跳过 IPv4 锁定"
        ret=1
    fi

    # ── IPv6 ──
    if [ "$IPV6_POLICY" = "dual" ]; then
        if [ "$IP6TABLES_AVAIL" -eq 1 ]; then
            __fw_apply_v6 "ip6tables" "$VTL_CHAIN_NAME" "$SSH_PORTS" "$MODE" "$EXTRA_PORTS"
            log_write "LOCK" "IPv6 VTL-LOCK 注入完成 | SSH:${SSH_PORTS} | 模式:${MODE}"
        else
            log_write "WARN" "IPV6_POLICY=dual 但 ip6tables 不可用，跳过 IPv6 锁定"
            ret=1
        fi
    fi

    return "$ret"
}

# ─── fw_unlock ────────────────────────────────────────────────
# 移除 VTL-LOCK 规则
# 输入: 无（读取 VTL_CHAIN_NAME, IPV6_POLICY）
# 输出: iptables 操作
# 返回: 0=成功, 1=失败
# 注意: 幂等
function fw_unlock() {
    local ret=0

    # ── IPv4 ── (无论 IPTABLES_AVAIL 如何都尝试移除)
    if command -v iptables &>/dev/null; then
        __fw_remove_v4 "iptables" "$VTL_CHAIN_NAME"
        log_write "UNLOCK" "IPv4 VTL-LOCK 已移除"
    else
        log_write "WARN" "iptables 不可用，跳过 IPv4 解锁"
        ret=1
    fi

    # ── IPv6 ──
    if [ "$IPV6_POLICY" = "dual" ]; then
        if command -v ip6tables &>/dev/null; then
            __fw_remove_v6 "ip6tables" "$VTL_CHAIN_NAME"
            log_write "UNLOCK" "IPv6 VTL-LOCK 已移除"
        else
            log_write "WARN" "IPV6_POLICY=dual 但 ip6tables 不可用，跳过 IPv6 解锁"
            ret=1
        fi
    fi

    return "$ret"
}

# ─── fw_is_locked ─────────────────────────────────────────────
# 检测是否已注入 VTL-LOCK
# 输入: 无
# 返回: 0=已锁定, 1=未锁定
function fw_is_locked() {
    # 先检测 iptables 是否可用
    if ! command -v iptables &>/dev/null; then
        return 1
    fi

    # 检查 OUTPUT 链上是否有 -j VTL-LOCK 规则
    if iptables -C OUTPUT -j "$VTL_CHAIN_NAME" &>/dev/null; then
        return 0
    fi

    # 如果 IPV6_POLICY=dual，也检查 ip6tables
    if [ "$IPV6_POLICY" = "dual" ] && command -v ip6tables &>/dev/null; then
        if ip6tables -C OUTPUT -j "$VTL_CHAIN_NAME" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# ─── fw_test ──────────────────────────────────────────────────
# 测试锁定 30 秒后自动解锁
# 输入: 无
# 输出: 锁定 → 等待 30 秒 → 解锁
# 返回: 0=正常
function fw_test() {
    echo "=== VTL-LOCK 沙盒测试 ==="
    echo "锁定 30 秒..."
    echo "警告: SSH($SSH_PORTS) 和 DNS 将放行，其他出站流量将被拦截！"
    echo ""

    fw_lock || {
        echo "❌ 锁定失败！"
        return 1
    }

    echo "✅ 已锁定，输出规则:"
    if [ "$IPTABLES_AVAIL" -eq 1 ]; then
        echo "--- iptables VTL-LOCK ---"
        iptables -L "$VTL_CHAIN_NAME" -n 2>/dev/null
    fi
    if [ "$IPV6_POLICY" = "dual" ] && [ "$IP6TABLES_AVAIL" -eq 1 ]; then
        echo "--- ip6tables VTL-LOCK ---"
        ip6tables -L "$VTL_CHAIN_NAME" -n 2>/dev/null
    fi

    echo ""
    echo "等待 30 秒后自动解锁..."
    sleep 30

    fw_unlock
    echo ""
    echo "✅ 已解锁，测试完成"
    return 0
}

# ─── 直接执行（脚本单独运行时）─────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # 尝试加载配置
    if [ -z "$VTL_CHAIN_NAME" ]; then
        CONF_DIR="${CONF_DIR:-/opt/vps-traffic-limit/conf}"
        LIB_DIR="${LIB_DIR:-/opt/vps-traffic-limit/lib}"
        [ -f "$CONF_DIR/config" ] && source "$CONF_DIR/config"
    fi

    case "${1:-detect}" in
        detect)
            fw_detect
            echo "IPTABLES_AVAIL=$IPTABLES_AVAIL IP6TABLES_AVAIL=$IP6TABLES_AVAIL"
            ;;
        lock)
            fw_lock
            echo "Exit: $?"
            ;;
        unlock)
            fw_unlock
            echo "Exit: $?"
            ;;
        is-locked)
            fw_is_locked && echo "LOCKED" || echo "UNLOCKED"
            ;;
        test)
            fw_test
            ;;
        *)
            echo "用法: $0 {detect|lock|unlock|is-locked|test}"
            exit 1
            ;;
    esac
fi
