import AppKit
import Combine
import Foundation
import PDFKit

// MARK: - Model types

enum AttachmentKind: String, Codable, Sendable {
    case image, pdf, text, other

    /// Extensions whose contents can be read as UTF-8 and inlined into the
    /// prompt so the model writes them into the suggestion text directly
    /// (no separate clipboard file). Anything outside this list and the
    /// image/pdf sets falls through to `.other` and is treated as opaque.
    static let textExts: Set<String> = [
        "md", "markdown", "txt", "html", "htm",
        "csv", "tsv", "json", "log", "yaml", "yml", "toml",
        "py", "js", "jsx", "ts", "tsx", "swift", "go", "rs",
        "java", "c", "cpp", "h", "hpp", "sh", "bash", "zsh",
        "rb", "php", "css", "scss", "less", "xml", "ini",
    ]

    static func detect(for url: URL) -> AttachmentKind {
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg"]
        if imageExts.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if textExts.contains(ext) { return .text }
        return .other
    }
}

enum DescriptionStatus: String, Codable, Sendable {
    case pending, ready, failed
}

struct AttachmentEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var description: String
    var kind: AttachmentKind
    var bookmarkData: Data
    var byteSize: Int64
    var addedAt: String
    var descriptionStatus: DescriptionStatus
    /// Inlined file content for `.text` entries (UTF-8, capped). nil for all other kinds.
    var body: String?

    enum CodingKeys: String, CodingKey {
        case id, displayName, description, kind
        case bookmarkData = "bookmark"
        case byteSize, addedAt, descriptionStatus, body
    }
}

struct AttachmentAddResult {
    let entry: AttachmentEntry
    let largeSizeWarning: Bool
}

enum AttachmentError: LocalizedError {
    case fileTooLarge(byteSize: Int64)
    case bookmarkCreationFailed
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            let mb = size / (1024 * 1024)
            return "File is \(mb) MB, which exceeds the 100 MB limit."
        case .bookmarkCreationFailed:
            return "Could not create a persistent reference to this file."
        case .fileNotFound:
            return "File not found."
        }
    }
}

enum AttachmentFileStatus: Sendable {
    case available(URL)
    /// File deleted — show "Relink…"
    case missing
    /// Transient (volume not mounted) — mark unavailable, not Relink
    case unavailable
}

// MARK: - Storage paths (nonisolated — safe to call from any actor)

enum AttachmentPaths {
    static var attachmentsDir: URL {
        let dir = Paths.appSupportDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var thumbsDir: URL {
        let dir = attachmentsDir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var indexPath: URL {
        attachmentsDir.appendingPathComponent("index.json")
    }

    static func thumbPath(id: String) -> URL {
        thumbsDir.appendingPathComponent("\(id).png")
    }
}

// MARK: - Library

@MainActor
final class AttachmentLibrary: ObservableObject {
    static let shared = AttachmentLibrary()

    @Published private(set) var entries: [AttachmentEntry] = []
    @Published private(set) var unavailableIDs: Set<String> = []

    private var staleRefreshedIDs: Set<String> = []
    private var volumeMountObserver: NSObjectProtocol?
    private var descriptionTasks: [String: Task<Void, Never>] = [:]

    private static let softWarnBytes: Int64 = 25 * 1024 * 1024
    private static let hardRejectBytes: Int64 = 100 * 1024 * 1024

    private init() {
        load()
        registerVolumeNotifications()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: AttachmentPaths.indexPath),
              let loaded = try? decoder.decode([AttachmentEntry].self, from: data) else {
            return
        }
        entries = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: AttachmentPaths.indexPath, options: .atomic)
    }

    // MARK: - Adding files

    func addFile(at url: URL) throws -> AttachmentAddResult {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attrs[.size] as? Int64) ?? 0

        if byteSize > Self.hardRejectBytes {
            throw AttachmentError.fileTooLarge(byteSize: byteSize)
        }

