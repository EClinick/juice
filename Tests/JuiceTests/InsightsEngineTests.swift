import Foundation
import Testing
@testable import JuiceCore

/// Fixed clock: 2023-11-14 22:13:20 UTC.
private let now = Date(timeIntervalSince1970: 1_700_000_000)

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// Day strings relative to the fixed clock (UTC).
private let today = "2023-11-14"
private let dayMinus1 = "2023-11-13"
private let dayMinus2 = "2023-11-12"
private let dayMinus3 = "2023-11-11"

private func run(samples: [InsightSample] = [], appDays: [InsightAppDay] = []) -> [Insight] {
    InsightsEngine.insights(samples: samples, appDays: appDays, now: now, calendar: utcCalendar)
}

private func batterySample(secondsAgo: TimeInterval, watts: Double, percent: Int = 50) -> InsightSample {
    InsightSample(
        date: now.addingTimeInterval(-secondsAgo),
        percent: percent,
        onAC: false,
        isCharging: false,
        watts: watts
    )
}

private func acSample(secondsAgo: TimeInterval, percent: Int) -> InsightSample {
    InsightSample(
        date: now.addingTimeInterval(-secondsAgo),
        percent: percent,
        onAC: true,
        isCharging: percent < 100,
        watts: 0
    )
}

/// `count` baseline discharge samples, hourly, starting 16 minutes ago
/// (just outside the 15-minute recent window, well inside 7 days).
private func baselineSamples(count: Int, watts: Double) -> [InsightSample] {
    (0..<count).map { batterySample(secondsAgo: 16 * 60 + Double($0) * 3600, watts: watts) }
}

/// `count` recent discharge samples, one per minute inside the 15-minute window.
private func recentSamples(count: Int, watts: Double) -> [InsightSample] {
    (1...count).map { batterySample(secondsAgo: Double($0) * 60, watts: watts) }
}

private func appDay(_ day: String, _ appKey: String, _ wh: Double, name: String? = nil) -> InsightAppDay {
    InsightAppDay(day: day, appKey: appKey, displayName: name ?? appKey, wh: wh)
}

@Suite("InsightsEngine")
struct InsightsEngineTests {

    // MARK: - Empty input

    @Test func noDataYieldsNoInsights() {
        #expect(run() == [])
    }

    // MARK: - Drain anomaly

    @Test func drainAnomalyFiresAbove2x() {
        let samples = baselineSamples(count: 60, watts: 5.0) + recentSamples(count: 5, watts: 10.5)
        let insights = run(samples: samples)
        #expect(insights.count == 1)
        let insight = insights[0]
        #expect(insight.kind == .drainAnomaly)
        #expect(insight.severity == .warning)
        #expect(insight.id == "drainAnomaly:battery")
        #expect(insight.title == "Draining 2.1x faster than usual")
        #expect(insight.detail.contains("10.5"))
        #expect(insight.detail.contains("5.0"))
    }

    @Test func drainAnomalyDoesNotFireBelow2x() {
        let samples = baselineSamples(count: 60, watts: 5.0) + recentSamples(count: 5, watts: 9.5)
        #expect(run(samples: samples) == [])
    }

    @Test func drainAnomalyDoesNotFireAtExactly2x() {
        let samples = baselineSamples(count: 60, watts: 5.0) + recentSamples(count: 5, watts: 10.0)
        #expect(run(samples: samples) == [])
    }

    @Test func drainAnomalyRequires60BaselineSamples() {
        let samples = baselineSamples(count: 59, watts: 5.0) + recentSamples(count: 5, watts: 20.0)
        #expect(run(samples: samples) == [])
    }

    @Test func drainAnomalyRequires5RecentSamples() {
        let samples = baselineSamples(count: 60, watts: 5.0) + recentSamples(count: 4, watts: 20.0)
        #expect(run(samples: samples) == [])
    }

    @Test func drainAnomalyIgnoresACAndZeroWattSamples() {
        // Recent window filled with AC samples and zero-watt samples only.
        var samples = baselineSamples(count: 60, watts: 5.0)
        samples += (1...5).map { acSample(secondsAgo: Double($0) * 60, percent: 80) }
        samples += (6...10).map { batterySample(secondsAgo: Double($0) * 60, watts: 0) }
        #expect(run(samples: samples) == [])
    }

