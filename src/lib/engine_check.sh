#!/bin/bash
# ===========================================
# VTL 核心检查引擎
# 作为 cron 定时器的入口，编排整个检查→锁定/解锁→通知流程
# 依赖: config (全局变量), engine_firewall.sh (fw_*), engine_notify.sh (notify_send), common.sh (log_write/detect_*)
# ===========================================

# ─── 内建 fallback ────────────────────────────────────────────
# 若 common.sh 已加载则使用其 log_write/detect_firewall，
# 否则使用内建版本保持独立

if ! type log_write &>/dev/null 2>&1; then
    log_write() {
        local level="$1"
        local msg="$2"
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$level] $msg" >> "${LOG_FILE:-/dev/null}"
    }
fi

if ! type detect_firewall &>/dev/null 2>&1; then
    detect_firewall() {
        IPTABLES_AVAIL=0
        IP6TABLES_AVAIL=0
        command -v iptables &>/dev/null && iptables -L &>/dev/null && IPTABLES_AVAIL=1
        command -v ip6tables &>/dev/null && ip6tables -L &>/dev/null && IP6TABLES_AVAIL=1
    }
fi

# ─── check_get_traffic ────────────────────────────────────────
# 获取当月流量数据
# 输入: 读取全局 INTERFACE, DIRECTION, LIMIT_GB
# 输出: 设置 USED_BYTES, USED_GB, USED_PERCENT, LIMIT_BYTES
# 依赖: vnstat -m --json (每月首次使用 -m 兜底)
# 返回: 0=成功, 1=vnstat无数据
function check_get_traffic() {
    local vnstat_month
    local tx=0
    local rx=0

    # 获取当月流量（使用 --json 格式）
    vnstat_month=$(vnstat -m --json 2>/dev/null)
    if [ -z "$vnstat_month" ]; then
        log_write "ERROR" "vnstat -m --json 无输出"
        return 1
    fi

    # 解析上行流量 (tx)
    tx=$(echo "$vnstat_month" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data.get('interfaces', []):
        if iface.get('name') == '$INTERFACE':
            months = (iface.get('traffic', {}).get('month', [])
                      or iface.get('traffic', {}).get('months', []))
            if months:
                print(months[0].get('tx', 0))
                break
except: print(0)
" 2>/dev/null)

    # 解析下行流量 (rx)
    rx=$(echo "$vnstat_month" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data.get('interfaces', []):
        if iface.get('name') == '$INTERFACE':
            months = (iface.get('traffic', {}).get('month', [])
                      or iface.get('traffic', {}).get('months', []))
            if months:
                print(months[0].get('rx', 0))
                break
except: print(0)
" 2>/dev/null)

    # 检查解析结果
    [ -z "$tx" ] && tx=0
    [ -z "$rx" ] && rx=0

    # 如果 tx 和 rx 都是 0，可能 vnstat 尚无本月数据
    if [ "$tx" -eq 0 ] && [ "$rx" -eq 0 ]; then
        log_write "SKIP" "vnstat 返回的 tx/rx 均为 0，可能尚无本月数据"
        return 1
    fi

    # 根据 DIRECTION 确定用量
    case "$DIRECTION" in
        total)
            USED_BYTES=$((tx + rx))
            ;;
        ingress)
            USED_BYTES=$rx
            ;;
        egress|*)
            USED_BYTES=$tx
            ;;
    esac

    # 限额从 GB 转换为 bytes (1 GB = 1073741824 bytes)
    LIMIT_BYTES=$((LIMIT_GB * 1073741824))

    # 用 AWK 做精度计算
    USED_GB=$(awk -v bytes="$USED_BYTES" 'BEGIN { printf "%.4f", bytes / 1073741824 }')
    USED_PERCENT=$(awk -v used="$USED_BYTES" -v limit="$LIMIT_BYTES" \
        'BEGIN { if (limit > 0) printf "%.2f", (used / limit) * 100; else print 0 }')

    return 0
}

# ─── check_should_lock ────────────────────────────────────────
# 判断是否应锁定
# 输入: USED_PERCENT
# 返回: 0=应锁定(≥100%), 1=不应锁(<100%)
function check_should_lock() {
    local result
    result=$(awk -v pct="$USED_PERCENT" 'BEGIN { print (pct >= 100) ? 1 : 0 }')
    [ "$result" -eq 1 ] && return 0 || return 1
}

