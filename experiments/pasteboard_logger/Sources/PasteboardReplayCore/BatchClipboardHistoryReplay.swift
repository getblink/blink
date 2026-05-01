import AppKit
import Foundation

public final class BatchClipboardHistoryReplay {
    private let inputDirectory: URL
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let derivedPayloadDirectoryName = "derived-payloads"

    public init(inputDirectory: URL, outputDirectory: URL, fileManager: FileManager = .default) {
        self.inputDirectory = inputDirectory.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func run() throws -> [URL] {
        let timeline = try loadTimeline()
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try removeStaleRequestFiles()
        try removeStaleDerivedPayloads()

        var written: [URL] = []
        for snapshot in timeline {
            let request = try buildRequest(for: snapshot)
            let outputFile = outputDirectory.appendingPathComponent("\(snapshot.id).request.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(request)
            try data.write(to: outputFile, options: .atomic)
            written.append(outputFile)
        }
        return written
    }

    public func buildRequest(for snapshot: SnapshotSummary) throws -> ModelRequest {
        let snapshotDir = inputDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshot.id, isDirectory: true)
        let itemDirs = try discoverItemDirectories(snapshotDir: snapshotDir)

        var warnings: [String] = []
        if snapshot.isConcealed {
            warnings.append("concealed_content_omitted")
        } else if itemDirs.count < snapshot.itemCount {
            throw ReplayError.missingItemPayloads(
                snapshotID: snapshot.id,
                expected: snapshot.itemCount,
                found: itemDirs.count
            )
        }

        var items: [ModelItem] = []
        var runtimePayloads: [String: [RuntimePayload]] = [:]
        var handles: [String] = []

        for (emittedIndex, itemDir) in itemDirs.enumerated() {
            let payloads = try readPayloads(snapshotDir: snapshotDir, itemDir: itemDir)
            if payloads.isEmpty {
                throw ReplayError.missingItemPayloads(
                    snapshotID: snapshot.id,
                    expected: snapshot.itemCount,
                    found: emittedIndex
                )
            }

            let handle = "item_\(emittedIndex + 1)"
            handles.append(handle)
            runtimePayloads[handle] = payloads
            let embeddedImages = try extractEmbeddedImages(
                snapshotID: snapshot.id,
                sourceHandle: handle,
                payloads: payloads,
                warnings: &warnings
            )
            items.append(
                buildModelItem(
                    handle: handle,
                    snapshot: snapshot,
                    payloads: payloads,
                    embeddedImageCount: embeddedImages.detectedCount
                )
            )

            for image in embeddedImages.items {
                handles.append(image.item.handle)
                items.append(image.item)
                runtimePayloads[image.item.handle] = image.payloads
            }
        }

        return ModelRequest(
            schemaVersion: 0,
            snapshot: SnapshotMetadata(
                snapshotId: snapshot.id,
                observedAt: snapshot.observedAt,
                changeCount: snapshot.changeCount,
                sourceURL: snapshot.sourceURL.isEmpty ? nil : snapshot.sourceURL,
                renderedKind: snapshot.renderedKind
            ),
            items: items,
            allowedHandles: handles,
            runtimePayloads: runtimePayloads,
            warnings: warnings
        )
    }

    private func removeStaleRequestFiles() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.lastPathComponent.hasSuffix(".request.json") {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeStaleDerivedPayloads() throws {
        let url = outputDirectory.appendingPathComponent(derivedPayloadDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func loadTimeline() throws -> [SnapshotSummary] {
        let timelineURL = inputDirectory.appendingPathComponent("timeline.json")
        let data = try Data(contentsOf: timelineURL)
        return try JSONDecoder().decode([SnapshotSummary].self, from: data)
    }

    private func discoverItemDirectories(snapshotDir: URL) throws -> [URL] {
        let itemsDir = snapshotDir.appendingPathComponent("items", isDirectory: true)
        guard fileManager.fileExists(atPath: itemsDir.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: itemsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                    return false
                }
                return values.isDirectory == true && url.lastPathComponent.hasPrefix("item-")
            }
            .sorted { itemIndex($0.lastPathComponent) < itemIndex($1.lastPathComponent) }
    }

    private func readPayloads(snapshotDir: URL, itemDir: URL) throws -> [RuntimePayload] {
        let files = try fileManager.contentsOfDirectory(
            at: itemDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var rawFilesByIndex: [Int: URL] = [:]
        var decodedFilesByIndex: [Int: URL] = [:]

        for file in files {
            guard let parsed = parsePayloadFilename(file.lastPathComponent) else {
                continue
            }
            if parsed.isRaw {
                rawFilesByIndex[parsed.index] = file
            } else if parsed.isDecoded {
                decodedFilesByIndex[parsed.index] = file
            }
        }

        return rawFilesByIndex.keys.sorted().compactMap { index in
            guard let rawFile = rawFilesByIndex[index],
                  let parsed = parsePayloadFilename(rawFile.lastPathComponent) else {
                return nil
            }

            let fileSize = (try? rawFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let decodedFile = decodedFilesByIndex[index]
            let metadata = RepresentationMetadata(
                rawExtension: rawFile.pathExtension.isEmpty ? nil : rawFile.pathExtension,
                decodedExtension: decodedFile?.pathExtension,
                imageDimensions: imageDimensions(from: rawFile)
            )
            return RuntimePayload(
                uti: parsed.uti,
                byteSize: fileSize,
                rawPath: relativePath(from: inputDirectory, to: rawFile),
                decodedPath: decodedFile.map { relativePath(from: inputDirectory, to: $0) },
                representation: metadata
            )
        }
    }

    private func buildModelItem(
        handle: String,
        snapshot: SnapshotSummary,
        payloads: [RuntimePayload],
        embeddedImageCount: Int
    ) -> ModelItem {
        let utis = payloads.map(\.uti)
        var byteSizes: [String: Int] = [:]
        for payload in payloads {
            byteSizes[payload.uti] = payload.byteSize
        }
        let htmlText = decodedTextForUTI("public.html", payloads: payloads)
        let sourceURL = sourceURL(snapshot: snapshot, payloads: payloads)
        let imageDimensions = payloads.compactMap(\.representation.imageDimensions).first
        let previewText = previewText(payloads: payloads)

        return ModelItem(
            handle: handle,
            kind: inferKind(utis: utis),
            utis: utis,
            byteSizes: byteSizes,
            decodedTextPreview: previewText.map { oneLinePreview($0, limit: 500) },
            sourceURL: sourceURL,
            imageDimensions: imageDimensions,
            hasEmbeddedImageData: embeddedImageCount > 0 || htmlText?.range(of: "data:image/", options: .caseInsensitive) != nil,
            embeddedImageCount: utis.contains(where: isHTMLType) ? embeddedImageCount : nil,
            derivedFrom: nil,
            derivedKind: nil,
            mimeType: nil,
            sourceUTI: nil,
            sourcePath: nil
        )
    }

    private func extractEmbeddedImages(
        snapshotID: String,
        sourceHandle: String,
        payloads: [RuntimePayload],
        warnings: inout [String]
    ) throws -> EmbeddedImageExtraction {
        guard let htmlPayload = payloads.first(where: { isHTMLType($0.uti) }),
              let html = decodedText(payload: htmlPayload) else {
            return EmbeddedImageExtraction(detectedCount: 0, items: [])
        }
        let sourcePath = htmlPayload.decodedPath ?? htmlPayload.rawPath

        let references = embeddedImageReferences(in: html)
        guard !references.isEmpty else {
            return EmbeddedImageExtraction(detectedCount: 0, items: [])
        }

        let snapshotDerivedDir = outputDirectory
            .appendingPathComponent(derivedPayloadDirectoryName, isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
        try fileManager.createDirectory(at: snapshotDerivedDir, withIntermediateDirectories: true)

        var extracted: [DerivedEmbeddedImage] = []
        for (index, reference) in references.enumerated() {
            let imageNumber = index + 1
            guard let fileExtension = extensionForImageMIMEType(reference.mimeType),
                  let uti = utiForImageMIMEType(reference.mimeType) else {
                warnings.append("\(sourceHandle)_image_\(imageNumber)_unsupported_embedded_image_mime_\(reference.mimeType)")
                continue
            }

            let normalizedBase64 = reference.base64.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: normalizedBase64) else {
                warnings.append("\(sourceHandle)_image_\(imageNumber)_invalid_embedded_image_base64")
                continue
            }

            let derivedHandle = "\(sourceHandle)_image_\(imageNumber)"
            let fileURL = snapshotDerivedDir.appendingPathComponent("\(derivedHandle).\(fileExtension)")
            try data.write(to: fileURL, options: .atomic)

            guard let dimensions = imageDimensions(from: fileURL) else {
                try? fileManager.removeItem(at: fileURL)
                warnings.append("\(derivedHandle)_invalid_embedded_image_bytes")
                continue
            }
            let payload = RuntimePayload(
                uti: uti,
                byteSize: data.count,
                rawPath: relativePath(from: outputDirectory, to: fileURL),
                decodedPath: nil,
                representation: RepresentationMetadata(
                    rawExtension: fileExtension,
                    decodedExtension: nil,
                    imageDimensions: dimensions
                )
            )
            let item = ModelItem(
                handle: derivedHandle,
                kind: .image,
                utis: [uti],
                byteSizes: [uti: data.count],
                decodedTextPreview: nil,
                sourceURL: nil,
                imageDimensions: dimensions,
                hasEmbeddedImageData: false,
                embeddedImageCount: nil,
                derivedFrom: sourceHandle,
                derivedKind: "embedded_html_image",
                mimeType: reference.mimeType,
                sourceUTI: htmlPayload.uti,
                sourcePath: sourcePath
            )
            extracted.append(DerivedEmbeddedImage(item: item, payloads: [payload]))

            if let fragmentHTML = richImageFragmentHTML(for: reference) {
                let fragmentHandle = "\(sourceHandle)_image_fragment_\(imageNumber)"
                let fragmentURL = snapshotDerivedDir.appendingPathComponent("\(fragmentHandle).html")
                let fragmentData = Data(fragmentHTML.utf8)
                try fragmentData.write(to: fragmentURL, options: .atomic)
                let fragmentPayload = RuntimePayload(
                    uti: htmlPayload.uti,
                    byteSize: fragmentData.count,
                    rawPath: relativePath(from: outputDirectory, to: fragmentURL),
                    decodedPath: nil,
                    representation: RepresentationMetadata(
                        rawExtension: "html",
                        decodedExtension: nil,
                        imageDimensions: nil
                    )
                )
                let googleSlidesPayloads = try googleSlidesImageObjectPayloads(
                    sourceHandle: sourceHandle,
                    imageNumber: imageNumber,
                    fragmentHTMLPayload: fragmentPayload,
                    sourcePayloads: payloads,
                    derivedDirectory: snapshotDerivedDir,
                    warnings: &warnings
                )
                let fragmentPayloads = googleSlidesPayloads?.payloads ?? [fragmentPayload]
                let fragmentUTIs = fragmentPayloads.map(\.uti)
                let fragmentByteSizes = Dictionary(uniqueKeysWithValues: fragmentPayloads.map { ($0.uti, $0.byteSize) })
                let fragmentItem = ModelItem(
                    handle: fragmentHandle,
                    kind: .html,
                    utis: fragmentUTIs,
                    byteSizes: fragmentByteSizes,
                    decodedTextPreview: oneLinePreview(redactDataURLs(in: fragmentHTML), limit: 500),
                    sourceURL: nil,
                    imageDimensions: dimensions,
                    hasEmbeddedImageData: true,
                    embeddedImageCount: 1,
                    derivedFrom: sourceHandle,
                    derivedKind: googleSlidesPayloads?.derivedKind ?? "embedded_html_image_fragment",
                    mimeType: reference.mimeType,
                    sourceUTI: htmlPayload.uti,
                    sourcePath: sourcePath
                )
                extracted.append(DerivedEmbeddedImage(item: fragmentItem, payloads: fragmentPayloads))
            }
        }

        return EmbeddedImageExtraction(detectedCount: references.count, items: extracted)
    }

    private func googleSlidesImageObjectPayloads(
        sourceHandle: String,
        imageNumber: Int,
        fragmentHTMLPayload: RuntimePayload,
        sourcePayloads: [RuntimePayload],
        derivedDirectory: URL,
        warnings: inout [String]
    ) throws -> GoogleSlidesImageObjectPayloads? {
        guard let customPayload = sourcePayloads.first(where: { $0.uti == chromiumWebCustomDataUTI }) else {
            return nil
        }
        let customURL = inputDirectory.appendingPathComponent(customPayload.rawPath)
        guard let customData = try? Data(contentsOf: customURL),
              let customEntries = parseChromiumWebCustomData(customData) else {
            warnings.append("\(sourceHandle)_image_fragment_\(imageNumber)_invalid_chromium_web_custom_data")
            return nil
        }

        guard let fragment = filteredGoogleSlidesImageObjectCustomData(
            entries: customEntries,
            imageIndex: imageNumber - 1
        ) else {
            return nil
        }

        let filteredCustomData = buildChromiumWebCustomData(entries: fragment.entries)
        let customFilename = "\(sourceHandle)_image_fragment_\(imageNumber).web-custom-data.bin"
        let filteredCustomURL = derivedDirectory.appendingPathComponent(customFilename)
        try filteredCustomData.write(to: filteredCustomURL, options: .atomic)

        var payloads = [fragmentHTMLPayload]
        if let sourceRFHToken = sourcePayloads.first(where: { $0.uti == chromiumSourceRFHTokenUTI }) {
            payloads.append(sourceRFHToken)
        }
        payloads.append(
            RuntimePayload(
                uti: chromiumWebCustomDataUTI,
                byteSize: filteredCustomData.count,
                rawPath: relativePath(from: outputDirectory, to: filteredCustomURL),
                decodedPath: nil,
                representation: RepresentationMetadata(
                    rawExtension: "bin",
                    decodedExtension: nil,
                    imageDimensions: nil
                )
            )
        )
        if let sourceURL = sourcePayloads.first(where: { $0.uti == chromiumSourceURLUTI }) {
            payloads.append(sourceURL)
        }

        return GoogleSlidesImageObjectPayloads(
            derivedKind: "google_slides_image_object_fragment",
            payloads: payloads
        )
    }

    private func previewText(payloads: [RuntimePayload]) -> String? {
        let preferredUTIs = [
            "public.utf8-plain-text",
            "public.text",
            "NSStringPboardType",
            "public.url",
            "public.file-url",
            "org.chromium.source-url"
        ]
        for uti in preferredUTIs {
            if let text = decodedTextForUTI(uti, payloads: payloads) {
                return redactDataURLs(in: text)
            }
        }
        for payload in payloads {
            if let text = decodedText(payload: payload) {
                return redactDataURLs(in: text)
            }
        }
        if let html = decodedTextForUTI("public.html", payloads: payloads) {
            return redactDataURLs(in: html)
        }
        return nil
    }

    private func decodedTextForUTI(_ uti: String, payloads: [RuntimePayload]) -> String? {
        payloads.first { $0.uti == uti }.flatMap(decodedText(payload:))
    }

    private func decodedText(payload: RuntimePayload) -> String? {
        guard let decodedPath = payload.decodedPath else {
            return nil
        }
        let url = inputDirectory.appendingPathComponent(decodedPath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func sourceURL(snapshot: SnapshotSummary, payloads: [RuntimePayload]) -> String? {
        if !snapshot.sourceURL.isEmpty {
            return snapshot.sourceURL
        }
        return decodedTextForUTI("org.chromium.source-url", payloads: payloads)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferKind(utis: [String]) -> ModelItem.Kind {
        if utis.contains(where: isHTMLType) {
            return .html
        }
        if utis.contains(where: isImageType) {
            return .image
        }
        if utis.contains(where: isFileType) {
            return .file
        }
        if utis.contains(where: isTextType) {
            return .text
        }
        return .unknown
    }
}

public enum ReplayError: Error, Equatable, LocalizedError {
    case missingItemPayloads(snapshotID: String, expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case let .missingItemPayloads(snapshotID, expected, found):
            return "Snapshot \(snapshotID) expected \(expected) item payload folder(s), found \(found)"
        }
    }
}

public struct SnapshotSummary: Codable {
    public var id: String
    public var observedAt: String
    public var changeCount: Int
    public var renderedKind: String
    public var itemCount: Int
    public var htmlBytes: Int
    public var plainTextBytes: Int
    public var types: [String]
    public var sourceURL: String
    public var hasEmbeddedImage: Bool
    public var isConcealed: Bool
    public var preview: String

    public init(
        id: String,
        observedAt: String,
        changeCount: Int,
        renderedKind: String,
        itemCount: Int,
        htmlBytes: Int,
        plainTextBytes: Int,
        types: [String],
        sourceURL: String,
        hasEmbeddedImage: Bool,
        isConcealed: Bool,
        preview: String
    ) {
        self.id = id
        self.observedAt = observedAt
        self.changeCount = changeCount
        self.renderedKind = renderedKind
        self.itemCount = itemCount
        self.htmlBytes = htmlBytes
        self.plainTextBytes = plainTextBytes
        self.types = types
        self.sourceURL = sourceURL
        self.hasEmbeddedImage = hasEmbeddedImage
        self.isConcealed = isConcealed
        self.preview = preview
    }
}

public struct ModelRequest: Codable, Equatable {
    public var schemaVersion: Int
    public var snapshot: SnapshotMetadata
    public var items: [ModelItem]
    public var allowedHandles: [String]
    public var runtimePayloads: [String: [RuntimePayload]]
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshot
        case items
        case allowedHandles = "allowed_handles"
        case runtimePayloads = "runtime_payloads"
        case warnings
    }
}

public struct SnapshotMetadata: Codable, Equatable {
    public var snapshotId: String
    public var observedAt: String
    public var changeCount: Int
    public var sourceURL: String?
    public var renderedKind: String

    enum CodingKeys: String, CodingKey {
        case snapshotId = "snapshot_id"
        case observedAt = "observed_at"
        case changeCount = "change_count"
        case sourceURL = "source_url"
        case renderedKind = "rendered_kind"
    }
}

public struct ModelItem: Codable, Equatable {
    public enum Kind: String, Codable {
        case html
        case text
        case image
        case file
        case unknown
    }

    public var handle: String
    public var kind: Kind
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
    }
}

public struct RuntimePayload: Codable, Equatable {
    public var uti: String
    public var byteSize: Int
    public var rawPath: String
    public var decodedPath: String?
    public var representation: RepresentationMetadata

    enum CodingKeys: String, CodingKey {
        case uti
        case byteSize = "byte_size"
        case rawPath = "raw_path"
        case decodedPath = "decoded_path"
        case representation
    }
}

public struct RepresentationMetadata: Codable, Equatable {
    public var rawExtension: String?
    public var decodedExtension: String?
    public var imageDimensions: ImageDimensions?

    enum CodingKeys: String, CodingKey {
        case rawExtension = "raw_extension"
        case decodedExtension = "decoded_extension"
        case imageDimensions = "image_dimensions"
    }
}

public struct ImageDimensions: Codable, Equatable {
    public var width: Int
    public var height: Int
}

struct PayloadFilename {
    var index: Int
    var uti: String
    var isRaw: Bool
    var isDecoded: Bool
}

struct EmbeddedImageReference {
    var mimeType: String
    var base64: String
    var imageTag: String
}

struct EmbeddedImageExtraction {
    var detectedCount: Int
    var items: [DerivedEmbeddedImage]
}

struct DerivedEmbeddedImage {
    var item: ModelItem
    var payloads: [RuntimePayload]
}

struct GoogleSlidesImageObjectPayloads {
    var derivedKind: String
    var payloads: [RuntimePayload]
}

struct ChromiumWebCustomDataEntry: Equatable {
    var name: String
    var value: String
}

let chromiumWebCustomDataUTI = "org.chromium.web-custom-data"
let chromiumSourceRFHTokenUTI = "org.chromium.internal.source-rfh-token"
let chromiumSourceURLUTI = "org.chromium.source-url"
let googleDocsDrawingsObjectUTI = "application/x-vnd.google-docs-drawings-object+wrapped"
let googleDocsImageClipUTI = "application/x-vnd.google-docs-image-clip+wrapped"
let googleDocsInternalClipIDUTI = "application/x-vnd.google-docs-internal-clip-id"

func parsePayloadFilename(_ filename: String) -> PayloadFilename? {
    guard filename.count > 3,
          let dashIndex = filename.firstIndex(of: "-"),
          let index = Int(filename[..<dashIndex]) else {
        return nil
    }

    let rest = filename[filename.index(after: dashIndex)...]
    if let rawRange = rest.range(of: ".raw.") {
        return PayloadFilename(index: index, uti: String(rest[..<rawRange.lowerBound]), isRaw: true, isDecoded: false)
    }
    if rest.hasSuffix(".decoded.txt") {
        let uti = rest.dropLast(".decoded.txt".count)
        return PayloadFilename(index: index, uti: String(uti), isRaw: false, isDecoded: true)
    }
    return nil
}

func parseChromiumWebCustomData(_ data: Data) -> [ChromiumWebCustomDataEntry]? {
    var offset = 0
    guard let totalByteCount = readLittleEndianUInt32(data, offset: &offset),
          totalByteCount == data.count - 4,
          let entryCount = readLittleEndianUInt32(data, offset: &offset) else {
        return nil
    }

    var entries: [ChromiumWebCustomDataEntry] = []
    for _ in 0..<entryCount {
        guard let name = readChromiumCustomDataString(data, offset: &offset),
              let value = readChromiumCustomDataString(data, offset: &offset) else {
            return nil
        }
        entries.append(ChromiumWebCustomDataEntry(name: name, value: value))
    }
    guard offset == data.count else {
        return nil
    }
    return entries
}

func buildChromiumWebCustomData(entries: [ChromiumWebCustomDataEntry]) -> Data {
    var data = Data(count: 4)
    appendLittleEndianUInt32(UInt32(entries.count), to: &data)
    for entry in entries {
        appendChromiumCustomDataString(entry.name, to: &data)
        appendChromiumCustomDataString(entry.value, to: &data)
    }
    writeLittleEndianUInt32(UInt32(data.count - 4), to: &data, at: 0)
    return data
}

func filteredGoogleSlidesImageObjectCustomData(
    entries: [ChromiumWebCustomDataEntry],
    imageIndex: Int
) -> (entries: [ChromiumWebCustomDataEntry], shapeID: String, blobID: String)? {
    guard imageIndex >= 0,
          let drawingsValue = entries.first(where: { $0.name == googleDocsDrawingsObjectUTI })?.value,
          let drawingsOuter = jsonObject(drawingsValue),
          let drawingsDataString = drawingsOuter["data"] as? String,
          var drawingsInner = jsonObject(drawingsDataString),
          let imageClipValue = entries.first(where: { $0.name == googleDocsImageClipUTI })?.value,
          let imageClipOuter = jsonObject(imageClipValue),
          let imageClipDataString = imageClipOuter["data"] as? String,
          var imageClipInner = jsonObject(imageClipDataString) else {
        return nil
    }

    let imageObjects = googleSlidesImageObjects(in: drawingsInner)
    guard imageIndex < imageObjects.count else {
        return nil
    }
    let selected = imageObjects[imageIndex]
    drawingsInner["resolved"] = filterGoogleSlidesRows(drawingsInner["resolved"], shapeID: selected.shapeID)
    drawingsInner["unresolved"] = filterGoogleSlidesRows(drawingsInner["unresolved"], shapeID: selected.shapeID)
    drawingsInner["autotext_content"] = [:] as [String: Any]

    var filteredDrawingsOuter = drawingsOuter
    guard let filteredDrawingsInnerData = compactJSONData(drawingsInner),
          let filteredDrawingsInnerString = String(data: filteredDrawingsInnerData, encoding: .utf8) else {
        return nil
    }
    filteredDrawingsOuter["data"] = filteredDrawingsInnerString

    for key in ["image_urls", "placeholder_ids", "cosmo_ids"] {
        if let values = imageClipInner[key] as? [String: Any] {
            imageClipInner[key] = values.filter { $0.key == selected.blobID }
        }
    }

    var filteredImageClipOuter = imageClipOuter
    guard let filteredImageClipInnerData = compactJSONData(imageClipInner),
          let filteredImageClipInnerString = String(data: filteredImageClipInnerData, encoding: .utf8),
          let filteredDrawingsOuterData = compactJSONData(filteredDrawingsOuter),
          let filteredDrawingsOuterString = String(data: filteredDrawingsOuterData, encoding: .utf8) else {
        return nil
    }
    filteredImageClipOuter["data"] = filteredImageClipInnerString
    guard let filteredImageClipOuterData = compactJSONData(filteredImageClipOuter),
          let filteredImageClipOuterString = String(data: filteredImageClipOuterData, encoding: .utf8) else {
        return nil
    }

    var filteredEntries = [
        ChromiumWebCustomDataEntry(name: googleDocsDrawingsObjectUTI, value: filteredDrawingsOuterString),
        ChromiumWebCustomDataEntry(name: googleDocsImageClipUTI, value: filteredImageClipOuterString)
    ]
    if let internalClipID = entries.first(where: { $0.name == googleDocsInternalClipIDUTI }) {
        filteredEntries.append(internalClipID)
    }
    return (filteredEntries, selected.shapeID, selected.blobID)
}

func googleSlidesImageObjects(in drawingsInner: [String: Any]) -> [(shapeID: String, blobID: String)] {
    guard let rows = drawingsInner["resolved"] as? [Any] else {
        return []
    }
    var objects: [(shapeID: String, blobID: String)] = []
    var seenShapeIDs = Set<String>()
    for rowValue in rows {
        guard let row = rowValue as? [Any],
              row.count > 4,
              numberValue(row[0]) == 3,
              let shapeID = row[1] as? String,
              let properties = row[4] as? [Any],
              let blobID = googleSlidesBlobID(in: properties),
              !seenShapeIDs.contains(shapeID) else {
            continue
        }
        seenShapeIDs.insert(shapeID)
        objects.append((shapeID, blobID))
    }
    return objects
}

func filterGoogleSlidesRows(_ value: Any?, shapeID: String) -> [[Any]] {
    guard let rows = value as? [Any] else {
        return []
    }
    return rows.compactMap { rowValue in
        guard let row = rowValue as? [Any],
              row.count > 1,
              row[1] as? String == shapeID else {
            return nil
        }
        return row
    }
}

func googleSlidesBlobID(in properties: [Any]) -> String? {
    var index = 0
    while index + 1 < properties.count {
        if numberValue(properties[index]) == 49,
           let blobID = properties[index + 1] as? String {
            return blobID
        }
        index += 2
    }
    return nil
}

func jsonObject(_ value: String) -> [String: Any]? {
    guard let data = value.data(using: .utf8) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func compactJSONData(_ value: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func numberValue(_ value: Any) -> Int? {
    (value as? NSNumber)?.intValue
}

func readLittleEndianUInt32(_ data: Data, offset: inout Int) -> Int? {
    guard offset + 4 <= data.count else {
        return nil
    }
    let value = Int(data[offset])
        | (Int(data[offset + 1]) << 8)
        | (Int(data[offset + 2]) << 16)
        | (Int(data[offset + 3]) << 24)
    offset += 4
    return value
}

func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

func writeLittleEndianUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

func readChromiumCustomDataString(_ data: Data, offset: inout Int) -> String? {
    guard let codeUnitCount = readLittleEndianUInt32(data, offset: &offset) else {
        return nil
    }
    let byteCount = codeUnitCount * 2
    guard byteCount >= 0,
          offset + byteCount <= data.count else {
        return nil
    }
    let stringData = data.subdata(in: offset..<(offset + byteCount))
    offset = alignChromiumCustomDataOffset(offset + byteCount)
    return String(data: stringData, encoding: .utf16LittleEndian)
}

func appendChromiumCustomDataString(_ value: String, to data: inout Data) {
    appendLittleEndianUInt32(UInt32(value.utf16.count), to: &data)
    for codeUnit in value.utf16 {
        data.append(UInt8(codeUnit & 0xff))
        data.append(UInt8((codeUnit >> 8) & 0xff))
    }
    while data.count % 4 != 0 {
        data.append(0)
    }
}

func alignChromiumCustomDataOffset(_ offset: Int) -> Int {
    (offset + 3) & ~3
}

func itemIndex(_ value: String) -> Int {
    guard value.hasPrefix("item-"),
          let index = Int(value.dropFirst("item-".count)) else {
        return Int.max
    }
    return index
}

func relativePath(from base: URL, to file: URL) -> String {
    let basePath = base.standardizedFileURL.path
    let filePath = file.standardizedFileURL.path
    if filePath.hasPrefix(basePath + "/") {
        return String(filePath.dropFirst(basePath.count + 1))
    }
    return file.lastPathComponent
}

func oneLinePreview(_ value: String, limit: Int) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    guard singleLine.count > limit else {
        return singleLine
    }
    return "\(singleLine.prefix(limit))..."
}

func redactDataURLs(in value: String) -> String {
    value.replacingOccurrences(
        of: #"data:[^"'\s>)<]+"#,
        with: "[redacted-data-url]",
        options: [.regularExpression, .caseInsensitive]
    )
}

func embeddedImageReferences(in html: String) -> [EmbeddedImageReference] {
    let tagPattern = #"<img\b[^>]*\bsrc\s*=\s*(['"])(data:image/([A-Za-z0-9.+-]+);base64,([^'"]+))\1[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
        return []
    }
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    return regex.matches(in: html, options: [], range: nsRange).compactMap { match in
        guard let tagRange = Range(match.range(at: 0), in: html),
              let subtypeRange = Range(match.range(at: 3), in: html),
              let base64Range = Range(match.range(at: 4), in: html) else {
            return nil
        }
        let subtype = html[subtypeRange].lowercased()
        return EmbeddedImageReference(
            mimeType: "image/\(subtype)",
            base64: String(html[base64Range]),
            imageTag: String(html[tagRange])
        )
    }
}

func richImageFragmentHTML(for reference: EmbeddedImageReference) -> String? {
    let tag = reference.imageTag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard tag.range(of: #"^<img\b[^>]*>$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
        return nil
    }
    let metadataPattern = #"\b(width|height|title|alt|aria-label|data-[A-Za-z0-9_-]+)\s*="#
    guard tag.range(of: metadataPattern, options: [.regularExpression, .caseInsensitive]) != nil else {
        return nil
    }
    return """
    <!doctype html>
    <html>
    <body>\(tag)</body>
    </html>
    """
}

func extensionForImageMIMEType(_ mimeType: String) -> String? {
    switch mimeType.lowercased() {
    case "image/png":
        return "png"
    case "image/jpeg", "image/jpg":
        return "jpg"
    case "image/tiff":
        return "tiff"
    case "image/gif":
        return "gif"
    default:
        return nil
    }
}

func utiForImageMIMEType(_ mimeType: String) -> String? {
    switch mimeType.lowercased() {
    case "image/png":
        return "public.png"
    case "image/jpeg", "image/jpg":
        return "public.jpeg"
    case "image/tiff":
        return "public.tiff"
    case "image/gif":
        return "com.compuserve.gif"
    default:
        return nil
    }
}

func imageDimensions(from file: URL) -> ImageDimensions? {
    guard isImageExtension(file.pathExtension),
          let image = NSImage(contentsOf: file) else {
        return nil
    }
    if let representation = image.representations.first {
        return ImageDimensions(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
    return ImageDimensions(width: Int(image.size.width), height: Int(image.size.height))
}

func isHTMLType(_ uti: String) -> Bool {
    uti == "public.html" || uti == "NSHTMLPboardType"
}

func isTextType(_ uti: String) -> Bool {
    uti == "public.utf8-plain-text"
        || uti == "public.utf16-external-plain-text"
        || uti == "public.text"
        || uti == "NSStringPboardType"
        || uti == "public.url"
        || uti == "org.chromium.source-url"
}

func isImageType(_ uti: String) -> Bool {
    uti == "public.png"
        || uti == "public.jpeg"
        || uti == "public.jpg"
        || uti == "public.tiff"
        || uti == "NSPasteboardTypePNG"
        || uti == "NSTIFFPboardType"
}

func isFileType(_ uti: String) -> Bool {
    uti == "public.file-url"
        || uti == "public.utf8-tagged-file-url"
        || uti == "NSFilenamesPboardType"
}

func isImageExtension(_ value: String) -> Bool {
    switch value.lowercased() {
    case "png", "jpg", "jpeg", "tiff", "tif", "gif":
        return true
    default:
        return false
    }
}