    @Test func drainAnomalyIgnoresBaselineOlderThan7Days() {
        // 60 baseline samples, all older than 7 days: gate must fail.
        let stale = (0..<60).map {
            batterySample(secondsAgo: 8 * 24 * 3600 + Double($0) * 3600, watts: 5.0)
        }
        let samples = stale + recentSamples(count: 5, watts: 20.0)
        #expect(run(samples: samples) == [])
    }

    // MARK: - App anomaly

    @Test func appAnomalyFiresWithThreePriorDaysAndHighUsage() {
        let appDays = [
            appDay(dayMinus3, "com.a", 1.0, name: "AppA"),
            appDay(dayMinus2, "com.a", 1.0, name: "AppA"),
            appDay(dayMinus1, "com.a", 1.0, name: "AppA"),
            appDay(today, "com.a", 3.5, name: "AppA"),
        ]
        let insights = run(appDays: appDays)
        #expect(insights.count == 1)
        let insight = insights[0]
        #expect(insight.kind == .appAnomaly)
        #expect(insight.severity == .notice)
        #expect(insight.id == "appAnomaly:com.a")
        #expect(insight.title == "AppA used 3.5x its typical energy today")
    }

    @Test func appAnomalyRequiresThreePriorDays() {
        let appDays = [
            appDay(dayMinus2, "com.a", 1.0),
            appDay(dayMinus1, "com.a", 1.0),
            appDay(today, "com.a", 3.5),
        ]
        #expect(run(appDays: appDays) == [])
    }

    @Test func appAnomalyDoesNotFireAtExactly3x() {
        let appDays = [
            appDay(dayMinus3, "com.a", 1.0),
            appDay(dayMinus2, "com.a", 1.0),
            appDay(dayMinus1, "com.a", 1.0),
            appDay(today, "com.a", 3.0),
        ]
        #expect(run(appDays: appDays) == [])
    }

    @Test func appAnomalyRespectsAbsoluteFloor() {
        // 5x its typical energy, but only 1.5 Wh today: below the 2.0 Wh floor.
        let appDays = [
            appDay(dayMinus3, "com.a", 0.3),
            appDay(dayMinus2, "com.a", 0.3),
            appDay(dayMinus1, "com.a", 0.3),
            appDay(today, "com.a", 1.5),
        ]
        #expect(run(appDays: appDays) == [])
    }

    // MARK: - Hog of the week

    @Test func hogOfWeekFiresAtExactly25PercentShare() {
        // Four apps at 5 Wh each: total 20 Wh, top share exactly 25%.
        let appDays = ["com.a", "com.b", "com.c", "com.d"].map {
            appDay(today, $0, 5.0, name: "App-\($0)")
        }
        let insights = run(appDays: appDays)
        #expect(insights.count == 1)
        let insight = insights[0]
        #expect(insight.kind == .hogOfWeek)
        #expect(insight.severity == .info)
        // Tie broken deterministically by appKey.
        #expect(insight.id == "hogOfWeek:com.a")
        #expect(insight.title == "App-com.a: 25% of all energy this week")
    }

    @Test func hogOfWeekDoesNotFireBelow25PercentShare() {
        // Top app 2.4 of 10.4 Wh total: about 23%.
        var appDays = [appDay(today, "com.top", 2.4)]
        appDays += ["com.b", "com.c", "com.d", "com.e"].map { appDay(today, $0, 2.0) }
        #expect(run(appDays: appDays) == [])
    }

    @Test func hogOfWeekRequiresMoreThan10WhTotal() {
        // 100% share but only 9 Wh over the week.
        let appDays = [appDay(dayMinus1, "com.a", 9.0)]
        #expect(run(appDays: appDays) == [])
    }

    @Test func hogOfWeekIgnoresDaysOutsideWindow() {
        // Huge usage 8+ days ago must not count toward the week.
        let appDays = [
            appDay("2023-11-05", "com.a", 100.0),
            appDay(today, "com.a", 9.0),
        ]
        #expect(run(appDays: appDays) == [])
    }

    // MARK: - Charging habit

    /// `fullCount` of `total` on-AC samples sit at 100%; the rest at 50%.
    private func acSamples(total: Int, fullCount: Int) -> [InsightSample] {
        (1...total).map { i in
            acSample(secondsAgo: Double(i) * 60, percent: i <= fullCount ? 100 : 50)
        }
    }

