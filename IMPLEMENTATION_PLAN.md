# s-singbox 可执行开发方案

基于 s-xray 架构设计的 sing-box 管理工具 - 完整实施方案

---

## 📋 项目概述

### 定位与目标

**核心原则**：
- 🎯 **架构对标 s-xray**：保持与 s-xray 高度一致的模块化设计和数据架构
- ⚡ **内核切换为 sing-box**：充分利用 sing-box 的协议优势（Hysteria2/TUIC/Naive）
- 🔧 **CLI 优先**：纯命令行工具，无 GUI/WebUI
- 📚 **官方文档为准**：所有配置严格遵守 sing-box 官方规范

### 关键特性

✅ **保留 s-xray 的优秀设计**：
- 三层数据架构（users、nodes、bindings 分离）
- 模块化代码组织（17个功能模块）
- 动态配置生成系统
- 用户-节点绑定机制

✅ **适配 sing-box 生态**：
- sing-box 配置结构（route 替代 routing）
- 新协议支持（Shadowsocks、Trojan、Hysteria2、TUIC、Naive、VMess、VLESS、ShadowTLS）
- Rule Set 新特性（替代传统 geoip/geosite）
- Clash API 可选集成
- 域名管理和证书自动化
- 出站规则和路由策略管理

---

## 🏗️ 架构设计

### 整体架构图

```
┌─────────────────────────────────────────────────────────┐
│                    CLI 入口层                              │
│              singbox-manager.sh                           │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│                  命令路由层                                │
│  菜单系统 + 命令解析 + 参数验证                            │
└──┬──────┬──────┬──────┬──────┬──────┬──────┬──────────┘
   │      │      │      │      │      │      │
   ▼      ▼      ▼      ▼      ▼      ▼      ▼
┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐
│内核│ │节点│ │用户│ │订阅│ │监控│ │防火│ │API │
│管理│ │管理│ │管理│ │管理│ │统计│ │墙  │ │集成│
└──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘
   │      │      │      │      │      │      │
   └──────┴──────┴──────┴──────┴──────┴──────┘
                      │
                      ▼
        ┌──────────────────────────┐
        │    配置生成核心引擎          │
        │  config_generator.sh      │
        └────────┬─────────────────┘
                 │
                 ▼
    ┌────────────────────────────────┐
    │        数据持久化层               │
    │  users.json                     │
    │  nodes.json                     │
    │  node_users.json (bindings)     │
    └────────────────────────────────┘
                 │
                 ▼
    ┌────────────────────────────────┐
    │      sing-box 内核层            │
    │  /usr/local/singbox/sing-box   │
    │  config.json (动态生成)          │
    └────────────────────────────────┘
```

### 目录结构

