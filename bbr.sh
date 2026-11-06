#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System  : Debian 12 / 13 and later
#   Desc    : BBR一键加速 + TCP深度调优
#   Version : 3.3.0-debian
#   Author  : VPS值得买
#   测评网站    : https://vpszdm.com
#=================================================

# 终端显示：交互终端自动启用颜色，日志/重定向默认纯文本。
ui_init() {
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' PLAIN=''
    UI_COLUMNS=${COLUMNS:-}
    if [[ -t 1 ]] && command -v stty &>/dev/null; then
        local terminal_rows terminal_columns
        read -r terminal_rows terminal_columns < <(stty size 2>/dev/null) || true
        if [[ "$terminal_columns" =~ ^[0-9]{2,3}$ ]]; then UI_COLUMNS=$terminal_columns; fi
    fi
    if [[ -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] &&
       { [[ -t 1 ]] || [[ ${BBR_COLOR:-auto} == always ]]; }; then
        RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
        BLUE=$'\033[36m' CYAN=$'\033[96m' BOLD=$'\033[1m'
        DIM=$'\033[90m' PLAIN=$'\033[0m'
    fi
}
ui_init

sh_ver="3.3.0-debian"

ui_log() { printf '  %s[%s]%s %s\n' "$1" "$2" "$PLAIN" "$3"; }
info()  { ui_log "$BLUE" '信息' "$*"; }
ok()    { ui_log "$GREEN" '完成' "$*"; }
warn()  { ui_log "$YELLOW" '提醒' "$*"; }
skip()  { ui_log "$YELLOW" '跳过' "$*"; }
error() { ui_log "$RED" '失败' "$*"; }
die()   { error "$*"; exit 1; }

hr() {
    local width=68 i
    if [[ ${UI_COLUMNS:-} =~ ^[0-9]{2,3}$ ]]; then
        width=$((10#$UI_COLUMNS - 4))
        if (( width < 32 )); then width=32; fi
        if (( width > 68 )); then width=68; fi
    fi
    printf '  %s' "$DIM"
    for (( i=0; i<width; i++ )); do printf '─'; done
    printf '%s\n' "$PLAIN"
}

ui_detail() { printf '         %s\n' "$*"; }
ui_kv()     { printf '  %s%s%s  %s\n' "$DIM" "$1" "$PLAIN" "$2"; }
ui_section() {
    printf '\n  %s%s%s\n' "$BOLD$CYAN" "$1" "$PLAIN"
    hr
}
ui_step() { printf '\n  %s[%s/%s]%s %s\n' "$CYAN" "$1" "$2" "$PLAIN" "$3"; }
ui_prompt() { printf '\n  %s›%s %s ' "$CYAN" "$PLAIN" "$1"; }

banner() {
    printf '\n'
    hr
    printf '  %sDEBIAN  /  BBR + TCP%s\n' "$BOLD$CYAN" "$PLAIN"
    printf '  网络配置助手  %sv%s%s\n' "$DIM" "$sh_ver" "$PLAIN"
    printf '\n  Debian 12 / 13 及以上 · TCP 自动适配\n'
    printf '  %s基于 VPS值得买原脚本修改 · vpszdm.com%s\n' "$DIM" "$PLAIN"
    hr
}

run_action() {
    local title="$1"
    shift
    ui_section "$title"
    if "$@"; then
        printf '\n'
        ui_detail '本次操作结束，结果见上方提示。'
    else
        printf '\n'
        error '本次操作未全部完成，请查看上方原因。'
        return 1
    fi
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
        info "正在安装缺少的依赖：${deps[*]}"
        ui_detail "软件包管理器输出如下；完成后会自动继续。"
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
        printf '\n'
        warn '检测到 OpenVZ 容器，内核由宿主机管理。'
        ui_detail 'BBR 是否可用取决于宿主机支持与容器权限。'
        ui_detail '本脚本可能无法修改相关参数。'
        read -rp "$(ui_prompt '仍要继续吗？[y/N]：')" continue_openvz
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
            read -rp "$(ui_prompt '仍要继续吗？[y/N]：')" continue_boot
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
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    if check_bbr_status; then
        printf '\n'
        ok 'BBR 已启用'
        ui_detail '配置已保存，实际网络表现请从客户端验证。'
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
    local dev="" speed="" sample queues rxdrop txdrop
    read -r DETECT_TOTAL_MIB DETECT_FREE_MIB < <(effective_memory)
    ui_kv '有效内存' "${DETECT_TOTAL_MIB} MiB（当前可用约 ${DETECT_FREE_MIB} MiB）"
    ui_kv 'CPU 核心' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 未知)"
    ui_kv '当前内核' "$(uname -r)"
    dev=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$dev" ]] || dev=$(ip -o -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$dev" ]]; then
        ui_kv '默认出口' "$dev"
        if [[ -r "/sys/class/net/$dev/speed" ]]; then
            speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null) || speed=""
            if [[ "$speed" =~ ^[0-9]+$ ]]; then
                ui_kv '网卡速率' "$speed Mbps（报告值，不代表实际带宽）"
            fi
        fi
        queues=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$1=="qdisc" && !seen[$2]++ {printf "%s%s",sep,$2; sep=" / "} END {print ""}')
        ui_kv '网卡队列' "${queues:-不可读取}（保持现状）"
        if [[ -r "/sys/class/net/$dev/statistics/rx_dropped" && -r "/sys/class/net/$dev/statistics/tx_dropped" ]]; then
            read -r rxdrop < "/sys/class/net/$dev/statistics/rx_dropped"
            read -r txdrop < "/sys/class/net/$dev/statistics/tx_dropped"
            ui_kv '累计丢弃' "网卡接收 ${rxdrop:-未知} / 发送 ${txdrop:-未知}（非线路丢包率）"
        fi
    else
        skip '未检测到默认出口，略过网卡信息'
    fi
    printf '\n'
    info '读取现有 TCP 连接摘要'
    if sample=$(ss -Htin state established 2>/dev/null); then
        read -r DETECT_SAMPLES DETECT_MEDIAN_MS DETECT_P75_MS < <(printf '%s\n' "$sample" | parse_socket_rtts | rtt_summary)
    else
        DETECT_SAMPLES=0 DETECT_MEDIAN_MS=0 DETECT_P75_MS=0
        warn "ss 读取失败，按无样本处理"
    fi
    if (( DETECT_SAMPLES > 0 )); then
        ui_kv '连接样本' "${DETECT_SAMPLES} 个（排除回环）"
        ui_kv 'RTT 摘要' "中位数 ${DETECT_MEDIAN_MS} ms / P75 ${DETECT_P75_MS} ms"
        ui_detail '全机连接快照，仅作诊断，不用于估算线路带宽。'
    else
        skip '暂无可用 RTT 样本，继续执行可判断的项目'
    fi
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
    local before state_dir staged apply_error
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
    if ! apply_error=$(sysctl -w net.ipv4.tcp_moderate_rcvbuf=1 2>&1); then
        rm -f -- "$staged"
        warn "系统拒绝修改，已跳过，原持久配置保留"
        [[ -z "$apply_error" ]] || ui_detail "$apply_error"
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
    ok '已开启内核接收缓冲区自动调节'
    ui_detail '具体大小由内核按连接与现有上限决定。'
    info "配置已保存，备份已完成"
    ui_detail "配置：$conf_file"
    ui_detail "备份：$state_dir"
    printf '\n'
    ui_detail '需要恢复时，可执行以下命令：'
    ui_detail "sysctl -p $state_dir/runtime-before.conf"
    ui_detail '持久配置恢复方法见 README，备份文件已保留。'
}

