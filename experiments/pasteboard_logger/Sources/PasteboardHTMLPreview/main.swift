import AppKit
import Foundation
import PasteboardReplayCore

var httpServer: Process?
var signalSources: [DispatchSourceSignal] = []

struct Config {
    var outputPath: String?
    var watch = false
    var pollInterval: TimeInterval = 0.25
    var port = 8765
}

func parseConfig(arguments: [String]) -> Config {
    var config = Config()
    var index = 1

    while index < arguments.count {
        switch arguments[index] {
        case "--out":
            index += 1
            guard index < arguments.count else {
                fail("Expected path after --out")
            }
            config.outputPath = arguments[index]
        case "--watch":
            config.watch = true
        case "--interval":
            index += 1
            guard index < arguments.count,
                  let interval = TimeInterval(arguments[index]),
                  interval > 0 else {
                fail("Expected positive number after --interval")
            }
            config.pollInterval = interval
        case "--port":
            index += 1
            guard index < arguments.count,
                  let port = Int(arguments[index]),
                  port > 0 else {
                fail("Expected positive integer after --port")
            }
            config.port = port
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
    Usage: swift run PasteboardHTMLPreview [--watch] [--interval seconds] [--out directory] [--port port]

    Dumps NSPasteboard.general contents into immutable snapshot folders and writes an interactive timeline page.
    In --watch mode, appends a new snapshot whenever changeCount changes and serves the page locally.
    """)
    exit(exitCode)
}

func resolveOutputDirectory(_ path: String?) -> URL {
    let resolvedPath = path ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("pasteboard-html-preview-\(filenameTimestamp())", isDirectory: true)
        .path

    let rawURL: URL
    if (resolvedPath as NSString).isAbsolutePath {
        rawURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
    } else {
        rawURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(resolvedPath, isDirectory: true)
    }
    return rawURL.standardizedFileURL
}

func filenameTimestamp(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter.string(from: date)
}

func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func loadTimeline(from outDir: URL) -> [SnapshotSummary] {
    let file = outDir.appendingPathComponent("timeline.json")
    guard let data = try? Data(contentsOf: file),
          let timeline = try? JSONDecoder().decode([SnapshotSummary].self, from: data) else {
        return []
    }
    return timeline
}

func saveTimeline(_ timeline: [SnapshotSummary], to outDir: URL) throws {
    let file = outDir.appendingPathComponent("timeline.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(timeline).write(to: file, options: .atomic)
}

func startHTTPServer(directory: URL, port: Int) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-m", "http.server", "\(port)",
        "--bind", "127.0.0.1",
        "--directory", directory.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func installSignalHandlers() {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler {
            httpServer?.terminate()
            exit(signalNumber)
        }
        source.resume()
        signalSources.append(source)
    }
}

func renderIndex(outDir: URL, timeline: [SnapshotSummary], watch: Bool) throws {
    let rows = timeline.reversed().map { snapshot in
        let typeSummary = snapshot.types.prefix(5).map { "<code>\(escapeHTML($0))</code>" }.joined(separator: " ")
        let sourceURL = snapshot.sourceURL.isEmpty ? "" : "<div class=\"source\">\(escapeHTML(snapshot.sourceURL))</div>"
        let flags = [
            snapshot.hasEmbeddedImage ? "embedded image" : nil,
            snapshot.isConcealed ? "concealed" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        return """
        <article class="snapshot">
          <a class="open" target="viewer" href="snapshots/\(escapeHTML(snapshot.id))/snapshot.html">Open</a>
          <div class="main">
            <div><strong>cc \(snapshot.changeCount)</strong> <span class="muted">\(escapeHTML(snapshot.observedAt))</span></div>
            <div class="metrics">rendered=<code>\(escapeHTML(snapshot.renderedKind))</code> html=<code>\(snapshot.htmlBytes)</code> text=<code>\(snapshot.plainTextBytes)</code> items=<code>\(snapshot.itemCount)</code>\(flags.isEmpty ? "" : " flags=<code>\(escapeHTML(flags))</code>")</div>
            <div class="types">\(typeSummary)</div>
            \(sourceURL)
            <div class="preview">\(escapeHTML(snapshot.preview))</div>
          </div>
        </article>
        """
    }.joined(separator: "\n")

    let latest = timeline.last
    let latestHref = latest.map { "snapshots/\(escapeHTML($0.id))/snapshot.html" } ?? "about:blank"
    let latestSummary = latest.map { "cc \($0.changeCount) / \($0.renderedKind) / \($0.observedAt)" } ?? "no snapshots yet"
    let liveScript = watch ? """
    let lastCount = \(timeline.count);
    var selectedSnapshot = \(latest.map { "\"\($0.id)\"" } ?? "null");
    var followLatest = true;

    function escapeHTML(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function snapshotRow(snapshot) {
      const typeSummary = snapshot.types.slice(0, 5).map((type) => `<code>${escapeHTML(type)}</code>`).join(" ");
      const sourceURL = snapshot.sourceURL ? `<div class="source">${escapeHTML(snapshot.sourceURL)}</div>` : "";
      const flags = [snapshot.hasEmbeddedImage ? "embedded image" : null, snapshot.isConcealed ? "concealed" : null].filter(Boolean).join(", ");
      const activeClass = snapshot.id === selectedSnapshot ? " active" : "";
      return `
        <article class="snapshot${activeClass}">
          <a class="open" target="viewer" data-id="${escapeHTML(snapshot.id)}" href="snapshots/${escapeHTML(snapshot.id)}/snapshot.html">Open</a>
          <div class="main">
            <div><strong>cc ${snapshot.changeCount}</strong> <span class="muted">${escapeHTML(snapshot.observedAt)}</span></div>
            <div class="metrics">rendered=<code>${escapeHTML(snapshot.renderedKind)}</code> html=<code>${snapshot.htmlBytes}</code> text=<code>${snapshot.plainTextBytes}</code> items=<code>${snapshot.itemCount}</code>${flags ? ` flags=<code>${escapeHTML(flags)}</code>` : ""}</div>
            <div class="types">${typeSummary}</div>
            ${sourceURL}
            <div class="preview">${escapeHTML(snapshot.preview || "")}</div>
          </div>
        </article>
      `;
    }

    function renderTimeline(timeline) {
      const snapshots = document.querySelector("#snapshots");
      const latest = timeline[timeline.length - 1];
      if (!latest) {
        snapshots.innerHTML = '<div class="snapshot">No snapshots yet.</div>';
        return;
      }

      if (!selectedSnapshot || followLatest) {
        selectedSnapshot = latest.id;
        document.querySelector("#viewer").src = `snapshots/${latest.id}/snapshot.html`;
      }

      document.querySelector("#snapshotCount").textContent = String(timeline.length);
      document.querySelector("#latestSummary").textContent = `cc ${latest.changeCount} / ${latest.renderedKind} / ${latest.observedAt}`;
      snapshots.innerHTML = timeline.slice().reverse().map(snapshotRow).join("");
      bindSnapshotLinks();
    }

    function bindSnapshotLinks() {
      for (const link of document.querySelectorAll("#snapshots a.open")) {
        link.addEventListener("click", () => {
          selectedSnapshot = link.dataset.id;
          followLatest = false;
        });
      }
    }

    async function pollTimeline() {
      try {
        const response = await fetch("timeline.json?ts=" + Date.now(), { cache: "no-store" });
        const timeline = await response.json();
        if (Array.isArray(timeline) && timeline.length !== lastCount) {
          lastCount = timeline.length;
          renderTimeline(timeline);
        }
      } catch (_) {}
      setTimeout(pollTimeline, 1000);
    }
    bindSnapshotLinks();
    pollTimeline();
    """ : ""

    let page = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Pasteboard Timeline</title>
      <style>
        :root {
          color-scheme: light dark;
          font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          background: Canvas;
          color: CanvasText;
        }
        body { margin: 0; }
        header {
          padding: 14px 18px;
          border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
        }
        h1 { font-size: 18px; margin: 0 0 6px; }
        .layout {
          display: grid;
          grid-template-columns: minmax(320px, 430px) 1fr;
          height: calc(100vh - 70px);
          min-height: 520px;
        }
        aside {
          border-right: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
          overflow: auto;
        }
        iframe {
          width: 100%;
          height: 100%;
          border: 0;
          background: white;
        }
        .snapshot {
          display: grid;
          grid-template-columns: 52px 1fr;
          gap: 10px;
          padding: 12px;
          border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
        }
        .snapshot.active {
          background: color-mix(in srgb, Highlight 12%, transparent);
        }
        .open {
          align-self: start;
          border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
          border-radius: 6px;
          padding: 6px 8px;
          text-align: center;
          text-decoration: none;
          color: CanvasText;
          font-size: 12px;
        }
        .metrics, .types, .source, .preview, .muted {
          color: color-mix(in srgb, CanvasText 64%, transparent);
          font-size: 12px;
          line-height: 1.45;
        }
        .preview, .source {
          margin-top: 5px;
          word-break: break-word;
        }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
          font-size: 11px;
        }
        @media (max-width: 900px) {
          .layout { grid-template-columns: 1fr; height: auto; }
          iframe { height: 70vh; }
        }
      </style>
    </head>
    <body>
      <header>
        <h1>Pasteboard Timeline</h1>
        <div class="muted">mode=<code>\(watch ? "live" : "one-shot")</code> snapshots=<code id="snapshotCount">\(timeline.count)</code> latest=<code id="latestSummary">\(escapeHTML(latestSummary))</code> folder=<code>\(escapeHTML(outDir.path))</code></div>
      </header>
      <div class="layout">
        <aside id="snapshots">
          \(rows.isEmpty ? "<div class=\"snapshot\">No snapshots yet.</div>" : rows)
        </aside>
        <iframe id="viewer" name="viewer" src="\(latestHref)" title="Selected pasteboard snapshot"></iframe>
      </div>
      <script>
        \(liveScript)
      </script>
    </body>
    </html>
    """

    try page.write(to: outDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
}

let config = parseConfig(arguments: CommandLine.arguments)
let outDir = resolveOutputDirectory(config.outputPath)
let pasteboard = NSPasteboard.general
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

if config.watch {
    installSignalHandlers()
    httpServer = try startHTTPServer(directory: outDir, port: config.port)
    Thread.sleep(forTimeInterval: 0.2)
    guard httpServer?.isRunning == true else {
        fail("Could not start local HTTP server on 127.0.0.1:\(config.port)")
    }
}

var timeline = loadTimeline(from: outDir)
let snapshotWriter = PasteboardSnapshotWriter(outDir: outDir)
let firstSnapshot = try snapshotWriter.writeSnapshot(from: pasteboard)
timeline.append(firstSnapshot)
try saveTimeline(timeline, to: outDir)
try renderIndex(outDir: outDir, timeline: timeline, watch: config.watch)

print(outDir.appendingPathComponent("index.html").path)
if config.watch {
    print("http://127.0.0.1:\(config.port)/index.html")
}
print("captured changeCount=\(firstSnapshot.changeCount) rendered=\(firstSnapshot.renderedKind) htmlBytes=\(firstSnapshot.htmlBytes) plainTextBytes=\(firstSnapshot.plainTextBytes)")

if config.watch {
    print("Watching NSPasteboard.general every \(config.pollInterval)s. Press Ctrl-C to stop.")
    fflush(stdout)

    var lastChangeCount = pasteboard.changeCount
    while true {
        Thread.sleep(forTimeInterval: config.pollInterval)
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            continue
        }

        lastChangeCount = changeCount
        let snapshot = try snapshotWriter.writeSnapshot(from: pasteboard)
        timeline.append(snapshot)
        try saveTimeline(timeline, to: outDir)
        try renderIndex(outDir: outDir, timeline: timeline, watch: true)
        print("captured changeCount=\(snapshot.changeCount) rendered=\(snapshot.renderedKind) htmlBytes=\(snapshot.htmlBytes) plainTextBytes=\(snapshot.plainTextBytes)")
        fflush(stdout)
    }
}
