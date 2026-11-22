//! The mock world's network core.
//!
//! The VM's NIC is plugged into an L2 hub that also holds a DHCP server and
//! the gateway. Every IPv4 packet the VM routes off its LAN reaches
//! [`World::from_vm`], which plays the whole internet:
//!
//! - UDP 53 to the gateway: DNS, from [`crate::dns::Zone`].
//! - UDP to the VPN server's WireGuard port: a pktkit WireGuard handler.
//!   Decrypted tunnel packets go to [`World::tunnel_in`], which serves DNS on
//!   the tunnel DNS address and hands TCP to the same services.
//! - TCP: a pktkit slirp stack with virtual listeners only. Its destination
//!   filter refuses every real dial, so nothing here reaches the host's
//!   network.
//! - ICMP echo to the mock hosts: answered (the client pings servers to
//!   measure latency).
//!
//! While leak accounting is armed, any packet the VM sends outside the
//! tunnel, other than to its LAN or to the WireGuard endpoint, is a leak.

use crate::dns::Zone;
use pktkit::wg::{self, NoisePublicKey, PacketType, TimerAction};
use pktkit::{IpPrefix, L3Device, L3Handler, Packet, Protocol, Result};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

pub const LAN_GW: Ipv4Addr = Ipv4Addr::new(192, 168, 77, 1);
pub const LAN_DHCP: Ipv4Addr = Ipv4Addr::new(192, 168, 77, 2);
pub const LAN_BITS: u8 = 24;
pub const API_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 10);
pub const IP_API_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 11);
pub const VPN_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 20);
pub const FILES_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 30);
/// What the IP check reports for the VM when it isn't on the VPN.
pub const PUBLIC_IP: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 77);
pub const WG_PORT: u16 = 1337;
pub const VPN_CN: &str = "test1.kynvpn.test";
pub const SERVER_VIP: Ipv4Addr = Ipv4Addr::new(10, 7, 0, 1);
pub const TUNNEL_DNS: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 243);
pub const TUNNEL_DNS_MACE: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 241);
pub const META_TUNNEL_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
pub const TUNNEL_MTU: u32 = 1420;

pub fn in_tunnel_net(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 10 && o[1] == 7
}

fn in_lan(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 192 && o[1] == 168 && o[2] == 77
}

pub fn zone() -> Zone {
    Zone::new(&[
        ("ws.atonline.com", API_IP),
        ("ip.kynvpn.com", IP_API_IP),
        (VPN_CN, VPN_IP),
        ("files.kynvpn.test", FILES_IP),
    ])
}

#[derive(Default)]
pub struct Counters {
    pub logins: AtomicU64,
    pub token_expired: AtomicU64,
    pub wg_handshakes: AtomicU64,
    pub tunnel_in: AtomicU64,
    pub tunnel_out: AtomicU64,
    pub tunnel_dropped: AtomicU64,
    pub dns_lan: AtomicU64,
    pub dns_tunnel: AtomicU64,
    pub server_bypass: AtomicU64,
    pub preexisting_flow: AtomicU64,
}

#[derive(Default)]
struct Leaks {
    count: u64,
    samples: Vec<String>,
}

struct Peer {
    ip: Ipv4Addr,
    endpoint: Option<SocketAddrV4>,
}

/// A plain L3 device: what is sent to it goes to `on_send`; `inject` feeds a
/// packet to whoever installed the handler (the slirp stack).
pub struct Port {
    addr: IpPrefix,
    handler: Mutex<Option<L3Handler>>,
    on_send: Box<dyn Fn(&Packet) + Send + Sync>,
}

impl Port {
    pub fn new(addr: IpPrefix, on_send: impl Fn(&Packet) + Send + Sync + 'static) -> Arc<Port> {
        Arc::new(Port { addr, handler: Mutex::new(None), on_send: Box::new(on_send) })
    }

    pub fn inject(&self, pkt: &[u8]) {
        let h = self.handler.lock().unwrap().clone();
        if let Some(h) = h {
            let _ = h(Packet::from_slice(pkt));
        }
    }
}

impl L3Device for Port {
    fn set_handler(&self, h: L3Handler) {
        *self.handler.lock().unwrap() = Some(h);
    }
    fn send(&self, packet: &Packet) -> Result<()> {
        (self.on_send)(packet);
        Ok(())
    }
    fn addr(&self) -> IpPrefix {
        self.addr
    }
    fn set_addr(&self, _prefix: IpPrefix) -> Result<()> {
        Ok(())
    }
    fn close(&self) -> Result<()> {
        Ok(())
    }
}

