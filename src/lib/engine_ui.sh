#!/bin/bash
# ===========================================
# VTL 终端渲染引擎 — engine_ui.sh
# 纯输出函数，不操作防火墙
# ===========================================

# ─── 辅助函数（内部使用）────

# 计算字符串的显示宽度（考虑 CJK 全角字符）
# 输出: 整数（显示列数）
_display_width() {
    local s="$1" w=0 i c
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:$i:1}"
        local code
        printf -v code '%d' "'$c" 2>/dev/null
        # CJK / 全角 / Emoji 区域粗略判断（U+2000 以上）
        if [ "$code" -gt 127 ] || [ "$code" -lt 0 ]; then
            w=$((w + 2))
        else
            w=$((w + 1))
        fi
    done
    echo "$w"
}

# 补齐空格使字符串达到指定显示宽度
_pad_to_width() {
    local s="$1"
    local target="$2"
    local current
    current=$(_display_width "$s")
    local needed=$((target - current))
    if [ "$needed" -gt 0 ]; then
        printf "%s%${needed}s" "$s" ""
    else
        printf "%s" "$s"
    fi
}

# 重复字符 n 次
_repeat() {
    local ch="$1" n="$2" i
    for ((i = 0; i < n; i++)); do
        echo -n "$ch"
    done
}

# ─── Terminal 检测 ───

# ui_detect_term: 检测终端宽度
#   设置: TERM_WIDTH (整数), IS_NARROW (bool, 宽度<60时为true)
function ui_detect_term() {
    if command -v tput >/dev/null 2>&1; then
        TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    else
        TERM_WIDTH=80
    fi
    [ "$TERM_WIDTH" -lt 60 ] && IS_NARROW=true || IS_NARROW=false
}

# ─── 渲染原语 ───

# ui_progress_bar: 渲染进度条
#   输入: $1 = percent (浮点数, 如 80.41)
#         $2 = width (整数, 进度条字符宽度, 默认终端宽度一半)
#   打印: ████████░░░░ 带百分比
function ui_progress_bar() {
    local percent="$1"
    local width="${2:-$((TERM_WIDTH / 2))}"
    [ "$width" -lt 5 ] && width=5
    [ "$width" -gt 80 ] && width=80

    local filled unfilled
    filled=$(awk "BEGIN{printf \"%d\", $percent * $width / 100}")
    [ "$filled" -lt 0 ] && filled=0
    [ "$filled" -gt "$width" ] && filled=$width
    unfilled=$((width - filled))

    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do
        bar="${bar}█"
    done
    for ((i = 0; i < unfilled; i++)); do
        bar="${bar}░"
    done
    printf "%s %s%%" "$bar" "$percent"
}

# ui_hr: 渲染分隔线
#   输入: $1 = 字符（默认 ─）
function ui_hr() {
    local ch="${1:-─}"
    local width=$TERM_WIDTH
    if $IS_NARROW; then
        width=$((TERM_WIDTH > 40 ? TERM_WIDTH : 40))
    fi
    echo
    _repeat "$ch" "$width"
    echo
}