tcp_tune() {
    ui_step 1 3 '自动检测服务器环境'
    detect_network
    local plan
    ui_step 2 3 '判断可自动适配的项目'
    plan=$(build_auto_tcp_plan) || return 1
    skip '线路带宽与连接拓扑：无法可靠判断，保持现状'
    if [[ -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
        warn "发现旧版调优配置；本次保留，旧参数不会自动恢复。恢复方法见 README。"
    fi
    if [[ -z "$plan" ]]; then
        ui_step 3 3 '执行结果'
        skip '无需调整：参数已开启，或系统不支持可靠检测'
        ui_detail '本次未写入配置。'
        return 0
    fi
    ui_step 3 3 '备份并应用自动适配'
    info '检测到接收缓冲区自动调节已关闭，正在开启'
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
    read -rp "$(ui_prompt '确认更新内核？[y/N]：')" confirm
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
    read -rp "$(ui_prompt '确认删除列出的旧内核？[y/N]：')" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    apt-get purge -y "${remove[@]}" || { error "部分内核清理失败"; return 1; }
    ok "清理完成（未运行 autoremove）"
}

show_status() {
    local cc qdisc auto bbr_status auto_status
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc='不可读取'
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc='不可读取'
    auto=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null) || auto='未知'
    if [[ "$cc" == bbr ]]; then
        bbr_status="${GREEN}已启用${PLAIN}"
    elif [[ "$cc" == '不可读取' ]]; then
        bbr_status="${YELLOW}未知（无法读取）${PLAIN}"
    else
        bbr_status="${YELLOW}未启用${PLAIN}"
    fi
    case "$auto" in
        1) auto_status="${GREEN}已开启${PLAIN}" ;;
        0) auto_status="${YELLOW}未开启，可选 2 自动检测${PLAIN}" ;;
        *) auto_status="${YELLOW}不可判断，将自动跳过${PLAIN}" ;;
    esac
    ui_kv '操作系统' "${OS:-debian} ${VER:-未知} / ${ARCH:-未知}"
    ui_kv '当前内核' "$(uname -r)"
    ui_kv 'BBR 状态' "$bbr_status"
    ui_kv '拥塞控制' "$cc"
    ui_kv '默认队列' "$qdisc"
    ui_kv 'TCP 自动' "$auto_status"
    if [[ -f /etc/sysctl.d/99-tcp-auto.conf ]]; then
        ui_kv '持久配置' '已保存自动适配配置（运行状态见上方）'
    fi
    if [[ -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
        ui_kv '旧版配置' "${YELLOW}存在，历史设置仍保留${PLAIN}"
    fi
}

show_menu() {
    local choice
    while true; do
        ui_section '系统概览'
        show_status
        ui_section '请选择操作'
        printf '  %s1%s  开启 BBR\n' "$GREEN" "$PLAIN"
        ui_detail '启用拥塞控制，并保存配置'
        printf '\n  %s2%s  TCP 自动检测与适配  %s[无需设置]%s\n' "$GREEN" "$PLAIN" "$CYAN" "$PLAIN"
        ui_detail '自动检测 · 能适配才调整 · 其余跳过'
        printf '\n'
        hr
        printf '  %s3%s  更新 Debian 内核\n' "$CYAN" "$PLAIN"
        printf '  %s4%s  清理旧内核\n' "$CYAN" "$PLAIN"
        printf '  %s5%s  查看当前状态\n' "$CYAN" "$PLAIN"
        printf '  %s0%s  退出\n' "$DIM" "$PLAIN"
        read -rp "$(ui_prompt '输入编号 [0–5]：')" choice || return 0
        case "$choice" in
            1) run_action '开启 BBR' enable_bbr ;;
            2) run_action 'TCP 自动检测与适配' tcp_tune ;;
            3) run_action '更新 Debian 内核' upgrade_kernel_debian ;;
            4) run_action '清理旧内核' remove_old_kernels ;;
            5) ui_section '当前系统状态'; show_status ;;
            0) printf '\n'; info '已退出。配置结果已保留。'; printf '\n'; return 0 ;;
            *) warn '请输入 0 到 5 之间的编号。'; continue ;;
        esac
        [[ "$choice" == 2 ]] && continue
        read -rp "$(ui_prompt '按 Enter 返回菜单…')" _ || return 0
    done
}

main() {
    banner
    ui_step 1 4 '检查系统版本'
    check_system
    ok "Debian $VER / $ARCH"
    ui_step 2 4 '检查运行环境'
    [[ $EUID -eq 0 ]] || die '请使用 root 用户运行（sudo bash bbr.sh）'
    [[ -t 0 ]] || die '请先下载脚本，再在交互终端运行；不要使用 curl | bash'
    ok 'root 权限与交互终端已就绪'
    ui_step 3 4 '检查系统依赖'
    check_dependencies || die '依赖安装失败，请查看上方软件包管理器输出'
    ok '所需命令已就绪'
    ui_step 4 4 '检测虚拟化环境'
    check_virt
    printf '\n'
    ok '准备完成，进入操作菜单'
    show_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
