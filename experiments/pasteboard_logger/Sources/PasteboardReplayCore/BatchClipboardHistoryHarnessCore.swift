import Foundation

public final class BatchClipboardHistoryAssembler {
    private let inputDirectory: URL
    private let replayOutputDirectory: URL
    private let imageTagCacheDirectory: URL?
    private let imageClassifier: ImageContentClassifier?

    public init(
        inputDirectory: URL,
        replayOutputDirectory: URL,
        imageTagCacheDirectory: URL? = nil,
        imageClassifier: ImageContentClassifier? = nil
    ) {
        self.inputDirectory = inputDirectory.standardizedFileURL
        self.replayOutputDirectory = replayOutputDirectory.standardizedFileURL
        self.imageTagCacheDirectory = imageTagCacheDirectory?.standardizedFileURL
        self.imageClassifier = imageClassifier
    }

    public func build(
        goal: String,
        snapshots: [SnapshotSummary],
        historyLimit: Int
    ) throws -> BatchRequestPair {
        let activeSnapshots = snapshots.filter { !$0.isConcealed }
        let replay = BatchClipboardHistoryReplay(
            inputDirectory: inputDirectory,
            outputDirectory: replayOutputDirectory,
            imageTagCacheDirectory: imageTagCacheDirectory,
            imageClassifier: imageClassifier
        )

        var groups: [BuildSourceGroup] = []
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
                    BuildSourceGroup(
                        snapshot: snapshot,
                        request: request,
                        rootHandle: rootHandle,
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
        var sourceGroups: [BatchSourceGroup] = []
        var globalIndex = 1

        for (groupIndex, group) in selectedGroups.enumerated() {
            var remap: [String: String] = [:]
            for item in group.items {
                remap[item.handle] = "item_\(globalIndex)"
                globalIndex += 1
            }

            var remappedVariants: [BatchSourceGroupVariant] = []
            let originalRootHandle = group.items.first(where: { $0.derivedFrom == nil })?.handle ?? group.rootHandle
            for item in group.items {
                guard let remappedHandle = remap[item.handle] else {
                    continue
                }
                let role = sourceGroupVariantRole(for: item, rootHandle: originalRootHandle)
                remappedVariants.append(
                    BatchSourceGroupVariant(
                        handle: remappedHandle,
                        role: role,
                        derivedFrom: item.derivedFrom.flatMap { remap[$0] },
                        derivedKind: item.derivedKind,
                        preserves: sourceVariantPreserves(role: role, item: item),
                        loses: sourceVariantLoses(role: role, item: item),
                        kind: item.kind,
                        utis: item.utis,
                        byteSizes: item.byteSizes,
                        decodedTextPreview: item.decodedTextPreview,
                        sourceURL: item.sourceURL,
                        imageDimensions: item.imageDimensions,
                        visualTags: item.visualTags,
                        visualSummary: item.visualSummary,
                        visualTagStatus: item.visualTagStatus,
                        hasEmbeddedImageData: item.hasEmbeddedImageData,
                        embeddedImageCount: item.embeddedImageCount,
                        sourceHandle: item.handle
                    )
                )
            }
            sourceGroups.append(
                BatchSourceGroup(
                    groupID: "group_\(groupIndex + 1)",
                    rootHandle: remap[group.rootHandle] ?? group.rootHandle,
                    sourceSummary: group.items.first(where: { $0.handle == group.rootHandle })?.decodedTextPreview,
                    variants: remappedVariants
                )
            )

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
                        visualTags: item.visualTags,
                        visualSummary: item.visualSummary,
                        visualTagStatus: item.visualTagStatus,
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
            sourceGroups: sourceGroups,
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
            allowedHandles: allowedHandles,
            sourceGroups: sourceGroups
        )
        return BatchRequestPair(full: full, model: model)
    }

    private func selectHistoryGroups(_ groups: [BuildSourceGroup], historyLimit: Int) -> [BuildSourceGroup] {
        guard historyLimit > 0 else {
            return []
        }
        var selectedReversed: [BuildSourceGroup] = []
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

    private func sourceGroupVariantRole(for item: ModelItem, rootHandle: String) -> String {
        if item.derivedFrom == nil {
            return item.handle == rootHandle && (item.kind == .html || item.utis.contains("public.html")) ? "root_rich_parent" : "root_parent"
        }
        guard let kind = item.derivedKind else {
            return "derived_variant"
        }
        if kind == "embedded_html_image" {
            return "derived_raw_image"
        }
        if kind == "embedded_html_image_fragment" || kind == "google_slides_image_object_fragment" {
            return "derived_rich_image_fragment"
        }
        return "derived_variant"
    }

    private func sourceVariantPreserves(role: String, item: ModelItem) -> [String] {
        switch role {
        case "root_rich_parent":
            return ["full_selection", "layout", "styles", "text"]
        case "derived_raw_image":
            return ["image"]
        case "derived_rich_image_fragment":
            return ["image", "fragment_layout"]
        default:
            return item.derivedKind == nil ? ["content"] : ["selection_payload"]
        }
    }

    private func sourceVariantLoses(role: String, item: ModelItem) -> [String] {
        switch role {
        case "root_rich_parent":
            return []
        case "derived_raw_image":
            return ["structure", "text", "context"]
        case "derived_rich_image_fragment":
            return ["surrounding_context", "sibling_objects", "full_document"]
        default:
            return item.derivedKind == nil ? [] : ["full_context"]
        }
    }

}

private struct BuildSourceGroup {
    var snapshot: SnapshotSummary
    var request: ModelRequest
    var rootHandle: String
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
    public var sourceGroups: [BatchSourceGroup] = []
    public var runtimePayloads: [String: [RuntimePayload]]
    public var pathBases: BatchPathBases
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case goal
        case snapshots
        case items
        case allowedHandles = "allowed_handles"
        case sourceGroups = "source_groups"
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
    public var sourceGroups: [BatchSourceGroup] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case goal
        case items
        case allowedHandles = "allowed_handles"
        case sourceGroups = "source_groups"
    }
}

public struct BatchSourceGroup: Codable, Equatable {
    public var groupID: String
    public var rootHandle: String
    public var sourceSummary: String?
    public var variants: [BatchSourceGroupVariant]

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case rootHandle = "root_handle"
        case sourceSummary = "source_summary"
        case variants
    }
}

