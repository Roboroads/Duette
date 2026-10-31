import CoreAudio
@testable import DuetteAudio
import XCTest

/// Checks against the machine's real HAL. Nothing here starts IO, so no permission prompt can
/// block it on a CI runner; what the runner lacks (audio devices) is skipped. The printed
/// "HAL ..." lines are the evidence for how the HAL lays out an aggregate's streams.
///
/// Set DUETTE_SKIP_HAL_TESTS=1 to skip them.
final class HALSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["DUETTE_SKIP_HAL_TESTS"] != nil {
            throw XCTSkip("DUETTE_SKIP_HAL_TESTS is set")
        }
        HAL.deliverNotificationsOnHALThread()
    }

    func testDeviceListAndUIDLookups() throws {
        let ids = try HAL.deviceIDs()
        for id in ids {
            // An aggregate another test just destroyed can still be listed for a moment.
            guard let info = try? HAL.deviceInfo(id), !info.uid.hasPrefix(DuetteDriver.aggregateUIDPrefix) else { continue }
            print("HAL device: \(info)")
            XCTAssertEqual(HAL.deviceID(forUID: info.uid), id)
        }
        XCTAssertNil(HAL.deviceID(forUID: "me.roboroads.duette.no-such-device"))
        print("HAL sink lookup: \(String(describing: HAL.deviceID(forUID: DuetteDriver.sinkUID)))")
        print("HAL default input: \(String(describing: HAL.defaultInputDeviceID()))")
    }

    func testProcessObjectsDescribeThemselves() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = try HAL.processObjectIDs().compactMap(HAL.processInfo)
        print("HAL processes: \(processes.count), this process: \(String(describing: HAL.processObjectID(forPID: me)))")
        if let mine = HAL.processObjectID(forPID: me) {
            XCTAssertEqual(HAL.processInfo(mine)?.pid, me)
        }
    }

    func testBuilderAggregateIsAcceptedAndItsStreamsResolve() throws {
        let (output, mic) = try standIns()
        let spec = AggregateSpec(sinkUID: output.uid, micUID: mic?.uid, name: "DuetteKit smoke test")
        let (inputLayout, outputLayout) = try buildAndResolve(spec, sink: output, mic: mic, tap: nil)
        XCTAssertEqual(outputLayout.range(.sink).first, 0, "the main subdevice comes first")
        XCTAssertGreaterThan(outputLayout.range(.sink).count, 0)
        if mic != nil { XCTAssertGreaterThan(inputLayout.range(.mic).count, 0) }
    }

    func testTapOnThisProcessAndItsPlaceInTheAggregate() throws {
        let (output, mic) = try standIns()
        let me = ProcessInfo.processInfo.processIdentifier
        guard let processObject = HAL.processObjectID(forPID: me) else {
            throw XCTSkip("this process has no process object")
        }
        let tap: ProcessTap
        do {
            tap = try TapController.create(TapSpec(processObjectIDs: [processObject], name: "DuetteKit smoke tap"))
        } catch {
            print("HAL tap refused: \(error)")
            throw XCTSkip("the HAL refused the tap here: \(error)")
        }
        defer { TapController.destroy(tap.id) }
        print("HAL tap: \(tap)")
        XCTAssertEqual(tap.channels, 2, "a stereo mixdown")

        let spec = AggregateSpec(sinkUID: output.uid, micUID: mic?.uid, tapUID: tap.uid, name: "DuetteKit smoke tap test")
        let (inputLayout, _) = try buildAndResolve(spec, sink: output, mic: mic, tap: tap)
        XCTAssertGreaterThan(inputLayout.range(.tap).count, 0)
    }

    /// A mono tap next to a stereo mic: the channel counts differ, so the resolver can tell from
    /// the aggregate itself whether tap streams come before or after subdevice streams.
    func testMonoTapRevealsWhereTapStreamsGo() throws {
        let (output, found) = try standIns()
        guard let mic = found, mic.inputChannels >= 2 else { throw XCTSkip("needs a stereo input device") }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let processObject = HAL.processObjectID(forPID: me) else {
            throw XCTSkip("this process has no process object")
        }
        let description = CATapDescription(monoMixdownOfProcesses: tapProcessList([processObject]))
        description.uuid = UUID()
        description.name = "DuetteKit smoke mono tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        let tap: ProcessTap
        do {
            tap = try TapController.create(description)
        } catch {
            throw XCTSkip("the HAL refused the tap here: \(error)")
        }
        defer { TapController.destroy(tap.id) }
        XCTAssertEqual(tap.channels, 1)

        let spec = AggregateSpec(sinkUID: output.uid, micUID: mic.uid, tapUID: tap.uid, name: "DuetteKit smoke mono tap")
        let (inputLayout, _) = try buildAndResolve(spec, sink: output, mic: mic, tap: tap)
        print("HAL tap order: tap at \(inputLayout.range(.tap)), mic at \(inputLayout.range(.mic)), by \(inputLayout.method)")
        XCTAssertEqual(inputLayout.method, .channelCounts)
        XCTAssertEqual(inputLayout.range(.tap).count, 1)
    }

    func testControllerOnTheRealSystemWaitsForTheDriver() throws {
        guard HAL.deviceID(forUID: DuetteDriver.sinkUID) == nil else {
            throw XCTSkip("the Duette driver is installed here")
        }
        let system = CoreAudioSystem()
        XCTAssertNil(system.inputClientPIDs(), "no driver, no 'dcli'")
        let controller = EngineController(audioSystem: system)
        let reached = expectation(description: "waiting for the driver")
        reached.assertForOverFulfill = false
        controller.onStatusChange = { status in
            if status.state == .waitingForDriver { reached.fulfill() }
        }
        controller.start(EngineConfiguration(appBundleID: "com.apple.Music"))
        wait(for: [reached], timeout: 10)
        print("HAL controller choices: mics \(controller.micChoices().map(\.name)), apps \(controller.appChoices().map(\.bundleID))")
        controller.stop()
    }

    /// Runs only where the driver is installed (a dev Mac, or a CI job that installs it): the
    /// hidden "Duette Sink" as the aggregate's main subdevice, with the IOProc running on it.
    func testHiddenSinkAsMainSubdeviceRunsTheEngine() throws {
        guard HAL.deviceID(forUID: DuetteDriver.sinkUID) != nil else {
            throw XCTSkip("the Duette driver is not installed here")
        }
        let controller = EngineController(audioSystem: CoreAudioSystem())
        let running = expectation(description: "running")
        running.assertForOverFulfill = false
        controller.onStatusChange = { status in
            if case .running = status.state { running.fulfill() }
        }
        // No mic and no app: the aggregate holds only the sink, so no permission prompt can block.
        controller.start(EngineConfiguration(mic: .device(uid: "me.roboroads.duette.no-such-mic")))
        wait(for: [running], timeout: 10)
        let before = controller.engine.stats().cycles
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(controller.engine.stats().cycles, before, "the IOProc runs on the aggregate")
        print("HAL hidden sink as main subdevice: \(controller.status)")
        controller.stop()
    }

    // MARK: - Helpers

    /// A real output device to stand in for the sink, and an input device for the mic if any.
    private func standIns() throws -> (AudioDeviceInfo, AudioDeviceInfo?) {
        let devices = try HAL.deviceIDs().compactMap { try? HAL.deviceInfo($0) }
        let aggregate = UInt32(kAudioDeviceTransportTypeAggregate)
        guard let output = devices.first(where: { $0.outputChannels > 0 && $0.transportType != aggregate }) else {
            throw XCTSkip("no output device on this machine")
        }
        let mic = devices.first { $0.inputChannels > 0 && $0.uid != output.uid && DeviceCatalog.isSelectableMic($0) }
        print("HAL stand-ins: sink \(output.name) (\(output.uid)), mic \(mic.map { "\($0.name) (\($0.uid))" } ?? "none")")
        return (output, mic)
    }

    private func members(scope: AudioObjectPropertyScope, sink: AudioDeviceInfo, mic: AudioDeviceInfo?,
                         tap: ProcessTap?) throws -> [LayoutMember] {
        var result = [LayoutMember(role: .sink, objectID: sink.id, streams: try HAL.streams(of: sink.id, scope: scope))]
        if let mic {
            result.append(LayoutMember(role: .mic, objectID: mic.id, streams: try HAL.streams(of: mic.id, scope: scope)))
        }
        if let tap, scope == kAudioObjectPropertyScopeInput {
            result.append(LayoutMember(role: .tap, objectID: tap.id, streams: [StreamInfo(id: 0, channels: tap.channels)]))
        }
        return result
    }

    private func describeStreams(_ streams: [StreamInfo]) -> String {
        streams.map { stream in
            let object = AudioObject(stream.id)
            let terminal = (try? object.get(kAudioStreamPropertyTerminalType, as: UInt32.self)).map { FourCC.string($0) ?? String($0) } ?? "?"
            let start = (try? object.get(kAudioStreamPropertyStartingChannel, as: UInt32.self)).map { String($0) } ?? "?"
            return "{id \(stream.id) ch \(stream.channels) buf \(stream.buffers) owner \(stream.owner) terminal \(terminal) start \(start)}"
        }.joined(separator: " ")
    }

    private func describeMembers(_ members: [LayoutMember]) -> String {
        members.map { member in
            let streams = member.streams.map { stream in "\(stream.id)/\(stream.channels)ch" }
            return "\(member.role.rawValue)#\(member.objectID) \(streams)"
        }.joined(separator: " ")
    }

    private func buildAndResolve(_ spec: AggregateSpec, sink: AudioDeviceInfo, mic: AudioDeviceInfo?,
                                 tap: ProcessTap?) throws -> (StreamLayout, StreamLayout) {
        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(AggregateBuilder.description(for: spec) as CFDictionary, &aggregate)
        guard status == kNoError, aggregate != 0 else {
            XCTFail("AudioHardwareCreateAggregateDevice: \(FourCC.describe(status))")
            throw CoreAudioError(status, "create the aggregate")
        }
        defer { _ = AudioHardwareDestroyAggregateDevice(aggregate) }
        XCTAssertEqual(try AudioObject(aggregate).getString(kAudioDevicePropertyDeviceUID), spec.uid)

        let inputMembers = try members(scope: kAudioObjectPropertyScopeInput, sink: sink, mic: mic, tap: tap)
        let outputMembers = try members(scope: kAudioObjectPropertyScopeOutput, sink: sink, mic: mic, tap: tap)
        let expectedInputs = inputMembers.reduce(0) { $0 + $1.streams.count }
        let expectedOutputs = outputMembers.reduce(0) { $0 + $1.streams.count }

        // The aggregate fills in its streams shortly after it is created.
        var inputStreams: [StreamInfo] = []
        var outputStreams: [StreamInfo] = []
        for _ in 0..<30 {
            inputStreams = try HAL.streams(of: aggregate, scope: kAudioObjectPropertyScopeInput)
            outputStreams = try HAL.streams(of: aggregate, scope: kAudioObjectPropertyScopeOutput)
            if inputStreams.count == expectedInputs && outputStreams.count == expectedOutputs { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let label = spec.tapUID == nil ? "aggregate" : "aggregate+tap"
        print("HAL \(label) \(aggregate) input: \(describeStreams(inputStreams))")
        print("HAL \(label) members input: \(describeMembers(inputMembers))")
        print("HAL \(label) \(aggregate) output: \(describeStreams(outputStreams))")
        print("HAL \(label) members output: \(describeMembers(outputMembers))")
        let inputBuffers = (try? AudioObject(aggregate).bufferChannels(scope: kAudioObjectPropertyScopeInput)) ?? []
        let outputBuffers = (try? AudioObject(aggregate).bufferChannels(scope: kAudioObjectPropertyScopeOutput)) ?? []
        print("HAL \(label) buffer channels: input \(inputBuffers) output \(outputBuffers)")

        let inputLayout = try StreamLayoutResolver.resolve(streams: inputStreams, members: inputMembers)
        let outputLayout = try StreamLayoutResolver.resolve(streams: outputStreams, members: outputMembers)
        print("HAL \(label) layout: input \(inputLayout.ranges) by \(inputLayout.method), output \(outputLayout.ranges) by \(outputLayout.method)")
        return (inputLayout, outputLayout)
    }
}
