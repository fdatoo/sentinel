import SentinelKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var draft: HubSettings
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    private var urlIsValid: Bool { HubEndpoint.parseBaseURL(draft.hubURL) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://sentinel.your-tailnet.ts.net", text: $draft.hubURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !draft.hubURL.isEmpty, !urlIsValid {
                        Text("Enter an http or https URL.").font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Hub URL")
                } footer: {
                    Text("Answering needs the tailnet. Turn on VPN On Demand in the Tailscale app.")
                }

                Section("Device name") {
                    TextField("Device name", text: $draft.deviceName)
                }

                Section {
                    TextField("dev-node", text: $draft.devNode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Dev node id (optional)")
                } footer: {
                    Text("Sent as X-Sentinel-Node. Use it only against a hub started with --dev.")
                }

                if let note = model.registrationNote {
                    Section { Text(note).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(draft)
                        dismiss()
                    }
                    .disabled(!urlIsValid || draft.trimmedDeviceName.isEmpty)
                }
            }
        }
    }
}
