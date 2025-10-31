# S-SingBox 项目文件架构图

## 📁 项目文件组织结构

```
s-singbox/
│
├── 📄 singbox-manager.sh                 # 🎯 主入口 (约670行)
│   └─ 职责: 模块加载、主菜单、数据初始化
│
├── 📄 install.sh                         # 📦 安装脚本 (约435行)
│   └─ 职责: 系统检测、依赖安装、内核安装、在线安装支持
│
├── 📄 uninstall.sh                       # 🗑️ 卸载脚本
│   └─ 职责: 卸载清理、数据保留选项
│
├── 📂 modules/                           # 🧩 核心模块目录 (16个模块)
│   │
│   ├── 📄 common.sh                      # 🛠️ 公共库 (584行)
│   │   ├─ log_*()                        # 五级日志系统
│   │   ├─ ensure_dir()                   # 目录管理
│   │   ├─ generate_uuid()                # UUID生成
│   │   ├─ generate_random_password()     # 密码生成
│   │   └─ confirm()                      # 用户确认提示
│   │
│   ├── 📄 input-validation.sh            # 🔒 输入验证 (501行)
│   │   ├─ validate_port()                # 端口验证
│   │   ├─ validate_domain()              # 域名格式验证
│   │   ├─ validate_uuid()                # UUID格式校验
│   │   └─ validate_*_config()            # 协议配置验证
│   │
│   ├── 📄 safe_json.sh                   # 💾 安全JSON (503行)
│   │   ├─ safe_json_write()              # 原子性写入
│   │   ├─ safe_json_read()               # 安全读取
│   │   ├─ validate_json()                # JSON验证
│   │   └─ backup_json()                  # JSON备份
│   │
│   ├── 📄 selector.sh                    # 🎯 选择器 (新增)
│   │   ├─ select_node()                  # 节点选择器
│   │   ├─ select_user()                  # 用户选择器
│   │   ├─ select_multiple_users()        # 多选用户
│   │   ├─ get_*_by_index()               # 索引转换工具
│   │   └─ node_exists()/user_exists()    # 存在性验证
│   │
│   ├── 📄 core.sh                        # ⚙️ 内核管理 (657行)
│   │   ├─ install_singbox()              # 智能安装(架构检测)
│   │   ├─ update_singbox()               # 版本更新
│   │   ├─ uninstall_singbox()            # 卸载清理
│   │   └─ *_singbox_service()            # systemd服务管理
│   │
│   ├── 📄 node.sh                        # 📡 节点管理 (1,072行)
│   │   ├─ add_*_node()                   # 添加各协议节点
│   │   │  • VLESS (Reality/TLS)
│   │   │  • VMess (WebSocket/gRPC)
│   │   │  • Trojan (TLS)
│   │   │  • Shadowsocks
│   │   │  • Hysteria2
│   │   ├─ list_nodes()                   # 节点列表展示
│   │   ├─ delete_node()                  # 删除节点
│   │   └─ generate_share_link()          # 分享链接生成
│   │
│   ├── 📄 user.sh                        # 👤 用户管理 (567行)
│   │   ├─ add_user()                     # 添加用户
│   │   ├─ list_users()                   # 用户列表
│   │   ├─ modify_user()                  # 修改用户属性
│   │   ├─ delete_user()                  # 删除用户
│   │   ├─ set_traffic_limit()            # 流量限制设置
│   │   └─ check_user_status()            # 用户状态检测
│   │
│   ├── 📄 user_node_binding.sh           # 🔗 绑定管理 (536行)
│   │   ├─ bind_user_to_node()            # 用户绑定节点
│   │   ├─ unbind_user_from_node()        # 解绑用户
│   │   ├─ list_user_bindings()           # 查看用户绑定
│   │   ├─ list_node_users()              # 查看节点用户
│   │   ├─ batch_bind_users()             # 批量绑定操作
│   │   └─ cleanup_empty_bindings()       # 清理空绑定
│   │
│   ├── 📄 config_generator.sh            # ⚡ 配置生成器 (733行)
│   │   ├─ generate_singbox_config()      # 主配置生成逻辑
│   │   ├─ generate_inbound()             # inbound配置生成
│   │   ├─ generate_users()               # users配置生成
│   │   ├─ generate_transport()           # 传输层配置
│   │   └─ generate_tls_settings()        # TLS/Reality配置
│   │
│   ├── 📄 subscription.sh                # 📮 订阅管理 (520行)
│   │   ├─ generate_subscription()        # 生成订阅
│   │   ├─ update_subscription()          # 更新订阅
│   │   ├─ delete_subscription()          # 删除订阅
│   │   ├─ generate_v2ray_sub()           # V2Ray格式
│   │   ├─ generate_clash_sub()           # Clash YAML格式
│   │   └─ generate_singbox_sub()         # SingBox JSON格式
│   │
│   ├── 📄 outbound.sh                    # 🌐 出站管理 (784行)
│   │   ├─ add_outbound()                 # 添加出站规则
│   │   ├─ list_outbounds()               # 列出规则库
│   │   ├─ delete_outbound()              # 删除规则
│   │   ├─ bind_node_outbound()           # 节点绑定出站
│   │   └─ test_outbound()                # 出站测试
│   │
│   ├── 📄 domain.sh                      # 🌍 域名管理 (531行)
│   │   ├─ add_domain()                   # 添加域名
│   │   ├─ list_domains()                 # 列出域名
│   │   ├─ delete_domain()                # 删除域名
│   │   ├─ test_domain_latency()          # 域名延迟测试
│   │   └─ get_best_domain()              # 获取最优域名
│   │
│   ├── 📄 cert.sh                        # 🔐 证书管理 (535行)
│   │   ├─ generate_self_signed_cert()    # 生成自签名证书
│   │   ├─ request_acme_cert()            # ACME证书申请
│   │   ├─ renew_cert()                   # 证书续期
│   │   ├─ list_certs()                   # 列出证书
│   │   └─ delete_cert()                  # 删除证书
│   │
│   ├── 📄 firewall.sh                    # 🔥 防火墙 (549行)
│   │   ├─ detect_firewall()              # 智能识别防火墙类型
│   │   ├─ open_port()                    # 开放端口(TCP/UDP)
│   │   ├─ close_port()                   # 关闭端口
│   │   └─ show_firewall_rules()          # 查看规则
│   │
│   ├── 📄 monitor.sh                     # 📊 监控统计 (511行)
│   │   ├─ show_status()                  # 系统状态展示
│   │   ├─ show_traffic()                 # 流量统计
│   │   ├─ get_online_users()             # 在线用户检测
│   │   └─ show_realtime_traffic()        # 实时速率监控
│   │
│   ├── 📄 singbox_api.sh                 # 🔌 SingBox API (466行)
│   │   ├─ api_add_user()                 # 动态添加用户
│   │   ├─ api_remove_user()              # 动态删除用户
│   │   ├─ api_reload_config()            # 重载配置
│   │   └─ api_get_stats()                # 获取统计信息
│   │
│   └── 📄 config.sh                      # 🗂️ 配置管理 (393行)
│       ├─ backup_config()                # 配置备份
│       ├─ restore_config()               # 配置恢复
│       ├─ list_backups()                 # 列出备份
│       └─ validate_config()              # 配置验证
│
├── 📂 scripts/                           # 🛠️ 工具脚本目录
│   ├── 📄 diagnose.sh                    # 系统诊断工具
│   └── 📄 backup.sh                      # 数据备份工具
│
├── 📂 docs/                              # 📚 文档目录
│   ├── 📄 architecture-files.md          # 本文件
│   └── 📄 architecture-modules.md        # 模块架构文档
│
└── 📂 data/                              # 💾 数据目录 (运行时创建)
    ├── 📄 users.json                     # 用户数据
    ├── 📄 nodes.json                     # 节点配置
    ├── 📄 node_users.json                # 绑定关系
    ├── 📄 domains.json                   # 域名数据
    ├── 📄 outbounds.json                 # 出站规则
    └── 📄 route_rules.json               # 路由规则

```