# ui_box: 渲染带边框的盒子（单层框）
#   输入: $1 = 标题行
#         $2个参数起 = 内容行（每个参数一行）
function ui_box() {
    local title="$1"
    shift
    local lines=("$@")

    # 窄终端降级——无框纯文本
    if $IS_NARROW; then
        echo ""
        echo "$title"
        local sep_width=$((TERM_WIDTH > 30 ? TERM_WIDTH : 30))
        _repeat "-" "$sep_width"
        echo
        local line
        for line in "${lines[@]}"; do
            echo "$line"
        done
        _repeat "-" "$sep_width"
        echo
        return
    fi

    # 计算最宽行
    local max_content=0 len
    len=$(_display_width "$title")
    [ "$len" -gt "$max_content" ] && max_content=$len
    local line
    for line in "${lines[@]}"; do
        len=$(_display_width "$line")
        [ "$len" -gt "$max_content" ] && max_content=$len
    done

    # 框内宽 = 内容宽 + 2 (左右空格)
    local inner_width=$((max_content + 2))
    local total_width=$((inner_width + 2))   # + 左边框 + 右边框

    # 不要超过终端宽度
    [ "$total_width" -gt "$TERM_WIDTH" ] && total_width=$TERM_WIDTH
    [ "$total_width" -lt 10 ] && total_width=10

    local horiz
    horiz=$(_repeat "─" $((total_width - 2)))

    # 顶边框
    printf "┌%s┐\n" "$horiz"

    # 标题行（居左）
    printf "│ %s│\n" "$(_pad_to_width "$title" "$((total_width - 3))")"

    # 有内容行 → 分隔线 + 内容
    if [ ${#lines[@]} -gt 0 ]; then
        printf "├%s┤\n" "$horiz"
        local line
        for line in "${lines[@]}"; do
            printf "│ %s│\n" "$(_pad_to_width "$line" "$((total_width - 3))")"
        done
    fi

    # 底边框
    printf "└%s┘\n" "$horiz"
}

# ─── 显示函数 ───

# ui_show_status: 显示 llcx -c 状态
#   输入: 读取全局 + 需要参数: $1=used_gb, $2=limit_gb, $3=percent,
#         $4=direction, $5=interface, $6=mode, $7=locked(bool)
function ui_show_status() {
    local used_gb="${1:-${USED_GB:-0}}"
    local limit_gb="${2:-${LIMIT_GB:-0}}"
    local percent="${3:-${USED_PERCENT:-0}}"
    local direction="${4:-${DIRECTION:-egress}}"
    local interface="${5:-${INTERFACE:-unknown}}"
    local mode="${6:-${MODE:-strict}}"
    local locked="${7:-0}"
    # 格式化锁定状态: 转 "true"/"false" 字符串为 0/1
    [ "$locked" = "true" ] && locked=1
    [ "$locked" = "false" ] && locked=0

    # 实际锁定状态检查（如果 fw_is_locked 可用）
    if [ "$locked" = "0" ] && command -v fw_is_locked >/dev/null 2>&1; then
        fw_is_locked && locked=1
    fi

    # 格式化数值
    local used_fmt limit_fmt remain_fmt
    used_fmt=$(awk "BEGIN{printf \"%.2f\", $used_gb}")
    limit_fmt=$(awk "BEGIN{printf \"%.2f\", $limit_gb}")
    local remain_gb
    remain_gb=$(awk "BEGIN{printf \"%.2f\", $limit_gb - $used_gb}")
    remain_fmt="$remain_gb"

    # 方向描述
    local dir_desc="上行"
    [ "$direction" = "ingress" ] && dir_desc="下行"
    [ "$direction" = "total" ] && dir_desc="合计"

    # 当月
    local month
    month=$(date "+%Y-%m")

    # ─── 场景判断 ───
    local status_emoji status_text remain_text
    local extra_lines=()

    if [ "$locked" = "1" ] || [ "$locked" = "true" ]; then
        # 场景4/5: 已锁定
        status_emoji="🔒"

        if [ "$mode" = "custom" ] && [ -n "$EXTRA_PORTS" ]; then
            status_text="已锁定 (custom)"
            extra_lines+=("放行端口         22, 53, ${EXTRA_PORTS} (SSH+DNS+自定义)")
        else
            status_text="已锁定 (strict)"
            extra_lines+=("放行端口         22, 53 (SSH+DNS)")
        fi

        # 获取锁定时间
        local lock_time="未知"
        if [ -f "$LOCK_STATE_FILE" ]; then
            lock_time=$(head -1 "$LOCK_STATE_FILE" | cut -d'|' -f1)
            [ -z "$lock_time" ] && lock_time=$(stat -c "%y" "$LOCK_STATE_FILE" 2>/dev/null | cut -d. -f1)
        fi
        extra_lines+=("锁定时间         $lock_time")
        local over_gb
        over_gb=$(awk "BEGIN{printf \"%.2f\", $used_gb - $limit_gb}")
        extra_lines+=("超限量           +${over_gb} GB")

    elif [ "$(awk "BEGIN{print ($percent >= $CRIT_PERCENT)}")" -eq 1 ]; then
        # 场景3: 95% 极度预警
        status_emoji="🔴"
        status_text="极度接近限额 (${CRIT_PERCENT}%)"
        extra_lines+=("剩余流量         ${remain_fmt} GB")
        extra_lines+=("⚠️  即将到达限额，请及时处理")

    elif [ "$(awk "BEGIN{print ($percent >= $WARN_PERCENT)}")" -eq 1 ]; then
        # 场景2: 80% 预警
        status_emoji="🟡"
        status_text="已达 ${WARN_PERCENT}% 预警线"
        extra_lines+=("剩余流量         ${remain_fmt} GB")
        extra_lines+=("⚠️  注意控制流量使用")

    else
        # 场景1: 正常
        status_emoji="🟢"
        status_text="正常运行"
        extra_lines+=("剩余流量         ${remain_fmt} GB")
    fi

    # 防火墙状态
    local fw_status="iptables"
    command -v iptables >/dev/null 2>&1 || fw_status="未检测"

    # 构建内容
    local content=()
    content+=("网卡              ${interface}")
    content+=("月份              ${month}")
    content+=("${dir_desc}             ${used_fmt} GB  $(ui_progress_bar "$percent" 20)")
    content+=("限额              ${limit_fmt} GB        [${direction}]")
    content+=("模式              ${mode}  防火墙: ${fw_status}")
    content+=("")
    content+=("状态              ${status_emoji} ${status_text}")
    local i
    for i in "${extra_lines[@]}"; do
        content+=("$i")
    done

    ui_box "📊 本月流量查询" "${content[@]}"
}

# ui_show_report: 显示 llcx -r 月度汇总
#   输入: 无 (从 vnstat -m 获取数据)
# ui_show_report: 显示 llcx -r 月度汇总
#   输入: 无 (从 vnstat -m 获取数据)
function ui_show_report() {
    export LC_ALL=C 2>/dev/null || true
    # 静默模式：抑制 awk stderr 输出
    exec 2>/dev/null
    local interface="${INTERFACE:-$(detect_interface 2>/dev/null || echo ens4)}"
    local limit_gb="${LIMIT_GB:-0}"
    local direction="${DIRECTION:-egress}"

    local dir_label="上行"
    [ "$direction" = "ingress" ] && dir_label="下行"
    [ "$direction" = "total" ] && dir_label="合计"

    if ! command -v vnstat >/dev/null 2>&1; then
        ui_box "📅 月度流量汇总 · 历史数据" "" "❌ vnstat 未安装" ""
        return 1
    fi

    # 用 python3 解析 vnstat -m --json，更稳定
    local json_data
    json_data=$(vnstat -i "$interface" -m --json 2>/dev/null)
    if [ -z "$json_data" ]; then
        ui_box "📅 月度流量汇总 · 历史数据" "" "暂无月度数据（vnstat 数据采集中）" ""
        return
    fi

    local parsed
    parsed=$(echo "$json_data" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data['interfaces']:
        if iface['name'] == '$interface':
            months = iface['traffic']['month']
            for m in months:
                y = m['date']['year']
                mo = m['date']['month']
                rx = m['rx']
                tx = m['tx']
                total = tx + rx
                rx_gb = rx / 1073741824.0
                tx_gb = tx / 1073741824.0
                total_gb = total / 1073741824.0
                print(f'{y:04d}-{mo:02d}|{tx_gb:.2f}|{rx_gb:.2f}|{total_gb:.2f}|{tx}|{rx}')
            break
except: pass
" 2>/dev/null)

    if [ -z "$parsed" ]; then
        ui_box "📅 月度流量汇总 · 历史数据" "" "暂无月度数据" ""
        return
    fi

    # 构建表格内容
    local content=()
    content+=("网卡: ${interface}    计费方向: ${direction} (${dir_label})")

    local sep="${cw1:-8}─┬─── ──┬─── ──┬─── ──┬─── ──"

    local h1="月份" h2="${dir_label}" h3="下行" h4="合计" h5="状态"

    local header=""
    header+="$(_pad_to_width "$h1" 8)│"
    header+="$(_pad_to_width "$h2" 10)│"
    header+="$(_pad_to_width "$h3" 10)│"
    header+="$(_pad_to_width "$h4" 10)│"
    header+="$(_pad_to_width "$h5" 20)"

    local sep; sep=$(_repeat "─" 8); sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 20)"; content+=("$sep")  # 假装分隔线
    content+=("$header")
    local sep; sep=$(_repeat "─" 8); sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 20)"; content+=("$sep")

    local total_tx=0 total_rx=0 total_all=0 count=0
    local line month tx_val rx_val total_val tx_bytes rx_bytes

    while IFS='|' read -r month tx_val rx_val total_val tx_bytes rx_bytes; do
        [ -z "$month" ] && continue
        tx_val=$(printf "%.2f" "$tx_val")
        rx_val=$(printf "%.2f" "$rx_val")
        total_val=$(printf "%.2f" "$total_val")

        local ref_gb=0
        [ "$direction" = "egress" ] && ref_gb=$tx_val
        [ "$direction" = "ingress" ] && ref_gb=$rx_val
        [ "$direction" = "total" ] && ref_gb=$total_val

        local status_text="🟢 正常"
        local pct
        if [ "$(awk 2>/dev/null || echo 0 "BEGIN{print $ref_gb > $limit_gb}" 2>/dev/null || echo 0)" = "1" ] && [ "$(awk "BEGIN{printf "%.2f", $limit_gb > 0}")" = "1" ]; then
            pct=$(awk 2>/dev/null || echo 0 "BEGIN{printf "%.2f", scale=0; $ref_gb * 100 / $limit_gb}")
            status_text="🔴 已锁定(超限 ${pct}%)"
        elif [ "$(awk 2>/dev/null || echo 0 "BEGIN{print $ref_gb > $limit_gb * 0.95}" 2>/dev/null || echo 0)" = "1" ] && [ "$(awk "BEGIN{printf "%.2f", $limit_gb > 0}")" = "1" ]; then
            pct=$(awk 2>/dev/null || echo 0 "BEGIN{printf "%.2f", scale=0; $ref_gb * 100 / $limit_gb}")
            status_text="🔴 极度接近(${pct}%)"
        elif [ "$(awk 2>/dev/null || echo 0 "BEGIN{print $ref_gb > $limit_gb * 0.8}" 2>/dev/null || echo 0)" = "1" ] && [ "$(awk "BEGIN{printf "%.2f", $limit_gb > 0}")" = "1" ]; then
            pct=$(awk 2>/dev/null || echo 0 "BEGIN{printf "%.2f", scale=0; $ref_gb * 100 / $limit_gb}")
            status_text="🟡 接近限额(${pct}%)"
        fi

        local data_line=""
        data_line+="$(_pad_to_width "$month" 8)│"
        data_line+="$(_pad_to_width "$tx_val" 10)│"
        data_line+="$(_pad_to_width "$rx_val" 10)│"
        data_line+="$(_pad_to_width "$total_val" 10)│"
        data_line+="$(_pad_to_width "$status_text" 20)"

        content+=("$data_line")

        total_tx=$(awk "BEGIN{printf "%.2f", $total_tx + $tx_val}")
        total_rx=$(awk "BEGIN{printf "%.2f", $total_rx + $rx_val}")
        total_all=$(awk "BEGIN{printf "%.2f", $total_all + $total_val}")
        count=$((count + 1))
    done <<< "$parsed"

    local sep; sep=$(_repeat "─" 8); sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 10)"; sep="${sep}┼"; sep="${sep}$(_repeat "─" 20)"; content+=("$sep")

    # 合计
    local sum_line=""
    sum_line+="$(_pad_to_width "合计" 8)│"
    sum_line+="$(_pad_to_width "$(printf "%.2f" "$total_tx")" 10)│"
    sum_line+="$(_pad_to_width "$(printf "%.2f" "$total_rx")" 10)│"
    sum_line+="$(_pad_to_width "$(printf "%.2f" "$total_all")" 10)│"
    sum_line+="$(_pad_to_width "" 20)"
    content+=("$sum_line")

    if [ "$count" -gt 0 ]; then
        local avg_line=""
        avg_line+="$(_pad_to_width "月均" 8)│"
        avg_line+="$(_pad_to_width "$(printf "%.2f" "$(awk "BEGIN{printf "%.2f", $total_tx / $count}" -l)")" 10)│"
        avg_line+="$(_pad_to_width "$(printf "%.2f" "$(awk "BEGIN{printf "%.2f", $total_rx / $count}" -l)")" 10)│"
        avg_line+="$(_pad_to_width "$(printf "%.2f" "$(awk "BEGIN{printf "%.2f", $total_all / $count}" -l)")" 10)│"
        avg_line+="$(_pad_to_width "" 20)"
        content+=("$avg_line")
    fi

    ui_box "📅 月度流量汇总 · 历史数据" "${content[@]}"
}
function ui_main_menu() {
    local IS_NARROW=${IS_NARROW:-false}
    ui_detect_term
    while true; do
        clear

        # 尝试获取流量概要
        local used_fmt="--" limit_fmt="--" pct="--" status_line="  等待数据..." status_emoji="⏳"
        if command -v vnstat >/dev/null 2>&1 && [ -n "$INTERFACE" ]; then
            local raw
            raw=$(vnstat -i "$INTERFACE" --oneline b 2>/dev/null)
            if [ -n "$raw" ]; then
                local rx tx total
                rx=$(echo "$raw" | awk -F';' '{print $8}')
                tx=$(echo "$raw" | awk -F';' '{print $9}')
                total=$(echo "$raw" | awk -F';' '{print $10}')
                [ -z "$tx" ] && tx=0
                [ -z "$LIMIT_GB" ] && LIMIT_GB=0
                local used_bytes=0
                [ "$DIRECTION" = "egress" ] && used_bytes=$tx
                [ "$DIRECTION" = "ingress" ] && used_bytes=$rx
                [ "$DIRECTION" = "total" ] && used_bytes=$total
                local used_gb
                used_gb=$(awk "BEGIN{printf \"%.2f\", $used_bytes / 1073741824}")
                used_fmt="$used_gb"
                limit_fmt=$(awk "BEGIN{printf \"%.2f\", $LIMIT_GB}")
                pct=$(awk "BEGIN{printf \"%.1f\", $used_bytes / $LIMIT_GB / 1073741824 * 100}")

                local locked=false
                if command -v fw_is_locked >/dev/null 2>&1; then
                    fw_is_locked && locked=1
                fi

                if [ "$locked" = "1" ] || [ "$locked" = "true" ]; then
                    status_emoji="🔒"
                    status_line="已锁定"
                elif [ "$(awk "BEGIN{print ($pct >= $CRIT_PERCENT)}")" -eq 1 ]; then
                    status_emoji="🔴"
                    status_line="极度接近限额 (${CRIT_PERCENT}%)"
                elif [ "$(awk "BEGIN{print ($pct >= $WARN_PERCENT)}")" -eq 1 ]; then
                    status_emoji="🟡"
                    status_line="已达 ${WARN_PERCENT}% 预警线"
                else
                    status_emoji="🟢"
                    status_line="正常"
                fi
            fi
        fi

        # 通知状态
        local notify_status="❌ 未配置"
        [ -n "$TELEGRAM_BOT_TOKEN" ] && notify_status="✅ Telegram"
        [ -n "$WECHAT_WEBHOOK_URL" ] && notify_status="✅ 企业微信"
        [ -n "$EMAIL_SMTP_SERVER" ] && notify_status="✅ 邮件"
        [ -n "$SERVERCHAN_KEY" ] && notify_status="✅ Server酱"
        [ "$NOTIFY_CHANNEL" = "none" ] && notify_status="❌ 未配置"

        # 防火墙状态
        local fw_avail="未检测"
        command -v iptables >/dev/null 2>&1 && fw_avail="iptables"

        local content=()
        content+=("")
        content+=("  网卡: ${INTERFACE:---}         方向: ${DIRECTION:-egress}")
        content+=("  已用: ${used_fmt} GB    限额: ${limit_fmt} GB    ${pct}%")
        content+=("  状态: ${status_emoji} ${status_line}      防火墙: ${fw_avail}   模式: ${MODE:-strict}")
        content+=("  通知: ${notify_status}")
        content+=("")
        content+=("  请选择操作:")
        content+=("")
        content+=("    1) 📊  本月流量查询      — 详细流量数据 + 进度条")
        content+=("    2) 📅  历史月度汇总      — 各月流量账单对比")
        content+=("    3) 🔒  锁定管理          — 手动锁定 / 解锁 / 状态")
        content+=("    4) ⚙️  配置管理          — 修改接口/限额/通知等")
        content+=("    5) 📋  查看日志          — 系统运行日志")
        content+=("    6) 🔔  发送测试通知      — 验证通知是否正常")
        content+=("    7) ❌  卸载系统          — 完全移除 VTL")
        content+=("")
        content+=("    q)   退出")

        ui_box "🛡️  VPS 流量监控系统  v5.0" "${content[@]}"

        if $IS_NARROW; then
            echo -n "  请输入选项 [1-7/q]: "
        else
            # 框外提示
            echo ""
            echo -n "  请输入选项 [1-7/q]: "
        fi
        read -r choice

        case "$choice" in
            1) ui_status_menu ;;
            2) ui_report_menu ;;
            3) ui_lock_menu ;;
            4) ui_config_menu ;;
            5) ui_logs_menu ;;
            6) ui_notify_menu ;;
            7) ui_uninstall_menu ;;
            q|Q) echo ""; exit 0 ;;
            *) ;;
        esac
    done
}

