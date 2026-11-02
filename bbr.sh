#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System  : Debian 12 / 13 and later
#   Desc    : BBR一键加速 + TCP深度调优
#   Version : 3.0.0-debian
#   Author  : VPS值得买
#   测评网站    : https://vpszdm.com
#=================================================

# ────────────────────────── 颜色定义 ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
CYAN='\033[0;96m'
BOLD='\033[1m'
PLAIN='\033[0m'

sh_ver="3.0.0-debian"

# ────────────────────────── 通用工具函数 ──────────────────────────
info()    { echo -e "${BLUE}[INFO]${PLAIN}  $*"; }
ok()      { echo -e "${GREEN}[  OK]${PLAIN}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
error()   { echo -e "${RED}[FAIL]${PLAIN}  $*"; }
die()     { error "$*"; exit 1; }

hr() {
    echo -e "${BLUE}──────────────────────────────────────────────────────${PLAIN}"
}

banner() {
    echo "BBR + TCP 调优 v${sh_ver} — Debian 12 / 13 及以上"
    echo "基于 VPS值得买原脚本修改，原作者：https://vpszdm.com"
}

is_supported_system() {
    local id="$1" major="${2%%.*}"
    [[ "$id" == "debian" && "$major" =~ ^[0-9]+$ ]] || return 1
    (( 10#$major >= 12 ))
}

check_system() {
    [[ -r /etc/os-release ]] || die "无法识别系统，仅支持 Debian 12 及以上"
    local ID="" VERSION_ID=""
    . /etc/os-release
    is_supported_system "$ID" "$VERSION_ID" || die "当前系统 $ID $VERSION_ID 不支持，仅支持 Debian 12 及以上"
    OS="$ID"
    VER="$VERSION_ID"
    ARCH=$(uname -m)
}

backup_file() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    local backup_dir
    backup_dir=$(mktemp -d /var/backups/debian-bbr.XXXXXXXX) || return 1
    cp -a -- "$file" "$backup_dir/" || return 1
    info "原配置已备份到 $backup_dir/"
}

# ────────────────────────── 依赖检查与安装 ──────────────────────────
check_dependencies() {
    local deps=() dep
    for dep in curl; do
        command -v "$dep" &>/dev/null || deps+=("$dep")
    done
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || deps+=(ca-certificates)
    if (( ${#deps[@]} )); then
        apt-get update && apt-get install -y "${deps[@]}" || return 1
    fi
}

# ────────────────────────── 虚拟化检测 ──────────────────────────
check_virt() {
    hr
    info "检测虚拟化类型..."

    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt)
    elif command -v virt-what &>/dev/null; then
        virt_type=$(virt-what | head -1)
    elif grep -q "openvz" /proc/vz/version 2>/dev/null || grep -q "openvz" /proc/cpuinfo 2>/dev/null; then
        virt_type="openvz"
    else
        virt_type="unknown"
    fi

    ok "虚拟化类型: ${BOLD}${virt_type}${PLAIN}"

    if [[ "$virt_type" == "openvz" ]]; then
        echo ""
        echo -e "${RED}  ┌─────────────────────────────────────────────────┐${PLAIN}"
        echo -e "${RED}  │  ⚠  警告：检测到 OpenVZ 虚拟化                  │${PLAIN}"
        echo -e "${RED}  │     OpenVZ 容器无法更换内核，无法启用 BBR        │${PLAIN}"
        echo -e "${RED}  │     建议更换为 KVM / Xen 虚拟化的 VPS            │${PLAIN}"
        echo -e "${RED}  └─────────────────────────────────────────────────┘${PLAIN}"
        echo ""
        read -rp "  是否继续（可能失败）? [y/N]: " continue_openvz
        [[ ! "$continue_openvz" =~ ^[Yy]$ ]] && exit 1
    fi
}

# ────────────────────────── /boot 空间检查 ──────────────────────────
check_boot_space() {
    hr
    info "检查 /boot 分区空间..."
    local boot_available
    boot_available=$(df -m /boot 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ -n "$boot_available" ]]; then
        if [[ $boot_available -lt 100 ]]; then
            warn "/boot 空间不足（可用: ${boot_available}MB），建议清理旧内核后再继续"
            read -rp "  是否继续? [y/N]: " continue_boot
            [[ ! "$continue_boot" =~ ^[Yy]$ ]] && exit 1
        else
            ok "/boot 空间充足（可用: ${boot_available}MB）"
        fi
    fi
}

# ────────────────────────── BBR 状态检测 ──────────────────────────
check_bbr_status() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$cc" == "bbr" ]]
}

# ────────────────────────── 内核版本检测 ──────────────────────────
check_kernel_native_bbr() {
    local kver major minor
    kver=$(uname -r | cut -d- -f1)
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)

    if [[ $major -gt 5 ]] || [[ $major -eq 5 && $minor -ge 4 ]]; then
        ok "内核 ${kver} 原生支持 BBR（最佳）"
        return 0
    elif [[ $major -eq 4 && $minor -ge 9 ]] || [[ $major -ge 5 ]]; then
        warn "内核 ${kver} 支持 BBR（建议升级到 5.4+）"
        return 0
    else
        error "内核 ${kver} 不支持 BBR，需要升级内核"
        return 1
    fi
}

# ────────────────────────── sysctl 兼容写入（兼容 LXC/容器）──────────────────────────
# 优先用 sysctl -w 逐条写入，避免 sysctl -p 在容器内遇到不支持的参数时中途退出
sysctl_apply_file() {
    local conf_file="$1"
    [[ -r "$conf_file" ]] || { error "无法读取 $conf_file"; return 1; }
    local skipped=0

    while IFS= read -r line; do
        # 跳过注释行和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # 提取 key=value（key 去除所有空格，value 仅去除首尾空白，保留中间空格）
        local key value
        key=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        value=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ -z "$key" || -z "$value" ]] && continue

        # 尝试写入，捕获错误
        local err
        err=$(sysctl -w "${key}=${value}" 2>&1)
        if [[ $? -ne 0 ]]; then
            # 报告失败并继续处理其他参数（容器内常见）
            warn "跳过不支持的参数: ${key} (${err})"
            (( skipped++ ))
        fi
    done < "$conf_file"

    (( skipped == 0 ))
}

