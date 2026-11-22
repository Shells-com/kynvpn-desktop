# Changelog
### Next release
* All: Removed the opt-in connection statistics ("Help Improve") feature entirely. The app has no code left to send usage events
* All: Removed dedicated IPs
* All: Updated "What's new" for the Kyn VPN launch

### v1.0.3
* Internal: The Linux client is now tested end to end (install, connect, DNS, kill switch, reconnect) before it is published

### v1.0.2
* All: Fixed an extra empty entry in each country's location list
* All: Removed Shadowsocks from the Multi-Hop settings, since Kyn VPN has no Shadowsocks servers
* Linux: Fixed the installer skipping the service setup after a failed install
* Linux: Fixed a firewall rule that could be created without a VPN server address

### v1.0.1
* Linux: The installer now uses Kyn VPN's own file names and leaves other VPN apps' files alone

### v1.0.0
* First release of Kyn VPN
* All: WireGuard connections to Kyn VPN servers, with DNS through the tunnel
* All: The server list is signed and verified by the app before use
* All: Signed, notarized builds, with automatic updates that are verified before they're installed
