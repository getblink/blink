import Foundation

public final class BatchClipboardHistoryAssembler {
    private let inputDirectory: URL
    private let replayOutputDirectory: URL

    public init(inputDirectory: URL, replayOutputDirectory: URL) {
        self.inputDirectory = inputDirectory.standardizedFileURL
        self.replayOutputDirectory = replayOutputDirectory.standardizedFileURL
    }

    public func build(
        goal: String,
        snapshots: [SnapshotSummary],
        historyLimit: Int
    ) throws -> BatchRequestPair {
        let activeSnapshots = snapshots.filter { !$0.isConcealed }
        let replay = BatchClipboardHistoryReplay(
            inputDirectory: inputDirectory,
            outputDirectory: replayOutputDirectory
        )

        var groups: [BatchSourceGroup] = []
        var allSnapshotMetadata: [SnapshotMetadata] = []
        var allWarnings: [String] = []

        for snapshot in activeSnapshots {
            let request = try replay.buildRequest(for: snapshot)
            allSnapshotMetadata.append(request.snapshot)
            allWarnings.append(contentsOf: request.warnings.map { "\(snapshot.id):\($0)" })
            for rootHandle in request.allowedHandles where !rootHandle.contains("_image_") {
                let children = request.items.filter { $0.handle == rootHandle || $0.derivedFrom == rootHandle }
                guard !children.isEmpty else {
                    continue
                }
                groups.append(
                    BatchSourceGroup(
                        snapshot: snapshot,
                        request: request,
                        items: children
                    )
                )
            }
        }

        let selectedGroups = selectHistoryGroups(groups, historyLimit: historyLimit)
        let selectedSnapshotIDs = Set(selectedGroups.map { $0.snapshot.id })
        let snapshotMetadata = allSnapshotMetadata.filter { selectedSnapshotIDs.contains($0.snapshotId) }
        let warnings = allWarnings.filter { warning in
            guard let snapshotID = warning.split(separator: ":", maxSplits: 1).first else {
                return true
            }
            return selectedSnapshotIDs.contains(String(snapshotID))
        }

        var items: [BatchModelItem] = []
        var runtimePayloads: [String: [RuntimePayload]] = [:]
        var allowedHandles: [String] = []
        var globalIndex = 1

        for group in selectedGroups {
            var remap: [String: String] = [:]
            for item in group.items {
                remap[item.handle] = "item_\(globalIndex)"
                globalIndex += 1
            }

            for item in group.items {
                guard let globalHandle = remap[item.handle] else {
                    continue
                }
                allowedHandles.append(globalHandle)
                runtimePayloads[globalHandle] = group.request.runtimePayloads[item.handle] ?? []
                items.append(
                    BatchModelItem(
                        handle: globalHandle,
                        kind: item.kind,
                        utis: item.utis,
                        byteSizes: item.byteSizes,
                        decodedTextPreview: item.decodedTextPreview,
                        sourceURL: item.sourceURL,
                        imageDimensions: item.imageDimensions,
                        hasEmbeddedImageData: item.hasEmbeddedImageData,
                        embeddedImageCount: item.embeddedImageCount,
                        derivedFrom: item.derivedFrom.flatMap { remap[$0] },
                        derivedKind: item.derivedKind,
                        mimeType: item.mimeType,
                        sourceUTI: item.sourceUTI,
                        sourcePath: item.sourcePath,
                        sourceSnapshotID: group.snapshot.id,
                        sourceHandle: item.handle,
                        sourcePaths: (group.request.runtimePayloads[item.handle] ?? []).map(\.rawPath)
                    )
                )
            }
        }

        let full = BatchFullRequest(
            schemaVersion: 0,
            goal: goal,
            snapshots: snapshotMetadata,
            items: items,
            allowedHandles: allowedHandles,
            runtimePayloads: runtimePayloads,
            pathBases: BatchPathBases(
                htmlPreview: inputDirectory.path,
                replayOutput: replayOutputDirectory.path
            ),
            warnings: warnings
        )
        let model = BatchModelRequest(
            schemaVersion: full.schemaVersion,
            goal: goal,
            items: items,
            allowedHandles: allowedHandles
        )
        return BatchRequestPair(full: full, model: model)
    }

