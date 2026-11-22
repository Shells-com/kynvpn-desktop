//! mockworld: the entire network a Kyn VPN end-to-end test VM is plugged
//! into. See tests/e2e/README.md.
//!
//! Usage: mockworld --qemu-socket PATH --www DIR --cert PEM --key PEM
//!                  [--result FILE] [--artifacts DIR] [--timeout SECS] [--verbose]
//!
//! QEMU connects with `-netdev stream,addr.type=unix,addr.path=PATH`. The
//! process exits when the guest posts its result to /e2e/result (status 0 if
//! it passed, 1 if not), or 2 on timeout.

mod api;
mod dns;
mod world;

use httpsd::session::{Session, SessionConfig};
use httpsd::tls::TlsAcceptor;
use pktkit::{IpPrefix, L2Hub};
use serde_json::{Value, json};
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use world::World;

struct Args {
    qemu_socket: PathBuf,
    www: PathBuf,
    cert: PathBuf,
    key: PathBuf,
    result: Option<PathBuf>,
    artifacts: Option<PathBuf>,
    timeout: u64,
    verbose: bool,
}

fn parse_args() -> Args {
    let mut a = Args {
        qemu_socket: PathBuf::new(),
        www: PathBuf::new(),
        cert: PathBuf::new(),
        key: PathBuf::new(),
        result: None,
        artifacts: None,
        timeout: 900,
        verbose: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut val = || it.next().unwrap_or_else(|| die(&format!("{arg} needs a value")));
        match arg.as_str() {
            "--qemu-socket" => a.qemu_socket = val().into(),
            "--www" => a.www = val().into(),
            "--cert" => a.cert = val().into(),
            "--key" => a.key = val().into(),
            "--result" => a.result = Some(val().into()),
            "--artifacts" => a.artifacts = Some(val().into()),
            "--timeout" => a.timeout = val().parse().unwrap_or_else(|_| die("bad --timeout")),
            "--verbose" => a.verbose = true,
            _ => die(&format!("unknown argument {arg}")),
        }
    }
    if a.qemu_socket.as_os_str().is_empty() || a.www.as_os_str().is_empty() {
        die("--qemu-socket and --www are required");
    }
    a
}

fn die(msg: &str) -> ! {
    eprintln!("mockworld: {msg}");
    std::process::exit(64);
}

