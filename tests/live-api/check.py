#!/usr/bin/env python3
"""Call the Kyn VPN APIs the desktop client uses, the way the client calls
them, and check the responses against what the client parses.

Uses the test token from Network/VPN/Token:test.  Read-only except addKey
(registers a throwaway WireGuard key on each region's first server) and
expire_token (on a test token).  Needs python3 and openssl; run it from
anywhere:

    python3 tests/live-api/check.py
"""
import base64, json, os, re, socket, ssl, subprocess, sys, tempfile, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

REST = "https://ws.atonline.com/_rest/"
IP_API = "https://ip.kynvpn.com/clientinfo/ip/"
LIST_API = "https://ip.kynvpn.com/"
results = []

def report(name, ok, detail=""):
    results.append((name, ok))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"  ({detail})" if detail else ""))

def http(url, method="GET", headers=None, body=None, ctx=None, timeout=20):
    # The client (Qt) sends no User-Agent; ip.kynvpn.com rejects Python's default
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "kynvpn-apicheck", **(headers or {})}, data=body)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def jtype(v, t):
    return {"bool": isinstance(v, bool), "str": isinstance(v, str),
            "int": isinstance(v, int) and not isinstance(v, bool),
            "num": isinstance(v, (int, float)) and not isinstance(v, bool)}[t]

def token():
    st, b = http(REST.replace("_rest", "_special/rest") + "Network/VPN/Token:test")
    return json.loads(b)["data"]["token"]

def check_account(tok):
    # Daemon::loadAccountInfo: GET apiV2 "account", Authorization: Token <tok>
    st, b = http(REST + "Network/VPN:apiV2?resource=/account", headers={"Authorization": "Token " + tok})
    if st != 200:
        report("account (apiV2)", False, f"HTTP {st}: {b[:200]!r}"); return
    j = json.loads(b)
    # Fields read by loadAccountInfo, with the DaemonAccount types
    want = {"plan": "str", "active": "bool", "canceled": "bool", "recurring": "bool",
            "needs_payment": "bool", "days_remaining": "int", "renewable": "bool",
            "renew_url": "str", "expiration_time": "num", "expire_alert": "bool",
            "expired": "bool", "username": "str"}
    if not isinstance(j, dict) or "data" in j and "result" in j:
        report("account (apiV2)", False, "response is wrapped, client reads top-level fields: " + str(list(j)[:6])); return
    bad = [f"{k}={j[k]!r}" for k, t in want.items() if k in j and not jtype(j[k], t)]
    missing = [k for k in want if k not in j]
    report("account (apiV2)", not bad, f"missing (defaulted): {missing}; wrong types: {bad}; plan={j.get('plan')!r} active={j.get('active')!r}")

def check_account_bad_token():
    st, b = http(REST + "Network/VPN:apiV2?resource=/account", headers={"Authorization": "Token deadbeef"})
    report("account rejects a bad token with 401", st == 401, f"HTTP {st}")

def check_ip():
    st, b = http(IP_API + "v1")
    j = json.loads(b) if st == 200 else {}
    ok = st == 200 and isinstance(j.get("ip"), str) and isinstance(j.get("connected"), bool)
    report("ip API v1", ok, f"HTTP {st} ip={j.get('ip')} connected={j.get('connected')}")

def check_lists():
    out = {}
    for res in ("vpninfo/servers/v6", "vpninfo/regions/v2"):
        st, b = http(LIST_API + res)
        ok = st == 200
        # JsonRefresher: the signature follows the last '}' of the JSON
        end = b.rfind(b"}")
        body, sig = b[:end + 1], b[end + 1:]
        try:
            j = json.loads(body)
        except Exception:
            ok = False; j = None
        report(res, ok and j is not None and bool(sig.strip()), f"HTTP {st}, {len(b)} bytes, signature {'present' if sig.strip() else 'missing'}")
        out[res] = (body, sig, j)
    return out

def verify_sig(body, sig, pubkey_pem):
    # Ed25519 over the JSON (client: Environment regions list key)
    with tempfile.TemporaryDirectory() as d:
        open(f"{d}/k.pem", "wb").write(pubkey_pem)
        open(f"{d}/m", "wb").write(body)
        open(f"{d}/s", "wb").write(base64.b64decode(b"".join(sig.split())))
        r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", f"{d}/k.pem",
                            "-rawin", "-in", f"{d}/m", "-sigfile", f"{d}/s"], capture_output=True)
        return r.returncode == 0

def wg_keypair():
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["openssl", "genpkey", "-algorithm", "X25519", "-out", f"{d}/k"], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", f"{d}/k", "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        return base64.b64encode(der[-32:]).decode()

def server_ctx():
    # The client checks VPN server certificates against the system CAs and the
    # server's "cn" (FixedApiBase), connecting by IP
    return ssl.create_default_context()

