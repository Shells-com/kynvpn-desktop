#!/bin/bash
# Runs inside the end-to-end test VM, as root, from cloud-init.
#
# Installs the Kyn VPN Linux build served by mockworld, then drives it with
# kynctl through login, connect, tunnel checks, a server outage with the
# killswitch on, disconnect and logout. Every step's outcome is posted back
# to mockworld, which also counts any packet that leaks outside the tunnel.
set -u

# Control endpoints on the gateway: on the LAN, so always reachable (even
# with the killswitch blocking everything else) and never counted as a leak.
CTL=http://192.168.77.1
FILES=http://files.kynvpn.test
VPN_IP=203.0.113.20
PUBLIC_IP=198.51.100.77
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

RESULTS=/root/e2e-results.jsonl
: > "$RESULTS"
FAILED=0

log() {
    echo "e2e: $*"
    curl -s -m 5 --data-binary "$*" "$CTL/e2e/log" > /dev/null || true
}

record() { # name pass(true/false) detail
    jq -nc --arg n "$1" --argjson p "$2" --arg d "${3:-}" '{name:$n,pass:$p,detail:$d}' >> "$RESULTS"
    if [ "$2" = true ]; then log "PASS $1 ${3:-}"; else FAILED=1; log "FAIL $1 ${3:-}"; fi
}

upload() { # name file
    [ -f "$2" ] && curl -s -m 30 --data-binary "@$2" "$CTL/e2e/upload/$1" > /dev/null || true
}

finish() {
    log "finishing (failed=$FAILED)"
    kynctl -u dump daemon-state > /root/daemon-state.json 2>&1 || true
    upload daemon-state.json /root/daemon-state.json
    upload daemon.log /opt/kynvpn/var/daemon.log
    journalctl -u kynvpn --no-pager > /root/kynvpn-journal.txt 2>&1 || true
    upload kynvpn-journal.txt /root/kynvpn-journal.txt
    upload install.log /root/install.log
    local pass=true
    [ "$FAILED" = 0 ] || pass=false
    jq -sc --argjson pass "$pass" '{pass:$pass, steps:.}' "$RESULTS" > /root/e2e-result.json
    curl -s -m 10 --data-binary @/root/e2e-result.json "$CTL/e2e/result" > /dev/null
    sleep 2
    poweroff
    exit 0
}

# wait_for SECONDS COMMAND...: retry until COMMAND succeeds.
wait_for() {
    local deadline=$(( $(date +%s) + $1 )); shift
    while ! "$@" > /dev/null 2>&1; do
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 1
    done
}

# Test traffic leaves from ports 61000-61999, so a leak sample shows whether
# it was ours or the daemon's.
tcurl() { curl --local-port 61000-61999 "$@"; }
tdig() { dig -b "0.0.0.0#$((61000 + RANDOM % 1000))" "$@"; }

state() { kynctl get connectionstate 2>/dev/null; }
is_state() { [ "$(state)" = "$1" ]; }
not_state() { [ "$(state)" != "$1" ]; }
pubip_is() { [ "$(kynctl get pubip 2>/dev/null)" = "$1" ]; }
vpnip_is() { [ "$(kynctl get vpnip 2>/dev/null)" = "$1" ]; }
logged_in() { [ "$(kynctl -u dump daemon-account 2>/dev/null | jq -r .loggedIn)" = true ]; }
leaks() { curl -s -m 5 "$CTL/e2e/leaks" | jq -r .count; }
world() { curl -s -m 5 "$CTL/e2e/state"; }

log "guest test starting on $(lsb_release -ds 2>/dev/null) $(uname -m)"

# --- The mock network -------------------------------------------------------
if [ "$(getent hosts files.kynvpn.test | awk '{print $1}')" = 203.0.113.30 ]; then
    record dns-lan true
else
    record dns-lan false "files.kynvpn.test did not resolve"; finish
fi

# --- Install ----------------------------------------------------------------
curl -fsS "$FILES/ca.crt" -o /usr/local/share/ca-certificates/kyn-e2e.crt \
    && update-ca-certificates > /dev/null \
    && record trust-test-ca true || { record trust-test-ca false; finish; }

curl -fsS "$FILES/kyn.run" -o /home/ubuntu/kyn.run && chown ubuntu: /home/ubuntu/kyn.run \
    || { record download-installer false; finish; }
if sudo -u ubuntu -H bash /home/ubuntu/kyn.run < /dev/null > /root/install.log 2>&1 \
    && systemctl is-active --quiet kynvpn; then
    record install true "$(kynctl --version 2>/dev/null | head -1)"
else
    record install false "$(tail -5 /root/install.log | tr '\n' ' ')"; finish
fi

# The production regions list is signed with a key we don't hold; point the
# daemon at the mock's list instead.
curl -fsS "$FILES/modern_regions_override.json" -o /opt/kynvpn/etc/modern_regions_override.json \
    || { record regions-override false "download"; finish; }
systemctl restart kynvpn
wait_for 30 kynctl get connectionstate || { record daemon-restart false; finish; }
kynctl set debuglogging true
kynctl background enable
kynctl -u applysettings '{"wireguardPingTimeout":15}' || true

if wait_for 60 sh -c 'kynctl get regions | grep -qv "^auto$"'; then
    record regions true "$(kynctl get regions | tr '\n' ' ')"
else
    record regions false "$(kynctl get regions 2>&1 | tr '\n' ' ')"
fi

# --- Login ------------------------------------------------------------------
printf 'e2e-user\ne2e-password\n' > /root/creds && chmod 600 /root/creds
kynctl login /root/creds > /root/login.out 2>&1
if wait_for 30 logged_in; then
    record login true
else
    record login false "$(cat /root/login.out | tr '\n' ' ')"; finish
fi
rm -f /root/creds