## 📊 文件统计

| 类型 | 数量 | 总行数 | 说明 |
|------|------|--------|------|
| **主脚本** | 3 | ~1,100行 | 入口+安装+卸载 |
| **核心模块** | 16 | ~8,500行 | 功能实现 |
| **工具脚本** | 2 | ~200行 | 辅助工具 |
| **总计** | 21 | ~9,800行 | Shell代码 |

## 🔄 模块加载顺序（优先级加载）

```
singbox-manager.sh 启动
    ↓
1. source modules/common.sh              # 最先加载(日志系统、工具函数)
    ↓
2. 第二优先级加载:
   ├─ input-validation.sh                # 输入验证(安全基础)
   └─ safe_json.sh                       # JSON安全操作
    ↓
3. 第三优先级加载:
   └─ selector.sh                        # 选择器模块
    ↓
4. 第四优先级加载业务模块:
   ├─ core.sh                            # 内核管理
   ├─ node.sh                            # 节点管理
   ├─ user.sh                            # 用户管理
   ├─ user_node_binding.sh               # 绑定管理
   ├─ config_generator.sh                # 配置生成
   ├─ subscription.sh                    # 订阅管理
   ├─ outbound.sh                        # 出站管理
   ├─ domain.sh                          # 域名管理
   ├─ cert.sh                            # 证书管理
   ├─ firewall.sh                        # 防火墙管理
   ├─ monitor.sh                         # 监控统计
   ├─ singbox_api.sh                     # API管理
   └─ config.sh                          # 配置管理
    ↓
5. 初始化数据目录
    ↓
6. 初始化 admin 用户
    ↓
7. 进入主菜单循环
```

## 📦 依赖关系图

