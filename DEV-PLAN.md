# VPS 流量监控系统 — 开发技术蓝图 v1.0

> 目标：将 v5-SCHEME.md 方案逐行落实为可运行的 Bash 脚本
> 原则：先写接口定义 → 再写实现 → 再写测试

---

## 一、文件依赖关系图

```
install.sh (安装器，一次性)
  ├── 纯文本输出（无 lib 依赖，安装时自带渲染）
  │
  └── 安装完成后生成 /etc/vps-traffic-limit/ 运行时文件

/opt/vps-traffic-limit/
├── bin/
│   └── llcx                     ← 唯一入口，依赖所有引擎
├── lib/
│   ├── engine_firewall.sh       ← 独立，无 lib 依赖
│   ├── engine_check.sh          ← 依赖: config, engine_notify
│   ├── engine_ui.sh             ← 独立，纯输出函数
│   └── engine_notify.sh         ← 独立，依赖 curl/wget
├── conf/
│   └── config                   ← 被所有引擎读取
└── log/
    └── vtl-core.log             ← 被所有引擎写入

/run/vps-traffic-limit/
├── locked.state                 ← engine_check 读写
└── vtl.lock                     ← flock 互斥锁
```

**加载顺序**（`llcx` 入口和 `engine_check.sh` 头部）：
```bash
# 统一加载器
CONF_DIR="/opt/vps-traffic-limit/conf"
LIB_DIR="/opt/vps-traffic-limit/lib"

source "$CONF_DIR/config"
source "$LIB_DIR/engine_ui.sh"
source "$LIB_DIR/engine_firewall.sh"
source "$LIB_DIR/engine_notify.sh"
source "$LIB_DIR/engine_check.sh"
```

---

## 二、全局变量定义（config 文件）

这是**所有脚本的契约**。每个变量写清楚：类型、来源、谁读谁写。

```bash
# /opt/vps-traffic-limit/conf/config
# 权限: 600 (root only)

# ── 网络 ──
INTERFACE="ens4"           # 字符串, 安装时指定, 只读
SSH_PORTS="22,38030"       # 逗号分隔, 安装时检测, 可配置修改

# ── 流量限额 ──
LIMIT_GB=170               # 整数, 安装时指定, 可配置修改
DIRECTION="egress"         # egress|total|ingress, 只读

# ── 锁定策略 ──
MODE="strict"              # strict|custom, 可配置修改
EXTRA_PORTS=""             # 逗号分隔, 仅 custom 模式生效
IPV6_POLICY="dual"         # dual|ipv4_only, 只读

# ── 计费周期 ──
PROVIDER_TIMEZONE="America/Los_Angeles"  # IANA 时区
RESET_DAY=1                # 1-28

# ── 通知 ──
NOTIFY_CHANNEL="telegram"  # none|telegram|wechat|email|serverchan
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

# ── 阈值 ──
WARN_PERCENT=80            # 整数 1-99
CRIT_PERCENT=95            # 整数 1-99

# ── 运行时（不由用户配置，引擎自动维护）──
VTL_CHAIN_NAME="VTL-LOCK"
LOCK_STATE_FILE="/run/vps-traffic-limit/locked.state"
LOCK_FILE="/run/vps-traffic-limit/vtl.lock"
LOG_FILE="/var/log/vtl-core.log"
```

---

## 三、引擎函数接口定义（先定接口，后写实现）

### 3.1 engine_firewall.sh

```bash
# ── 函数清单 ──

# fw_detect: 检测 iptables/ip6tables 是否可用
#   输入: 无
#   输出: 设置 I PTABLES_AVAIL, IP6TABLES_AVAIL
#   返回: 0=至少一个可用, 1=两者都不可用
function fw_detect() { ... }

# fw_lock: 注入 VTL-LOCK 规则
#   输入: 读取全局变量 SSH_PORTS, MODE, EXTRA_PORTS, IPV6_POLICY
#   输出: iptables -N VTL-LOCK + 规则填充 + -I OUTPUT 1 -j VTL-LOCK
#   返回: 0=成功, 1=失败
#   注意: 幂等——重复执行不会重复创建链
function fw_lock() { ... }

# fw_unlock: 移除 VTL-LOCK 规则
#   输入: 无
#   输出: -D OUTPUT -j VTL-LOCK + -F VTL-LOCK + -X VTL-LOCK
#   返回: 0=成功, 1=失败
#   注意: 幂等——重复执行不会出错
function fw_unlock() { ... }

# fw_is_locked: 检测是否已注入 VTL-LOCK
#   输入: 无
#   输出: 无
#   返回: 0=已锁定, 1=未锁定
function fw_is_locked() { ... }

# fw_test: 测试锁定30秒
#   输入: 无
#   输出: 锁30秒 → 自动解锁
#   返回: 0=正常
function fw_test() { ... }
```