# ────────────────────────── 启用 BBR ──────────────────────────
enable_bbr() {
    hr
    check_kernel_native_bbr || { warn "请先升级内核再启用 BBR"; return 1; }

    info "正在写入 BBR 配置..."

    backup_file /etc/sysctl.d/99-bbr.conf || return 1
    mkdir -p /etc/sysctl.d || return 1
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF' || return 1
# ── BBR 拥塞控制 ──
net.core.default_qdisc         = fq
net.ipv4.tcp_congestion_control = bbr

# ── 发送 / 接收缓冲区 ──
net.core.rmem_max               = 33554432
net.core.wmem_max               = 33554432
net.ipv4.tcp_rmem               = 4096 87380 33554432
net.ipv4.tcp_wmem               = 4096 65536 33554432

# ── 连接队列 ──
net.core.netdev_max_backlog     = 10000
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192

# ── TCP 快速选项 ──
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    # 使用兼容方式逐条写入（兼容 LXC/Docker 等容器环境）
    sysctl_apply_file /etc/sysctl.d/99-bbr.conf || warn "部分配置未生效，请查看上面的错误"

    # 兜底：强制写入最关键的两条
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

    if check_bbr_status; then
        echo ""
        echo -e "${GREEN}  ┌─────────────────────────────────────────────────┐${PLAIN}"
        echo -e "${GREEN}  │  ✅  BBR 已启用，实际性能请通过测速验证               │${PLAIN}"
        echo -e "${GREEN}  └─────────────────────────────────────────────────┘${PLAIN}"
        echo ""
    else
        echo ""
        error "BBR 启用失败，当前环境可能不支持修改拥塞控制算法"
        echo ""
        echo -e "${YELLOW}  可能原因：${PLAIN}"
        echo "    1. LXC/OpenVZ 容器且宿主机未授予 net_admin 权限"
        echo "    2. 内核未编译 BBR 模块（运行: modprobe tcp_bbr 验证）"
        echo "    3. 容器平台锁定了该参数"
        echo ""
        echo -e "${YELLOW}  手动验证命令：${PLAIN}"
        echo "    modprobe tcp_bbr && echo ok"
        echo "    echo bbr > /proc/sys/net/ipv4/tcp_congestion_control"
        echo "    sysctl net.ipv4.tcp_congestion_control"
        return 1
    fi
}

