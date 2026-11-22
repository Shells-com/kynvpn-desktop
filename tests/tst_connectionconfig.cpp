// Copyright (c) 2026 Private Internet Access, Inc.
//
// This file is part of the Private Internet Access Desktop Client.
//
// The Private Internet Access Desktop Client is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// The Private Internet Access Desktop Client is distributed in the hope that
// it will be useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with the Private Internet Access Desktop Client.  If not, see
// <https://www.gnu.org/licenses/>.

#include <common/src/common.h>
#include <QtTest>

#include "daemon/src/vpn.h"
#include "common/src/locations.h"

namespace
{
    QStringList piaDummyDnsServers{QStringLiteral("209.222.18.222"), QStringLiteral("209.222.18.218")};

    const auto locationJson = QJsonDocument::fromJson(R"(
{
  "groups": {
    "ovpntcp": [{ "name": "openvpn_tcp", "ports": [80, 443] }],
    "ovpnudp": [{ "name": "openvpn_udp", "ports": [8080, 853] }]
  },
  "regions": [
    {
      "id": "nz",
      "name": "New Zealand",
      "country": "NZ",
      "auto_region": true,
      "dns": "nz.privacy.network",
      "port_forward": true,
      "geo": false,
      "offline": false,
      "servers": {
        "ovpnudp": [{ "ip": "43.250.207.86", "cn": "newzealand403" }],
        "ovpntcp": [{ "ip": "43.250.207.85", "cn": "newzealand403" }]
      }
    }
  ]
}
)").object();
    const auto metadataJson = QJsonDocument::fromJson(R"({
        "translations":{},
        "country_groups":{},
        "gps":{}
    })").object();
}

class tst_connectionconfig : public QObject
{
    Q_OBJECT

private slots:

    // Default (PIA dns)
    void testGetDnsServers()
    {
        ConnectionConfig config1;
        QVERIFY(config1.dnsType() == ConnectionConfig::DnsType::Pia);
    }

    // Handshake DNS
    void testGenDnsServersHdns()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.overrideDNS(QStringLiteral("hdns"));
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.getDnsServers() == QStringList{hDnsAddress()});
        QVERIFY(config.dnsType() == ConnectionConfig::DnsType::HDns);
    }

    // Local DNS
    void testGenDnsServersLocal()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.overrideDNS(QStringLiteral("local"));
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.getDnsServers() == QStringList{resolverLocalAddress()});
        QVERIFY(config.dnsType() == ConnectionConfig::DnsType::Local);
    }

    // Custom DNS
    void testGetDnsServersCustom()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        auto customDns = QStringList{"1.1.1.1", "8.8.8.8"};
        settings.overrideDNS(customDns);
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.getDnsServers() == customDns);
        QVERIFY(config.dnsType() == ConnectionConfig::DnsType::Custom);
        // special getter only for customDns
        QVERIFY(config.customDns() == customDns);
    }

    // Existing DNS
    void testGetDnsServersExisting()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        auto emptyList = QStringList{};
        settings.overrideDNS(""); // Empty string indicates Existing DNS
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.getDnsServers() == emptyList);
        QVERIFY(config.dnsType() == ConnectionConfig::DnsType::Existing);
    }

    void testMethodForcedByAuthDefault()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        // Default (OpenVPN)
        settings.method(QStringLiteral("openvpn"));
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.method() == ConnectionConfig::Method::OpenVPN);
        QVERIFY(config.methodForcedByAuth() == false);
    }

    void testMethodForcedByAuthWireguard()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.method(QStringLiteral("wireguard"));
        // valid token must match this regex: "^[0-9A-Fa-f]+$""
        account.token("BABA");
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.method() == ConnectionConfig::Method::Wireguard);
        QVERIFY(config.methodForcedByAuth() == false);
    }

    void testMethodForcedByAuthWireguardNoToken()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        // Wanted Wireguard but forced to OpenVPN as no valid token
        settings.method(QStringLiteral("wireguard"));
        account.token(""); // no token
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.method() == ConnectionConfig::Method::OpenVPN);
        QVERIFY(config.methodForcedByAuth() == true);
    }

    // Obfuscation is off by default, and only captured for WireGuard
    void testWireguardObfuscationDefault()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.method(QStringLiteral("wireguard"));
        account.token("BABA");
        ConnectionConfig config{settings, state, account};
        QVERIFY(config.wireguardObfuscation() == false);
    }

    // Enabling the setting is captured, except on Windows where AmneziaWG is
    // not supported at all
    void testWireguardObfuscationEnabled()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.method(QStringLiteral("wireguard"));
        settings.wireguardObfuscation(true);
        account.token("BABA");
        ConnectionConfig config{settings, state, account};
#if defined(Q_OS_WIN)
        QVERIFY(config.wireguardObfuscation() == false);
#else
        QVERIFY(config.wireguardObfuscation() == true);
#endif
    }

    // Toggling obfuscation has to reconnect to apply
    void testWireguardObfuscationRequiresReconnect()
    {
        DaemonSettings settings;
        StateModel state;
        DaemonAccount account;

        settings.method(QStringLiteral("wireguard"));
        account.token("BABA");
        ConnectionConfig configOff{settings, state, account};

        settings.wireguardObfuscation(true);
        ConnectionConfig configOn{settings, state, account};

#if defined(Q_OS_WIN)
        // The setting is ignored on Windows, so nothing changes
        QVERIFY(!configOff.hasChanged(configOn));
#else
        QVERIFY(configOff.hasChanged(configOn));
#endif
    }

    void testparseIpv4Host()
    {
        // Valid Ipv4 IP
        QHostAddress address1 = ConnectionConfig::parseIpv4Host(QStringLiteral("1.1.1.1"));
        QVERIFY(!address1.isNull());

        // Hostnames are not accepted
        QTest::ignoreMessage(QtInfoMsg, "Invalid SOCKS proxy address: \"privateinternetaccess.com\"");
        QHostAddress address2 = ConnectionConfig::parseIpv4Host(QStringLiteral("privateinternetaccess.com"));
        QVERIFY(address2.isNull());

        // Ipv6 IP are not accepted
        QTest::ignoreMessage(QtWarningMsg, "Invalid SOCKS proxy network protocol QAbstractSocket::IPv6Protocol for address QHostAddress(\"fe80::1\") - parsed from \"fe80::1\"");
        QHostAddress address3 = ConnectionConfig::parseIpv4Host(QStringLiteral("fe80::1"));
        QVERIFY(address3.isNull());
    }
};

QTEST_GUILESS_MAIN(tst_connectionconfig)
#include TEST_MOC