```
common.sh (公共库)
    ├─ 被所有模块依赖
    └─ 提供: log_*()、confirm()、工具函数

input-validation.sh (验证库)
    ├─ 被依赖: node.sh、user.sh、subscription.sh
    └─ 提供: validate_*() 系列函数

safe_json.sh (JSON库)
    ├─ 被依赖: 所有数据操作模块
    └─ 提供: 安全的JSON读写

selector.sh (选择器库)
    ├─ 被依赖: 所有需要选择的模块
    └─ 提供: select_*()、get_*_by_index()

config_generator.sh (配置生成器)
    ├─ 依赖: node.sh、user.sh、user_node_binding.sh
    ├─ 读取: nodes.json、users.json、node_users.json
    └─ 生成: config.json

singbox_api.sh (API模块)
    ├─ 依赖: user.sh、node.sh
    └─ 作用: 动态管理用户和配置

subscription.sh (订阅模块)
    ├─ 依赖: user.sh、node.sh、user_node_binding.sh
    └─ 生成: V2Ray/Clash/SingBox订阅文件

monitor.sh (监控模块)
    ├─ 依赖: singbox_api.sh、user.sh
    └─ 提供: 流量统计、在线状态
```

## 🗂️ 数据文件结构

```
/usr/local/singbox/
├── 📄 sing-box                          # SingBox可执行文件
├── 📄 config.json                       # 当前运行配置(生成)
├── 📂 data/                             # 数据存储目录
│   ├── 📄 users.json                    # 全局用户池
│   ├── 📄 nodes.json                    # 节点配置库
│   ├── 📄 node_users.json               # 绑定关系表
│   ├── 📄 outbounds.json                # 出站规则库
│   ├── 📄 domains.json                  # 域名管理数据
│   ├── 📄 route_rules.json              # 路由规则
│   └── 📂 subscriptions/                # 订阅文件目录
│       ├── 📄 {user}_v2ray.txt          # V2Ray订阅
│       ├── 📄 {user}_clash.yaml         # Clash订阅
│       └── 📄 {user}_singbox.json       # SingBox订阅
│
├── 📂 backup/                           # 配置备份目录
│   └── 📄 config.json.{timestamp}       # 历史备份
│
└── 📂 logs/                             # 日志目录
    ├── 📄 singbox.log                   # SingBox运行日志
    └── 📄 manager.log                   # 管理脚本日志
```

## 🔑 关键文件说明

### 1️⃣ singbox-manager.sh (主入口)
- **职责**: 整个系统的入口和调度中心
- **行数**: ~670行
- **关键功能**:
  - 优先级模块加载器 (load_modules)
  - 主菜单系统 (12个功能模块菜单)
  - 数据初始化 (init_data_dir, init_users_file)
  - 状态显示 (版本、用户数、节点数)

### 2️⃣ config_generator.sh (配置核心)
- **职责**: 将JSON数据转换为SingBox配置文件
- **行数**: 733行
- **关键逻辑**:
  1. 读取 nodes.json、users.json、node_users.json
  2. 遍历节点,生成inbounds配置
  3. 根据绑定关系添加users
  4. 生成transport配置(传输层)
  5. 生成tls配置(Reality/TLS)
  6. 原子性写入config.json
  7. 重启SingBox服务

### 3️⃣ subscription.sh (订阅核心)
- **职责**: 生成三种订阅格式
- **行数**: 520行
- **支持格式**:
  - V2Ray: Base64格式(通用客户端)
  - Clash: YAML格式(Clash/ClashX)
  - SingBox: JSON格式(sing-box客户端)

### 4️⃣ node.sh (节点核心)
- **职责**: 节点CRUD和协议配置
- **行数**: 1,072行
- **支持协议**:
  - VLESS (Reality/TLS)
  - VMess (WebSocket/gRPC)
  - Trojan (TLS)
  - Shadowsocks
  - Hysteria2

### 5️⃣ selector.sh (选择器核心) 【新增】
- **职责**: 统一的选择器接口
- **关键功能**:
  - 节点选择器
  - 用户选择器
  - 多选功能
  - 索引转换
  - 存在性验证

## 📐 架构设计原则

### ✅ 模块化
- 每个模块职责单一,独立可维护
- 通过公共库统一接口
- 优先级加载确保依赖顺序

### ✅ 数据与配置分离
- 数据存储: JSON文件 (users.json, nodes.json)
- 配置生成: config_generator.sh 动态生成
- 分离式架构便于管理和扩展

### ✅ 安全优先
- 输入验证: input-validation.sh 统一验证
- JSON安全: safe_json.sh 原子性操作
- 日志审计: common.sh 分级日志

### ✅ 代码复用
- 选择器模块: 统一的选择接口，避免代码重复
- 公共库: 工具函数集中管理
- 验证模块: 输入验证统一处理

### ✅ 易于扩展
- 添加新协议: 修改 node.sh 和 config_generator.sh
- 添加新功能: 创建新模块并在加载列表中注册
- 模块化设计: 新模块独立开发，最小化影响
