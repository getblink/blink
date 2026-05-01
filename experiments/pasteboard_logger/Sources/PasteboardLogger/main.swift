import AppKit
import Foundation

struct Config {
    var pollInterval: TimeInterval = 0.25
    var previewLength = 500
    var dumpCurrent = false
    var logFilePath: String?
}

struct AppSnapshot {
    var name: String
    var bundleID: String
    var pid: pid_t
    var path: String
}

final class OutputLog {
    let fileURL: URL
    private let fileHandle: FileHandle

    init(path: String?) {
        let resolvedPath = path ?? "logs/pasteboard-\(Self.filenameTimestamp()).log"
        let rawFileURL: URL
        if (resolvedPath as NSString).isAbsolutePath {
            rawFileURL = URL(fileURLWithPath: resolvedPath)
        } else {
            rawFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(resolvedPath)
        }
        fileURL = rawFileURL.standardizedFileURL

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            fputs("error: could not open log file \(fileURL.path): \(error)\n", stderr)
            exit(1)
        }
    }

    deinit {
        try? fileHandle.close()
    }

    func line(_ value: String = "") {
        print(value)
        if let data = "\(value)\n".data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    func flush() {
        fflush(stdout)
        fileHandle.synchronizeFile()
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct ClipboardLogger {
    private let pasteboard = NSPasteboard.general
    private let config: Config
    private let output: OutputLog
    private let previewTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-external-plain-text",
        "public.text",
        "public.html",
        "public.rtf",
        "public.utf8-tagged-file-url",
        "public.file-url",
        "public.url",
        "org.chromium.source-url",
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType.html.rawValue,
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.fileURL.rawValue,
        NSPasteboard.PasteboardType.URL.rawValue
    ]
    private let imageTypes: Set<String> = [
        "public.png",
        "public.tiff",
        "public.jpeg",
        "public.jpg",
        NSPasteboard.PasteboardType.png.rawValue,
        NSPasteboard.PasteboardType.tiff.rawValue
    ]

    init(config: Config, output: OutputLog) {
        self.config = config
        self.output = output
    }

    func run() {
        var lastChangeCount = pasteboard.changeCount
        output.line("Watching NSPasteboard.general (changeCount=\(lastChangeCount), interval=\(config.pollInterval)s)")
        output.line("Log file: \(output.fileURL.path)")
        output.line("Press Ctrl-C to stop.")
        output.line()
        output.flush()

        if config.dumpCurrent {
            logCurrentPasteboard(changeCount: lastChangeCount)
        }

        while true {
            Thread.sleep(forTimeInterval: config.pollInterval)
            let changeCount = pasteboard.changeCount
            guard changeCount != lastChangeCount else {
                continue
            }
            lastChangeCount = changeCount
            logCurrentPasteboard(changeCount: changeCount)
        }
    }

    private func logCurrentPasteboard(changeCount: Int) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sourceApp = frontmostAppSnapshot()
        let items = pasteboard.pasteboardItems ?? []

        output.line("=== Clipboard Event ===")
        output.line("timestamp: \(timestamp)")
        output.line("changeCount: \(changeCount)")
        output.line("frontmostAppAtDetection:")
        if let sourceApp {
            output.line("  name: \(sourceApp.name)")
            output.line("  bundleID: \(sourceApp.bundleID)")
            output.line("  pid: \(sourceApp.pid)")
            output.line("  path: \(sourceApp.path)")
        } else {
            output.line("  unavailable")
        }
        output.line("  note: best-effort copy source; NSPasteboard does not expose the writer app")
        output.line("items: \(items.count)")

        if items.isEmpty {
            output.line("  (no pasteboard items)")
            output.line()
            output.flush()
            return
        }

        for (index, item) in items.enumerated() {
            let typeNames = item.types.map(\.rawValue)
            output.line("item[\(index)]:")

            if isConcealed(typeNames: typeNames) {
                output.line("  concealed: true")
                output.line("  content: skipped")
                continue
            }

            output.line("  types (\(typeNames.count)):")
            for typeName in typeNames {
                output.line("    - \(typeName)")
            }

            for pasteboardType in item.types {
                log(type: pasteboardType, item: item)
            }
        }

        output.line()
        output.flush()
    }

    private func log(type: NSPasteboard.PasteboardType, item: NSPasteboardItem) {
        let typeName = type.rawValue
        guard let data = item.data(forType: type) else {
            output.line("  \(typeName):")
            output.line("    bytes: unavailable")
            return
        }

        output.line("  \(typeName):")
        output.line("    bytes: \(data.count)")

        if imageTypes.contains(typeName) {
            if let dimensions = imageDimensions(from: data) {
                output.line("    image: \(Int(dimensions.width))x\(Int(dimensions.height))")
            } else {
                output.line("    image: dimensions unavailable")
            }
            return
        }

        if previewTypes.contains(typeName) {
            if let preview = decodedPreview(for: typeName, data: data) {
                output.line("    preview: \(preview)")
            } else {
                output.line("    preview: <could not decode as text>")
            }
            return
        }

        output.line("    first64Hex: \(data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    private func decodedPreview(for typeName: String, data: Data) -> String? {
        let string: String?
        if typeName == "public.rtf" || typeName == NSPasteboard.PasteboardType.rtf.rawValue {
            string = decodeRTF(data)
        } else if typeName == "public.utf16-external-plain-text" {
            string = String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian)
        } else {
            string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian)
                ?? String(data: data, encoding: .ascii)
        }

        guard let string else {
            return nil
        }
        return truncate(singleLineEscaped(string), limit: config.previewLength)
    }

    private func decodeRTF(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            return String(data: data, encoding: .utf8)
        }
        return attributed.string
    }

    private func imageDimensions(from data: Data) -> CGSize? {
        guard let image = NSImage(data: data) else {
            return nil
        }
        if let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    private func isConcealed(typeNames: [String]) -> Bool {
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

    private func frontmostAppSnapshot() -> AppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return AppSnapshot(
            name: app.localizedName ?? "<unknown>",
            bundleID: app.bundleIdentifier ?? "<unknown>",
            pid: app.processIdentifier,
            path: app.bundleURL?.path ?? "<unknown>"
        )
    }

    private func singleLineEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return "\(value.prefix(limit))..."
    }
}

