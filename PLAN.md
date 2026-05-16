# VPS 流量控制 — 完整优化方案 v2

> 基于阿廷反馈迭代：SSH 端口自适应 + 两种锁定模式 + 完整逻辑图

---

## 一、SSH 端口自适应

### 问题
用户可能把 SSH 端口从 22 改成别的（比如 2222、38030 等），写死 22 会让这些人 SSH 断连。

### 解决方案

安装脚本**自动检测** SSH 端口，检测优先级：

```
1. 读取 /etc/ssh/sshd_config → 查找 "Port" 指令
   - 支持多个 Port（VPS 同时监听多个端口时）
   - 过滤掉注释行
2. 如果没找到 Port 指令 → 默认 22
3. 用户可通过 --ssh-port 手动覆盖
```

检测结果写入配置文件，锁定规则动态生成。

### 多端口场景
如果一个 VPS 配置了多个 SSH 端口（比如 22 和 2222 并存），规则会放行所有检测到的 SSH 端口。

---

## 二、两种锁定模式

用户可根据需求二选一：

| 模式 | 描述 | 放行内容 |
|------|------|----------|
| **strict**（严格模式）🏆 默认 | 只放行 SSH + DNS | SSH 端口、DNS（53/tcp+udp） |
| **custom**（自定义模式） | 用户指定放行端口列表 | SSH 端口（必含）、DNS（必含）、用户指定的端口 |

### 严格模式（strict）

```
ACCEPT  tcp --sport {SSH_PORT}     ← SSH 服务器回应
ACCEPT  tcp --dport {SSH_PORT}     ← 主动 SSH 出门
ACCEPT  udp --dport 53             ← DNS
ACCEPT  tcp --dport 53             ← DNS fallback
DROP    all                         ← 全部拦截
```

### 自定义模式（custom）

```
ACCEPT  tcp --sport {SSH_PORT}     ← SSH 服务器回应（自动）
ACCEPT  tcp --dport {SSH_PORT}     ← 主动 SSH 出门（自动）
ACCEPT  udp --dport 53             ← DNS（自动）
ACCEPT  tcp --dport 53             ← DNS（自动）
ACCEPT  tcp/udp --dport {PORT_1}   ← 用户指定端口 1
ACCEPT  tcp/udp --dport {PORT_2}   ← 用户指定端口 2
...                                ← ...
DROP    all                         ← 全部拦截
```

### 用户配置方式

```bash
# 安装时选择模式
sudo bash install.sh --mode strict                    # 严格模式（默认）
sudo bash install.sh --mode custom --allow-ports 80,443,8080   # 自定义模式

# 安装后修改
sudo vps-traffic-limit config --mode custom --allow-ports 80,443
```

---

## 三、防火墙方案（3 种后端）

### 选择策略

```
用户指定 --firewall
    ├── iptables ← 使用 iptables
    ├── nftables ← 使用 nftables
    └── ufw      ← 使用 ufw
无指定时自动检测:
    ├── ufw 已启用?          → 推荐 ufw（询问用户）
    ├── nft 命令可用且系统较新? → 推荐 nftables（询问用户）
    └── 兜底                 → iptables
```

### iptables 后端

```bash
# 锁定
iptables -F OUTPUT  # 清空自定义规则（保留默认策略）
iptables -A OUTPUT -p tcp --sport {SSH_PORT} -j ACCEPT
iptables -A OUTPUT -p tcp --dport {SSH_PORT} -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# 用户自定义端口
for port in ${CUSTOM_PORTS[@]}; do
    iptables -A OUTPUT -p tcp --dport $port -j ACCEPT
    iptables -A OUTPUT -p udp --dport $port -j ACCEPT
done
iptables -A OUTPUT -j DROP

# 持久化
iptables-save > /etc/vps-traffic-limit/rules.v4
# 配合 iptables-persistent 开机自动加载
```

### nftables 后端