```
s-singbox/
├── singbox-manager.sh              # 主入口脚本 (对标 xray-manager.sh)
├── install.sh                      # 一键安装脚本
├── uninstall.sh                    # 卸载脚本
├── README.md                       # 项目说明
│
├── modules/                        # 功能模块目录
│   ├── common.sh                   # 通用函数库（日志/颜色/工具）
│   ├── safe_json.sh                # JSON 安全操作库
│   ├── input-validation.sh         # 输入验证模块
│   │
│   ├── core.sh                     # sing-box 内核管理
│   ├── config.sh                   # 配置文件基础管理
│   ├── config_generator.sh         # 配置生成核心（重写）
│   │
│   ├── node.sh                     # 节点管理（协议适配）
│   ├── user.sh                     # 用户管理
│   ├── user_node_binding.sh        # 用户-节点绑定关系
│   ├── domain.sh                   # 域名管理（证书/SNI/绑定）
│   ├── outbound.sh                 # 出站规则管理
│   │
│   ├── subscription.sh             # 订阅管理（URL拉取/更新）
│   ├── monitor.sh                  # 监控统计
│   ├── firewall.sh                 # 防火墙管理
│   ├── singbox_api.sh              # sing-box API 集成
│   ├── cert.sh                     # 证书管理（acme.sh集成）
│   │
│   ├── protocol_shadowsocks.sh     # Shadowsocks 协议助手
│   ├── protocol_trojan.sh          # Trojan 协议助手
│   ├── protocol_hysteria2.sh       # Hysteria2 协议助手
│   └── protocol_tuic.sh            # TUIC 协议助手
│
├── templates/                      # 配置模板目录
│   ├── base_config.json            # 基础配置模板
│   ├── protocols/                  # 协议配置模板
│   │   ├── shadowsocks.json
│   │   ├── trojan.json
│   │   ├── hysteria2.json
│   │   ├── tuic.json
│   │   ├── naive.json
│   │   ├── vmess.json              # VMess 协议模板
│   │   ├── vless.json              # VLESS 协议模板
│   │   └── shadowtls.json          # ShadowTLS 协议模板
│   ├── transports/                 # 传输层模板
│   │   ├── ws.json                 # WebSocket
│   │   └── grpc.json               # gRPC
│   └── route_rules.json            # 路由规则模板
│
├── scripts/                        # 辅助脚本
│   ├── diagnose.sh                 # 环境诊断
│   ├── backup.sh                   # 配置备份
│   └── migrate_from_xray.sh        # 从 Xray 迁移工具
│
└── data/                           # 数据文件（运行时生成）
    ├── users.json                  # 用户数据
    ├── nodes.json                  # 节点数据
    ├── node_users.json             # 绑定关系数据
    ├── domains.json                # 域名管理数据
    ├── outbounds.json              # 出站配置数据
    └── route_rules.json            # 路由规则数据
```

---

## 📊 核心数据模型

### 1. users.json - 用户数据

```json
{
  "users": [
    {
      "id": "uuid-string",           // UUID v4
      "username": "admin",            // 用户名
      "email": "admin@local",         // 邮箱（用于统计标识）
      "password": "hashed-password",  // 密码（Shadowsocks/Trojan用）
      "level": 0,                     // 用户等级（0-9）
      "enabled": true,                // 是否启用
      "created_at": "2024-01-01T00:00:00Z",
      "traffic_limit": 0,             // 流量限制（0=无限制）
      "expire_time": ""               // 过期时间（空=永久）
    }
  ]
}
```

### 2. nodes.json - 节点数据

```json
{
  "nodes": [
    {
      "port": "443",
      "protocol": "trojan",           // shadowsocks/trojan/hysteria2/tuic/naive
      "transport": "tcp",             // tcp/ws/grpc/http
      "security": "tls",              // tls/reality/none
      "listen": "0.0.0.0",
      "tag": "trojan-443",            // 节点唯一标识
      "extra": {                      // 协议特定配置
        "tls": {
          "server_name": "example.com",
          "certificate_path": "/path/to/cert.pem",
          "key_path": "/path/to/key.pem"
        }
      },
      "created_at": "2024-01-01T00:00:00Z"
    }
  ]
}
```

### 3. node_users.json - 绑定关系

```json
{
  "bindings": [
    {
      "port": "443",
      "protocol": "trojan",
      "users": [
        "uuid-1",
        "uuid-2"
      ]
    }
  ]
}
```

---

## 🔧 核心模块详解

### Module 1: config_generator.sh（配置生成核心）

**功能**：根据三层数据文件动态生成完整的 sing-box config.json

**核心流程**：

```bash
generate_singbox_config() {
    # 1. 加载数据文件
    load_json_files()

    # 2. 生成基础配置
    generate_base_config()  # log, dns, ntp

    # 3. 生成 inbounds
    for node in nodes.json; do
        protocol=$(get_protocol)
        users=$(get_bound_users node.port)

        case $protocol in
            shadowsocks)
                generate_shadowsocks_inbound()
                ;;
            trojan)
                generate_trojan_inbound()
                ;;
            hysteria2)
                generate_hysteria2_inbound()
                ;;
            tuic)
                generate_tuic_inbound()
                ;;
        esac

        inbounds+=($inbound)
    done

    # 4. 生成 outbounds
    generate_outbounds()  # direct, block

    # 5. 生成 route
    generate_route_rules()

    # 6. 合并配置
    merge_config()

    # 7. 校验配置
    validate_config()  # sing-box check

    # 8. 写入文件
    write_config()
}
```

