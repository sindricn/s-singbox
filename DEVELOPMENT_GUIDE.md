# 开发文档：基于 sing-box 内核的节点管理工具 (s-singbox)

## 1. 项目定位与目标

本项目旨在创建一个功能强大且高度自动化的 CLI 工具，用于管理 `sing-box` 核心。其设计哲学严格参考 `s-xray`，专注于通过命令行接口（CLI）实现对 `sing-box` 配置的动态生成、节点管理和服务生命周期控制。

**核心原则**:
- **对标 `s-xray`**: 在架构设计、功能模块、命令结构和操作流程上，与 `s-xray` 保持高度一致性。
- **CLI 优先**: 所有功能都通过命令行实现，不考虑图形化界面（GUI/WebUI）。
- **配置即代码**: 通过结构化的数据（JSON/YAML）和模板来管理复杂的 `sing-box` 配置。
- **官方文档为准**: 所有生成的配置片段必须严格遵守 `sing-box` 官方文档的规范。

---

## 2. 核心架构设计

整体架构遵循 `s-xray` 的模式，将用户输入、数据持久化、配置生成和进程控制解耦。

![Architecture Diagram](https://i.imgur.com/your-placeholder-diagram.png)  <!-- 这是一个占位符，实际开发中可以替换为架构图 -->

1.  **`sing-box` 内核 (Core Engine)**:
    - 作为项目的底层依赖，负责实际的网络代理功能。
    - 本工具通过生成 `config.json` 并管理其进程来间接控制它。

2.  **配置层 (Configuration Layer)**:
    - **`config.template.json` (配置模板)**: 这是 `sing-box` 配置的骨架。它包含了除 `outbounds` 和 `route` 规则外的所有静态配置（如 `inbounds`, `dns`, `log` 等）。这是用户进行个性化定制的主要入口。
    - **`s-singbox.json` (工具配置文件)**: 类似于 `s-xray` 的核心配置文件，用于定义工具自身的行为，例如 `sing-box` 可执行文件的路径、配置文件的生成路径等。
    - **`nodes.json` (节点数据库)**: 持久化存储所有出站节点信息的数据库文件。每个节点的格式都需要标准化。

3.  **数据管理层 (Data Management Layer)**:
    - 负责对 `nodes.json` 文件进行原子性的增、删、改、查（CRUD）操作。
    - 提供接口供上层模块调用，屏蔽直接的文件读写细节。

4.  **命令执行层 (Command Execution Layer)**:
    - 这是 CLI 的入口，负责解析用户输入的命令和参数（例如 `s-singbox node add`）。
    - 根据不同的命令，调用下层的服务模块来完成具体任务。

5.  **服务模块层 (Service Modules)**:
    - **节点管理模块 (Node Manager)**: 处理与节点相关的逻辑，如添加、删除、列表展示、格式转换等。
    - **配置生成模块 (Config Generator)**: 核心模块。它读取 `config.template.json` 和 `nodes.json`，将两者合并，生成最终供 `sing-box` 使用的 `config.json`。
    - **服务控制模块 (Service Controller)**: 负责管理 `sing-box` 的进程，包括启动、停止、重启、状态查询和日志查看。
    - **订阅管理模块 (Subscription Manager)**: (高级功能) 负责拉取、解析和更新来自远程 URL 的节点订阅。

---

## 3. 功能模块详解

### 3.1. 节点管理 (Node)

- **数据模型**: 定义统一的节点输入格式。为了兼容性，可以设计成能直接解析 `sing-box` outbound 片段的 JSON 格式，并为其补充一个唯一的 `tag` 字段。
- **命令**:
    - `s-singbox node add -f <node.json>`: 从指定的 JSON 文件添加一个或多个节点。
    - `s-singbox node ls`: 列出当前 `nodes.json` 中的所有节点，并显示关键信息（tag, server, protocol）。
    - `s-singbox node rm --tag <node_tag>`: 根据 `tag` 删除一个节点。
    - `s-singbox node test --tag <node_tag>`: (高级功能) 测试指定节点的连通性。

### 3.2. 配置生成 (Generate)

- **逻辑**:
    1. 读取 `s-singbox.json` 获取模板和输出路径。
    2. 读取 `config.template.json` 作为基础配置。
    3. 读取 `nodes.json` 获取所有节点。
    4. 将节点列表注入到基础配置的 `outbounds` 数组中。
    5. **（重要）** 动态生成 `route` 规则。例如，可以创建一个名为 "proxy" 的 `selector` 出站，并将所有节点作为其成员，然后在路由规则中直接使用 "proxy" 作为出口。
    6. 将最终生成的完整配置写入 `config.json`。
- **命令**:
    - `s-singbox generate`: 手动触发一次配置生成。这个命令通常在其他命令（如 `node add`）后自动调用。

### 3.3. 服务控制 (Service)

- **实现**: 通过操作系统的 `exec` 或 `spawn` 等功能来执行 `sing-box` 的二进制文件。
- **命令**:
    - `s-singbox service start`: 启动 `sing-box` 进程。在启动前，应先调用 `sing-box check -c config.json` 验证配置文件的合法性。
    - `s-singbox service stop`: 停止 `sing-box` 进程。
    - `s-singbox service restart`: 重启服务。通常是 `stop` 和 `start` 的组合。
    - `s-singbox service status`: 检查 `sing-box` 进程是否存在及其运行状态。
    - `s-singbox service log`: 实时输出 `sing-box` 的日志（tail a log file or stream stdout）。

---

## 4. 优化建议 (相比 `s-xray` 的可改进点)

1.  **原子化操作与备份**:
    - **建议**: 在任何修改 `nodes.json` 或 `config.json` 的操作前，先创建一个备份文件（如 `nodes.json.bak`）。操作成功后再删除备份。这可以防止因意外中断（如 Ctrl+C）导致配置文件损坏。

2.  **更强的配置校验**:
    - **建议**: 在 `node add` 时，不仅仅是接收 JSON，而是尝试根据 `sing-box` 的 schema 对其进行结构校验。这可以提前发现节点格式错误，而不是等到 `sing-box service start` 时才失败。

3.  **状态管理**:
    - **建议**: 引入一个状态文件（如 `.s-singbox.state`），用于记录 `sing-box` 进程的 PID。这样 `stop` 和 `status` 命令可以更精确地管理进程，而不是通过进程名匹配，避免误操作。

4.  **模块化节点协议**:
    - **建议**: 可以为不同的协议（VLESS, Trojan, Shadowsocks...）创建独立的转换逻辑模块。当用户提供一个简化的节点信息时（例如，一个分享链接），工具可以自动将其转换为 `sing-box` 所需的完整 JSON 格式，提高易用性。

---

## 5. 开发路线图

**Phase 1: 核心框架搭建**
1.  [ ] 初始化项目结构，确定编程语言（推荐 Go 或 Rust）。
2.  [ ] 实现 `s-singbox.json` 的读取和解析。
3.  [ ] 实现数据管理层，完成对 `nodes.json` 的 CRUD 基础操作。
4.  [ ] 实现 `s-singbox node ls` 和 `s-singbox node rm`。

**Phase 2: 核心功能实现**
1.  [ ] 实现配置生成模块 (`generate`)。
2.  [ ] 实现 `s-singbox node add`，并集成 `generate` 的自动调用。
3.  [ ] 实现服务控制模块，完成 `start`, `stop`, `status` 命令。

**Phase 3: 完善与优化**
1.  [ ] 实现 `service log` 功能。
2.  [ ] 加入上述“优化建议”中的原子化操作和 PID 文件管理。
3.  [ ] (可选) 实现订阅管理模块。
4.  [ ] 编写详细的用户文档和命令行帮助信息。
