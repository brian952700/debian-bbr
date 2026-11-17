# Debian BBR + 自适应 TCP 调优

仅支持 **Debian 12、13 及以上正式数字版本**，要求 Bash 和 root 权限。不接受 Ubuntu、CentOS、RHEL、Debian 11 或更早版本，也不把 Debian 衍生发行版当作 Debian。

基于用户提供的 VPS值得买 `bbr.sh` 修改，保留原作者署名及网站 https://vpszdm.com 。原文件未提供许可证，本仓库未另行添加许可证。

## 一键下载安装并打开菜单

在 Debian 的 root SSH 终端执行（先下载成功，再运行，交互输入保留给菜单）：

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fL --retry 3 https://raw.githubusercontent.com/brian952700/debian-bbr/main/bbr.sh -o /root/bbr.sh && bash /root/bbr.sh
```

已有 curl 和 CA 证书时：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/brian952700/debian-bbr/main/bbr.sh -o /root/bbr.sh && bash /root/bbr.sh
```

后续直接执行 `bash /root/bbr.sh`。不使用 `curl | bash`，因为脚本需要交互输入。

菜单：

| 选项 | 功能 |
| --- | --- |
| 1 | 启用并验证 BBR，尝试将默认队列设为 fq |
| 2 | 自动检测与适配，无参数填写或确认；无法判断的项目跳过 |
| 3 | 从当前 Debian 软件源更新已安装的同类型内核元包，安装前确认 |
| 4 | 确认运行内核和备用镜像后，预演并清理同系列旧内核，由 APT 显示实际删除计划并确认 |
| 5 | 刷新运行状态，查看实际网卡队列和 TCP 连接诊断 |
| 0 | 退出 |

## 终端界面

启动时显示 4 步真实检查；菜单按网络配置、内核维护和状态查看分组。青色表示信息，绿色表示完成，黄色表示跳过或提醒，红色表示失败。通过空行和缩进区分步骤、诊断摘要、结果及可复制的配置/备份路径，不使用虚假百分比或强制清屏。

交互终端自动启用颜色；重定向输出或 TERM=dumb 时使用纯文本。支持 NO_COLOR 环境变量关闭颜色。窄终端会缩短分隔线，避免用易错位的封闭框线和 Emoji 表格。TCP 自动适配仍然无需输入参数或确认。

菜单一次输出完整内容，普通返回使用最近一次状态。启用 BBR、TCP 自动适配和主动查看状态时刷新概览。

## TCP 自动适配

菜单 2 直接检查接收缓冲区自动调节。已开启或无法读取时跳过，关闭时尝试开启并验证。该流程无需填写参数或确认。

只读诊断集中在菜单 5：

- 自动读取可用内存、可读的 cgroup 内存限制、CPU、默认出口及实际队列。
- 自动读取全机已建立 TCP 连接的 RTT 快照并排除回环，只显示汇总；没有连接样本或检测失败时按未知处理。此统计包含其他服务和出站连接，不用于识别 VLESS、国内运营商或 CDN。
- RTT 诊断最多统计 512 个样本。连接详情读取超过 3 秒时跳过 RTT 摘要。具体缓冲区由内核在已有上限和内存管理机制内调整。
- 取消旧版带宽时延积估算和 8/16/32/64/128 MiB 档位。服务器无法可靠自动获知国内线路容量、目标带宽、业务端口和 CDN 拓扑，因此这些信息不再影响任何写入。
- 缓冲区上限、TIME_WAIT、SYN 重试、conntrack、端口范围、文件上限、MTU 策略及实际网卡队列等，本次全部保持现状。不能可靠适配的项目不会套用固定值。

如果内核自动调节已经开启，菜单 2 很可能提示“没有可调整项”，这表示跳过了无需或无法判断的修改，不代表检测失败或已经加速。此功能不改变 BBR 内部增益，也不承诺联通、移动、电信线路提速。XHTTP 若使用 H3/QUIC，其 UDP 传输不由此 TCP 参数控制。

## 配置与备份

菜单 1 管理 `/etc/sysctl.d/99-bbr.conf`。先备份，再应用并回读 BBR 与默认队列。验证通过的设置以原子替换方式保存。当 BBR 启用失败或文件保存失败时，脚本尝试恢复已修改的运行值。默认队列 `fq` 有单独结果，实际出口网卡队列见菜单 5。

菜单 2 管理 `/etc/sysctl.d/99-tcp-auto.conf`，同样先应用、回读再保存。两个菜单使用同一个锁，避免脚本的两个会话同时写配置。能读取 systemd 加载顺序时，脚本会提示可能覆盖设置的后加载规则。

终端显示备份的具体路径。BBR 使用 `/var/backups/debian-bbr.XXXXXXXX/`，目录内的 `99-bbr.conf` 是原持久文件。TCP 自动适配使用 `/var/backups/debian-bbr-auto.XXXXXXXX/`，目录内的 `previous.conf` 是原持久文件。两个目录均以 `runtime-before.conf` 保存原运行值，`no-previous-config` 表示原先没有持久文件。

恢复时先使用 sysctl -p 备份目录/runtime-before.conf，再将 previous.conf 复制回 /etc/sysctl.d/99-tcp-auto.conf；若有 no-previous-config 标记，应移除本次新增文件。请使用终端输出的真实备份目录。

**升级旧版：** v3.2 保留旧版 /etc/sysctl.d/99-tcp-tune.conf 和此前的 limits.conf 修改，不猜测并恢复未知原值；检测到旧文件会提示。若曾应用旧版调优，请用当时备份恢复不需要的设置。仅升级脚本不会自动撤销过去已应用的参数。

## 系统与验证

仅支持 Debian 12、13 及以上数字版本。内核维护只在可识别的独立内核环境执行。清理前保护当前运行内核与同系列备用镜像，并检查 APT 预演的全部操作。

GitHub Actions 在 Debian 12、13 容器中检查 Bash 语法、内核清理保护、启动与持久配置、TCP 自动跳过和菜单刷新。sysctl 写入和 apt 操作使用模拟命令。

```bash
bash -n bbr.sh
bash tests/smoke.sh
```

接收自动调节依据：[Linux 内核 TCP 参数文档](https://docs.kernel.org/networking/ip-sysctl.html)。
