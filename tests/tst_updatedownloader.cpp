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

#include "daemon/src/updatedownloader.h"
#include <common/src/openssl.h>
#include <common/src/testshim.h>
#include "version.h"
#include "brand.h"
#include "src/mocknetwork.h"
#include <QtTest>

/*

=== UpdateDownloader tests ===

These tests validate UpdateDownloader.  Mainly, they validate the precedence
between the GA and beta channels, comparisons with the current daemon version,
and toggling the beta-related settings.  They also check that update metadata
is only accepted with a valid signature and an installer hash, and the hash
check of downloaded installers.

These tests are not intended to provide coverage of SemVersion or JsonRefresher,
which have separate tests.

*/

namespace TestData {

// Ed25519 key pair signing the mock update metadata.  This is a test key, it
// has nothing to do with the product's update key.
const QByteArray updateTestPrivKey = QByteArrayLiteral(
    "-----BEGIN PRIVATE KEY-----\n"
    "MC4CAQAwBQYDK2VwBCIEIDaMrB1Ql3j8rmQ+qurDxC13nu7BOLlRSbwpwsmWQ72M\n"
    "-----END PRIVATE KEY-----"
);
const QByteArray updateTestPubKey = QByteArrayLiteral(
    "-----BEGIN PUBLIC KEY-----\n"
    "MCowBQYDK2VwAyEAT5p+fVzHIUUipcmNxrxLnQwrA0FXG/Xy/462y+TzTrQ=\n"
    "-----END PUBLIC KEY-----"
);
// Another key, whose signatures must be rejected
const QByteArray otherPrivKey = QByteArrayLiteral(
    "-----BEGIN PRIVATE KEY-----\n"
    "MC4CAQAwBQYDK2VwBCIEIGKUtZpMoRl/9tlkgFvVGHzeaVv2KWXCrW9e7MZXJQ+z\n"
    "-----END PRIVATE KEY-----"
);

// Installer hashes for the mock updates (the tests never download them)
const QString hashA = QStringLiteral("aa00000000000000000000000000000000000000000000000000000000000001");
const QString hashB = QStringLiteral("bb00000000000000000000000000000000000000000000000000000000000002");

const QString &gaChannel = QStringLiteral("release");
const QString &betaChannel = QStringLiteral("beta");

// Newer release
// The UpdateDownloader uses the actual version even in unit tests, so the
// 'newer' version is set really high.
const Update newerGa{QStringLiteral("https://unit.test/v100"), QStringLiteral("100.0.0"), {}, hashA};
// Older release
const Update olderGa{QStringLiteral("https://unit.test/v080"), QStringLiteral("0.8.0"), {}, hashB};
// The same release.
// (The version here could actually have pre-release tags depending on the
// version being built.)
const Update sameGa{QStringLiteral("https://unit.test/vCurrent"), QString::fromStdString(Version::semanticVersion()), {}, hashA};

// The newer/older betas are relative to the "newer" GA release.
const Update newerBeta{QStringLiteral("https://unit.test/v101b"), QStringLiteral("101.0.0-beta.3"), {}, hashA};
const Update newerBeta2{QStringLiteral("https://unit.test/v102b"), QStringLiteral("102.0.0-beta.2"), {}, hashB};
const Update olderBeta{QStringLiteral("https://unit.test/v99b"), QStringLiteral("99.0.0-beta.7"), {}, hashB};

// Payload for no build at all on a channel.
// (Just an empty 'latest_version_piax' object.)
const QByteArray &noBuildPayload = QByteArrayLiteral("{\"" BRAND_UPDATE_JSON_KEY_NAME "\": {}}");

// Current build version - initialized by first test, which ensures that an
// invalid version fails the build.
SemVersion buildVersion{0, 0, 0};
bool buildIsBeta = false;

}

// Append the signature to update metadata, as the release signing does
QByteArray signPayload(const QByteArray &payload,
                       const QByteArray &privKey = TestData::updateTestPrivKey)
{
    const QByteArray signature{signEd25519(privKey, payload)};
    Q_ASSERT(!signature.isEmpty());
    return payload + "\n\n" + signature.toBase64() + "\n";
}

