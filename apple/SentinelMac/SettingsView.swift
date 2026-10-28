import AppKit
import SentinelKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var draft: HubSettings

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    private var urlIsValid: Bool { HubEndpoint.parseBaseURL(draft.hubURL) != nil }

    var body: some View {
        Form {
            Section {
                TextField("Hub URL", text: $draft.hubURL, prompt: Text("https://sentinel.your-tailnet.ts.net"))
                    .autocorrectionDisabled()
                if !draft.hubURL.isEmpty, !urlIsValid {
                    Text("Enter an http or https URL.").font(.caption).foregroundStyle(.red)
                }
                TextField("Device name", text: $draft.deviceName)
                TextField("Dev node id (optional)", text: $draft.devNode, prompt: Text("dev-node"))
                    .autocorrectionDisabled()
                Text("The node id is sent as X-Sentinel-Node. Use it only against a hub started with --dev.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Text(model.connection.summary)
                        .font(.caption)
                        .foregroundStyle(isFailure ? .red : .secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Save") { model.save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!urlIsValid || draft.trimmedDeviceName.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isFailure: Bool {
        if case .failed = model.connection { return true }
        return false
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Sentinel Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
