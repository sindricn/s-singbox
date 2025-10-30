# s-singbox

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![sing-box](https://img.shields.io/badge/sing--box-compatible-orange.svg)](https://sing-box.sagernet.org/)

基于 sing-box 的代理服务管理工具 - 命令行界面，简单易用

## ✨ 功能特性

### 协议支持

支持 8 种主流代理协议：

- **Shadowsocks** - 经典代理协议
- **Trojan** - TLS 伪装协议
- **Hysteria2** - 基于 QUIC 的高性能协议
- **TUIC** - UDP 优化协议
- **Naive** - 基于 Chromium 的抗检测协议
- **VMess** - V2Ray 经典协议
- **VLESS** - 轻量级高性能协议
- **ShadowTLS** - TLS 流量伪装

### 核心功能

- 🔐 **用户管理** - 多用户支持，流量限制，到期时间管理
- 🌐 **节点管理** - 添加/删除/修改节点，支持多种协议
- 🔗 **用户绑定** - 灵活的用户-节点绑定关系
- 🔒 **证书管理** - 自动申请和续期 SSL/TLS 证书（acme.sh）
- 🌍 **域名管理** - 域名配置和证书关联
- 📡 **订阅管理** - 从订阅链接导入节点
- 📊 **流量监控** - 实时流量统计和用户监控
- 🔥 **防火墙管理** - 自动配置防火墙规则
- ⚙️ **出站规则** - 路由规则和分流管理
- 🔧 **配置管理** - 自动生成和验证配置文件

## 🚀 快速开始

### 一键安装

**方式一：直接安装（推荐）**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)
```

或使用 wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)
```

**方式二：克隆后安装**

```bash
# 克隆仓库
git clone https://github.com/sindricn/s-singbox.git
cd s-singbox

# 运行安装脚本
sudo bash install.sh
```

安装脚本会自动完成：
- 安装系统依赖（curl, wget, tar, jq）
- 下载并安装 sing-box 内核
- 配置 systemd 服务
- 初始化数据文件

### 系统要求

- **操作系统**: Linux (Ubuntu 20.04+, Debian 10+, CentOS 8+, Arch Linux)
- **权限**: root 或 sudo
- **依赖**: curl, wget, tar, jq, systemctl

## 📖 使用方法

### 启动管理工具

```bash
# 使用命令
singbox-manager

# 或直接运行脚本
./singbox-manager.sh
```

### 基本操作流程

#### 1. 添加节点

进入管理工具主菜单：

```
主菜单 -> 节点管理 -> 添加节点
```

根据提示选择协议类型并配置参数：
- 端口号
- 传输协议
- 加密方式
- TLS 配置（如需要）

#### 2. 添加用户

```
主菜单 -> 用户管理 -> 添加用户
```

配置用户信息：
- 用户名
- 邮箱
- 流量限制（可选）
- 到期时间（可选）

#### 3. 绑定用户到节点

```
主菜单 -> 绑定管理 -> 绑定用户
```

选择用户和节点进行绑定，用户只能使用已绑定的节点。

#### 4. 生成配置并启动服务

```
主菜单 -> 配置管理 -> 生成配置
主菜单 -> 服务控制 -> 启动服务
```

配置会自动生成并验证，然后启动 sing-box 服务。

### 证书管理

#### 申请证书

```
主菜单 -> 证书管理 -> 申请证书
```

支持两种验证方式：
- **HTTP-01** - 适用于单域名，需要开放 80 端口
- **DNS API** - 适用于通配符域名，支持 Cloudflare、阿里云等

#### 自动续期

证书会自动检测并续期，无需手动操作。

### 订阅管理

#### 添加订阅

```
主菜单 -> 订阅管理 -> 添加订阅
```

输入订阅链接，系统会自动：
- 拉取订阅内容
- 解析节点信息
- 添加到节点列表

#### 更新订阅

```
主菜单 -> 订阅管理 -> 更新订阅
```

重新拉取订阅并更新节点配置。

### 流量监控

```
主菜单 -> 监控统计 -> 查看流量统计
```

查看：
- 用户流量使用情况
- 节点流量统计
- 在线用户列表

### 配置备份与恢复

#### 创建备份

```bash
./scripts/backup.sh create
```

#### 恢复备份

```bash
./scripts/backup.sh restore
```

### 系统诊断

```bash
./scripts/diagnose.sh
```

检查：
- 系统环境和依赖
- sing-box 安装状态
- 配置文件有效性
- 服务运行状态
- 网络和防火墙

## 🛠️ 常用命令

### 服务管理

```bash
# 启动服务
systemctl start sing-box

# 停止服务
systemctl stop sing-box

# 重启服务
systemctl restart sing-box

# 查看状态
systemctl status sing-box

# 查看日志
journalctl -u sing-box -f
```

### 配置验证

```bash
# 验证配置文件
sing-box check -c /usr/local/singbox/config.json
```

### 防火墙管理

```bash
# Ubuntu/Debian (UFW)
ufw allow 端口号/tcp
ufw allow 端口号/udp

# CentOS/RHEL (firewalld)
firewall-cmd --permanent --add-port=端口号/tcp
firewall-cmd --permanent --add-port=端口号/udp
firewall-cmd --reload
```

## 🐛 故障排除

### 服务无法启动

```bash
# 1. 检查配置文件
sing-box check -c /usr/local/singbox/config.json

# 2. 查看详细日志
journalctl -u sing-box -n 50 --no-pager

# 3. 运行诊断脚本
./scripts/diagnose.sh
```

### 端口被占用

```bash
# 查看端口占用
ss -tuln | grep :端口号

# 或
netstat -tuln | grep :端口号
```

### 证书问题

- 确保域名解析正确指向服务器
- 检查 80 端口是否开放（HTTP-01 验证）
- 查看 acme.sh 日志：`~/.acme.sh/acme.sh.log`

### 配置文件损坏

```bash
# 恢复最近的备份
./scripts/backup.sh restore
```

## 🗑️ 卸载

```bash
sudo bash uninstall.sh
```

卸载过程会询问是否保留配置和数据文件。

## 📚 更多资源

- **sing-box 官方文档**: https://sing-box.sagernet.org/
- **项目 Issues**: https://github.com/sindricn/s-singbox/issues
- **项目 Discussions**: https://github.com/sindricn/s-singbox/discussions

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

## ⚠️ 免责声明

本工具仅供学习和研究使用。使用者需遵守当地法律法规，开发者不对使用本工具产生的任何后果负责。

---

<div align="center">

Made with ❤️ by [sindricn](https://github.com/sindricn)

</div>
