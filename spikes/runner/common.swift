// Throwaway spike helpers: Core Audio property access, level metering, watchdog.
import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func fourcc(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
    return "\(v)"
}

func errStr(_ e: OSStatus) -> String {
    e == 0 ? "ok" : "err\(e)/\(fourcc(UInt32(bitPattern: e)))"
}

func getValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> (OSStatus, T) {
    var address = a
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let err = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
    return (err, value)
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    var address = addr(sel, scope)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let err = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(obj, &address, 0, nil, &size, ptr)
    }
    guard err == 0, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> [T] {
    var address = a
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &address, 0, nil, &size) == 0, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    var arr = [T](repeating: zero, count: count)
    let err = arr.withUnsafeMutableBytes { buf in
        AudioObjectGetPropertyData(obj, &address, 0, nil, &size, buf.baseAddress!)
    }
    guard err == 0 else { return [] }
    return Array(arr.prefix(Int(size) / MemoryLayout<T>.stride))
}

/// Channels per buffer of a device's stream configuration in one scope.
func bufferChannels(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
    var address = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &address, 0, nil, &size) == 0, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &address, 0, nil, &size, raw) == 0 else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.map { Int($0.mNumberChannels) }
}

func formatString(_ f: AudioStreamBasicDescription) -> String {
    "\(Int(f.mSampleRate))Hz/\(f.mChannelsPerFrame)ch/\(fourcc(f.mFormatID))/flags\(f.mFormatFlags)/\(f.mBitsPerChannel)bit"
}

func streamFormats(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [String] {
    let streams = getArray(dev, addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0))
    return streams.map { s in
        let (e, f) = getValue(s, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
        return e == 0 ? formatString(f) : errStr(e)
    }
}

func fmtList(_ xs: [Float]) -> String {
    xs.isEmpty ? "-" : xs.map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
}

func fmtList(_ xs: [Double]) -> String {
    xs.isEmpty ? "-" : xs.map { String(format: "%.4f", $0) }.joined(separator: ",")
}

func fmtList(_ xs: [Int]) -> String {
    xs.isEmpty ? "-" : xs.map { String($0) }.joined(separator: ",")
}

/// Peak and RMS per input buffer, fed from a HAL IOProc. Assumes Float32 samples.
final class LevelMeter {
    private let lock = NSLock()
    private var peaks: [Float] = []
    private var sumSq: [Double] = []
    private var samples: [Int] = []
    private var channels: [Int] = []
    private var callbacks = 0
    private var firstNonZero = -1

    func process(_ abl: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        lock.lock()
        defer { lock.unlock() }
        callbacks += 1
        while peaks.count < list.count {
            peaks.append(0); sumSq.append(0); samples.append(0); channels.append(0)
        }
        var anyNonZero = false
        for i in 0..<list.count {
            let buf = list[i]
            channels[i] = Int(buf.mNumberChannels)
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            let p = data.assumingMemoryBound(to: Float32.self)
            var pk: Float32 = 0
            var ss: Double = 0
            for j in 0..<n {
                let v = p[j]
                let a = Swift.abs(v)
                if a > pk { pk = a }
                ss += Double(v) * Double(v)
            }
            if pk > peaks[i] { peaks[i] = pk }
            sumSq[i] += ss
            samples[i] += n
            if pk > 0.00001 { anyNonZero = true }
        }
        if anyNonZero && firstNonZero < 0 { firstNonZero = callbacks }
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        var rms: [Double] = []
        for i in 0..<sumSq.count {
            rms.append(samples[i] > 0 ? (sumSq[i] / Double(samples[i])).squareRoot() : 0)
        }
        let nonZero = peaks.contains { $0 > 0.00001 }
        return "callbacks=\(callbacks) bufch=\(fmtList(channels)) peaks=\(fmtList(peaks)) rms=\(fmtList(rms)) nonzero=\(nonZero ? "yes" : "no") firstnz=\(firstNonZero)"
    }
}

func startWatchdog(seconds: Double, command: String) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        print("RESULT cmd=\(command) status=watchdog-timeout seconds=\(Int(seconds))")
        exit(124)
    }
}

/// Wait while letting the main run loop handle any HAL notifications.
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let r = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)
        if r == .finished { usleep(100_000) }
    }
}

/// HAL process objects: "pid:runningInput:runningOutput" for each client coreaudiod knows.
func halProcesses() -> [(obj: AudioObjectID, pid: Int32, input: UInt32, output: UInt32)] {
    let procs = getArray(systemObject, addr(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0))
    return procs.map { p in
        let pid = getValue(p, addr(kAudioProcessPropertyPID), Int32(0)).1
        let input = getValue(p, addr(kAudioProcessPropertyIsRunningInput), UInt32(0)).1
        let output = getValue(p, addr(kAudioProcessPropertyIsRunningOutput), UInt32(0)).1
        return (obj: p, pid: pid, input: input, output: output)
    }
}