**关键点**：
- 使用 jq 进行 JSON 操作
- 每个协议独立的生成函数
- 配置校验失败自动回滚
- 操作原子性保证

### Module 2: node.sh（节点管理）

**功能**：添加、删除、列表、测试节点

**核心命令**：

```bash
# 添加节点
add_node() {
    # 1. 选择协议类型
    select_protocol()  # shadowsocks/trojan/hysteria2/tuic

    # 2. 输入协议参数
    case $protocol in
        shadowsocks)
            input_ss_params()  # method, password, port
            ;;
        trojan)
            input_trojan_params()  # password, port, tls
            ;;
        hysteria2)
            input_hy2_params()  # password, port, obfs
            ;;
    esac

    # 3. 检查端口冲突
    check_port_conflict()

    # 4. 生成节点配置
    generate_node_config()

    # 5. 保存到 nodes.json
    save_node()

    # 6. 自动绑定 admin 用户
    bind_admin_user()

    # 7. 重新生成配置
    generate_singbox_config()

    # 8. 重载服务
    reload_singbox()
}

# 删除节点
delete_node() {
    list_nodes()
    select_node()
    remove_from_nodes_json()
    remove_bindings()
    regenerate_config()
    reload_singbox()
}

# 列出节点
list_nodes() {
    # 显示表格：端口 | 协议 | 传输 | 用户数 | 状态
    format_table()
}
```

**协议适配器**：

每个协议一个独立的配置生成函数：

```bash
# protocol_shadowsocks.sh
generate_shadowsocks_inbound() {
    local port=$1
    local method=$2
    local users=$3  # JSON array of user objects

    # 读取模板
    template=$(cat templates/protocols/shadowsocks.json)

    # 替换变量
    config=$(echo "$template" | jq \
        --arg port "$port" \
        --arg method "$method" \
        --argjson users "$users" \
        '.listen = "0.0.0.0" |
         .port = ($port | tonumber) |
         .method = $method |
         .users = $users')

    echo "$config"
}
```

### Module 3: user.sh（用户管理）

**功能**：添加、删除、列表、修改用户

**核心功能**：

```bash
add_user() {
    # 生成 UUID
    uuid=$(generate_uuid)

    # 输入用户信息
    read username email level

    # 生成密码（Shadowsocks/Trojan用）
    password=$(generate_random_password)

    # 保存到 users.json
    save_user()

    # 提示绑定节点
    prompt_bind_nodes()
}

bind_user_to_node() {
    # 选择用户
    select_user()

    # 选择节点
    select_nodes()  # 多选

    # 更新绑定关系
    update_bindings()

    # 重新生成配置
    regenerate_config()
}
```

### Module 4: domain.sh（域名管理）

**功能**：域名配置、证书关联、域名解析管理

**核心功能**：

```bash
# 添加域名
add_domain() {
    # 输入域名信息
    read domain purpose  # tls/sni/node

    # 证书配置
    if [[ "$purpose" == "tls" || "$purpose" == "node" ]]; then
        read cert_path key_path
        verify_cert_files()
    fi

    # 关联节点
    read associated_nodes

    # 保存到 domains.json
    save_domain()
}

# 批量申请证书
batch_request_certs() {
    # 遍历未配置证书的域名
    for domain in unconfigured_domains; do
        # 选择验证方式
        select_verification_method()  # HTTP-01/DNS/Standalone

        # 调用 cert.sh 申请证书
        issue_cert()

        # 更新域名证书路径
        update_domain_cert()
    done
}

# 关联域名到节点
associate_domain_to_node() {
    select_domain()
    select_node()
    update_association()
}
```

### Module 5: outbound.sh（出站规则管理）

**功能**：出站配置和路由规则管理

**核心功能**：

