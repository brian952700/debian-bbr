#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System  : Debian 12 / 13 and later
#   Desc    : BBR一键加速 + TCP深度调优
#   Version : 3.2.0-debian
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

sh_ver="3.2.0-debian"

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
    local deps=()
    command -v sysctl &>/dev/null || deps+=(procps)
    if ! command -v ip &>/dev/null || ! command -v ss &>/dev/null || ! command -v tc &>/dev/null; then
        deps+=(iproute2)
    fi
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
        if ! err=$(sysctl -w "${key}=${value}" 2>&1); then
            # 报告失败并继续处理其他参数（容器内常见）
            warn "跳过不支持的参数: ${key} (${err})"
            skipped=$((skipped + 1))
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

# 只读诊断：不测速、不扫描第三方节点、不读取代理账号或证书。
parse_socket_rtts() {
    awk '
        /^[^ \t]/ && !/rtt:/ {
            skip = ($0 ~ /(^|[ \t])(127\.|\[?::1\]?:|\[?::ffff:127\.)/)
            next
        }
        !skip {
            for (i=1; i<=NF; i++) if ($i ~ /^rtt:[0-9]/) {
                split($i, p, ":"); split(p[2], r, "/")
                if (r[1]+0 > 0) print r[1]+0
            }
        }'
}

rtt_summary() {
    sort -n | awk '{a[NR]=$1} END {
        if (NR) printf "%d %.3f %.3f\n", NR, a[int((NR+1)/2)], a[int((NR*3+3)/4)]
        else print "0 0 0"
    }'
}

effective_memory() {
    local total available limit used f
    read -r total available < <(awk '
        /^MemTotal:/ {t=int($2/1024)} /^MemAvailable:/ {a=int($2/1024)}
        END {print t+0, a+0}' /proc/meminfo)
    # 容器内 /proc/meminfo 可能显示宿主机内存，优先收紧到可读的 cgroup 限制。
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$f" ]] || continue
        read -r limit < "$f"
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        # 使用 awk 避免 v1 的超大 unlimited 值溢出 shell 算术。
        if awk -v l="$limit" -v t="$total" 'BEGIN {exit !(l>0 && l/1048576<t)}'; then
            used=0
            if [[ "$f" == */memory.max && -r /sys/fs/cgroup/memory.current ]]; then
                read -r used < /sys/fs/cgroup/memory.current
            elif [[ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
                read -r used < /sys/fs/cgroup/memory/memory.usage_in_bytes
            fi
            read -r total available < <(awk -v l="$limit" -v u="$used" -v a="$available" 'BEGIN {
                t=int(l/1048576); free=int((l-u)/1048576); if(free<0) free=0
                if(free<a) a=free; print t,a
            }')
        fi
    done
    printf '%s %s\n' "$total" "$available"
}

detect_network() {
    local dev="" speed="" sample
    read -r DETECT_TOTAL_MIB DETECT_FREE_MIB < <(effective_memory)
    info "有效内存: ${DETECT_TOTAL_MIB} MiB；可用估计: ${DETECT_FREE_MIB} MiB"
    info "CPU: $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 未知)；内核: $(uname -r)"
    dev=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$dev" ]] || dev=$(ip -o -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$dev" ]]; then
        info "默认出口: $dev（多出口/策略路由时不一定对应所有客户端）"
        if [[ -r "/sys/class/net/$dev/speed" ]]; then
            speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null) || speed=""
            [[ "$speed" =~ ^[0-9]+$ ]] && info "网卡报告速率: $speed Mbps，仅供参考，不当作实际带宽"
        fi
        ip -s link show dev "$dev" 2>/dev/null || true
        info "实际网卡队列（只查看，不替换已有 mq/整形配置）："
        tc qdisc show dev "$dev" 2>/dev/null || true
    else
        warn "未检测到默认出口；不会据此猜测线路质量"
    fi
    info "读取本机已建立 TCP 连接的一次 RTT 快照（排除回环，仅供诊断）..."
    if sample=$(ss -Htin state established 2>/dev/null); then
        read -r DETECT_SAMPLES DETECT_MEDIAN_MS DETECT_P75_MS < <(printf '%s\n' "$sample" | parse_socket_rtts | rtt_summary)
    else
        DETECT_SAMPLES=0 DETECT_MEDIAN_MS=0 DETECT_P75_MS=0
        warn "ss 读取失败，按无样本处理"
    fi
    info "RTT 样本 ${DETECT_SAMPLES} 个；中位数 ${DETECT_MEDIAN_MS} ms；P75 ${DETECT_P75_MS} ms"
    echo "这是全机 TCP 平滑 RTT，包含其他服务和出站连接；不用于推断运营商、带宽或参数上限。"
    echo "仅显示汇总，不保存连接地址；没有样本时继续跳过依赖线路信息的调整。"
}