# ────────────────────────── TCP 深度调优 ──────────────────────────
tcp_tune() {
    hr
    info "正在应用 TCP 深度调优..."
    echo ""
    echo -e "${YELLOW}  本操作将优化以下参数：${PLAIN}"
    echo "    • TIME_WAIT 连接回收与复用"
    echo "    • TCP 连接保活 (keepalive)"
    echo "    • MTU 探测 & PMTU"
    echo "    • 本地端口范围扩展"
    echo "    • SYN Cookie 防 SYN Flood"
    echo "    • 连接追踪表 (nf_conntrack)"
    echo "    • 文件描述符上限
    固定参数不保证提速；容器中部分参数可能被宿主机限制。"
    echo ""
    read -rp "  确认写入? [y/N]: " confirm_tune
    [[ ! "$confirm_tune" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    backup_file /etc/sysctl.d/99-tcp-tune.conf || return 1
    backup_file /etc/security/limits.conf || return 1
    mkdir -p /etc/sysctl.d || return 1
    cat > /etc/sysctl.d/99-tcp-tune.conf <<'EOF' || return 1
# ════════════════════════════════════════════
#   TCP 深度调优 - by VPS值得买
#   https://vpszdm.com
# ════════════════════════════════════════════

# ── TIME_WAIT ──────────────────────────────
# 允许复用符合内核安全条件的 TIME_WAIT 连接
net.ipv4.tcp_tw_reuse           = 1
# TIME_WAIT 最大数量，超出直接丢弃
net.ipv4.tcp_max_tw_buckets     = 20000

# ── 连接保活 ───────────────────────────────
# 空闲 60s 后开始发送 keepalive 探测包
net.ipv4.tcp_keepalive_time     = 60
# 探测间隔 10s
net.ipv4.tcp_keepalive_intvl    = 10
# 最多探测 6 次无响应则断开
net.ipv4.tcp_keepalive_probes   = 6

# ── SYN 握手 ───────────────────────────────
# SYN Cookie 防 SYN Flood
net.ipv4.tcp_syncookies         = 1
# SYN 重试次数
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_synack_retries     = 3
# SYN 等待队列
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192

# ── 端口范围 ───────────────────────────────
net.ipv4.ip_local_port_range    = 1024 65535

# ── MTU 探测（推荐开启，减少分片）──────────
net.ipv4.tcp_mtu_probing        = 1

# ── 内存与缓冲区 ───────────────────────────
net.core.rmem_default           = 262144
net.core.wmem_default           = 262144
net.core.rmem_max               = 33554432
net.core.wmem_max               = 33554432
net.ipv4.tcp_rmem               = 4096 87380 33554432
net.ipv4.tcp_wmem               = 4096 65536 33554432

# ── 连接队列/网卡接收队列 ──────────────────
net.core.netdev_max_backlog     = 10000

# ── TCP 选项 ───────────────────────────────
# 启用 TCP Fast Open
net.ipv4.tcp_fastopen           = 3
# 关闭空闲后慢启动（提升长肥管道性能）
net.ipv4.tcp_slow_start_after_idle = 0
# 选择性确认（提升丢包恢复效率）
net.ipv4.tcp_sack               = 1
# 时间戳（配合 tw_reuse 使用）
net.ipv4.tcp_timestamps         = 1
# 窗口扩展（大带宽必备）
net.ipv4.tcp_window_scaling     = 1
# 不保存连接的 TCP 路径度量
net.ipv4.tcp_no_metrics_save    = 1

# ── 连接追踪表（如有 nf_conntrack 模块）──────
net.netfilter.nf_conntrack_max              = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# ── 文件描述符 ─────────────────────────────
fs.file-max                     = 1000000
EOF

    # 使用兼容方式逐条写入（自动跳过不支持的参数）
    sysctl_apply_file /etc/sysctl.d/99-tcp-tune.conf || warn "部分配置未生效，请查看上面的错误"

    # 提升系统文件描述符限制（持久化）
    if ! grep -q "# tcp-tune" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF' || return 1

# tcp-tune: 提升文件描述符限制
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
    fi

    echo ""
    echo -e "${GREEN}  ┌─────────────────────────────────────────────────┐${PLAIN}"
    echo -e "${GREEN}  │  ✅  TCP 调优已尝试应用，请检查输出                         │${PLAIN}"
    echo -e "${GREEN}  │     配置文件: /etc/sysctl.d/99-tcp-tune.conf    │${PLAIN}"
    echo -e "${GREEN}  │     sysctl 即时应用，登录限制需重新登录                       │${PLAIN}"
    echo -e "${GREEN}  └─────────────────────────────────────────────────┘${PLAIN}"
    echo ""
}

# 仅使用当前 Debian 已配置的软件源，不更换源，不安装第三方内核。
upgrade_kernel_debian() {
    local arch package
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64|riscv64|s390x) package="linux-image-$arch" ;;
        armhf) package="linux-image-armmp" ;;
        i386) package="linux-image-686-pae" ;;
        ppc64el) package="linux-image-powerpc64le" ;;
        *) error "架构 $arch 未配置自动内核升级，请使用发行版对应内核包"; return 1 ;;
    esac
    info "将从当前软件源安装/更新 $package。已有云厂商定制内核时请先确认兼容性。"
    local confirm
    read -rp "确认继续? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    check_boot_space
    apt-get update && apt-get install -y "$package" || { error "内核更新失败"; return 1; }
    ok "内核包安装完成；如安装了新内核，请在维护窗口重启后再次检查 BBR。"
}