### 3.2 engine_check.sh

```bash
# ── 函数清单 ──

# check_get_traffic: 获取当月流量数据
#   输入: INTERFACE, DIRECTION
#   输出: 设置 USED_BYTES, USED_GB, USED_PERCENT, LIMIT_BYTES
#   依赖: vnstat --oneline b
#   返回: 0=成功, 1=vnstat无数据
function check_get_traffic() { ... }

# check_should_lock: 判断是否应锁定
#   输入: USED_PERCENT, LIMIT_GB
#   输出: 无
#   返回: 0=应锁定, 1=不应锁
function check_should_lock() { ... }

# check_double_insurance: 双保险一致性校验
#   输入: LOCK_STATE_FILE, fw_is_locked 结果
#   输出: 4种状态的自动修复
#   返回: 0=一致, 1=已修复不一致
function check_double_insurance() { ... }

# check_should_reset: 判断是否到计费周期重置
#   输入: PROVIDER_TIMEZONE, RESET_DAY
#   输出: 无
#   返回: 0=应重置, 1=不应
function check_should_reset() { ... }

# check_cron: 定时器入口（每3分钟调用）
#   输入: 无
#   输出: 完整检查 → 锁/解锁 → 通知
#   返回: 0=正常
#   逻辑:
#     1. flock 获取锁 (超时3秒退出)
#     2. check_should_reset → 是则解锁+重置
#     3. check_get_traffic → 获取流量
#     4. check_should_lock → 判断是否超限
#     5. check_double_insurance → 修复不一致
#     6. 如需锁定: 先发通知, 再fw_lock
#     7. 如需解锁: 先fw_unlock, 再发通知
#     8. 释放flock
function check_cron() { ... }
```

### 3.3 engine_notify.sh

```bash
# ── 函数清单 ──

# notify_send: 发送通知（统一入口）
#   输入: 
#     $1 = type (lock|unlock|warn_80|warn_95|test)
#     $2 = 附加信息 (如 "上行: 171GB")
#   输出: 根据 NOTIFY_CHANNEL 调用对应发送函数
#   返回: 0=成功, 1=失败
#   注意: 5秒超时，失败不退整体流程
function notify_send() {
    local type="$1"
    local extra="$2"
    local message=""
    message=$(notify_build_message "$type" "$extra")
    
    case "$NOTIFY_CHANNEL" in
        telegram)   notify_telegram "$message" ;;
        wechat)     notify_wechat "$message" ;;
        email)      notify_email "$message" ;;
        serverchan) notify_serverchan "$message" ;;
    esac
}

# notify_build_message: 组装通知文本
#   输入: type, extra
#   输出: 格式化的通知字符串
function notify_build_message() { ... }

# notify_send_test: 发送测试通知
#   输入: 无
#   输出: 测试消息
#   返回: 0=成功, 1=失败
function notify_send_test() { ... }

# 各渠道内部函数：
function notify_telegram()     { curl -s --connect-timeout 5 -X POST ...; }
function notify_wechat()       { curl -s --connect-timeout 5 -X POST ...; }
function notify_email()        { ... }  # 使用 /usr/sbin/sendmail 或 python3 smtplib
function notify_serverchan()   { curl -s --connect-timeout 5 -X POST ...; }
```

### 3.4 engine_ui.sh

