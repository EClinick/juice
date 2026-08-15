import Testing
@testable import Juice

@Suite("Juice application information")
struct JuiceApplicationInfoTests {
    @Test("Bundle display name and complete version are presented")
    func completeBundleInformation() {
        let info = JuiceApplicationInfo(infoDictionary: [
            "CFBundleDisplayName": "Juice Dev",
            "CFBundleName": "Ignored name",
            "CFBundleShortVersionString": "0.3.2",
            "CFBundleVersion": "27",
        ])

        #expect(info.name == "Juice Dev")
        #expect(info.versionText == "Version 0.3.2 (27)")
        #expect(info.accessibilityVersionText == "Version 0.3.2, build 27")
    }

    @Test("Bundle name is used when display name is absent")
    func bundleNameFallback() {
        let info = JuiceApplicationInfo(infoDictionary: [
            "CFBundleName": "Juice",
            "CFBundleShortVersionString": "0.3.2",
        ])

        #expect(info.name == "Juice")
        #expect(info.versionText == "Version 0.3.2")
        #expect(info.accessibilityVersionText == "Version 0.3.2")
    }

    @Test("Missing or blank bundle metadata has honest fallbacks")
    func missingBundleInformation() {
        let info = JuiceApplicationInfo(infoDictionary: [
            "CFBundleDisplayName": "  ",
            "CFBundleShortVersionString": "\n",
            "CFBundleVersion": "27",
        ])

        #expect(info.name == "Juice")
        #expect(info.versionText == "Build 27")
        #expect(JuiceApplicationInfo(infoDictionary: [:]).versionText == "Version unavailable")
    }
}