# ─── check_double_insurance ───────────────────────────────────
# 双保险一致性校验：状态文件 ↔ 防火墙规则
# 输入: LOCK_STATE_FILE 是否存在, fw_is_locked 结果
# 输出: 修复不一致（重新锁/重建state/解锁）
# 逻辑: 4种状态矩阵
#   state=1 + locked=1 → 一致, 正常 (返回0)
#   state=1 + locked=0 → 规则丢失, 重新锁 (返回1)
#   state=0 + locked=1 → state丢失, 重建state (返回1)
#   state=0 + locked=0 → 一致, 正常 (返回0)
# 返回: 0=一致, 1=已修复
function check_double_insurance() {
    local state_exists=0  # 0=不存在, 1=存在
    local rules_active=0  # 0=未锁定, 1=已锁定

    [ -f "$LOCK_STATE_FILE" ] && state_exists=1
    fw_is_locked && rules_active=1

    if [ "$state_exists" -eq 1 ] && [ "$rules_active" -eq 1 ]; then
        # 🟢 正常锁定 — 一致
        return 0
    elif [ "$state_exists" -eq 1 ] && [ "$rules_active" -eq 0 ]; then
        # ⚠️ state 在但规则丢了 → 重新锁
        log_write "FIX" "双保险修复: state存在但规则丢失，重新锁定"
        fw_lock || log_write "ERROR" "双保险修复: fw_lock 失败"
        return 1
    elif [ "$state_exists" -eq 0 ] && [ "$rules_active" -eq 1 ]; then
        # ⚠️ 规则在但 state 丢了 → 重建 state
        echo "$(date +%s)" > "$LOCK_STATE_FILE"
        log_write "FIX" "双保险修复: 规则存在但state丢失，已重建state"
        return 1
    else
        # 🟢 未锁定 — 一致
        return 0
    fi
}

