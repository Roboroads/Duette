import CoreAudio
@testable import DuetteAudio
import XCTest

/// Checks against the machine's real HAL. Nothing here starts IO or needs a permission, so it is
/// safe on a CI runner; what the runner lacks (no audio devices at all) is skipped. The printed
/// lines are the evidence for how the HAL lays out an aggregate's streams.
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

    func testBuilderAggregateIsAcceptedAndItsStreamsResolve() throws {
        let devices = try HAL.deviceIDs().compactMap { try? HAL.deviceInfo($0) }
        guard let output = devices.first(where: { $0.outputChannels > 0 && $0.transportType != UInt32(kAudioDeviceTransportTypeAggregate) }) else {
            throw XCTSkip("no output device on this machine")
        }
        let mic = devices.first { $0.inputChannels > 0 && $0.uid != output.uid && DeviceCatalog.isSelectableMic($0) }
        let spec = AggregateSpec(sinkUID: output.uid, micUID: mic?.uid, name: "DuetteKit smoke test")
        print("HAL aggregate: stand-in sink \(output.name), mic \(mic?.name ?? "none")")

        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(AggregateBuilder.description(for: spec) as CFDictionary, &aggregate)
        XCTAssertEqual(status, 0, "AudioHardwareCreateAggregateDevice: \(FourCC.describe(status))")
        guard status == 0, aggregate != 0 else { return }
        defer { _ = AudioHardwareDestroyAggregateDevice(aggregate) }

        let members: (AudioObjectPropertyScope) throws -> [LayoutMember] = { scope in
            var result = [LayoutMember(role: .sink, objectID: output.id, streams: try HAL.streams(of: output.id, scope: scope))]
            if let mic {
                result.append(LayoutMember(role: .mic, objectID: mic.id, streams: try HAL.streams(of: mic.id, scope: scope)))
            }
            return result
        }
        let inputMembers = try members(kAudioObjectPropertyScopeInput)
        let outputMembers = try members(kAudioObjectPropertyScopeOutput)
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
        print("HAL aggregate \(aggregate) input streams: \(inputStreams); members: \(inputMembers)")
        print("HAL aggregate \(aggregate) output streams: \(outputStreams); members: \(outputMembers)")

        let inputLayout = try StreamLayoutResolver.resolve(streams: inputStreams, members: inputMembers)
        let outputLayout = try StreamLayoutResolver.resolve(streams: outputStreams, members: outputMembers)
        print("HAL aggregate layout: input \(inputLayout), output \(outputLayout)")
        XCTAssertEqual(outputLayout.range(.sink).first, 0, "the main subdevice comes first")
        XCTAssertGreaterThan(outputLayout.range(.sink).count, 0)
        if let mic, mic.inputChannels > 0 {
            XCTAssertGreaterThan(inputLayout.range(.mic).count, 0)
        }

        let uid = try AudioObject(aggregate).getString(kAudioDevicePropertyDeviceUID)
        XCTAssertEqual(uid, spec.uid)
    }
}
