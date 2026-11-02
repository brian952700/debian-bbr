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
| 1 | 启用 BBR + fq（不再覆盖缓冲区，交给自适应调优） |
| 2 | 先检测服务器与连接 RTT，再预览自适应 TCP 配置，确认后应用 |
| 3 | 通过当前 Debian 软件源更新内核，安装前确认 |
| 4 | 清理旧内核，保留当前运行内核和按版本排序最新的两个内核包，删除前确认 |
| 5 | 查看内核、BBR、队列和配置状态 |
| 0 | 退出 |

## 调优前的检测（v3.1）

主要面向直连 VLESS + WS + TLS / VLESS + XHTTP + TLS。建议先让中国联通、移动或电信客户端连接节点并持续传输，再选菜单 2。

1. 输入公网 TCP/TLS 端口（默认 443），选择直连或 CDN/不确定。
2. 读取内存及可读的 cgroup 内存限制、CPU、默认出口、网卡计数和实际 qdisc。虚拟网卡速率仅显示，不用于猜测可用带宽。
3. 用 ss 读取指定入站端口的一次已建立连接快照，排除回环，显示可用 TCP 平滑 RTT 样本数、中位数及 P75。不会上传或写入报告中的客户端 IP。
4. 输入预计分配给单条代理连接的 Mbps 带宽；不知道可留空。直连且至少有 5 个 RTT 样本才自动参考 P75，也可输入国内客户端测得的 TCP RTT。CDN 场景不把客户端 RTT 当成回源 RTT。
5. 预览完整配置，输入 y 才备份并应用；回车默认取消。诊断不运行公网测速，不扫描第三方节点，也不读取 Xray 配置、UUID、证书或访问日志。

这不是“三网自动最优”：脚本不按运营商识别客户端，一次快照也不能代表晚高峰、未来负载或端到端吞吐。共享带宽和路由瓶颈无法从虚拟网卡速率推断。XHTTP 可使用 H3/QUIC，此时 TCP 参数不直接控制 UDP 传输；脚本不更改应用配置、路由、实际网卡队列或自动重启服务。

## 缓冲区选择方法

以下是可审查的工程启发式，未声称属于 BBR 官方调优公式。目标约为 2 倍带宽时延积，向上选档，并受到内存余量限制。未知带宽或未知 RTT 时不主动升档。

| 有效总内存与当前可用内存 | 上限封顶 |
| --- | --- |
| 总内存不足 512 MiB，或可用不足 128 MiB，或无法识别 | 8 MiB |
| 总内存 ≥512 MiB，且可用 ≥128 MiB | 16 MiB |
| 总内存 ≥1 GiB，且可用 ≥256 MiB | 32 MiB |
| 总内存 ≥2 GiB，且可用 ≥512 MiB | 64 MiB |
| 总内存 ≥4 GiB，且可用 ≥1 GiB | 128 MiB |

默认基线为 32 MiB，内存不足时降低；有带宽和 RTT 才按估算向上选档。上限不是预分配量；高并发仍可能增加内存压力，需观察实际吞吐、延迟和内存。未读取到容器/父 cgroup 限制时，内存估计可能偏大，用户应核对诊断结果。

保留接收缓冲区自动调节、SACK、时间戳、窗口扩展、SYN cookies 和空闲后不重启慢启动；启用黑洞触发的 MTU 探测，恢复连接路径度量缓存。移除旧版对 TIME_WAIT、SYN 重试、conntrack、端口范围及文件描述符的固定覆盖。没有改变 BBR 内部增益。

## 配置、备份和恢复

- 仅支持 Debian 12+，更新内核使用当前软件源，不升级发行版大版本，不更换软件源。
- 菜单 1 管理 /etc/sysctl.d/99-bbr.conf；菜单 2 管理 /etc/sysctl.d/99-tcp-tune.conf。
- 菜单 2 应用前保存旧文件、本次涉及参数的当前运行值 runtime-before.conf，以及不含客户端地址的 report.txt，目录为 /var/backups/debian-bbr-tune.XXXXXXXX/，终端会显示真实路径。
- 恢复本次运行值：sysctl -p /var/backups/debian-bbr-tune.实际目录/runtime-before.conf。再将备份的 99-tcp-tune.conf 复制回 /etc/sysctl.d/；若有 no-previous-tcp-config 标记，则原先没有该配置文件，应移除本次新增文件。请使用终端显示的真实目录。
- 从 v3.0 升级：旧版已生效但新版不再覆盖的运行值不会自动复原；旧版 limits.conf 追加也不会自动删除。需使用此前备份恢复，或整理持久配置后重启并核对。系统其他 sysctl 文件也可能覆盖这些值。
- 部分参数可能被容器宿主机限制。脚本逐项报告失败，配置文件存在不等于全部生效。
- 内核清理保留当前运行内核和最新两个内核包，不执行 autoremove。内核更新后自行安排重启。

## 验证

GitHub Actions 在 Debian 12、13 容器中执行 Bash 语法检查和无真实 sysctl/apt 写入的测试，覆盖版本限制、参数应用错误、内核保留、自适应内存/BDP 边界、IPv4/IPv6 RTT 解析、回环排除、无样本和取消流程。没有真实 VPS 或三网性能实测，未来 Debian 版本仍需验证。

```bash
bash -n bbr.sh
bash tests/smoke.sh
```

参考：[Linux 内核 TCP 参数](https://docs.kernel.org/networking/ip-sysctl.html)、[Xray XHTTP 说明](https://github.com/XTLS/Xray-core/discussions/4113)。