// Build the update payload JSON from an Update object (unsigned).
// The platform name, update version, and update URI are assumed not to contain
// characters that would have to be escaped in JSON; no escaping is performed.
QByteArray buildUnsignedUpdatePayload(const Update &update)
{
    return (R"(
{
    ")" + QStringLiteral(BRAND_UPDATE_JSON_KEY_NAME) + R"(": {
        ")" + UpdateChannel::platformName + R"(": {
            "version": ")" + update.version() + R"(",
            "download": ")" + update.uri() + R"(",
            "sha256": ")" + update.sha256() + R"("
        }
    }
})").toUtf8();
}

// Build the signed update payload from an Update object.
QByteArray buildUpdatePayload(const Update &update)
{
    return signPayload(buildUnsignedUpdatePayload(update));
}

// Enqueue an update payload reply
auto enqueueUpdateReply(const Update &update)
{
    return MockNetworkManager::enqueueReply(buildUpdatePayload(update));
}

Q_DECLARE_METATYPE(Update)
namespace
{
    RegisterMetaType<Update> rxUpdateMetaType;
}

// Diagnostic output for an Update.  See QTest::toString() - per doc, it is
// preferred to provide an overload in the type's namespace to be found by ADL.
//
// Avoid using this directly; it is for QCOMPARE() and friends.  The highly
// generic name is unfortunate, especially given the propensity for leaks due to
// the return value behavior.
char *toString(const Update &update)
{
    // Per doc, the string has to be allocated on the heap with new[], and we
    // rely on the caller to delete[] it.  QTest::toString() does this when
    // given a QString.
    return QTest::toString(QStringLiteral("Update: ") + update.version() +
        QStringLiteral(" - ") + update.uri());
}

// Test fixture - contains an UpdateDownloader with both release channel names
// set, and a QSignalSpy for the updateRefreshed signal.  The UpdateDownloader
// isn't started yet.
class DownloaderFixture
{
public:
    DownloaderFixture()
        : _downloader{}, _updateSpy{&_downloader, &UpdateDownloader::updateRefreshed}
    {
        _pUpdateApi = std::make_shared<FixedApiBase>(
                std::initializer_list<QString>{BRAND_UPDATE_APIS}
            );
        _downloader.setSignatureKey(TestData::updateTestPubKey);
        setGaUpdateChannel(TestData::gaChannel);
        setBetaUpdateChannel(TestData::betaChannel);
    }

public:
    // Shortcuts for a few methods of UpdateDownloader including the ApiBase
    // from DownloaderFixture automatically
    void run(bool newRunning) {_downloader.run(newRunning, _pUpdateApi);}
    void setGaUpdateChannel(const QString &channel) {_downloader.setGaUpdateChannel(channel, _pUpdateApi);}
    void setBetaUpdateChannel(const QString &channel) {_downloader.setBetaUpdateChannel(channel, _pUpdateApi);}
    void enableBetaChannel(bool enable) {_downloader.enableBetaChannel(enable, _pUpdateApi);}

public:
    // All data members are public; this is just a shortcut for test setup.
    std::shared_ptr<ApiBase> _pUpdateApi;
    UpdateDownloader _downloader;
    QSignalSpy _updateSpy;
};

class tst_updatedownloader : public QObject
{
    Q_OBJECT

private slots:
    void init()
    {
        TestShim::installMock<QNetworkAccessManager, MockNetworkManager>();
    }

    // Make sure the version number is sane.  This doesn't prevent a build from
    // running (to avoid causing a nuisance in development), but it does fail
    // unit tests to prevent such a build from being released.
    //
    // The tests below would probably fail anyway if the version number isn't
    // sane, since UpdateDownloader uses it, but this failure is clearer.
    void validateVersion()
    {
        // This throws if the version number is not sane, which fails the test.
        TestData::buildVersion = SemVersion{QString::fromStdString(Version::semanticVersion())};
        TestData::buildIsBeta = TestData::buildVersion.isPrereleaseType(u"beta");
    }