```nftables
# /etc/vps-traffic-limit/rules.nft
table inet filter {
    chain OUTPUT {
        type filter hook output priority filter; policy accept;
        
        # SSH
        tcp sport {SSH_PORT} accept
        tcp dport {SSH_PORT} accept
        
        # DNS
        udp dport 53 accept
        tcp dport 53 accept
        
        # 用户自定义
        tcp dport {CUSTOM_PORTS} accept
        udp dport {CUSTOM_PORTS} accept
        
        # 拦截所有
        drop
    }
}
```

```bash
# 锁定
nft add rule inet filter OUTPUT tcp sport {SSH_PORT} accept
nft add rule inet filter OUTPUT tcp dport {SSH_PORT} accept
# ...
nft replace rule inet filter OUTPUT handle X drop  # 替换默认策略

# 持久化
nft list ruleset > /etc/vps-traffic-limit/rules.nft
# 或
nft -f /etc/vps-traffic-limit/rules.nft
```

### ufw 后端

```bash
# 锁定
ufw default deny outgoing
ufw allow out {SSH_PORT}/tcp
ufw allow out 53/udp
ufw allow out 53/tcp
# 用户自定义
for port in ${CUSTOM_PORTS[@]}; do
    ufw allow out $port/tcp
    ufw allow out $port/udp
done

# 解锁
ufw default allow outgoing
```

⚠️ **ufw 的局限性**：
- 重启后 ufw 规则保持（ufw 本身已持久化）
- 但 ufw 锁定解锁切换较慢（每次 reload）
- 用户明确选 ufw 时才用，不自动推荐

---

## 四、双保险机制

```python
每次检查脚本运行时：
1. 获取当月上行流量
2. 检查流量是否 > LIMIT_GB
3. 检查 lock file 是否存在
4. 检查防火墙是否处于锁定状态

判断逻辑：

if 流量超限:
    if lock_file存在 AND 防火墙已锁定:
        → 正常，跳过
    else:
        → 执行锁定（创建 lock_file + 添加规则）
        → 发送告警通知

if 流量未超限:
    if lock_file存在 OR 防火墙已锁定:
        → 解锁（删除 lock_file + 清除规则）
        → 发送解锁通知
    else:
        → 正常，跳过
```

---

## 五、通知模块

### 配置文件 (`/etc/vps-traffic-limit/config`)

```ini
# 通知通道
notify_channel=none|telegram|wechat_webhook|email

# Telegram
telegram_bot_token=
telegram_chat_id=

# 企业微信群机器人
wechat_webhook_url=

# 邮件
email_smtp_server=
email_smtp_port=465
email_smtp_user=
email_smtp_pass=
email_from=
email_to=

# 通知触发条件（默认全部）
notify_on_lock=true       # 锁定通知
notify_on_unlock=true     # 解锁通知
notify_on_warning=true    # 预警通知（到达 80%/95%）
```

### 通知内容

```
[⚠️ 流量预警] VPS 月上行已达 136.00 GB / 170.00 GB（80%）
┌─────────────────────────
│ 网卡: ens4
│ 当前上行: 136.00 GB
│ 限额: 170.00 GB
│ 预计剩余可用: 34.00 GB
└─────────────────────────

[⛔ 流量锁定] 月上行已超限，已自动阻断非 SSH 出站
┌─────────────────────────
│ 网卡: ens4
│ 当前上行: 171.23 GB
│ 锁定时间: 2026-05-16 13:00
│ 模式: strict
│ 防火墙: iptables
└─────────────────────────

[✅ 流量解锁] 新月份已到，已自动恢复网络
┌─────────────────────────
│ 解锁时间: 2026-06-01 00:03
└─────────────────────────
```

---

## 六、流量统计方向

### 用户可选项

| 参数 | 计费方向 | 常见厂商 |
|------|----------|----------|
| `--direction egress` 🏆 默认 | **上行**（出站） | **GCP**、AWS、Azure、阿里云国际、腾讯云、华为云 |
| `--direction total` | **双向合计** | Hetzner、BuyVM、OVH 部分套餐、Contabo |
| `--direction ingress` | **下行**（入站） | 极少，通常不收费 |

