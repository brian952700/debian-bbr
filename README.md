# Debian BBR + TCP 调优

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
| 1 | 启用 BBR + fq，并保存基础 TCP 配置 |
| 2 | 可选 TCP 深度调优，写入前确认 |
| 3 | 通过当前 Debian 软件源更新内核，安装前确认 |
| 4 | 清理旧内核，保留当前运行内核和按版本排序最新的两个内核包，删除前确认 |
| 5 | 查看内核、BBR、队列和配置状态 |
| 0 | 退出 |

## 修改范围与注意事项

- 移除其他发行版的分支、软件源修复、第三方内核源、GRUB 修改和自动重启入口。
- 启动时先验证系统及版本，再检查依赖；不更换已有软件源。更新内核不会升级 Debian 大版本。
- 保留 BBR 和可选 TCP 调优功能。移除原脚本不按机器内存计算的 `tcp_mem` 固定值。
- 覆盖已有配置前，备份至 `/var/backups/debian-bbr.XXXXXXXX/`，终端会输出具体目录。
- 修改 `/etc/sysctl.d/99-bbr.conf`、`/etc/sysctl.d/99-tcp-tune.conf`，深度调优还会追加 `/etc/security/limits.conf`。
- sysctl 参数逐项应用并显示失败；容器宿主机可能限制 BBR 和相关参数，配置文件存在不代表全部生效。
- 文件描述符的登录限制需重新登录；systemd 服务还可能有单独的 `LimitNOFILE`。
- 内核清理不执行 `autoremove`。内核更新后，请自行安排重启，再检查运行中的内核和 BBR。
- 调优参数沿用原脚本，需按业务验证，不保证提速。未来 Debian 数字版本允许通过检查，但仍需在目标系统上验证。

## 检查

GitHub Actions 在 Debian 12 和 Debian 13 容器中执行 Bash 语法检查和无系统写入的测试，覆盖版本限制、sysctl 参数解析与错误报告、内核保留和取消删除。容器测试不代表真实 VPS 上的 BBR 或内核安装实测。

```bash
bash -n bbr.sh
bash tests/smoke.sh
```