```bash
# 添加出站配置
add_outbound() {
    # 选择出站类型
    select_outbound_type()  # direct/block/dns/selector/urltest

    case $type in
        direct)
            add_direct_outbound()
            ;;
        block)
            add_block_outbound()
            ;;
        selector)
            # 手动选择出站
            read selector_name outbounds
            add_selector_outbound()
            ;;
        urltest)
            # 自动测速选择
            read urltest_name outbounds url interval
            add_urltest_outbound()
            ;;
    esac

    # 保存到 outbounds.json
    save_outbound()
}

# 添加路由规则
add_route_rule() {
    # 选择规则类型
    select_rule_type()  # domain/ip/geosite/geoip/port/protocol

    case $rule_type in
        domain)
            read domain_pattern outbound
            add_domain_rule()
            ;;
        ip)
            read ip_cidr outbound
            add_ip_rule()
            ;;
        geosite)
            read geosite_code outbound
            add_geosite_rule()
            ;;
        geoip)
            read geoip_code outbound
            add_geoip_rule()
            ;;
    esac

    # 保存到 route_rules.json
    save_route_rule()
}

# 设置默认出站
set_default_outbound() {
    read default_outbound
    update_final_rule()
}
```

### Module 6: cert.sh（证书管理）

**功能**：证书申请、续期、管理

**核心功能**：

```bash
# 安装 acme.sh
install_acme() {
    download_acme_sh()
    install_to_singbox_dir()
    set_default_ca()  # ZeroSSL/Let's Encrypt
}

# HTTP-01 验证申请证书
issue_cert_http() {
    local domain=$1

    # 临时停止服务
    stop_singbox()

    # 申请证书
    acme.sh --issue -d "$domain" --standalone

    # 安装证书到指定目录
    install_cert_to_dir()

    # 重启服务
    start_singbox()
}

# DNS API 验证申请证书
issue_cert_dns() {
    local domain=$1
    local dns_provider=$2

    # 选择 DNS 提供商
    select_dns_provider()  # Cloudflare/Aliyun/DNSPod

    # 输入 API 凭据
    read api_key api_secret

    # 申请证书
    acme.sh --issue -d "$domain" --dns dns_$provider

    # 安装证书
    install_cert_to_dir()
}

# 自动续期
renew_certs() {
    # acme.sh 自动续期
    acme.sh --renew-all

    # 重载服务
    reload_singbox()
}
```

### Module 7: subscription.sh（订阅管理）

**功能**：添加、更新、删除订阅源

**核心流程**：

```bash
add_subscription() {
    # 输入订阅 URL
    read url name

    # 拉取订阅内容
    content=$(curl -s "$url")

    # 解析订阅（Base64 或 JSON）
    if is_base64; then
        decode_base64()
    fi

    # 解析每个节点
    for link in $content; do
        parse_share_link()  # ss://, trojan://, hysteria2://
        add_node_from_link()
    done

    # 保存订阅信息
    save_subscription()
}

update_subscription() {
    # 重新拉取
    fetch_subscription()

    # 对比差异
    diff_nodes()

    # 更新节点
    update_nodes()

    # 重新生成配置
    regenerate_config()
}
```

**订阅链接解析器**：

支持的格式：
- `ss://` - Shadowsocks
- `trojan://` - Trojan
- `hysteria2://` - Hysteria2
- `tuic://` - TUIC
- JSON 格式订阅

---

## 🎯 开发路线图

### Phase 1: 基础框架（1-2周）

**目标**：核心可运行，基本功能可用

**任务清单**：

```
✅ 1.1 项目初始化
  - 创建目录结构
  - 编写 README.md
  - 初始化 Git 仓库

✅ 1.2 基础模块迁移
  - modules/common.sh（从 s-xray 迁移）
  - modules/safe_json.sh（从 s-xray 迁移）
  - modules/input-validation.sh（从 s-xray 迁移）

✅ 1.3 内核管理模块
  - modules/core.sh（改造为 sing-box）
    - install_singbox()：下载和安装 sing-box
    - update_singbox()：更新到最新版本
    - uninstall_singbox()：卸载清理
    - systemd 服务配置

✅ 1.4 数据文件初始化
  - 创建 data/ 目录
  - 初始化 users.json（含 admin 用户）
  - 初始化 nodes.json（空数组）
  - 初始化 node_users.json（空绑定）

✅ 1.5 配置管理基础
  - modules/config.sh
    - 配置文件路径管理
    - 备份和恢复机制
```

