import AppKit
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
            tldr: "tl;dr Sam is asking whether the launch checklist is ready before tomorrow's beta invite. They mostly need a concise go/no-go and any remaining blocker.",
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

private struct OnboardingChatMockView: View {
    let messages: [ChatMockMessage]
    let hotkeyDisplay: String
    let title: String

    var body: some View {
        VStack(spacing: 0) {
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
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        ChatMockBubble(message: message)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
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
    }
}

private final class OnboardingChatMockWindow: NSWindow {
    var onEsc: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEsc?()
            return
        }
        super.keyDown(with: event)
    }
}

final class OnboardingChatMockWindowController: NSObject, NSWindowDelegate {
    private let messages: [ChatMockMessage]
    private let hotkeyDisplay: String
    private let onClose: () -> Void
    private var window: OnboardingChatMockWindow?
    private var didFireClose = false

    init(messages: [ChatMockMessage], hotkeyDisplay: String, onClose: @escaping () -> Void) {
        self.messages = messages
        self.hotkeyDisplay = hotkeyDisplay
        self.onClose = onClose
        super.init()
    }

    func show() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 520)
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
        win.onEsc = { [weak self] in self?.close() }

        let host = NSHostingView(rootView: OnboardingChatMockView(
            messages: messages,
            hotkeyDisplay: hotkeyDisplay,
            title: "Sam"
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = host

        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFireClose else { return }
        didFireClose = true
        onClose()
    }
}
