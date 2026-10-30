// Throwaway spike: process tap on a PID (or a global tap), read through a private aggregate.
import CoreAudio
import Foundation

// CATapDescription takes NSArray<NSNumber *>; these overloads let the compiler pick
// whichever element type the SDK imports it as.
func procList(_ ids: [AudioObjectID]) -> [NSNumber] { ids.map { NSNumber(value: $0) } }
func procList(_ ids: [AudioObjectID]) -> [AudioObjectID] { ids }

func pidToProcessObject(_ pid: pid_t) -> (OSStatus, AudioObjectID) {
    var address = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid
    var obj = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
    return (err, obj)
}

/// target: a PID, or "global" for a stereo global tap excluding nothing.
/// withSubdevice: add the default output device as main subdevice (as Duette will
/// with its own device); otherwise the aggregate holds only the tap.
func runTap(target: String, seconds: Double, muted: Bool, withSubdevice: Bool) -> Int32 {
    var fields = ["cmd=tap", "target=\(target)", "muted=\(muted ? 1 : 0)", "sub=\(withSubdevice ? 1 : 0)"]
    func fail(_ status: String) -> Int32 {
        print("RESULT " + (fields + ["status=\(status)"]).joined(separator: " "))
        return 1
    }

    for p in halProcesses() {
        print("  halProcess obj=\(p.obj) pid=\(p.pid) runningIn=\(p.input) runningOut=\(p.output)")
    }

    let desc: CATapDescription
    if target == "global" {
        desc = CATapDescription(stereoGlobalTapButExcludeProcesses: procList([]))
    } else {
        guard let pid = Int32(target) else { return fail("bad-target") }
        var procObj = AudioObjectID(0)
        var lastErr: OSStatus = 0
        for _ in 0..<30 {
            let (e, o) = pidToProcessObject(pid)
            lastErr = e
            if e == 0 && o != 0 { procObj = o; break }
            usleep(100_000)
        }
        fields.append("translate=\(errStr(lastErr))")
        fields.append("procobj=\(procObj)")
        if procObj == 0 { return fail("no-process-object") }
        desc = CATapDescription(stereoMixdownOfProcesses: procList([procObj]))
    }
    desc.uuid = UUID()
    desc.name = "duette-spike-tap"
    desc.muteBehavior = muted ? .muted : .unmuted

    var tapID = AudioObjectID(0)
    let eTap = AudioHardwareCreateProcessTap(desc, &tapID)
    fields.append("tap=\(errStr(eTap))")
    if eTap != 0 || tapID == 0 { return fail("tap-create-failed") }
    defer { _ = AudioHardwareDestroyProcessTap(tapID) }
    let (eFmt, tapFmt) = getValue(tapID, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription())
    fields.append("tapfmt=\(eFmt == 0 ? formatString(tapFmt) : errStr(eFmt))")
    print("  tap id=\(tapID) uid=\(getString(tapID, kAudioTapPropertyUID) ?? "?") uuid=\(desc.uuid.uuidString)")

    var dict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "duette-spike-agg",
        kAudioAggregateDeviceUIDKey: "duette-spike-agg-" + UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
            [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any],
        ],
    ]
    if withSubdevice {
        let out = getDefault(kAudioHardwarePropertyDefaultOutputDevice)
        if out == 0 { return fail("no-default-output") }
        let outUID = deviceUID(out)
        fields.append("main=\(deviceName(out).replacingOccurrences(of: " ", with: "_"))")
        dict[kAudioAggregateDeviceMainSubDeviceKey] = outUID
        dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID] as [String: Any]]
    }
    var agg = AudioObjectID(0)
    let eAgg = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
    fields.append("agg=\(errStr(eAgg))")
    if eAgg != 0 || agg == 0 { return fail("aggregate-create-failed") }
    defer { _ = AudioHardwareDestroyAggregateDevice(agg) }
    pump(0.3)
    fields.append("aggIn=\(fmtList(bufferChannels(agg, kAudioObjectPropertyScopeInput)))")
    fields.append("aggRate=\(Int(getValue(agg, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)).1))")
    print("  aggregate id=\(agg) inFormats=\(streamFormats(agg, kAudioObjectPropertyScopeInput))")

    let meter = LevelMeter()
    var procID: AudioDeviceIOProcID? = nil
    let eCreate = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inInput, _, _, _ in
        meter.process(inInput)
    }
    guard eCreate == 0, let proc = procID else { return fail("ioproc-failed-\(errStr(eCreate))") }
    let eStart = AudioDeviceStart(agg, proc)
    fields.append("start=\(errStr(eStart))")
    pump(seconds)
    _ = AudioDeviceStop(agg, proc)
    _ = AudioDeviceDestroyIOProcID(agg, proc)
    print("RESULT " + fields.joined(separator: " ") + " status=ran " + meter.summary())
    return eStart == 0 ? 0 : 1
}
