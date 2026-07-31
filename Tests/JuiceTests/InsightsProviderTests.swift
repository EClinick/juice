import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("Insights provider lifecycle")
struct InsightsProviderTests {
    @Test("A canceled hidden load skips insight work")
    func canceledLoadReturnsImmediately() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-insights-\(UUID().uuidString).sqlite")
            .path
        let provider = InsightsProvider(store: try JuiceStore(path: path))

        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.currentInsights()
        }

        #expect(await load.value.isEmpty)
    }
}