public struct BatchSourceGroupVariant: Codable, Equatable {
    public var handle: String
    public var role: String
    public var derivedFrom: String?
    public var derivedKind: String?
    public var preserves: [String]
    public var loses: [String]
    public var kind: ModelItem.Kind
    public var utis: [String]
    public var byteSizes: [String: Int]
    public var decodedTextPreview: String?
    public var sourceURL: String?
    public var imageDimensions: ImageDimensions?
    public var visualTags: [VisualTag]
    public var visualSummary: String?
    public var visualTagStatus: String?
    public var hasEmbeddedImageData: Bool
    public var embeddedImageCount: Int?
    public var sourceHandle: String?

    enum CodingKeys: String, CodingKey {
        case handle
        case role
        case derivedFrom = "derived_from"
        case derivedKind = "derived_kind"
        case preserves
        case loses
        case kind
        case utis
        case byteSizes = "byte_sizes"
        case decodedTextPreview = "decoded_text_preview"
        case sourceURL = "source_url"
        case imageDimensions = "image_dimensions"
        case visualTags = "visual_tags"
        case visualSummary = "visual_summary"
        case visualTagStatus = "visual_tag_status"
        case hasEmbeddedImageData = "has_embedded_image_data"
        case embeddedImageCount = "embedded_image_count"
        case sourceHandle = "source_handle"
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
    public var visualTags: [VisualTag]
    public var visualSummary: String?
    public var visualTagStatus: String?
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
        case visualTags = "visual_tags"
        case visualSummary = "visual_summary"
        case visualTagStatus = "visual_tag_status"
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
    case missingPasteItems
    case pasteItemsNotArray
    case malformedPasteItem
    case malformedPasteItemType
    case malformedPasteHandle
    case malformedPasteText
    case unknownHandle(String)
    case duplicateHandle(String)
    case pasteTextTooLong(limit: Int, actual: Int)
    case pasteTextTotalTooLong(limit: Int, actual: Int)
    case emptyPasteText
    case malformedSelectionObject

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Model output must be JSON."
        case .missingSelectedHandles:
            return "Model output must contain selected_handles or paste_items."
        case .selectedHandlesNotStrings:
            return "selected_handles must be an ordered array of strings."
        case .missingPasteItems:
            return "Model output must contain paste_items."
        case .pasteItemsNotArray:
            return "paste_items must be an array."
        case .malformedPasteItem:
            return "Each paste item must be an object with a valid type."
        case .malformedPasteItemType:
            return "Each paste item type must be handle or text."
        case .malformedPasteHandle:
            return "Each handle paste item must include a handle string."
        case .malformedPasteText:
            return "Each text paste item must include plain text."
        case let .pasteTextTooLong(limit, actual):
            return "Generated text item exceeded limit \(limit), actual \(actual)."
        case let .pasteTextTotalTooLong(limit, actual):
            return "Generated text total exceeded limit \(limit), actual \(actual)."
        case .emptyPasteText:
            return "Generated text must not be empty after trimming control characters."
        case let .unknownHandle(handle):
            return "Model selected unknown handle: \(handle)"
        case let .duplicateHandle(handle):
            return "Model selected duplicate handle: \(handle)"
        case .malformedSelectionObject:
            return "Model output must be an object with selected_handles or paste_items."
        }
    }
}

