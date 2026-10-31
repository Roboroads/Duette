import CoreAudio
@testable import DuetteAudio
import XCTest

final class ProcessCatalogTests: XCTestCase {
    private let discord = "com.hnc.Discord"
    // Discord's main process (pid 100) is not a Core Audio client; its helpers are.
    private let renderer = AudioProcessInfo(objectID: 201, pid: 101, bundleID: "com.hnc.Discord.helper.Renderer",
                                            isRunningOutput: true)
    private let gpuHelper = AudioProcessInfo(objectID: 202, pid: 102, bundleID: "com.hnc.Discord.helper")
    private let lookalike = AudioProcessInfo(objectID: 203, pid: 103, bundleID: "com.hnc.DiscordX", isRunningOutput: true)
    private let unbundledChild = AudioProcessInfo(objectID: 204, pid: 104, bundleID: "")
    private let grandchild = AudioProcessInfo(objectID: 205, pid: 105, bundleID: "org.example.codec")
    private let music = AudioProcessInfo(objectID: 206, pid: 200, bundleID: "com.apple.Music", isRunningOutput: true)

    private let parents: [pid_t: pid_t] = [101: 100, 102: 100, 103: 1, 104: 100, 105: 104, 100: 1, 200: 1]
    private func parent(_ pid: pid_t) -> pid_t? { parents[pid] }

    private var all: [AudioProcessInfo] { [renderer, gpuHelper, lookalike, unbundledChild, grandchild, music] }

    func testBundleIDRules() {
        XCTAssertTrue(ProcessCatalog.bundleID("com.hnc.Discord", belongsTo: discord))
        XCTAssertTrue(ProcessCatalog.bundleID("com.hnc.Discord.helper.Renderer", belongsTo: discord))
        XCTAssertFalse(ProcessCatalog.bundleID("com.hnc.DiscordX", belongsTo: discord))
        XCTAssertFalse(ProcessCatalog.bundleID("com.hnc", belongsTo: discord))
        XCTAssertFalse(ProcessCatalog.bundleID("", belongsTo: discord))
        XCTAssertFalse(ProcessCatalog.bundleID("com.hnc.Discord", belongsTo: ""))
    }

    func testDiscordHelpersAreGroupedUnderDiscord() {
        let group = ProcessCatalog.processes(of: discord, in: all, appPIDs: [100], parentPID: parent)
        XCTAssertEqual(Set(group.map(\.objectID)), [201, 202, 204, 205])
    }

    func testParentChainAloneFindsHelpersWithForeignBundleIDs() {
        // Only the parent chain links pid 105 (via 104) to Discord's main process.
        XCTAssertTrue(ProcessCatalog.descends(105, from: [100], parentPID: parent))
        XCTAssertFalse(ProcessCatalog.descends(103, from: [100], parentPID: parent))
        XCTAssertFalse(ProcessCatalog.descends(100, from: [100], parentPID: parent), "a process is not its own descendant")
    }

    func testParentChainSurvivesLoopsAndGaps() {
        let loop: [pid_t: pid_t] = [10: 11, 11: 10]
        XCTAssertFalse(ProcessCatalog.descends(10, from: [99], parentPID: { loop[$0] }))
        XCTAssertFalse(ProcessCatalog.descends(10, from: [99], parentPID: { _ in nil }))
    }

    func testWithoutTheMainPIDOnlyBundleIDsMatch() {
        let group = ProcessCatalog.processes(of: discord, in: all, appPIDs: [], parentPID: parent)
        XCTAssertEqual(Set(group.map(\.objectID)), [201, 202])
    }

    func testAnAppWhoseMainProcessPlaysIsItsOwnGroup() {
        let group = ProcessCatalog.processes(of: "com.apple.Music", in: all, appPIDs: [], parentPID: parent)
        XCTAssertEqual(group, [music])
    }

