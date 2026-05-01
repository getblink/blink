import AppKit
import Foundation

public final class PasteboardSnapshotWriter {
    private let outDir: URL
    private let fileManager: FileManager

    public init(outDir: URL, fileManager: FileManager = .default) {
        self.outDir = outDir.standardizedFileURL
        self.fileManager = fileManager
    }

    public func writeSnapshot(from pasteboard: NSPasteboard = .general) throws -> SnapshotSummary {
        let observedAtDate = Date()
        let observedAt = eventTimestamp(date: observedAtDate)
        let changeCount = pasteboard.changeCount
        let id = "\(filenameTimestamp(date: observedAtDate))-cc\(changeCount)"
        let snapshotsDir = outDir.appendingPathComponent("snapshots", isDirectory: true)
        let snapshotDir = snapshotsDir.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let htmlType = NSPasteboard.PasteboardType(rawValue: "public.html")
        let plainType = NSPasteboard.PasteboardType(rawValue: "public.utf8-plain-text")
        let sourceURLType = NSPasteboard.PasteboardType(rawValue: "org.chromium.source-url")
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let items = pasteboard.pasteboardItems ?? []
        let htmlData = pasteboard.data(forType: htmlType)
        let html = htmlData.flatMap(decodeText)
        let plainText = pasteboard.data(forType: plainType).flatMap(decodeText)
        let sourceURL = pasteboard.data(forType: sourceURLType).flatMap(decodeText) ?? ""
        let htmlContainsEmbeddedImage = html?.range(of: "data:image/", options: .caseInsensitive) != nil

        if let html {
            try html.write(to: snapshotDir.appendingPathComponent("clipboard.html"), atomically: true, encoding: .utf8)
            try html.write(to: snapshotDir.appendingPathComponent("html-source.txt"), atomically: true, encoding: .utf8)
        }
        if let plainText {
            try plainText.write(to: snapshotDir.appendingPathComponent("plain-text.txt"), atomically: true, encoding: .utf8)
        }

        var dumpedRows: [String] = []
        var primaryImagePath: String?
        var hasConcealedItem = false

        for (itemIndex, item) in items.enumerated() {
            let typeNames = item.types.map(\.rawValue)
            if isConcealed(typeNames: typeNames) {
                hasConcealedItem = true
                dumpedRows.append("<tr><td>\(itemIndex)</td><td><code>concealed</code></td><td></td><td>skipped</td><td>skipped</td></tr>")
                continue
            }

            let itemDir = snapshotDir
                .appendingPathComponent("items", isDirectory: true)
                .appendingPathComponent("item-\(itemIndex)", isDirectory: true)
            try fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)

            for (typeIndex, type) in item.types.enumerated() {
                let typeName = type.rawValue
                guard let data = item.data(forType: type) else {
                    dumpedRows.append("<tr><td>\(itemIndex)</td><td><code>\(escapeHTML(typeName))</code></td><td>unavailable</td><td></td><td></td></tr>")
                    continue
                }

                let basename = "\(String(format: "%02d", typeIndex))-\(safeFilename(typeName))"
                let rawFile = itemDir.appendingPathComponent("\(basename).raw.\(fileExtension(for: typeName))")
                try data.write(to: rawFile, options: .atomic)

                let rawRelPath = relativePath(from: snapshotDir, to: rawFile)
                if primaryImagePath == nil, isImageType(typeName) {
                    primaryImagePath = rawRelPath
                }

                var decodedLink = "<span class=\"muted\">none</span>"
                if isTextLikeType(typeName), let decodedText = decodeText(data) {
                    let decodedFile = itemDir.appendingPathComponent("\(basename).decoded.txt")
                    try decodedText.write(to: decodedFile, atomically: true, encoding: .utf8)
                    let decodedRelPath = relativePath(from: snapshotDir, to: decodedFile)
                    decodedLink = "<a href=\"\(escapeHTML(decodedRelPath))\">\(escapeHTML(decodedRelPath))</a>"
                }

                dumpedRows.append("<tr><td>\(itemIndex)</td><td><code>\(escapeHTML(typeName))</code></td><td><code>\(data.count)</code></td><td><a href=\"\(escapeHTML(rawRelPath))\">\(escapeHTML(rawRelPath))</a></td><td>\(decodedLink)</td></tr>")
            }
        }

