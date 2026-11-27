import Foundation
import Testing
@testable import TextReaderHelper

/// When Slit is allowed to look for updates at all.
struct UpdateConfigurationTests {
    private static let key = Data(repeating: 7, count: 32).base64EncodedString()
    private static let feed = "https://raw.githubusercontent.com/Ryukun1/slit/main/appcast.xml"

    @Test("A packaged app with a feed and a key can update")
    func configured() throws {
        let config = try #require(UpdateConfiguration(info: [
            "SUFeedURL": Self.feed, "SUPublicEDKey": Self.key,
        ]))

        #expect(config.feedURL.absoluteString == Self.feed)
        #expect(config.publicKey == Self.key)
    }

    @Test("Without Info.plist values (swift run, tests) it never goes online")
    func unpackaged() {
        #expect(UpdateConfiguration(info: nil) == nil)
        #expect(UpdateConfiguration(info: [:]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": Self.feed]) == nil)
        #expect(UpdateConfiguration(info: ["SUPublicEDKey": Self.key]) == nil)
    }

    @Test("Updates are only fetched over HTTPS")
    func requiresHTTPS() {
        #expect(UpdateConfiguration(info: [
            "SUFeedURL": "http://raw.githubusercontent.com/Ryukun1/slit/main/appcast.xml",
            "SUPublicEDKey": Self.key,
        ]) == nil)
    }

    @Test("A key that is not a 32-byte Ed25519 key is refused", arguments: [
        "", "not base64!", Data(repeating: 1, count: 16).base64EncodedString(),
        Data(repeating: 1, count: 64).base64EncodedString(),
    ])
    func rejectsBadKey(key: String) {
        #expect(UpdateConfiguration(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": key]) == nil)
    }

    @Test("Slit's real public key is well-formed")
    func realKey() {
        #expect(UpdateConfiguration(info: [
            "SUFeedURL": Self.feed,
            "SUPublicEDKey": "DOR7SRSzTrCnOF5ksh+5sgSN+8yCxVfhGepO4tmR3r0=",
        ]) != nil)
    }
}
