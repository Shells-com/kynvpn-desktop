# End-to-end test: the Linux client in a VM against a mock backend

`tests/e2e/run.sh` installs a Kyn VPN Linux build in an Ubuntu 24.04 VM and
drives it with `kynctl`: login, connect over WireGuard, traffic through the
tunnel, a server outage with the killswitch on, reconnect, disconnect and
logout. It checks that nothing leaks outside the tunnel.

```sh
tests/e2e/run.sh                                  # latest release, host architecture
tests/e2e/run.sh --installer out/kyn/artifacts/kyn-linux-arm64-….run
tests/e2e/run.sh --arch x86_64 --verbose --keep
```

Needs QEMU (with UEFI firmware for arm64), `qemu-img`, Rust, `openssl` and
`python3`; `gh` too unless you pass `--installer`. On macOS the VM uses HVF, on
Linux KVM when `/dev/kvm` is writable; a foreign architecture runs under TCG
(slow).

The first run downloads the Ubuntu cloud image and builds a base image with
the client's dependencies, using the internet once. It's cached in
`~/.cache/kynvpn-e2e` (`KYN_E2E_CACHE` to move it). Each test boots a
throwaway overlay of it.

## The mock world

The test VM has no internet. Its only network is `mockworld`, a Rust program
(`tests/e2e/mockworld`, built on [pktkit](https://crates.io/crates/pktkit) and
[httpsd](https://crates.io/crates/httpsd)) that QEMU's NIC is plugged into:

| Address | What |
|---|---|
| 192.168.77.0/24 | The VM's LAN; DHCP from .2, the VM gets .100 |
| 192.168.77.1 | Gateway and DNS; `http://192.168.77.1/e2e/…` test controls |
| 203.0.113.10 `ws.atonline.com` | The account API: `token`, `account`, `expire_token` |
| 203.0.113.11 `ip.kynvpn.com` | The IP check: `connected:true` and the VPN address through the tunnel |
| 203.0.113.20 `test1.kynvpn.test` | The VPN server: WireGuard and `addKey` on 1337, meta API on 443 |
| 203.0.113.30 `files.kynvpn.test` | Plain HTTP: the installer, the test script, the cloud-init seed |
| 10.0.0.243 (in the tunnel) | DNS |
| 10.0.0.1:443 (in the tunnel) | The meta API |

DNS answers only those names. TCP goes to a userspace stack with virtual
listeners only, and every real destination is refused. Other traffic is
dropped. Hostnames match production, so the client runs with its built-in
URLs. The two exceptions:

- the test CA is added to the VM's trust store (the client uses the system CAs);
- the servers list comes from `/opt/kynvpn/etc/modern_regions_override.json`,
  because the production list is signed with a key the test doesn't hold.

The login is `e2e-user` / `e2e-password`.

**Leaks.** After connecting, the guest arms leak accounting. From then on,
any packet the VM sends outside the tunnel is a leak, and so is any DNS query
to the LAN resolver. Only LAN traffic and WireGuard to the server are allowed.
`POST /e2e/server/down` makes the VPN server stop answering, to test the
killswitch.

## Output

The script prints each step and the overall result. It exits 0 if everything
passed, 1 if a step failed, and 2 on a timeout or setup problem.

The work directory it prints holds:
- `report.json`
- `console.log` (the VM's serial console)
- `mockworld.log`
- `artifacts/`, with the daemon's log, state and journal uploaded by the guest

The guest-side steps are in `guest/guest-test.sh`.