public enum BatchPasteItemType: String, Codable, Equatable {
    case handle
    case text
}

public struct BatchPastePlanItem: Codable, Equatable {
    public var type: BatchPasteItemType
    public var handle: String?
    public var text: String?
    public var syntheticHandle: String?

    public init(
        type: BatchPasteItemType,
        handle: String? = nil,
        text: String? = nil,
        syntheticHandle: String? = nil
    ) {
        self.type = type
        self.handle = handle
        self.text = text
        self.syntheticHandle = syntheticHandle
    }

    public var resolvedHandle: String? {
        switch type {
        case .handle:
            return handle
        case .text:
            return syntheticHandle
        }
    }

    public var textCharCount: Int {
        text?.count ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case type
        case handle
        case text
        case syntheticHandle = "synthetic_handle"
    }
}

public func assignSyntheticTextHandles(
    to items: [BatchPastePlanItem],
    prefix: String = "generated_text"
) -> [BatchPastePlanItem] {
    var nextTextIndex = 1
    var assigned = items
    for index in assigned.indices {
        guard assigned[index].type == .text else {
            continue
        }
        if assigned[index].syntheticHandle == nil || assigned[index].syntheticHandle?.isEmpty == true {
            assigned[index].syntheticHandle = "\(prefix)_\(nextTextIndex)"
            nextTextIndex += 1
        }
    }
    return assigned
}

public func parseAndValidateSelection(
    _ raw: String,
    allowedHandles: [String],
    maxGeneratedTextItemChars: Int = 4000,
    maxGeneratedTextTotalChars: Int = 8000
) throws -> [BatchPastePlanItem] {
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
          let value = try? JSONSerialization.jsonObject(with: data),
          let object = value as? [String: Any] else {
        throw BatchSelectionError.invalidJSON
    }
    guard object["selected_handles"] != nil || object["paste_items"] != nil else {
        throw BatchSelectionError.missingSelectedHandles
    }
    let allowed = Set(allowedHandles)

    if object["paste_items"] == nil {
        guard let selected = object["selected_handles"] as? [Any] else {
            throw BatchSelectionError.selectedHandlesNotStrings
        }
        var seen: Set<String> = []
        var actions: [BatchPastePlanItem] = []
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
            actions.append(BatchPastePlanItem(type: .handle, handle: handle))
        }
        return actions
    }

    guard let rawItems = object["paste_items"] else {
        throw BatchSelectionError.missingPasteItems
    }
    guard let rawItemsArray = rawItems as? [Any] else {
        throw BatchSelectionError.pasteItemsNotArray
    }

    var seen: Set<String> = []
    var actions: [BatchPastePlanItem] = []
    var generatedTotal = 0
    for rawItem in rawItemsArray {
        guard let item = rawItem as? [String: Any] else {
            throw BatchSelectionError.malformedPasteItem
        }
        guard let rawType = item["type"] as? String, let type = BatchPasteItemType(rawValue: rawType) else {
            throw BatchSelectionError.malformedPasteItemType
        }

        switch type {
        case .handle:
            guard let handle = item["handle"] as? String else {
                throw BatchSelectionError.malformedPasteHandle
            }
            guard allowed.contains(handle) else {
                throw BatchSelectionError.unknownHandle(handle)
            }
            guard !seen.contains(handle) else {
                throw BatchSelectionError.duplicateHandle(handle)
            }
            seen.insert(handle)
            actions.append(BatchPastePlanItem(type: .handle, handle: handle))
        case .text:
            guard let text = item["text"] as? String else {
                throw BatchSelectionError.malformedPasteText
            }
            let trimmedText = text.trimmingCharacters(in: .controlCharacters)
            guard !trimmedText.isEmpty else {
                throw BatchSelectionError.emptyPasteText
            }
            guard trimmedText.count <= maxGeneratedTextItemChars else {
                throw BatchSelectionError.pasteTextTooLong(
                    limit: maxGeneratedTextItemChars,
                    actual: trimmedText.count
                )
            }
            generatedTotal += trimmedText.count
            guard generatedTotal <= maxGeneratedTextTotalChars else {
                throw BatchSelectionError.pasteTextTotalTooLong(
                    limit: maxGeneratedTextTotalChars,
                    actual: generatedTotal
                )
            }
            actions.append(BatchPastePlanItem(type: .text, text: trimmedText))
        }
    }

    return actions
}

