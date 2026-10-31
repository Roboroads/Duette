import AppKit
import CoreAudio
import DuetteAudio
import Foundation
import os

/// How the "Export Diagnostics" button is doing.
enum ExportState: Equatable {
    case idle
    case working
    /// Saved here, where the user chose.
    case saved(URL)
    /// Something went wrong; the text says what, in plain words.
    case failed(String)
}

/// How "Measure latency" is doing.
enum LatencyCheck: Equatable {
    case idle
    case measuring
    case done(LatencyMeasurement)
    /// The text says what went wrong, in plain words.
    case failed(String)
}

/// The numbers under "For experts".
struct ExpertSnapshot: Equatable {
    var latencyText: String
    var overloads: UInt64
}

/// Everything the menu and the welcome guide show and do. It owns the EngineController, saves the
/// user's choices, and turns the engine's status into plain words.
///
/// Published properties change on the main thread only. Engine updates arrive on the control
/// queue and are moved over by `services.runOnMain`.
final class AppModel: ObservableObject {
    static let discordBundleID = "com.hnc.Discord"

    // What the menu shows.
    @Published private(set) var status = EngineStatus()
    @Published private(set) var appChoices: [AppEntry] = []
    @Published private(set) var micChoices: [MicChoice] = []
    @Published private(set) var micPermission: PermissionState
    @Published private(set) var loginItem: LoginItemState = .off
    @Published private(set) var export: ExportState = .idle
    /// A short plain-words note about something that went wrong in the menu (not the engine).
    @Published private(set) var message: String?
    @Published private(set) var driverToneOn = false
    @Published private(set) var engineToneOn = false
    @Published private(set) var latencyCheck: LatencyCheck = .idle

    // What the user chose; saved by Settings.
    @Published private(set) var appBundleID: String?
    @Published private(set) var mic: MicSelection
    @Published private(set) var bufferFrameSize: UInt32
    @Published private(set) var onboardingDone: Bool
    /// The screen of the welcome guide that shows.
    @Published private(set) var guide = OnboardingFlow()
    @Published private(set) var gains: [MixSource: Float]
    @Published private(set) var mutes: [MixSource: Bool]

    let controller: EngineController
    /// Set by the app to show the welcome guide again.
    var onShowGuide: (() -> Void)?