        let renderedKind: String
        let renderSection: String
        if html != nil {
            renderedKind = "html"
            renderSection = "<iframe src=\"clipboard.html\" title=\"Rendered clipboard HTML\"></iframe>"
        } else if let primaryImagePath {
            renderedKind = "image"
            renderSection = "<div class=\"imageWrap\"><img src=\"\(escapeHTML(primaryImagePath))\" alt=\"Rendered clipboard image\"></div>"
        } else if plainText != nil {
            renderedKind = "plain-text"
            renderSection = "<iframe src=\"plain-text.txt\" title=\"Plain text clipboard payload\"></iframe>"
        } else if hasConcealedItem {
            renderedKind = "concealed"
            renderSection = "<div class=\"empty\">Concealed clipboard content was present. Payload dumping and rendering were skipped.</div>"
        } else {
            renderedKind = "none"
            renderSection = "<div class=\"empty\">No renderable <code>public.html</code>, image, or plain text payload was present.</div>"
        }

        let sourceURLHTML = sourceURL.isEmpty
            ? "<span class=\"muted\">none</span>"
            : "<a href=\"\(escapeHTML(sourceURL))\">\(escapeHTML(sourceURL))</a>"
        let htmlSourceSection = html == nil
            ? "<div class=\"empty\">No HTML source file was written.</div>"
            : "<iframe src=\"html-source.txt\" title=\"Raw clipboard HTML source\"></iframe>"
        let plainTextSection = plainText == nil
            ? "<div class=\"empty\">No <code>public.utf8-plain-text</code> payload was present.</div>"
            : "<iframe src=\"plain-text.txt\" title=\"Plain text clipboard payload\"></iframe>"
        let typeList = types.map { "<li><code>\(escapeHTML($0))</code></li>" }.joined(separator: "\n")

        let summary = SnapshotSummary(
            id: id,
            observedAt: observedAt,
            changeCount: changeCount,
            renderedKind: renderedKind,
            itemCount: items.count,
            htmlBytes: htmlData?.count ?? 0,
            plainTextBytes: plainText?.utf8.count ?? 0,
            types: types,
            sourceURL: sourceURL,
            hasEmbeddedImage: htmlContainsEmbeddedImage,
            isConcealed: hasConcealedItem,
            preview: oneLinePreview(plainText ?? sourceURL, limit: 220)
        )

        try renderSnapshotPage(
            snapshotDir: snapshotDir,
            summary: summary,
            sourceURLHTML: sourceURLHTML,
            renderSection: renderSection,
            htmlSourceSection: htmlSourceSection,
            plainTextSection: plainTextSection,
            dumpedFileRows: dumpedRows.joined(separator: "\n"),
            typeList: typeList
        )