pub struct World {
    pub token: String,
    pub token_expired: AtomicBool,
    pub wg: Arc<wg::Handler>,
    peers: Mutex<HashMap<[u8; 32], Peer>>,
    next_peer: AtomicU32,
    pub leak_armed: AtomicBool,
    pub server_down: AtomicBool,
    leaks: Mutex<Leaks>,
    /// TCP flows (src, sport, dst, dport) the VM opened outside the tunnel
    /// before leak accounting was armed. Their remaining packets (the ACK
    /// of the server closing an idle keep-alive connection, say) aren't
    /// leaks: nothing new leaves, the connection predates the VPN.
    preexisting: Mutex<HashSet<(Ipv4Addr, u16, Ipv4Addr, u16)>>,
    pub counters: Counters,
    zone: Zone,
    to_vm: Mutex<Option<L3Handler>>,
    pub outside: Mutex<Option<Arc<Port>>>,
    pub tunnel: Mutex<Option<Arc<Port>>>,
    done: Mutex<Option<mpsc::Sender<Value>>>,
    start: Instant,
    verbose: bool,
}

impl World {
    pub fn new(done: mpsc::Sender<Value>, verbose: bool) -> Arc<World> {
        let mut tok = [0u8; 32];
        getrandom(&mut tok);
        let token: String = tok.iter().map(|b| format!("{b:02x}")).collect();
        let wg = wg::Handler::new(wg::Config::default()).expect("wireguard handler");
        Arc::new(World {
            token,
            token_expired: AtomicBool::new(false),
            wg,
            peers: Mutex::new(HashMap::new()),
            next_peer: AtomicU32::new(2),
            leak_armed: AtomicBool::new(false),
            server_down: AtomicBool::new(false),
            leaks: Mutex::new(Leaks::default()),
            preexisting: Mutex::new(HashSet::new()),
            counters: Counters::default(),
            zone: zone(),
            to_vm: Mutex::new(None),
            outside: Mutex::new(None),
            tunnel: Mutex::new(None),
            done: Mutex::new(Some(done)),
            start: Instant::now(),
            verbose,
        })
    }

    pub fn log(&self, msg: impl AsRef<str>) {
        eprintln!("[{:8.3}] {}", self.start.elapsed().as_secs_f64(), msg.as_ref());
    }

    fn debug(&self, msg: impl FnOnce() -> String) {
        if self.verbose {
            self.log(msg());
        }
    }

    pub fn finish(&self, result: Value) {
        if let Some(tx) = self.done.lock().unwrap().take() {
            let _ = tx.send(result);
        }
    }

    pub fn reset_leaks(&self) {
        *self.leaks.lock().unwrap() = Leaks::default();
    }

    pub fn leak_report(&self) -> Value {
        let l = self.leaks.lock().unwrap();
        json!({ "armed": self.leak_armed.load(Ordering::SeqCst), "count": l.count, "samples": l.samples })
    }

    pub fn state_report(&self, asker: Ipv4Addr) -> Value {
        let c = &self.counters;
        let peers: Vec<Value> = self
            .peers
            .lock()
            .unwrap()
            .values()
            .map(|p| json!({ "ip": p.ip.to_string(), "endpoint": p.endpoint.map(|e| e.to_string()) }))
            .collect();
        json!({
            "asker": asker.to_string(),
            "via_tunnel": in_tunnel_net(asker),
            "logins": c.logins.load(Ordering::SeqCst),
            "token_expired": c.token_expired.load(Ordering::SeqCst),
            "wg_handshakes": c.wg_handshakes.load(Ordering::SeqCst),
            "tunnel_in": c.tunnel_in.load(Ordering::SeqCst),
            "tunnel_out": c.tunnel_out.load(Ordering::SeqCst),
            "tunnel_dropped": c.tunnel_dropped.load(Ordering::SeqCst),
            "dns_lan": c.dns_lan.load(Ordering::SeqCst),
            "dns_tunnel": c.dns_tunnel.load(Ordering::SeqCst),
            "server_bypass_packets": c.server_bypass.load(Ordering::SeqCst),
            "preexisting_flow_packets": c.preexisting_flow.load(Ordering::SeqCst),
            "server_down": self.server_down.load(Ordering::SeqCst),
            "peers": peers,
        })
    }

