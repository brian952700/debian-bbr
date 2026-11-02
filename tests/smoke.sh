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
sysctl() { printf '%s
' "$*" >> "$tmp/sysctl.log"; }
sysctl_apply_file "$tmp/sysctl.conf"
grep -Fx -- '-w net.ipv4.tcp_rmem=4096 87380 33554432' "$tmp/sysctl.log" || fail 'lost buffer spaces'
[[ $(wc -l < "$tmp/sysctl.log") == 2 ]] || fail 'bad sysctl count'
sysctl() { return 1; }
if sysctl_apply_file "$tmp/sysctl.conf"; then fail 'hid sysctl failure'; fi
if sysctl_apply_file "$tmp/missing"; then fail 'accepted missing file'; fi

# Running kernel is older than the two newest; all three must survive cleanup.
uname() { echo '6.1.0-18-amd64'; }
dpkg-query() {
    printf '%s
'         'installed linux-image-6.1.0-17-amd64'         'installed linux-image-6.1.0-18-amd64'         'installed linux-image-6.1.0-19-amd64'         'installed linux-image-6.12.0-1-amd64'         'config-files linux-image-6.1.0-16-amd64'
}
apt-get() { printf '%s
' "$*" >> "$tmp/apt.log"; }
remove_old_kernels <<< y
[[ $(cat "$tmp/apt.log") == 'purge -y linux-image-6.1.0-17-amd64' ]] || fail 'unsafe kernel cleanup'
: > "$tmp/apt.log"
remove_old_kernels <<< n
[[ ! -s "$tmp/apt.log" ]] || fail 'ignored cancellation'
dpkg-query() { echo 'installed linux-image-6.1.0-18-amd64'; }
remove_old_kernels < /dev/null
[[ ! -s "$tmp/apt.log" ]] || fail 'removed only kernel'
echo 'PASS: OS guard, sysctl parsing/errors, kernel retention/cancellation'