public struct ResolvedSelectionManifest: Codable, Equatable {
    public var selectedHandles: [String]
    public var pasteItems: [BatchPastePlanItem]
    public var generatedTextCharCountByHandle: [String: Int]
    public var totalGeneratedTextChars: Int
    public var items: [ResolvedSelectionItem]

    enum CodingKeys: String, CodingKey {
        case selectedHandles = "selected_handles"
        case pasteItems = "paste_items"
        case generatedTextCharCountByHandle = "generated_text_char_count_by_handle"
        case totalGeneratedTextChars = "total_generated_text_chars"
        case items
    }
}

public struct ResolvedSelectionItem: Codable, Equatable {
    public var type: BatchPasteItemType
    public var handle: String
    public var text: String?
    public var syntheticHandle: String?
    public var generatedTextCharCount: Int?
    public var sourceSnapshotID: String?
    public var sourceHandle: String?
    public var payloads: [ResolvedPayload]

    enum CodingKeys: String, CodingKey {
        case type
        case handle
        case text
        case syntheticHandle = "synthetic_handle"
        case generatedTextCharCount = "generated_text_char_count"
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
    selectedItems: [BatchPastePlanItem],
    fullRequest: BatchFullRequest
) -> ResolvedSelectionManifest {
    let itemByHandle = Dictionary(uniqueKeysWithValues: fullRequest.items.map { ($0.handle, $0) })
    let htmlPreview = URL(fileURLWithPath: fullRequest.pathBases.htmlPreview, isDirectory: true)
    let replayOutput = URL(fileURLWithPath: fullRequest.pathBases.replayOutput, isDirectory: true)

    let selectedHandles = selectedItems.compactMap(\.resolvedHandle)
    var generatedTextCharCountByHandle: [String: Int] = [:]
    var totalGeneratedTextChars = 0
    var items: [ResolvedSelectionItem] = []

    for selectedItem in selectedItems {
        switch selectedItem.type {
        case .handle:
            guard let handle = selectedItem.handle else {
                continue
            }
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
            items.append(
                ResolvedSelectionItem(
                    type: .handle,
                    handle: handle,
                    text: nil,
                    syntheticHandle: nil,
                    generatedTextCharCount: nil,
                    sourceSnapshotID: modelItem?.sourceSnapshotID,
                    sourceHandle: modelItem?.sourceHandle,
                    payloads: payloads
                )
            )
        case .text:
            guard let text = selectedItem.text else {
                continue
            }
            let syntheticHandle = selectedItem.syntheticHandle ?? "generated_text_\(generatedTextCharCountByHandle.count + 1)"
            let charCount = text.count
            let byteSize = text.utf8.count
            generatedTextCharCountByHandle[syntheticHandle] = charCount
            totalGeneratedTextChars += charCount

            items.append(
                ResolvedSelectionItem(
                    type: .text,
                    handle: syntheticHandle,
                    text: text,
                    syntheticHandle: syntheticHandle,
                    generatedTextCharCount: charCount,
                    sourceSnapshotID: nil,
                    sourceHandle: nil,
                    payloads: [
                        ResolvedPayload(
                            uti: "public.utf8-plain-text",
                            rawPath: "generated://\(syntheticHandle)/public.utf8-plain-text",
                            decodedPath: nil,
                            expectedByteSize: byteSize,
                            actualByteSize: byteSize,
                            error: nil
                        ),
                        ResolvedPayload(
                            uti: "NSStringPboardType",
                            rawPath: "generated://\(syntheticHandle)/NSStringPboardType",
                            decodedPath: nil,
                            expectedByteSize: byteSize,
                            actualByteSize: byteSize,
                            error: nil
                        ),
                    ]
                )
            )
        }
    }

    return ResolvedSelectionManifest(
        selectedHandles: selectedHandles,
        pasteItems: selectedItems,
        generatedTextCharCountByHandle: generatedTextCharCountByHandle,
        totalGeneratedTextChars: totalGeneratedTextChars,
        items: items
    )
}

public func resolveSelection(
    selectedHandles: [String],
    fullRequest: BatchFullRequest
) -> ResolvedSelectionManifest {
    let selectedItems = selectedHandles.map { BatchPastePlanItem(type: .handle, handle: $0) }
    return resolveSelection(selectedItems: selectedItems, fullRequest: fullRequest)
}
