// Throwaway spike: list devices, plug-ins and defaults; set the default devices.
import CoreAudio
import Foundation

func allDevices() -> [AudioObjectID] {
    getArray(systemObject, addr(kAudioHardwarePropertyDevices), AudioObjectID(0))
}

func deviceName(_ id: AudioObjectID) -> String { getString(id, kAudioObjectPropertyName) ?? "?" }
func deviceUID(_ id: AudioObjectID) -> String { getString(id, kAudioDevicePropertyDeviceUID) ?? "?" }

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioObjectID {
    getValue(systemObject, addr(sel), AudioObjectID(0)).1
}

func setDefault(_ sel: AudioObjectPropertySelector, _ dev: AudioObjectID) -> OSStatus {
    var address = addr(sel)
    var d = dev
    return AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
}

/// First device whose name or UID contains `query` (case-insensitive) and that has
/// channels in `scope`, when given.
func findDevice(_ query: String, scope: AudioObjectPropertyScope?) -> AudioObjectID? {
    let q = query.lowercased()
    for d in allDevices() {
        guard deviceName(d).lowercased().contains(q) || deviceUID(d).lowercased().contains(q) else { continue }
        if let s = scope, bufferChannels(d, s).reduce(0, +) == 0 { continue }
        return d
    }
    return nil
}

func runList() -> Int32 {
    let devs = allDevices()
    print("devices: \(devs.count)")
    var names: [String] = []
    for d in devs {
        let n = deviceName(d)
        names.append(n.replacingOccurrences(of: " ", with: "_"))
        let mfr = getString(d, kAudioObjectPropertyManufacturer) ?? "?"
        let rate = getValue(d, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)).1
        let hidden = getValue(d, addr(kAudioDevicePropertyIsHidden), UInt32(0)).1
        let transport = getValue(d, addr(kAudioDevicePropertyTransportType), UInt32(0)).1
        print("  device id=\(d) name=\"\(n)\" uid=\"\(deviceUID(d))\" mfr=\"\(mfr)\" in=\(fmtList(bufferChannels(d, kAudioObjectPropertyScopeInput))) out=\(fmtList(bufferChannels(d, kAudioObjectPropertyScopeOutput))) rate=\(rate) hidden=\(hidden) transport=\(fourcc(transport))")
        print("    inFormats=\(streamFormats(d, kAudioObjectPropertyScopeInput)) outFormats=\(streamFormats(d, kAudioObjectPropertyScopeOutput))")
    }
    let defaults: [(String, AudioObjectPropertySelector)] = [
        ("defaultInput", kAudioHardwarePropertyDefaultInputDevice),
        ("defaultOutput", kAudioHardwarePropertyDefaultOutputDevice),
        ("defaultSystemOutput", kAudioHardwarePropertyDefaultSystemOutputDevice),
    ]
    for (label, sel) in defaults {
        let d = getDefault(sel)
        print("  \(label)=\(d) \"\(d == 0 ? "-" : deviceName(d))\"")
    }
    let plugins = getArray(systemObject, addr(kAudioHardwarePropertyPlugInList), AudioObjectID(0))
    var bundles: [String] = []
    for p in plugins {
        let b = getString(p, kAudioPlugInPropertyBundleID) ?? "?"
        bundles.append(b)
        print("  plugin id=\(p) bundle=\(b)")
    }
    for p in halProcesses() {
        print("  halProcess obj=\(p.obj) pid=\(p.pid) runningIn=\(p.input) runningOut=\(p.output)")
    }
    let joined = names.joined(separator: ",")
    print("RESULT cmd=list devices=\(devs.count) names=\(joined.isEmpty ? "-" : joined) plugins=\(bundles.joined(separator: ","))")
    return 0
}

func runSetDefault(query: String) -> Int32 {
    guard let d = findDevice(query, scope: nil) else {
        print("RESULT cmd=set-default status=not-found query=\(query)")
        return 1
    }
    let eOut = setDefault(kAudioHardwarePropertyDefaultOutputDevice, d)
    let eSys = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, d)
    var eIn: OSStatus = -1
    if bufferChannels(d, kAudioObjectPropertyScopeInput).reduce(0, +) > 0 {
        eIn = setDefault(kAudioHardwarePropertyDefaultInputDevice, d)
    }
    print("RESULT cmd=set-default device=\(d) output=\(errStr(eOut)) system=\(errStr(eSys)) input=\(errStr(eIn))")
    return eOut == 0 ? 0 : 1
}
