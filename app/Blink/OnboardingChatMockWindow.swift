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

private struct SlackMessageRow: View {
    let message: ChatMockMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.name ?? "Someone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("9:42 AM")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        let name = message.name ?? "?"
        let initial = String(name.prefix(1)).uppercased()
        let palette: [Color] = [
            Color(red: 0.36, green: 0.45, blue: 0.85),
            Color(red: 0.78, green: 0.38, blue: 0.55),
            Color(red: 0.30, green: 0.62, blue: 0.48),
        ]
        let color = palette[abs(name.hashValue) % palette.count]
        return Text(initial)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
            )
    }
}

private struct OnboardingChatMockView: View {
    let fixture: OnboardingFixture
    let channelName: String
    let hotkeyDisplay: String

    var body: some View {
        VStack(spacing: 0) {
            channelHeader
            Divider()
            messageList
            hotkeyHint
        }
    }

    private var hotkeyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("Press")
                .foregroundColor(.secondary)
            Text(hotkeyDisplay)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            Text("to ask Blink for a reply")
                .foregroundColor(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var channelHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Text(channelName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(fixture.messages) { message in
                    SlackMessageRow(message: message)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// AppKit reply composer. SwiftUI's `TextField` doesn't reliably regain
/// first-responder status after the suggestions overlay grabs key status,
/// which means the Inserter's synthesized Cmd+V lands on a non-editable
/// view and beeps. An honest `NSTextField` (with explicit
/// `makeFirstResponder` from the window delegate) is deterministic.
private final class ReplyComposerView: NSView {
    let textField = NSTextField()

    init(channelName: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholderString = "Reply to #\(channelName)"
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = false
        textField.cell?.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 5

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// NSWindow that closes on Esc. The mock window's footer copy promises
/// "press Esc when you're done", so the window itself needs to honor that
/// even though we no longer intercept arbitrary keys.
private final class EscClosingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Onboarding demo surface. Renders a Slack-style channel from the bundled
/// fixture and serves as a real capture target for the live Blink pipeline
/// — the suggestions overlay, hotkey listening, and paste path all come
/// from the actual coordinator. Owns no key handling of its own beyond Esc.
final class OnboardingChatMockWindowController: NSObject, NSWindowDelegate {
    private let fixture: OnboardingFixture
    private let channelName: String
    private let hotkeyDisplay: String
    private let onClose: () -> Void
    private var window: NSWindow?
    private var replyComposer: ReplyComposerView?
    private var didFireClose = false

    init(
        fixture: OnboardingFixture,
        channelName: String = "launch-readiness",
        hotkeyDisplay: String,
        onClose: @escaping () -> Void
    ) {
        self.fixture = fixture
        self.channelName = channelName
        self.hotkeyDisplay = hotkeyDisplay
        self.onClose = onClose
        super.init()
    }

    func show() {
        // Re-shows reuse the existing window so a re-entry into the demo
        // flow doesn't leak the previous one (this controller is held by
        // AppDelegate across the session).
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        didFireClose = false

        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 560)
        let win = EscClosingWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "#\(channelName)"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self

        let chat = NSHostingView(rootView: OnboardingChatMockView(
            fixture: fixture,
            channelName: channelName,
            hotkeyDisplay: hotkeyDisplay
        ))
        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.setContentHuggingPriority(.defaultLow, for: .vertical)
        chat.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let composer = ReplyComposerView(channelName: channelName)
        composer.setContentHuggingPriority(.defaultHigh, for: .vertical)
        composer.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        replyComposer = composer

        let stack = NSStackView(views: [chat, composer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            composer.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        win.contentView = container

        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(composer.textField)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// Used by the host to re-front the mock right before firing a real
    /// summarize, so the screenshot targets this window (not whatever was
    /// frontmost from the System Settings detour during permission grants).
    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFireClose else { return }
        didFireClose = true
        onClose()
    }

    /// Re-claim first-responder status for the reply composer every time the
    /// window regains key status. The suggestions overlay grabs key while
    /// the user is on 1/2/3, which drops the composer's responder slot —
    /// without this hook, the Inserter's synthesized Cmd+V hits a
    /// non-editable view and beeps.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, let composer = replyComposer else { return }
        if window.firstResponder !== composer.textField {
            window.makeFirstResponder(composer.textField)
        }
    }
}
