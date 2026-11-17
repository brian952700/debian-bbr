#!/usr/bin/env bash
# All mutating system commands below are mocked. No sysctl/apt writes occur.
set -eo pipefail
cd "$(dirname "$0")/.."
source ./bbr.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
for version in 12 12.9 13 13.1 14 20; do
    is_supported_system debian "$version" || fail "rejected Debian $version"
done
for version in 11 10 '' sid testing invalid; do
    if is_supported_system debian "$version"; then fail "accepted Debian $version"; fi
done
for id in ubuntu centos rhel fedora linuxmint; do
    if is_supported_system "$id" 24; then fail "accepted $id"; fi
done
check_system
[[ "$OS" == debian ]] || fail 'wrong OS'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# Keep simulated live sysctl values in files so command substitutions share state.
bbr_conf="$tmp/bbr-test/99-bbr.conf"
bbr_cc_key=net.ipv4.tcp_congestion_control
bbr_qdisc_key=net.core.default_qdisc
mkdir -p -- "${bbr_conf%/*}"
reset_bbr_test() {
    printf '%s\n' 'cubic' > "$tmp/$bbr_cc_key"
    printf '%s\n' 'fq_codel' > "$tmp/$bbr_qdisc_key"
    printf '%s\n' '# prior config' 'net.ipv4.tcp_sack = 1' > "$bbr_conf"
    cp -- "$bbr_conf" "$tmp/bbr-before.conf"
    : > "$tmp/bbr-writes"
}
sysctl() {
    local key="${2%%=*}" value="${2#*=}"
    case "$1" in
        -n) cat -- "$tmp/$key" ;;
        -w)
            printf '%s\n' "$2" >> "$tmp/bbr-writes"
            case "${BBR_TEST_MODE:-ok}:$value" in
                deny_bbr:bbr|deny_fq:fq) return 1 ;;
                missing_fq_readback:fq) return 0 ;;
            esac
            printf '%s\n' "$value" > "$tmp/$key"
            ;;
        *) return 1 ;;
    esac
}

reset_bbr_test
if BBR_TEST_MODE=deny_bbr enable_bbr "$bbr_conf" "$tmp/backup-bbr-denied"; then fail 'rejected BBR reported success'; fi
cmp -s "$bbr_conf" "$tmp/bbr-before.conf" || fail 'rejected BBR changed persistence'
[[ $(cat "$tmp/$bbr_qdisc_key") == fq_codel ]] || fail 'rejected BBR changed queue'
[[ $(cat "$tmp/bbr-writes") == "$bbr_cc_key=bbr" ]] || fail 'rejected BBR led to extra writes'

reset_bbr_test
BBR_TEST_MODE=deny_fq enable_bbr "$bbr_conf" "$tmp/backup-fq-denied"
[[ $(cat "$tmp/$bbr_cc_key") == bbr ]] || fail 'fq rejection prevented BBR'
[[ $(cat "$tmp/$bbr_qdisc_key") == fq_codel ]] || fail 'fq rejection changed queue'
grep -Fxq "$bbr_cc_key = bbr" "$bbr_conf" || fail 'BBR missing from persistent config'
if grep -Fq "$bbr_qdisc_key" "$bbr_conf"; then fail 'rejected fq persisted'; fi
grep -Fxq 'net.ipv4.tcp_sack = 1' "$bbr_conf" || fail 'unrelated config entry removed'

reset_bbr_test
BBR_TEST_MODE=missing_fq_readback enable_bbr "$bbr_conf" "$tmp/backup-fq-unverified"
if grep -Fq "$bbr_qdisc_key" "$bbr_conf"; then fail 'unverified fq persisted'; fi

reset_bbr_test
mv() { return 1; }
if enable_bbr "$bbr_conf" "$tmp/backup-bbr-save-failed"; then fail 'save failure reported success'; fi
unset -f mv
[[ $(cat "$tmp/$bbr_cc_key") == cubic ]] || fail 'BBR was not rolled back'
[[ $(cat "$tmp/$bbr_qdisc_key") == fq_codel ]] || fail 'queue was not rolled back'
cmp -s "$bbr_conf" "$tmp/bbr-before.conf" || fail 'save failure changed persistence'