        guard let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            throw AttachmentError.bookmarkCreationFailed
        }

        let id = Self.makeID(from: url)
        let kind = AttachmentKind.detect(for: url)
        // Local-describe for text and opaque-binary at add time; image/pdf go
        // out to the server's /v1/describe-file and stay pending until then.
        var initialBody: String? = nil
        var initialDescription = ""
        var initialStatus: DescriptionStatus = .pending
        switch kind {
        case .text:
            initialBody = AttachmentHelpers.readTextBody(at: url)
            initialDescription = AttachmentHelpers.localDescribeText(body: initialBody)
            initialStatus = .ready
        case .other:
            initialDescription = AttachmentHelpers.localDescribeOpaque(displayName: url.lastPathComponent, byteSize: byteSize)
            initialStatus = .ready
        case .image, .pdf:
            break
        }
        let entry = AttachmentEntry(
            id: id,
            displayName: url.lastPathComponent,
            description: initialDescription,
            kind: kind,
            bookmarkData: bookmarkData,
            byteSize: byteSize,
            addedAt: JSONFiles.isoString(),
            descriptionStatus: initialStatus,
            body: initialBody
        )

        entries.append(entry)
        save()

        // Thumbnail on background thread — static + nonisolated so safe in detached task
        let capturedURL = url
        let capturedID = id
        let capturedKind = kind
        Task.detached(priority: .background) {
            await AttachmentHelpers.generateThumbnail(for: capturedURL, id: capturedID, kind: capturedKind)
        }

        return AttachmentAddResult(
            entry: entry,
            largeSizeWarning: byteSize > Self.softWarnBytes
        )
    }

    // MARK: - Bookmark resolution

    func resolveURL(for entry: AttachmentEntry) async -> AttachmentFileStatus {
        let bookmarkData = entry.bookmarkData
        let entryID = entry.id
        return await Task.detached(priority: .userInitiated) {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return AttachmentFileStatus.missing
                }
                if isStale {
                    Task { @MainActor in
                        AttachmentLibrary.shared.scheduleStaleRefresh(entryID: entryID, resolvedURL: url)
                    }
                }
                return AttachmentFileStatus.available(url)
            } catch let error as NSError {
                if error.code == NSFileReadNoSuchFileError {
                    return AttachmentFileStatus.missing
                }
                return AttachmentFileStatus.unavailable
            }
        }.value
    }

    func resolveURLSync(for entry: AttachmentEntry) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        if isStale {
            let id = entry.id
            Task { scheduleStaleRefresh(entryID: id, resolvedURL: url) }
        }
        return url
    }

    func resolveURLs(for refs: [AttachmentRef], warnOnMissing: ((Int) -> Void)? = nil) -> [URL] {
        var urls: [URL] = []
        var missingCount = 0
        for ref in refs {
            guard let entry = entries.first(where: { $0.id == ref.id }),
                  let url = resolveURLSync(for: entry) else {
                missingCount += 1
                continue
            }
            urls.append(url)
        }
        if missingCount > 0 { warnOnMissing?(missingCount) }
        return urls
    }

    private func scheduleStaleRefresh(entryID: String, resolvedURL: URL) {
        Task {
            guard let fresh = try? resolvedURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return }
            guard let idx = self.entries.firstIndex(where: { $0.id == entryID }) else { return }
            self.entries[idx].bookmarkData = fresh
            self.save()
            self.staleRefreshedIDs.insert(entryID)
        }
    }

    // MARK: - Mutations

    func removeEntry(id: String) {
        entries.removeAll { $0.id == id }
        descriptionTasks[id]?.cancel()
        descriptionTasks.removeValue(forKey: id)
        save()
        try? FileManager.default.removeItem(at: AttachmentPaths.thumbPath(id: id))
    }

    func relinkEntry(id: String, newURL: URL) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard let bookmark = try? newURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            throw AttachmentError.bookmarkCreationFailed
        }
        entries[idx].bookmarkData = bookmark
        entries[idx].displayName = newURL.lastPathComponent
        unavailableIDs.remove(id)
        save()
    }

    func updateDisplayName(id: String, name: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].displayName = name
        save()
    }

    func updateDescription(id: String, description: String, status: DescriptionStatus) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].description = description
        entries[idx].descriptionStatus = status
        save()
    }

    func updateBodyAndDescription(id: String, body: String?, description: String, status: DescriptionStatus) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].body = body
        entries[idx].description = description
        entries[idx].descriptionStatus = status
        save()
    }

    // MARK: - Thumbnail access

    func thumbnail(for id: String) -> NSImage? {
        NSImage(contentsOf: AttachmentPaths.thumbPath(id: id))
    }

    // MARK: - Auto-description (Phase B)

    func scheduleDescription(entryID: String, proxyConfig: ProxyConfig) {
        descriptionTasks[entryID]?.cancel()
        let entry = entries.first(where: { $0.id == entryID })
        guard let entry, entry.descriptionStatus == .pending else { return }

        switch entry.kind {
        case .text:
            descriptionTasks[entryID] = Task {
                let fileStatus = await AttachmentLibrary.shared.resolveURL(for: entry)
                guard case .available(let url) = fileStatus else {
                    AttachmentLibrary.shared.updateDescription(id: entryID, description: "", status: .failed)
                    AttachmentLibrary.shared.descriptionTasks.removeValue(forKey: entryID)
                    return
                }
                let body = await Task.detached(priority: .background) {
                    AttachmentHelpers.readTextBody(at: url)
                }.value
                let desc = AttachmentHelpers.localDescribeText(body: body)
                AttachmentLibrary.shared.updateBodyAndDescription(id: entryID, body: body, description: desc, status: .ready)
                AttachmentLibrary.shared.descriptionTasks.removeValue(forKey: entryID)
            }
        case .other:
            let desc = AttachmentHelpers.localDescribeOpaque(displayName: entry.displayName, byteSize: entry.byteSize)
            updateDescription(id: entryID, description: desc, status: .ready)
        case .image, .pdf:
            descriptionTasks[entryID] = Task {
                let fileStatus = await AttachmentLibrary.shared.resolveURL(for: entry)
                guard case .available(let url) = fileStatus else {
                    AttachmentLibrary.shared.updateDescription(id: entryID, description: "", status: .failed)
                    AttachmentLibrary.shared.descriptionTasks.removeValue(forKey: entryID)
                    return
                }
                do {
                    let desc = try await AttachmentHelpers.callDescribeFile(
                        entry: entry, fileURL: url, proxyConfig: proxyConfig
                    )
                    AttachmentLibrary.shared.updateDescription(id: entryID, description: desc, status: .ready)
                } catch {
                    AttachmentLibrary.shared.updateDescription(id: entryID, description: "", status: .failed)
                }
                AttachmentLibrary.shared.descriptionTasks.removeValue(forKey: entryID)
            }
        }
    }

    func retryDescription(entryID: String, proxyConfig: ProxyConfig) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[idx].descriptionStatus = .pending
        save()
        scheduleDescription(entryID: entryID, proxyConfig: proxyConfig)
    }

    // MARK: - ID generation

    private static func makeID(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        var slug = name.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 40 { slug = String(slug.prefix(40)) }
        if slug.isEmpty { slug = "file" }
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(slug)-\(suffix)"
    }

    // MARK: - Volume notifications

    private func registerVolumeNotifications() {
        volumeMountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryUnavailableEntries() }
        }
    }

    private func retryUnavailableEntries() {
        let toRetry = entries.filter { unavailableIDs.contains($0.id) }
        for entry in toRetry {
            let entryID = entry.id
            Task {
                let status = await AttachmentLibrary.shared.resolveURL(for: entry)
                await MainActor.run {
                    switch status {
                    case .available:
                        AttachmentLibrary.shared.unavailableIDs.remove(entryID)
                    case .missing:
                        AttachmentLibrary.shared.unavailableIDs.remove(entryID)
                    case .unavailable:
                        break
                    }
                }
            }
        }
    }

    func refreshStatusForAllEntries() {
        for entry in entries {
            let entryID = entry.id
            Task {
                let status = await AttachmentLibrary.shared.resolveURL(for: entry)
                await MainActor.run {
                    switch status {
                    case .available:
                        AttachmentLibrary.shared.unavailableIDs.remove(entryID)
                    case .unavailable:
                        AttachmentLibrary.shared.unavailableIDs.insert(entryID)
                    case .missing:
                        AttachmentLibrary.shared.unavailableIDs.remove(entryID)
                    }
                }
            }
        }
    }
}