    // A newer release in GA should be offered.  (No beta channel in this test.)
    void testGaNewer()
    {
        DownloaderFixture fixture;
        QSignalSpy consumeSpy{&MockNetworkManager::_replyConsumed, &ReplyConsumedSignal::signal};

        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        fixture.run(true);
        QVERIFY(consumeSpy.wait(100));
        QVERIFY(!MockNetworkManager::hasNextReply());

        // Complete the response
        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        // The available update and GA update are both the newer release
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::newerGa);
        // Beta channel isn't active
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        // No feature flags
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // An older release in GA should be offered as a downgrade only if the
    // current build is a beta.
    void testGaOlder()
    {
        DownloaderFixture fixture;
        QSignalSpy consumeSpy{&MockNetworkManager::_replyConsumed, &ReplyConsumedSignal::signal};

        auto pGaReply = enqueueUpdateReply(TestData::olderGa);
        fixture.run(true);
        QVERIFY(consumeSpy.wait(100));
        QVERIFY(!MockNetworkManager::hasNextReply());

        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // Only one of these behaviors will be tested in a given build, since it
        // depends on the build version.  The other behavior doesn't matter in
        // that build though (a bug in the beta behavior of a non-beta build has
        // no effect, etc.)
        if(TestData::buildIsBeta)
        {
            // The GA release is offered
            QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::olderGa);
        }
        else
        {
            // No update is offered
            QCOMPARE(fixture._updateSpy[0][0].value<Update>(), Update{});
        }
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        // The cached GA update is the older release
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::olderGa);
        // Beta channel isn't active
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        // No feature flags
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // Exactly the same release in GA is not offered.
    void testGaSame()
    {
        DownloaderFixture fixture;
        QSignalSpy consumeSpy{&MockNetworkManager::_replyConsumed, &ReplyConsumedSignal::signal};

        auto pGaReply = enqueueUpdateReply(TestData::sameGa);
        fixture.run(true);
        QVERIFY(consumeSpy.wait(100));
        QVERIFY(!MockNetworkManager::hasNextReply());

        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        // There is no available update, but the release is still cached for the
        // GA channel.   Beta isn't active.
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::sameGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // Exactly the same release in beta is not offered.
    void testBetaSame()
    {
        DownloaderFixture fixture;

        auto pGaReply = enqueueUpdateReply(TestData::olderGa);
        auto pBetaReply = enqueueUpdateReply(TestData::sameGa);
        fixture.enableBetaChannel(true);
        fixture.run(true);
        // Finish GA reply - update is notified
        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        // Finish beta reply - update is notified
        pBetaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // Update for GA being fetched - nothing offered (even if the current
        // build is a beta, since the beta channel is enabled)
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::olderGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});

        // Update for beta being fetched - still nothing offered, since the
        // newest release is the same
        QCOMPARE(fixture._updateSpy[1][0].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[1][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[1][2].value<Update>(), TestData::olderGa);
        QCOMPARE(fixture._updateSpy[1][3].value<Update>(), TestData::sameGa);
        QCOMPARE(fixture._updateSpy[1][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // With beta active, a newer release supersedes GA
    void testBetaNewer()
    {
        DownloaderFixture fixture;

        // The responses are queued in the order that UpdateDownloader will
        // request them.  This isn't terribly robust (more robust would be to
        // check the requested URI), but it works for now and is validated by
        // checking the cached data provided to the updateRefreshed() signal.
        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        auto pBetaReply = enqueueUpdateReply(TestData::newerBeta);

        fixture.enableBetaChannel(true);
        fixture.run(true);

        pGaReply->queueFinished();
        // An update occurs when GA is fetched
        QVERIFY(fixture._updateSpy.wait());
        // Another update occurs when beta is fetched
        pBetaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // When GA only had been fetched, the GA release is offered
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});

        // When beta is fetched, it supersedes the GA release.  The GA release
        // is still cached on the GA channel.
        QCOMPARE(fixture._updateSpy[1][0].value<Update>(), TestData::newerBeta);
        QCOMPARE(fixture._updateSpy[1][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[1][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[1][3].value<Update>(), TestData::newerBeta);
        QCOMPARE(fixture._updateSpy[1][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // An older beta release does not supersede GA
    void testBetaOlder()
    {
        DownloaderFixture fixture;

        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        auto pBetaReply = enqueueUpdateReply(TestData::olderBeta);

        fixture.enableBetaChannel(true);
        fixture.run(true);

        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        pBetaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // When GA only had been fetched, the GA release is offered
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});

        // When beta is fetched, the GA release is still offered, but we cache
        // the older beta on that channel.
        QCOMPARE(fixture._updateSpy[1][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[1][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[1][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[1][3].value<Update>(), TestData::olderBeta);
        QCOMPARE(fixture._updateSpy[1][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // No beta release at all does not cause any issues; GA is still offered
    void testNoBeta()
    {
        DownloaderFixture fixture;

        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        auto pBetaReply = MockNetworkManager::enqueueReply(signPayload(TestData::noBuildPayload));

        fixture.enableBetaChannel(true);
        fixture.run(true);

        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        pBetaReply->queueFinished();
        // No change is emitted for this, because no build is found on the beta
        // channel.  (UpdateChannel does not emit a change in this case.)
        QVERIFY(!fixture._updateSpy.wait(1000));

        // When GA only had been fetched, the GA release is offered
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

    // Test toggling the beta channel.
    // Initially, just the GA channel is on with an update.  Then beta is
    // enabled, and beta supersedes GA.  Then, beta is disabled again.
    // Beta is then enabled again, and we act as if an even newer release was
    // published in the meantime, which should supersede GA again.
    void testToggleBeta()
    {
        DownloaderFixture fixture;

        // Start with just the GA channel
        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        fixture.run(true);

        pGaReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // Verify the update from GA.
        QCOMPARE(fixture._updateSpy[0][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[0][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[0][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[0][4].value<std::vector<QString>>(), std::vector<QString>{});

        // Enable the beta channel.  It has a newer beta initially.
        auto pBetaNewerReply = enqueueUpdateReply(TestData::newerBeta);
        fixture.enableBetaChannel(true);
        pBetaNewerReply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());

        // Verify the beta update.
        QCOMPARE(fixture._updateSpy[1][0].value<Update>(), TestData::newerBeta);
        QCOMPARE(fixture._updateSpy[1][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[1][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[1][3].value<Update>(), TestData::newerBeta);
        QCOMPARE(fixture._updateSpy[1][4].value<std::vector<QString>>(), std::vector<QString>{});

        // Disable the beta channel and verify that we offer the GA update
        // again.  This happens synchronouly and doesn't have to make any
        // network requests.
        fixture.enableBetaChannel(false);
        QVERIFY(fixture._updateSpy.length() == 3);  // Emitted synchronously
        // We go back to the GA update, and the beta cache is cleared.
        QCOMPARE(fixture._updateSpy[2][0].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[2][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[2][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[2][3].value<Update>(), Update{});
        QCOMPARE(fixture._updateSpy[2][4].value<std::vector<QString>>(), std::vector<QString>{});

        // Enable beta again.  We don't cache the beta channel when it's
        // stopped, so there shouldn't be any change at this point.
        auto pBetaNewer2Reply = enqueueUpdateReply(TestData::newerBeta2);
        fixture.enableBetaChannel(true);
        QVERIFY(!fixture._updateSpy.wait(1000));    // No signal expected

        // Act as if the beta channel had been updated while it was stopped.
        pBetaNewer2Reply->queueFinished();
        QVERIFY(fixture._updateSpy.wait());
        QCOMPARE(fixture._updateSpy[3][0].value<Update>(), TestData::newerBeta2);
        QCOMPARE(fixture._updateSpy[3][1].value<bool>(), false);
        QCOMPARE(fixture._updateSpy[3][2].value<Update>(), TestData::newerGa);
        QCOMPARE(fixture._updateSpy[3][3].value<Update>(), TestData::newerBeta2);
        QCOMPARE(fixture._updateSpy[3][4].value<std::vector<QString>>(), std::vector<QString>{});
    }

private:
    // Load one GA payload and check that no update is offered from it
    void checkRejected(const QByteArray &payload)
    {
        DownloaderFixture fixture;
        QSignalSpy consumeSpy{&MockNetworkManager::_replyConsumed, &ReplyConsumedSignal::signal};

        auto pGaReply = MockNetworkManager::enqueueReply(payload);
        fixture.run(true);
        QVERIFY(consumeSpy.wait(100));
        pGaReply->queueFinished();
        // The metadata is discarded, the (empty) update doesn't change
        QVERIFY(!fixture._updateSpy.wait(500));
    }

private slots:
    // Unsigned metadata is ignored
    void testUnsignedRejected()
    {
        checkRejected(buildUnsignedUpdatePayload(TestData::newerGa));
    }

    // Metadata signed by another key is ignored
    void testWrongKeyRejected()
    {
        checkRejected(signPayload(buildUnsignedUpdatePayload(TestData::newerGa),
                                  TestData::otherPrivKey));
    }

    // Metadata altered after signing is ignored
    void testTamperedRejected()
    {
        QByteArray payload{buildUpdatePayload(TestData::newerGa)};
        payload.replace("https://unit.test/v100", "https://evil.test/v100");
        checkRejected(payload);
    }

    // Signed metadata without a valid installer hash offers no update
    void testMissingHashRejected()
    {
        const Update noHash{TestData::newerGa.uri(), TestData::newerGa.version(), {}, {}};
        QVERIFY(!noHash.isValid());
        checkRejected(buildUpdatePayload(noHash));
        QByteArray shortHash{buildUnsignedUpdatePayload(TestData::newerGa)};
        shortHash.replace(TestData::hashA.toLatin1(), TestData::hashA.left(63).toLatin1());
        checkRejected(signPayload(shortHash));
    }

    // Without a signing key, no metadata is accepted, even signed
    void testNoKeyRejectsAll()
    {
        DownloaderFixture fixture;
        fixture._downloader.setSignatureKey({});
        // The key applies to channels set afterwards
        fixture.setGaUpdateChannel(TestData::gaChannel);
        QSignalSpy consumeSpy{&MockNetworkManager::_replyConsumed, &ReplyConsumedSignal::signal};
        auto pGaReply = enqueueUpdateReply(TestData::newerGa);
        fixture.run(true);
        QVERIFY(consumeSpy.wait(100));
        pGaReply->queueFinished();
        QVERIFY(!fixture._updateSpy.wait(500));
    }

    // Update only keeps well-formed hashes, lowercased
    void testUpdateHash()
    {
        const Update upper{QStringLiteral("https://unit.test/u"), QStringLiteral("1.0.0"), {},
                           TestData::hashA.toUpper()};
        QVERIFY(upper.isValid());
        QCOMPARE(upper.sha256(), TestData::hashA);
        const Update notHex{QStringLiteral("https://unit.test/u"), QStringLiteral("1.0.0"), {},
                            QString(64, QLatin1Char('g'))};
        QVERIFY(!notHex.isValid());
        QCOMPARE(notHex.uri(), QString{});
        QCOMPARE(notHex.version(), QString{});
    }

    // Downloaded installers are checked against the hash from the metadata
    void testInstallerHash()
    {
        const QByteArray installer{"installer contents"};
        const QByteArray actual{QCryptographicHash::hash(installer, QCryptographicHash::Sha256)};
        const QString expected{QString::fromLatin1(actual.toHex())};
        QVERIFY(UpdateDownloader::checkInstallerHash(actual, expected));
        // Another file, or no expected hash, never passes
        QVERIFY(!UpdateDownloader::checkInstallerHash(
            QCryptographicHash::hash("other", QCryptographicHash::Sha256), expected));
        QVERIFY(!UpdateDownloader::checkInstallerHash(actual, {}));
        QVERIFY(!UpdateDownloader::checkInstallerHash({}, {}));
    }
};

QTEST_GUILESS_MAIN(tst_updatedownloader)
#include TEST_MOC
