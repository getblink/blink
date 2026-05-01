import Foundation
import PasteboardReplayCore

struct CLIConfig {
    var inputPath: String?
    var outputPath: String?
}

func parseConfig(arguments: [String]) -> CLIConfig {
    var config = CLIConfig()
    var index = 1

    while index < arguments.count {
        switch arguments[index] {
        case "--input":
            index += 1
            guard index < arguments.count else {
                fail("Expected path after --input")
            }
            config.inputPath = arguments[index]
        case "--out":
            index += 1
            guard index < arguments.count else {
                fail("Expected path after --out")
            }
            config.outputPath = arguments[index]
        case "--help", "-h":
            printUsageAndExit()
        default:
            fail("Unknown argument: \(arguments[index])")
        }
        index += 1
    }

    guard config.inputPath != nil else {
        fail("Missing required --input path")
    }
    guard config.outputPath != nil else {
        fail("Missing required --out path")
    }

    return config
}

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n\n", stderr)
    printUsageAndExit(exitCode: 2)
}

func printUsageAndExit(exitCode: Int32 = 0) -> Never {
    print("""
    Usage: swift run BatchClipboardHistoryReplay --input html-preview --out model-requests

    Replays immutable PasteboardHTMLPreview snapshots into one schema_version 0 model-request JSON file per snapshot.
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

let config = parseConfig(arguments: CommandLine.arguments)
let inputDir = resolveDirectory(config.inputPath!)
let outputDir = resolveDirectory(config.outputPath!)

do {
    let writer = BatchClipboardHistoryReplay(inputDirectory: inputDir, outputDirectory: outputDir)
    let written = try writer.run()
    for file in written {
        print(file.path)
    }
    print("wrote \(written.count) request file\(written.count == 1 ? "" : "s")")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