# ui_status_menu: 子菜单1 本月流量
function ui_status_menu() {
    while true; do
        ui_detect_term
        clear

        # 获取流量数据
        local used_gb=0 limit_gb="${LIMIT_GB:-0}" percent=0
        local locked=false

        if command -v vnstat >/dev/null 2>&1 && [ -n "$INTERFACE" ]; then
            local raw
            raw=$(vnstat -i "$INTERFACE" --oneline b 2>/dev/null)
            if [ -n "$raw" ]; then
                local rx tx total
                rx=$(echo "$raw" | awk -F';' '{print $8}')
                tx=$(echo "$raw" | awk -F';' '{print $9}')
                total=$(echo "$raw" | awk -F';' '{print $10}')
                [ -z "$tx" ] && tx=0
                local used_bytes=0
                [ "$DIRECTION" = "egress" ] && used_bytes=$tx
                [ "$DIRECTION" = "ingress" ] && used_bytes=$rx
                [ "$DIRECTION" = "total" ] && used_bytes=$total
                used_gb=$(awk "BEGIN{printf \"%.2f\", $used_bytes / 1073741824}")
                limit_gb=$(awk "BEGIN{printf \"%.2f\", $LIMIT_GB}")
                percent=$(awk "BEGIN{printf \"%.1f\", $used_bytes / $LIMIT_GB / 1073741824 * 100}")
            fi
        fi

        if command -v fw_is_locked >/dev/null 2>&1; then
            fw_is_locked && locked=1
        fi

        ui_show_status "$used_gb" "$limit_gb" "$percent" "$DIRECTION" "$INTERFACE" "$MODE" "$locked"

        echo ""
        # 操作栏
        local actions
        if [ "$locked" = "1" ] || [ "$locked" = "true" ]; then
            actions="  [1] 刷新  [2] 解锁  [3] 配置  [q] 返回上级"
        else
            actions="  [1] 刷新  [2] 锁定管理  [3] 配置  [q] 返回上级"
        fi
        echo "$actions"

        # 框底线(模拟)
        local line_w=$TERM_WIDTH
        [ "$line_w" -gt 80 ] && line_w=80
        _repeat "─" "$line_w"
        echo ""

        echo -n "  请输入选项: "
        read -r choice

        case "$choice" in
            1) continue ;;  # 刷新：重新循环
            2)
                if [ "$locked" = "1" ] || [ "$locked" = "true" ]; then
                    # 解锁
                    if command -v fw_unlock >/dev/null 2>&1; then
                        fw_unlock
                        if command -v notify_send >/dev/null 2>&1; then
                            notify_send unlock "手动解锁"
                        fi
                        echo "  ✅ 已解锁"
                    else
                        echo "  ❌ fw_unlock 不可用"
                    fi
                else
                    # 跳锁定管理
                    ui_lock_menu
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            3)
                ui_config_menu
                ;;
            q|Q) return ;;
            *) ;;
        esac
    done
}