reset_bbr_test
enable_bbr "$bbr_conf" "$tmp/backup-bbr-ok"
grep -Fxq "$bbr_qdisc_key = fq" "$bbr_conf" || fail 'verified fq missing from config'
: > "$tmp/bbr-writes"
enable_bbr "$bbr_conf" "$tmp/backup-bbr-repeat"
[[ ! -s "$tmp/bbr-writes" && ! -e "$tmp/backup-bbr-repeat" ]] || fail 'unchanged settings re-applied on repeat'
echo 'PASS: BBR and fq verification, rollback and idempotence'

# Running kernel identification, flavour retention and APT's simulated plan.
kernel_case=known
kernel_fallback=available
apt_plan=expected
apt_log="$tmp/kernel-apt.log"
systemd-detect-virt() { [[ "$kernel_case" == container ]]; }
uname() { printf '%s\n' '6.1.0-18-amd64'; }
dpkg-query() {
    case "$1" in
        -S)
            [[ "$kernel_case" != unknown ]] || return 1
            if [[ "$kernel_case" == multiple_owners ]]; then
                printf '%s\n' 'linux-image-6.1.0-18-amd64:amd64, another-package: /boot/vmlinuz-6.1.0-18-amd64'
            elif [[ "$kernel_case" == unsigned ]]; then
                printf '%s\n' 'linux-image-6.1.0-18-amd64-unsigned: /boot/vmlinuz-6.1.0-18-amd64'
            else
                printf '%s\n' 'linux-image-6.1.0-18-amd64:amd64: /boot/vmlinuz-6.1.0-18-amd64'
            fi
            ;;
        -W)
            if [[ "$*" == *'linux-image-amd64' ]]; then
                printf '%s' 'installed'
            elif [[ "$kernel_case" == unsigned ]]; then
                printf '%s\n' \
                    'installed linux-image-6.1.0-16-amd64-unsigned' \
                    'installed linux-image-6.1.0-18-amd64-unsigned' \
                    'installed linux-image-6.1.0-19-amd64-unsigned' \
                    'installed linux-image-6.12.0-1-amd64-unsigned'
            else
                printf '%s\n' \
                    'installed linux-image-6.1.0-17-amd64' \
                    'installed linux-image-6.1.0-18-amd64' \
                    'installed linux-image-6.1.0-19-amd64' \
                    'installed linux-image-6.12.0-1-amd64' \
                    'installed linux-image-6.1.0-15-cloud-amd64' \
                    'installed linux-image-6.1.0-14-amd64-unsigned' \
                    'config-files linux-image-6.1.0-16-amd64'
            fi
            ;;
        *) return 1 ;;
    esac
}
kernel_has_boot_files() { [[ "$kernel_fallback" == available ]]; }
apt-get() {
    if [[ "$1" == -s ]]; then
        case "$apt_plan" in
            expected) printf 'Purg %s [1]\n' "${!#}" ;;
            unexpected) printf 'Purg %s [1]\nPurg linux-image-cloud-amd64 [1]\n' "${!#}" ;;
            reconfigure) printf 'Purg %s [1]\nConf another-package (1)\n' "${!#}" ;;
            unknown) printf 'Unknown operation %s\n' "${!#}" ;;
            failure) return 1 ;;
        esac
    else
        printf '%s\n' "$*" >> "$apt_log"
    fi
}

[[ $(kernel_package_flavour linux-image-6.12.86+deb13.1-cloud-amd64) == cloud-amd64 ]]
[[ $(kernel_package_flavour linux-image-6.1.0-18-amd64-unsigned) == amd64 ]]
remove_old_kernels <<< y
[[ $(cat "$apt_log") == *'purge -- linux-image-6.1.0-17-amd64' ]]
[[ $(cat "$apt_log") == *'APT::Get::Assume-Yes=false'* ]]
: > "$apt_log"
kernel_case=unsigned
remove_old_kernels <<< y
[[ $(cat "$apt_log") == *'purge -- linux-image-6.1.0-16-amd64-unsigned' ]]
: > "$apt_log"
kernel_case=known
remove_old_kernels <<< n
[[ ! -s "$apt_log" ]]
for rejected_plan in unexpected reconfigure unknown failure; do
    apt_plan="$rejected_plan"
    if remove_old_kernels <<< y; then
        printf 'Unsafe APT simulation accepted: %s\n' "$apt_plan" >&2
        exit 1
    fi
    [[ ! -s "$apt_log" ]]