        return summary
    }

    private func renderSnapshotPage(
        snapshotDir: URL,
        summary: SnapshotSummary,
        sourceURLHTML: String,
        renderSection: String,
        htmlSourceSection: String,
        plainTextSection: String,
        dumpedFileRows: String,
        typeList: String
    ) throws {
        let page = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Pasteboard Snapshot \(summary.changeCount)</title>
          <style>
            :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: Canvas; color: CanvasText; }
            body { margin: 0; }
            header { border-bottom: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 16px 20px 14px; }
            h1 { font-size: 18px; line-height: 1.2; margin: 0 0 10px; }
            .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 8px 16px; font-size: 13px; }
            code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; }
            .muted { color: color-mix(in srgb, CanvasText 60%, transparent); }
            .tabs { display: flex; gap: 8px; padding: 12px 20px; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); flex-wrap: wrap; }
            button { border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); background: color-mix(in srgb, Canvas 92%, CanvasText); color: CanvasText; border-radius: 6px; padding: 7px 10px; cursor: pointer; }
            button[aria-pressed="true"] { background: Highlight; color: HighlightText; border-color: Highlight; }
            main { height: calc(100vh - 154px); }
            section { display: none; height: 100%; }
            section.active { display: block; }
            iframe { width: 100%; height: 100%; border: 0; background: white; }
            .imageWrap { box-sizing: border-box; height: 100%; padding: 18px 20px; overflow: auto; background: color-mix(in srgb, Canvas 96%, CanvasText); }
            .imageWrap img { max-width: 100%; height: auto; display: block; }
            .types { padding: 18px 20px; overflow: auto; box-sizing: border-box; height: 100%; }
            li { margin: 6px 0; }
            .warn { color: #b45309; font-weight: 600; }
            .empty { padding: 18px 20px; color: color-mix(in srgb, CanvasText 65%, transparent); }
            table { border-collapse: collapse; width: 100%; font-size: 13px; }
            th, td { border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding: 8px 10px; text-align: left; vertical-align: top; }
          </style>
        </head>
        <body>
          <header>
            <h1>Pasteboard Snapshot</h1>
            <div class="meta">
              <div><strong>observedAt</strong>: <code>\(summary.observedAt)</code></div>
              <div><strong>changeCount</strong>: <code>\(summary.changeCount)</code></div>
              <div><strong>rendered</strong>: <code>\(summary.renderedKind)</code></div>
              <div><strong>HTML bytes</strong>: <code>\(summary.htmlBytes)</code></div>
              <div><strong>Plain text bytes</strong>: <code>\(summary.plainTextBytes)</code></div>
              <div><strong>Embedded image data</strong>: <span class="\(summary.hasEmbeddedImage ? "warn" : "muted")">\(summary.hasEmbeddedImage ? "yes" : "not detected")</span></div>
              <div><strong>Snapshot folder</strong>: <code>\(escapeHTML(relativePath(from: outDir, to: snapshotDir)))</code></div>
              <div style="grid-column: 1 / -1;"><strong>Source URL</strong>: \(sourceURLHTML)</div>
            </div>
          </header>
          <nav class="tabs" aria-label="Preview tabs">
            <button type="button" data-tab="render" aria-pressed="true">Rendered</button>
            <button type="button" data-tab="html" aria-pressed="false">HTML Source</button>
            <button type="button" data-tab="text" aria-pressed="false">Plain Text</button>
            <button type="button" data-tab="files" aria-pressed="false">Dumped Files</button>
            <button type="button" data-tab="types" aria-pressed="false">Pasteboard Types</button>
          </nav>
          <main>
            <section id="render" class="active">\(renderSection)</section>
            <section id="html">\(htmlSourceSection)</section>
            <section id="text">\(plainTextSection)</section>
            <section id="files"><div class="types"><table><thead><tr><th>Item</th><th>Type</th><th>Bytes</th><th>Raw File</th><th>Decoded File</th></tr></thead><tbody>\(dumpedFileRows)</tbody></table></div></section>
            <section id="types"><div class="types"><ul>\(typeList)</ul></div></section>
          </main>
          <script>
            for (const button of document.querySelectorAll("[data-tab]")) {
              button.addEventListener("click", () => {
                for (const other of document.querySelectorAll("[data-tab]")) other.setAttribute("aria-pressed", String(other === button));
                for (const section of document.querySelectorAll("main section")) section.classList.toggle("active", section.id === button.dataset.tab);
              });
            }
          </script>
        </body>
        </html>
        """

        try page.write(to: snapshotDir.appendingPathComponent("snapshot.html"), atomically: true, encoding: .utf8)
    }
}

func filenameTimestamp(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter.string(from: date)
}

func eventTimestamp(date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

func decodeText(_ data: Data) -> String? {
    String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
        ?? String(data: data, encoding: .utf16LittleEndian)
        ?? String(data: data, encoding: .utf16BigEndian)
}

func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func safeFilename(_ value: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    let mapped = value.map { allowed.contains($0) ? String($0) : "-" }.joined()
    let collapsed = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func fileExtension(for typeName: String) -> String {
    if typeName == "public.html" { return "html" }
    if typeName == "public.png" { return "png" }
    if typeName == "public.jpeg" || typeName == "public.jpg" { return "jpg" }
    if typeName == "public.tiff" { return "tiff" }
    return "bin"
}

func isTextLikeType(_ typeName: String) -> Bool {
    typeName == "public.utf8-plain-text"
        || typeName == "public.utf16-external-plain-text"
        || typeName == "public.text"
        || typeName == "public.html"
        || typeName == "public.url"
        || typeName == "public.file-url"
        || typeName == "org.chromium.source-url"
        || typeName == "NSStringPboardType"
}

func isConcealed(typeNames: [String]) -> Bool {
    typeNames.contains { rawType in
        let type = rawType.lowercased()
        return type == "org.nspasteboard.concealedtype"
            || type.contains("concealed")
            || type.contains("password")
            || type.contains("passwd")
            || type.contains("secret")
            || type.contains("credential")
            || type.contains("keychain")
    }
}