# ui_report_menu: 子菜单2 历史汇总
function ui_report_menu() {
    ui_detect_term
    clear
    ui_show_report
    echo ""
    echo -n "  [q] 返回上级: "
    while true; do
        read -r choice
        case "$choice" in
            q|Q) return ;;
            *) echo -n "  [q] 返回上级: " ;;
        esac
    done
}

# ui_lock_menu: 子菜单3 锁定管理
function ui_lock_menu() {
    while true; do
        ui_detect_term
        clear

        local locked=false
        if command -v fw_is_locked >/dev/null 2>&1; then
            fw_is_locked && locked=1
        fi

        local lock_status="🟢 未锁定"
        $locked && lock_status="🔴 已锁定"

        local fw_avail="未检测"
        command -v iptables >/dev/null 2>&1 && fw_avail="iptables"

        local content=()
        content+=("当前状态: ${lock_status}")
        content+=("防火墙: ${fw_avail}  模式: ${MODE:-strict}")
        content+=("放行端口: ${SSH_PORTS:-22}, 53 (SSH+DNS)")
        if [ "$MODE" = "custom" ] && [ -n "$EXTRA_PORTS" ]; then
            content+=("额外放行: ${EXTRA_PORTS}")
        fi
        content+=("")
        content+=("  1) 🔒 手动锁定")
        content+=("     立即阻断除 SSH+DNS 外的所有出站流量")
        content+=("")
        content+=("  2) 🔓 手动解锁")
        content+=("     移除锁定规则，恢复所有出站流量")
        content+=("")
        content+=("  3) 🧪 测试锁定 (30秒自动恢复)")
        content+=("     模拟锁定30秒，可验证SSH是否正常，到期自动解锁")
        content+=("")
        content+=("  q) ↩️  返回主菜单")

        ui_box "🔒 锁定管理" "${content[@]}"
        echo ""
        echo -n "  请输入选项: "
        read -r choice

        case "$choice" in
            1)
                if command -v fw_lock >/dev/null 2>&1; then
                    fw_lock
                    if command -v notify_send >/dev/null 2>&1; then
                        notify_send lock "手动锁定"
                    fi
                    echo "  ✅ 已锁定"
                else
                    echo "  ❌ fw_lock 不可用"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            2)
                if command -v fw_unlock >/dev/null 2>&1; then
                    fw_unlock
                    if command -v notify_send >/dev/null 2>&1; then
                        notify_send unlock "手动解锁"
                    fi
                    echo "  ✅ 已解锁"
                else
                    echo "  ❌ fw_unlock 不可用"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            3)
                if command -v fw_test >/dev/null 2>&1; then
                    (
                        fw_test &
                    )
                    echo "  🧪 测试锁定中 (30 秒)..."
                    echo "  ⚠️ 除 SSH 和 DNS 外的所有出站流量已被阻断"
                    echo ""
                    echo "  按 Enter 键立即恢复..."
                    read -r
                    if command -v fw_unlock >/dev/null 2>&1; then
                        fw_unlock
                        echo "  ✅ 已恢复"
                    fi
                else
                    echo "  ❌ fw_test 不可用"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            q|Q) return ;;
            *) ;;
        esac
    done
}