done
apt_plan=expected
kernel_fallback=missing
remove_old_kernels <<< y
[[ ! -s "$apt_log" ]]
kernel_fallback=available
for kernel_case in unknown multiple_owners container; do
    remove_old_kernels <<< y
    upgrade_kernel_debian <<< y
    [[ ! -s "$apt_log" ]]
done
kernel_case=known
df() { printf 'Avail IFree\n250 5000\n'; }
upgrade_kernel_debian <<< y
[[ $(tail -n 1 "$apt_log") == '--no-remove install -y -- linux-image-amd64' ]]
: > "$apt_log"
df() { printf 'Avail IFree\n250 0\n'; }
if upgrade_kernel_debian <<< y; then
    printf '%s\n' 'Kernel update did not stop on zero free inodes' >&2
    exit 1
fi
[[ ! -s "$apt_log" ]]
unset -f df systemd-detect-virt uname dpkg-query apt-get kernel_has_boot_files
printf '%s\n' 'Kernel maintenance checks passed'

read_socket_details() {
    cat <<'EOF'
0 0 192.0.2.1:443 198.51.100.1:50000
    cubic rtt:100/10 cwnd:10
0 0 192.0.2.1:443 198.51.100.2:50000
    bbr rtt:150/10 cwnd:10
0 0 [2001:db8::1]:443 [2001:db8::2]:50000
    bbr rtt:200/10 cwnd:10
0 0 192.0.2.1:443 198.51.100.3:50000
    bbr rtt:250/10 cwnd:10
0 0 192.0.2.1:443 198.51.100.4:50000
    bbr rtt:300/10 cwnd:10
0 0 127.0.0.1:443 127.0.0.1:50000
    cubic rtt:0.001/0.001
0 0 [::1]:443 [::1]:50000
    cubic rtt:0.001/0.001
EOF
}
[[ $(read_socket_details | parse_socket_rtts 512 | rtt_summary) == '5 200.000 250.000' ]] || fail 'RTT parsing/loopback exclusion'
[[ $(printf '' | parse_socket_rtts 512 | rtt_summary) == '0 0 0' ]] || fail 'empty RTT parsing'
[[ $(printf '10\n90\n' | rtt_summary) == '2 50.000 90.000' ]] || fail 'incorrect median for even samples'
[[ $(read_socket_details | parse_socket_rtts 2 | rtt_summary) == '2 125.000 150.000' ]] || fail 'RTT sample limit ignored'
effective_memory() { echo '2048 600'; }
ip() { return 0; }
tc() { return 0; }
detect_network
[[ "$DETECT_SAMPLES $DETECT_MEDIAN_MS $DETECT_P75_MS" == '5 200.000 250.000' ]] || fail 'diagnostic result'
read_socket_details() { return 124; }
detect_network
[[ "$DETECT_SAMPLES" == 0 ]] || fail 'ss timeout not handled'
sysctl() {
    if [[ "$1" == -n ]]; then
        [[ ${AUTO_MODE:-ok} != unreadable ]] || return 1
        cat "$tmp/auto-state"
    elif [[ "$1" == -w ]]; then
        printf '%s\n' "$2" >> "$tmp/auto-writes"
        [[ ${AUTO_MODE:-ok} != deny ]] || return 1
        [[ ${AUTO_MODE:-ok} != no_effect ]] || return 0
        printf '%s\n' "${2##*=}" > "$tmp/auto-state"
    else
        return 1
    fi
}
echo 0 > "$tmp/auto-state"
plan=$(build_auto_tcp_plan)
[[ "$plan" == 'net.ipv4.tcp_moderate_rcvbuf = 1' ]] || fail 'disabled auto tuning not detected'
echo 1 > "$tmp/auto-state"
[[ -z $(build_auto_tcp_plan) ]] || fail 'already enabled not skipped'
echo unexpected > "$tmp/auto-state"
[[ -z $(build_auto_tcp_plan) ]] || fail 'unknown value not skipped'
AUTO_MODE=unreadable
[[ -z $(build_auto_tcp_plan) ]] || fail 'unreadable value not skipped'
AUTO_MODE=ok
echo 0 > "$tmp/auto-state"
mkdir -p "$tmp/conf"
apply_auto_tcp_plan "$plan" "$tmp/conf/auto.conf" "$tmp/backups" < /dev/null
[[ $(cat "$tmp/auto-state") == 1 ]] || fail 'auto tuning not enabled'
grep -Fx "$plan" "$tmp/conf/auto.conf" || fail 'not persisted'
grep -Fx 'net.ipv4.tcp_moderate_rcvbuf = 0' "$tmp"/backups/*/runtime-before.conf || fail 'missing runtime backup'
markers=("$tmp"/backups/*/no-previous-config)
[[ -f "${markers[0]}" ]] || fail 'missing absence marker'

