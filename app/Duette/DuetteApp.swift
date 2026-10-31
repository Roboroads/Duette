import SwiftUI

@main
struct DuetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The uninstaller runs the app with a job on the command line (see LaunchCommand). Do it and
        // quit before anything else starts: no menu bar icon, no audio, no second-copy check.
        if let command = LaunchCommand(arguments: CommandLine.arguments) {
            exit(command.run(loginItem: SystemLoginItem()) { print($0) })
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}
