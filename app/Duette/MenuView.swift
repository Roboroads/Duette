import AppKit
import DuetteAudio
import SwiftUI

/// What opens from the menu bar icon. Plain words, big targets, every control labelled for
/// VoiceOver. Anything technical is under "For experts".
struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var showExperts = false
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(line: model.statusLine, onFix: { model.perform($0) })

            if let warning = model.feedbackWarning {
                WarningBanner(
                    text: warning,
                    hint: "In \(model.selectedAppName ?? "that app"), choose your real microphone instead of “Duette”.")
            }

            AppSourceRow(model: model)
            MicSourceRow(model: model)
            OutputRow(model: model)

            LaunchAtLoginRow(
                state: model.loginItem,
                setEnabled: { model.setLaunchAtLogin($0) },
                openSettings: { model.perform(.openLoginItemsSettings) })

            if let note = model.message {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showExperts.toggle() }
                } label: {
                    HStack {
                        Text("For experts")
                            .font(.headline)
                        Spacer(minLength: 0)
                        Image(systemName: showExperts ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("For experts")
                .accessibilityValue(showExperts ? "expanded" : "collapsed")
                .accessibilityHint("Shows technical settings")

                if showExperts {
                    ExpertsView(model: model)
                }
            }

            Divider()
            FooterView(model: model)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { model.menuDidOpen() }
        .onReceive(refreshTimer) { _ in model.refreshChoices() }
    }
}

// MARK: - Status

extension StatusLine.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .waiting: return .orange
        case .problem: return .red
        case .idle: return .gray
        }
    }

    /// The colour is not the only cue; VoiceOver reads this.
    var spokenName: String {
        switch self {
        case .good: return "OK"
        case .waiting: return "Waiting"
        case .problem: return "Problem"
        case .idle: return "Paused"
        }
    }
}

