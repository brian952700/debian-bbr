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
[[ $(recommend_buffer_mib 512 128 1000 200) == 16 ]] || fail 'small VPS ceiling'
[[ $(recommend_buffer_mib 2048 600 1000 200) == 64 ]] || fail 'large BDP upgrade'
[[ $(recommend_buffer_mib 4096 2048 10000 200) == 128 ]] || fail 'absolute cap'
[[ $(recommend_buffer_mib 4096 2048 100 100) == 32 ]] || fail 'low BDP stays standard'
[[ $(recommend_buffer_mib 4096 2048 0 0) == 32 ]] || fail 'unknown network escalated'
[[ $(recommend_buffer_mib 4096 64 1000 200) == 8 ]] || fail 'memory pressure ignored'
[[ $(recommend_buffer_mib 0 0 1000 200) == 8 ]] || fail 'missing memory escalated'
for invalid in '-1' '0' '1e3' '1;id' '9999999999999' ''; do
    if valid_measurement "$invalid" 100000; then fail 'invalid measurement accepted'; fi
done
valid_measurement 0.5 100000 || fail 'decimal rejected'
write_adaptive_config 67108864 > "$tmp/generated.conf"
grep -Fx 'net.ipv4.tcp_rmem = 4096 131072 67108864' "$tmp/generated.conf" || fail 'wrong buffer'
if grep -Eq 'tcp_mem|conntrack|tcp_max_tw_buckets|tcp_syn_retries|nofile' "$tmp/generated.conf"; then
    fail 'unrelated tuning reintroduced'
fi

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
detect_network 443
[[ "$DETECT_SAMPLES $DETECT_MEDIAN_MS $DETECT_P75_MS" == '5 200.000 250.000' ]] || fail 'diagnostic result'
ss() { return 1; }
detect_network 443
[[ "$DETECT_SAMPLES" == 0 ]] || fail 'ss failure not handled'
tcp_tune <<< $'443\n1\n\n\nn' > "$tmp/cancel.out"
grep -q '已取消，未写入调优配置' "$tmp/cancel.out" || fail 'cancel flow failed'
echo 'PASS: OS, sysctl, kernel safety, adaptive bounds, RTT parsing, detection failure and cancellation'