// MARK: - Catalog serialization (Phase C)

extension AttachmentEntry {
    var catalogItem: [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": description,
            "kind": kind.rawValue,
        ]
        if let body, !body.isEmpty {
            item["body"] = body
        }
        return item
    }
}

// MARK: - Helpers (nonisolated free functions — safe in Task.detached)

enum AttachmentHelpers {
    // MARK: Text body capture (Phase D)

    /// Max bytes of file content we inline into the prompt for `.text` entries.
    /// Keeps the prompt envelope small and bounds Gemini token cost regardless
    /// of source file size.
    static let textBodyCapBytes = 4 * 1024

    static func readTextBody(at url: URL) -> String? {
        // Bounded read so a 100 MB .json/.csv doesn't mmap into addFile just to
        // grab the first 4 KB.
        let totalSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            totalSize = size
        } else {
            totalSize = 0
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let capped: Data
        do {
            capped = try handle.read(upToCount: textBodyCapBytes) ?? Data()
        } catch {
            return nil
        }
        let truncated = totalSize > Int64(capped.count)
        guard var text = String(data: capped, encoding: .utf8) else { return nil }
        if truncated {
            // Trim to last newline so the marker doesn't dangle mid-line.
            if let lastNewline = text.lastIndex(of: "\n") {
                text = String(text[..<lastNewline])
            }
            text += "\n…[truncated, \(totalSize - Int64(capped.count)) more bytes]"
        }
        return text
    }

    static func localDescribeText(body: String?) -> String {
        let trimmed = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty text file" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let snippet = firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        return "Text: \(snippet)"
    }

