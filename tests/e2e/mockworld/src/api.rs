//! The HTTP side of the mock world: the Kyn account API, the IP check, the
//! VPN server's addKey, plain file serving for the guest, and the /e2e/
//! control endpoints the guest test script drives.

use crate::world::{self, World};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use httpsd::proto::{Request, Response, StatusCode};
use serde_json::{Value, json};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;

pub const USERNAME: &str = "e2e-user";
pub const PASSWORD: &str = "e2e-password";

fn json_response(status: StatusCode, v: Value) -> Response {
    Response::new(status)
        .header("Content-Type", "application/json")
        .body(v.to_string())
}

fn status(code: u16, reason: &'static str) -> StatusCode {
    StatusCode::new(code, reason)
}

/// Decode `application/x-www-form-urlencoded`-style query strings.
pub fn query_params(q: &str) -> Vec<(String, String)> {
    fn dec(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::with_capacity(b.len());
        let mut i = 0;
        while i < b.len() {
            match b[i] {
                b'+' => out.push(b' '),
                b'%' if i + 2 < b.len() => {
                    match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                        Ok(v) => {
                            out.push(v);
                            i += 2;
                        }
                        Err(_) => out.push(b'%'),
                    }
                }
                c => out.push(c),
            }
            i += 1;
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    q.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| match p.split_once('=') {
            Some((k, v)) => (dec(k), dec(v)),
            None => (dec(p), String::new()),
        })
        .collect()
}

fn param(req: &Request, name: &str) -> Option<String> {
    query_params(req.query().unwrap_or(""))
        .into_iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v)
}

pub struct Api {
    pub world: Arc<World>,
    pub www: PathBuf,
    /// Where files the guest uploads (logs) are written.
    pub artifacts: Option<PathBuf>,
}

impl httpsd::Handler for Api {
    fn handle(&self, req: &Request) -> Response {
        let local = req.local_addr();
        let peer = req.peer_addr();
        let resp = self.route(req, local, peer);
        self.world.log(format!(
            "http {} {}:{} {} {} -> {}",
            peer.map(|p| p.ip().to_string()).unwrap_or_default(),
            req.host().unwrap_or("-"),
            local.map(|l| l.port()).unwrap_or(0),
            req.method(),
            req.target(),
            resp.status_code().code()
        ));
        resp
    }
}

impl Api {
    fn route(&self, req: &Request, local: Option<SocketAddr>, peer: Option<SocketAddr>) -> Response {
        let Some(local) = local else {
            return Response::status(StatusCode::BAD_REQUEST);
        };
        let IpAddr::V4(lip) = local.ip() else {
            return Response::status(StatusCode::NOT_FOUND);
        };
        let peer_ip = match peer.map(|p| p.ip()) {
            Some(IpAddr::V4(ip)) => ip,
            _ => Ipv4Addr::UNSPECIFIED,
        };
        match (lip, local.port()) {
            (world::API_IP, 443) => self.account_api(req, req.path()),
            // The VPN server's meta service, used while disconnected and,
            // inside the tunnel, at 10.0.0.1.
            (world::VPN_IP, 443) | (world::META_TUNNEL_IP, 443) => {
                self.account_api(req, req.path())
            }
            (world::IP_API_IP, 443) => self.ip_api(req, peer_ip),
            (world::VPN_IP, world::WG_PORT) => self.add_key(req, peer_ip),
            (world::FILES_IP, 80) | (world::LAN_GW, 80) => self.files(req, peer_ip),
            _ => Response::status(StatusCode::NOT_FOUND),
        }
    }