# ui_config_menu: 子菜单4 配置管理
function ui_config_menu() {
    while true; do
        ui_detect_term
        clear

        local notify_status="未配置"
        [ -n "$TELEGRAM_BOT_TOKEN" ] && notify_status="Telegram ✅"
        [ -n "$WECHAT_WEBHOOK_URL" ] && notify_status="企业微信 ✅"
        [ -n "$EMAIL_SMTP_SERVER" ] && notify_status="邮件 ✅"
        [ -n "$SERVERCHAN_KEY" ] && notify_status="Server酱 ✅"
        [ "$NOTIFY_CHANNEL" = "none" ] && notify_status="未配置"

        local content=()
        content+=("当前配置:")
        content+=("")
        content+=("    接口:     ${INTERFACE:---}")
        content+=("    SSH端口:  ${SSH_PORTS:-22}")
        content+=("    限额:     ${LIMIT_GB:-0}.00 GB (${DIRECTION:-egress})")
        content+=("    模式:     ${MODE:-strict}")
        content+=("    防火墙:   iptables")
        content+=("    通知:     ${notify_status}")
        content+=("    时区:     ${PROVIDER_TIMEZONE:-UTC}")
        content+=("    结算日:   每月 ${RESET_DAY:-1} 号")
        content+=("    IPv6:     ${IPV6_POLICY:-dual}")
        content+=("")
        content+=("  1) 修改监控接口/限额")
        content+=("  2) 修改锁定模式/端口")
        content+=("  3) 修改通知配置")
        content+=("  4) 修改 SSH 端口检测结果")
        content+=("  5) 修改计费时区/结算日")
        content+=("  6) 📄 查看完整配置")
        content+=("  q) ↩️  返回主菜单")

        ui_box "⚙️  配置管理" "${content[@]}"
        echo ""
        echo -n "  请输入选项: "
        read -r choice

        case "$choice" in
            1)
                echo ""
                echo "  ⚙️  修改监控接口/限额"
                echo "  ──────────────────────"
                echo -n "  请输入接口名 [${INTERFACE:-ens4}]: "
                read -r new_iface
                [ -z "$new_iface" ] && new_iface="${INTERFACE:-ens4}"
                echo -n "  请输入流量限额(GB) [${LIMIT_GB:-170}]: "
                read -r new_limit
                [ -z "$new_limit" ] && new_limit="${LIMIT_GB:-170}"

                # 写入配置（调用外部配置更新函数或直接写文件）
                if [ -f "$CONF_DIR/config" ]; then
                    sed -i "s/^INTERFACE=.*/INTERFACE=\"$new_iface\"/" "$CONF_DIR/config"
                    sed -i "s/^LIMIT_GB=.*/LIMIT_GB=$new_limit/" "$CONF_DIR/config"
                    # 重新加载
                    source "$CONF_DIR/config" 2>/dev/null
                    echo "  ✅ 配置已更新"
                else
                    echo "  ❌ 配置文件不存在: $CONF_DIR/config"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            2)
                echo ""
                echo "  ⚙️  修改锁定模式"
                echo "  ──────────────"
                echo "  当前模式: ${MODE:-strict}"
                echo ""
                echo "  1) strict — 仅放行 SSH 和 DNS，其他全部拦截"
                echo "  2) custom — 放行 SSH + DNS + 自定义端口"
                echo -n "  请选择新模式 [当前: ${MODE:-strict}]: "
                read -r new_mode
                case "$new_mode" in
                    1|strict|"")
                        new_mode="strict"
                        new_extra=""
                        ;;
                    2|custom)
                        new_mode="custom"
                        echo -n "  请输入放行端口 (逗号分隔，支持范围): "
                        read -r new_extra
                        ;;
                    *)
                        echo "  ⚠️  无效选项，跳过"
                        new_mode="${MODE:-strict}"
                        ;;
                esac

                if [ -f "$CONF_DIR/config" ]; then
                    sed -i "s/^MODE=.*/MODE=\"$new_mode\"/" "$CONF_DIR/config"
                    sed -i "s/^EXTRA_PORTS=.*/EXTRA_PORTS=\"$new_extra\"/" "$CONF_DIR/config"
                    source "$CONF_DIR/config" 2>/dev/null
                    echo "  ✅ 配置已更新"
                    echo "  ⚠️ 新配置将在下次定时检查时生效"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            3)
                echo ""
                echo "  ⚙️  通知配置修改需编辑配置文件"
                echo "  ${CONF_DIR:-/opt/vps-traffic-limit/conf}/config"
                echo ""
                echo "  相关变量:"
                echo "    NOTIFY_CHANNEL  (none|telegram|wechat|email|serverchan)"
                echo "    TELEGRAM_BOT_TOKEN"
                echo "    TELEGRAM_CHAT_ID"
                echo "    WECHAT_WEBHOOK_URL"
                echo "    EMAIL_SMTP_*"
                echo "    SERVERCHAN_KEY"
                echo "  按 Enter 继续..."
                read -r
                ;;
            4)
                echo ""
                echo -n "  请输入 SSH 端口 (逗号分隔) [${SSH_PORTS:-22}]: "
                read -r new_ssh
                [ -z "$new_ssh" ] && new_ssh="${SSH_PORTS:-22}"
                if [ -f "$CONF_DIR/config" ]; then
                    sed -i "s/^SSH_PORTS=.*/SSH_PORTS=\"$new_ssh\"/" "$CONF_DIR/config"
                    source "$CONF_DIR/config" 2>/dev/null
                    echo "  ✅ SSH 端口已更新: $new_ssh"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            5)
                echo ""
                echo -n "  请输入计费时区 (IANA格式) [${PROVIDER_TIMEZONE:-UTC}]: "
                read -r new_tz
                [ -z "$new_tz" ] && new_tz="${PROVIDER_TIMEZONE:-UTC}"
                echo -n "  请输入结算日 (1-28) [${RESET_DAY:-1}]: "
                read -r new_day
                [ -z "$new_day" ] && new_day="${RESET_DAY:-1}"

                if [ -f "$CONF_DIR/config" ]; then
                    sed -i "s|^PROVIDER_TIMEZONE=.*|PROVIDER_TIMEZONE=\"$new_tz\"|" "$CONF_DIR/config"
                    sed -i "s/^RESET_DAY=.*/RESET_DAY=$new_day/" "$CONF_DIR/config"
                    source "$CONF_DIR/config" 2>/dev/null
                    echo "  ✅ 时区/结算日已更新"
                fi
                echo "  按 Enter 继续..."
                read -r
                ;;
            6)
                echo ""
                if [ -f "$CONF_DIR/config" ]; then
                    cat "$CONF_DIR/config"
                else
                    echo "  ❌ 配置文件不存在"
                fi
                echo ""
                echo "  按 Enter 继续..."
                read -r
                ;;
            q|Q) return ;;
            *) ;;
        esac
    done
}