func parseConfig(arguments: [String]) -> Config {
    var config = Config()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--dump-current":
            config.dumpCurrent = true
        case "--interval":
            index += 1
            guard index < arguments.count, let interval = TimeInterval(arguments[index]), interval > 0 else {
                fail("Expected positive number after --interval")
            }
            config.pollInterval = interval
        case "--preview":
            index += 1
            guard index < arguments.count, let previewLength = Int(arguments[index]), previewLength >= 0 else {
                fail("Expected non-negative integer after --preview")
            }
            config.previewLength = previewLength
        case "--log-file":
            index += 1
            guard index < arguments.count else {
                fail("Expected path after --log-file")
            }
            config.logFilePath = arguments[index]
        case "--help", "-h":
            printUsageAndExit()
        default:
            fail("Unknown argument: \(argument)")
        }
        index += 1
    }

    return config
}

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n\n", stderr)
    printUsageAndExit(exitCode: 2)
}

func printUsageAndExit(exitCode: Int32 = 0) -> Never {
    print("""
    Usage: swift run PasteboardLogger [--dump-current] [--interval seconds] [--preview characters] [--log-file path]

    Watches NSPasteboard.general.changeCount and logs one block per clipboard change.
    Output is written to stdout and a log file. By default, logs land in ./logs/.
    """)
    exit(exitCode)
}

let config = parseConfig(arguments: CommandLine.arguments)
let output = OutputLog(path: config.logFilePath)
ClipboardLogger(config: config, output: output).run()
