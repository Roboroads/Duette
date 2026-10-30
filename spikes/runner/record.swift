// Throwaway spike: record from an input device through a HAL IOProc and report levels.
import CoreAudio
import Foundation

func runRecord(query: String, seconds: Double) -> Int32 {
    guard let dev = findDevice(query, scope: kAudioObjectPropertyScopeInput) else {
        print("RESULT cmd=record status=no-input-device query=\(query)")
        return 1
    }
    print("record device=\(dev) name=\"\(deviceName(dev))\" inFormats=\(streamFormats(dev, kAudioObjectPropertyScopeInput))")
    let meter = LevelMeter()
    var procID: AudioDeviceIOProcID? = nil
    let eCreate = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inInput, _, _, _ in
        meter.process(inInput)
    }
    guard eCreate == 0, let proc = procID else {
        print("RESULT cmd=record status=ioproc-failed create=\(errStr(eCreate))")
        return 1
    }
    let eStart = AudioDeviceStart(dev, proc)
    pump(0.5)
    // Does coreaudiod know this client by its real PID while it records?
    let me = getpid()
    let mine = halProcesses().filter { $0.pid == me }
    let selfSeen = mine.isEmpty ? "no" : "yes(runningIn=\(mine[0].input))"
    pump(max(0, seconds - 0.5))
    let eStop = AudioDeviceStop(dev, proc)
    _ = AudioDeviceDestroyIOProcID(dev, proc)
    print("RESULT cmd=record device=\(dev) start=\(errStr(eStart)) stop=\(errStr(eStop)) pid=\(me) halSelf=\(selfSeen) \(meter.summary())")
    return eStart == 0 ? 0 : 1
}