# 只生成能够可靠判断的修改；不依据 RTT 或虚拟网卡速率猜测缓冲区上限。
build_auto_tcp_plan() {
    local current
    if current=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null); then
        [[ "$current" == 0 ]] && printf '%s\n' 'net.ipv4.tcp_moderate_rcvbuf = 1'
    fi
    return 0
}

apply_auto_tcp_plan() {
    local plan="$1" conf_file="$2" backup_root="$3"
    [[ "$plan" == 'net.ipv4.tcp_moderate_rcvbuf = 1' ]] || { error "没有可安全应用的自动调优项"; return 1; }
    local before state_dir staged
    before=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null) || { warn "参数已不可读，跳过"; return 0; }
    [[ "$before" == 0 ]] || { info "参数已变化或已经开启，跳过"; return 0; }
    mkdir -p -- "$backup_root" "$(dirname "$conf_file")" || return 1
    state_dir=$(mktemp -d "$backup_root/debian-bbr-auto.XXXXXXXX") || return 1
    if [[ -e "$conf_file" ]]; then
        cp -a -- "$conf_file" "$state_dir/previous.conf" || return 1
    else
        touch "$state_dir/no-previous-config" || return 1
    fi
    printf '%s\n' "net.ipv4.tcp_moderate_rcvbuf = $before" > "$state_dir/runtime-before.conf" || return 1
    staged=$(mktemp "$(dirname "$conf_file")/.debian-bbr-auto.XXXXXXXX") || return 1
    if ! printf '# Managed by Debian BBR automatic tuning\n%s\n' "$plan" > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    chmod 644 "$staged" || { rm -f -- "$staged"; return 1; }
    # 先应用并回读验证。宿主机拒绝或不生效时不留下持久配置。
    if ! sysctl -w net.ipv4.tcp_moderate_rcvbuf=1; then
        rm -f -- "$staged"
        warn "系统拒绝修改，已跳过，原持久配置保留"
        return 1
    fi
    if [[ $(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null) != 1 ]]; then
        sysctl -w "net.ipv4.tcp_moderate_rcvbuf=$before" >/dev/null 2>&1 || warn "运行值恢复失败，请检查系统限制"
        rm -f -- "$staged"
        warn "无法验证参数生效，未保存持久配置"
        return 1
    fi
    if ! mv -f -- "$staged" "$conf_file"; then
        sysctl -w "net.ipv4.tcp_moderate_rcvbuf=$before" >/dev/null 2>&1 || warn "运行值恢复失败，请检查系统限制"
        rm -f -- "$staged"
        return 1
    fi
    ok "已开启内核接收缓冲区自动调节；具体大小由内核按连接及现有上限决定"
    info "配置：$conf_file；备份：$state_dir"
    echo "恢复运行值：sysctl -p $state_dir/runtime-before.conf"
    echo "恢复持久配置：还原备份 previous.conf；若有 no-previous-config 标记，则原先没有该文件。"
}

tcp_tune() {
    hr
    info "自动检测 TCP 环境，无需填写任何参数"
    detect_network
    local plan
    plan=$(build_auto_tcp_plan) || return 1
    info "带宽、三网线路、业务端口和 CDN/直连无法可靠自动判断，不据此修改缓冲区、队列或重试参数"
    if [[ -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
        warn "发现旧版调优配置；本次保留，旧参数不会自动恢复。恢复方法见 README。"
    fi
    if [[ -z "$plan" ]]; then
        ok "未发现可可靠自动调整的项目；已开启、不支持或不可读取的参数均跳过，未写入配置"
        return 0
    fi
    info "检测到接收缓冲区自动调节已关闭，正在自动开启并备份"
    apply_auto_tcp_plan "$plan" /etc/sysctl.d/99-tcp-auto.conf /var/backups
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

    # 配置文件存在不代表运行值已生效。
    if [[ -f /etc/sysctl.d/99-tcp-auto.conf || -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
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
        echo "2. TCP 自动检测与适配（无需设置）"
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
        [[ "$choice" == 2 ]] && continue
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
