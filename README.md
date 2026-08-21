# xray-reality-starter

## 项目简介 / Introduction

**中文：** 一个安全优先、可审计的 Xray 一键部署与管理脚本，用于在 Debian/Ubuntu 上部署单用户 VLESS + TCP + XTLS Vision + REALITY。它默认采用随机凭据、固定上游版本、安装器校验、配置备份、失败回滚和 BBR + fq，不默认安装 WARP，也不自动修改防火墙。

**English:** A safety-focused, auditable Xray deployment and management script for running single-user VLESS + TCP + XTLS Vision + REALITY on Debian/Ubuntu. It uses random credentials, pinned upstream versions, installer checksum verification, configuration backups, automatic rollback, and BBR + fq by default. It does not install WARP or modify firewall rules automatically.

部署协议栈 / Protocol stack：

```text
VLESS + TCP + XTLS Vision + REALITY
```

当前第一版支持 Debian/Ubuntu 与 systemd。它不是代理内核；底层使用官方 Xray-core。

The first release supports Debian/Ubuntu systems running systemd. This project is not a proxy core; it deploys the official Xray-core.

## 特点

- 固定 Xray 版本，不静默追踪最新版。
- Xray 官方安装器固定到 Git commit，并验证 SHA-256。
- UUID、X25519 密钥和 Short ID 分别随机生成。
- 不把 UUID、主机名或密钥材料发送给第三方生成服务。
- 覆盖 Xray 配置前自动备份。
- 写入配置前运行 `xray run -test`。
- 启动失败时自动恢复旧配置。
- 默认启用 BBR + fq，并写入独立的开机持久化配置；可通过 `--disable-bbr` 关闭。
- 不自动修改防火墙，也不自动安装 WARP。

## 快速开始

在测试 VPS 上下载并检查脚本：

```bash
curl -fLO https://example.com/xray-reality.sh
less xray-reality.sh
chmod +x xray-reality.sh
sudo ./xray-reality.sh install
```

非交互部署：

```bash
sudo ./xray-reality.sh install \
  --port 443 \
  --sni www.bing.com \
  --yes
```

交互安装未通过 `--sni` 或 `SNI` 指定目标时，会提示输入 REALITY SNI；直接回车使用默认值 `www.bing.com`。非交互安装添加 `--yes` 后同样使用该默认值。

安装默认加载 BBR 并将队列算法设为 `fq`。如果内核不提供 `tcp_bbr` 模块，脚本会给出警告并继续安装 Xray；如需明确关闭，可添加 `--disable-bbr` 或设置 `ENABLE_BBR=0`。

Interactive installs prompt for a REALITY SNI unless `--sni` or the `SNI` environment variable is provided. Press Enter to accept the `www.bing.com` default; unattended installs with `--yes` use the same default.

IPv6-only VPS 可以明确指定：

```bash
sudo ./xray-reality.sh install \
  --address 2001:db8::10 \
  --listen :: \
  --yes
```

请把示例地址换成服务器的真实公网 IPv6。

## 管理命令

安装成功后，脚本会复制为 `/usr/local/sbin/xray-reality`：

```bash
xray-reality show
xray-reality status
xray-reality update --version v26.3.27
xray-reality uninstall
```

主要文件：

```text
/usr/local/etc/xray/config.json
/usr/local/etc/xray-reality/state.json
/usr/local/etc/xray-reality/backups/
/usr/local/sbin/xray-reality
```

## 参数

```text
--port PORT          服务端端口，默认 443
--sni DOMAIN         REALITY 目标，默认 www.bing.com
--address ADDRESS    客户端连接地址，默认自动探测
--listen ADDRESS     Xray 监听地址
--uuid UUID          使用指定 UUID；默认随机生成
--version VERSION    固定 Xray 版本
--fingerprint NAME   客户端指纹，默认 chrome
--enable-bbr         启用 BBR + fq（默认，兼容参数）
--disable-bbr        不启用 BBR
--yes                非交互确认
```

也可以使用 `PORT`、`SNI`、`ADDRESS`、`LISTEN`、`UUID`、`XRAY_VERSION`、`FINGERPRINT`、`ENABLE_BBR` 环境变量；`ENABLE_BBR` 只能是 `1` 或 `0`。

## 已验证环境 / Tested environment

2026-08-21 在全新 Oracle Cloud Ubuntu 24.04.4 LTS、systemd、x86_64 环境完成了以下测试：

- 全新安装和 Xray 配置校验。
- systemd 启动、启用及 TCP 443 外部连通性。
- Windows Xray 客户端通过 REALITY 节点访问公网，出口地址与 VPS 一致。
- 同版本 `update`、`show`、`help` 管理命令。
- Oracle Ubuntu 默认 iptables 规则下手动放行并持久化 TCP 443。
- BBR + fq 运行时切换及开机持久化配置。

Tested on a fresh Oracle Cloud Ubuntu 24.04.4 LTS x86_64 instance with systemd. Installation, configuration validation, service startup, external TCP connectivity, end-to-end REALITY proxying, same-version updates, and management commands passed.

尚未完成 Debian 12 和完整卸载后重装测试。

Debian 12 and a full uninstall/reinstall cycle have not been tested yet.

## 发布前必须做的事

1. 在全新的 Debian 12 上测试，并完成一次卸载后重装测试。
2. 确认 TCP 入站端口已通过云防火墙和本机防火墙放行。
3. 检查选择的 SNI 目标支持 TLS 1.3，并可从服务器直连。
4. 给仓库打 Git tag，让用户下载固定版本而不是 `main`。
5. 发布脚本自身的 SHA-256，并在 README 中记录。
6. 更新 Xray 或官方安装器提交时，重新完成安装、更新和回滚测试。

## 安全边界

- 脚本需要 root 权限，因此运行前必须审查源码。
- 安装器虽然固定提交并校验，但 Xray 安装器还会从 GitHub Releases 下载 Xray；部署环境需要信任 GitHub 和 XTLS 发布流程。
- `state.json` 权限为 `0600`，不保存 REALITY 私钥；私钥位于 Xray 服务配置中。
- Xray 配置按服务用户的主组设置为 `0640`。
- 卸载前会把状态目录及配置备份保存到 root 用户目录，再删除运行中的项目文件。
- 请遵守服务器所在地及使用所在地的法律和服务商条款。

## 开发检查

```bash
bash -n xray-reality.sh
shellcheck xray-reality.sh
```

仓库提供了 `ci/lint.yml.example`。启用 GitHub Actions 时，将它复制到工作流目录后提交：

```bash
mkdir -p .github/workflows
cp ci/lint.yml.example .github/workflows/lint.yml
git add -- .github/workflows/lint.yml
git commit -m "ci: enable ShellCheck workflow"
git push
```

提交工作流文件的 GitHub CLI/OAuth 令牌需要 `workflow` 权限。

## 上游项目

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)

## License

MIT
