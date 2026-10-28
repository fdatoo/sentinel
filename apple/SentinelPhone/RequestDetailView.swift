import SentinelKit
import SwiftUI

struct RequestDetailView: View {
    let model: AppModel
    let requestID: String

    @State private var loaded: Request?
    @State private var missing = false
    @State private var text = ""
    @State private var sending = false
    @State private var message: Message?
    @Environment(\.dismiss) private var dismiss

    private struct Message {
        var text: String
        var isError: Bool
    }

    private var request: Request? { model.request(id: requestID) ?? loaded }

    var body: some View {
        Group {
            if let request {
                detail(request)
            } else if missing {
                ContentUnavailableView("Request not found", systemImage: "questionmark.circle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if request == nil {
                loaded = await model.loadRequest(id: requestID)
                missing = loaded == nil
            }
        }
    }

    private func detail(_ request: Request) -> some View {
        Form {
            Section {
                Text(request.title).font(.headline)
                LabeledContent("From", value: agentLine(request))
                if let expires = request.expiresAt, request.state == .pending {
                    LabeledContent("Expires") { Text(expires, style: .relative) }
                }
            }

            if let body = request.body, !body.isEmpty {
                Section("Details") {
                    Text(MarkdownRendering.attributed(body)).textSelection(.enabled)
                }
            }

            if request.state == .pending {
                answerSection(request)
            } else {
                Section("Outcome") {
                    Text(request.resolutionSummary)
                    if let reply = request.response?.text, !reply.isEmpty {
                        Text(reply).foregroundStyle(.secondary)
                    }
                }
            }

            if let message {
                Section {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(message.isError ? .red : .primary)
                }
            }
        }
    }

    @ViewBuilder
    private func answerSection(_ request: Request) -> some View {
        if request.allowText {
            Section(request.options.isEmpty ? "Reply" : "Note (optional)") {
                TextField("Type here", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .disabled(sending)
                if request.kind != .authorize && !request.options.isEmpty {
                    Button("Send reply without choosing") { send(request, optionID: nil) }
                        .disabled(trimmedText.isEmpty || sending)
                } else if request.options.isEmpty {
                    Button("Send") { send(request, optionID: nil) }
                        .disabled(trimmedText.isEmpty || sending)
                }
            }
        }

        if !request.options.isEmpty {
            Section {
                ForEach(request.options) { option in
                    Button(role: option.style == .destructive ? .destructive : nil) {
                        send(request, optionID: option.id)
                    } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                            if request.requiresAuthentication(forOptionID: option.id) {
                                Image(systemName: "faceid").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(sending)
                }
            } footer: {
                if request.kind == .authorize {
                    Text("Approving asks for Face ID first.")
                }
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func agentLine(_ request: Request) -> String {
        if let host = request.agent.host, !host.isEmpty { return "\(request.agent.label) on \(host)" }
        return request.agent.label
    }

    private func send(_ request: Request, optionID: String?) {
        sending = true
        message = nil
        let note = trimmedText.isEmpty ? nil : trimmedText
        Task {
            let outcome = await model.answer(request, optionID: optionID, text: note)
            sending = false
            switch outcome {
            case .sent:
                dismiss()
            case .cancelled:
                break
            case .alreadyResolved(let text):
                message = Message(text: text, isError: false)
            case .failed(let text):
                message = Message(text: text, isError: true)
            }
        }
    }
}