    @Test func chargingHabitFiresAtExactly40Percent() {
        let insights = run(samples: acSamples(total: 200, fullCount: 80))
        #expect(insights.count == 1)
        let insight = insights[0]
        #expect(insight.kind == .chargingHabit)
        #expect(insight.severity == .notice)
        #expect(insight.id == "chargingHabit:ac")
        #expect(insight.title == "Sitting at full charge 40% of plugged-in time")
        #expect(insight.detail.contains("charge limit"))
    }

    @Test func chargingHabitDoesNotFireBelow40Percent() {
        #expect(run(samples: acSamples(total: 200, fullCount: 79)) == [])
    }

    @Test func chargingHabitRequires200ACSamples() {
        #expect(run(samples: acSamples(total: 199, fullCount: 199)) == [])
    }

    // MARK: - medianOf

    @Test func medianOfEmptyIsNil() {
        #expect(InsightsEngine.medianOf([]) == nil)
    }

    @Test func medianOfSingleValue() {
        #expect(InsightsEngine.medianOf([7.0]) == 7.0)
    }

    @Test func medianOfOddCount() {
        #expect(InsightsEngine.medianOf([3.0, 1.0, 2.0]) == 2.0)
    }

    @Test func medianOfEvenCount() {
        #expect(InsightsEngine.medianOf([4.0, 1.0, 3.0, 2.0]) == 2.5)
    }

    // MARK: - Determinism and ordering

    @Test func sameInputTwiceYieldsIdenticalOutput() {
        // Input constructed so that all four kinds fire at once.
        let samples = baselineSamples(count: 80, watts: 5.0)
            + recentSamples(count: 6, watts: 15.0)
            + acSamples(total: 250, fullCount: 200)
        let appDays = [
            appDay(dayMinus3, "com.hog", 4.0, name: "Hog"),
            appDay(dayMinus2, "com.hog", 4.0, name: "Hog"),
            appDay(dayMinus1, "com.hog", 4.0, name: "Hog"),
            appDay(today, "com.hog", 13.0, name: "Hog"),
            appDay(today, "com.other", 1.0, name: "Other"),
        ]

        let first = run(samples: samples, appDays: appDays)
        let second = run(samples: samples, appDays: appDays)

        #expect(first == second)
        #expect(first.map(\.id) == second.map(\.id))

        // All four kinds present, sorted severity desc then kind.
        #expect(first.map(\.kind) == [.drainAnomaly, .appAnomaly, .chargingHabit, .hogOfWeek])
        #expect(first.map(\.severity) == [.warning, .notice, .notice, .info])
    }
}

@Suite("filterPartialCoverageDays")
struct FilterPartialCoverageDaysTests {

    @Test func partialDayIsExcluded() {
        let appDays = [
            appDay(dayMinus2, "com.a", 0.1),
            appDay(dayMinus2, "com.b", 0.1),
            appDay(dayMinus1, "com.a", 10.0),
        ]
        let filtered = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: today)
        #expect(filtered.map(\.day) == [dayMinus1])
    }

    @Test func todayIsNeverExcluded() {
        let appDays = [
            appDay(today, "com.a", 0.1)
        ]
        let filtered = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: today)
        #expect(filtered.count == 1)
        #expect(filtered[0].day == today)
    }

    @Test func dayAtExactlyThresholdIsKept() {
        let appDays = [
            appDay(dayMinus1, "com.a", 2.5),
            appDay(dayMinus1, "com.b", 2.5),
        ]
        let filtered = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: today)
        #expect(filtered.count == 2)
    }

    @Test func partialFirstDayPreventsFalseAppAnomaly() {
        // Scenario: powerlog data starts late on dayMinus3, so that day's
        // total is only 0.2 Wh. Without filtering, its tiny per-app value
        // poisons the "typical Wh/day" median and the app looks anomalous.
        let appDays = [
            appDay(dayMinus3, "com.vscode", 0.2, name: "VS Code"),
            appDay(dayMinus2, "com.vscode", 8.0, name: "VS Code"),
            appDay(dayMinus1, "com.vscode", 9.0, name: "VS Code"),
            appDay(today, "com.vscode", 12.0, name: "VS Code"),
        ]
        let filtered = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: today)

        // Only 2 prior days survive, so the 3-prior-day anomaly gate
        // cannot fire.
        #expect(filtered.filter { $0.day != today }.map(\.day).sorted()
            == [dayMinus2, dayMinus1].sorted())
        let insights = run(appDays: filtered)
        #expect(!insights.contains { $0.kind == .appAnomaly })
    }
}
