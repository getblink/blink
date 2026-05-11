import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

struct ChatMockMessage: Identifiable {
    enum Role { case incoming, outgoing }
    let id = UUID()
    let role: Role
    let name: String?
    let text: String
}

struct OnboardingFixture {
    let tldr: String
    let suggestions: [String]
    let messages: [ChatMockMessage]

    static func load() -> OnboardingFixture {
        let resourceRoot = Bundle.main.resourceURL
        let nestedDir = resourceRoot?.appendingPathComponent("onboarding", isDirectory: true)
        let jsonURL = [
            nestedDir?.appendingPathComponent("tldr.json"),
            resourceRoot?.appendingPathComponent("tldr.json"),
        ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }

        let fallback = OnboardingFixture(
            tldr: "Sam is asking whether the launch checklist is ready before tomorrow's beta invite. They mostly need a concise go/no-go and any remaining blocker.",
            suggestions: [
                "Yes, the launch checklist is ready. I only want one last pass on the permissions wording before we send the beta invite.",
                "Almost. The core flow is ready, but I still need to verify the fresh-install permission path once more.",
                "Not yet. I found one first-run issue and will send a clean go/no-go after I retest it.",
            ],
            messages: defaultMessages()
        )

        guard let url = jsonURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }

        let tldr = (json["tldr"] as? String) ?? fallback.tldr
        let suggestions = (json["suggestions"] as? [String]) ?? fallback.suggestions
        let messages: [ChatMockMessage]
        if let raw = json["messages"] as? [[String: Any]], !raw.isEmpty {
            messages = raw.compactMap { entry -> ChatMockMessage? in
                guard let text = entry["text"] as? String else { return nil }
                let roleRaw = (entry["role"] as? String) ?? "incoming"
                let role: ChatMockMessage.Role = (roleRaw == "outgoing") ? .outgoing : .incoming
                let name = entry["name"] as? String
                return ChatMockMessage(role: role, name: name, text: text)
            }
        } else {
            messages = defaultMessages()
        }
        return OnboardingFixture(tldr: tldr, suggestions: suggestions, messages: messages)
    }

    private static func defaultMessages() -> [ChatMockMessage] {
        [
            ChatMockMessage(role: .incoming, name: "Sam", text: "Hey — quick check before tomorrow. Is the launch checklist actually ready?"),
            ChatMockMessage(role: .incoming, name: "Sam", text: "I want to send the beta invite first thing in the morning, but only if we're a clean go."),
            ChatMockMessage(role: .outgoing, name: "You", text: "Let me confirm the last couple items."),
            ChatMockMessage(role: .incoming, name: "Sam", text: "Cool. Mostly I just need a go / no-go, plus any remaining blocker."),
        ]
    }
}

/// Local state shared between the SwiftUI view and the AppKit window. Owned
/// by the controller so the window's keyDown can mutate state that the view
/// reads.
final class OnboardingDemoState: ObservableObject {
    enum Phase {
        case awaitingHotkey
        case showingSuggestions
        case pasted(index: Int)
    }

    @Published var phase: Phase = .awaitingHotkey
}

