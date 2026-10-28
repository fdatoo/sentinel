import AppKit
import SentinelKit
import SwiftUI

@MainActor
@Observable
final class RequestPanelModel {
    enum Phase: Equatable {
        case idle
        case sending
        /// A failed attempt; the buttons stay live so the user can retry.
        case failed(String)
        /// The request is over (answered here or elsewhere). The panel is closing.
        case resolved(String)
    }

    var request: Request
    var phase: Phase = .idle
    var text = ""

    init(request: Request) {
        self.request = request
    }
}

struct RequestPanelView: View {
    let model: RequestPanelModel
    let onAnswer: (_ optionID: String?, _ text: String?) -> Void
    let onDismiss: () -> Void

    @State private var bodyHeight: CGFloat = 0

    private var request: Request { model.request }
    private var busy: Bool { model.phase == .sending }
    private var finished: Bool {
        if case .resolved = model.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let markdown = request.body, !markdown.isEmpty, !request.sensitive {
                ScrollView {
                    Text(MarkdownRendering.attributed(markdown))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
                }
                .frame(height: min(max(bodyHeight, 1), 240))
            }

            if case .resolved(let summary) = model.phase {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                controls
                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(agentLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close. The request stays pending in the menu.")
        }
    }

    private var agentLine: String {
        if let host = request.agent.host, !host.isEmpty { return "\(request.agent.label) on \(host)" }
        return request.agent.label
    }

    @ViewBuilder
    private var controls: some View {
        if request.allowText {
            TextField(textPrompt, text: Bindable(model).text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .onSubmit(submitTextOnly)
        }

        OptionButtonLayout { optionButtons }

        if request.allowText, canSendTextOnly {
            Button("Send reply without choosing", action: submitTextOnly)
                .buttonStyle(.link)
                .disabled(busy || trimmedText.isEmpty)
        }

        if busy {
            ProgressView().controlSize(.small)
        }
    }

    private var textPrompt: String {
        request.options.isEmpty ? "Reply" : "Add a note (optional)"
    }

    private var trimmedText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For an authorize request, text without a choice would be neither approval
    /// nor denial, so only offer it when there are no options to pick from.
    private var canSendTextOnly: Bool {
        request.kind != .authorize && !request.options.isEmpty
    }

    private var optionButtons: some View {
        ForEach(request.options) { option in
            Button(role: option.style == .destructive ? .destructive : nil) {
                onAnswer(option.id, trimmedText.isEmpty ? nil : trimmedText)
            } label: {
                // Bordered buttons keep labels on one line unless told otherwise;
                // a label wider than the panel wraps and the bezel grows with it.
                Text(option.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(option.style == .destructive ? .red : nil)
            .controlSize(.large)
            .disabled(busy || finished)
        }
    }

    private func submitTextOnly() {
        guard !trimmedText.isEmpty, !busy else { return }
        if request.options.isEmpty || canSendTextOnly {
            onAnswer(nil, trimmedText)
        }
    }
}

/// Lays option buttons out side by side at equal widths when every label fits
/// its share of the row, and stacks them full width otherwise. An equal split
/// that only fits on total width would still truncate the longest label.
private struct OptionButtonLayout: Layout {
    var maxPerRow = 3
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    private func fitsInRow(_ subviews: Subviews, width: CGFloat) -> Bool {
        guard subviews.count <= maxPerRow else { return false }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return widest * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1) <= width
    }

    private func rowItemWidth(_ count: Int, width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        if fitsInRow(subviews, width: width) {
            let item = ProposedViewSize(width: rowItemWidth(subviews.count, width: width), height: nil)
            return CGSize(width: width, height: subviews.map { $0.sizeThatFits(item).height }.max() ?? 0)
        }
        let item = ProposedViewSize(width: width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(item).height }
        return CGSize(width: width, height: heights.reduce(0, +) + rowSpacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if fitsInRow(subviews, width: bounds.width) {
            let itemWidth = rowItemWidth(subviews.count, width: bounds.width)
            var x = bounds.minX
            for subview in subviews {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: itemWidth, height: bounds.height)
                )
                x += itemWidth + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    proposal: ProposedViewSize(width: bounds.width, height: height)
                )
                y += height + rowSpacing
            }
        }
    }
}

/// Non-activating so a prompt appearing mid-typing doesn't steal the keyboard
/// from the app in front, yet able to become key once the user clicks a field.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel's content height changes after layout; keep the top edge fixed
    /// so it grows downward instead of off the top of the screen.
    private var pinnedTop: CGFloat?

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        pinnedTop = frame.maxY
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinned(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(pinned(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func pinned(_ rect: NSRect) -> NSRect {
        guard let pinnedTop else { return rect }
        var rect = rect
        rect.origin.y = pinnedTop - rect.height
        return rect
    }
}

@MainActor
final class PanelController {
    private struct Entry {
        let panel: FloatingPanel
        let model: RequestPanelModel
        var closeTask: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]
    var answerHandler: ((_ request: Request, _ optionID: String?, _ text: String?) -> Void)?

    func model(for requestID: String) -> RequestPanelModel? {
        entries[requestID]?.model
    }

    func show(_ request: Request) {
        if let entry = entries[request.id] {
            entry.model.request = request
            entry.panel.orderFrontRegardless()
            return
        }

        let model = RequestPanelModel(request: request)
        let view = RequestPanelView(
            model: model,
            onAnswer: { [weak self, weak model] optionID, text in
                guard let self, let model else { return }
                self.answerHandler?(model.request, optionID, text)
            },
            onDismiss: { [weak self] in self?.close(requestID: request.id) }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        controller.view.layoutSubtreeIfNeeded()
        panel.setContentSize(controller.view.fittingSize)
        position(panel)
        entries[request.id] = Entry(panel: panel, model: model)
        panel.orderFrontRegardless()
    }

    func update(_ request: Request) {
        entries[request.id]?.model.request = request
    }

    /// Shows `summary` in the panel (when one is open) and closes it shortly after.
    func resolve(requestID: String, summary: String, after delay: Duration = .seconds(4)) {
        guard var entry = entries[requestID] else { return }
        entry.closeTask?.cancel()
        entry.model.phase = .resolved(summary)
        entry.closeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.close(requestID: requestID)
        }
        entries[requestID] = entry
    }

    func close(requestID: String) {
        guard let entry = entries.removeValue(forKey: requestID) else { return }
        entry.closeTask?.cancel()
        entry.panel.orderOut(nil)
    }

    /// Stacks new panels down from the top right of the main screen.
    private func position(_ panel: FloatingPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let offset = CGFloat(entries.count % 6) * 28
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 24 - offset,
            y: frame.maxY - size.height - 24 - offset
        ))
    }
}