# ─── check_should_reset ──────────────────────────────────────
# 判断是否到计费周期重置
# 输入: PROVIDER_TIMEZONE, RESET_DAY
# 逻辑: 用 TZ=$PROVIDER_TIMEZONE date 获取云厂商当日时间和小时
#       如果 day == RESET_DAY && hour == 0 → 应重置
# 返回: 0=应重置, 1=不应
function check_should_reset() {
    local current_day current_hour

    # 使用云厂商时区获取当前日期和小时
    current_day=$(TZ="$PROVIDER_TIMEZONE" date +%d 2>/dev/null)
    current_hour=$(TZ="$PROVIDER_TIMEZONE" date +%H 2>/dev/null)

    # 去掉前导零避免被当成八进制
    current_day=$((10#$current_day))
    current_hour=$((10#$current_hour))

    if [ "$current_day" -eq "$RESET_DAY" ] && [ "$current_hour" -eq 0 ]; then
        return 0
    fi
    return 1
}

# ─── check_cron ──────────────────────────────────────────────
# 定时器主入口（systemd timer 每3分钟调用）
# 输入: 无
# 输出: 完整检查流程
# 逻辑:
#   1. flock 获取互斥锁 (超时3秒 → SKIP)
#   2. 检测防火墙可用性
#   3. check_should_reset → 解锁+重置
#   4. check_get_traffic → 获取流量
#   5. check_double_insurance → 修复不一致
#   6. check_should_lock:
#      - 应锁 → 先 notify_send lock, 再 fw_lock, 写 state
#      - 不应锁 → 正常, 看是否需要预警
#   7. 预警: USED_PERCENT >= CRIT_PERCENT → notify_send warn_95,
#      USED_PERCENT >= WARN_PERCENT → notify_send warn_80
#   8. 记录日志
#   9. 释放 flock
# 返回: 0=正常
function check_cron() {
    local today
    local warn_sent_dir

    # 1. 进程互斥锁
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    exec 200>"$LOCK_FILE"
    flock -w 3 200 || {
        log_write "SKIP" "另一进程正在执行，跳过本次检查"
        return 0
    }

    log_write "CHECK" "开始定时检查..."

    # 2. 检测防火墙可用性
    detect_firewall
    if [ "$IPTABLES_AVAIL" -eq 0 ] && [ "$IP6TABLES_AVAIL" -eq 0 ]; then
        log_write "ERROR" "iptables/ip6tables 均不可用，跳过检查"
        flock -u 200
        return 0
    fi

    # 3. 计费周期重置检测
    if check_should_reset; then
        log_write "CHECK" "检测到计费周期重置日"
        fw_unlock || true
        rm -f "$LOCK_STATE_FILE"
        notify_send unlock "计费周期重置" || true
        log_write "RESET" "计费周期已重置，已解锁"
        flock -u 200
        return 0
    fi

    # 4. 获取流量数据
    check_get_traffic || {
        log_write "SKIP" "vnstat 无数据 (安装后需等待约5分钟)"
        flock -u 200
        return 0
    }

    log_write "CHECK" "已用: ${USED_GB}GB / ${LIMIT_GB}GB (${USED_PERCENT}%)"

    # 5. 双保险一致性检查（修复不一致但不因此终止流程）
    check_double_insurance || true

    # 6. 超限判断与执行
    if check_should_lock; then
        # 应锁定
        if ! fw_is_locked; then
            # 先发通知，再锁定
            notify_send lock "上行: ${USED_GB}GB" || true
            if fw_lock; then
                echo "$(date +%s)" > "$LOCK_STATE_FILE"
                log_write "LOCK" "超限锁定 | 上行: ${USED_GB}GB / ${LIMIT_GB}GB (${USED_PERCENT}%)"
            else
                log_write "ERROR" "fw_lock 失败"
            fi
        else
            log_write "CHECK" "已锁定，跳过重复锁定"
        fi
    else
        # 不应锁定

        # 未超限但已锁 → 异常降级（双保险已处理的遗漏情况）
        if fw_is_locked; then
            log_write "WARN" "异常: 未超限但防火墙仍处于锁定状态，尝试解锁"
            fw_unlock || true
            rm -f "$LOCK_STATE_FILE"
            notify_send unlock "用量恢复正常" || true
            log_write "UNLOCK" "异常降级: 未超限但处于锁定状态，已解锁"
        fi

        # 7. 预警通知（只在未锁定时发，且每天最多发一次，避免刷屏）
        today=$(date +%Y%m%d)
        warn_sent_dir="/run/vps-traffic-limit"
        mkdir -p "$warn_sent_dir" 2>/dev/null

        if [ "$(awk "BEGIN{print ($USED_PERCENT >= $CRIT_PERCENT)}")" -eq 1 ]; then
            # 极度阈值 (95%)
            if [ ! -f "${warn_sent_dir}/warn_sent_${today}_95" ]; then
                notify_send warn_95 "上行: ${USED_GB}GB" || true
                touch "${warn_sent_dir}/warn_sent_${today}_95"
                log_write "WARN" "已达 ${CRIT_PERCENT}% 极度阈值 | 上行: ${USED_GB}GB / ${LIMIT_GB}GB"
            fi
        elif [ "$(awk "BEGIN{print ($USED_PERCENT >= $WARN_PERCENT)}")" -eq 1 ]; then
            # 警告阈值 (80%)
            if [ ! -f "${warn_sent_dir}/warn_sent_${today}_80" ]; then
                notify_send warn_80 "上行: ${USED_GB}GB" || true
                touch "${warn_sent_dir}/warn_sent_${today}_80"
                log_write "WARN" "已达 ${WARN_PERCENT}% 警告阈值 | 上行: ${USED_GB}GB / ${LIMIT_GB}GB"
            fi
        fi
    fi

    log_write "CHECK" "检查完成"

    # 9. 释放 flock
    flock -u 200
    return 0
}

# ─── 直接执行（脚本单独运行时）─────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # 尝试加载依赖
    if [ -z "$VTL_CHAIN_NAME" ]; then
        CONF_DIR="${CONF_DIR:-/opt/vps-traffic-limit/conf}"
        LIB_DIR="${LIB_DIR:-/opt/vps-traffic-limit/lib}"
        [ -f "$CONF_DIR/config" ] && source "$CONF_DIR/config"
        [ -f "$LIB_DIR/engine_firewall.sh" ] && source "$LIB_DIR/engine_firewall.sh"
        [ -f "$LIB_DIR/engine_notify.sh" ] && source "$LIB_DIR/engine_notify.sh"
    fi

    case "${1:-cron}" in
        cron|check)
            check_cron
            echo "Exit: $?"
            ;;
        traffic)
            check_get_traffic
            echo "USED_BYTES=$USED_BYTES"
            echo "USED_GB=$USED_GB"
            echo "USED_PERCENT=$USED_PERCENT%"
            echo "LIMIT_BYTES=$LIMIT_BYTES"
            echo "Exit: $?"
            ;;
        should-lock)
            check_should_lock && echo "SHOULD_LOCK" || echo "SHOULD_NOT_LOCK"
            ;;
        double-insurance)
            check_double_insurance
            echo "Exit: $?"
            echo "(0=一致, 1=已修复)"
            ;;
        should-reset)
            check_should_reset && echo "SHOULD_RESET" || echo "SHOULD_NOT_RESET"
            ;;
        *)
            echo "用法: $0 {cron|traffic|should-lock|double-insurance|should-reset}"
            exit 1
            ;;
    esac
fi