```bash
# ── 函数清单 ──

# ui_detect_term: 检测终端宽度
#   输入: 无
#   输出: 设置 TERM_WIDTH (整数), IS_NARROW (bool)
#   使用: tput cols, 兜底 80
function ui_detect_term() { ... }

# ui_progress_bar: 渲染进度条
#   输入: $1 = percent (浮点数), $2 = width (整数, 默认终端宽度一半)
#   输出: ███░░░░ 字符串
function ui_progress_bar() { ... }

# ui_box: 渲染带边框的盒子
#   输入: $1 = 标题, $2 = 内容 (多行字符串)
#   输出: 打印 ┌─┐ 框
function ui_box() { ... }

# ui_table: 渲染表格
#   输入: $1 = 表头 (逗号分隔), $2 = 数据行 (多行, 逗号分隔)
#   输出: 打印表格
function ui_table() { ... }

# ui_show_status: 显示 llcx -c 状态
#   输入: 读取全局 + vnstat 数据
#   输出: 完整的状态界面（含场景判断：正常/预警/锁定）
function ui_show_status() { ... }

# ui_show_report: 显示 llcx -r 月度汇总
#   输入: vnstat -m 数据
#   输出: 年度表格
function ui_show_report() { ... }
```

### 3.5 llcx 入口脚本

```bash
# /opt/vps-traffic-limit/bin/llcx
# 入口逻辑，无函数定义，只有流程控制

#!/bin/bash
source /opt/vps-traffic-limit/conf/config
source /opt/vps-traffic-limit/lib/engine_ui.sh
source /opt/vps-traffic-limit/lib/engine_firewall.sh
source /opt/vps-traffic-limit/lib/engine_notify.sh
source /opt/vps-traffic-limit/lib/engine_check.sh
ui_detect_term

case "${1:-menu}" in
    -c|--check)     ui_show_status;;
    -r|--report)    ui_show_report;;
    lock)           fw_lock && notify_send lock "手动锁定";;
    unlock)         fw_unlock && notify_send unlock "手动解锁";;
    test-notify)    notify_send_test;;
    config)         ui_config_menu;;
    logs)           ui_logs_menu;;
    menu|"")        ui_main_menu;;
    *)              echo "用法: llcx [-c|-r|lock|unlock|config|logs|test-notify]";;
esac
```

---

## 四、关键函数的伪代码实现

### 4.1 fw_lock 核心逻辑

```bash
function fw_lock() {
    # 1. 创建/清空 VTL-LOCK 链
    iptables -N "$VTL_CHAIN_NAME" 2>/dev/null || iptables -F "$VTL_CHAIN_NAME"
    
    # 2. SSH 端口 — sport 和 dport 都要放
    #    注意: 把逗号分隔转成 iptables 多端口格式
    local ssh_ports=$(echo "$SSH_PORTS" | tr ',' ' ')
    for port in $ssh_ports; do
        iptables -A "$VTL_CHAIN_NAME" -p tcp --sport "$port" -j ACCEPT  # 回应客户端
        iptables -A "$VTL_CHAIN_NAME" -p tcp --dport "$port" -j ACCEPT  # 主动出站
    done
    
    # 3. DNS 放行
    iptables -A "$VTL_CHAIN_NAME" -p udp --dport 53 -j ACCEPT
    iptables -A "$VTL_CHAIN_NAME" -p tcp --dport 53 -j ACCEPT
    
    # 4. DHCP 续租放行
    iptables -A "$VTL_CHAIN_NAME" -p udp --sport 68 --dport 67 -j ACCEPT
    
    # 5. custom 模式 — 额外端口
    if [ "$MODE" = "custom" ] && [ -n "$EXTRA_PORTS" ]; then
        # 输入校验: EXTRA_PORTS 必须在安装/配置时已完成
        # 支持格式: 80,443,30000-50000
        local ports=$(echo "$EXTRA_PORTS" | tr ',' ' ')
        for item in $ports; do
            if echo "$item" | grep -q '-'; then
                # 端口范围
                local start=$(echo "$item" | cut -d- -f1)
                local end=$(echo "$item" | cut -d- -f2)
                iptables -A "$VTL_CHAIN_NAME" -p tcp --dport "$start:$end" -j ACCEPT
                iptables -A "$VTL_CHAIN_NAME" -p udp --dport "$start:$end" -j ACCEPT
            else
                iptables -A "$VTL_CHAIN_NAME" -p tcp --dport "$item" -j ACCEPT
                iptables -A "$VTL_CHAIN_NAME" -p udp --dport "$item" -j ACCEPT
            fi
        done
    fi
    
    # 6. 兜底拒绝
    iptables -A "$VTL_CHAIN_NAME" -j REJECT --reject-with icmp-port-unreachable
    
    # 7. 置顶劫持 OUTPUT 链
    iptables -I OUTPUT 1 -j "$VTL_CHAIN_NAME"
    
    # 8. IPv6 双栈
    if [ "$IPV6_POLICY" = "dual" ]; then
        ip6tables -N "$VTL_CHAIN_NAME" 2>/dev/null || ip6tables -F "$VTL_CHAIN_NAME"
        # 重复 2-7 步但用 ip6tables...
        # SSH + DNS + DHCP(IPv6用DHCPv6 port 546/547)
        ip6tables -A "$VTL_CHAIN_NAME" -p tcp --sport "$port" -j ACCEPT
        ip6tables -A "$VTL_CHAIN_NAME" -p tcp --dport "$port" -j ACCEPT
        ip6tables -A "$VTL_CHAIN_NAME" -p udp --dport 53 -j ACCEPT
        ip6tables -A "$VTL_CHAIN_NAME" -p udp --sport 546 --dport 547 -j ACCEPT  # DHCPv6
        ip6tables -A "$VTL_CHAIN_NAME" -j REJECT
        ip6tables -I OUTPUT 1 -j "$VTL_CHAIN_NAME"
    fi
    
    log_write "[LOCK] VTL-LOCK 注入完成 | SSH:$SSH_PORTS | 模式:$MODE"
    return 0
}
```

