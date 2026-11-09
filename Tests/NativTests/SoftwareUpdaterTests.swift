import Foundation
import Sparkle
import XCTest

@MainActor
final class SoftwareUpdaterTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "SoftwareUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func updater(_ defaults: UserDefaults, version: String = "0.3.7", build: String = "100") -> SoftwareUpdater {
        SoftwareUpdater(defaults: defaults, info: [
            "NativReleaseVersion": version, "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "CFBundleIdentifier": NativBuildIdentity.namespace,
            "SUFeedURL": "https://github.com/CharafChnioune/nativ/releases/latest/download/appcast.xml",
            "NativPreviewFeedURL": "https://github.com/CharafChnioune/nativ/releases/download/preview/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        ])
    }

    // The legacy item initializer is sufficient for testing metadata selection;
    // OS/hardware compatibility is deliberately left to Sparkle.
    private func item(_ version: String, build: String, channel: String? = nil) -> SUAppcastItem {
        var properties: [String: Any] = [
            "sparkle:version": build,
            "sparkle:shortVersionString": version,
            "enclosure": ["url": "https://github.com/CharafChnioune/nativ/releases/download/v\(version)/Nativ-\(version).dmg", "length": "100"],
        ]
        properties["sparkle:channel"] = channel
        return SUAppcastItem(dictionary: properties)!
    }

    func testReleaseOrderingAndValidation() throws {
        let ordered = ["0.3.9", "0.4.0rc1", "0.4.0rc2", "0.4.0rc10", "0.4.0", "0.4.1rc1", "1.0.0"]
        let versions = try ordered.map { try XCTUnwrap(ReleaseVersion($0)) }
        XCTAssertEqual(versions.reversed().sorted(), versions)
        XCTAssertEqual(ReleaseVersion("0.4"), ReleaseVersion("0.4.0"))
        for invalid in ["v0.4.0", "0.4.0rc0", "0.4.0rc01", "0.4.0-rc1", "0.4.0beta1", "0.4.0\n", "01.4.0", "", "999999999999999999999.4.0"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
    }

    func testStableUsersCannotReceiveCandidatesEvenWithMissingChannel() {
        let stable = SoftwareUpdateChannel.stable
        XCTAssertFalse(stable.permits(version: "0.4.0rc1", channel: "rc", installedVersion: "0.3.7"))
        XCTAssertFalse(stable.permits(version: "0.4.0rc1", channel: nil, installedVersion: "0.3.7"))
        XCTAssertTrue(stable.permits(version: "0.4.0", channel: nil, installedVersion: "0.3.7"))
    }

    func testCandidateChannelStillReceivesStableAndRejectsOtherChannels() {
        let preview = SoftwareUpdateChannel.releaseCandidates
        XCTAssertTrue(preview.permits(version: "0.4.0rc2", channel: "rc", installedVersion: "0.4.0rc1"))
        XCTAssertTrue(preview.permits(version: "0.4.0", channel: nil, installedVersion: "0.4.0rc2"))
        XCTAssertFalse(preview.permits(version: "0.4.0rc2", channel: nil, installedVersion: "0.4.0rc1"))
        XCTAssertFalse(preview.permits(version: "0.5.0", channel: "nightly", installedVersion: "0.4.0"))
        XCTAssertFalse(preview.permits(version: "garbage", channel: nil, installedVersion: "0.4.0"))
    }

    func testOptingOutWaitsForFinalWithoutDowngrading() {
        XCTAssertFalse(SoftwareUpdateChannel.stable.permits(version: "0.3.8", channel: nil, installedVersion: "0.4.0rc1"))
        XCTAssertFalse(SoftwareUpdateChannel.stable.permits(version: "0.4.0rc2", channel: "rc", installedVersion: "0.4.0rc1"))
        XCTAssertTrue(SoftwareUpdateChannel.stable.permits(version: "0.4.0", channel: nil, installedVersion: "0.4.0rc1"))
    }

    func testPreferencesDefaultStableAndPersistOptIn() {
        let defaults = defaults()
        defaults.set("unknown-future-channel", forKey: SoftwareUpdateChannel.storageKey)
        let current = updater(defaults)
        XCTAssertEqual(current.channel, .stable)
        XCTAssertEqual(current.feedURLString(for: current.updater), "https://github.com/CharafChnioune/nativ/releases/latest/download/appcast.xml")
        XCTAssertEqual(current.allowedChannels(for: current.updater), [])
        current.setChannel(.releaseCandidates)
        let restored = updater(defaults)
        XCTAssertEqual(restored.channel, .releaseCandidates)
        XCTAssertEqual(restored.allowedChannels(for: restored.updater), ["rc"])
        XCTAssertEqual(restored.feedURLString(for: restored.updater), "https://github.com/CharafChnioune/nativ/releases/download/preview/appcast.xml")
        restored.setChannel(.stable)
        XCTAssertEqual(updater(defaults).channel, .stable)
    }

    func testSelectionUsesPublicVersionBeforeBuildTimestamp() {
        let defaults = defaults()
        defaults.set("releaseCandidates", forKey: SoftwareUpdateChannel.storageKey)
        let current = updater(defaults, version: "0.4.0rc1")
        let final = item("0.4.0", build: "200")
        let backport = item("0.3.8", build: "400")
        let rebuiltCandidate = item("0.4.0rc2", build: "300", channel: "rc")
        XCTAssertTrue(current.bestUpdate(in: [backport, rebuiltCandidate, final]) === final)
        let stable = updater(defaults, version: "0.4.0", build: "200")
        XCTAssertNil(stable.bestUpdate(in: [backport, rebuiltCandidate]))
    }

    func testStableSelectionIgnoresMalformedUnchannelledCandidate() {
        let current = updater(defaults())
        let stable = item("0.3.8", build: "200")
        XCTAssertTrue(current.bestUpdate(in: [item("0.4.0rc1", build: "300"), stable]) === stable)
    }

    func testDownloadedUpdateLocksChannelAcrossRelaunchUntilResolved() {
        let defaults = defaults()
        defaults.set("releaseCandidates", forKey: SoftwareUpdateChannel.storageKey)
        let current = updater(defaults)
        current.updater(current.updater, didDownloadUpdate: item("0.4.0rc1", build: "200", channel: "rc"))
        XCTAssertFalse(current.canChangeChannel)
        current.setChannel(.stable)
        XCTAssertEqual(current.channel, .releaseCandidates)
        let restored = updater(defaults)
        XCTAssertFalse(restored.canChangeChannel)
        restored.userDidCancelDownload(restored.updater)
        XCTAssertTrue(restored.canChangeChannel)
        restored.setChannel(.stable)
        XCTAssertEqual(restored.channel, .stable)
    }

    func testInstalledUpdateUnlocksChannel() {
        let defaults = defaults()
        let current = updater(defaults)
        current.updater(current.updater, didDownloadUpdate: item("0.4.0", build: "200"))
        XCTAssertTrue(updater(defaults, version: "0.4.0", build: "200").canChangeChannel)
    }

    func testDisplayMetadataFallsBackForExistingBuilds() {
        XCTAssertEqual(ReleaseVersion.displayString(in: ["CFBundleShortVersionString": "0.3.7"]), "0.3.7")
        XCTAssertEqual(ReleaseVersion.displayString(in: ["CFBundleShortVersionString": "0.4.0", "NativReleaseVersion": "0.4.0rc1"]), "0.4.0rc1")
        XCTAssertEqual(ReleaseVersion.displayString(in: ["CFBundleShortVersionString": "0.4.0", "NativReleaseVersion": "$(NATIV_RELEASE_VERSION)"]), "0.4.0")
    }

    func testMissingOrUpstreamIdentityDisablesUpdates() {
        let unavailable = SoftwareUpdater(defaults: defaults(), info: ["CFBundleVersion": "1"])
        unavailable.start()
        XCTAssertFalse(unavailable.isConfigured)
        XCTAssertFalse(unavailable.canChangeChannel)
        XCTAssertNil(unavailable.feedURLString(for: unavailable.updater))
        XCTAssertTrue(unavailable.channelDescription.contains("unavailable"))
        var info: [String: Any] = [
            "CFBundleIdentifier": NativBuildIdentity.namespace,
            "SUFeedURL": "https://github.com/CharafChnioune/nativ/releases/latest/download/appcast.xml",
            "NativPreviewFeedURL": "https://github.com/CharafChnioune/nativ/releases/download/preview/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        ]
        XCTAssertNotNil(NativUpdateConfiguration(info: info))
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var changed = info
            changed[key] = false
            XCTAssertNil(NativUpdateConfiguration(info: changed))
            changed.removeValue(forKey: key)
            XCTAssertNil(NativUpdateConfiguration(info: changed))
        }
        for key in ["SUFeedURL", "NativPreviewFeedURL"] {
            var changed = info
            changed[key] = "https://github.com/Neywa-Labs/nativ/releases/latest/download/appcast.xml"
            XCTAssertNil(NativUpdateConfiguration(info: changed))
        }
        info["SUPublicEDKey"] = NativUpdateConfiguration.upstreamPublicKey
        XCTAssertNil(NativUpdateConfiguration(info: info))
    }

    func testUpstreamArchiveCannotBeSelectedFromAnyFeed() {
        let upstream = SUAppcastItem(dictionary: [
            "sparkle:version": "999", "sparkle:shortVersionString": "9.0.0",
            "enclosure": ["url": "https://github.com/Neywa-Labs/nativ/releases/download/v9.0.0/Nativ-9.0.0.dmg", "length": "100"],
        ])!
        XCTAssertNil(updater(defaults()).bestUpdate(in: [upstream]))
    }

    func testForkStorageStaysOutOfUpstreamNamespace() {
        // Upstream Nativ uses ~/Library/{Application Support,Caches}/Nativ; the fork must never share them.
        for url in [SystemTelemetryRecorder.defaultDirectory, ParakeetModelStore.cacheDirectory] {
            XCTAssertTrue(url.path.contains("/\(NativBuildIdentity.namespace)/"), url.path)
            XCTAssertFalse(url.path.contains("/Nativ/"), url.path)
        }
        XCTAssertEqual(KeychainGitHubOAuthCredentialStore.defaultService, NativBuildIdentity.namespace + ".github-oauth")
    }
}