    static func localDescribeOpaque(displayName: String, byteSize: Int64) -> String {
        let ext = (displayName as NSString).pathExtension.uppercased()
        let sizeText: String
        let mb = Double(byteSize) / (1024 * 1024)
        if mb >= 0.5 {
            sizeText = String(format: "%.1f MB", mb)
        } else {
            let kb = max(1.0, Double(byteSize) / 1024)
            sizeText = String(format: "%.0f KB", kb)
        }
        if ext.isEmpty {
            return "Binary file (\(sizeText))"
        }
        return "\(ext) file (\(sizeText))"
    }

    // MARK: Thumbnail

    static func generateThumbnail(for url: URL, id: String, kind: AttachmentKind) async {
        let thumbURL = AttachmentPaths.thumbPath(id: id)
        let maxDim: CGFloat = 60

        switch kind {
        case .image:
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(maxDim / size.width, maxDim / size.height)
            let thumbSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
            guard let ctx = CGContext(
                data: nil,
                width: Int(thumbSize.width),
                height: Int(thumbSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: thumbSize))
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: thumbSize))
            guard let thumb = ctx.makeImage() else { return }
            let bitmap = NSBitmapImageRep(cgImage: thumb)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: thumbURL, options: .atomic)

        case .pdf:
            guard let doc = PDFDocument(url: url),
                  let page = doc.page(at: 0) else { return }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(maxDim / bounds.width, maxDim / bounds.height)
            let thumbSize = CGSize(width: round(bounds.width * scale), height: round(bounds.height * scale))
            guard let ctx = CGContext(
                data: nil,
                width: Int(thumbSize.width),
                height: Int(thumbSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: thumbSize))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            page.draw(with: .mediaBox, to: ctx)
            guard let thumb = ctx.makeImage() else { return }
            let bitmap = NSBitmapImageRep(cgImage: thumb)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: thumbURL, options: .atomic)

        case .text, .other:
            // No thumbnail — pill falls back to the system file-type icon.
            break
        }
    }

    // MARK: Describe-file networking (Phase B)

    static func callDescribeFile(
        entry: AttachmentEntry,
        fileURL: URL,
        proxyConfig: ProxyConfig
    ) async throws -> String {
        let kind = entry.kind
        let displayName = entry.displayName

        let (fileData, mimeType): (Data, String) = try await Task.detached(priority: .background) {
            switch kind {
            case .image:
                return try downscaleImageForDescription(at: fileURL)
            case .pdf:
                let data = try Data(contentsOf: fileURL)
                return (data, "application/pdf")
            case .text, .other:
                // callDescribeFile is only invoked for image/pdf today;
                // text and other are described client-side. Bail loudly so a
                // future caller doesn't silently push the wrong kind to
                // Gemini.
                throw AttachmentError.fileNotFound
            }
        }.value

        let boundary = "blink-describe-\(UUID().uuidString.prefix(12).lowercased())"
        var body = Data()
        // Plain form field — must be the raw rawValue, NOT a JSON-encoded blob;
        // FastAPI's Form() sees the value as a literal string and matches it
        // against {"image", "pdf"}.
        let kindData = Data(kind.rawValue.utf8)
        appendPart(&body, boundary: boundary, name: "kind", data: kindData, mimeType: "text/plain")
        appendPart(&body, boundary: boundary, name: "file", data: fileData, mimeType: mimeType, filename: displayName)
        appendUTF8(&body, "--\(boundary)--\r\n")

        var req = URLRequest(url: proxyConfig.baseURL.appendingPathComponent("v1/describe-file"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(proxyConfig.token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30

        let (responseData, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let desc = payload["description"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return desc
    }

    // MARK: - Private helpers

    private static func downscaleImageForDescription(at url: URL) throws -> (Data, String) {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AttachmentError.fileNotFound
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let longEdge = max(size.width, size.height)
        let maxLongEdge: CGFloat = 1568
        guard longEdge > maxLongEdge else {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            return (data, mime)
        }

        let scale = maxLongEdge / longEdge
        let newSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        guard let ctx = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AttachmentError.bookmarkCreationFailed
        }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        guard let scaled = ctx.makeImage() else { throw AttachmentError.bookmarkCreationFailed }
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw AttachmentError.bookmarkCreationFailed
        }
        return (jpeg, "image/jpeg")
    }

    private static func appendPart(
        _ body: inout Data,
        boundary: String,
        name: String,
        data: Data,
        mimeType: String,
        filename: String? = nil
    ) {
        appendUTF8(&body, "--\(boundary)\r\n")
        if let filename {
            appendUTF8(&body, "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        } else {
            appendUTF8(&body, "Content-Disposition: form-data; name=\"\(name)\"\r\n")
        }
        appendUTF8(&body, "Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        appendUTF8(&body, "\r\n")
    }

    private static func appendUTF8(_ body: inout Data, _ string: String) {
        if let d = string.data(using: .utf8) { body.append(d) }
    }
}
