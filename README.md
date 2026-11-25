# sekai Releases

**sekai** 是一个低占用、独立的 Fboard 节点实现。本仓库只发布编译好的二进制，**源码在私有仓库** [`Fearless743/sekai`](https://github.com/Fearless743/sekai)。

单文件 Rust 二进制，不内嵌 xray-core；以 machine 模式通过 WebSocket 对接 Fboard 面板，核心协议为 VLESS，支持 TCP / TLS / WebSocket / httpupgrade / gRPC / XHTTP / QUIC / KCP / REALITY 等传输。

## 一键安装

安装脚本自动识别平台和 init 系统，下载二进制、写入配置、创建服务并启动。要求 root（sudo）；Alpine 需先 `apk add bash curl`。

```bash
curl -fsSL https://raw.githubusercontent.com/Fearless743/sekai-release/main/install.sh \
  | sudo bash -s -- --panel https://panel.example.com --token TOKEN --machine-id 1 --license-key FBN-XXXXXXXX-XXXXXXXX
```

`--panel`、`--token`、`--machine-id` 必填。`--license-key` 首次安装必填；若本地已有 license 缓存（`/etc/sekai/data/license.cache`）或旧配置中已有 `license.key`，重装/调整配置时可省略，脚本会复用本地授权而不是生成无授权配置；本地也没有任何授权信息时脚本直接报错退出。

已安装后再执行 `install` 会把本次传入的面板**追加**到现有配置，不会覆盖已有面板；相同 `面板地址 + machine ID` 重复传入时只更新其 token，不会产生重复实例。配置中的其他自定义设置与凭证也会保留。

安装结果：
- 二进制：`/usr/local/bin/sekai`
- 配置：`/etc/sekai/config.yml`（权限 600）
- 凭证：`/etc/sekai/credentials.env`（token 单独存放，配置里用 `token_env: MACHINE_TOKEN` 引用）
- 服务：systemd 下为 `sekai.service`（`Restart=always`，开机自启）；Alpine/OpenRC 下为 `/etc/init.d/sekai`（`rc-update add sekai default`，失败 10s 后强杀）
- 服务状态检查：安装脚本在启动后等待服务进入 active 状态（不再依赖独立探活端口）

可选参数：

```bash
--version v0.1.0              # 指定版本（默认 latest）
--replace                     # install 时重建配置，覆盖现有面板（默认追加）
```

多面板：重复 `--panel` / `--token` / `--machine-id` 三组参数即可（数量必须一一对应，license 只需一份）。脚本会生成 `instances:` 配置，每个面板一个实例，token 分别存入 `/etc/sekai/credentials.env` 的 `SEKAI_TOKEN_0`、`SEKAI_TOKEN_1`……单面板时仍保持原有扁平配置格式：

```bash
curl -fsSL https://raw.githubusercontent.com/Fearless743/sekai-release/main/install.sh \
  | bash -s -- \
    --panel https://a.example.com --token TOKEN_A --machine-id 52 \
    --panel https://b.example.com --token TOKEN_B --machine-id 7 \
    --license-key FBN-XXXX-XXXX
```

已安装一个面板后再添加第二个面板，直接重跑 install（只传新面板即可，无需重复 `--license-key`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Fearless743/sekai-release/main/install.sh \
  | bash -s -- --panel https://c.example.com --token TOKEN_C --machine-id 8
```

如需彻底重建配置（丢弃旧面板及自定义项），加 `--replace`。

日志默认关闭：生成的配置里 `log.level: silent`（完全不输出）。需要日志时请手动编辑 `/etc/sekai/config.yml`，把该值改为 `info` / `debug` / `warn` / `error` 或 `off`，然后重启服务。

其他操作：

```bash
sudo bash install.sh upgrade                       # 升级二进制并重启
sudo bash install.sh status                        # 查看状态
sudo bash install.sh logs                          # 实时跟随日志（Ctrl+C 退出）
sudo bash install.sh uninstall --purge --yes       # 卸载（--purge 同时删除 /etc/sekai）
```

`logs` 在 systemd 下用 `journalctl -u sekai.service -f`，在 Alpine/OpenRC 下跟随 `/var/log/sekai.log` 与 `/var/log/sekai.err.log`。日志内容为静默时为空属正常现象。

支持平台：Linux x86_64 / aarch64，glibc（systemd）与 Alpine/musl（OpenRC）均自动识别并选用对应安装包。macOS 请用下方手动下载。

## 手动下载

从 [Releases](../../releases) 页面下载对应平台的压缩包，或使用下面的直链（始终指向最新版本）：

| 平台 | 文件 | 直链 |
|------|------|------|
| Linux x86_64 (glibc) | `sekai-x86_64-unknown-linux-gnu.tar.gz` | [下载](../../releases/latest/download/sekai-x86_64-unknown-linux-gnu.tar.gz) |
| Linux aarch64 (glibc) | `sekai-aarch64-unknown-linux-gnu.tar.gz` | [下载](../../releases/latest/download/sekai-aarch64-unknown-linux-gnu.tar.gz) |
| Linux x86_64 (musl / Alpine) | `sekai-x86_64-unknown-linux-musl.tar.gz` | [下载](../../releases/latest/download/sekai-x86_64-unknown-linux-musl.tar.gz) |
| Linux aarch64 (musl / Alpine) | `sekai-aarch64-unknown-linux-musl.tar.gz` | [下载](../../releases/latest/download/sekai-aarch64-unknown-linux-musl.tar.gz) |
| Windows x64 | `sekai-x86_64-pc-windows-msvc.zip` | [下载](../../releases/latest/download/sekai-x86_64-pc-windows-msvc.zip) |
| macOS aarch64 (Apple Silicon) | `sekai-aarch64-apple-darwin.tar.gz` | [下载](../../releases/latest/download/sekai-aarch64-apple-darwin.tar.gz) |

每个压缩包内只有一个可执行文件 `sekai`（Windows 为 `sekai.exe`）。

## 快速开始

```bash
# Linux x86_64 示例
curl -L -o sekai.tar.gz \
  https://github.com/Fearless743/sekai-release/releases/latest/download/sekai-x86_64-unknown-linux-gnu.tar.gz
tar xzf sekai.tar.gz
chmod +x sekai

# 准备配置文件（填写 panel.url / machine.machine_id / machine.token）
./sekai -c config.yml
```

也可通过环境变量提供凭证：`API_HOST` / `MACHINE_ID` / `MACHINE_TOKEN`，或在配置里用 `machine.token_env` 指定变量名。

## 功能

- **面板链路**：machine 模式 WebSocket，节点发现、配置/用户/设备同步、流量上报、op.ack
- **协议**：VLESS（TCP/UDP、addons、fallback、Vision），另有 Trojan / VMess / Shadowsocks / AnyTLS 等
- **传输**：raw TCP、TLS、WebSocket、httpupgrade、H2/gRPC/XHTTP、QUIC、KCP、REALITY
- **低占用**：空闲常驻内存约 3.7–4.0 MB；5 个节点约 4.5–5.4 MB（均经真实握手验证）
- **可裁剪**：`--no-default-features` 可关闭 QUIC/KCP/ECH/PQ/H2/REALITY，只保留核心 VLESS

完整特性与构建说明见源码仓库的 [README](https://github.com/Fearless743/sekai#readme)。

## 授权（License）

这是付费软件，节点运行需要有效的 license key。启动时向 Cloudflare Worker 验证服务器在线验证（Ed25519 签名、机器码绑定、协议白名单、到期时间）。公开二进制里**只有公钥**，无法伪造令牌。

- License 按服务器硬件指纹绑定：同一台服务器上的多个进程/面板只占 1 个设备额度
- 令牌有效期由 Worker 签名内的 `exp` 决定，本地缓存不可篡改绕过
- 本地已缓存有效令牌（或旧配置里保留了 key）时，安装脚本不再要求重复输入 license key；令牌到期后仍需凭 key 在线续期
- 详细授权机制见源码仓库 [docs/LICENSING.md](https://github.com/Fearless743/sekai/blob/main/docs/LICENSING.md)

购买与授权管理请联系项目方。
