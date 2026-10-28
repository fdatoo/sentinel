import AppKit
import SentinelKit
import SwiftUI

@main
struct SentinelMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            let count = model.pending.count
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 {
                Text("\(count)")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        let requests = model.pending.requests
        if requests.isEmpty {
            Text("No pending requests")
        } else {
            ForEach(requests) { request in
                Button("\(request.agent.label): \(request.title)") {
                    model.showPanel(requestID: request.id)
                }
            }
        }

        Divider()

        Text(model.connection.summary)

        Toggle("Launch at login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Button("Settings...") { model.showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Sentinel") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
