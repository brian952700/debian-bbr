#!/usr/bin/env bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

#=================================================
#   System  : Debian 12 / 13 and later
#   Desc    : BBR一键加速 + TCP深度调优
#   Version : 3.4.0-debian
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

sh_ver="3.4.0-debian"

ui_log() { printf '  %s[%s]%s %s\n' "$1" "$2" "$PLAIN" "$3"; }
info()  { ui_log "$BLUE" '信息' "$*"; }
ok()    { ui_log "$GREEN" '完成' "$*"; }
warn()  { ui_log "$YELLOW" '提醒' "$*"; }
skip()  { ui_log "$YELLOW" '跳过' "$*"; }
error() { ui_log "$RED" '失败' "$*"; }
die()   { error "$*"; exit 1; }

hr() {
    local width=68 line
    if [[ ${UI_COLUMNS:-} =~ ^[0-9]{2,3}$ ]]; then
        width=$((10#$UI_COLUMNS - 4))
        if (( width < 32 )); then width=32; fi
        if (( width > 68 )); then width=68; fi
    fi
    printf -v line '%*s' "$width" ''
    printf '  %s%s%s\n' "$DIM" "${line// /─}" "$PLAIN"
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

# ────────────────────────── 依赖检查与安装 ──────────────────────────
check_dependencies() {
    local deps=()
    command -v sysctl &>/dev/null || deps+=(procps)
    command -v flock &>/dev/null || deps+=(util-linux)
    if ! command -v ip &>/dev/null || ! command -v ss &>/dev/null || ! command -v tc &>/dev/null; then
        deps+=(iproute2)
    fi
    if (( ${#deps[@]} )); then
        info "正在安装缺少的依赖：${deps[*]}"
        ui_detail "软件包管理器输出如下；完成后会自动继续。"
        apt-get update && apt-get install -y "${deps[@]}" || return 1
    fi
}

# 只锁定写入操作。锁随子 shell 退出释放，避免两个会话互相覆盖备份。
with_sysctl_lock() (
    local lock_fd
    exec {lock_fd}>>/run/debian-bbr-sysctl.lock || { error '无法打开配置锁'; return 1; }
    flock -n "$lock_fd" || { warn '配置操作暂不可用，请稍后再试'; return 1; }
    "$@"
)

# 使用 systemd 的实际文件顺序，报告最后一条可能覆盖本次设置的规则。
warn_sysctl_conflicts() {
    local conf_file="$1" key="$2" expected="$3" config override
    [[ -x /lib/systemd/systemd-sysctl ]] || return 0
    config=$(/lib/systemd/systemd-sysctl --cat-config --no-pager 2>/dev/null) || return 0
    override=$(LC_ALL=C awk -v target="${conf_file##*/}" -v key="$key" -v expected="$expected" '
        /^# \// {
            file=substr($0,3)
            name=file
            sub(/^.*\//,"",name)
            next
        }
        name > target && index($0,"=") {
            split_at=index($0,"=")
            setting=substr($0,1,split_at-1)
            value=substr($0,split_at+1)
            gsub(/[[:space:]]/,"",setting)
            sub(/^-/,"",setting)
            gsub(/\//,".",setting)
            sub(/^[[:space:]]+/,"",value)
            sub(/[[:space:]]+$/,"",value)
            if (setting==key) {
                last_file=file
                last_value=value
            }
        }
        END {if (last_file!="" && last_value!=expected) print last_file " (" last_value ")"}
    ' <<< "$config")
    if [[ -n "$override" ]]; then
        warn "启动时 $key 可能被后加载的配置覆盖"
        ui_detail "$override"
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
    fi
}

# 恢复单项运行值。未发生变化时避免无谓的写入。
restore_bbr_setting() {
    local key="$1" before="$2" current
    current=$(sysctl -n "$key" 2>/dev/null) || current=''
    [[ "$current" == "$before" ]] && return 0
    if ! sysctl -w "$key=$before" >/dev/null 2>&1 ||
       [[ $(sysctl -n "$key" 2>/dev/null) != "$before" ]]; then
        error "恢复 $key 失败，请检查运行值。"
        return 1
    fi
}

# 在子 shell 内管理临时文件和回滚，避免影响其他菜单项的信号处理。
enable_bbr() (
    local conf_file="${1:-/etc/sysctl.d/99-bbr.conf}" backup_root="${2:-/var/backups}"
    local cc_key=net.ipv4.tcp_congestion_control qdisc_key=net.core.default_qdisc
    local before_cc before_qdisc staged state_dir apply_error
    local changed_cc=0 changed_qdisc=0 fq_verified=0

    before_cc=$(sysctl -n "$cc_key" 2>/dev/null) || before_cc=''
    [[ -n "$before_cc" ]] || { error '无法读取当前拥塞控制，已跳过 BBR 配置。'; exit 1; }
    before_qdisc=$(sysctl -n "$qdisc_key" 2>/dev/null) || before_qdisc=''
    if [[ -L "$conf_file" || ( -e "$conf_file" && ! -f "$conf_file" ) ]]; then
        error "配置路径不是普通文件：$conf_file"
        exit 1
    fi

    mkdir -p -- "$(dirname -- "$conf_file")" || exit 1
    staged=$(mktemp -- "${conf_file}.XXXXXXXX") || exit 1
    # 同目录原子替换成功后，临时文件路径即不存在。
    trap 'if [[ -e "$staged" ]]; then
        if (( changed_qdisc )); then restore_bbr_setting "$qdisc_key" "$before_qdisc" || true; fi
        if (( changed_cc )); then restore_bbr_setting "$cc_key" "$before_cc" || true; fi
        rm -f -- "$staged"
    fi' EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    if [[ -f "$conf_file" ]]; then
        # 只替换本操作涉及的两项，保留旧版文件中的其他设置。
        awk '
            /^[[:space:]]*-?[[:space:]]*net[.\/]ipv4[.\/]tcp_congestion_control[[:space:]]*=/ {next}
            /^[[:space:]]*-?[[:space:]]*net[.\/]core[.\/]default_qdisc[[:space:]]*=/ {next}
            {print}
        ' "$conf_file" > "$staged" || exit 1
    else
        printf '# Debian BBR\n' > "$staged" || exit 1
    fi
    printf '%s = bbr\n' "$cc_key" >> "$staged" || exit 1
    if [[ "$before_qdisc" == fq ]]; then
        fq_verified=1
        printf '%s = fq\n' "$qdisc_key" >> "$staged" || exit 1
    fi

    if [[ "$before_cc" == bbr && ( "$before_qdisc" == fq || -z "$before_qdisc" ) ]] &&
       cmp -s -- "$staged" "$conf_file"; then
        ok 'BBR 已启用，持久配置无需更新。'
        if (( fq_verified )); then
            ok '默认队列已设置为 fq。'
            warn_sysctl_conflicts "$conf_file" "$qdisc_key" fq || true
        else
            skip '无法读取默认队列，已保留当前设置。'
        fi
        warn_sysctl_conflicts "$conf_file" "$cc_key" bbr || true
        exit 0
    fi

    mkdir -p -- "$backup_root" || exit 1
    state_dir=$(mktemp -d -- "$backup_root/debian-bbr.XXXXXXXX") || exit 1
    if [[ -f "$conf_file" ]]; then
        cp -a -- "$conf_file" "$state_dir/" || exit 1
    else
        touch -- "$state_dir/no-previous-config" || exit 1
    fi
    {
        printf '%s = %s\n' "$cc_key" "$before_cc"
        if [[ -n "$before_qdisc" ]]; then printf '%s = %s\n' "$qdisc_key" "$before_qdisc"; fi
    } > "$state_dir/runtime-before.conf" || exit 1
    info "备份目录：$state_dir"

    if [[ "$before_cc" != bbr ]]; then
        changed_cc=1
        if ! apply_error=$(sysctl -w "$cc_key=bbr" 2>&1) ||
           [[ $(sysctl -n "$cc_key" 2>/dev/null) != bbr ]]; then
            error '当前内核未能启用 BBR，请检查模块和容器权限。'
            [[ -z "$apply_error" ]] || ui_detail "$apply_error"
            exit 1
        fi
    fi

    if [[ -n "$before_qdisc" && "$before_qdisc" != fq ]]; then
        changed_qdisc=1
        if apply_error=$(sysctl -w "$qdisc_key=fq" 2>&1) &&
           [[ $(sysctl -n "$qdisc_key" 2>/dev/null) == fq ]]; then
            fq_verified=1
            printf '%s = fq\n' "$qdisc_key" >> "$staged" || exit 1
        else
            restore_bbr_setting "$qdisc_key" "$before_qdisc" || exit 1
            changed_qdisc=0
            skip 'fq 未能生效，保留原默认队列。'
            [[ -z "$apply_error" ]] || ui_detail "$apply_error"
        fi
    fi

    if ! chmod 644 -- "$staged" || ! mv -fT -- "$staged" "$conf_file"; then
        error '保存 BBR 配置失败，正在恢复运行值。'
        exit 1
    fi
    ok 'BBR 已启用并保存。'
    warn_sysctl_conflicts "$conf_file" "$cc_key" bbr || true
    if (( fq_verified )); then
        ok '默认队列已设置为 fq。'
        warn_sysctl_conflicts "$conf_file" "$qdisc_key" fq || true
    elif [[ -z "$before_qdisc" ]]; then
        skip '无法读取默认队列，已保留当前设置。'
    fi
)

# 只读诊断：不测速、不扫描第三方节点、不读取代理账号或证书。
parse_socket_rtts() {
    awk -v limit="$1" '
        /^[^ \t]/ && !/rtt:/ {
            skip = ($0 ~ /(^|[ \t])(127\.|\[?::1\]?:|\[?::ffff:127\.)/)
            next
        }
        !skip && count < limit {
            for (i=1; i<=NF; i++) if ($i ~ /^rtt:[0-9]/) {
                split($i, p, ":"); split(p[2], r, "/")
                if (r[1]+0 > 0) {
                    print r[1]+0
                    count++
                    break
                }
            }
        }'
}

rtt_summary() {
    sort -n | awk '{a[NR]=$1} END {
        if (NR) {
            middle = (a[int((NR+1)/2)] + a[int(NR/2)+1])/2
            printf "%d %.3f %.3f\n", NR, middle, a[int((NR*3+3)/4)]
        } else print "0 0 0"
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

read_socket_details() {
    timeout --kill-after=1s 3s ss -Htin state established
}

detect_network() {
    local dev="" speed="" summary queues rxdrop txdrop
    local max_samples=512
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
    if summary=$(
        set -o pipefail
        export LC_ALL=C
        read_socket_details 2>/dev/null | parse_socket_rtts "$max_samples" | rtt_summary
    ); then
        read -r DETECT_SAMPLES DETECT_MEDIAN_MS DETECT_P75_MS <<< "$summary"
    else
        DETECT_SAMPLES=0 DETECT_MEDIAN_MS=0 DETECT_P75_MS=0
        warn 'TCP 连接读取超时或失败，略过 RTT 摘要'
    fi
    if (( DETECT_SAMPLES > 0 )); then
        ui_kv '连接样本' "${DETECT_SAMPLES} 个（排除回环）"
        ui_kv 'RTT 摘要' "中位数 ${DETECT_MEDIAN_MS} ms / P75 ${DETECT_P75_MS} ms"
        if (( DETECT_SAMPLES == max_samples )); then
            ui_detail "显示前 $max_samples 个有效样本。"
        fi
        ui_detail '全机连接快照，仅作诊断。'
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
    if [[ -L "$conf_file" || ( -e "$conf_file" && ! -f "$conf_file" ) ]]; then
        error "配置路径不是普通文件：$conf_file"
        return 1
    fi
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
    if ! mv -fT -- "$staged" "$conf_file"; then
        sysctl -w "net.ipv4.tcp_moderate_rcvbuf=$before" >/dev/null 2>&1 || warn "运行值恢复失败，请检查系统限制"
        rm -f -- "$staged"
        return 1
    fi
    ok '已开启内核接收缓冲区自动调节'
    ui_detail '具体大小由内核按连接与现有上限决定。'
    info "配置已保存，备份已完成"
    ui_detail "配置：$conf_file"
    ui_detail "备份：$state_dir"
    warn_sysctl_conflicts "$conf_file" net.ipv4.tcp_moderate_rcvbuf 1
    printf '\n'
    ui_detail '需要恢复时，可执行以下命令：'
    ui_detail "sysctl -p $state_dir/runtime-before.conf"
    ui_detail '持久配置恢复方法见 README，备份文件已保留。'
}

tcp_tune() {
    local plan
    ui_step 1 2 '检查接收缓冲区自动调节'
    plan=$(build_auto_tcp_plan) || return 1
    if [[ -f /etc/sysctl.d/99-tcp-tune.conf ]]; then
        warn "发现旧版调优配置；本次保留，旧参数不会自动恢复。恢复方法见 README。"
    fi
    if [[ -z "$plan" ]]; then
        ui_step 2 2 '执行结果'
        skip '无需调整：参数已开启，或系统不支持可靠检测'
        ui_detail '本次未写入配置。'
        return 0
    fi
    ui_step 2 2 '备份并应用自动适配'
    info '检测到接收缓冲区自动调节已关闭，正在开启'
    apply_auto_tcp_plan "$plan" /etc/sysctl.d/99-tcp-auto.conf /var/backups
}

# Debian 内核维护。只有能识别正在运行的 Debian 内核包时才操作。
kernel_maintenance_available() {
    if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --container --quiet; then
        warn '容器共享宿主机内核，跳过内核维护。'
        return 1
    fi
    case "${virt_type:-}" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|proot|rkt|pouch)
            warn '容器共享宿主机内核，跳过内核维护。'
            return 1
            ;;
    esac
    return 0
}

kernel_current_package() {
    local release image owner
    release=$(uname -r) || return 1
    image="/boot/vmlinuz-$release"
    owner=$(dpkg-query -S -- "$image" 2>/dev/null) || return 1
    # Reject multiple owners/diversions and require an exact path match.
    [[ "$owner" != *$'\n'* && "$owner" == *": $image" ]] || return 1
    owner="${owner%": $image"}"
    owner="${owner%%:*}"
    case "$owner" in
        "linux-image-$release"|"linux-image-$release-unsigned") printf '%s\n' "$owner" ;;
        *) return 1 ;;
    esac
}

kernel_package_flavour() {
    local name="${1%-unsigned}"
    # Debian 12: 6.1.0-34-amd64. Debian 13: 6.12.86+deb13-cloud-amd64.
    [[ "$name" =~ ^linux-image-[0-9]+(\.[0-9]+)+(-[0-9]+|\+deb[0-9]+(\.[0-9]+)*)?-(.+)$ ]] || return 1
    case "${BASH_REMATCH[4]}" in
        amd64|cloud-amd64|rt-amd64|arm64|arm64-16k|cloud-arm64|rt-arm64|armmp|armmp-lpae|rt-armmp|686|686-pae|riscv64|s390x|powerpc64le|powerpc64le-64k)
            printf '%s\n' "${BASH_REMATCH[4]}"
            ;;
        *) return 1 ;;
    esac
}

kernel_check_boot_space() {
    local space mib inodes
    if ! space=$(LC_ALL=C df -m --output=avail,iavail /boot 2>/dev/null); then
        error '无法读取 /boot 的剩余空间，本次升级已停止。'
        return 1
    fi
    read -r mib inodes < <(printf '%s\n' "$space" | awk 'NR == 2 { print $1, $2 }')
    if [[ ! "$mib" =~ ^[0-9]+$ || ! "$inodes" =~ ^[0-9]+$ ]]; then
        error '无法确认 /boot 剩余空间或 inode，本次升级已停止。'
        return 1
    fi
    info "/boot 当前可用 ${mib} MiB，剩余 inode ${inodes}。"
    if (( mib < 100 || inodes == 0 )); then
        warn '/boot 可用空间不足，本次升级已停止。'
        return 1
    fi
}

upgrade_kernel_debian() {
    local current flavour package confirm
    kernel_maintenance_available || return 0
    if ! current=$(kernel_current_package) || ! flavour=$(kernel_package_flavour "$current"); then
        warn '无法识别当前内核类型，跳过自动升级。'
        return 0
    fi
    package="linux-image-$flavour"
    if [[ "$current" == *-unsigned ||
          $(dpkg-query -W -f='${db:Status-Status}' -- "$package" 2>/dev/null) != installed ]]; then
        warn '无法确认已安装、且与当前内核匹配的升级元包，跳过自动升级。'
        return 0
    fi
    info "将通过当前软件源更新已安装的 $package。"
    read -rp "$(ui_prompt '确认更新内核？[y/N]：')" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    kernel_check_boot_space || return 1
    apt-get update && apt-get --no-remove install -y -- "$package" || { error '内核更新失败。'; return 1; }
    ok '内核包处理完成。如安装了新内核，请安排重启后检查。'
}

kernel_has_boot_files() {
    local release="${1#linux-image-}"
    release="${release%-unsigned}"
    [[ -s "/boot/vmlinuz-$release" && -s "/boot/initrd.img-$release" ]]
}

kernel_simulate_purge() {
    local simulation action package rest
    local -A expected=() planned=()
    for package in "$@"; do expected["$package"]=1; done
    if ! simulation=$(LC_ALL=C apt-get -s -o APT::Get::AutomaticRemove=false purge -- "$@" 2>&1); then
        error 'APT 清理预检失败。'
        ui_detail "$simulation"
        return 1
    fi
    while read -r action package rest; do
        case "$action" in
            Remv|Purg)
                package="${package%%:*}"
                if [[ -z "$package" || ! ${expected[$package]+present} ]]; then
                    error "APT 计划额外删除 ${package:-未知包}，清理已停止。"
                    return 1
                fi
                planned["$package"]=1
                ;;
            Conf|Inst)
                error "APT 计划安装或配置 ${package:-未知包}，清理已停止。"
                return 1
                ;;
        esac
    done <<< "$simulation"
    for package in "$@"; do
        if [[ ! ${planned[$package]+present} ]]; then
            error "无法确认 APT 会清理 $package，清理已停止。"
            return 1
        fi
    done
}

remove_old_kernels() {
    local current flavour package package_flavour installed state confirm fallback='' found_current=0
    local -a kernels=() remove=()
    kernel_maintenance_available || return 0
    if ! current=$(kernel_current_package) || ! flavour=$(kernel_package_flavour "$current"); then
        warn '无法确认当前内核对应的 Debian 软件包，跳过清理。'
        return 0
    fi
    if ! installed=$(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' 'linux-image-[0-9]*' 2>/dev/null); then
        warn '无法读取已安装的内核包，跳过清理。'
        return 0
    fi
    while read -r state package; do
        [[ "$state" == installed ]] || continue
        package="${package%%:*}"
        package_flavour=$(kernel_package_flavour "$package") || continue
        [[ "$package_flavour" == "$flavour" ]] || continue
        # Preserve other kernel variants, including a different signing type.
        if [[ "$current" == *-unsigned ]]; then
            [[ "$package" == *-unsigned ]] || continue
        else
            [[ "$package" != *-unsigned ]] || continue
        fi
        [[ "$package" != "$current" ]] || found_current=1
        kernels+=("$package")
    done <<< "$installed"
    if (( ! found_current )); then
        warn '运行内核的软件包未处于已安装状态，跳过清理。'
        return 0
    fi
    if (( ${#kernels[@]} <= 2 )); then
        info '当前内核类型没有足够的版本可清理。'
        return 0
    fi
    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "${kernels[@]}" | LC_ALL=C sort -Vu)
    local index keep_from
    keep_from=$(( ${#sorted[@]} - 2 ))
    for (( index=0; index<${#sorted[@]}; ++index )); do
        package="${sorted[index]}"
        [[ "$package" == "$current" ]] && continue
        if (( index >= keep_from )); then
            if kernel_has_boot_files "$package"; then fallback="$package"; fi
        else
            remove+=("$package")
        fi
    done
    if (( ! ${#remove[@]} )); then
        info '没有需要清理的内核包。'
        return 0
    fi
    if [[ -z "$fallback" ]]; then
        warn '在保留的内核中未找到完整的备用镜像和 initramfs，跳过清理。'
        return 0
    fi
    kernel_simulate_purge "${remove[@]}" || return 1
    info "保留当前内核 $current 及配有启动文件的备用内核 $fallback。"
    info 'APT 预检通过，待清理软件包如下。'
    printf '  %s\n' "${remove[@]}"
    read -rp "$(ui_prompt '进入 APT 删除确认？[y/N]：')" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    # Prompt again using the actual plan, since the simulation held no package lock.
    apt-get -o APT::Get::AutomaticRemove=false -o APT::Get::Assume-Yes=false -o quiet=0 purge -- "${remove[@]}" ||
        { error '内核清理已取消或失败。'; return 1; }
    ok '内核清理完成。'
}

show_status() {
    local cc qdisc auto bbr_status auto_status
    IFS= read -r cc 2>/dev/null < /proc/sys/net/ipv4/tcp_congestion_control || cc='不可读取'
    IFS= read -r qdisc 2>/dev/null < /proc/sys/net/core/default_qdisc || qdisc='不可读取'
    IFS= read -r auto 2>/dev/null < /proc/sys/net/ipv4/tcp_moderate_rcvbuf || auto='未知'
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

render_menu() {
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
    printf '  %s5%s  刷新状态与网络诊断\n' "$CYAN" "$PLAIN"
    printf '  %s0%s  退出\n' "$DIM" "$PLAIN"
}

show_menu() {
    local choice menu=''
    while true; do
        if [[ -z "$menu" ]]; then
            menu=$(render_menu) || return 1
        fi
        printf '%s\n' "$menu"
        read -rp "$(ui_prompt '输入编号 [0–5]：')" choice || return 0
        case "$choice" in
            1) run_action '开启 BBR' with_sysctl_lock enable_bbr ;;
            2) run_action 'TCP 自动检测与适配' with_sysctl_lock tcp_tune ;;
            3) run_action '更新 Debian 内核' upgrade_kernel_debian ;;
            4) run_action '清理旧内核' remove_old_kernels ;;
            5) run_action '网络诊断' detect_network ;;
            0) printf '\n'; info '已退出。配置结果已保留。'; printf '\n'; return 0 ;;
            *) warn '请输入 0 到 5 之间的编号。'; continue ;;
        esac
        case "$choice" in
            1|2|5) menu='' ;;
        esac
        [[ "$choice" == 2 ]] && continue
        read -rp "$(ui_prompt '按 Enter 返回菜单…')" _ || return 0
    done
}

main() {
    local virt_type
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
