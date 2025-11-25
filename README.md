# S-Singbox

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![sing-box](https://img.shields.io/badge/sing--box-compatible-orange.svg)](https://sing-box.sagernet.org/)
[![Version](https://img.shields.io/badge/version-V1.0.0-brightgreen.svg)](https://github.com/sindricn/s-singbox)

基于 sing-box 的开源代理服务管理脚本，提供完整的协议支持和用户管理能力。

## 🎯 核心特性

**"一键搭建高性能代理节点，无需域名和证书"**

### 📡 协议支持

**入站协议**（11种）：
- **VLESS** - 轻量级高性能协议（支持 Reality/TLS/TCP/WS）
- **VMess** - V2Ray 经典协议
- **Trojan** - TLS 伪装协议
- **Shadowsocks** - 经典代理协议
- **Hysteria2** - 基于 QUIC 的高性能协议
- **TUIC** - QUIC 优化协议
- **Naive** - 强抗审查代理
- **AnyTLS** - 流量填充混淆（sing-box 1.12.0+）
- **HTTP** - HTTP 代理
- **SOCKS** - SOCKS5 代理
- **Mixed** - HTTP + SOCKS5 混合代理

**出站协议**：支持所有主流协议出站配置，实现代理链和分流功能

**传输协议**：TCP、WebSocket、gRPC、HTTP/2、QUIC

**加密层**：TLS、Reality、自签名证书

### 🔐 用户管理

- 全局用户系统，支持多用户共享节点
- 流量限制和到期时间设置
- 灵活的用户-节点绑定关系
- 实时流量统计和连接监控

### 🔗 订阅管理

- **订阅格式**：Base64、Clash、SingBox
- **自动生成**：支持按用户生成专属订阅链接
- **批量更新**：一键更新所有用户订阅
- **元数据管理**：订阅有效期、流量限制

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

**推荐安装方式**（使用 curl）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)
```

或使用 wget：

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

- **权限要求**: root 或 sudo 权限

- **软件依赖**:
  - curl 或 wget
  - tar / unzip
  - jq (JSON 处理)
  - systemctl (systemd)


## 🤝 贡献指南

欢迎提交 Pull Request！贡献前请：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📜 更新日志

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