# ui_logs_menu: 子菜单5 查看日志
function ui_logs_menu() {
    while true; do
        ui_detect_term
        clear

        local log_file="${LOG_FILE:-/var/log/vtl-core.log}"

        local content=()
        content+=("日志文件: $log_file")
        content+=("")
        content+=("  1) 查看最近 20 条")
        content+=("  2) 📡 实时追踪 (Ctrl+C 退出)")
        content+=("  3) 查看锁定/解锁事件")
        content+=("  4) 查看通知发送记录")
        content+=("  q) ↩️  返回主菜单")

        ui_box "📋 系统日志" "${content[@]}"
        echo ""
        echo -n "  请输入选项: "
        read -r choice

        case "$choice" in
            1)
                echo ""
                if [ -f "$log_file" ]; then
                    tail -20 "$log_file"
                else
                    echo "  📭 日志文件不存在: $log_file"
                fi
                echo ""
                echo "  按 Enter 继续..."
                read -r
                ;;
            2)
                if [ -f "$log_file" ]; then
                    echo "  📡 实时追踪中 (Ctrl+C 退出)..."
                    tail -f "$log_file"
                else
                    echo "  📭 日志文件不存在"
                    echo "  按 Enter 继续..."
                    read -r
                fi
                ;;
            3)
                echo ""
                if [ -f "$log_file" ]; then
                    grep -E '\[LOCK\]|\[UNLOCK\]' "$log_file" | tail -20
                else
                    echo "  📭 日志文件不存在"
                fi
                echo ""
                echo "  按 Enter 继续..."
                read -r
                ;;
            4)
                echo ""
                if [ -f "$log_file" ]; then
                    grep -E '\[NOTIFY\]|\[WARN\]' "$log_file" | tail -20
                else
                    echo "  📭 日志文件不存在"
                fi
                echo ""
                echo "  按 Enter 继续..."
                read -r
                ;;
            q|Q) return ;;
            *) ;;
        esac
    done
}

