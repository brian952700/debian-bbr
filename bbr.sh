#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System  : Debian 12 / 13 and later
#   Desc    : BBR一键加速 + TCP深度调优
#   Version : 3.1.0-debian
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

sh_ver="3.1.0-debian"

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

valid_measurement() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v n="$1" -v max="$2" 'BEGIN {exit !(n>0 && n<=max)}'
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

recommend_buffer_mib() {
    # 工程启发式，不是 BBR 算法参数：内存约束 + 约 2 倍带宽时延积。
    # 参数均由内部检测或通过校验的数值提供；用 awk 避免输入进入 shell 算术表达式。
    awk -v total="$1" -v free="$2" -v bw="$3" -v rtt="$4" 'BEGIN {
        cap=8
        if(total>=512 && free>=128) cap=16
        if(total>=1024 && free>=256) cap=32
        if(total>=2048 && free>=512) cap=64
        if(total>=4096 && free>=1024) cap=128
        result=(cap<32 ? cap : 32)
        if(bw>0 && rtt>0) {
            need=2*bw*rtt*125/1048576
            while(result<need && result<cap) result*=2
        }
        if(result>cap) result=cap
        print result
    }'
}

detect_network() {
    local port="$1" dev="" speed="" sample
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
    info "读取本机 TCP $port 入站已建立连接的一次 RTT 快照（排除回环）..."
    if sample=$(ss -Htin state established "( sport = :$port )" 2>/dev/null); then
        read -r DETECT_SAMPLES DETECT_MEDIAN_MS DETECT_P75_MS < <(printf '%s\n' "$sample" | parse_socket_rtts | rtt_summary)
    else
        DETECT_SAMPLES=0 DETECT_MEDIAN_MS=0 DETECT_P75_MS=0
        warn "ss 读取失败，按无样本处理"
    fi
    info "RTT 样本 ${DETECT_SAMPLES} 个；中位数 ${DETECT_MEDIAN_MS} ms；P75 ${DETECT_P75_MS} ms"
    echo "这是 TCP 平滑 RTT，不是三网测速或丢包率；同端口也可能包含网站访问。"
    echo "不采集客户端 IP 到报告，不读取 Xray/Nginx 配置。建议让国内客户端连接并传输后重试。"
}

write_adaptive_config() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    cat <<EOF
# Debian BBR 自适应 TCP 配置；上限由内存与可选 BDP 估算决定。
# 不修改 BBR 内部增益，不承诺三网最优；不替换实际网卡队列。
net.core.rmem_max = $bytes
net.core.wmem_max = $bytes
net.ipv4.tcp_rmem = 4096 131072 $bytes
net.ipv4.tcp_wmem = 4096 65536 $bytes
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
}