### 4.2 check_cron 核心逻辑

```bash
function check_cron() {
    # 1. flock 互斥锁 (超时3秒)
    exec 200>"$LOCK_FILE"
    flock -w 3 200 || {
        log_write "[SKIP] 另一进程正在执行，跳过本次检查"
        return 0
    }
    
    # 2. 计费周期重置检测
    if check_should_reset; then
        fw_unlock
        rm -f "$LOCK_STATE_FILE"
        notify_send unlock "计费周期重置"
        log_write "[RESET] 计费周期已重置，已解锁"
    fi
    
    # 3. 获取流量
    check_get_traffic || {
        log_write "[SKIP] vnstat 无数据，跳过"
        flock -u 200
        return 0
    }
    
    # 4. 双保险一致性检查
    check_double_insurance
    
    # 5. 超限判断 + 执行
    if check_should_lock; then
        # 先发通知，再锁定
        if ! fw_is_locked; then
            notify_send lock "上行: ${USED_GB}GB"
            fw_lock
            echo "$(date +%s)" > "$LOCK_STATE_FILE"
            log_write "[LOCK] 超限锁定 | 上行: ${USED_GB}GB / ${LIMIT_GB}GB"
        fi
    else
        # 未超限但已锁 → 异常降级
        if fw_is_locked; then
            if check_double_insurance; then
                fw_unlock
                rm -f "$LOCK_STATE_FILE"
                log_write "[UNLOCK] 异常降级: 未超限但处于锁定状态"
                notify_send unlock "异常降级"
            fi
        fi
        
        # 预警通知
        if [ "$(awk "BEGIN{print ($USED_PERCENT >= $WARN_PERCENT)}")" -eq 1 ] && \
           [ "$(awk "BEGIN{print ($USED_PERCENT < $CRIT_PERCENT)}")" -eq 1 ]; then
            notify_send warn_80 "上行: ${USED_GB}GB"
        elif [ "$(awk "BEGIN{print ($USED_PERCENT >= $CRIT_PERCENT)}")" -eq 1 ]; then
            notify_send warn_95 "上行: ${USED_GB}GB"
        fi
    fi
    
    log_write "[CHECK] 已用: ${USED_GB}GB / ${LIMIT_GB}GB (${USED_PERCENT}%) | 状态: $(fw_is_locked && echo 锁定 || echo 正常)"
    flock -u 200
    return 0
}
```

### 4.3 双保险 check_double_insurance