安装时打印提示：
```
> 流量计费方向: egress（上行）
  ⚠️ 请确认你的 VPS 厂商计费规则：
     - GCP Free Tier: 只计上行
     - AWS/Azure/阿里云: 同
     - Hetzner/BuyVM: 请选 --direction total
```

---

## 七、完整逻辑图

```
┌─────────────────────────────────────────────────────────┐
│                    install.sh 安装流程                     │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. 检测系统 (Debian/Ubuntu)                             │
│  2. 检测网卡 (自动+手动指定)                              │
│  3. 检测 SSH 端口 → 读 sshd_config → 用户可覆盖           │
│  4. 检测防火墙 → iptables/nftables/ufw                    │
│  5. 选择锁定模式 → strict / custom + 端口列表              │
│  6. 选择计费方向 → egress / total / ingress               │
│  7. 选择通知渠道 → none/telegram/wechat/email             │
│  8. 安装 vnstat, iptables-persistent 等依赖               │
│  9. 部署脚本到 /etc/vps-traffic-limit/                   │
│ 10. 配置 shortcut 命令 (llcx, ydcx)                      │
│ 11. 设置 systemd timer (每3分钟) + 开机自启               │
│ 12. 首次运行检查                                          │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              定时检查流程 (每3分钟)                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌───────────┐                                           │
│  │ 读取 config│                                           │
│  └─────┬─────┘                                           │
│        ▼                                                  │
│  ┌─────────────────┐                                     │
│  │ vnstat 获取流量数据│                                    │
│  └──────┬──────────┘                                     │
│         ▼                                                │
│  ┌──────────────────┐   是    ┌──────────────────┐       │
│  │ 流量是否超限？      ├───────→│ 是否已有 lock +     │       │
│  └──────┬───────────┘        │ 规则已生效？        │       │
│         │ 否                  └──────┬───────────┘       │
│         ▼                           │                   │
│  ┌──────────────────┐   是          │                   │
│  │ lock或规则是否存在？├────┐        │ 是                │
│  └──────┬───────────┘    │        ▼  │                 │
│         │ 否             │   ┌────────────┐             │
│         ▼                │   │ 正常跳过 ✓ │             │
│  ┌────────────┐          │   └────────────┘             │
│  │ 正常跳过 ✓  │          │                              │
│  └────────────┘          │ 否                           │
│                          ▼                              │
│                  ┌──────────────────┐                   │
│                  │ 自动修复不一致状态 │                   │
│                  └──────┬───────────┘                   │
│                         ▼                               │
│                  ┌──────────────────┐                   │
│                  │ 执行锁定/解锁操作 │                    │
│                  └──────┬───────────┘                   │
│                         ▼                               │
│                  ┌──────────────────┐                   │
│                  │ 发送通知         │                    │
│                  │ (如已配置)       │                    │
│                  └──────────────────┘                   │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│               防火墙锁定/解锁流程                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│        锁定                                          │
│    ┌──────────┐                                        │
│    │ 检测后端   │                                        │
│    │ (iptables │                                        │
│    │ /nftables │                                        │
│    │ /ufw)     │                                        │
│    └────┬─────┘                                        │
│         ▼                                              │
│    ┌────────────────────┐                              │
│    │ 生成规则集          │                              │
│    │ → SSH端口(自适应)   │                              │
│    │ → DNS(自动)        │                              │
│    │ → 自定义端口(如配置) │                              │
│    │ → DROP all(末尾)   │                              │
│    └──────┬─────────────┘                              │
│           ▼                                            │
│    ┌────────────────────┐                              │
│    │ 写入规则 + 持久化    │                              │
│    │ → iptables-save    │                              │
│    │ → nft list ruleset │                              │
│    │ → ufw reload       │                              │
│    └──────┬─────────────┘                              │
│           ▼                                            │
│    ┌────────────────────┐                              │
│    │ 创建 lock file      │                              │
│    │ → /var/lock/       │                              │
│    │   vps-traffic-     │                              │
│    │   limit.lock       │                              │
│    │   (写入时间戳)      │                              │
│    └────────────────────┘                              │
│                                                          │
│        解锁                                          │
│    ┌──────────┐                                        │
│    │ 清除防火墙规则│                                     │
│    │ → iptables -F│                                     │
│    │ → nft flush  │                                     │
│    │ → ufw default│                                     │
│    │   allow      │                                     │
│    └──────┬──────┘                                     │
│           ▼                                            │
│    ┌────────────────────┐                              │
│    │ 恢复默认策略        │                              │
│    │ → 恢复 ACCEPT      │                              │
│    │ → 持久化           │                              │
│    └──────┬────────────┘                               │
│           ▼                                            │
│    ┌────────────────────┐                              │
│    │ 删除 lock file      │                              │
│    └────────────────────┘                              │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              开/关流程 (llcx 命令展示)                    │
├─────────────────────────────────────────────────────────┤
│                                                          │
│   llcx                                                    │
│   ┌─────────────────────────────────────────────────┐    │
│   │  网卡: ens4                                     │    │
│   │  月份: 2026-05                                  │    │
│   │  上行: 136.2345 GB                              │    │
│   │  下行: 45.6789 GB                               │    │
│   │  合计: 181.9134 GB                              │    │
│   │  限额: 170.00 GB (上行)                          │    │
│   │  状态: 🟢 正常运行 / 🔴 已锁定                    │    │
│   │  模式: strict (仅 SSH+DNS)                       │    │
│   │  防火墙: iptables                                │    │
│   └─────────────────────────────────────────────────┘    │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

## 八、安装用法

```bash
# 最小安装（全自动检测）
sudo bash install.sh

