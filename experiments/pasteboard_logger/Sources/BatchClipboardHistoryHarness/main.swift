import AppKit
import Foundation
import PasteboardReplayCore

struct HarnessConfig {
    var workDir = "batch-harness"
    var historyLimit = 20
    var pollInterval: TimeInterval = 0.25
    var modelScript = "scripts/batch_model_select.py"
    var pythonPath: String?
    var mockResponse: String?
}

func parseConfig(arguments: [String]) -> HarnessConfig {
    var config = HarnessConfig()
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--work-dir":
            index += 1
            guard index < arguments.count else { fail("Expected path after --work-dir") }
            config.workDir = arguments[index]
        case "--history-limit":
            index += 1
            guard index < arguments.count, let limit = Int(arguments[index]), limit > 0 else {
                fail("Expected positive integer after --history-limit")
            }
            config.historyLimit = limit
        case "--interval":
            index += 1
            guard index < arguments.count, let interval = TimeInterval(arguments[index]), interval > 0 else {
                fail("Expected positive number after --interval")
            }
            config.pollInterval = interval
        case "--model-script":
            index += 1
            guard index < arguments.count else { fail("Expected path after --model-script") }
            config.modelScript = arguments[index]
        case "--python":
            index += 1
            guard index < arguments.count else { fail("Expected path after --python") }
            config.pythonPath = arguments[index]
        case "--mock-response":
            index += 1
            guard index < arguments.count else { fail("Expected JSON string after --mock-response") }
            config.mockResponse = arguments[index]
        case "--help", "-h":
            printUsageAndExit()
        default:
            fail("Unknown argument: \(arguments[index])")
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
    Usage: swift run BatchClipboardHistoryHarness [--work-dir batch-harness] [--history-limit 20] [--python path] [--mock-response JSON]

    Watches NSPasteboard.general, captures immutable snapshots, and lets you run a dry batch selection loop.
    Commands: goal <text>, run, list, clear, quit
    """)
    exit(exitCode)
}

func resolveDirectory(_ path: String) -> URL {
    let rawURL: URL
    if (path as NSString).isAbsolutePath {
        rawURL = URL(fileURLWithPath: path, isDirectory: true)
    } else {
        rawURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
    }
    return rawURL.standardizedFileURL
}

func resolveFile(_ path: String) -> URL {
    if (path as NSString).isAbsolutePath {
        return URL(fileURLWithPath: path, isDirectory: false)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
}

func resolvePythonExecutable(_ explicitPath: String?) -> URL {
    if let explicitPath {
        return resolveFile(explicitPath)
    }

    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .standardizedFileURL
    // Do not call standardizedFileURL on Python executables: venv launchers are
    // often symlinks, and resolving them runs the base interpreter without the
    // venv's installed packages.
    let candidates = [
        cwd.appendingPathComponent("scratchpad/.venv/bin/python", isDirectory: false),
        cwd.appendingPathComponent("../../scratchpad/.venv/bin/python", isDirectory: false),
        cwd.appendingPathComponent(".venv/bin/python", isDirectory: false),
        cwd.appendingPathComponent("app/python-dist/bin/python3", isDirectory: false),
        cwd.appendingPathComponent("../../app/python-dist/bin/python3", isDirectory: false),
        URL(fileURLWithPath: "/usr/bin/python3", isDirectory: false)
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ?? URL(fileURLWithPath: "/usr/bin/python3", isDirectory: false)
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter.string(from: Date())
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func buildBatchRequest(goal: String, snapshots: [SnapshotSummary], replayDir: URL) throws -> BatchRequestPair {
    let assembler = BatchClipboardHistoryAssembler(inputDirectory: htmlPreviewDir, replayOutputDirectory: replayDir)
    return try assembler.build(goal: goal, snapshots: snapshots, historyLimit: config.historyLimit)
}

func printBuffer(_ request: BatchModelRequest) {
    guard !request.items.isEmpty else {
        print("No clipboard items captured yet.")
        return
    }
    print("handle  kind        bytes       UTIs / preview")
    print("------  ----------  ----------  ----------------------------------------")
    for item in request.items {
        let kind = item.kind.rawValue
        let bytes = item.byteSizes.values.reduce(0, +)
        let utis = item.utis.prefix(3).joined(separator: ", ")
        let preview = item.decodedTextPreview ?? item.sourceURL ?? item.sourcePath ?? ""
        let handle = item.handle.padding(toLength: 7, withPad: " ", startingAt: 0)
        let paddedKind = kind.padding(toLength: 10, withPad: " ", startingAt: 0)
        let paddedBytes = String(bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(handle) \(paddedKind) \(paddedBytes) \(utis) \(preview)")
    }
}

func runModel(python: URL, script: URL, modelRequest: URL, rawOutput: URL, mockResponse: String?) throws -> String {
    if let mockResponse {
        try mockResponse.write(to: rawOutput, atomically: true, encoding: .utf8)
        return mockResponse
    }

    let process = Process()
    process.executableURL = python
    process.arguments = [
        script.path,
        "--request", modelRequest.path
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outData, encoding: .utf8) ?? ""
    let errors = String(data: errData, encoding: .utf8) ?? ""
    try (output + (errors.isEmpty ? "" : "\n[stderr]\n\(errors)")).write(to: rawOutput, atomically: true, encoding: .utf8)
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BatchClipboardHistoryHarness", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "Model helper failed with status \(process.terminationStatus). See \(rawOutput.path)"
        ])
    }
    return output
}

let config = parseConfig(arguments: CommandLine.arguments)
let workDir = resolveDirectory(config.workDir)
let htmlPreviewDir = workDir.appendingPathComponent("html-preview", isDirectory: true)
let runsDir = workDir.appendingPathComponent("runs", isDirectory: true)
let modelScript = resolveDirectory(".").appendingPathComponent(config.modelScript)
let pythonExecutable = resolvePythonExecutable(config.pythonPath)
let pasteboard = NSPasteboard.general
let snapshotWriter = PasteboardSnapshotWriter(outDir: htmlPreviewDir)
let fileManager = FileManager.default
try fileManager.createDirectory(at: htmlPreviewDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: runsDir, withIntermediateDirectories: true)

var snapshots: [SnapshotSummary] = []
var goal = ""
let captureQueue = DispatchQueue(label: "batch-clipboard-history-harness.capture")

func captureIfChanged() {
    captureQueue.async {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        do {
            let snapshot = try snapshotWriter.writeSnapshot(from: pasteboard)
            snapshots.append(snapshot)
            if snapshots.count > config.historyLimit * 2 {
                snapshots.removeFirst(snapshots.count - config.historyLimit * 2)
            }
            print("captured cc=\(snapshot.changeCount) kind=\(snapshot.renderedKind) preview=\(snapshot.preview)")
            print("> ", terminator: "")
            fflush(stdout)
        } catch {
            fputs("capture error: \(error)\n", stderr)
        }
    }
}

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
timer.schedule(deadline: .now() + config.pollInterval, repeating: config.pollInterval)
timer.setEventHandler {
    captureIfChanged()
}
timer.resume()

var lastChangeCount = pasteboard.changeCount
let initialSnapshot = try snapshotWriter.writeSnapshot(from: pasteboard)
captureQueue.sync {
    snapshots.append(initialSnapshot)
}

print("Batch clipboard history harness")
print("work-dir: \(workDir.path)")
print("python: \(pythonExecutable.path)")
print("Commands: goal <text>, run, list, clear, quit")
print("> ", terminator: "")
fflush(stdout)

while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "quit" || trimmed == "exit" {
        break
    } else if trimmed.hasPrefix("goal ") {
        goal = String(trimmed.dropFirst("goal ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        print("goal set.")
    } else if trimmed == "list" {
        let current = captureQueue.sync { snapshots }
        do {
            let pair = try buildBatchRequest(
                goal: goal,
                snapshots: current,
                replayDir: workDir.appendingPathComponent("list-replay", isDirectory: true)
            )
            printBuffer(pair.model)
        } catch {
            fputs("list error: \(error.localizedDescription)\n", stderr)
        }
    } else if trimmed == "clear" {
        captureQueue.sync { snapshots.removeAll() }
        print("cleared in-memory buffer.")
    } else if trimmed == "run" {
        let current = captureQueue.sync { snapshots }
        guard !goal.isEmpty else {
            print("Set a goal first: goal <text>")
            print("> ", terminator: "")
            fflush(stdout)
            continue
        }
        guard current.contains(where: { !$0.isConcealed }) else {
            print("No non-concealed snapshots captured yet.")
            print("> ", terminator: "")
            fflush(stdout)
            continue
        }

        do {
            let runDir = runsDir.appendingPathComponent(timestamp(), isDirectory: true)
            let replayDir = runDir.appendingPathComponent("replay", isDirectory: true)
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
            let pair = try buildBatchRequest(goal: goal, snapshots: current, replayDir: replayDir)
            let fullURL = runDir.appendingPathComponent("batch-request.full.json")
            let modelURL = runDir.appendingPathComponent("batch-request.model.json")
            let rawURL = runDir.appendingPathComponent("model-output.raw.txt")
            let parsedURL = runDir.appendingPathComponent("model-output.json")
            let resolvedURL = runDir.appendingPathComponent("resolved-selection.json")
            try writeJSON(pair.full, to: fullURL)
            try writeJSON(pair.model, to: modelURL)
            let raw = try runModel(
                python: pythonExecutable,
                script: modelScript,
                modelRequest: modelURL,
                rawOutput: rawURL,
                mockResponse: config.mockResponse
            )
            let selected = try parseAndValidateSelection(raw, allowedHandles: pair.model.allowedHandles)
            try writeJSON(["selected_handles": selected], to: parsedURL)
            let resolved = resolveSelection(selectedHandles: selected, fullRequest: pair.full)
            try writeJSON(resolved, to: resolvedURL)
            print("wrote \(runDir.path)")
            print("selected: \(selected.joined(separator: ", "))")
        } catch {
            fputs("run error: \(error.localizedDescription)\n", stderr)
        }
    } else if trimmed.isEmpty {
        // no-op
    } else {
        print("Unknown command. Use: goal <text>, run, list, clear, quit")
    }
    print("> ", terminator: "")
    fflush(stdout)
}