    private func selectHistoryGroups(_ groups: [BatchSourceGroup], historyLimit: Int) -> [BatchSourceGroup] {
        guard historyLimit > 0 else {
            return []
        }
        var selectedReversed: [BatchSourceGroup] = []
        var count = 0
        for group in groups.reversed() {
            if !selectedReversed.isEmpty && count + group.items.count > historyLimit {
                break
            }
            selectedReversed.append(group)
            count += group.items.count
            if count >= historyLimit {
                break
            }
        }
        return selectedReversed.reversed()
    }
}

private struct BatchSourceGroup {
    var snapshot: SnapshotSummary
    var request: ModelRequest
    var items: [ModelItem]
}

public struct BatchRequestPair {
    public var full: BatchFullRequest
    public var model: BatchModelRequest
}

public struct BatchFullRequest: Codable, Equatable {
    public var schemaVersion: Int
    public var goal: String
    public var snapshots: [SnapshotMetadata]
    public var items: [BatchModelItem]
    public var allowedHandles: [String]
    public var runtimePayloads: [String: [RuntimePayload]]
    public var pathBases: BatchPathBases
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case goal
        case snapshots
        case items
        case allowedHandles = "allowed_handles"
        case runtimePayloads = "runtime_payloads"
        case pathBases = "path_bases"
        case warnings
    }
}

public struct BatchModelRequest: Codable, Equatable {
    public var schemaVersion: Int
    public var goal: String
    public var items: [BatchModelItem]
    public var allowedHandles: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case goal
        case items
        case allowedHandles = "allowed_handles"
    }
}

public struct BatchPathBases: Codable, Equatable {
    public var htmlPreview: String
    public var replayOutput: String

    enum CodingKeys: String, CodingKey {
        case htmlPreview = "html_preview"
        case replayOutput = "replay_output"
    }
}

public struct BatchModelItem: Codable, Equatable {
    public var handle: String
    public var kind: ModelItem.Kind
    public var utis: [String]
    public var byteSizes: [String: Int]
    public var decodedTextPreview: String?
    public var sourceURL: String?
    public var imageDimensions: ImageDimensions?
    public var hasEmbeddedImageData: Bool
    public var embeddedImageCount: Int?
    public var derivedFrom: String?
    public var derivedKind: String?
    public var mimeType: String?
    public var sourceUTI: String?
    public var sourcePath: String?
    public var sourceSnapshotID: String
    public var sourceHandle: String
    public var sourcePaths: [String]

    enum CodingKeys: String, CodingKey {
        case handle
        case kind
        case utis
        case byteSizes = "byte_sizes"
        case decodedTextPreview = "decoded_text_preview"
        case sourceURL = "source_url"
        case imageDimensions = "image_dimensions"
        case hasEmbeddedImageData = "has_embedded_image_data"
        case embeddedImageCount = "embedded_image_count"
        case derivedFrom = "derived_from"
        case derivedKind = "derived_kind"
        case mimeType = "mime_type"
        case sourceUTI = "source_uti"
        case sourcePath = "source_path"
        case sourceSnapshotID = "source_snapshot_id"
        case sourceHandle = "source_handle"
        case sourcePaths = "source_paths"
    }
}

public enum BatchSelectionError: Error, Equatable, LocalizedError {
    case invalidJSON
    case missingSelectedHandles
    case selectedHandlesNotStrings
    case unknownHandle(String)
    case duplicateHandle(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Model output must be JSON."
        case .missingSelectedHandles:
            return "Model output must contain selected_handles."
        case .selectedHandlesNotStrings:
            return "selected_handles must be an ordered array of strings."
        case let .unknownHandle(handle):
            return "Model selected unknown handle: \(handle)"
        case let .duplicateHandle(handle):
            return "Model selected duplicate handle: \(handle)"
        }
    }
}

