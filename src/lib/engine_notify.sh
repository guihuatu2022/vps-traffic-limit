# ===========================================
# VTL 通知引擎 — 多渠道消息发送
# 依赖: config (全局变量), common.sh (log_write)
# 渠道: Telegram / 企业微信 / Server酱 / 邮件 SMTP
# ===========================================

# ─── 内部函数：构建端口放行说明 ───
# 输入: 无（读取全局变量）
# 输出: 打印放行说明字符串
_notify_build_port_summary() {
    local summary="SSH(${SSH_PORTS})+DNS"
    if [ "$MODE" = "custom" ] && [ -n "$EXTRA_PORTS" ]; then
        summary="${summary}+自定义(${EXTRA_PORTS})"
    fi
    echo "$summary"
}

# ─── 内部函数：从 extra 字符串提取 GB 数值 ───
# 输入: $1 = extra 字符串 (如 "上行: 171GB")
# 输出: 打印提取的数值 (如 "171")
_notify_extract_gb() {
    echo "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
}

# ─── notify_build_message: 组装通知文本 ───
# 输入: $1 = type (lock|unlock|warn_80|warn_95|test)
#       $2 = extra (附加信息)
# 输出: 打印格式化的通知文本
notify_build_message() {
    local type="$1"
    local extra="${2:-}"
    local now
    now=$(date "+%Y-%m-%d %H:%M:%S")
    local port_summary
    port_summary=$(_notify_build_port_summary)

    case "$type" in
        lock)
            cat <<-EOF
⛔ VPS 流量已锁定
━━━━━━━━━━━━━━━━━━
网卡: ${INTERFACE}
原因: 月上行 ${extra} 已超限
模式: ${MODE}
放行: ${port_summary}
锁定时间: ${now}
━━━━━━━━━━━━━━━━━━
次月将自动解锁，无需人工干预
EOF
            ;;
        unlock)
            cat <<-EOF
✅ VPS 流量已解锁
━━━━━━━━━━━━━━━━━━
网卡: ${INTERFACE}
原因: ${extra}
解锁时间: ${now}
━━━━━━━━━━━━━━━━━━
EOF
            ;;
        warn_80)
            local used_gb
            used_gb=$(_notify_extract_gb "$extra")
            local remaining_gb="?"
            if [ -n "$used_gb" ] && [ -n "$LIMIT_GB" ]; then
                remaining_gb=$(awk "BEGIN{printf \"%.1f\", ${LIMIT_GB} - ${used_gb}}")
            fi
            cat <<-EOF
⚠️ VPS 流量预警 (80%)
━━━━━━━━━━━━━━━━━━
网卡: ${INTERFACE}
已使用: ${extra}
限额: ${LIMIT_GB}GB
剩余约: ${remaining_gb}GB
━━━━━━━━━━━━━━━━━━
请留意流量使用情况
EOF
            ;;
        warn_95)
            local used_gb
            used_gb=$(_notify_extract_gb "$extra")
            local remaining_gb="?"
            if [ -n "$used_gb" ] && [ -n "$LIMIT_GB" ]; then
                remaining_gb=$(awk "BEGIN{printf \"%.1f\", ${LIMIT_GB} - ${used_gb}}")
            fi
            cat <<-EOF
🚨 VPS 流量极度接近限额 (95%)!
━━━━━━━━━━━━━━━━━━
网卡: ${INTERFACE}
已使用: ${extra}
限额: ${LIMIT_GB}GB
剩余约: ${remaining_gb}GB
━━━━━━━━━━━━━━━━━━
超限后将自动锁定（SSH不断）
EOF
            ;;
        test)
            cat <<-EOF
🔔 VTL 测试通知
━━━━━━━━━━━━━━━━━━
这是一条测试消息
如果你的 VPS 收到此通知，说明通知配置正常
━━━━━━━━━━━━━━━━━━
EOF
            ;;
        *)
            echo "未知通知类型: ${type}"
            return 1
            ;;
    esac
}

# ─── Telegram 渠道 ───
notify_telegram() {
    local msg="$1"
    curl -s --connect-timeout 5 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || return 1
    return 0
}

# ─── 企业微信渠道 ───
notify_wechat() {
    local msg="$1"
    curl -s --connect-timeout 5 \
        -X POST "$WECHAT_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"msgtype":"text","text":{"content":"%s"}}' "$msg")" >/dev/null 2>&1 || return 1
    return 0
}

# ─── Server酱渠道 ───
notify_serverchan() {
    local msg="$1"
    curl -s --connect-timeout 5 \
        -X POST "https://sctapi.ftqq.com/${SERVERCHAN_KEY}.send" \
        -d "title=VTL 通知" \
        -d "content=${msg}" >/dev/null 2>&1 || return 1
    return 0
}

# ─── 邮件 SMTP 渠道（使用 python3 smtplib）───
notify_email() {
    local msg="$1"
    # 安全转义：替换单引号
    local safe_msg
    safe_msg=$(echo "$msg" | sed "s/'/'\\\\''/g")
    python3 -c "
import smtplib
from email.message import EmailMessage
e = EmailMessage()
e.set_content('''${safe_msg}''')
e['Subject'] = 'VTL 通知'
e['From'] = '${EMAIL_FROM}'
e['To'] = '${EMAIL_TO}'
with smtplib.SMTP_SSL('${EMAIL_SMTP_SERVER}', ${EMAIL_SMTP_PORT}) as s:
    s.login('${EMAIL_SMTP_USER}', '${EMAIL_SMTP_PASS}')
    s.send_message(e)
" 2>/dev/null || return 1
    return 0
}

# ─── notify_send: 发送通知（统一入口）───
# 输入: $1 = type (lock|unlock|warn_80|warn_95|test)
#       $2 = extra (附加信息)
# 返回: 0=成功, 1=失败
# 注意: 失败不退出进程，仅记录日志
notify_send() {
    local type="$1"
    local extra="${2:-}"
    local message
    local ret=0

    # NOTIFY_CHANNEL=none 时静默跳过
    [ "$NOTIFY_CHANNEL" = "none" ] && return 0

    # 组装消息
    message=$(notify_build_message "$type" "$extra") || {
        log_write "ERROR" "通知消息组装失败: type=${type}"
        return 1
    }

    # 根据渠道分发
    case "$NOTIFY_CHANNEL" in
        telegram)
            notify_telegram "$message" && ret=0 || ret=1
            ;;
        wechat)
            notify_wechat "$message" && ret=0 || ret=1
            ;;
        email)
            notify_email "$message" && ret=0 || ret=1
            ;;
        serverchan)
            notify_serverchan "$message" && ret=0 || ret=1
            ;;
        *)
            log_write "ERROR" "未知通知渠道: ${NOTIFY_CHANNEL}"
            return 1
            ;;
    esac

    if [ "$ret" -eq 0 ]; then
        log_write "NOTIFY" "发送成功 (${NOTIFY_CHANNEL}) | type=${type}"
    else
        log_write "ERROR" "通知发送失败: 渠道=${NOTIFY_CHANNEL}, type=${type}"
    fi

    return "$ret"
}

# ─── notify_send_test: 发送测试通知 ───
# 输入: 无
# 返回: 0=成功, 1=失败
notify_send_test() {
    notify_send "test" "测试消息" && return 0 || return 1
}
