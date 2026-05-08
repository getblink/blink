import AppKit
import Foundation

/// Zips the N most recent bundles under `Paths.runsDir` into a single archive
/// on the tester's Desktop for AirDrop/email transport back to the research
/// machine. The receiving side runs `scratchpad/import_field_runs.py <zip>`.
enum BundleExporter {
    enum ExportError: LocalizedError {
        case noRuns
        case zipFailed(stderr: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case .noRuns: return "no runs found under \(Paths.runsDir.path)"
            case .zipFailed(let s, let code): return "/usr/bin/zip failed (\(code)): \(s)"
            }
        }
    }

    static func exportLastNToDesktop(
        n: Int,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let runs = try mostRecentBundles(limit: n)
                if runs.isEmpty {
                    completion(.failure(ExportError.noRuns))
                    return
                }
                let desktop = try FileManager.default.url(
                    for: .desktopDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false
                )
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                let dest = desktop.appendingPathComponent(
                    "Blink-runs-\(formatter.string(from: Date())).zip")

                try zip(bundles: runs, destination: dest)
                completion(.success(dest))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func mostRecentBundles(limit: Int) throws -> [URL] {
        let runsDir = Paths.runsDir
        let entries = try FileManager.default.contentsOfDirectory(
            at: runsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let bundles = entries.compactMap { url -> (URL, Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true,
                  let date = values?.contentModificationDate,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("fixture.json").path)
            else { return nil }
            return (url, date)
        }
        return bundles
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    private static func zip(bundles: [URL], destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = bundles[0].deletingLastPathComponent()
        var args = ["-qr", destination.path]
        for bundle in bundles {
            args.append(bundle.lastPathComponent)
        }
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ExportError.zipFailed(stderr: msg, status: process.terminationStatus)
        }
    }
}