if wait_for 90 pubip_is "$PUBLIC_IP"; then
    record pubip-before true "$PUBLIC_IP"
else
    record pubip-before false "got '$(kynctl get pubip)'"
fi

# --- Connect ----------------------------------------------------------------
kynctl connect
if wait_for 90 is_state Connected; then
    record connect true
else
    record connect false "state $(state)"; finish
fi
wait_for 30 vpnip_is "$VPN_IP" \
    && record vpnip true "$VPN_IP" \
    || record vpnip false "got '$(kynctl get vpnip)'"

# Leak accounting from here on: everything must go through the tunnel.
curl -s -m 5 -X POST "$CTL/e2e/leaks/arm" > /dev/null

# DNS while connected must be answered through the tunnel.
before=$(world | jq .dns_tunnel)
if [ "$(getent hosts ip.kynvpn.com | awk '{print $1}')" = 203.0.113.11 ] \
    && [ "$(world | jq .dns_tunnel)" -gt "$before" ]; then
    record dns-through-tunnel true "resolver: $(resolvectl dns 2>/dev/null | grep -v ': *$' | tr '\n' ' ')"
else
    record dns-through-tunnel false "$(resolvectl dns 2>&1 | tr '\n' ' ')"
fi

ipcheck=$(tcurl -s -m 10 https://ip.kynvpn.com/clientinfo/ip/v1)
[ "$(echo "$ipcheck" | jq -r .connected)" = true ] \
    && record https-through-tunnel true "$ipcheck" \
    || record https-through-tunnel false "$ipcheck"

[ "$(tcurl -s -m 10 -o /dev/null -w '%{http_code}' "$FILES/ca.crt")" = 200 ] \
    && record http-through-tunnel true \
    || record http-through-tunnel false

ping -c 2 -W 2 203.0.113.11 > /dev/null && record ping-through-tunnel true || record ping-through-tunnel false
# Traffic the mock drops inside the tunnel: still must not leak outside it.
tdig +time=2 +tries=1 @8.8.8.8 example.com > /dev/null 2>&1 || true
tcurl -s -m 3 http://192.0.2.1/ > /dev/null 2>&1 || true
sleep 2
n=$(leaks)
[ "$n" = 0 ] && record no-leaks-connected true || record no-leaks-connected false "$(curl -s "$CTL/e2e/leaks")"

# --- Server outage with the killswitch on -----------------------------------
kynctl -u applysettings '{"killswitch":"on"}' && sleep 2
curl -s -m 5 -X POST "$CTL/e2e/server/down" > /dev/null
log "server down; waiting for the client to notice"
deadline=$(( $(date +%s) + 120 ))
while is_state Connected && [ "$(date +%s)" -lt "$deadline" ]; do
    tcurl -s -m 2 http://203.0.113.30/ > /dev/null 2>&1
    ping -c 1 -W 1 203.0.113.11 > /dev/null 2>&1
    getent hosts ip.kynvpn.com > /dev/null 2>&1
done
not_state Connected && record outage-detected true "state $(state)" || record outage-detected false
{ date; kynctl get connectionstate; iptables-save; ip6tables-save; ip rule; ip route show table all; resolvectl status; } \
    > /root/outage-net.txt 2>&1
upload outage-net.txt /root/outage-net.txt
# Keep trying to get out while the client is reconnecting.
for i in $(seq 1 10); do
    tcurl -s -m 2 http://203.0.113.30/ > /dev/null 2>&1
    tcurl -s -m 2 https://ip.kynvpn.com/clientinfo/ip/v1 > /dev/null 2>&1
    tdig +time=1 +tries=1 @8.8.8.8 example.com > /dev/null 2>&1
done
n=$(leaks)
[ "$n" = 0 ] && record killswitch-no-leaks true || record killswitch-no-leaks false "$(curl -s "$CTL/e2e/leaks")"

curl -s -m 5 -X POST "$CTL/e2e/server/up" > /dev/null
if wait_for 180 is_state Connected; then
    record reconnect true
else
    record reconnect false "state $(state)"
fi
kynctl -u applysettings '{"killswitch":"auto"}' || true
n=$(leaks)
[ "$n" = 0 ] && record no-leaks-reconnect true || record no-leaks-reconnect false "$(curl -s "$CTL/e2e/leaks")"
curl -s -m 5 -X POST "$CTL/e2e/leaks/disarm" > /dev/null

# --- Disconnect, logout -----------------------------------------------------
kynctl disconnect
wait_for 30 is_state Disconnected && record disconnect true || record disconnect false "state $(state)"
ipcheck=$(tcurl -s -m 10 https://ip.kynvpn.com/clientinfo/ip/v1)
[ "$(echo "$ipcheck" | jq -r .connected)" = false ] \
    && record direct-after-disconnect true \
    || record direct-after-disconnect false "$ipcheck"

# Negative control: disconnected, a direct connection must register as a
# leak, or the checks above prove nothing.
curl -s -m 5 -X POST "$CTL/e2e/leaks/arm" > /dev/null
tcurl -s -m 5 -o /dev/null http://203.0.113.30/ca.crt
n=$(leaks)
curl -s -m 5 -X POST "$CTL/e2e/leaks/disarm" > /dev/null
[ "$n" -gt 0 ] 2>/dev/null && record leak-detector-works true "$n packets" || record leak-detector-works false "saw $n"

expired_before=$(world | jq .token_expired)
kynctl logout
if wait_for 30 sh -c '[ "$(kynctl -u dump daemon-account | jq -r .loggedIn)" = false ]' \
    && wait_for 15 sh -c "[ \"\$(curl -s -m 5 $CTL/e2e/state | jq .token_expired)\" -gt $expired_before ]"; then
    record logout true
else
    record logout false
fi

finish