```bash
function check_double_insurance() {
    local state_exists=0  # 0=不存在, 1=存在
    local rules_active=0  # 0=未锁定, 1=已锁定
    
    [ -f "$LOCK_STATE_FILE" ] && state_exists=1
    fw_is_locked && rules_active=1
    
    # 4 种状态矩阵
    if [ "$state_exists" -eq 1 ] && [ "$rules_active" -eq 1 ]; then
        # 🟢 正常锁定 — 一致
        return 0
    elif [ "$state_exists" -eq 1 ] && [ "$rules_active" -eq 0 ]; then
        # ⚠️ state 在但规则丢了 → 重新锁
        log_write "[FIX] 双保险修复: state存在但规则丢失，重新锁定"
        fw_lock
        return 1
    elif [ "$state_exists" -eq 0 ] && [ "$rules_active" -eq 1 ]; then
        # ⚠️ 规则在但 state 丢了 → 重建 state
        echo "$(date +%s)" > "$LOCK_STATE_FILE"
        log_write "[FIX] 双保险修复: 规则存在但state丢失，已重建state"
        return 1
    else
        # 🟢 未锁定 — 一致
        return 0
    fi
}
```

---

## 五、输入校验规范

所有用户输入在**接受时刻**必须通过以下校验函数：

```bash
# ⚠️ 这是安全红线，所有 install.sh 和 llcx config 的输入必经之路

# 校验端口号
# 输入: "80,443,30000-50000"
# 通过: 每个元素是 1-65535 的数字，或 X-Y 的范围（X<Y, 1-65535）
# 拒绝: 空格/字母/符号/shell特殊字符/负数/0/65536+
function validate_ports() {
    local input="$1"
    local IFS=','  # 临时改分隔符
    for item in $input; do
        item=$(echo "$item" | xargs)  # 去首尾空格
        if echo "$item" | grep -qE '^[0-9]+-[0-9]+$'; then
            local s=$(echo "$item" | cut -d- -f1)
            local e=$(echo "$item" | cut -d- -f2)
            [ "$s" -ge 1 ] && [ "$s" -le 65535 ] && \
            [ "$e" -ge 1 ] && [ "$e" -le 65535 ] && \
            [ "$s" -lt "$e" ] || return 1
        elif echo "$item" | grep -qE '^[0-9]+$'; then
            [ "$item" -ge 1 ] && [ "$item" -le 65535 ] || return 1
        else
            return 1
        fi
    done
    return 0
}

# 校验接口名: 字母开头，字母数字
function validate_interface() {
    echo "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9]+$'
}

# 校验命令名: 字母开头，字母数字下划线连字符
function validate_cmd_name() {
    echo "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'
}

# 校验数字: 正整数
function validate_number() {
    echo "$1" | grep -qE '^[1-9][0-9]*$'
}

# 校验百分比: 1-99
function validate_percent() {
    echo "$1" | grep -qE '^[1-9][0-9]?$' && [ "$1" -ge 1 ] && [ "$1" -le 99 ]
}

# 校验时区: 是否是有效 IANA 时区（通过测试 date 命令）
function validate_timezone() {
    TZ="$1" date +%Z >/dev/null 2>&1
}
```

---

## 六、systemd 单元规范（纠正后的正确写法）

### vtl-check.service

```ini
[Unit]
Description=VTL Core Defense Engine
# 不要求 After=ufw.service，因为 VTL-LOCK 是独立链，不碰 ufw
After=network.target vnstat.service netfilter-persistent.service
Requires=vnstat.service

[Service]
Type=oneshot
ExecStart=/opt/vps-traffic-limit/bin/llcx cron-check
ExecStartPre=/bin/sleep 5
StandardOutput=null
StandardError=journal
PrivateDevices=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

### vtl-check.timer

```ini
[Unit]
Description=VTL Periodic Check (every 3 minutes)

[Timer]
OnBootSec=1min
OnUnitActiveSec=3min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
```

### vtl-reset.timer（计费周期重置专用）

```ini
[Unit]
Description=VTL Billing Reset Trigger

[Timer]
# 每天凌晨检查，由 check_cron 判断是否到计费日
OnCalendar=*-*-* 00:00:00
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
```

### vtl-check.path（watchdog，规则文件变化时触发）

```ini
[Unit]
Description=VTL Config Watchdog