def https_to_ip(ip, port, cn, path, headers=None):
    ctx = server_ctx()
    with socket.create_connection((ip, port), timeout=15) as s:
        with ctx.wrap_socket(s, server_hostname=cn) as t:
            req = f"GET {path} HTTP/1.1\r\nHost: {cn}:{port}\r\nConnection: close\r\n"
            for k, v in (headers or {}).items():
                req += f"{k}: {v}\r\n"
            t.sendall((req + "\r\n").encode())
            data = b""
            while True:
                c = t.recv(65536)
                if not c: break
                data += c
    head, _, body = data.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1])
    if b"transfer-encoding: chunked" in head.lower():
        out = b""; rest = body
        while rest:
            n, _, rest = rest.partition(b"\r\n")
            n = int(n, 16)
            if n == 0: break
            out += rest[:n]; rest = rest[n+2:]
        body = out
    return status, body

def check_addkey(servers, tok):
    regions = servers.get("regions", [])
    groups = servers.get("groups", {})
    for region in regions:
        wg = region.get("servers", {}).get("wg", [])
        if not wg:
            report(f"addKey {region.get('name')}", False, "no wg servers"); continue
        srv = wg[0]
        port = srv.get("port") or groups.get("wg", [{}])[0].get("ports", [0])[0]
        pub = wg_keypair()
        path = "/addKey?pubkey=" + urllib.parse.quote(pub, safe="") + "&pt=" + urllib.parse.quote(tok, safe="")
        try:
            st, b = https_to_ip(srv["ip"], port, srv["cn"], path)
        except Exception as e:
            report(f"addKey {region['name']} {srv['cn']}", False, f"{type(e).__name__}: {e}"); continue
        try:
            j = json.loads(b)
        except Exception:
            report(f"addKey {region['name']} {srv['cn']}", False, f"HTTP {st} non-JSON {b[:120]!r}"); continue
        # WireguardMethod::parseAuthResult
        problems = []
        if j.get("status") != "OK": problems.append(f"status={j.get('status')!r}")
        sp = j.get("server_port")
        if not (isinstance(sp, int) and 0 < sp < 65536): problems.append(f"server_port={sp!r}")
        for k in ("server_ip", "server_vip"):
            try: socket.inet_pton(socket.AF_INET, j.get(k, ""))
            except Exception: problems.append(f"{k}={j.get(k)!r}")
        pip = j.get("peer_ip", "")
        try:
            a, _, m = pip.partition("/"); socket.inet_pton(socket.AF_INET, a)
            if not (m and 0 < int(m) <= 32): problems.append(f"peer_ip={pip!r} (needs /prefix)")
        except Exception: problems.append(f"peer_ip={pip!r}")
        try:
            if len(base64.b64decode(j.get("server_key", ""))) != 32: problems.append("server_key length")
        except Exception: problems.append("server_key not base64")
        report(f"addKey {region['name']} {srv['cn']}:{port}", not problems,
               f"HTTP {st}; " + ("; ".join(problems) if problems else
               f"peer_ip={pip} server_vip={j.get('server_vip')} dns={j.get('dns_servers')}"))
        # Meta API v2 on the same server (MetaServiceApiBase: https://ip:port/apiv2/...)
        try:
            st2, b2 = https_to_ip(srv["ip"], port, srv["cn"], "/apiv2/account", {"Authorization": "Token " + tok})
            report(f"meta /apiv2/account via {srv['cn']}", st2 == 200, f"HTTP {st2} {b2[:100]!r}")
        except Exception as e:
            report(f"meta /apiv2/account via {srv['cn']}", False, f"{type(e).__name__}: {e}")

def check_expire(tok):
    # Daemon::RPC_logout: POST apiV2 "expire_token" with an empty JSON object
    st, b = http(REST + "Network/VPN:apiV2?resource=/expire_token", method="POST",
                 headers={"Authorization": "Token " + tok, "Content-Type": "application/json"}, body=b"{}")
    report("expire_token", st == 200, f"HTTP {st} {b[:150]!r}")

def check_token_login_shape():
    # Daemon::RPC_login: POST apiV2 "token" {username,password}; bad credentials must be 401
    st, b = http(REST + "Network/VPN:apiV2?resource=/token", method="POST",
                 headers={"Content-Type": "application/json"},
                 body=json.dumps({"username": "kyn-apicheck-nonexistent@example.invalid", "password": "x"}).encode())
    report("token (login) rejects bad credentials with 401", st == 401, f"HTTP {st} {b[:120]!r}")

def regions_list_key():
    # Environment::defaultRegionsListPublicKey in the daemon
    src = open(os.path.join(REPO, "daemon/src/environment.cpp")).read()
    m = re.search(r"defaultRegionsListPublicKey = QByteArrayLiteral\((.*?)\);", src, re.S)
    pem = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)))
    return pem.replace("\\n", "\n").encode()

def main():
    pub_pem = regions_list_key()
    tok = token()
    print(f"test token: {len(tok)} chars, {'hex' if all(c in '0123456789abcdefABCDEF' for c in tok) else 'not hex (JWT)'}")
    check_account(tok)
    check_account_bad_token()
    check_token_login_shape()
    check_ip()
    lists = check_lists()
    for res, (body, sig, j) in lists.items():
        report(f"{res} signature verifies", verify_sig(body, sig, pub_pem))
    servers = lists["vpninfo/servers/v6"][2] or {}
    check_addkey(servers, tok)
    check_expire(token())
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    sys.exit(1 if failed else 0)

main()