private struct ChatMockBubble: View {
    let message: ChatMockMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .outgoing { Spacer(minLength: 60) }
            VStack(alignment: message.role == .outgoing ? .trailing : .leading, spacing: 2) {
                if let name = message.name, message.role == .incoming {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundColor(message.role == .outgoing ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(message.role == .outgoing
                                  ? Color.accentColor
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.role == .incoming { Spacer(minLength: 60) }
        }
    }
}

private struct SuggestionRow: View {
    let index: Int
    let text: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingChatMockView: View {
    let fixture: OnboardingFixture
    let hotkeyDisplay: String
    let title: String
    @ObservedObject var state: OnboardingDemoState
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            chatScroll
            Divider()
            footerArea
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay(
                    Text("S")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("active now")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var chatScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fixture.messages) { message in
                    ChatMockBubble(message: message)
                }
                if case .pasted(let index) = state.phase {
                    pastedReply(index: index)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func pastedReply(index: Int) -> some View {
        let suggestion = fixture.suggestions.indices.contains(index)
            ? fixture.suggestions[index]
            : ""
        ChatMockBubble(message: ChatMockMessage(
            role: .outgoing,
            name: "You",
            text: suggestion
        ))
        .transition(.opacity)
    }

    @ViewBuilder
    private var footerArea: some View {
        switch state.phase {
        case .awaitingHotkey:
            hotkeyHint
        case .showingSuggestions:
            suggestionsPanel
        case .pasted:
            pastedHint
        }
    }

    private var hotkeyHint: some View {
        HStack(spacing: 6) {
            Text("Press")
                .foregroundColor(.secondary)
            Text(hotkeyDisplay)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
            Text("to summarize · Esc to close")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 12))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("tl;dr")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Text(fixture.tldr)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )

            VStack(spacing: 5) {
                ForEach(Array(fixture.suggestions.prefix(3).enumerated()), id: \.offset) { idx, text in
                    SuggestionRow(index: idx + 1, text: text) {
                        onSelect(idx)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("Press")
                Text("1").bold().foregroundColor(.primary)
                Text("/")
                Text("2").bold().foregroundColor(.primary)
                Text("/")
                Text("3").bold().foregroundColor(.primary)
                Text("to insert · Esc to close")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pastedHint: some View {
        HStack(spacing: 6) {
            Text("Reply inserted. Esc to close.")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 12))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private final class OnboardingChatMockWindow: NSWindow {
    var onEsc: (() -> Void)?
    var onHotkey: (() -> Void)?
    var onChoice: ((Int) -> Void)?
    var shouldConsumeChoiceKeys: (() -> Bool)?
    var hotkey: Hotkey?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc always closes.
        if event.keyCode == CGKeyCode(kVK_Escape) {
            onEsc?()
            return
        }
        // The configured summary hotkey reveals the suggestions panel.
        if let hotkey, Self.matches(event: event, hotkey: hotkey) {
            onHotkey?()
            return
        }
        // 1 / 2 / 3 (no modifiers) selects a suggestion, but only while the
        // suggestions panel is showing — otherwise let the event fall
        // through so the OS makes its usual beep.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, shouldConsumeChoiceKeys?() == true {
            switch Int(event.keyCode) {
            case kVK_ANSI_1: onChoice?(0); return
            case kVK_ANSI_2: onChoice?(1); return
            case kVK_ANSI_3: onChoice?(2); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    private static func matches(event: NSEvent, hotkey: Hotkey) -> Bool {
        guard CGKeyCode(event.keyCode) == hotkey.keyCode else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var flags: CGEventFlags = []
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        // `.function` is set automatically for function-class keys (arrows,
        // F-keys, page nav). Only treat it as Fn when the hotkey actually
        // requires it, otherwise e.g. ⌃⌥→ would never match.
        if hotkey.flags.contains(.maskSecondaryFn), mods.contains(.function) {
            flags.insert(.maskSecondaryFn)
        }
        return flags == hotkey.flags
    }
}

/// Self-contained onboarding sample. The window owns its own key handling
/// (no global hotkey tap), renders deterministic tldr + suggestions from the
/// bundled fixture, and never reaches into screen capture, accessibility, or
/// the model. As a result, it works before any TCC permission is granted.
final class OnboardingChatMockWindowController: NSObject, NSWindowDelegate {
    private let fixture: OnboardingFixture
    private let hotkey: Hotkey
    private let hotkeyDisplay: String
    private let onClose: () -> Void
    private var window: OnboardingChatMockWindow?
    private var state = OnboardingDemoState()
    private var didFireClose = false

    init(
        fixture: OnboardingFixture,
        hotkey: Hotkey,
        hotkeyDisplay: String,
        onClose: @escaping () -> Void
    ) {
        self.fixture = fixture
        self.hotkey = hotkey
        self.hotkeyDisplay = hotkeyDisplay
        self.onClose = onClose
        super.init()
    }

    func show() {
        // Re-create on each show so phase state is fresh; older controllers
        // that lingered with .pasted leftovers would confuse repeat visits.
        state = OnboardingDemoState()

        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 560)
        let win = OnboardingChatMockWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Messages — Sam"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.hotkey = hotkey
        win.onEsc = { [weak self] in self?.close() }
        win.onHotkey = { [weak self] in self?.revealSuggestions() }
        win.onChoice = { [weak self] idx in self?.choose(index: idx) }
        win.shouldConsumeChoiceKeys = { [weak self] in
            guard let self else { return false }
            if case .showingSuggestions = self.state.phase { return true }
            return false
        }

        let host = NSHostingView(rootView: OnboardingChatMockView(
            fixture: fixture,
            hotkeyDisplay: hotkeyDisplay,
            title: "Sam",
            state: state,
            onSelect: { [weak self] idx in self?.choose(index: idx) }
        ))
        // Use autoresizing rather than auto-layout so the SwiftUI tree's
        // intrinsic content size (which grows when the suggestions panel
        // reveals) doesn't drag the window taller.
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: contentRect.size)
        host.autoresizingMask = [.width, .height]
        win.contentView = host

        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    private func revealSuggestions() {
        // If we've already inserted a reply, the hotkey is a no-op until Esc.
        if case .pasted = state.phase { return }
        state.phase = .showingSuggestions
    }

    private func choose(index: Int) {
        // Only consume number keys while the suggestions panel is visible.
        guard case .showingSuggestions = state.phase else { return }
        guard fixture.suggestions.indices.contains(index) else { return }
        state.phase = .pasted(index: index)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFireClose else { return }
        didFireClose = true
        onClose()
    }
}