remove_old_kernels() {
    local current package confirm
    current="linux-image-$(uname -r)"
    local kernels=() keep=() remove=()
    mapfile -t kernels < <(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' 'linux-image-[0-9]*' 2>/dev/null |
        awk '$1 == "installed" {sub(/:[^:]+$/, "", $2); print $2}' | sort -V)
    (( ${#kernels[@]} )) || { info "没有找到已安装的版本化内核包"; return 0; }
    mapfile -t keep < <(printf '%s\n' "${kernels[@]}" | tail -n 2)
    for package in "${kernels[@]}"; do
        [[ "$package" == "$current" ]] && continue
        [[ "$package" == "${keep[0]}" || "$package" == "${keep[1]:-}" ]] && continue
        remove+=("$package")
    done
    (( ${#remove[@]} )) || { ok "无须清理：保留当前运行内核和最新两个内核包"; return 0; }
    info "保留当前运行内核和最新两个内核包，将清理："
    printf '  %s\n' "${remove[@]}"
    read -rp "确认删除? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    apt-get purge -y "${remove[@]}" || { error "部分内核清理失败"; return 1; }
    ok "清理完成（未运行 autoremove）"
}

# ────────────────────────── 系统状态展示 ──────────────────────────
show_status() {
    hr
    local bbr_status bbr_mod qdisc cc
    check_bbr_status  && bbr_status="${GREEN}✅ 已启用${PLAIN}" || bbr_status="${RED}❌ 未启用${PLAIN}"
    if grep -q '^tcp_bbr ' /proc/modules 2>/dev/null; then
        bbr_mod="${GREEN}✅ 已加载（模块）${PLAIN}"
    elif grep -q 'CONFIG_TCP_CONG_BBR=y' /boot/config-$(uname -r) 2>/dev/null \
      || zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_TCP_CONG_BBR=y'; then
        bbr_mod="${GREEN}✅ 已内置（built-in）${PLAIN}"
    elif check_bbr_status; then
        bbr_mod="${GREEN}✅ 运行中（内置）${PLAIN}"
    else
        bbr_mod="${RED}❌ 未加载${PLAIN}"
    fi
    qdisc=$(sysctl -n net.core.default_qdisc        2>/dev/null || echo "未设置")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control  2>/dev/null || echo "未设置")

    printf "  ${CYAN}%-18s${PLAIN} %s\n"    "操作系统:"   "$OS $VER"
    printf "  ${CYAN}%-18s${PLAIN} %s\n"    "系统架构:"   "$ARCH"
    printf "  ${CYAN}%-18s${PLAIN} %s\n"    "内核版本:"   "$(uname -r)"
    printf "  ${CYAN}%-18s${PLAIN}${bbr_status}\n" "BBR 状态:"
    printf "  ${CYAN}%-18s${PLAIN}${bbr_mod}\n"    "BBR 模块:"
    printf "  ${CYAN}%-18s${PLAIN} %s\n"    "队列算法:"   "$qdisc"
    printf "  ${CYAN}%-18s${PLAIN} %s\n"    "拥塞控制:"   "$cc"

    # TCP 调优状态
    if [[ -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
        printf "  ${CYAN}%-18s${PLAIN} ${GREEN}配置文件存在（生效情况请检查）${PLAIN}\n" "TCP 调优:"
    else
        printf "  ${CYAN}%-18s${PLAIN} ${YELLOW}⬜ 未应用${PLAIN}\n" "TCP 调优:"
    fi
    hr
}

show_menu() {
    local choice
    while true; do
        banner
        show_status
        echo "1. 启用 BBR"
        echo "2. TCP 深度调优"
        echo "3. 更新 Debian 内核"
        echo "4. 清理旧内核（保留当前及最新两个）"
        echo "5. 查看状态"
        echo "0. 退出"
        read -rp "请选择 [0-5]: " choice || return 0
        case "$choice" in
            1) enable_bbr ;;
            2) tcp_tune ;;
            3) upgrade_kernel_debian ;;
            4) remove_old_kernels ;;
            5) show_status ;;
            0) return 0 ;;
            *) warn "无效选项" ;;
        esac
        read -rp "按 Enter 继续..." _ || return 0
    done
}

main() {
    # 必须先完成版本检查，再允许安装依赖或修改系统。
    check_system
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行（sudo bash bbr.sh）"
    [[ -t 0 ]] || die "请先下载脚本，再在交互终端运行；不要使用 curl | bash"
    check_dependencies || die "依赖安装失败"
    check_virt
    show_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