    /// Authorize a client key (from addKey) and give it a tunnel address.
    /// The same key keeps its address.
    pub fn add_wg_peer(&self, key: [u8; 32]) -> Ipv4Addr {
        let mut peers = self.peers.lock().unwrap();
        if let Some(p) = peers.get(&key) {
            return p.ip;
        }
        let n = self.next_peer.fetch_add(1, Ordering::SeqCst);
        let ip = Ipv4Addr::new(10, 7, (n >> 8) as u8, n as u8);
        self.wg.add_peer(NoisePublicKey::from(key));
        peers.insert(key, Peer { ip, endpoint: None });
        self.log(format!("wireguard: authorized peer {ip}"));
        ip
    }

    fn record_leak(&self, desc: String) {
        let mut l = self.leaks.lock().unwrap();
        l.count += 1;
        if l.samples.len() < 32 {
            self.log(format!("LEAK: {desc}"));
            l.samples.push(desc);
        }
    }

    fn send_to_vm(&self, pkt: &[u8]) {
        let h = self.to_vm.lock().unwrap().clone();
        if let Some(h) = h {
            let _ = h(Packet::from_slice(pkt));
        }
    }

    fn udp_packet(src: Ipv4Addr, sport: u16, dst: Ipv4Addr, dport: u16, payload: &[u8]) -> Vec<u8> {
        let udp = pktkit::build::build_udp(src.into(), dst.into(), sport, dport, payload);
        pktkit::build::build_ipv4(src, dst, Protocol::UDP, 64, &udp)
    }

    /// An IPv4 packet the VM sent to the gateway (anything off its LAN).
    pub fn from_vm(&self, pkt: &Packet) {
        let b = pkt.as_bytes();
        if b.is_empty() {
            return;
        }
        if pkt.version() == 6 {
            // The mock network has no IPv6; link-local and multicast are
            // the VM's own business, anything else is a leak.
            if b.len() >= 40 && self.leak_armed.load(Ordering::SeqCst) {
                let dst: [u8; 16] = b[24..40].try_into().unwrap();
                let dst = std::net::Ipv6Addr::from(dst);
                let seg0 = dst.segments()[0];
                if seg0 & 0xffc0 != 0xfe80 && seg0 & 0xff00 != 0xff00 {
                    self.record_leak(format!("ipv6 to {dst}"));
                }
            }
            return;
        }
        let (Some(src), Some(dst)) = (pkt.ipv4_src_addr(), pkt.ipv4_dst_addr()) else {
            return;
        };
        let proto = pkt.ipv4_protocol();
        let l4 = pkt.ipv4_payload();
        let ports = (l4.len() >= 4)
            .then(|| (u16::from_be_bytes([l4[0], l4[1]]), u16::from_be_bytes([l4[2], l4[3]])));

        let to_wg = proto == Protocol::UDP && dst == VPN_IP && ports.map(|p| p.1) == Some(WG_PORT);
        let armed = self.leak_armed.load(Ordering::SeqCst);
        let mut old_flow = false;
        if let (Protocol::TCP, Some((s, d))) = (proto, ports) {
            let key = (src, s, dst, d);
            let syn_only = l4.get(13).is_some_and(|f| f & 0x12 == 0x02);
            let mut flows = self.preexisting.lock().unwrap();
            if !armed {
                flows.insert(key);
            } else {
                old_flow = !syn_only && flows.contains(&key);
            }
        }
        if armed && old_flow {
            self.counters.preexisting_flow.fetch_add(1, Ordering::Relaxed);
        }
        // The daemon talks to the VPN server itself outside the tunnel
        // (addKey, the meta API) to set it up; that is not a leak.
        if armed && !old_flow && dst == VPN_IP && !to_wg {
            self.counters.server_bypass.fetch_add(1, Ordering::Relaxed);
        } else if armed
            && !old_flow
            && dst != VPN_IP
            && !to_wg
            && !in_lan(dst)
            && !dst.is_broadcast()
            && !dst.is_multicast()
        {
            let what = match (proto, ports) {
                (Protocol::TCP, Some((s, d))) => {
                    let flags = l4.get(13).copied().unwrap_or(0);
                    let names: Vec<&str> = [(0x02, "SYN"), (0x10, "ACK"), (0x01, "FIN"), (0x04, "RST"), (0x08, "PSH")]
                        .iter()
                        .filter(|(b, _)| flags & b != 0)
                        .map(|(_, n)| *n)
                        .collect();
                    format!("tcp {src}:{s} -> {dst}:{d} [{}]", names.join(","))
                }
                (Protocol::UDP, Some((s, d))) => format!("udp {src}:{s} -> {dst}:{d}"),
                _ => format!("proto {} {src} -> {dst}", proto.as_u8()),
            };
            self.record_leak(what);
        }

        let server_down = self.server_down.load(Ordering::SeqCst);
        match proto {
            Protocol::UDP => {
                let Some((sport, dport)) = ports else { return };
                let payload = l4.get(8..).unwrap_or(&[]);
                if dst == LAN_GW && dport == 53 {
                    self.counters.dns_lan.fetch_add(1, Ordering::Relaxed);
                    // The LAN is allowed while connected, but its resolver
                    // isn't: a lookup sent there bypasses the VPN's DNS.
                    if self.leak_armed.load(Ordering::SeqCst) {
                        let name = self.zone.answer(payload).map(|(_, n)| n).unwrap_or_default();
                        self.record_leak(format!("dns {src}:{sport} -> {dst}:53 ({name})"));
                    }
                    if let Some((reply, name)) = self.zone.answer(payload) {
                        self.debug(|| format!("dns(lan) {name}"));
                        self.send_to_vm(&Self::udp_packet(dst, 53, src, sport, &reply));
                    }
                } else if to_wg && !server_down {
                    self.wg_in(payload, SocketAddrV4::new(src, sport));
                }
            }
            Protocol::ICMP => {
                if [LAN_GW, API_IP, IP_API_IP, FILES_IP].contains(&dst) || (dst == VPN_IP && !server_down) {
                    if let Some(reply) = echo_reply(b) {
                        self.send_to_vm(&reply);
                    }
                }
            }
            Protocol::TCP => {
                if dst == VPN_IP && server_down {
                    return;
                }
                let port = self.outside.lock().unwrap().clone();
                if let Some(port) = port {
                    port.inject(b);
                }
            }
            _ => {}
        }
    }