### Phase 2: 核心功能（2-3周）

**目标**：节点和用户管理可用，配置生成正确

**任务清单**：

```
🔥 2.1 配置生成核心（重写）
  - modules/config_generator.sh
    - 基础配置生成（log, dns, ntp）
    - inbounds 生成框架
    - outbounds 生成（direct, block）
    - route 规则生成
    - 配置合并和校验

🔥 2.2 协议模板设计
  - templates/base_config.json
  - templates/protocols/shadowsocks.json
  - templates/protocols/trojan.json
  - templates/route_rules.json

🔥 2.3 节点管理（基础协议）
  - modules/node.sh
    - add_node()：添加节点向导
    - delete_node()：删除节点
    - list_nodes()：列出所有节点
    - 支持 Shadowsocks 协议
    - 支持 Trojan 协议

🔥 2.4 用户管理
  - modules/user.sh（从 s-xray 迁移）
    - add_user()
    - delete_user()
    - list_users()
    - modify_user()

🔥 2.5 绑定关系管理
  - modules/user_node_binding.sh（从 s-xray 迁移）
    - bind_user_to_node()
    - unbind_user()
    - list_bindings()

🔥 2.6 服务控制
  - singbox-manager.sh 主脚本
    - start_singbox()
    - stop_singbox()
    - restart_singbox()
    - status_singbox()
    - 菜单系统
```

### Phase 3: 协议扩展（1-2周）

**目标**：支持 sing-box 所有协议

**任务清单**：

```
✅ 3.1 Hysteria2 协议支持
  - templates/protocols/hysteria2.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理

✅ 3.2 TUIC 协议支持
  - templates/protocols/tuic.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理

✅ 3.3 Naive 协议支持
  - templates/protocols/naive.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理

✅ 3.4 VMess 协议支持
  - templates/protocols/vmess.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理
  - 支持 TLS 和传输层配置

✅ 3.5 VLESS 协议支持
  - templates/protocols/vless.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理
  - 支持 Flow（xtls-rprx-vision）

✅ 3.6 ShadowTLS 协议支持
  - templates/protocols/shadowtls.json
  - config_generator.sh 中添加生成函数
  - node.sh 中添加节点管理
  - 支持 v1/v2/v3 版本

✅ 3.7 传输层支持
  - WebSocket 配置
  - gRPC 配置
  - templates/transports/ 模板

✅ 3.8 证书管理模块
  - modules/cert.sh 实现
  - acme.sh 集成
  - 自动续期功能

✅ 3.9 域名管理模块
  - modules/domain.sh 实现
  - TLS 证书域名管理
  - SNI 路由域名
  - 节点绑定域名

✅ 3.10 出站规则模块
  - modules/outbound.sh 实现
  - 出站配置管理（Direct/Block/DNS/Selector/URLTest）
  - 路由规则管理（Domain/IP/GeoSite/GeoIP）
```

### Phase 4: 高级功能（2-3周）

**目标**：生产环境就绪

**任务清单**：

```
🚀 4.1 订阅管理
  - modules/subscription.sh（改造）
    - add_subscription()
    - update_subscription()
    - delete_subscription()
    - list_subscriptions()
    - 订阅链接解析器（多协议）

🚀 4.2 监控统计
  - modules/monitor.sh（迁移）
    - 流量统计
    - 在线用户统计
    - 节点状态检测

🚀 4.3 API 集成
  - modules/singbox_api.sh
    - Clash API 集成（可选）
    - 统计 API 接口
    - 用户流量查询

🚀 4.4 防火墙管理
  - modules/firewall.sh（迁移）
    - 端口开放
    - 规则管理

🚀 4.5 辅助工具
  - scripts/diagnose.sh：环境诊断
  - scripts/backup.sh：配置备份
  - scripts/migrate_from_xray.sh：从 Xray 迁移

🚀 4.6 文档完善
  - 用户手册
  - 开发文档
  - API 文档
```

### Phase 5: 测试与优化（1周）

**任务清单**：