    func testAppPickerListsPlayingAppsFirst() {
        let apps = [RunningApp(bundleID: "com.apple.Safari", name: "Safari", pid: 300),
                    RunningApp(bundleID: discord, name: "Discord", pid: 100),
                    RunningApp(bundleID: "com.apple.Music", name: "Music", pid: 200),
                    RunningApp(bundleID: "", name: "No bundle", pid: 400)]
        let entries = ProcessCatalog.appEntries(runningApps: apps, processes: all, parentPID: parent)
        XCTAssertEqual(entries.map(\.name), ["Discord", "Music", "Safari"])
        XCTAssertEqual(entries.map(\.isPlayingAudio), [true, true, false])
    }

    func testSystemParentOfThisProcessIsKnown() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(ProcessCatalog.systemParentPID(of: me), getppid())
    }
}

final class TapControllerTests: XCTestCase {
    func testTapDescriptionIsAnUnmutedPrivateStereoMixdown() {
        let uuid = UUID()
        let description = TapController.makeDescription(TapSpec(processObjectIDs: [201, 202], name: "t", uuid: uuid))
        XCTAssertEqual(description.uuid, uuid)
        XCTAssertEqual(description.name, "t")
        XCTAssertEqual(description.muteBehavior, .unmuted)
        XCTAssertTrue(description.isPrivate)
        let processes = (description.processes as NSArray).compactMap { ($0 as? NSNumber)?.uint32Value }
        XCTAssertEqual(processes, [201, 202])
    }

    func testAggregateWithATapListsItWithDriftCompensation() throws {
        let description = AggregateBuilder.description(for: AggregateSpec(ownerPID: 5, micUID: "mic", tapUID: "TAP-UUID"))
        let taps = try XCTUnwrap(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, "TAP-UUID")
        XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        // The tap does not change the clock: the sink stays main and clock device.
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, DuetteDriver.sinkUID)
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, DuetteDriver.sinkUID)
    }

    func testAggregateWithoutATapHasNoTapList() {
        let description = AggregateBuilder.description(for: AggregateSpec(ownerPID: 5, micUID: "mic"))
        XCTAssertNil(description[kAudioAggregateDeviceTapListKey])
        XCTAssertNil(description[kAudioAggregateDeviceTapAutoStartKey])
    }
}

final class StreamLayoutTapTests: XCTestCase {
    private func tap(channels: Int = 2) -> LayoutMember {
        LayoutMember(role: .tap, objectID: 70, streams: [StreamInfo(id: 0, channels: channels)])
    }

    func testTapTakesTheStreamNobodyElseOwns() throws {
        // The mic's stream is listed under its own ID; the tap's stream has no known object.
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2), StreamInfo(id: 61, channels: 2)],
            members: [LayoutMember(role: .mic, objectID: 60, streams: [StreamInfo(id: 61, channels: 2)]), tap()])
        XCTAssertEqual(layout.method, .streamIDs)
        XCTAssertEqual(layout.range(.tap), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 1, count: 1))
    }

    func testTapOwnerIdentifiesItsStream() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2, owner: 70), StreamInfo(id: 901, channels: 2, owner: 60)],
            members: [LayoutMember(role: .mic, objectID: 60, streams: [StreamInfo(id: 61, channels: 2)]), tap()])
        XCTAssertEqual(layout.method, .owners)
        XCTAssertEqual(layout.range(.tap), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 1, count: 1))
    }

    func testMonoMicAndStereoTapAreToldApartByChannels() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2), StreamInfo(id: 901, channels: 1)],
            members: [LayoutMember(role: .mic, objectID: 60, streams: [StreamInfo(id: 61, channels: 1)]), tap()])
        XCTAssertEqual(layout.method, .channelCounts)
        XCTAssertEqual(layout.range(.tap), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 1, count: 1))
    }

    func testStereoMicAndStereoTapWithNoEvidenceUseCompositionOrder() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2), StreamInfo(id: 901, channels: 2)],
            members: [LayoutMember(role: .mic, objectID: 60, streams: [StreamInfo(id: 61, channels: 2)]), tap()])
        XCTAssertEqual(layout.method, .memberOrder)
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.tap), BufferRange(first: 1, count: 1))
    }

    func testTapOnlyAggregate() throws {
        let layout = try StreamLayoutResolver.resolve(streams: [StreamInfo(id: 900, channels: 2)], members: [tap()])
        XCTAssertEqual(layout.range(.tap), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), .none)
    }
}
