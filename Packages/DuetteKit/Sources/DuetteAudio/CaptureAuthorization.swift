import Darwin
import Foundation

/// Asks macOS whether Duette may record other apps' sound (System Audio Recording).
///
/// Public API has no such question: a process tap that is not allowed just delivers exact zeros.
/// The one way to ask is the preflight call of the private TCC framework, which is looked up at
/// run time, so a Mac that lacks it, or answers anything unexpected, gives `.unknown` and nothing
/// else changes. `.unknown` never raises the permission hint after sound (see EngineController).
enum TCCPreflight {
    /// int TCCAccessPreflight(CFStringRef service, CFDictionaryRef options)
    private typealias Function = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let function: Function? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    /// The service name of System Audio Recording in the privacy database.
    static let audioCaptureService = "kTCCServiceAudioCapture"

    /// Asks the real TCC framework, or nil if it has no such function.
    static func askTCC(_ service: String) -> Int32? {
        function?(service as CFString, nil)
    }

    /// The raw answer for System Audio Recording, or nil when it cannot be asked.
    static func rawAudioCaptureAnswer(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                                      ask: (String) -> Int32? = TCCPreflight.askTCC) -> Int32? {
        ask(audioCaptureService)
    }

    static func audioCapture(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                             ask: (String) -> Int32? = TCCPreflight.askTCC) -> CaptureAuthorization {
        authorization(forResult: rawAudioCaptureAnswer(osVersion: osVersion, ask: ask))
    }

    /// 0 is allowed and 1 is denied. Anything else (2 is "not asked yet"), or no answer at all, is
    /// not enough to call a permission lost.
    static func authorization(forResult result: Int32?) -> CaptureAuthorization {
        switch result {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }
}

extension CoreAudioSystem {
    public func systemAudioCaptureAuthorization() -> CaptureAuthorization {
        TCCPreflight.audioCapture()
    }

    public func systemAudioCaptureRawAnswer() -> Int32? {
        TCCPreflight.rawAudioCaptureAnswer()
    }
}