```
🧪 5.1 功能测试
  - 所有命令功能测试
  - 配置生成正确性测试
  - 边界条件测试

🧪 5.2 性能优化
  - 配置生成速度优化
  - JSON 操作优化
  - 脚本执行效率

🧪 5.3 错误处理
  - 异常捕获
  - 友好错误提示
  - 回滚机制测试

🧪 5.4 安全加固
  - 权限检查
  - 输入验证
  - 文件权限设置
```

---

## 💡 关键优化点

### 相比 s-xray 的改进

#### 1. 配置校验增强

```bash
# 在配置生成后立即校验
generate_singbox_config() {
    # ... 生成配置 ...

    # 使用 sing-box check 校验
    if ! sing-box check -c "$CONFIG_FILE"; then
        print_error "配置校验失败，自动回滚"
        restore_backup
        return 1
    fi
}
```

#### 2. 原子操作保证

```bash
# 所有 JSON 修改前备份
modify_json_file() {
    local file=$1

    # 创建备份
    cp "$file" "${file}.bak"

    # 执行修改
    if ! jq '...' "$file" > "${file}.tmp"; then
        print_error "修改失败，回滚"
        mv "${file}.bak" "$file"
        return 1
    fi

    # 提交修改
    mv "${file}.tmp" "$file"
    rm "${file}.bak"
}
```

#### 3. 进程管理改进

```bash
# 使用 PID 文件
start_singbox() {
    sing-box run -c "$CONFIG_FILE" &
    echo $! > "$PID_FILE"
}

stop_singbox() {
    if [[ -f "$PID_FILE" ]]; then
        kill $(cat "$PID_FILE")
        rm "$PID_FILE"
    fi
}
```

#### 4. 协议模板化

```
templates/protocols/
├── shadowsocks.json      # Shadowsocks 模板
├── trojan.json           # Trojan 模板
├── hysteria2.json        # Hysteria2 模板
└── tuic.json             # TUIC 模板
```

每个协议独立维护，便于更新和扩展。

#### 5. 配置分离设计

```bash
# 基础配置
base_config.json          # log, dns, ntp

# 动态配置
- inbounds：根据 nodes.json 生成
- outbounds：根据需求生成
- route：根据 route_rules.json 模板生成
```

### sing-box 特有优化

#### 1. Rule Set 支持

```json
{
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "outbound": "direct"
      }
    ]
  }
}
```

#### 2. 缓存文件

```json
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/usr/local/singbox/cache.db",
      "store_fakeip": true
    }
  }
}
```

#### 3. Clash API 集成

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "secret": "your-secret"
    }
  }
}
```

---

## 📝 配置示例

### 完整配置示例

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns_proxy",
        "address": "tls://8.8.8.8",
        "address_resolver": "dns_resolver"
      },
      {
        "tag": "dns_direct",
        "address": "223.5.5.5",
        "address_resolver": "dns_resolver",
        "detour": "direct"
      },
      {
        "tag": "dns_resolver",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns_resolver"
      },
      {
        "rule_set": "geosite-cn",
        "server": "dns_direct"
      }
    ],
    "final": "dns_proxy"
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-443",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "method": "aes-128-gcm",
      "users": [
        {
          "name": "admin@local",
          "password": "strong-password"
        }
      ]
    },
    {
      "type": "hysteria2",
      "tag": "hy2-8443",
      "listen": "0.0.0.0",
      "listen_port": 8443,
      "users": [
        {
          "name": "user1@local",
          "password": "password123"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "certificate_path": "/path/to/cert.pem",
        "key_path": "/path/to/key.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs"
      }
    ],
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "rule_set": "geosite-cn",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/usr/local/singbox/cache.db"
    }
  }
}
```

---

## 🧪 测试计划

### 单元测试

```bash
# 测试 JSON 操作
test_json_operations() {
    test_add_user
    test_delete_user
    test_add_node
    test_bind_user_to_node
}

# 测试配置生成
test_config_generation() {
    test_generate_shadowsocks_inbound
    test_generate_trojan_inbound
    test_generate_hysteria2_inbound
    test_merge_config
    test_validate_config
}

# 测试服务控制
test_service_control() {
    test_start_service
    test_stop_service
    test_restart_service
    test_status_check
}
```