[Path]
PathModified=/opt/vps-traffic-limit/conf/config
Unit=vtl-check.service

[Install]
WantedBy=multi-user.target
```

---

## 七、开发顺序（按依赖关系）

```
第一轮（并行，互不依赖）
├── [A] lib/engine_firewall.sh    ← 纯 iptables 操作
├── [B] lib/engine_notify.sh      ← 纯 HTTP 请求
├── [C] lib/engine_ui.sh          ← 纯终端输出
└── [D] conf/config               ← 数据定义

第二轮（依赖第一轮）
├── [E] lib/engine_check.sh       ← 依赖 A B D
├── [F] bin/llcx                   ← 依赖 A B C D E

第三轮（依赖第二轮）
├── [G] install.sh                ← 生成 D 和所有引擎
├── [H] systemd 单元文件           ← 部署时复制
└── [I] logrotate 配置             ← 部署时复制

第四轮（测试和验证）
└── 编写测试脚本
```

---

## 八、测试策略

### 单元测试（每个函数独立）

```bash
# 测试 fw_lock 是否正确创建链
test_fw_lock() {
    fw_lock
    iptables -L VTL-LOCK -n >/dev/null 2>&1 || { echo "FAIL: VTL-LOCK 不存在"; return 1; }
    iptables -C OUTPUT -j VTL-LOCK >/dev/null 2>&1 || { echo "FAIL: OUTPUT 劫持不存在"; return 1; }
    # 验证规则数
    local rules=$(iptables -L VTL-LOCK -n | wc -l)
    [ "$rules" -gt 3 ] || { echo "FAIL: 规则太少"; return 1; }
    fw_unlock
    echo "PASS: fw_lock"
}

# 测试幂等性
test_fw_idempotent() {
    fw_lock
    fw_lock  # 再次执行
    fw_unlock
    echo "PASS: fw_idempotent"
}

# 测试 fw_is_locked
test_fw_is_locked() {
    fw_is_locked && { echo "FAIL: 不应该检测到锁定"; return 1; }
    fw_lock
    fw_is_locked || { echo "FAIL: 应该检测到锁定"; return 1; }
    fw_unlock
    fw_is_locked && { echo "FAIL: 不应该检测到锁定"; return 1; }
    echo "PASS: fw_is_locked"
}
```

### 集成测试

```bash
# 测试完整检查流程
test_check_cron() {
    # 模拟超限流量
    LIMIT_GB=10  # 设一个很小的限额
    # 执行检查
    check_cron
    # 验证是否锁定
    fw_is_locked || { echo "FAIL: 应该已锁定"; return 1; }
    # 验证状态文件
    [ -f "$LOCK_STATE_FILE" ] || { echo "FAIL: 状态文件应该存在"; return 1; }
    fw_unlock
    rm -f "$LOCK_STATE_FILE"
    echo "PASS: check_cron"
}
```

### 手动验证清单

安装后逐项验证：

```
□ llcx          → 主菜单正常显示
□ llcx -c       → 流量状态显示
□ llcx -r       → 历史汇总显示
□ llcx lock     → 锁定成功，SSH 不断，curl 被拦
□ llcx unlock   → 解锁成功，curl 恢复
□ 等 3 分钟     → 定时器触发，日志有记录
□ 模拟超限      → 收到通知，自动锁定
```

---

## 九、日志写入函数（所有引擎共用）

```bash
# 统一日志格式: [时间] [LEVEL] 消息
# LEVEL: CHECK | LOCK | UNLOCK | WARN | NOTIFY | ERROR | FIX | SKIP | RESET
function log_write() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" >> "$LOG_FILE"
}
```

---

## 十、开发环境建议

```
开发机:  任何 Debian/Ubuntu 机器
测试机:  用 Docker container 或一个低配 VPS
Docker 测试:
  docker run -it --rm --cap-add=NET_ADMIN debian:12 bash
  在容器内可以测试 iptables 规则注入（需要 --cap-add=NET_ADMIN）

版本控制: 每个引擎文件独立，第一轮就 push 到 GitHub
第一轮完成时: 每个引擎可单独测试
第二轮完成时: llcx 命令可完整工作
第三轮完成时: install.sh 可部署到新系统
```