# ui_notify_menu: 子菜单6 测试通知
function ui_notify_menu() {
    ui_detect_term
    clear

    local notify_status="未配置"
    [ -n "$TELEGRAM_BOT_TOKEN" ] && notify_status="Telegram"
    [ -n "$WECHAT_WEBHOOK_URL" ] && notify_status="企业微信"
    [ -n "$EMAIL_SMTP_SERVER" ] && notify_status="邮件"
    [ -n "$SERVERCHAN_KEY" ] && notify_status="Server酱"
    [ "$NOTIFY_CHANNEL" = "none" ] && notify_status="未配置"

    local content=()
    content+=("通知渠道: ${NOTIFY_CHANNEL:-none}")
    content+=("")
    if [ "$NOTIFY_CHANNEL" = "telegram" ]; then
        local token_masked="${TELEGRAM_BOT_TOKEN:0:10}...${TELEGRAM_BOT_TOKEN: -5}"
        content+=("Bot Token:  ${token_masked}")
        content+=("Chat ID:    ${TELEGRAM_CHAT_ID:---}")
    elif [ "$NOTIFY_CHANNEL" = "wechat" ]; then
        local webhook_masked="${WECHAT_WEBHOOK_URL:0:20}..."
        content+=("Webhook:    ${webhook_masked}")
    elif [ "$NOTIFY_CHANNEL" = "email" ]; then
        content+=("SMTP:       ${EMAIL_SMTP_SERVER}:${EMAIL_SMTP_PORT}")
        content+=("发件人:     ${EMAIL_FROM:-${EMAIL_SMTP_USER:---}}")
        content+=("收件人:     ${EMAIL_TO:---}")
    elif [ "$NOTIFY_CHANNEL" = "serverchan" ]; then
        content+=("SendKey:    ${SERVERCHAN_KEY:0:8}...")
    else
        content+=("  ⚠️  未配置通知渠道")
        content+=("  请先在配置管理中设置通知")
    fi

    ui_box "🔔 测试通知发送" "${content[@]}"
    echo ""

    if [ "$NOTIFY_CHANNEL" != "none" ] && [ "$NOTIFY_CHANNEL" != "none" ]; then
        echo "  ⏳ 正在发送测试消息..."

        if command -v notify_send_test >/dev/null 2>&1; then
            if notify_send_test; then
                echo ""
                echo "  ✅ 发送成功！"
                echo "     请检查你的 ${notify_status}，应该收到了一条测试消息"
            else
                echo ""
                echo "  ❌ 发送失败！"
                echo "     可能原因: VPS 出站被拦截或 DNS 污染"
            fi
        else
            if command -v notify_send >/dev/null 2>&1; then
                if notify_send test "系统测试消息"; then
                    echo ""
                    echo "  ✅ 发送成功！"
                else
                    echo ""
                    echo "  ❌ 发送失败！"
                fi
            else
                echo "  ❌ notify_send_test/notify_send 函数不可用"
                echo "  请确认 engine_notify.sh 已加载"
            fi
        fi
    fi

    echo ""
    echo "  [1] 重试  [2] 修改通知配置  [q] 返回"
    echo -n "  请输入选项: "
    while true; do
        read -r choice
        case "$choice" in
            1) ui_notify_menu; return ;;
            2) ui_config_menu; return ;;
            q|Q) return ;;
            *) echo -n "  请输入选项: " ;;
        esac
    done
}

