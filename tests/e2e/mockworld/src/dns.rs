//! A tiny authoritative DNS responder for the mock world: A records for the
//! hosts the client talks to, NXDOMAIN for everything else (the VM has no
//! other internet to reach).

use std::net::Ipv4Addr;

pub struct Zone {
    hosts: Vec<(String, Ipv4Addr)>,
}

impl Zone {
    pub fn new(hosts: &[(&str, Ipv4Addr)]) -> Zone {
        Zone {
            hosts: hosts
                .iter()
                .map(|(n, ip)| (n.to_ascii_lowercase(), *ip))
                .collect(),
        }
    }

    pub fn lookup(&self, name: &str) -> Option<Ipv4Addr> {
        let name = name.trim_end_matches('.').to_ascii_lowercase();
        self.hosts.iter().find(|(n, _)| *n == name).map(|(_, ip)| *ip)
    }

    /// Answer one query. Returns the reply and the name asked about, or None
    /// for something that isn't a standard query.
    pub fn answer(&self, query: &[u8]) -> Option<(Vec<u8>, String)> {
        if query.len() < 12 {
            return None;
        }
        let flags = u16::from_be_bytes([query[2], query[3]]);
        let qdcount = u16::from_be_bytes([query[4], query[5]]);
        if flags & 0x8000 != 0 || (flags >> 11) & 0xF != 0 || qdcount != 1 {
            return None;
        }
        // Question: labels, then type and class.
        let mut pos = 12;
        let mut labels = Vec::new();
        loop {
            let len = *query.get(pos)? as usize;
            pos += 1;
            if len == 0 {
                break;
            }
            if len & 0xC0 != 0 {
                return None;
            }
            labels.push(String::from_utf8_lossy(query.get(pos..pos + len)?).into_owned());
            pos += len;
        }
        let qtype = u16::from_be_bytes([*query.get(pos)?, *query.get(pos + 1)?]);
        let qend = pos + 4;
        if query.len() < qend {
            return None;
        }
        let name = labels.join(".");
        let found = self.lookup(&name);

        let mut r = Vec::with_capacity(qend + 16);
        r.extend_from_slice(&query[0..2]);
        // QR, opcode 0, AA, RD copied, RA; rcode NOERROR or NXDOMAIN.
        let rcode = if found.is_some() { 0 } else { 3 };
        let rflags: u16 = 0x8000 | 0x0400 | (flags & 0x0100) | 0x0080 | rcode;
        r.extend_from_slice(&rflags.to_be_bytes());
        let ancount: u16 = if found.is_some() && qtype == 1 { 1 } else { 0 };
        r.extend_from_slice(&1u16.to_be_bytes());
        r.extend_from_slice(&ancount.to_be_bytes());
        r.extend_from_slice(&0u16.to_be_bytes());
        r.extend_from_slice(&0u16.to_be_bytes());
        r.extend_from_slice(&query[12..qend]);
        if ancount == 1 {
            let ip = found.unwrap();
            r.extend_from_slice(&[0xC0, 0x0C]); // pointer to the question name
            r.extend_from_slice(&1u16.to_be_bytes()); // A
            r.extend_from_slice(&1u16.to_be_bytes()); // IN
            r.extend_from_slice(&60u32.to_be_bytes());
            r.extend_from_slice(&4u16.to_be_bytes());
            r.extend_from_slice(&ip.octets());
        }
        Some((r, name))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(name: &str, qtype: u16) -> Vec<u8> {
        let mut q = vec![0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        for l in name.split('.') {
            q.push(l.len() as u8);
            q.extend_from_slice(l.as_bytes());
        }
        q.push(0);
        q.extend_from_slice(&qtype.to_be_bytes());
        q.extend_from_slice(&1u16.to_be_bytes());
        q
    }

    #[test]
    fn answers_known_and_unknown() {
        let z = Zone::new(&[("ip.kynvpn.com", Ipv4Addr::new(203, 0, 113, 11))]);
        let (r, n) = z.answer(&query("IP.kynvpn.com", 1)).unwrap();
        assert_eq!(n, "IP.kynvpn.com");
        assert_eq!(r[3] & 0xF, 0);
        assert_eq!(&r[r.len() - 4..], &[203, 0, 113, 11]);
        let (r, _) = z.answer(&query("ip.kynvpn.com", 28)).unwrap();
        assert_eq!((r[3] & 0xF, r[7]), (0, 0)); // AAAA: NOERROR, no answer
        let (r, _) = z.answer(&query("github.com", 1)).unwrap();
        assert_eq!(r[3] & 0xF, 3);
    }
}