    private let settings: Settings
    private let services: AppServices
    private var engineStarted = false
    private var selfTests: [String: String] = [:]
    private var activeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "me.roboroads.duette.app", category: "app")

    init(settings: Settings, services: AppServices) {
        self.settings = settings
        self.services = services
        if settings.isFirstRun {
            // Zero choices: Discord is the app most people want, so it is already picked.
            settings.appBundleID = services.isInstalled(Self.discordBundleID) ? Self.discordBundleID : nil
        }
        appBundleID = settings.appBundleID
        mic = settings.mic
        bufferFrameSize = settings.bufferFrameSize
        onboardingDone = settings.onboardingDone
        micPermission = services.permissions.microphone
        var storedGains: [MixSource: Float] = [:]
        var storedMutes: [MixSource: Bool] = [:]
        for source in MixSource.allCases {
            storedGains[source] = settings.gain(source)
            storedMutes[source] = settings.isMuted(source)
        }
        gains = storedGains
        mutes = storedMutes
        controller = EngineController(audioSystem: services.audioSystem, scheduler: services.scheduler)
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    static func live() -> AppModel {
        AppModel(settings: Settings(), services: .live())
    }

    // MARK: Starting and stopping

    var configuration: EngineConfiguration {
        EngineConfiguration(appBundleID: appBundleID, mic: mic, bufferFrameSize: bufferFrameSize)
    }

    /// Called once at launch. The engine waits for the welcome guide: its microphone question and
    /// the app sound question belong to the guide's screens.
    func start() {
        pushMixToEngine()
        refreshPermission()
        refreshLoginItem()
        refreshDriverTone()
        refreshChoices()
        controller.onStatusChange = { [weak self] new in self?.receive(new) }
        status = controller.status
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuDidOpen()
        }
        if onboardingDone { startEngine() }
    }

    func stop() {
        controller.stop()
        engineStarted = false
        // The driver's test beep lives in the driver and would go on after Duette quits.
        if services.driverToneState() == true { try? services.setDriverTone(false) }
    }

    // MARK: The welcome guide

    func guideNext() {
        let leaving = guide.step
        guide.next()
        // The microphone and the app sound screens are behind us: from here on Duette runs.
        if leaving == .appSound { completeOnboarding() }
    }

    func guideBack() {
        guide.back()
    }

    /// The guide opens at its first screen.
    func resetGuide() {
        guide = OnboardingFlow()
    }

    /// The guide's window closed. Closing it on or after the app sound screen counts as done: both
    /// permission screens were shown, and the engine must run on later launches too.
    func guideWindowClosed() {
        if guide.step.rawValue >= OnboardingFlow.Step.appSound.rawValue { completeOnboarding() }
    }

    /// Marks setup as done and starts the engine, which is also what makes macOS ask about the
    /// app's sound. Safe to call again.
    func completeOnboarding() {
        settings.onboardingDone = true
        onboardingDone = true
        startEngine()
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        controller.start(configuration)
    }

    private func receive(_ new: EngineStatus) {
        services.runOnMain { [weak self] in self?.apply(new) }
    }

    private func apply(_ new: EngineStatus) {
        if new.state != status.state {
            let line = StatusLine.make(status: new, selectedAppName: selectedAppName, micPermission: micPermission,
                                       setupDone: onboardingDone)
            log.info("Engine state changed: \(String(describing: new.state), privacy: .public); the menu says: \(line.message, privacy: .public)")
        }
        status = new
    }

    // MARK: What the user chose

    func selectApp(_ bundleID: String?) {
        guard bundleID != appBundleID else { return }
        appBundleID = bundleID
        settings.appBundleID = bundleID
        pushConfiguration()
    }

    func selectMic(_ selection: MicSelection) {
        guard selection != mic else { return }
        mic = selection
        settings.mic = selection
        pushConfiguration()
    }

    func setBufferFrameSize(_ size: UInt32) {
        guard EngineConfiguration.bufferFrameSizes.contains(size), size != bufferFrameSize else { return }
        bufferFrameSize = size
        settings.bufferFrameSize = size
        pushConfiguration()
    }

    private func pushConfiguration() {
        if engineStarted { controller.update(configuration) }
    }

    func gain(for source: MixSource) -> Float {
        gains[source] ?? Settings.defaultGain
    }

    func isMuted(_ source: MixSource) -> Bool {
        mutes[source] ?? false
    }

    /// Gains go from 0% to 200%; anything else is clamped.
    func setGain(_ value: Float, for source: MixSource) {
        let clamped = Settings.clampGain(value)
        gains[source] = clamped
        settings.setGain(clamped, for: source)
        controller.engine.setGain(clamped, for: source)
    }

    func setMuted(_ muted: Bool, for source: MixSource) {
        mutes[source] = muted
        settings.setMuted(muted, for: source)
        controller.engine.setMuted(muted, for: source)
    }

    private func pushMixToEngine() {
        for source in MixSource.allCases {
            controller.engine.setGain(gain(for: source), for: source)
            controller.engine.setMuted(isMuted(source), for: source)
        }
    }

    // MARK: Words for the UI

    func displayName(for bundleID: String) -> String {
        if let entry = appChoices.first(where: { $0.bundleID == bundleID }) { return entry.name }
        if let name = services.displayName(bundleID) { return name }
        return AppNaming.fallbackName(bundleID)
    }

    /// The name of the chosen app, or nil for "just my microphone".
    var selectedAppName: String? {
        appBundleID.map { displayName(for: $0) }
    }

    var statusLine: StatusLine {
        StatusLine.make(status: status, selectedAppName: selectedAppName, micPermission: micPermission,
                        setupDone: onboardingDone)
    }

    /// Shown as a banner in the menu while the chosen app records "Duette" itself.
    var feedbackWarning: String? {
        guard status.feedbackLoop else { return nil }
        return "\(selectedAppName ?? "An app") is using Duette as its input: callers will hear themselves"
    }

    /// Whether the menu bar icon carries a badge.
    var hasWarning: Bool {
        status.feedbackLoop
    }

    /// What VoiceOver reads for the menu bar icon.
    var menuBarDescription: String {
        "Duette. " + statusLine.message + (hasWarning ? ". Warning: callers can hear themselves" : "")
    }

    // MARK: Menu events

    /// The menu opened, or the app came to the front: look again at everything that can change
    /// behind our back.
    func menuDidOpen() {
        refreshPermission()
        refreshLoginItem()
        refreshDriverTone()
        refreshChoices()
    }

    func refreshChoices() {
        let apps = controller.appChoices()
        let mics = controller.micChoices()
        if apps != appChoices { appChoices = apps }
        if mics != micChoices { micChoices = mics }
    }

    func refreshPermission() {
        setMicPermission(services.permissions.microphone)
    }

    private func setMicPermission(_ state: PermissionState) {
        guard state != micPermission else { return }
        let wasGranted = micPermission == .granted
        micPermission = state
        // The mic was opened without permission and gave silence; open it again now it may.
        if state == .granted, !wasGranted, engineStarted { controller.rebuild() }
    }

    func refreshLoginItem() {
        let state = services.loginItem.state
        if state != loginItem { loginItem = state }
    }

    func perform(_ fix: FixAction) {
        switch fix {
        case .openMicrophoneSettings:
            services.openURL(SettingsPane.microphone.url)
        case .openSystemAudioSettings:
            services.openURL(SettingsPane.systemAudioRecording.url)
        case .allowMicrophone:
            services.permissions.requestMicrophone { [weak self] state in self?.setMicPermission(state) }
        case .tryAgain:
            if engineStarted { controller.rebuild() } else { startEngine() }
        case .continueSetup:
            onShowGuide?()
        case .openLoginItemsSettings:
            services.openLoginItemsSettings()
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try services.loginItem.setEnabled(enabled)
            message = nil
        } catch {
            log.error("Launch at login could not be changed: \(error.localizedDescription, privacy: .public)")
            message = "Duette couldn't change this. You can also do it in System Settings > General > Login Items & Extensions."
        }
        refreshLoginItem()
    }

    // MARK: For experts

    /// The driver's test beep keeps playing after the app quits, so what the switch shows comes from
    /// the driver, not from what this run did.
    func refreshDriverTone() {
        let state = services.driverToneState() ?? false
        if state != driverToneOn { driverToneOn = state }
    }

    func setDriverTone(_ on: Bool) {
        do {
            try services.setDriverTone(on)
            driverToneOn = on
            selfTests["driverTestTone"] = on ? "on" : "off"
            message = nil
        } catch {
            // The beep is still in the state it was in, so the switch keeps showing that.
            selfTests["driverTestTone"] = "failed: \(error.localizedDescription)"
            log.error("The driver's test tone could not be changed: \(error.localizedDescription, privacy: .public)")
            message = "The test beep needs Duette to be installed. Run the Duette installer and try again."
        }
    }

    func setEngineTone(_ on: Bool) {
        controller.engine.testTone = on
        engineToneOn = on
        selfTests["engineTestTone"] = on ? "on" : "off"
    }

    func currentMeters() -> Meters {
        controller.engine.meters()
    }

    func expertSnapshot() -> ExpertSnapshot {
        var latency = "not running"
        if let aggregate = status.aggregateID {
            let duette = services.audioSystem.deviceID(forUID: DuetteDriver.deviceUID).map(services.deviceTiming)
            let estimate = LatencyModel.estimate(aggregate: services.deviceTiming(aggregate), duette: duette,
                                                 sampleRate: status.sampleRate ?? 48000)
            latency = "about \(Int(estimate.milliseconds.rounded())) ms"
        }
        return ExpertSnapshot(latencyText: latency, overloads: controller.engine.stats().overloads)
    }

    // MARK: Measure latency

    /// "Measure latency": the engine pauses for about a second while a test sound goes through
    /// Duette, and the answer is said in plain words. Apps listening to Duette hear the sound.
    func measureLatency() {
        guard latencyCheck != .measuring else { return }
        latencyCheck = .measuring
        controller.measureLatency(timing: services.deviceTiming) { [weak self] result in
            guard let self else { return }
            self.services.runOnMain { self.finishLatency(result) }
        }
    }

    private func finishLatency(_ result: Result<LatencyMeasurement, LatencyMeasurementError>) {
        switch result {
        case .success(let measurement):
            latencyCheck = .done(measurement)
            let rate = measurement.sampleRate > 0 ? measurement.sampleRate : 48000
            let summary = String(format: "%.1f ms: loopback %.2f ms measured, %.2f ms estimated", measurement.totalMilliseconds,
                                 measurement.loopback.meanFrames * 1000 / rate,
                                 Double(measurement.estimate.loopbackFrames) * 1000 / rate)
            selfTests["latency"] = summary
            log.info("Latency measured: \(summary, privacy: .public)")
        case .failure(let error):
            latencyCheck = .failed(Self.plainWords(error))
            selfTests["latency"] = "failed: \(error)"
            log.error("The latency could not be measured: \(String(describing: error), privacy: .public)")
        }
    }

    static func plainWords(_ error: LatencyMeasurementError) -> String {
        switch error {
        case .notRunning:
            return "Duette isn't running yet, so there is nothing to measure."
        case .driverMissing:
            return "Duette's driver isn't installed. Run the Duette installer and try again."
        case .notHeard:
            return "Duette couldn't hear its test sound. Check that Duette may use the microphone, then try again."
        case .unsupported, .failed:
            return "The measurement didn't work. Please try again."
        }
    }

    /// One plain sentence: what Duette adds, or why there is no answer.
    var latencyResult: String? {
        switch latencyCheck {
        case .idle, .measuring:
            return nil
        case .done(let measurement):
            return "Duette adds about \(max(1, Int(measurement.totalMilliseconds.rounded()))) ms of delay."
        case .failed(let text):
            return text
        }
    }

    /// The measured loopback next to what was expected.
    var latencyDetail: String? {
        guard case .done(let measurement) = latencyCheck else { return nil }
        let rate = measurement.sampleRate > 0 ? measurement.sampleRate : 48000
        return String(format: "The test sound took %.1f ms through Duette (expected %.1f ms).",
                      measurement.loopback.meanFrames * 1000 / rate, Double(measurement.estimate.loopbackFrames) * 1000 / rate)
    }

    /// What the self-tests found, for diagnostics.
    var selfTestResults: [String: String] { selfTests }

    // MARK: Diagnostics

    func diagnosticsPermissions() -> [String: String] {
        [
            "microphone": micPermission.rawValue,
            "systemAudioRecording": status.appSilentWhilePlaying
                ? "probably denied: the app is playing but only silence arrives"
                : "unknown: macOS has no check for it; allowed if sound arrives",
        ]
    }

    func exportDiagnostics() {
        guard export != .working else { return }
        export = .working
        let permissions = diagnosticsPermissions()
        let selfTests = self.selfTests
        let collector = DiagnosticsCollector(audioSystem: services.audioSystem, controller: controller,
                                             timing: services.deviceTiming, selfTestTone: services.driverToneState)
        let exporter = services.diagnosticsExporter
        services.runInBackground { [weak self] in
            let built = Result { () throws -> URL in
                let report = collector.collect(permissions: permissions, selfTests: selfTests)
                return try exporter.build(report: try DiagnosticsCollector.encode(report))
            }
            guard let self else { return }
            self.services.runOnMain { self.finishExport(built) }
        }
    }

    /// The zip is made; ask where to put it, move it there and show it in Finder.
    private func finishExport(_ built: Result<URL, Error>) {
        let manager = FileManager.default
        switch built {
        case .failure(let error):
            log.error("The diagnostics could not be collected: \(String(describing: error), privacy: .public)")
            export = .failed("Duette couldn't put the details together. Please try again.")
        case .success(let zip):
            guard let destination = services.chooseDestination(zip.lastPathComponent) else {
                // They changed their mind.
                try? manager.removeItem(at: zip)
                export = .idle
                return
            }
            do {
                // The save panel already asked about replacing a file that is there.
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.moveItem(at: zip, to: destination)
                export = .saved(destination)
                services.reveal(destination)
            } catch {
                log.error("The diagnostics could not be saved: \(error.localizedDescription, privacy: .public)")
                try? manager.removeItem(at: zip)
                export = .failed("Duette couldn't save the file there. Please choose another place.")
            }
        }
    }
}
