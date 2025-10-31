# S-Xray 项目文件架构图

## 📁 项目文件组织结构

```
s-xray/
│
├── 📄 xray-manager.sh                    # 🎯 主入口 (2,438行)
│   └─ 职责: 模块加载、主菜单、数据初始化
│
├── 📄 install.sh                         # 📦 安装脚本 (287行)
│   └─ 职责: 系统检测、依赖安装、项目部署
│
├── 📄 uninstall.sh                       # 🗑️ 卸载脚本 (344行)
│   └─ 职责: 三级卸载选项、清理残留
│
├── 📂 modules/                           # 🧩 核心模块目录
│   │
│   ├── 📄 common.sh                      # 🛠️ 公共库 (443行)
│   │   ├─ log()                          # 五级日志系统
│   │   ├─ ensure_json_file()            # JSON文件安全
│   │   ├─ validate_json_file()          # JSON格式验证
│   │   └─ confirm_action()              # 用户确认提示
│   │
│   ├── 📄 input-validation.sh            # 🔒 输入验证 (433行)
│   │   ├─ validate_port_enhanced()      # 端口验证+占用检测
│   │   ├─ validate_domain()             # 域名格式+DNS验证
│   │   ├─ validate_uuid()               # UUID格式校验
│   │   └─ validate_*_config()           # 协议配置验证
│   │
│   ├── 📄 core.sh                        # ⚙️ 内核管理 (231行)
│   │   ├─ install_xray()                # 智能安装(架构检测)
│   │   ├─ update_xray()                 # 版本更新
│   │   ├─ uninstall_xray()              # 卸载清理
│   │   └─ manage_xray_service()         # systemd服务管理
│   │
│   ├── 📄 node.sh                        # 📡 节点管理 (1,836行)
│   │   ├─ quick_add_vless_reality()     # 一键快速部署
│   │   ├─ add_vless_node()              # VLESS节点添加
│   │   ├─ add_vmess_node()              # VMess节点添加
│   │   ├─ add_trojan_node()             # Trojan节点添加
│   │   ├─ add_shadowsocks_node()        # SS节点添加
│   │   ├─ list_nodes()                  # 节点列表展示
│   │   ├─ delete_node()                 # 删除节点
│   │   └─ generate_share_link()         # 分享链接生成
│   │
│   ├── 📄 user.sh                        # 👤 用户管理 (1,563行)
│   │   ├─ init_admin_user()             # 初始化admin用户
│   │   ├─ add_global_user()             # 添加全局用户
│   │   ├─ list_global_users()           # 用户列表(带在线状态)
│   │   ├─ modify_user_menu()            # 修改用户属性
│   │   ├─ delete_global_user()          # 删除用户+解绑
│   │   ├─ set_traffic_limit()           # 流量限制设置
│   │   └─ check_user_status()           # 用户状态检测
│   │
│   ├── 📄 user_node_binding.sh           # 🔗 绑定管理 (1,747行)
│   │   ├─ bind_user_to_node()           # 用户绑定节点
│   │   ├─ unbind_user_from_node()       # 解绑用户
│   │   ├─ list_user_bindings()          # 查看用户绑定
│   │   ├─ list_node_users()             # 查看节点用户
│   │   └─ batch_bind_operations()       # 批量绑定操作
│   │
│   ├── 📄 config_generator.sh            # ⚡ 配置生成器 (611行)
│   │   ├─ generate_xray_config()        # 主配置生成逻辑
│   │   ├─ generate_inbound()            # inbound配置生成
│   │   ├─ generate_clients()            # clients配置生成
│   │   ├─ generate_stream_settings()    # 传输层配置
│   │   └─ generate_security_settings()  # 安全层配置
│   │
│   ├── 📄 subscription.sh                # 📮 订阅管理 (3,486行)
│   │   ├─ generate_subscription()       # 生成订阅
│   │   ├─ update_subscription()         # 更新订阅
│   │   ├─ delete_subscription()         # 删除订阅
│   │   ├─ generate_base64_sub()         # Base64格式
│   │   ├─ generate_clash_sub()          # Clash YAML格式
│   │   └─ generate_singbox_sub()        # SingBox JSON格式
│   │
│   ├── 📄 outbound.sh                    # 🌐 出站管理 (1,893行)
│   │   ├─ add_outbound_rule()           # 添加出站规则
│   │   ├─ list_outbound_rules()         # 列出规则库
│   │   ├─ delete_outbound_rule()        # 删除规则
│   │   ├─ bind_node_outbound()          # 节点绑定出站
│   │   └─ check_outbound_consistency()  # 一致性检测
│   │
│   ├── 📄 firewall.sh                    # 🔥 防火墙 (320行)
│   │   ├─ detect_firewall()             # 智能识别防火墙类型
│   │   ├─ open_port()                   # 开放端口(TCP/UDP)
│   │   ├─ close_port()                  # 关闭端口
│   │   └─ show_firewall_rules()         # 查看规则
│   │
│   ├── 📄 monitor.sh                     # 📊 监控统计 (267行)
│   │   ├─ show_status()                 # 系统状态展示
│   │   ├─ show_traffic()                # 流量统计
│   │   ├─ get_online_users()            # 在线用户检测
│   │   └─ show_realtime_traffic()       # 实时速率监控
│   │
│   ├── 📄 xray_api.sh                    # 🔌 Xray API (318行)
│   │   ├─ api_add_user()                # 动态添加用户
│   │   ├─ api_remove_user()             # 动态删除用户
│   │   ├─ api_reload_user()             # 重载用户配置
│   │   ├─ api_test_connection()         # API连接测试
│   │   └─ api_list_inbounds()           # 列出inbound
│   │
│   ├── 📄 domain.sh                      # 🌍 域名管理 (1,214行)
│   │   ├─ test_best_reality_domains()   # 域名优选(延迟测试)
│   │   ├─ get_default_domain()          # 获取默认域名
│   │   ├─ set_default_domain()          # 设置默认域名
│   │   └─ manage_certificates()         # 证书管理
│   │
│   ├── 📄 selector.sh                    # 🎯 选择器 (363行)
│   │   ├─ select_node()                 # 节点选择器
│   │   ├─ select_user()                 # 用户选择器
│   │   └─ get_*_by_index()              # 索引转换工具
│   │
│   ├── 📄 safe_json.sh                   # 💾 安全JSON (111行)
│   │   ├─ safe_json_write()             # 原子性写入
│   │   ├─ validate_json_syntax()        # 语法验证
│   │   └─ rollback_on_error()           # 错误回滚
│   │
│   └── 📄 config.sh                      # 🗂️ 配置管理 (297行)
│       ├─ backup_config()               # 配置备份
│       ├─ restore_config()              # 配置恢复
│       ├─ list_backups()                # 列出备份
│       └─ validate_config()             # 配置验证
│
├── 📂 scripts/                           # 🛠️ 工具脚本目录
│   ├── 📄 check_jq_version.sh           # jq版本检查
│   ├── 📄 diagnose_env.sh               # 环境诊断
│   ├── 📄 diagnose_stats.sh             # Stats API诊断
│   ├── 📄 test_stats_api.sh             # API测试工具
│   └── 📄 migrate_to_separated_architecture.sh  # 架构迁移
│
├── 📂 docs/                              # 📚 文档目录
│   └── 📄 architecture-files.md         # 本文件
│
└── 📂 .claude/                           # 🤖 Claude配置
    └── 📄 settings.local.json           # 本地设置

```

