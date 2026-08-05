# S-Singbox

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![sing-box](https://img.shields.io/badge/sing--box-compatible-orange.svg)](https://sing-box.sagernet.org/)
[![Version](https://img.shields.io/badge/version-V1.1.2-brightgreen.svg)](https://github.com/sindricn/s-singbox)

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

**默认内核出站协议与策略**（19 类）：HTTP、SOCKS、VLESS、VMess、Trojan、Shadowsocks、Hysteria v1、Hysteria2、TUIC、AnyTLS、ShadowTLS、SSH、Snell v4/v6、Tor、WireGuard Endpoint、Selector、URLTest、Direct、Block


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

- 默认使用自动构建并校验的项目内核，跟随 sing-box 官方稳定版更新；更新异常时自动回滚，避免影响现有节点。

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




## 🤝 贡献指南

欢迎提交 Pull Request！贡献前请：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request


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
