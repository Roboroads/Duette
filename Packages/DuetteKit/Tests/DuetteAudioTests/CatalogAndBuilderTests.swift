import CoreAudio
@testable import DuetteAudio
import XCTest

final class DriverProtocolTests: XCTestCase {
    func testCustomPropertySelectorsMatchTheirFourCharacterCodes() {
        XCTAssertEqual(DuetteDriver.selfTestToneProperty, FourCC.code("dtst"))
        XCTAssertEqual(DuetteDriver.inputClientsProperty, FourCC.code("dcli"))
        XCTAssertEqual(FourCC.string(DuetteDriver.inputClientsProperty), "dcli")
    }

    func testAggregateUIDCarriesThePID() {
        XCTAssertEqual(DuetteDriver.aggregateUID(pid: 4242), "me.roboroads.duette.agg.4242")
    }

    func testErrorCodesAreReadable() {
        XCTAssertEqual(FourCC.describe(OSStatus(bitPattern: FourCC.code("nope"))), "'nope' (1852797029)")
        XCTAssertEqual(FourCC.describe(-50), "-50")
        XCTAssertEqual(FourCC.describe(0), "no error")
    }
}

final class DeviceCatalogTests: XCTestCase {
    private let builtIn = AudioDeviceInfo(id: 10, uid: "BuiltInMic", name: "MacBook Pro Microphone", inputChannels: 1)
    private let usb = AudioDeviceInfo(id: 11, uid: "USB-Mic-1", name: "USB Mic", inputChannels: 2)
    private let speakers = AudioDeviceInfo(id: 12, uid: "BuiltInSpeakers", name: "Speakers", outputChannels: 2)
    private let duette = AudioDeviceInfo(id: 13, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
    private let ownAggregate = AudioDeviceInfo(id: 14, uid: DuetteDriver.aggregateUID(pid: 99), name: "Duette Engine",
                                               inputChannels: 4, outputChannels: 2, isPrivateAggregate: true)
    private let otherPrivateAggregate = AudioDeviceInfo(id: 15, uid: "com.example.agg", name: "Their Aggregate",
                                                        inputChannels: 2, isPrivateAggregate: true)
    private let userAggregate = AudioDeviceInfo(id: 16, uid: "user.agg", name: "My Aggregate", inputChannels: 2)

    private var all: [AudioDeviceInfo] {
        [builtIn, usb, speakers, duette, ownAggregate, otherPrivateAggregate, userAggregate]
    }

    func testDuetteAndPrivateAggregatesAreNotMics() {
        let choices = DeviceCatalog.micChoices(from: all)
        XCTAssertEqual(choices.map(\.selection), [
            .systemDefault,
            .device(uid: "BuiltInMic"),
            .device(uid: "USB-Mic-1"),
            .device(uid: "user.agg"),
        ])
        XCTAssertEqual(choices.first?.name, "System default")
    }

    func testSystemDefaultFollowsTheDefaultInput() {
        XCTAssertEqual(DeviceCatalog.resolveMic(.systemDefault, devices: all, defaultInputUID: "USB-Mic-1"), usb)
        XCTAssertEqual(DeviceCatalog.resolveMic(.systemDefault, devices: all, defaultInputUID: "BuiltInMic"), builtIn)
        XCTAssertNil(DeviceCatalog.resolveMic(.systemDefault, devices: all, defaultInputUID: nil))
    }

    func testDuetteAsTheDefaultInputGivesNoMic() {
        XCTAssertNil(DeviceCatalog.resolveMic(.systemDefault, devices: all, defaultInputUID: DuetteDriver.deviceUID))
    }

    func testAChosenMicIsFoundByUIDAndIsGoneWhenUnplugged() {
        XCTAssertEqual(DeviceCatalog.resolveMic(.device(uid: "USB-Mic-1"), devices: all, defaultInputUID: nil), usb)
        let unplugged = all.filter { $0.uid != "USB-Mic-1" }
        XCTAssertNil(DeviceCatalog.resolveMic(.device(uid: "USB-Mic-1"), devices: unplugged, defaultInputUID: "BuiltInMic"))
        XCTAssertNil(DeviceCatalog.resolveMic(.device(uid: DuetteDriver.deviceUID), devices: all, defaultInputUID: nil))
    }

    func testMicSelectionSurvivesEncoding() throws {
        for selection in [MicSelection.systemDefault, .device(uid: "USB-Mic-1")] {
            let data = try JSONEncoder().encode(selection)
            XCTAssertEqual(try JSONDecoder().decode(MicSelection.self, from: data), selection)
        }
    }
}

final class AggregateBuilderTests: XCTestCase {
    func testMicOnlyAggregate() throws {
        let spec = AggregateSpec(ownerPID: 321, micUID: "USB-Mic-1")
        let description = AggregateBuilder.description(for: spec)

        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, "me.roboroads.duette.agg.321")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Int, 1)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Int, 0)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, DuetteDriver.sinkUID)
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, DuetteDriver.sinkUID)
        XCTAssertNotNil(description[kAudioAggregateDeviceNameKey] as? String)

        let subdevices = try XCTUnwrap(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        XCTAssertEqual(subdevices.count, 2)
        XCTAssertEqual(subdevices[0][kAudioSubDeviceUIDKey] as? String, DuetteDriver.sinkUID)
        XCTAssertNil(subdevices[0][kAudioSubDeviceDriftCompensationKey], "the sink is the clock")
        XCTAssertEqual(subdevices[1][kAudioSubDeviceUIDKey] as? String, "USB-Mic-1")
        XCTAssertEqual(subdevices[1][kAudioSubDeviceDriftCompensationKey] as? Int, 1)
    }

    func testWithoutAMicTheSinkIsTheOnlySubdevice() throws {
        let description = AggregateBuilder.description(for: AggregateSpec(ownerPID: 1))
        let subdevices = try XCTUnwrap(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        XCTAssertEqual(subdevices.count, 1)
        XCTAssertEqual(subdevices[0][kAudioSubDeviceUIDKey] as? String, DuetteDriver.sinkUID)
    }

    func testDescriptionIsAValidCFDictionary() {
        let description = AggregateBuilder.description(for: AggregateSpec(ownerPID: 7, micUID: "m"))
        let cf = description as CFDictionary
        XCTAssertEqual(CFDictionaryGetCount(cf), description.count)
    }
}