public func parseAndValidateSelection(_ raw: String, allowedHandles: [String]) throws -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let jsonText: String
    if trimmed.hasPrefix("```") {
        jsonText = trimmed
            .replacingOccurrences(of: #"^```[A-Za-z0-9_-]*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        jsonText = trimmed
    }
    guard let data = jsonText.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BatchSelectionError.invalidJSON
    }
    guard object.keys.contains("selected_handles") else {
        throw BatchSelectionError.missingSelectedHandles
    }
    guard let selected = object["selected_handles"] as? [Any] else {
        throw BatchSelectionError.selectedHandlesNotStrings
    }
    let allowed = Set(allowedHandles)
    var seen: Set<String> = []
    var handles: [String] = []
    for value in selected {
        guard let handle = value as? String else {
            throw BatchSelectionError.selectedHandlesNotStrings
        }
        guard allowed.contains(handle) else {
            throw BatchSelectionError.unknownHandle(handle)
        }
        guard !seen.contains(handle) else {
            throw BatchSelectionError.duplicateHandle(handle)
        }
        seen.insert(handle)
        handles.append(handle)
    }
    return handles
}

public struct ResolvedSelectionManifest: Codable, Equatable {
    public var selectedHandles: [String]
    public var items: [ResolvedSelectionItem]

    enum CodingKeys: String, CodingKey {
        case selectedHandles = "selected_handles"
        case items
    }
}

public struct ResolvedSelectionItem: Codable, Equatable {
    public var handle: String
    public var sourceSnapshotID: String?
    public var sourceHandle: String?
    public var payloads: [ResolvedPayload]

    enum CodingKeys: String, CodingKey {
        case handle
        case sourceSnapshotID = "source_snapshot_id"
        case sourceHandle = "source_handle"
        case payloads
    }
}

public struct ResolvedPayload: Codable, Equatable {
    public var uti: String
    public var rawPath: String
    public var decodedPath: String?
    public var expectedByteSize: Int
    public var actualByteSize: Int?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case uti
        case rawPath = "raw_path"
        case decodedPath = "decoded_path"
        case expectedByteSize = "expected_byte_size"
        case actualByteSize = "actual_byte_size"
        case error
    }
}

public func resolveSelection(
    selectedHandles: [String],
    fullRequest: BatchFullRequest
) -> ResolvedSelectionManifest {
    let itemByHandle = Dictionary(uniqueKeysWithValues: fullRequest.items.map { ($0.handle, $0) })
    let htmlPreview = URL(fileURLWithPath: fullRequest.pathBases.htmlPreview, isDirectory: true)
    let replayOutput = URL(fileURLWithPath: fullRequest.pathBases.replayOutput, isDirectory: true)

    let items = selectedHandles.map { handle in
        let modelItem = itemByHandle[handle]
        let payloads = (fullRequest.runtimePayloads[handle] ?? []).map { payload in
            let base = payload.rawPath.hasPrefix("derived-payloads/") ? replayOutput : htmlPreview
            let rawURL = base.appendingPathComponent(payload.rawPath)
            let actualSize = (try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let error: String?
            if actualSize == nil {
                error = "missing_file"
            } else if actualSize != payload.byteSize {
                error = "byte_size_mismatch"
            } else {
                error = nil
            }
            return ResolvedPayload(
                uti: payload.uti,
                rawPath: rawURL.path,
                decodedPath: payload.decodedPath.map { htmlPreview.appendingPathComponent($0).path },
                expectedByteSize: payload.byteSize,
                actualByteSize: actualSize,
                error: error
            )
        }
        return ResolvedSelectionItem(
            handle: handle,
            sourceSnapshotID: modelItem?.sourceSnapshotID,
            sourceHandle: modelItem?.sourceHandle,
            payloads: payloads
        )
    }
    return ResolvedSelectionManifest(selectedHandles: selectedHandles, items: items)
}
