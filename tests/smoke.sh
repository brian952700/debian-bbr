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
cat > "$tmp/sysctl.conf" <<'EOF'
# comment

net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl() { printf '%s\n' "$*" >> "$tmp/sysctl.log"; }
sysctl_apply_file "$tmp/sysctl.conf"
grep -Fx -- '-w net.ipv4.tcp_rmem=4096 87380 33554432' "$tmp/sysctl.log" || fail 'lost buffer spaces'
[[ $(wc -l < "$tmp/sysctl.log") == 2 ]] || fail 'bad sysctl count'
sysctl() { return 1; }
if sysctl_apply_file "$tmp/sysctl.conf"; then fail 'hid sysctl failure'; fi
if sysctl_apply_file "$tmp/missing"; then fail 'accepted missing file'; fi

# Running kernel is older than the two newest; all three must survive cleanup.
uname() { echo '6.1.0-18-amd64'; }
dpkg-query() {
    printf '%s\n' \
        'installed linux-image-6.1.0-17-amd64' \
        'installed linux-image-6.1.0-18-amd64' \
        'installed linux-image-6.1.0-19-amd64' \
        'installed linux-image-6.12.0-1-amd64' \
        'config-files linux-image-6.1.0-16-amd64'
}
apt-get() { printf '%s\n' "$*" >> "$tmp/apt.log"; }
remove_old_kernels <<< y
[[ $(cat "$tmp/apt.log") == 'purge -y linux-image-6.1.0-17-amd64' ]] || fail 'unsafe kernel cleanup'
: > "$tmp/apt.log"
remove_old_kernels <<< n
[[ ! -s "$tmp/apt.log" ]] || fail 'ignored cancellation'
dpkg-query() { echo 'installed linux-image-6.1.0-18-amd64'; }
remove_old_kernels < /dev/null
[[ ! -s "$tmp/apt.log" ]] || fail 'removed only kernel'

ss() {
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
[[ $(ss | parse_socket_rtts | rtt_summary) == '5 200.000 250.000' ]] || fail 'RTT parsing/loopback exclusion'
[[ $(printf '' | parse_socket_rtts | rtt_summary) == '0 0 0' ]] || fail 'empty RTT parsing'
effective_memory() { echo '2048 600'; }
ip() { return 0; }
tc() { return 0; }
detect_network
[[ "$DETECT_SAMPLES $DETECT_MEDIAN_MS $DETECT_P75_MS" == '5 200.000 250.000' ]] || fail 'diagnostic result'
ss() { return 1; }
detect_network
[[ "$DETECT_SAMPLES" == 0 ]] || fail 'ss failure not handled'
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
detect_network() { echo 'mock diagnostics'; }
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
echo 'PASS: OS, kernel safety, RTT diagnostics, zero-input tuning, skip cases and rollback'