    /// The slirp stack's reply on the outside network.
    pub fn outside_out(&self, pkt: &Packet) {
        if pkt.ipv4_src_addr() == Some(VPN_IP) && self.server_down.load(Ordering::SeqCst) {
            return;
        }
        self.send_to_vm(pkt.as_bytes());
    }

    fn set_endpoint(&self, key: &NoisePublicKey, ep: SocketAddrV4) {
        if let Some(p) = self.peers.lock().unwrap().get_mut(key.as_bytes()) {
            if p.endpoint != Some(ep) {
                self.log(format!("wireguard: peer {} endpoint {ep}", p.ip));
                p.endpoint = Some(ep);
            }
        }
    }

    fn wg_in(&self, payload: &[u8], from: SocketAddrV4) {
        let r = match self.wg.process_packet(payload, &SocketAddr::V4(from)) {
            Ok(r) => r,
            Err(e) => {
                self.debug(|| format!("wireguard: packet from {from} rejected: {e}"));
                return;
            }
        };
        match r.ty {
            PacketType::HandshakeResponse | PacketType::CookieReply => {
                if r.ty == PacketType::HandshakeResponse {
                    self.counters.wg_handshakes.fetch_add(1, Ordering::SeqCst);
                    self.set_endpoint(&r.peer_key, from);
                    self.log(format!("wireguard: handshake from {from}"));
                }
                if !r.response.is_empty() {
                    self.send_to_vm(&Self::udp_packet(VPN_IP, WG_PORT, *from.ip(), from.port(), &r.response));
                }
            }
            PacketType::TransportData => {
                self.set_endpoint(&r.peer_key, from);
                self.tunnel_in(&r.data, &r.peer_key);
            }
            PacketType::Keepalive => self.set_endpoint(&r.peer_key, from),
            PacketType::CookieReceived => {}
        }
    }