# ui_uninstall_menu: 子菜单7 卸载系统
function ui_uninstall_menu() {
    ui_detect_term
    clear

    local content=()
    content+=("")
    content+=("  ⚠️  即将执行以下操作:")
    content+=("")
    content+=("  • 停止并删除 systemd 定时器和服务")
    content+=("  • 清除防火墙锁定规则")
    content+=("  • 删除 /opt/vps-traffic-limit/")
    content+=("  • 删除快捷命令 /usr/local/bin/llcx")
    content+=("  • 删除日志文件和配置")
    content+=("  • (保留 vnstat 历史数据)")
    content+=("")

    ui_box "❌ 卸载 VPS 流量监控系统" "${content[@]}"
    echo ""
    echo -n "  确认卸载? [y/N]: "
    read -r confirm1
    case "$confirm1" in
        y|Y)
            echo ""
            echo -n "  ⚠️  再次确认？这将完全移除系统！"
            echo ""
            echo -n '  输入 "YES" 确认: '
            read -r confirm2
            if [ "$confirm2" = "YES" ]; then
                echo ""
                echo "  ⏳ 正在卸载..."

                # 执行卸载操作
                if command -v fw_unlock >/dev/null 2>&1; then
                    fw_unlock
                    echo "  ✅ 防火墙规则已清除"
                fi

                # 停止并禁用 systemd 服务
                local services
                services="vtl-check.timer vtl-check.service vtl-reset.timer vtl-monthly.service vtl-monthly.timer"
                for svc in $services; do
                    systemctl stop "$svc" 2>/dev/null || true
                    systemctl disable "$svc" 2>/dev/null || true
                done
                echo "  ✅ systemd 服务已停止"

                # 删除文件
                rm -rf /opt/vps-traffic-limit 2>/dev/null && echo "  ✅ /opt/vps-traffic-limit 已删除"
                rm -f /usr/local/bin/llcx 2>/dev/null || true
                rm -f /run/vps-traffic-limit/locked.state 2>/dev/null || true
                rm -f /var/log/vtl-core.log 2>/dev/null || true

                # 删除 systemd 单元文件
                for svc in $services; do
                    rm -f "/etc/systemd/system/$svc" 2>/dev/null || true
                done
                systemctl daemon-reload 2>/dev/null || true

                echo ""
                echo "  ✅ 已卸载，感谢使用！"
                echo ""
                exit 0
            else
                echo ""
                echo "  ❌ 卸载已取消"
                echo "  按 Enter 返回..."
                read -r
            fi
            ;;
        *)
            echo ""
            echo "  ❌ 卸载已取消"
            echo "  按 Enter 返回..."
            read -r
            ;;
    esac
}
