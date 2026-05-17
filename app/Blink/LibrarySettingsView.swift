import AppKit
import SwiftUI

/// Settings pane for the staged attachment library. Lets the user review,
/// rename, describe, relink, and remove entries.
struct LibrarySettingsView: View {
    @ObservedObject var library: AttachmentLibrary

    @State private var selectedID: String?
    @State private var editingNameID: String?
    @State private var editingDescriptionID: String?
    @State private var relinkTarget: AttachmentEntry?
    @State private var showingRelinkPanel = false
    @State private var statusByID: [String: AttachmentFileStatus] = [:]

    private var proxyConfig: ProxyConfig? { RuntimeEnvironment.proxyConfig() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if library.entries.isEmpty {
                emptyState
            } else {
                entryTable
            }
        }
        .task {
            await refreshStatuses()
        }
        .onChange(of: library.entries) { _ in
            Task { await refreshStatuses() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paperclip")
                .font(.system(size: 48))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            Text("No staged attachments")
                .font(.title3)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Text("Drag headshots, rate cards, and media kits into the Blink window to stage them. Blink will attach them automatically when relevant.")
                .font(.callout)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Entry table

    private var entryTable: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.entries) { entry in
                        EntryRow(
                            entry: entry,
                            fileStatus: statusByID[entry.id],
                            isUnavailable: library.unavailableIDs.contains(entry.id),
                            thumbnail: library.thumbnail(for: entry.id),
                            onRename: { newName in library.updateDisplayName(id: entry.id, name: newName) },
                            onDescriptionEdited: { newDesc in library.updateDescription(id: entry.id, description: newDesc, status: .ready) },
                            onShowInFinder: { showInFinder(entry: entry) },
                            onRemove: { library.removeEntry(id: entry.id) },
                            onRelink: { relinkTarget = entry; showRelinkPanel() },
                            onRegenerateDescription: {
                                guard let cfg = proxyConfig else { return }
                                library.retryDescription(entryID: entry.id, proxyConfig: cfg)
                            }
                        )
                        Divider()
                    }
                }
            }
            Spacer()
            footerHint
        }
    }

    private var footerHint: some View {
        Text("Files stay on your Mac. Blink attaches them when the email calls for it.")
            .font(.caption)
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func refreshStatuses() async {
        for entry in library.entries {
            let status = await library.resolveURL(for: entry)
            await MainActor.run { statusByID[entry.id] = status }
        }
    }

    private func showInFinder(entry: AttachmentEntry) {
        guard let url = library.resolveURLSync(for: entry) else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func showRelinkPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let entry = relinkTarget {
            panel.nameFieldStringValue = entry.displayName
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url, let id = relinkTarget?.id else { return }
            try? library.relinkEntry(id: id, newURL: url)
            relinkTarget = nil
        }
    }
}

// MARK: - Entry row

private struct EntryRow: View {
    let entry: AttachmentEntry
    let fileStatus: AttachmentFileStatus?
    let isUnavailable: Bool
    let thumbnail: NSImage?
    let onRename: (String) -> Void
    let onDescriptionEdited: (String) -> Void
    let onShowInFinder: () -> Void
    let onRemove: () -> Void
    let onRelink: () -> Void
    let onRegenerateDescription: () -> Void

    @State private var editingName: String = ""
    @State private var editingDescription: String = ""
    @State private var isNameEditing = false
    @State private var isDescEditing = false

    var isMissing: Bool {
        if case .missing = fileStatus { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnailView
            infoColumn
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            editingName = entry.displayName
            editingDescription = entry.description
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFileType: URL(fileURLWithPath: entry.displayName).pathExtension))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            }
        }
        .opacity(isUnavailable || isMissing ? 0.5 : 1.0)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Editable name
            if isNameEditing {
                TextField("Name", text: $editingName, onCommit: {
                    onRename(editingName)
                    isNameEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
            } else {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isUnavailable ? .secondary : .primary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { isNameEditing = true }
            }

            // Status badge
            HStack(spacing: 4) {
                statusBadge
                if isMissing {
                    Text("File missing")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if isUnavailable {
                    Text("Volume not mounted")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text(fileSizeString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Editable description
            if isDescEditing {
                TextField("Description", text: $editingDescription, onCommit: {
                    onDescriptionEdited(editingDescription)
                    isDescEditing = false
                })
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Text(entry.description.isEmpty ? (entry.descriptionStatus == .pending ? "Generating description…" : "No description") : entry.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .onTapGesture(count: 2) {
                        editingDescription = entry.description
                        isDescEditing = true
                    }
            }
        }
    }

    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        if isMissing { return .orange }
        if isUnavailable { return .secondary }
        switch entry.descriptionStatus {
        case .ready: return .green
        case .pending: return .yellow
        case .failed: return .orange
        }
    }

    private var fileSizeString: String {
        let bytes = entry.byteSize
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if isMissing {
                Button("Relink…", action: onRelink)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else if !isUnavailable {
                Button(action: onShowInFinder) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .opacity(0.7)
            }
            Button(action: onRegenerateDescription) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Regenerate description")
            .opacity(0.7)
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from library")
            .opacity(0.7)
        }
    }
}
