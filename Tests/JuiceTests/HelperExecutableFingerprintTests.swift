import Foundation
import Testing
@testable import JuiceXPCShared

@Suite("Helper executable fingerprint")
struct HelperExecutableFingerprintTests {
    @Test("Parses the fingerprint appended to a handshake version")
    func parsesHandshakeFingerprint() {
        #expect(HelperExecutableFingerprint.fromHandshakeVersion(
            "1.1.0|sha256:abc123") == "abc123")
        #expect(HelperExecutableFingerprint.fromHandshakeVersion("1.0.0") == nil)
    }

    @Test("Hashes the exact executable bytes")
    func hashesFileContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        #expect(HelperExecutableFingerprint.sha256(at: url) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