### 集成测试

```bash
# E2E 测试流程
test_full_workflow() {
    # 1. 安装
    ./install.sh

    # 2. 添加节点
    singbox-manager node add

    # 3. 添加用户
    singbox-manager user add

    # 4. 绑定关系
    singbox-manager bind

    # 5. 启动服务
    singbox-manager service start

    # 6. 验证连接
    test_connection

    # 7. 清理
    ./uninstall.sh
}
```

---

## 📚 参考资料

### sing-box 官方文档

- 配置文档：https://sing-box.sagernet.org/configuration/
- Inbound 文档：https://sing-box.sagernet.org/configuration/inbound/
- Outbound 文档：https://sing-box.sagernet.org/configuration/outbound/
- Route 文档：https://sing-box.sagernet.org/configuration/route/

### s-xray 项目

- GitHub: https://github.com/sindricn/s-xray
- 架构设计：三层数据模型
- 模块化组织：17个功能模块

### 工具链

- jq：JSON 处理
- systemd：服务管理
- acme.sh：证书申请
- curl/wget：订阅拉取

---

## 🎯 里程碑

### M1: 基础框架完成（Week 2）
- ✅ 项目结构搭建
- ✅ 基础模块迁移
- ✅ 内核管理可用

### M2: 核心功能完成（Week 5）
- ✅ 节点管理（SS/Trojan）
- ✅ 用户管理
- ✅ 配置生成正确
- ✅ 服务控制正常

### M3: 协议扩展完成（Week 7）
- ✅ Hysteria2 支持
- ✅ TUIC 支持
- ✅ Naive 支持
- ✅ VMess 支持
- ✅ VLESS 支持
- ✅ ShadowTLS 支持
- ✅ 传输层配置（WebSocket/gRPC）
- ✅ 证书管理模块
- ✅ 域名管理模块
- ✅ 出站规则模块

### M4: 生产就绪（Week 10）
- ✅ 订阅管理
- ✅ 监控统计
- ✅ 防火墙管理
- ✅ API 集成
- 🔄 文档完善（进行中）

---

## 🚀 快速开始

### 开发环境准备

```bash
# 克隆 s-xray 项目（参考）
git clone https://github.com/sindricn/s-xray.git

# 创建新项目
mkdir s-singbox
cd s-singbox

# 初始化目录结构
mkdir -p modules templates/{protocols,transports} scripts data

# 开始开发
vim singbox-manager.sh
```

### 第一阶段任务

```bash
# 1. 迁移 common.sh
cp ../s-xray/modules/common.sh modules/

# 2. 改造 core.sh
# 将所有 xray 相关改为 sing-box

# 3. 编写 config_generator.sh 框架
# 参考 s-xray/modules/config_generator.sh 但完全重写

# 4. 测试基础功能
./singbox-manager.sh
```

---

## ✅ 验收标准

### 功能验收

- [ ] 所有命令可正常执行
- [ ] 配置生成正确且通过 sing-box check
- [ ] 服务启动/停止/重启正常
- [ ] 用户管理功能完整
- [ ] 节点管理功能完整
- [ ] 订阅更新正常
- [ ] 流量统计准确

### 质量验收

- [ ] 代码模块化清晰
- [ ] 错误处理完善
- [ ] 日志记录详细
- [ ] 文档齐全
- [ ] 测试覆盖充分

### 性能验收

- [ ] 配置生成 < 2s
- [ ] 服务启动 < 3s
- [ ] 订阅更新 < 10s
- [ ] 内存占用 < 50MB

---

## 📞 联系与支持

- 项目地址：https://github.com/your-name/s-singbox
- 问题反馈：GitHub Issues
- 参考项目：s-xray (https://github.com/sindricn/s-xray)

---

**本方案基于深度分析 s-xray 架构和 sing-box 官方文档，确保可执行性和完整性。**

**预计总开发时间：8-10周**
**建议团队规模：1-2人**
**技术栈：Bash + jq + systemd + sing-box**