/// Serve one HTTP(S) connection accepted on the slirp stack.
fn serve_conn(stream: pktkit::slirp::TcpStream, tls: Option<Arc<TlsAcceptor>>, cfg: SessionConfig, w: Arc<World>) {
    let mut session = match &tls {
        Some(acc) => match acc.accept() {
            Ok(t) => Session::tls(cfg, t),
            Err(e) => return w.log(format!("tls accept: {e}")),
        },
        None => Session::plain(cfg),
    };
    session.set_addrs(Some(stream.peer_addr()), Some(stream.local_addr()));
    stream.set_read_timeout(Some(Duration::from_secs(120)));
    let mut buf = vec![0u8; 16384];
    loop {
        let n = match stream.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if let Err(e) = session.received(&buf[..n]) {
            w.log(format!("http session error from {}: {e}", stream.peer_addr()));
            let _ = session.to_send().map(|out| write_all(&stream, &out));
            break;
        }
        match session.to_send() {
            Ok(out) if !out.is_empty() => {
                if write_all(&stream, &out).is_err() {
                    break;
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
        if session.wants_close() {
            break;
        }
    }
    let _ = stream.close();
}

fn write_all(stream: &pktkit::slirp::TcpStream, mut data: &[u8]) -> std::io::Result<()> {
    while !data.is_empty() {
        let n = stream.write(data)?;
        if n == 0 {
            return Err(std::io::ErrorKind::WriteZero.into());
        }
        data = &data[n..];
    }
    Ok(())
}

fn main() {
    let args = parse_args();
    let (done_tx, done_rx) = std::sync::mpsc::channel::<Value>();
    let w = World::new(done_tx, args.verbose);

    let tls = if args.cert.as_os_str().is_empty() {
        die("--cert and --key are required")
    } else {
        let cert = std::fs::read_to_string(&args.cert).unwrap_or_else(|e| die(&format!("cert: {e}")));
        let key = std::fs::read_to_string(&args.key).unwrap_or_else(|e| die(&format!("key: {e}")));
        Arc::new(TlsAcceptor::from_pem(&cert, &key).unwrap_or_else(|e| die(&format!("tls: {e}"))))
    };

    // The internet: a slirp stack that only has virtual listeners. Refusing
    // every real destination keeps the VM off the host's network.
    let stack = pktkit::slirp::Stack::new();
    stack.set_dest_filter(Some(Arc::new(|_, _| false)));
    stack.set_mtu(world::TUNNEL_MTU).expect("mtu");
    let any = IpPrefix::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);
    let outside = {
        let w = w.clone();
        world::Port::new(any, move |p| w.outside_out(p))
    };
    let tunnel = {
        let w = w.clone();
        world::Port::new(any, move |p| w.tunnel_out_bytes(p.as_bytes()))
    };
    let (_ns_out, _c1) = stack.attach(outside.clone()).expect("attach outside");
    let (_ns_tun, _c2) = stack.attach(tunnel.clone()).expect("attach tunnel");
    *w.outside.lock().unwrap() = Some(outside);
    *w.tunnel.lock().unwrap() = Some(tunnel);

    let api: Arc<dyn httpsd::Handler> = Arc::new(api::Api { world: w.clone(), www: args.www.clone(), artifacts: args.artifacts.clone() });
    let cfg = SessionConfig::new(api);
    let services: &[(Ipv4Addr, u16, bool)] = &[
        (world::API_IP, 443, true),
        (world::IP_API_IP, 443, true),
        (world::VPN_IP, 443, true),
        (world::VPN_IP, world::WG_PORT, true),
        (world::META_TUNNEL_IP, 443, true),
        (world::FILES_IP, 80, false),
        (world::LAN_GW, 80, false),
    ];
    for &(ip, port, secure) in services {
        let l = stack.listen("tcp", &format!("{ip}:{port}")).expect("listen");
        let (cfg, w, tls) = (cfg.clone(), w.clone(), secure.then(|| tls.clone()));
        std::thread::spawn(move || {
            while let Ok(s) = l.accept() {
                let (cfg, w, tls) = (cfg.clone(), w.clone(), tls.clone());
                std::thread::spawn(move || serve_conn(s, tls, cfg, w));
            }
        });
    }

    // The LAN: hub, DHCP server, gateway.
    let hub = Arc::new(L2Hub::new());
    let mut dhcp_cfg = pktkit::dhcp::ServerConfig::new(
        world::LAN_DHCP,
        Ipv4Addr::new(192, 168, 77, 100),
        Ipv4Addr::new(192, 168, 77, 150),
    );
    dhcp_cfg.router = Some(world::LAN_GW);
    dhcp_cfg.dns = vec![world::LAN_GW];
    dhcp_cfg.lease_time = Duration::from_secs(12 * 3600);
    let _dhcp = hub.connect(pktkit::dhcp::Server::new(dhcp_cfg));
    let gw = pktkit::L2Adapter::new(world::Gateway(w.clone()), Default::default());
    let _gw = hub.connect_arc(gw);

    {
        let w = w.clone();
        std::thread::spawn(move || w.run_wg_timers());
    }

    let _ = std::fs::remove_file(&args.qemu_socket);
    let listener = pktkit::qemu::Listener::bind_unix(&args.qemu_socket)
        .unwrap_or_else(|e| die(&format!("bind {}: {e}", args.qemu_socket.display())));
    {
        let (hub, w) = (hub.clone(), w.clone());
        std::thread::spawn(move || {
            let mut ports = Vec::new();
            while let Ok(conn) = listener.accept() {
                w.log("qemu: VM connected");
                ports.push(hub.connect_arc(conn));
            }
        });
    }
    w.log(format!(
        "mockworld ready on {} (wireguard server key {})",
        args.qemu_socket.display(),
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, w.wg.public_key().as_bytes())
    ));

    let result = match done_rx.recv_timeout(Duration::from_secs(args.timeout)) {
        Ok(v) => v,
        Err(_) => json!({ "pass": false, "error": format!("timed out after {}s", args.timeout) }),
    };
    let report = json!({ "guest": result, "world": w.state_report(Ipv4Addr::UNSPECIFIED), "leaks": w.leak_report() });
    let text = serde_json::to_string_pretty(&report).unwrap();
    if let Some(p) = &args.result {
        let _ = std::fs::write(p, &text);
    }
    println!("{text}");
    let timed_out = result.get("error").and_then(|e| e.as_str()).is_some_and(|e| e.starts_with("timed out"));
    std::process::exit(if result["pass"] == true { 0 } else if timed_out { 2 } else { 1 });
}