echo 'previous config' > "$tmp/conf/auto.conf"
echo 0 > "$tmp/auto-state"
AUTO_MODE=deny
if apply_auto_tcp_plan "$plan" "$tmp/conf/auto.conf" "$tmp/denied" < /dev/null; then fail 'denied write reported success'; fi
[[ $(cat "$tmp/conf/auto.conf") == 'previous config' ]] || fail 'denied write changed persistence'
AUTO_MODE=no_effect
if apply_auto_tcp_plan "$plan" "$tmp/conf/auto.conf" "$tmp/no-effect" < /dev/null; then fail 'unverified write persisted'; fi
[[ $(cat "$tmp/conf/auto.conf") == 'previous config' ]] || fail 'no-effect write changed persistence'
AUTO_MODE=ok
mv() { return 1; }
if apply_auto_tcp_plan "$plan" "$tmp/conf/auto.conf" "$tmp/save-failure" < /dev/null; then fail 'save failure hidden'; fi
[[ $(cat "$tmp/auto-state") == 0 ]] || fail 'save failure did not restore runtime'
[[ $(cat "$tmp/conf/auto.conf") == 'previous config' ]] || fail 'save failure changed persistence'
unset -f mv

# The menu action must not read stdin or require user-supplied measurements.
detect_network() { fail 'menu option 2 triggered network diagnostics'; }
apply_auto_tcp_plan() { printf '%s\n' "$1" >> "$tmp/menu-applies"; }
echo 0 > "$tmp/auto-state"
tcp_tune < /dev/null
[[ $(cat "$tmp/menu-applies") == "$plan" ]] || fail 'noninteractive menu did not apply'
: > "$tmp/menu-applies"
echo 1 > "$tmp/auto-state"
tcp_tune < /dev/null
[[ ! -s "$tmp/menu-applies" ]] || fail 'enabled value not skipped by menu'
AUTO_MODE=unreadable
tcp_tune < /dev/null
[[ ! -s "$tmp/menu-applies" ]] || fail 'unreadable value not skipped by menu'

# Ordinary redraws reuse status; explicit refresh fetches a new snapshot.
show_status() { printf "status\n" >> "$tmp/status-calls"; }
detect_network() { printf "diagnostics\n" >> "$tmp/diagnostic-calls"; }
show_menu > "$tmp/menu-output" <<'EOF'
invalid
5

0
EOF
[[ $(wc -l < "$tmp/status-calls") == 2 ]] || fail 'menu did not reuse cached status or refresh exactly once'
[[ $(wc -l < "$tmp/diagnostic-calls") == 1 ]] || fail 'explicit diagnostics did not run once'
grep -Fq "已退出" "$tmp/menu-output" || fail 'menu refresh did not return to the input prompt'
echo 'PASS: OS, BBR and TCP rollback, kernel safety, RTT diagnostics and menu refresh'
