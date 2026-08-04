# S-Singbox

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![sing-box](https://img.shields.io/badge/sing--box-compatible-orange.svg)](https://sing-box.sagernet.org/)
[![Version](https://img.shields.io/badge/version-V1.1.1-brightgreen.svg)](https://github.com/sindricn/s-singbox)

基于 sing-box 的开源代理服务管理脚本，提供完整的协议支持和用户管理能力。

## 🎯 核心特性

**一键搭建、校验并管理适配 sing-box 官方稳定版的代理节点。**

> TLS 必选协议（Trojan、Hysteria2、TUIC、Naive、AnyTLS）必须提供有效证书，或由脚本生成自签名证书。

### 📡 协议支持

**入站协议**（13种）：
- **VLESS** - 轻量级高性能协议（支持 Reality/TLS/TCP/WS/gRPC/HTTP）
- **VMess** - V2Ray 经典协议（支持 TLS、TCP/WS/gRPC/HTTP；不再提供 sing-box 不支持的 mKCP）
- **Trojan** - TLS 伪装协议（支持连接回落）
- **Shadowsocks** - 默认使用 Shadowsocks 2022 多用户结构与独立主密钥
- **Hysteria2** - 基于 QUIC 的高性能协议（支持混淆、带宽限制和 UDP 端口跳跃；快速搭建默认关闭跳跃，避免云安全组未放行时节点不可用）
- **TUIC** - QUIC 优化协议
- **Naive** - 强抗审查代理
- **AnyTLS** - 流量填充混淆（sing-box 1.12.0+）
- **HTTP** - HTTP 代理
- **SOCKS** - SOCKS5 代理
- **Mixed** - HTTP + SOCKS5 混合代理
- **Hysteria v1** - QUIC 高性能经典协议
- **ShadowTLS v3** - TLS 流量伪装协议

> Snell 入站仅存在于 sing-box 1.14 测试版本，未纳入当前稳定版节点菜单；Snell v4/v6 出站仍按稳定内核能力保留。

**默认内核出站协议与策略**（19 类）：HTTP、SOCKS、VLESS、VMess、Trojan、Shadowsocks、Hysteria v1、Hysteria2、TUIC、AnyTLS、ShadowTLS、SSH、Snell v4/v6、Tor、WireGuard Endpoint、Selector、URLTest、Direct、Block

> Naive 入站可正常使用。Naive 出站依赖上游独立 Chromium/Cronet 工具链和 `libcronet.so`，不属于官方本地构建标签集合；仅在外部内核包含 `with_naive_outbound` 时开放。

WireGuard 按 sing-box 1.11+ 的新结构保存到顶层 `endpoints`，Selector/URLTest 会自动解析并带入依赖出站。Bridge 仅适用于 L3/TUN 转发，不适合作为当前 L4 节点的普通链式出站；旧 DNS outbound 已废弃，因此不在菜单中提供。

**传输协议**：TCP、WebSocket、gRPC、HTTP/2、QUIC

**加密层**：TLS、Reality、自签名证书

### 🔐 用户管理

- 全局用户系统，支持多用户共享节点
- 流量限制和到期时间设置
- 灵活的用户-节点绑定关系
- 实时显示当前在线用户、节点在线用户数和活动连接数
- Clash API 仅监听本机，并使用随机密钥保护连接数据
- V2Ray Stats API 用户流量统计
- 使用持久化累计账本，内核重启后流量不会归零
- systemd 定时器每分钟检查流量额度与有效期，超限用户自动停用

### 🔗 订阅管理

- **订阅格式**：Base64、Clash、SingBox
- **自动生成**：支持按用户生成专属订阅链接
- **批量更新**：一键更新所有用户订阅
- **元数据管理**：订阅有效期、流量限制
- **自动选择**：Clash 与 SingBox 订阅内置 URLTest 自动测速组，并保留手动节点和直连选择
- **证书策略**：仅自签名节点生成 `insecure/skip-cert-verify`，受信任证书保持严格校验
- **连接地址策略**：需要 TLS 域名时优先检测已配置的服务器域名，展示 DNS 核对结果并由用户确认；TLS/SNI 域名与客户端实际连接地址分开保存，避免把伪装域名误当成服务器地址

### 🧩 默认内核与安全更新

- 默认下载 GitHub Actions 预编译并经 SHA256 校验的项目内核，节点创建过程不会临时触发编译
- 提供 AMD64、ARM64、ARMv7 和 ARMv6 构建；没有匹配产物时才询问是否本地编译
- CI 每 6 小时检查官方最新稳定版；仅在版本变化时构建，回归测试成功后才更新项目稳定内核清单，服务器无需随版本修改脚本
- Clash API 连接数据增加认证用户字段，用于实时在线用户与节点连接统计
- 内核或实时 API 暂不可用时显示“数据不可用”，不会错误显示为 `0`
- 发布流水线从官方 `SagerNet/sing-box` 对应版本标签构建
- 按官方 `release/local/common.sh` 使用 `release/DEFAULT_BUILD_TAGS_OTHERS` 和 `release/LDFLAGS`
- 额外启用 `with_v2ray_api`，供用户流量统计使用
- 仅在明确选择本地编译时读取目标版本 `go.mod` 的 Go/toolchain 要求并准备工具链
- 更新前校验候选内核版本、能力和现有配置；启动失败自动回滚二进制
- 配置生成采用文件锁、临时文件、`sing-box check` 和原子替换
- 节点、用户、绑定、出站、订阅和配置使用最后可用快照；服务健康检查成功后才提交事务，异常退出会在下次启动自动恢复
- 节点创建后会检查实际 TCP/UDP 监听，并自动同步 UFW、firewalld 或 iptables 规则；监听或本机防火墙激活失败时自动回滚
- 云厂商安全组无法由脚本代管，创建成功后会明确列出需要放行的 TCP、UDP 端口及 Hysteria2 UDP 跳跃范围

### 🌐 高级功能

#### Cloudflare 隧道
- **Argo 临时隧道** - 无需 CF 账号，快速隐藏真实 IP
- **Argo 专用隧道** - 固定域名，支持自定义
- **WARP 隧道** - 作为出站，解锁 CF 优选 IP
- **隧道-节点绑定** - 自动管理隧道与节点关联

#### BBR 网络加速
- **一键安装** - 自动检测系统并安装最新 BBR
- **多版本支持** - BBRv1、BBRv2、BBR Plus、BBR Brutal
- **效果测试** - 延迟、丢包率、吞吐量对比测试
- **智能优化** - 自动优化网络参数


## 🚀 快速开始

### 一键安装

**稳定版**（main）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)
```

**开发验证版**（dev）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/dev/install.sh) dev
```

也可以通过环境变量明确指定分支：

```bash
S_SINGBOX_BRANCH=dev bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/dev/install.sh)
```

使用 wget 安装稳定版：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)
```

### 快捷命令

```bash
# 使用全局命令（推荐）
s-singbox

# 或使用别名
singbox-manager
```


### 系统要求

- **操作系统**:
  - Ubuntu 18.04+ / Debian 10+
  - CentOS 7+ / RHEL 7+
  - Arch Linux
  - 其他主流 Linux 发行版

- **系统架构**:
  - x86_64 (AMD64)
  - ARM64 (aarch64)
  - ARMv7
  - ARMv6

- **权限要求**: root 或 sudo 权限

- **软件依赖**:
  - curl 或 wget
  - tar / unzip
  - jq (JSON 处理)
  - git、openssl、ca-certificates
  - gzip、coreutils（SHA256 校验）、util-linux（文件锁）
  - systemctl (systemd)

正常安装直接使用预编译内核，无需 Go 工具链；仅在明确选择本地源码编译时自动检查和准备 Go。

### 标准路径

- 管理器：`/opt/s-singbox`
- sing-box 配置：`/etc/sing-box/config.json`
- 用户、节点、订阅和流量账本：`/var/lib/sing-box`
- 二进制：优先使用环境变量 `SINGBOX_BIN` 或 `command -v sing-box`

### 验证

在 Linux 上执行：

```bash
bash scripts/validate_all.sh
```

验证项包括 Bash 语法、废弃字段/旧路径扫描、入站协议配置矩阵、出站/策略结构、WireGuard Endpoint、Selector/URLTest 依赖闭包、旧 Xray 出站迁移、绑定调用链、首次安装顺序、IPv6/隧道 URL、服务器域名与连接地址选择、TCP/UDP 实际监听、本机防火墙与端口跳跃范围、分享链接特殊字符、Clash/SingBox 协议字段、实时连接 API、V2Ray Stats API，以及项目默认内核的 `sing-box check`。


## 🤝 贡献指南

欢迎提交 Pull Request！贡献前请：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📜 更新日志

### V1.1.1 (2026-08-04)

本次版本重点完善实时连接监控和 sing-box 内核自动更新能力。

- 新增实时在线用户、节点在线用户及活动连接统计
- 默认下载 AMD64、ARM64、ARMv7、ARMv6 预编译内核，避免服务器现场长时间编译
- 自动跟踪官方最新稳定版，构建与回归测试通过后滚动发布
- 增强内核清单、SHA256 校验、版本检查、服务启动及失败回滚
- 监控能力与节点创建解耦，数据不可用时不再错误显示为 `0`
- 完善用户流量持久化累计、定时采集和超限自动停用逻辑
- 修复内核安装路径与 systemd 实际执行路径不一致的问题

### V1.1.0 (2026-07-31)

本次版本全面适配 sing-box 1.13.15 稳定版，重点提升节点可用性、订阅兼容性和管理稳定性。

- 完善 13 种入站协议及常用出站协议支持
- 修复 VLESS Reality、TUIC 等节点连接问题
- Clash 与 sing-box 订阅新增自动测速选择
- 流量统计改为可选增强功能，不再影响节点创建
- 完善服务器域名、节点连接地址和 Cloudflare 隧道逻辑
- 增强配置检查、服务健康检查及失败自动回滚
- 完善定制内核构建、进度提示和异常处理

**已知问题：**

- 用户在线状态和流量累计统计暂时不可用，将在后续版本修复。

### V1.0.0 (2025-11-25)

**新增功能**：
- ✨ 完整的 sing-box 管理界面
- ✨ 11种入站协议支持
- ✨ Cloudflare 隧道集成（Argo + WARP）
- ✨ BBR 网络加速管理
- ✨ Reality 伪装域名优选
- ✨ 全局用户管理系统
- ✨ 多格式订阅支持

**优化改进**：
- 🎨 统一的菜单导航系统
- 🚀 一键快速搭建向导
- 🛡️ 自动化防火墙配置
- 📊 实时流量监控

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## ⚠️ 免责声明

**重要提示**：

- 本工具仅供学习和研究使用
- 使用者需遵守当地法律法规
- 开发者不对使用本工具产生的任何后果负责
- 请勿用于非法用途

## 🙏 致谢

感谢以下项目：

- [sing-box](https://github.com/SagerNet/sing-box) - 核心代理内核
- [acme.sh](https://github.com/acmesh-official/acme.sh) - 证书管理
- [cloudflared](https://github.com/cloudflare/cloudflared) - CF 隧道支持
- [bbr](https://github.com/google/bbr)-谷歌原生BBR

---

<div align="center">

**Made with ❤️ by [sindricn](https://github.com/sindricn)**

如果觉得项目有帮助，请给个 ⭐ Star！

[报告问题](https://github.com/sindricn/s-singbox/issues) · [功能建议](https://github.com/sindricn/s-singbox/discussions) · [贡献代码](https://github.com/sindricn/s-singbox/pulls)

</div>