    /// The account API. Reached either as
    /// `/_rest/Network/VPN:apiV2?resource=/token` (the platform REST base)
    /// or as `/apiv2/token` (a meta server).
    fn account_api(&self, req: &Request, path: &str) -> Response {
        let (version, resource) = if let Some(rest) = path.strip_prefix("/_rest/Network/VPN:") {
            let res = param(req, "resource").unwrap_or_default();
            (rest.to_ascii_lowercase(), res)
        } else if let Some(rest) = path.strip_prefix("/apiv2") {
            ("apiv2".to_owned(), rest.to_owned())
        } else if let Some(rest) = path.strip_prefix("/api/client/v5") {
            ("apiv5".to_owned(), rest.to_owned())
        } else {
            return Response::status(StatusCode::NOT_FOUND);
        };
        let resource = resource.trim_start_matches('/');
        let w = &self.world;
        let auth = req.headers().get("authorization").unwrap_or("");
        let token_ok = auth
            .strip_prefix("Token ")
            .is_some_and(|t| t == w.token && !w.token_expired.load(Ordering::SeqCst));
        let basic_ok = auth.strip_prefix("Basic ").is_some_and(|b| {
            B64.decode(b).ok().as_deref() == Some(format!("{USERNAME}:{PASSWORD}").as_bytes())
        });
        match (version.as_str(), resource) {
            ("apiv2", "token") => {
                let body: Value = serde_json::from_slice(req.body()).unwrap_or(Value::Null);
                if body["username"] == USERNAME && body["password"] == PASSWORD {
                    w.token_expired.store(false, Ordering::SeqCst);
                    w.counters.logins.fetch_add(1, Ordering::SeqCst);
                    json_response(StatusCode::OK, json!({ "token": w.token }))
                } else {
                    json_response(status(401, "Unauthorized"), json!({ "message": "bad credentials" }))
                }
            }
            ("apiv1" | "apiv2", "account") => {
                if !(token_ok || basic_ok) {
                    return json_response(status(401, "Unauthorized"), json!({}));
                }
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();
                json_response(
                    StatusCode::OK,
                    json!({
                        "plan": "monthly",
                        "active": true,
                        "canceled": false,
                        "recurring": true,
                        "needs_payment": false,
                        "days_remaining": 30,
                        "renewable": false,
                        "renew_url": "",
                        "expiration_time": now + 30 * 86400,
                        "expire_alert": false,
                        "expired": false,
                        "username": USERNAME,
                    }),
                )
            }
            ("apiv2", "expire_token") => {
                if token_ok {
                    w.token_expired.store(true, Ordering::SeqCst);
                    w.counters.token_expired.fetch_add(1, Ordering::SeqCst);
                    json_response(StatusCode::OK, json!({ "status": "success" }))
                } else {
                    json_response(status(401, "Unauthorized"), json!({}))
                }
            }
            _ => json_response(StatusCode::NOT_FOUND, json!({ "message": "not mocked" })),
        }
    }

    /// `https://ip.kynvpn.com/clientinfo/ip/v1`: reports the VPN exit address
    /// for requests that came through the tunnel, and the VM's "public"
    /// address otherwise.
    fn ip_api(&self, req: &Request, peer: Ipv4Addr) -> Response {
        if req.path().trim_end_matches('/') != "/clientinfo/ip/v1" {
            return Response::status(StatusCode::NOT_FOUND);
        }
        if world::in_tunnel_net(peer) {
            json_response(StatusCode::OK, json!({ "ip": world::VPN_IP.to_string(), "connected": true }))
        } else {
            json_response(StatusCode::OK, json!({ "ip": world::PUBLIC_IP.to_string(), "connected": false }))
        }
    }

    /// `https://<server>:1337/addKey?pubkey=…&pt=<token>`.
    fn add_key(&self, req: &Request, _peer: Ipv4Addr) -> Response {
        if req.path() != "/addKey" {
            return Response::status(StatusCode::NOT_FOUND);
        }
        let w = &self.world;
        if param(req, "pt").as_deref() != Some(w.token.as_str())
            || w.token_expired.load(Ordering::SeqCst)
        {
            return json_response(status(401, "Unauthorized"), json!({ "status": "ERROR", "message": "bad token" }));
        }
        let Some(key) = param(req, "pubkey")
            .and_then(|k| B64.decode(k.trim()).ok())
            .and_then(|k| <[u8; 32]>::try_from(k).ok())
        else {
            return json_response(StatusCode::BAD_REQUEST, json!({ "status": "ERROR", "message": "bad pubkey" }));
        };
        let peer_ip = w.add_wg_peer(key);
        json_response(
            StatusCode::OK,
            json!({
                "status": "OK",
                "server_key": B64.encode(w.wg.public_key().as_bytes()),
                "server_port": world::WG_PORT,
                "server_ip": world::VPN_IP.to_string(),
                "server_vip": world::SERVER_VIP.to_string(),
                "peer_ip": format!("{peer_ip}/32"),
                "peer_pubkey": B64.encode(key),
                "dns_servers": [world::TUNNEL_DNS.to_string()],
            }),
        )
    }

