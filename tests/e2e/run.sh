#!/bin/bash
# End-to-end test of the Kyn VPN Linux client in an Ubuntu VM, against a mock
# backend (tests/e2e/mockworld) that is the VM's entire network.
#
#   tests/e2e/run.sh [--installer kyn-linux-….run] [--arch arm64|x86_64]
#                    [--keep] [--verbose] [--timeout SECS]
#
# Without --installer, the installer of the latest GitHub release for the
# VM's architecture is downloaded. The first run also builds a base image
# (Ubuntu 24.04 cloud image plus the client's dependencies) with internet
# access; it's cached in ~/.cache/kynvpn-e2e. Test runs themselves have no
# internet: only mockworld.
#
# Exit status: 0 if every step passed, 1 if any failed, 2 on timeout or a
# setup problem. The report and logs are left in the printed work directory.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
cache=${KYN_E2E_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kynvpn-e2e}
ubuntu_release=noble

installer=""
arch=""
keep=0
verbose=""
timeout=1200
while [ $# -gt 0 ]; do
    case "$1" in
        --installer) installer=$2; shift 2 ;;
        --arch) arch=$2; shift 2 ;;
        --keep) keep=1; shift ;;
        --verbose) verbose=--verbose; shift ;;
        --timeout) timeout=$2; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "e2e: $*" >&2; exit 2; }
say() { echo "e2e: $*" >&2; }

host_arch=$(uname -m)
case "$host_arch" in arm64|aarch64) host_arch=arm64 ;; x86_64|amd64) host_arch=x86_64 ;; esac
arch=${arch:-$host_arch}
case "$arch" in
    arm64) qemu=qemu-system-aarch64; img_arch=arm64 ;;
    x86_64) qemu=qemu-system-x86_64; img_arch=amd64 ;;
    *) die "unsupported --arch $arch" ;;
esac
command -v "$qemu" > /dev/null || die "$qemu not found (install QEMU)"
command -v qemu-img > /dev/null || die "qemu-img not found"
command -v cargo > /dev/null || die "cargo not found"
command -v openssl > /dev/null || die "openssl not found"
command -v python3 > /dev/null || die "python3 not found"

