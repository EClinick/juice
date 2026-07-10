import Testing
@testable import JuiceCore

@Suite struct ProcessTreeTests {
    private let processes = [
        ProcessSnapshot(pid: 100, parentPID: 1, cpuPercent: 1.2, executablePath: "/Applications/App.app/Contents/MacOS/App"),
        ProcessSnapshot(pid: 101, parentPID: 100, cpuPercent: 4.0, executablePath: "/Applications/App.app/Contents/Helpers/Renderer"),
        ProcessSnapshot(pid: 102, parentPID: 101, cpuPercent: 0.5, executablePath: "/Applications/App.app/Contents/Helpers/Worker"),
        ProcessSnapshot(pid: 200, parentPID: 1, cpuPercent: 9.0, executablePath: "/usr/bin/unrelated")
    ]

    @Test func selectsRootAndEveryDescendant() {
        let selected = ProcessTree.descendants(of: [100], in: processes)
        #expect(selected.map(\.pid) == [101, 100, 102])
    }

    @Test func emptyRootsNeverSelectUnrelatedProcesses() {
        #expect(ProcessTree.descendants(of: [], in: processes).isEmpty)
    }

    @Test func ordersEqualCPUProcessesByPID() {
        let equalCPU = [
            ProcessSnapshot(pid: 12, parentPID: 10, cpuPercent: 1, executablePath: "/tmp/one"),
            ProcessSnapshot(pid: 10, parentPID: 1, cpuPercent: 1, executablePath: "/tmp/root"),
            ProcessSnapshot(pid: 11, parentPID: 10, cpuPercent: 1, executablePath: "/tmp/two")
        ]
        #expect(ProcessTree.descendants(of: [10], in: equalCPU).map(\.pid) == [10, 11, 12])
    }
}
