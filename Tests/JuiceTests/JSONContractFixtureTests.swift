import Foundation
import Testing

@Suite("JSON export contract fixtures")
struct JSONContractFixtureTests {
    private func readExample(_ name: String) throws -> [String: Any] {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("contracts/v0.1/examples")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test(
        "examples use the versioned envelope",
        arguments: [
            "now-windows.json",
            "top-windows.json",
            "no-power-source.json"
        ]
    )
    func examplesUseVersionedEnvelope(name: String) throws {
        let document = try readExample(name)

        #expect(document["schemaVersion"] as? String == "0.1")
        #expect(document["platform"] as? String == "windows")
        #expect(!(document["command"] as? String ?? "").isEmpty)
        #expect(document["generatedAt"] is String)
        #expect(document["ok"] is Bool)
    }

    @Test("unknown measurements are omitted")
    func nowFixtureOmitsUnmeasuredValues() throws {
        let document = try readExample("now-windows.json")
        let measurement = try #require(document["measurement"] as? [String: Any])
        let rails = try #require(measurement["rails"] as? [String: Any])
        let battery = try #require(document["battery"] as? [String: Any])

        #expect(rails["npu"] == nil)
        #expect(battery["chargeWatts"] == nil)
    }

    @Test("top energy reconciles")
    func topFixtureEnergyReconciles() throws {
        let document = try readExample("top-windows.json")
        let energy = try #require(document["energy"] as? [String: Any])
        let system = try #require(energy["systemWattHours"] as? NSNumber)
        let attributed = try #require(energy["attributedWattHours"] as? NSNumber)
        let platform = try #require(energy["platformWattHours"] as? NSNumber)

        #expect(abs(system.doubleValue - attributed.doubleValue - platform.doubleValue) < 0.000_000_001)
    }

    @Test("failure uses the same envelope")
    func failureFixtureUsesSameEnvelope() throws {
        let document = try readExample("no-power-source.json")
        let error = try #require(document["error"] as? [String: Any])

        #expect(document["ok"] as? Bool == false)
        #expect(error["code"] as? String == "noPowerSource")
        #expect(document["measurement"] == nil)
    }
}