    /// Plain HTTP at files.kynvpn.test: the guest's seed, installer and test
    /// script, plus /e2e/ controls.
    fn files(&self, req: &Request, peer: Ipv4Addr) -> Response {
        let path = req.path();
        if let Some(cmd) = path.strip_prefix("/e2e/") {
            return self.control(req, cmd, peer);
        }
        let rel = path.trim_start_matches('/');
        if rel.split('/').any(|c| c == ".." || c.starts_with('.')) {
            return Response::status(StatusCode::NOT_FOUND);
        }
        let mut p = self.www.join(rel);
        if p.is_dir() {
            p = p.join("index");
        }
        match std::fs::read(&p) {
            Ok(data) => Response::new(StatusCode::OK)
                .header("Content-Type", "application/octet-stream")
                .body(data),
            Err(_) => Response::status(StatusCode::NOT_FOUND),
        }
    }

    fn control(&self, req: &Request, cmd: &str, peer: Ipv4Addr) -> Response {
        let w = &self.world;
        match cmd {
            "log" => {
                for line in req.body_str().lines() {
                    w.log(format!("guest: {line}"));
                }
                Response::text("ok")
            }
            // Leak accounting: while armed, every packet the VM sends outside
            // the tunnel (other than to the LAN or the WireGuard endpoint) is
            // a leak.
            "leaks/arm" => {
                w.reset_leaks();
                w.leak_armed.store(true, Ordering::SeqCst);
                Response::text("armed")
            }
            "leaks/disarm" => {
                w.leak_armed.store(false, Ordering::SeqCst);
                Response::text("disarmed")
            }
            "leaks" => json_response(StatusCode::OK, w.leak_report()),
            // Simulate the VPN server going dark (drop WireGuard and the
            // server's TCP services) or coming back.
            "server/down" => {
                w.server_down.store(true, Ordering::SeqCst);
                Response::text("down")
            }
            "server/up" => {
                w.server_down.store(false, Ordering::SeqCst);
                Response::text("up")
            }
            "state" => json_response(StatusCode::OK, w.state_report(peer)),
            _ if cmd.starts_with("upload/") => {
                let name = &cmd["upload/".len()..];
                let ok_name = !name.is_empty()
                    && !name.starts_with('.')
                    && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c));
                match (&self.artifacts, ok_name) {
                    (Some(dir), true) => match std::fs::write(dir.join(name), req.body()) {
                        Ok(()) => {
                            w.log(format!("saved {name} ({} bytes)", req.body().len()));
                            Response::text("saved")
                        }
                        Err(e) => json_response(status(500, "Internal Server Error"), json!({ "error": e.to_string() })),
                    },
                    (None, _) => Response::text("not saved"),
                    (_, false) => Response::status(StatusCode::BAD_REQUEST),
                }
            }
            "result" => {
                let v: Value = serde_json::from_slice(req.body()).unwrap_or_else(|_| {
                    json!({ "pass": false, "error": "unparseable result", "raw": req.body_str() })
                });
                w.finish(v);
                Response::text("bye")
            }
            _ => Response::status(StatusCode::NOT_FOUND),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::query_params;

    #[test]
    fn decodes_query() {
        let q = query_params("pubkey=ab%2Bc%3D&pt=0123&x");
        assert_eq!(q[0], ("pubkey".into(), "ab+c=".into()));
        assert_eq!(q[1], ("pt".into(), "0123".into()));
        assert_eq!(q[2], ("x".into(), String::new()));
    }
}