/// One sentence with a coloured dot, and a button when there is something to press.
struct StatusHeader: View {
    let line: StatusLine
    let onFix: (FixAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(line.tone.color)
                    .frame(width: 14, height: 14)
                    .padding(.top, 3)
                Text(line.message)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(line.tone.spokenName): \(line.message)")

            if let fix = line.fix {
                Button {
                    onFix(fix)
                } label: {
                    Text(fix.title)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

struct WarningBanner: View {
    let text: String
    let hint: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sources

/// A volume slider with a mute button and a level bar, under a header that says what it is.
struct SourceRow<Header: View, LevelView: View>: View {
    let name: String
    @Binding var gain: Double
    @Binding var muted: Bool
    let header: Header
    let level: LevelView

    init(name: String, gain: Binding<Double>, muted: Binding<Bool>,
         @ViewBuilder header: () -> Header, @ViewBuilder level: () -> LevelView) {
        self.name = name
        _gain = gain
        _muted = muted
        self.header = header()
        self.level = level()
    }

    private var percent: Int { Int((gain * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 10) {
                Slider(value: $gain, in: 0...Double(MixEngine.maxGain))
                    .controlSize(.large)
                    .accessibilityLabel("Volume of \(name)")
                    .accessibilityValue("\(percent) percent")
                Text("\(percent)%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle(isOn: $muted) {
                    Text(muted ? "Muted" : "Mute")
                        .frame(minWidth: 52, minHeight: 24)
                }
                .toggleStyle(.button)
                .controlSize(.large)
                .accessibilityLabel("Mute \(name)")
            }
            level
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// A level bar that follows the engine at 30 frames per second.
struct LiveLevel: View {
    let title: String
    let peak: () -> Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            MeterView(title: title, peak: peak(), date: context.date)
        }
    }
}

struct RowTitle: View {
    let text: String
    let icon: AnyView

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

enum AppIcons {
    /// The app's icon at menu size. Falls back to a plain symbol.
    static func icon(bundleID: String, pid: pid_t? = nil, side: CGFloat = 18) -> NSImage {
        var image: NSImage?
        if let pid, let running = NSRunningApplication(processIdentifier: pid) {
            image = running.icon
        }
        if image == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let base = image ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        let copy = (base.copy() as? NSImage) ?? base
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}

struct AppSourceRow: View {
    @ObservedObject var model: AppModel

    private struct Entry: Identifiable {
        var bundleID: String
        var name: String
        var pid: pid_t?
        var id: String { bundleID }
    }

    /// What the picker offers: the running apps, and the chosen app even when it is not running.
    private var entries: [Entry] {
        var list = model.appChoices.map { Entry(bundleID: $0.bundleID, name: $0.name, pid: $0.pid) }
        if let chosen = model.appBundleID, !list.contains(where: { $0.bundleID == chosen }) {
            list.insert(Entry(bundleID: chosen, name: model.displayName(for: chosen) + " (not running)", pid: nil), at: 0)
        }
        return list
    }

    private var selection: Binding<String> {
        Binding(get: { model.appBundleID ?? "" }, set: { model.selectApp($0.isEmpty ? nil : $0) })
    }

    var body: some View {
        let name = model.selectedAppName
        SourceRow(
            name: name.map { "sound from \($0)" } ?? "app sound",
            gain: Binding(get: { Double(model.gain(for: .app)) }, set: { model.setGain(Float($0), for: .app) }),
            muted: Binding(get: { model.isMuted(.app) }, set: { model.setMuted($0, for: .app) }),
            header: {
                VStack(alignment: .leading, spacing: 8) {
                    RowTitle(
                        text: name.map { "Sound from \($0)" } ?? "Sound from an app",
                        icon: AnyView(appIcon(side: 28)))
                    Picker("Choose an app", selection: selection) {
                        ForEach(entries) { entry in
                            Label {
                                Text(entry.name)
                            } icon: {
                                Image(nsImage: AppIcons.icon(bundleID: entry.bundleID, pid: entry.pid))
                            }
                            .tag(entry.bundleID)
                        }
                        Divider()
                        Text("No app, only my microphone").tag("")
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .accessibilityLabel("Choose the app to share")
                }
            },
            level: {
                LiveLevel(title: "Sound from app", peak: { model.currentMeters().app.peak })
            })
    }

    @ViewBuilder
    private func appIcon(side: CGFloat) -> some View {
        if let bundleID = model.appBundleID {
            Image(nsImage: AppIcons.icon(bundleID: bundleID, side: side))
        } else {
            Image(systemName: "app.dashed").font(.title2)
        }
    }
}

struct MicSourceRow: View {
    @ObservedObject var model: AppModel

    private var choices: [MicChoice] {
        var list = model.micChoices
        if !list.contains(where: { $0.selection == model.mic }) {
            list.append(MicChoice(selection: model.mic, name: "Your microphone (not connected)"))
        }
        return list
    }

    private var selection: Binding<MicSelection> {
        Binding(get: { model.mic }, set: { model.selectMic($0) })
    }

    var body: some View {
        SourceRow(
            name: "your microphone",
            gain: Binding(get: { Double(model.gain(for: .mic)) }, set: { model.setGain(Float($0), for: .mic) }),
            muted: Binding(get: { model.isMuted(.mic) }, set: { model.setMuted($0, for: .mic) }),
            header: {
                VStack(alignment: .leading, spacing: 8) {
                    RowTitle(text: "Your microphone",
                             icon: AnyView(Image(systemName: "mic.fill").font(.title2)))
                    Picker("Choose a microphone", selection: selection) {
                        ForEach(choices, id: \.selection) { choice in
                            Text(choice.name).tag(choice.selection)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .accessibilityLabel("Choose your microphone")
                }
            },
            level: {
                LiveLevel(title: "Your microphone", peak: { model.currentMeters().mic.peak })
            })
    }
}

struct OutputRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SourceRow(
            name: "everything together",
            gain: Binding(get: { Double(model.gain(for: .output)) }, set: { model.setGain(Float($0), for: .output) }),
            muted: Binding(get: { model.isMuted(.output) }, set: { model.setMuted($0, for: .output) }),
            header: {
                RowTitle(text: "What other apps hear",
                         icon: AnyView(Image(systemName: "waveform").font(.title2)))
            },
            level: {
                LiveLevel(title: "What other apps hear", peak: { model.currentMeters().output.peak })
            })
    }
}

// MARK: - Launch at login

struct LaunchAtLoginRow: View {
    let state: LoginItemState
    let setEnabled: (Bool) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { state == .on || state == .needsApproval }, set: { setEnabled($0) })) {
                Text("Open Duette when I log in")
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .disabled(state == .unavailable)
            .accessibilityLabel("Open Duette when I log in")

            if state == .needsApproval {
                Text("Your Mac needs your OK first. Switch Duette on in Login Items.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items", action: openSettings)
                    .controlSize(.large)
            }
        }
    }
}

// MARK: - For experts

struct ExpertsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Buffer size", selection: Binding(get: { model.bufferFrameSize },
                                                    set: { model.setBufferFrameSize($0) })) {
                ForEach(EngineConfiguration.bufferFrameSizes, id: \.self) { size in
                    Text("\(size) frames").tag(size)
                }
            }
            .controlSize(.large)
            .accessibilityLabel("Buffer size")
            Text("Smaller is faster but can crackle. 128 suits most Macs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                let snapshot = model.expertSnapshot()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated delay: \(snapshot.latencyText)")
                    Text("Missed deadlines: \(snapshot.overloads)")
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }

            Toggle("Play test tone (driver)", isOn: Binding(get: { model.driverToneOn },
                                                           set: { model.setDriverTone($0) }))
                .controlSize(.large)
            Toggle("Play test tone (engine)", isOn: Binding(get: { model.engineToneOn },
                                                           set: { model.setEngineTone($0) }))
                .controlSize(.large)
        }
    }
}

// MARK: - Footer

struct RowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RowButton(title: "Export Diagnostics…", systemImage: "square.and.arrow.up") {
                model.exportDiagnostics()
            }
            .disabled(model.export == .working)
            exportNote
            RowButton(title: "Show the welcome guide", systemImage: "questionmark.circle") {
                model.onShowGuide?()
            }
            RowButton(title: "About Duette", systemImage: "info.circle") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            RowButton(title: "Quit Duette", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var exportNote: some View {
        switch model.export {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Collecting the details…")
            }
            .font(.subheadline)
        case .saved(let url, let onDesktop):
            VStack(alignment: .leading, spacing: 4) {
                Text(onDesktop ? "Saved on your Desktop. Send that file to whoever is helping you."
                               : "Saved. Send that file to whoever is helping you.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.large)
            }
        case .failed:
            Text("Duette couldn't save the file. Please try again.")
                .font(.subheadline)
        }
    }
}

#if DEBUG
struct MenuView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(
                line: StatusLine(tone: .problem, message: "Duette needs permission to hear Discord",
                                 fix: .openSystemAudioSettings),
                onFix: { _ in })
            WarningBanner(text: "Discord is using Duette as its input: callers will hear themselves",
                          hint: "In Discord, choose your real microphone instead of “Duette”.")
            SourceRow(name: "your microphone", gain: .constant(1), muted: .constant(false)) {
                RowTitle(text: "Your microphone", icon: AnyView(Image(systemName: "mic.fill")))
            } level: {
                MeterBar(fraction: 0.6)
            }
            LaunchAtLoginRow(state: .needsApproval, setEnabled: { _ in }, openSettings: {})
        }
        .padding(16)
        .frame(width: 360)
    }
}
#endif
