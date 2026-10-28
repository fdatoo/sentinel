import SentinelKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .pending

    enum Tab: String, CaseIterable, Identifiable {
        case pending = "Pending"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            content
                .navigationTitle("Sentinel")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    RequestDetailView(model: model, requestID: id)
                }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .notConfigured:
            ContentUnavailableView {
                Label("No hub configured", systemImage: "server.rack")
            } description: {
                Text("Enter your Sentinel hub's URL to see requests.")
            } actions: {
                Button("Open Settings") { model.showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        case .loading:
            ProgressView("Contacting hub...")
        case .unreachable where model.pending.isEmpty && model.history.isEmpty:
            unreachableView
        default:
            list
        }
    }

    private var unreachableView: some View {
        ContentUnavailableView {
            Label("Hub unreachable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Check that Tailscale is connected, then try again. Answering needs the tailnet.")
        } actions: {
            Button("Try Again") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            if model.loadState == .unreachable {
                Section {
                    Label("Hub unreachable. Check that Tailscale is connected.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                    Button("Try Again") { Task { await model.refresh() } }
                }
            }
            if case .failed(let message) = model.loadState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            if let banner = model.banner {
                Section {
                    Label(banner, systemImage: "info.circle")
                    Button("Dismiss") { model.banner = nil }
                }
            }
            if let note = model.registrationNote {
                Section {
                    Label(note, systemImage: "exclamationmark.triangle").font(.footnote)
                }
            }

            Section {
                Picker("List", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            let rows = tab == .pending ? model.pending : model.history
            Section {
                if rows.isEmpty {
                    Text(tab == .pending ? "Nothing is waiting on you." : "No past requests.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { request in
                    NavigationLink(value: request.id) {
                        RequestRow(request: request)
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }
}

struct RequestRow: View {
    let request: Request

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.title).font(.headline).lineLimit(2)
            HStack {
                Text(agentLine)
                Spacer()
                if request.state != .pending {
                    Text(request.resolutionSummary).lineLimit(1)
                } else if let created = request.createdAt {
                    Text(created, style: .relative)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var agentLine: String {
        if let host = request.agent.host, !host.isEmpty { return "\(request.agent.label) on \(host)" }
        return request.agent.label
    }
}