mkdir -p "$cache"
work=$(mktemp -d "${TMPDIR:-/tmp}/kynvpn-e2e.XXXXXX")
say "work directory: $work"
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2> /dev/null || true; done
    wait 2> /dev/null || true
    [ "$keep" = 1 ] || rm -f "$work"/*.qcow2 "$work"/vars.fd
}
trap cleanup EXIT

# --- QEMU ---------------------------------------------------------------------
accel=tcg
cpu=max
if [ "$arch" = "$host_arch" ]; then
    if [ "$(uname -s)" = Darwin ]; then accel=hvf; cpu=host
    elif [ -w /dev/kvm ]; then accel=kvm; cpu=host
    fi
fi
[ "$accel" = tcg ] && say "no hardware acceleration for $arch; this will be slow"

qemu_share=""
for d in "$(dirname "$(command -v "$qemu")")/../share/qemu" /usr/share/qemu /usr/local/share/qemu; do
    [ -d "$d" ] && { qemu_share=$d; break; }
done

# Arguments shared by the base-image build and the test run.
qemu_args() { # disk netdev-args smbios-seed-url console-log
    local -a a
    if [ "$arch" = arm64 ]; then
        local fw=""
        for f in "$qemu_share/edk2-aarch64-code.fd" /usr/share/AAVMF/AAVMF_CODE.fd \
                 /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
            [ -f "$f" ] && { fw=$f; break; }
        done
        [ -n "$fw" ] || die "no aarch64 UEFI firmware found (edk2-aarch64-code.fd / AAVMF)"
        local fwsize
        fwsize=$(wc -c < "$fw")
        rm -f "$work/vars.fd"
        dd if=/dev/zero of="$work/vars.fd" bs=1 count=0 seek="$fwsize" 2> /dev/null
        if [ "$fwsize" -lt 67108864 ]; then
            # Plain QEMU_EFI.fd: pad to the pflash size.
            cp "$fw" "$work/code.fd"
            dd if=/dev/zero of="$work/code.fd" bs=1 count=0 seek=67108864 2> /dev/null
            dd if=/dev/zero of="$work/vars.fd" bs=1 count=0 seek=67108864 2> /dev/null
            fw=$work/code.fd
        fi
        a+=(-machine virt -cpu "$cpu" -accel "$accel"
            -drive "if=pflash,format=raw,readonly=on,file=$fw"
            -drive "if=pflash,format=raw,file=$work/vars.fd")
    else
        a+=(-machine q35 -cpu "$cpu" -accel "$accel")
    fi
    a+=(-smp 4 -m 4096
        -drive "if=virtio,format=qcow2,file=$1"
        -netdev "$2" -device virtio-net-pci,netdev=n0,mac=52:54:00:4b:59:4e
        -smbios "type=1,serial=ds=nocloud;s=$3"
        -display none -serial "file:$4" -monitor none)
    printf '%s\0' "${a[@]}"
}

run_qemu() { # same args as qemu_args; runs in the background, sets qemu_pid
    local -a a=()
    while IFS= read -r -d '' x; do a+=("$x"); done < <(qemu_args "$@")
    "$qemu" "${a[@]}" &
    qemu_pid=$!
    pids+=("$qemu_pid")
}

# --- Base image -----------------------------------------------------------------
packages="libxkbcommon-x11-0 libnl-3-200 libnl-route-3-200 libnl-genl-3-200 iptables psmisc libatomic1 xterm curl dnsutils jq"
base_img="$cache/$ubuntu_release-server-cloudimg-$img_arch.img"
golden="$cache/golden-$ubuntu_release-$img_arch-$(echo "$packages" | shasum | cut -c1-10).qcow2"

if [ ! -f "$golden" ]; then
    if [ ! -f "$base_img" ]; then
        url="https://cloud-images.ubuntu.com/$ubuntu_release/current/$ubuntu_release-server-cloudimg-$img_arch.img"
        say "downloading $url"
        curl -fL --progress-bar -o "$base_img.part" "$url" && mv "$base_img.part" "$base_img"
    fi
    say "building the base image (Ubuntu $ubuntu_release + client dependencies); this needs internet, once"
    tmp_golden="$golden.part"
    qemu-img convert -O qcow2 "$base_img" "$tmp_golden"
    qemu-img resize -q "$tmp_golden" 10G
    seed="$work/golden-seed"
    mkdir -p "$seed"
    echo "instance-id: kyn-e2e-golden" > "$seed/meta-data"
    : > "$seed/vendor-data"
    cat > "$seed/user-data" <<EOF
#cloud-config
package_update: true
packages: [$(echo "$packages" | sed 's/ /, /g')]
runcmd:
  - systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer snapd.service snapd.socket snapd.seeded.service || true
  - echo KYN-E2E-GOLDEN-OK > /dev/console
power_state:
  mode: poweroff
  delay: now
EOF
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    python3 -m http.server --bind 127.0.0.1 --directory "$seed" "$port" > "$work/golden-http.log" 2>&1 &
    pids+=($!)
    run_qemu "$tmp_golden" "user,id=n0" "http://10.0.2.2:$port/" "$work/golden-console.log"
    if ! wait "$qemu_pid"; then die "base image VM failed; see $work/golden-console.log"; fi
    grep -q KYN-E2E-GOLDEN-OK "$work/golden-console.log" || die "base image setup didn't finish; see $work/golden-console.log"
    mv "$tmp_golden" "$golden"
    say "base image ready: $golden"
fi

# --- Installer --------------------------------------------------------------------
if [ -z "$installer" ]; then
    command -v gh > /dev/null || die "pass --installer, or install gh to fetch the latest release"
    if [ "$arch" = arm64 ]; then pattern='kyn-linux-arm64-*.run'; else pattern='kyn-linux-[0-9]*.run'; fi
    say "downloading the latest release's $pattern"
    gh release download -R Shells-com/kynvpn-desktop --pattern "$pattern" --dir "$work/release"
    installer=$(ls "$work"/release/*.run | head -1)
fi
[ -f "$installer" ] || die "installer not found: $installer"
say "installer: $(basename "$installer")"

# --- Test CA and the mock's certificate -------------------------------------------
pki="$work/pki"
mkdir -p "$pki"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=Kyn VPN e2e test CA" -keyout "$pki/ca.key" -out "$pki/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=ws.atonline.com" \
    -keyout "$pki/server.key" -out "$pki/server.csr" 2> /dev/null
cat > "$pki/server.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:ws.atonline.com,DNS:ip.kynvpn.com,DNS:test1.kynvpn.test,DNS:files.kynvpn.test
EOF
openssl x509 -req -in "$pki/server.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial \
    -days 2 -extfile "$pki/server.ext" -out "$pki/server.crt" 2> /dev/null
openssl pkcs8 -topk8 -nocrypt -in "$pki/server.key" -out "$pki/server.p8"
cat "$pki/server.crt" "$pki/ca.crt" > "$pki/chain.crt"

# --- What the guest downloads -----------------------------------------------------
www="$work/www"
mkdir -p "$www/seed" "$work/artifacts"
cp "$pki/ca.crt" "$www/ca.crt"
cp "$installer" "$www/kyn.run"
cp "$here/guest/guest-test.sh" "$www/guest-test.sh"
cat > "$www/modern_regions_override.json" <<'EOF'
{
  "groups": {
    "wg": [
      { "name": "wireguard", "ports": [1337] },
      { "name": "meta", "ports": [443] }
    ]
  },
  "regions": [
    {
      "id": "e2e-test",
      "name": "E2E Test",
      "country": "US",
      "auto_region": true,
      "dns": "test1.kynvpn.test",
      "port_forward": false,
      "geo": false,
      "offline": false,
      "servers": {
        "wg": [ { "ip": "203.0.113.20", "cn": "test1.kynvpn.test" } ]
      }
    }
  ]
}
EOF
echo "instance-id: kyn-e2e-$(date +%s)-$$" > "$www/seed/meta-data"
: > "$www/seed/vendor-data"
cat > "$www/seed/user-data" <<'EOF'
#cloud-config
runcmd:
  - [sh, -c, "curl -fsS http://203.0.113.30/guest-test.sh -o /root/guest-test.sh && bash /root/guest-test.sh > /dev/console 2>&1 || curl -s -m 10 --data-binary '{\"pass\":false,\"error\":\"guest script did not run\"}' http://192.168.77.1/e2e/result"]
EOF

# --- Run ----------------------------------------------------------------------------
say "building mockworld"
cargo build --release --quiet --manifest-path "$here/mockworld/Cargo.toml"
mockworld="$here/mockworld/target/release/mockworld"

qemu-img create -q -f qcow2 -b "$golden" -F qcow2 "$work/disk.qcow2"
sock="$work/net.sock"
"$mockworld" --qemu-socket "$sock" --www "$www" --cert "$pki/chain.crt" --key "$pki/server.p8" \
    --result "$work/report.json" --artifacts "$work/artifacts" --timeout "$timeout" $verbose \
    > "$work/mockworld.out" 2> >(tee "$work/mockworld.log" >&2) &
mock_pid=$!
pids+=("$mock_pid")
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || die "mockworld didn't start; see $work/mockworld.log"

say "booting the test VM ($arch, $accel)"
run_qemu "$work/disk.qcow2" "stream,id=n0,server=off,addr.type=unix,addr.path=$sock" \
    "http://203.0.113.30/seed/" "$work/console.log"

status=0
wait "$mock_pid" || status=$?
kill "$qemu_pid" 2> /dev/null || true

if [ -f "$work/report.json" ]; then
    python3 - "$work/report.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
g = r.get("guest", {})
for s in g.get("steps", []):
    print(f"  {'PASS' if s['pass'] else 'FAIL'}  {s['name']}" + (f"  ({s['detail']})" if s.get('detail') else ""))
if g.get("error"):
    print("  ERROR", g["error"])
print("RESULT:", "PASS" if g.get("pass") else "FAIL")
EOF
fi
say "logs: $work (console.log, mockworld.log, artifacts/)"
exit "$status"