## 📊 文件统计

| 类型 | 数量 | 总行数 | 说明 |
|------|------|--------|------|
| **主脚本** | 3 | 3,069行 | 入口+安装+卸载 |
| **核心模块** | 18 | ~14,000行 | 功能实现 |
| **工具脚本** | 5 | ~500行 | 辅助工具 |
| **配置文件** | 1 | - | Claude设置 |
| **总计** | 27 | ~17,500行 | Shell代码 |

## 🔄 模块加载顺序

```
xray-manager.sh 启动
    ↓
1. source modules/common.sh              # 最先加载(日志系统)
    ↓
2. source modules/input-validation.sh    # 第二加载(安全基础)
    ↓
3. source modules/safe_json.sh           # JSON安全操作
    ↓
4. 遍历加载其他模块:
   ├─ core.sh
   ├─ node.sh
   ├─ user.sh
   ├─ user_node_binding.sh
   ├─ config_generator.sh
   ├─ subscription.sh
   ├─ outbound.sh
   ├─ firewall.sh
   ├─ monitor.sh
   ├─ xray_api.sh
   ├─ domain.sh
   ├─ selector.sh
   └─ config.sh
    ↓
5. 初始化数据目录
    ↓
6. 初始化admin用户
    ↓
7. 进入主菜单循环
```

## 📦 依赖关系图