    /// A decrypted packet the client sent into the tunnel.
    fn tunnel_in(&self, inner: &[u8], key: &NoisePublicKey) {
        self.counters.tunnel_in.fetch_add(1, Ordering::Relaxed);
        let pkt = Packet::from_slice(inner);
        if inner.is_empty() || pkt.version() != 4 {
            self.counters.tunnel_dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        let (Some(src), Some(dst)) = (pkt.ipv4_src_addr(), pkt.ipv4_dst_addr()) else {
            return;
        };
        let expected = self.peers.lock().unwrap().get(key.as_bytes()).map(|p| p.ip);
        if expected != Some(src) {
            self.log(format!("wireguard: dropping tunnel packet from {src}, peer is {expected:?}"));
            self.counters.tunnel_dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        let l4 = pkt.ipv4_payload();
        match pkt.ipv4_protocol() {
            Protocol::UDP if l4.len() >= 8 => {
                let sport = u16::from_be_bytes([l4[0], l4[1]]);
                let dport = u16::from_be_bytes([l4[2], l4[3]]);
                if dport == 53 && (dst == TUNNEL_DNS || dst == TUNNEL_DNS_MACE) {
                    self.counters.dns_tunnel.fetch_add(1, Ordering::Relaxed);
                    if let Some((reply, name)) = self.zone.answer(&l4[8..]) {
                        self.debug(|| format!("dns(tunnel) {name}"));
                        self.tunnel_out_bytes(&Self::udp_packet(dst, 53, src, sport, &reply));
                    }
                } else {
                    self.debug(|| format!("tunnel: dropping udp to {dst}:{dport}"));
                    self.counters.tunnel_dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
            Protocol::ICMP => {
                if [SERVER_VIP, TUNNEL_DNS, API_IP, IP_API_IP, VPN_IP, FILES_IP].contains(&dst) {
                    if let Some(reply) = echo_reply(inner) {
                        self.tunnel_out_bytes(&reply);
                    }
                }
            }
            Protocol::TCP => {
                let port = self.tunnel.lock().unwrap().clone();
                if let Some(port) = port {
                    port.inject(inner);
                }
            }
            _ => {
                self.counters.tunnel_dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// Send a packet to the client through the tunnel.
    pub fn tunnel_out_bytes(&self, pkt: &[u8]) {
        if self.server_down.load(Ordering::SeqCst) {
            return;
        }
        let Some(dst) = Packet::from_slice(pkt).ipv4_dst_addr() else { return };
        let target = self
            .peers
            .lock()
            .unwrap()
            .iter()
            .find(|(_, p)| p.ip == dst)
            .map(|(k, p)| (NoisePublicKey::from(*k), p.endpoint));
        let Some((key, Some(ep))) = target else { return };
        match self.wg.encrypt(pkt, &key) {
            Ok(ct) => {
                self.counters.tunnel_out.fetch_add(1, Ordering::Relaxed);
                self.send_to_vm(&Self::udp_packet(VPN_IP, WG_PORT, *ep.ip(), ep.port(), &ct));
            }
            Err(e) => self.debug(|| format!("wireguard: encrypt for {dst} failed: {e}")),
        }
    }

    /// Run the WireGuard timers (rekeys, keepalives) forever.
    pub fn run_wg_timers(self: Arc<Self>) {
        let mut last_maint = Instant::now();
        loop {
            std::thread::sleep(Duration::from_millis(250));
            if self.server_down.load(Ordering::SeqCst) {
                continue;
            }
            for action in self.wg.poll_timers() {
                let (peer, packet) = match action {
                    TimerAction::SendHandshake { peer, packet } => (peer, packet),
                    TimerAction::SendKeepalive { peer, packet } => (peer, packet),
                    _ => continue,
                };
                let ep = self.peers.lock().unwrap().get(peer.as_bytes()).and_then(|p| p.endpoint);
                if let Some(ep) = ep {
                    self.send_to_vm(&Self::udp_packet(VPN_IP, WG_PORT, *ep.ip(), ep.port(), &packet));
                }
            }
            if last_maint.elapsed() > Duration::from_secs(10) {
                self.wg.maintenance();
                last_maint = Instant::now();
            }
        }
    }
}

/// The gateway's L3 face on the LAN, wrapped by an L2Adapter.
pub struct Gateway(pub Arc<World>);

impl L3Device for Gateway {
    fn set_handler(&self, h: L3Handler) {
        *self.0.to_vm.lock().unwrap() = Some(h);
    }
    fn send(&self, packet: &Packet) -> Result<()> {
        self.0.from_vm(packet);
        Ok(())
    }
    fn addr(&self) -> IpPrefix {
        IpPrefix::new(IpAddr::V4(LAN_GW), LAN_BITS)
    }
    fn set_addr(&self, _prefix: IpPrefix) -> Result<()> {
        Ok(())
    }
    fn close(&self) -> Result<()> {
        Ok(())
    }
}

/// Turn an IPv4 ICMP echo request into its reply.
fn echo_reply(pkt: &[u8]) -> Option<Vec<u8>> {
    let p = Packet::from_slice(pkt);
    let (src, dst) = (p.ipv4_src_addr()?, p.ipv4_dst_addr()?);
    let icmp = p.ipv4_payload();
    if icmp.len() < 8 || icmp[0] != 8 {
        return None;
    }
    let mut r = icmp.to_vec();
    r[0] = 0;
    r[2] = 0;
    r[3] = 0;
    let sum = pktkit::checksum(&r);
    r[2..4].copy_from_slice(&sum.to_be_bytes());
    Some(pktkit::build::build_ipv4(dst, src, Protocol::ICMP, 64, &r))
}

fn getrandom(buf: &mut [u8]) {
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buf))
        .expect("read /dev/urandom");
}