tcp_tune() {
    hr
    echo "直连 VLESS + WS/XHTTP + TLS：先诊断，再预览，确认后才写入。"
    echo "XHTTP 使用 H3/QUIC 时，TCP 调优不直接控制该 UDP 传输；CDN 场景 RTT 也不代表国内客户端。"
    local port topology bw rtt manual cap bytes confirm preview state_dir key value
    read -rp "公网 TLS/TCP 入站端口 [443]: " port || return 0
    port=${port:-443}
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { error "端口无效"; return 1; }
    port=$((10#$port))
    read -rp "连接方式 [1=直连，2=CDN/不确定；默认1]: " topology || return 0
    topology=${topology:-1}
    [[ "$topology" == 1 || "$topology" == 2 ]] || { error "选项无效"; return 1; }
    detect_network "$port"
    echo "套餐带宽只作为估算输入；不要填虚拟网卡速率或把共享峰值当保底。"
    read -rp "预计分配给单条代理连接的带宽 Mbps [留空=未知]: " bw || return 0
    if [[ -n "$bw" ]]; then
        valid_measurement "$bw" 100000 || { error "带宽应为 0 到 100000 之间的正数"; return 1; }
    else
        bw=0
    fi
    rtt=0
    if [[ "$topology" == 1 ]] && (( DETECT_SAMPLES >= 5 )); then
        rtt=$DETECT_P75_MS
        info "直连样本达到 5 个，使用当前快照的 P75 RTT 估算（非运营商分类）"
    else
        warn "无足够直连样本，或连接经过 CDN，不自动用该 RTT 放大缓冲区"
    fi
    read -rp "可填写从国内客户端测得的 TCP RTT 毫秒 [留空=沿用可用样本/未知]: " manual || return 0
    if [[ -n "$manual" ]]; then
        valid_measurement "$manual" 10000 || { error "RTT 应为 0 到 10000 之间的正数"; return 1; }
        if [[ "$topology" == 1 ]]; then
            rtt=$manual
        else
            warn "CDN 场景客户端 RTT 不等于回源 RTT；本次不用于计算源站 TCP 缓冲区"
        fi
    fi
    cap=$(recommend_buffer_mib "$DETECT_TOTAL_MIB" "$DETECT_FREE_MIB" "$bw" "$rtt")
    bytes=$((cap * 1048576))
    info "建议每个方向缓冲区上限: $cap MiB；BW=$bw Mbps，估算 RTT=$rtt ms（0=未知/不使用）"
    echo "这是试验上限，不会预分配给每条连接；高并发仍可能增加内存压力。"
    echo "算法依据：约 2 倍带宽时延积，按内存余量封顶 8/16/32/64/128 MiB；未知线路不主动升档。"
    echo "以下是将写入的完整配置："
    preview=$(write_adaptive_config "$bytes") || return 1
    printf '%s\n' "$preview"
    echo "不修改 Xray/Nginx、路由、端口范围、conntrack、文件上限或 SYN 重试。"
    echo "旧版已修改的其他运行值不会因移除旧配置而立即复原；需要按原备份恢复或重启后核对。"
    read -rp "备份并应用上述配置? [y/N]: " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消，未写入调优配置"; return 0; }

    state_dir=$(mktemp -d /var/backups/debian-bbr-tune.XXXXXXXX) || return 1
    if [[ -e /etc/sysctl.d/99-tcp-tune.conf ]]; then
        cp -a /etc/sysctl.d/99-tcp-tune.conf "$state_dir/" || return 1
    else
        touch "$state_dir/no-previous-tcp-config" || return 1
    fi
    while IFS='=' read -r key _; do
        [[ "$key" == \#* || -z "$key" ]] && continue
        key=${key// /}
        if value=$(sysctl -n "$key" 2>/dev/null); then
            printf '%s = %s\n' "$key" "$value" >> "$state_dir/runtime-before.conf" || return 1
        fi
    done <<< "$preview"
    printf 'port=%s\ntopology=%s\nsamples=%s\nrtt_median_ms=%s\nrtt_p75_ms=%s\nchosen_rtt_ms=%s\nbandwidth_mbps=%s\nbuffer_mib=%s\n' \
        "$port" "$topology" "$DETECT_SAMPLES" "$DETECT_MEDIAN_MS" "$DETECT_P75_MS" "$rtt" "$bw" "$cap" > "$state_dir/report.txt" || return 1
    mkdir -p /etc/sysctl.d || return 1
    printf '%s\n' "$preview" > /etc/sysctl.d/99-tcp-tune.conf || return 1
    info "配置与运行值备份：$state_dir"
    if sysctl_apply_file /etc/sysctl.d/99-tcp-tune.conf; then
        ok "全部目标参数已应用。请从国内客户端比较单连接吞吐、加载延迟和重传。"
    else
        warn "部分参数失败；配置已保存，请检查上方错误，不能视为全部生效。"
        return 1
    fi
    echo "恢复本次涉及的运行值：sysctl -p $state_dir/runtime-before.conf"
    echo "恢复持久配置：有旧文件时将备份复制回原路径；标记 no-previous-tcp-config 表示原先没有此文件。"
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
        echo "2. 网络检测 + 自适应 TCP 调优（直连 WS/XHTTP）"
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