```
common.sh (公共库)
    ├─ 被所有模块依赖
    └─ 提供: log()、confirm_action()、json工具

input-validation.sh (验证库)
    ├─ 被依赖: node.sh、user.sh、subscription.sh
    └─ 提供: validate_*() 系列函数

safe_json.sh (JSON库)
    ├─ 被依赖: 所有数据操作模块
    └─ 提供: 安全的JSON读写

config_generator.sh (配置生成器)
    ├─ 依赖: node.sh、user.sh、user_node_binding.sh
    ├─ 读取: nodes.json、users.json、node_users.json
    └─ 生成: config.json

xray_api.sh (API模块)
    ├─ 依赖: user.sh、node.sh
    └─ 作用: 动态管理用户(无需重启)

subscription.sh (订阅模块)
    ├─ 依赖: user.sh、node.sh、user_node_binding.sh
    └─ 生成: Base64/Clash/SingBox订阅文件

monitor.sh (监控模块)
    ├─ 依赖: xray_api.sh、user.sh
    └─ 提供: 流量统计、在线状态
```

## 🗂️ 数据文件结构

```
/usr/local/xray/
├── 📄 xray                              # Xray可执行文件
├── 📄 config.json                       # 当前运行配置(生成)
├── 📂 data/                             # 数据存储目录
│   ├── 📄 users.json                    # 全局用户池
│   ├── 📄 nodes.json                    # 节点配置库
│   ├── 📄 node_users.json               # 绑定关系表
│   ├── 📄 outbounds.json                # 出站规则库
│   ├── 📄 domains.json                  # 域名管理数据
│   ├── 📄 default_domain.txt            # 默认域名
│   ├── 📄 subscription_metadata.json    # 订阅元数据
│   └── 📂 subscriptions/                # 订阅文件目录
│       ├── 📄 {user}_{type}.txt         # Base64订阅
│       ├── 📄 {user}_{type}.yaml        # Clash订阅
│       └── 📄 {user}_{type}.json        # SingBox订阅
│
├── 📂 backup/                           # 配置备份目录
│   └── 📄 config.json.{timestamp}       # 历史备份
│
└── 📂 logs/                             # 日志目录
    └── 📄 xray-manager.log              # 管理脚本日志
```

## 🔑 关键文件说明

### 1️⃣ xray-manager.sh (主入口)
- **职责**: 整个系统的入口和调度中心
- **行数**: 2,438行
- **关键功能**:
  - 模块加载器 (source_modules)
  - 主菜单系统 (10个功能模块菜单)
  - 数据初始化 (init_data_dir, init_admin_user)
  - 状态显示 (版本、用户数、节点数、在线数)

### 2️⃣ config_generator.sh (配置核心)
- **职责**: 将JSON数据转换为Xray配置文件
- **行数**: 611行
- **关键逻辑**:
  1. 读取 nodes.json、users.json、node_users.json
  2. 遍历节点,生成inbounds配置
  3. 根据绑定关系添加clients
  4. 生成streamSettings(传输层)
  5. 生成security配置(Reality/TLS)
  6. 原子性写入config.json
  7. 重启Xray服务

### 3️⃣ subscription.sh (订阅核心)
- **职责**: 生成三种订阅格式
- **行数**: 3,486行
- **支持格式**:
  - Base64: 通用格式(Shadowrocket/V2rayNG)
  - Clash: YAML格式(Clash/ClashX)
  - SingBox: JSON格式(sing-box)

### 4️⃣ node.sh (节点核心)
- **职责**: 节点CRUD和协议配置
- **行数**: 1,836行
- **支持协议**:
  - VLESS (Reality/TLS/TCP)
  - VMess (TLS/TCP/WS/mKCP)
  - Trojan (TLS)
  - Shadowsocks (2022版)

### 5️⃣ user.sh (用户核心)
- **职责**: 全局用户管理
- **行数**: 1,563行
- **核心功能**:
  - 用户CRUD
  - 流量管理
  - 有效期控制
  - 在线状态检测

## 📐 架构设计原则

### ✅ 模块化
- 每个模块职责单一,独立可维护
- 通过公共库统一接口

### ✅ 数据与配置分离
- 数据存储: JSON文件 (users.json, nodes.json)
- 配置生成: config_generator.sh 动态生成

### ✅ 安全优先
- 输入验证: input-validation.sh 统一验证
- JSON安全: safe_json.sh 原子性操作
- 日志审计: common.sh 分级日志

### ✅ 易于扩展
- 添加新协议: 修改 node.sh 和 config_generator.sh
- 添加新功能: 创建新模块并在 xray-manager.sh 中加载