# 指定网卡、模式、自定义端口
sudo bash install.sh \
  --interface eth0 \
  --limit 200 \
  --mode custom \
  --allow-ports 80,443,8080,30000-50000 \
  --direction total \
  --firewall nftables \
  --ssh-port 38030 \
  --cmd-llcx llcx \
  --cmd-ydcx ydcx \
  --telegram-bot 123456:ABC... \
  --telegram-chat 123456789

# 交互式安装（无参数时进入交互模式）
sudo bash install.sh --interactive
```

---

## 九、配置文件结构

```ini
# /etc/vps-traffic-limit/config
[general]
interface = ens4
limit_gb = 170
direction = egress          # egress|total|ingress
mode = strict               # strict|custom
allow_ports =               # custom mode: 80,443,8080

[ssh]
ports = 22                  # 自动检测，可手动覆盖

[firewall]
backend = iptables          # iptables|nftables|ufw

[commands]
llcx = llcx
ydcx = ydcx

[notify]
channel = none              # none|telegram|wechat_webhook|email
telegram_bot_token =
telegram_chat_id =
wechat_webhook_url =
email_smtp_server =
email_smtp_port = 465
email_smtp_user =
email_smtp_pass =
email_from =
email_to =
notify_on_lock = true
notify_on_unlock = true
notify_on_warning = true
```

---

## 十、目录结构

```
GitHub 仓库:
vps-traffic-limit/
├── install.sh                    ← 一键安装（交互式 + 静默参数）
├── README.md                     ← 使用说明
├── LICENSE                       ← MIT
└── lib/
    ├── detect.sh                 ← 系统/网卡/SSH端口/防火墙检测
    ├── firewall-iptables.sh      ← iptables 后端
    ├── firewall-nftables.sh      ← nftables 后端
    ├── firewall-ufw.sh           ← ufw 后端
    └── notify.sh                 ← 通知模块

目标系统:
/etc/vps-traffic-limit/
├── config                        ← 配置文件
├── traffic-limit.sh              ← 核心检查脚本
├── lockdown.sh                   ← 加锁/解锁工具
├── notify.sh                     ← 通知模块
└── rules.v4 / rules.v6 / rules.nft  ← 持久化规则集
```
