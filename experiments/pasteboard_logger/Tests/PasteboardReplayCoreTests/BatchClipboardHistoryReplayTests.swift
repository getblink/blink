import AppKit
import XCTest
@testable import PasteboardReplayCore

final class BatchClipboardHistoryReplayTests: XCTestCase {
    func testPlainTextSnapshotEmitsOneTextItem() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "plain",
            itemCount: 1,
            renderedKind: "plain-text",
            plainTextBytes: 11,
            types: ["public.utf8-plain-text"]
        )
        try writePayload(root: root, snapshotID: "plain", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("hello world".utf8), decoded: "hello world")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.schemaVersion, 0)
        XCTAssertEqual(request.snapshot.snapshotId, "plain")
        XCTAssertEqual(request.items.count, 1)
        XCTAssertEqual(request.items[0].handle, "item_1")
        XCTAssertEqual(request.items[0].kind, .text)
        XCTAssertEqual(request.items[0].decodedTextPreview, "hello world")
        XCTAssertEqual(request.allowedHandles, ["item_1"])
        XCTAssertEqual(request.runtimePayloads["item_1"]?.first?.rawPath, "snapshots/plain/items/item-0/00-public.utf8-plain-text.raw.bin")
    }

    func testHTMLSnapshotIncludesTextPreviewAndEmbeddedImageFlag() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "html",
            renderedKind: "html",
            htmlBytes: 49,
            types: ["public.html", "public.utf8-plain-text"],
            sourceURL: "https://example.com"
        )
        let html = "<p>Hello</p><img src=\"data:image/png;base64,AAAA\">"
        try writePayload(root: root, snapshotID: "html", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")
        try writePayload(root: root, snapshotID: "html", itemIndex: 0, typeIndex: 1, uti: "public.utf8-plain-text", raw: Data("Hello".utf8), decoded: "Hello")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items[0].kind, .html)
        XCTAssertEqual(request.items[0].decodedTextPreview, "Hello")
        XCTAssertEqual(request.items[0].sourceURL, "https://example.com")
        XCTAssertTrue(request.items[0].hasEmbeddedImageData)
    }

    func testHTMLEmbeddedPNGCreatesOriginalAndDerivedImageItem() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = "<h1>Slide</h1><img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshot(root: root, id: "embedded-one", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "embedded-one", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1", "item_1_image_1"])
        XCTAssertEqual(request.allowedHandles, ["item_1", "item_1_image_1"])
        XCTAssertEqual(request.items[0].kind, .html)
        XCTAssertEqual(request.items[0].embeddedImageCount, 1)
        XCTAssertTrue(request.items[0].hasEmbeddedImageData)
        XCTAssertEqual(request.items[1].kind, .image)
        XCTAssertEqual(request.items[1].derivedFrom, "item_1")
        XCTAssertEqual(request.items[1].derivedKind, "embedded_html_image")
        XCTAssertEqual(request.items[1].mimeType, "image/png")
        XCTAssertEqual(request.items[1].sourceUTI, "public.html")
        XCTAssertEqual(request.items[1].sourcePath, "snapshots/embedded-one/items/item-0/00-public.html.decoded.txt")
        XCTAssertEqual(request.items[1].imageDimensions, ImageDimensions(width: 4, height: 5))
        XCTAssertEqual(request.runtimePayloads["item_1_image_1"]?.first?.rawPath, "derived-payloads/embedded-one/item_1_image_1.png")
        XCTAssertNil(request.runtimePayloads["item_1_image_fragment_1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests/derived-payloads/embedded-one/item_1_image_1.png").path))
    }

    func testHTMLEmbeddedPNGWithDisplayMetadataCreatesRichImageFragmentItem() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = """
        <section><img width="40" height="50" title="Profile crop" src="data:image/png;base64,\(png.base64EncodedString())"></section>
        """
        try writeSnapshot(root: root, id: "embedded-fragment", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "embedded-fragment", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1", "item_1_image_1", "item_1_image_fragment_1"])
        XCTAssertEqual(request.allowedHandles, ["item_1", "item_1_image_1", "item_1_image_fragment_1"])
        XCTAssertEqual(request.items[2].kind, .html)
        XCTAssertEqual(request.items[2].derivedFrom, "item_1")
        XCTAssertEqual(request.items[2].derivedKind, "embedded_html_image_fragment")
        XCTAssertEqual(request.items[2].sourceUTI, "public.html")
        XCTAssertEqual(request.items[2].imageDimensions, ImageDimensions(width: 4, height: 5))
        XCTAssertEqual(request.runtimePayloads["item_1_image_fragment_1"]?.first?.uti, "public.html")
        XCTAssertEqual(request.runtimePayloads["item_1_image_fragment_1"]?.first?.rawPath, "derived-payloads/embedded-fragment/item_1_image_fragment_1.html")
        XCTAssertTrue(request.items[2].decodedTextPreview?.contains("[redacted-data-url]") ?? false)
        XCTAssertFalse(request.items[2].decodedTextPreview?.contains("data:image") ?? true)
    }

    func testEmbeddedImageVariantsShareVisualMetadata() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = """
        <section><img width="40" height="50" title="Profile crop" src="data:image/png;base64,\(png.base64EncodedString())"></section>
        """
        try writeSnapshot(root: root, id: "visual-fragment", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "visual-fragment", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root, visualTags: ["person", "portrait", "face"]).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1", "item_1_image_1", "item_1_image_fragment_1"])
        XCTAssertEqual(request.items[1].visualTagStatus, "ok")
        XCTAssertEqual(request.items[1].visualTags.map(\.label), ["person", "portrait", "face"])
        XCTAssertEqual(request.items[1].visualSummary, "visual tags: person, portrait, face")
        XCTAssertEqual(request.items[2].visualTags, request.items[1].visualTags)
        XCTAssertEqual(request.items[2].visualSummary, request.items[1].visualSummary)
        XCTAssertEqual(request.items[2].visualTagStatus, request.items[1].visualTagStatus)
    }

    func testGoogleSlidesCustomDataCreatesFilteredImageObjectFragment() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = """
        <section><img width="40" height="40" title="Profile crop" src="data:image/png;base64,\(png.base64EncodedString())"></section>
        """
        let shapeID = "g-image"
        let blobID = "s-blob-v1-IMAGE-test"
        let customData = googleSlidesCustomData(shapeID: shapeID, blobID: blobID)
        try writeSnapshot(
            root: root,
            id: "google-fragment",
            renderedKind: "html",
            types: [
                "public.html",
                "org.chromium.internal.source-rfh-token",
                "org.chromium.web-custom-data",
                "org.chromium.source-url"
            ]
        )
        try writePayload(root: root, snapshotID: "google-fragment", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")
        try writePayload(root: root, snapshotID: "google-fragment", itemIndex: 0, typeIndex: 1, uti: "org.chromium.internal.source-rfh-token", raw: Data([1, 2, 3]), rawExtension: "bin")
        try writePayload(root: root, snapshotID: "google-fragment", itemIndex: 0, typeIndex: 2, uti: "org.chromium.web-custom-data", raw: customData, rawExtension: "bin")
        try writePayload(root: root, snapshotID: "google-fragment", itemIndex: 0, typeIndex: 3, uti: "org.chromium.source-url", raw: Data("https://docs.google.com/presentation/d/test".utf8), rawExtension: "bin")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1", "item_1_image_1", "item_1_image_fragment_1"])
        XCTAssertEqual(request.items[2].derivedKind, "google_slides_image_object_fragment")
        XCTAssertEqual(request.items[2].utis, [
            "public.html",
            "org.chromium.internal.source-rfh-token",
            "org.chromium.web-custom-data",
            "org.chromium.source-url"
        ])
        let payloads = try XCTUnwrap(request.runtimePayloads["item_1_image_fragment_1"])
        XCTAssertEqual(payloads.map(\.uti), request.items[2].utis)
        XCTAssertEqual(payloads[0].rawPath, "derived-payloads/google-fragment/item_1_image_fragment_1.html")
        XCTAssertEqual(payloads[2].rawPath, "derived-payloads/google-fragment/item_1_image_fragment_1.web-custom-data.bin")

        let filteredCustomURL = root.appendingPathComponent("requests/\(payloads[2].rawPath)")
        let filteredEntries = try XCTUnwrap(parseChromiumWebCustomData(Data(contentsOf: filteredCustomURL)))
        XCTAssertEqual(filteredEntries.map(\.name), [
            googleDocsDrawingsObjectUTI,
            googleDocsImageClipUTI,
            googleDocsInternalClipIDUTI
        ])
        let filteredDrawings = try XCTUnwrap(jsonObject(try XCTUnwrap(jsonObject(filteredEntries[0].value)?["data"] as? String)))
        let resolvedRows = try XCTUnwrap(filteredDrawings["resolved"] as? [[Any]])
        XCTAssertEqual(resolvedRows.count, 2)
        XCTAssertTrue(resolvedRows.allSatisfy { $0.count > 1 && ($0[1] as? String) == shapeID })
        let filteredImageClip = try XCTUnwrap(jsonObject(try XCTUnwrap(jsonObject(filteredEntries[1].value)?["data"] as? String)))
        XCTAssertEqual((filteredImageClip["image_urls"] as? [String: String])?[blobID], "https://example.com/image.png")
        XCTAssertNil((filteredImageClip["image_urls"] as? [String: String])?["s-blob-v1-IMAGE-other"])
    }

    func testHTMLMultipleEmbeddedImagesPreservesSourceOrderAndStableHandles() throws {
        let root = try makeTempDirectory()
        let png1 = try pngData(width: 2, height: 3)
        let png2 = try pngData(width: 6, height: 7)
        let html = """
        <img src="data:image/png;base64,\(png1.base64EncodedString())">
        <p>middle</p>
        <img src="data:image/png;base64,\(png2.base64EncodedString())">
        """
        try writeSnapshot(root: root, id: "embedded-many", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "embedded-many", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1", "item_1_image_1", "item_1_image_2"])
        XCTAssertEqual(request.items[0].embeddedImageCount, 2)
        XCTAssertEqual(request.items[1].imageDimensions, ImageDimensions(width: 2, height: 3))
        XCTAssertEqual(request.items[2].imageDimensions, ImageDimensions(width: 6, height: 7))
        XCTAssertEqual(request.runtimePayloads["item_1_image_1"]?.first?.rawPath, "derived-payloads/embedded-many/item_1_image_1.png")
        XCTAssertEqual(request.runtimePayloads["item_1_image_2"]?.first?.rawPath, "derived-payloads/embedded-many/item_1_image_2.png")
    }

    func testHTMLWithPlainTextAndEmbeddedImageKeepsTextPreviewOnOriginalItem() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 1, height: 1)
        let html = "<p>HTML copy</p><img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshot(root: root, id: "embedded-with-text", renderedKind: "html", types: ["public.html", "public.utf8-plain-text"])
        try writePayload(root: root, snapshotID: "embedded-with-text", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")
        try writePayload(root: root, snapshotID: "embedded-with-text", itemIndex: 0, typeIndex: 1, uti: "public.utf8-plain-text", raw: Data("Plain copy".utf8), decoded: "Plain copy")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items[0].decodedTextPreview, "Plain copy")
        XCTAssertEqual(request.items[1].handle, "item_1_image_1")
    }

    func testHTMLOnlyEmbeddedImagePreviewRedactsDataURL() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "html-only",
            renderedKind: "html",
            htmlBytes: 120,
            types: ["public.html"]
        )
        let html = "<img src=\"data:image/png;base64,AAAASECRETBBBB\"><p>Slide image</p>"
        try writePayload(root: root, snapshotID: "html-only", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items[0].kind, .html)
        XCTAssertTrue(request.items[0].hasEmbeddedImageData)
        XCTAssertEqual(request.items[0].decodedTextPreview, "<img src=\"[redacted-data-url]\"><p>Slide image</p>")
        XCTAssertFalse(request.items[0].decodedTextPreview?.contains("AAAASECRETBBBB") ?? true)
        XCTAssertFalse(request.items[0].decodedTextPreview?.contains("data:image") ?? true)
    }

    func testHTMLOnlyEmbeddedImageDoesNotLeakBase64InRequestJSON() throws {
        let root = try makeTempDirectory()
        let marker = "AAAASECRETBBBB"
        let html = "<img src=\"data:image/png;base64,\(marker)\"><p>Slide image</p>"
        try writeSnapshot(root: root, id: "html-only-redacted", renderedKind: "html", htmlBytes: html.count, types: ["public.html"])
        try writePayload(root: root, snapshotID: "html-only-redacted", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertFalse(json.contains(marker))
        XCTAssertFalse(json.contains("data:image"))
        XCTAssertEqual(request.items[0].decodedTextPreview, "<img src=\"[redacted-data-url]\"><p>Slide image</p>")
    }

    func testInvalidOrUnsupportedEmbeddedImageWarnsAndDoesNotCrash() throws {
        let root = try makeTempDirectory()
        let fakePNG = Data("not an image".utf8).base64EncodedString()
        let html = """
        <img src="data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=">
        <img src="data:image/png;base64,not-valid-base64!!!!">
        <img src="data:image/png;base64,\(fakePNG)">
        """
        try writeSnapshot(root: root, id: "embedded-bad", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "embedded-bad", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items.map(\.handle), ["item_1"])
        XCTAssertEqual(request.items[0].embeddedImageCount, 3)
        XCTAssertEqual(request.warnings, [
            "item_1_image_1_unsupported_embedded_image_mime_image/svg+xml",
            "item_1_image_2_invalid_embedded_image_base64",
            "item_1_image_3_invalid_embedded_image_bytes"
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests/derived-payloads/embedded-bad/item_1_image_3.png").path))
    }

    func testImageSnapshotIncludesDimensionsAndPayloadMetadata() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 3, height: 2)
        try writeSnapshot(
            root: root,
            id: "image",
            renderedKind: "image",
            types: ["public.png"]
        )
        try writePayload(root: root, snapshotID: "image", itemIndex: 0, typeIndex: 0, uti: "public.png", raw: png, rawExtension: "png")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items[0].kind, .image)
        XCTAssertEqual(request.items[0].imageDimensions, ImageDimensions(width: 3, height: 2))
        XCTAssertEqual(request.runtimePayloads["item_1"]?.first?.byteSize, png.count)
        XCTAssertEqual(request.runtimePayloads["item_1"]?.first?.representation.rawExtension, "png")
    }

    func testImageClassifierCachesByImageBytes() throws {
        let root = try makeTempDirectory()
        let image = root.appendingPathComponent("image.png")
        try pngData(width: 3, height: 2).write(to: image)
        let cache = root.appendingPathComponent("batch-clipboard-history/image-tags", isDirectory: true)
        var classifyCount = 0
        let classifier = ImageContentClassifier(cacheDirectory: cache) { _ in
            classifyCount += 1
            return self.visualMetadata(labels: ["photo", "person"])
        }

        let first = classifier.classify(imageURL: image)
        let secondClassifier = ImageContentClassifier(cacheDirectory: cache) { _ in
            XCTFail("Expected second classifier to reuse cached image tags")
            return self.visualMetadata(labels: ["wrong"])
        }
        let second = secondClassifier.classify(imageURL: image)

        XCTAssertEqual(first.visualTags.map(\.label), ["photo", "person"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(classifyCount, 1)
        let cachedFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertEqual(cachedFiles.filter { $0.pathExtension == "json" }.count, 1)
    }

    func testImageClassifierDoesNotCacheTransientErrors() throws {
        enum TestError: Error {
            case transient
        }

        let root = try makeTempDirectory()
        let image = root.appendingPathComponent("image.png")
        try pngData(width: 3, height: 2).write(to: image)
        let cache = root.appendingPathComponent("batch-clipboard-history/image-tags", isDirectory: true)
        let failingClassifier = ImageContentClassifier(cacheDirectory: cache) { _ in
            throw TestError.transient
        }

        let failed = failingClassifier.classify(imageURL: image)
        XCTAssertEqual(failed.visualTagStatus, "error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))

        var recoveryCount = 0
        let recoveryClassifier = ImageContentClassifier(cacheDirectory: cache) { _ in
            recoveryCount += 1
            return self.visualMetadata(labels: ["photo"])
        }
        let recovered = recoveryClassifier.classify(imageURL: image)

        XCTAssertEqual(recovered.visualTags.map(\.label), ["photo"])
        XCTAssertEqual(recoveryCount, 1)
        let cachedFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertEqual(cachedFiles.filter { $0.pathExtension == "json" }.count, 1)
    }

    func testMultiItemSnapshotPreservesItemAndHandleOrder() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(root: root, id: "multi", itemCount: 2, types: ["public.utf8-plain-text", "public.html"])
        try writePayload(root: root, snapshotID: "multi", itemIndex: 1, typeIndex: 0, uti: "public.html", raw: Data("<b>second</b>".utf8), decoded: "<b>second</b>", rawExtension: "html")
        try writePayload(root: root, snapshotID: "multi", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("first".utf8), decoded: "first")

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.allowedHandles, ["item_1", "item_2"])
        XCTAssertEqual(request.items.map(\.kind), [.text, .html])
        XCTAssertEqual(request.items.map(\.decodedTextPreview), ["first", "<b>second</b>"])
    }

    func testConcealedSnapshotEmitsWarningAndNoItems() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "concealed",
            itemCount: 1,
            renderedKind: "concealed",
            types: ["org.nspasteboard.ConcealedType"],
            isConcealed: true
        )

        let request = try replay(root).buildRequest(for: loadTimeline(root)[0])

        XCTAssertEqual(request.items, [])
        XCTAssertEqual(request.allowedHandles, [])
        XCTAssertEqual(request.runtimePayloads, [:])
        XCTAssertEqual(request.warnings, ["concealed_content_omitted"])
    }

    func testNonConcealedSnapshotWithMissingItemsFails() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "missing",
            itemCount: 1,
            types: ["public.utf8-plain-text"]
        )

        XCTAssertThrowsError(try replay(root).buildRequest(for: loadTimeline(root)[0])) { error in
            XCTAssertEqual(error as? ReplayError, .missingItemPayloads(snapshotID: "missing", expected: 1, found: 0))
        }
    }

    func testNonConcealedSnapshotWithEmptyItemFolderFails() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "empty-item",
            itemCount: 1,
            types: ["public.utf8-plain-text"]
        )
        let itemDir = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("empty-item", isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent("item-0", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try replay(root).buildRequest(for: loadTimeline(root)[0])) { error in
            XCTAssertEqual(error as? ReplayError, .missingItemPayloads(snapshotID: "empty-item", expected: 1, found: 0))
        }
    }

    func testRunWritesDeterministicJSONAcrossRuns() throws {
        let root = try makeTempDirectory()
        let out1 = root.appendingPathComponent("out1", isDirectory: true)
        let out2 = root.appendingPathComponent("out2", isDirectory: true)
        try writeSnapshot(root: root, id: "plain", types: ["public.utf8-plain-text"])
        try writePayload(root: root, snapshotID: "plain", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("stable".utf8), decoded: "stable")

        try BatchClipboardHistoryReplay(inputDirectory: root, outputDirectory: out1).run()
        try BatchClipboardHistoryReplay(inputDirectory: root, outputDirectory: out2).run()

        let json1 = try String(contentsOf: out1.appendingPathComponent("plain.request.json"), encoding: .utf8)
        let json2 = try String(contentsOf: out2.appendingPathComponent("plain.request.json"), encoding: .utf8)
        XCTAssertEqual(json1, json2)
    }

    func testRunRemovesStaleRequestFilesBeforeWritingCurrentTimeline() throws {
        let root = try makeTempDirectory()
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "{}".write(to: out.appendingPathComponent("stale.request.json"), atomically: true, encoding: .utf8)
        try "keep".write(to: out.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try writeSnapshot(root: root, id: "plain", types: ["public.utf8-plain-text"])
        try writePayload(root: root, snapshotID: "plain", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("stable".utf8), decoded: "stable")

        try BatchClipboardHistoryReplay(inputDirectory: root, outputDirectory: out).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("stale.request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("plain.request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("notes.txt").path))
    }

    func testRunRemovesStaleDerivedPayloadsBeforeWritingCurrentTimeline() throws {
        let root = try makeTempDirectory()
        let out = root.appendingPathComponent("out", isDirectory: true)
        let staleDir = out.appendingPathComponent("derived-payloads/stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleDir.appendingPathComponent("old.png"))
        let png = try pngData(width: 2, height: 2)
        let html = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshot(root: root, id: "embedded-clean", renderedKind: "html", types: ["public.html"])
        try writePayload(root: root, snapshotID: "embedded-clean", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        try BatchClipboardHistoryReplay(inputDirectory: root, outputDirectory: out).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("derived-payloads/embedded-clean/item_1_image_1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("embedded-clean.request.json").path))
    }

    func testBatchAssemblerFlattensMultipleSnapshotsIntoGlobalOrderedHandles() throws {
        let root = try makeTempDirectory()
        try writeSnapshotDirectory(root: root, id: "first", itemCount: 1, renderedKind: "plain-text", types: ["public.utf8-plain-text"])
        try writeSnapshotDirectory(root: root, id: "second", itemCount: 1, renderedKind: "plain-text", types: ["public.utf8-plain-text"])
        try writeTimeline(root: root, ids: ["first", "second"])
        try writePayload(root: root, snapshotID: "first", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("alpha".utf8), decoded: "alpha")
        try writePayload(root: root, snapshotID: "second", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("bravo".utf8), decoded: "bravo")

        let pair = try assembler(root).build(goal: "choose bravo", snapshots: loadTimeline(root), historyLimit: 20)

        XCTAssertEqual(pair.model.allowedHandles, ["item_1", "item_2"])
        XCTAssertEqual(pair.model.items.map(\.sourceSnapshotID), ["first", "second"])
        XCTAssertEqual(pair.model.items.map(\.sourceHandle), ["item_1", "item_1"])
        XCTAssertEqual(pair.model.items.map(\.decodedTextPreview), ["alpha", "bravo"])
        XCTAssertNotNil(pair.full.runtimePayloads["item_2"])
    }

    func testBatchAssemblerRemapsDerivedImageParentLinksToGlobalHandles() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 3, height: 4)
        let html = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshotDirectory(root: root, id: "plain", itemCount: 1, renderedKind: "plain-text", types: ["public.utf8-plain-text"])
        try writeSnapshotDirectory(root: root, id: "html", itemCount: 1, renderedKind: "html", types: ["public.html"])
        try writeTimeline(root: root, ids: ["plain", "html"], renderedKinds: ["plain-text", "html"], types: [["public.utf8-plain-text"], ["public.html"]])
        try writePayload(root: root, snapshotID: "plain", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("before".utf8), decoded: "before")
        try writePayload(root: root, snapshotID: "html", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let pair = try assembler(root).build(goal: "choose image", snapshots: loadTimeline(root), historyLimit: 20)

        XCTAssertEqual(pair.model.allowedHandles, ["item_1", "item_2", "item_3"])
        XCTAssertEqual(pair.model.items[2].derivedFrom, "item_2")
        XCTAssertEqual(pair.model.items[2].sourceSnapshotID, "html")
        XCTAssertEqual(pair.model.items[2].sourceHandle, "item_1_image_1")
        XCTAssertEqual(pair.model.sourceGroups.map(\.rootHandle), ["item_1", "item_2"])
        XCTAssertEqual(pair.model.sourceGroups[0].variants[0].role, "root_parent")
        XCTAssertEqual(pair.model.sourceGroups[1].variants[0].role, "root_rich_parent")
        XCTAssertEqual(pair.full.runtimePayloads["item_3"]?.first?.rawPath, "derived-payloads/html/item_1_image_1.png")
    }

    func testBatchAssemblerHistoryLimitKeepsDerivedGroupAndRenumbersContiguously() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 3, height: 4)
        let html = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshotDirectory(root: root, id: "old", itemCount: 1, renderedKind: "plain-text", types: ["public.utf8-plain-text"])
        try writeSnapshotDirectory(root: root, id: "html", itemCount: 1, renderedKind: "html", types: ["public.html"])
        try writeTimeline(root: root, ids: ["old", "html"], renderedKinds: ["plain-text", "html"], types: [["public.utf8-plain-text"], ["public.html"]])
        try writePayload(root: root, snapshotID: "old", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("old".utf8), decoded: "old")
        try writePayload(root: root, snapshotID: "html", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let pair = try assembler(root).build(goal: "latest html", snapshots: loadTimeline(root), historyLimit: 2)

        XCTAssertEqual(pair.model.allowedHandles, ["item_1", "item_2"])
        XCTAssertEqual(pair.model.items.map(\.sourceSnapshotID), ["html", "html"])
        XCTAssertEqual(pair.model.items[1].derivedFrom, "item_1")
        XCTAssertEqual(pair.model.items[1].sourceHandle, "item_1_image_1")
    }

    func testBatchAssemblerBuildsSourceGroupsWithVariantRolesAndMetadata() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = """
        <section><img width="40" height="50" title="Profile crop" src="data:image/png;base64,\(png.base64EncodedString())"></section>
        """
        try writeSnapshotDirectory(root: root, id: "google-fragment", itemCount: 1, renderedKind: "html", types: ["public.html"])
        try writeTimeline(
            root: root,
            ids: ["google-fragment"],
            renderedKinds: ["html"],
            types: [["public.html"]]
        )
        try writePayload(
            root: root,
            snapshotID: "google-fragment",
            itemIndex: 0,
            typeIndex: 0,
            uti: "public.html",
            raw: Data(html.utf8),
            decoded: html,
            rawExtension: "html"
        )

        let pair = try assembler(root).build(goal: "select image", snapshots: loadTimeline(root), historyLimit: 20)
        let sourceGroups = pair.model.sourceGroups

        XCTAssertEqual(sourceGroups.count, 1)
        XCTAssertEqual(sourceGroups[0].groupID, "group_1")
        XCTAssertEqual(sourceGroups[0].rootHandle, "item_1")
        XCTAssertEqual(sourceGroups[0].variants.map(\.handle), ["item_1", "item_2", "item_3"])
        XCTAssertEqual(sourceGroups[0].variants[0].role, "root_rich_parent")
        XCTAssertNil(sourceGroups[0].variants[0].derivedFrom)
        XCTAssertEqual(sourceGroups[0].variants[0].preserves, ["full_selection", "layout", "styles", "text"])
        XCTAssertEqual(sourceGroups[0].variants[0].loses, [])
        XCTAssertEqual(sourceGroups[0].variants[1].role, "derived_raw_image")
        XCTAssertEqual(sourceGroups[0].variants[1].derivedKind, "embedded_html_image")
        XCTAssertEqual(sourceGroups[0].variants[1].preserves, ["image"])
        XCTAssertEqual(sourceGroups[0].variants[1].loses, ["structure", "text", "context"])
        XCTAssertEqual(sourceGroups[0].variants[1].derivedFrom, "item_1")
        XCTAssertEqual(sourceGroups[0].variants[2].role, "derived_rich_image_fragment")
        XCTAssertEqual(sourceGroups[0].variants[2].derivedKind, "embedded_html_image_fragment")
        XCTAssertEqual(sourceGroups[0].variants[2].preserves, ["image", "fragment_layout"])
        XCTAssertEqual(
            sourceGroups[0].variants[2].loses,
            ["surrounding_context", "sibling_objects", "full_document"]
        )
        XCTAssertEqual(sourceGroups[0].variants[2].derivedFrom, "item_1")
    }

    func testBatchAssemblerPropagatesVisualTagsToItemsAndSourceGroupVariants() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 4, height: 5)
        let html = """
        <section><img width="40" height="50" title="Profile crop" src="data:image/png;base64,\(png.base64EncodedString())"></section>
        """
        try writeSnapshotDirectory(root: root, id: "visual-group", itemCount: 1, renderedKind: "html", types: ["public.html"])
        try writeTimeline(root: root, ids: ["visual-group"], renderedKinds: ["html"], types: [["public.html"]])
        try writePayload(root: root, snapshotID: "visual-group", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")

        let pair = try assembler(root, visualTags: ["person", "portrait"]).build(
            goal: "pic of my face",
            snapshots: loadTimeline(root),
            historyLimit: 20
        )

        XCTAssertEqual(pair.model.items[1].visualTags.map(\.label), ["person", "portrait"])
        XCTAssertEqual(pair.model.items[1].visualSummary, "visual tags: person, portrait")
        XCTAssertEqual(pair.model.sourceGroups[0].variants[1].visualTags.map(\.label), ["person", "portrait"])
        XCTAssertEqual(pair.model.sourceGroups[0].variants[2].visualTags.map(\.label), ["person", "portrait"])
    }


    func testBatchAssemblerOmitsConcealedSnapshots() throws {
        let root = try makeTempDirectory()
        try writeSnapshotDirectory(root: root, id: "concealed", itemCount: 1, renderedKind: "concealed", types: ["org.nspasteboard.ConcealedType"], isConcealed: true)
        try writeSnapshotDirectory(root: root, id: "plain", itemCount: 1, renderedKind: "plain-text", types: ["public.utf8-plain-text"])
        try writeTimeline(
            root: root,
            ids: ["concealed", "plain"],
            renderedKinds: ["concealed", "plain-text"],
            types: [["org.nspasteboard.ConcealedType"], ["public.utf8-plain-text"]],
            concealed: [true, false]
        )
        try writePayload(root: root, snapshotID: "plain", itemIndex: 0, typeIndex: 0, uti: "public.utf8-plain-text", raw: Data("visible".utf8), decoded: "visible")

        let pair = try assembler(root).build(goal: "visible only", snapshots: loadTimeline(root), historyLimit: 20)

        XCTAssertEqual(pair.model.allowedHandles, ["item_1"])
        XCTAssertEqual(pair.model.items[0].sourceSnapshotID, "plain")
    }

    func testBatchSelectionValidationSupportsLegacyAndNewPasteItems() throws {
        XCTAssertEqual(
            try parseAndValidateSelection(
                "{\"selected_handles\":[\"item_2\",\"item_1\"]}",
                allowedHandles: ["item_1", "item_2"]
            ),
            [
                BatchPastePlanItem(type: .handle, handle: "item_2"),
                BatchPastePlanItem(type: .handle, handle: "item_1"),
            ]
        )
        XCTAssertEqual(
            try parseAndValidateSelection(
                "{\"paste_items\":[{\"type\":\"handle\",\"handle\":\"item_2\"},{\"type\":\"text\",\"text\":\"hello\"}]}",
                allowedHandles: ["item_1", "item_2"]
            ),
            [
                BatchPastePlanItem(type: .handle, handle: "item_2"),
                BatchPastePlanItem(type: .text, text: "hello"),
            ]
        )
        XCTAssertEqual(
            try parseAndValidateSelection(
                "{\"selected_handles\":[\"item_1\"],\"paste_items\":[{\"type\":\"text\",\"text\":\"generated\"},{\"type\":\"handle\",\"handle\":\"item_2\"}]}",
                allowedHandles: ["item_1", "item_2"]
            ),
            [
                BatchPastePlanItem(type: .text, text: "generated"),
                BatchPastePlanItem(type: .handle, handle: "item_2"),
            ]
        )
        XCTAssertEqual(
            try parseAndValidateSelection("{\"selected_handles\":[]}", allowedHandles: ["item_1"]),
            []
        )
        XCTAssertEqual(
            try parseAndValidateSelection("{\"paste_items\":[]}", allowedHandles: ["item_1"]),
            []
        )
        XCTAssertThrowsError(try parseAndValidateSelection("not json", allowedHandles: ["item_1"])) { error in
            XCTAssertEqual(error as? BatchSelectionError, .invalidJSON)
        }
        XCTAssertThrowsError(try parseAndValidateSelection("{\"selected_handles\":[\"item_9\"]}", allowedHandles: ["item_1"])) { error in
            XCTAssertEqual(error as? BatchSelectionError, .unknownHandle("item_9"))
        }
        XCTAssertThrowsError(try parseAndValidateSelection("{\"selected_handles\":[\"item_1\",\"item_1\"]}", allowedHandles: ["item_1"])) { error in
            XCTAssertEqual(error as? BatchSelectionError, .duplicateHandle("item_1"))
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                "{\"paste_items\":[{\"type\":\"text\",\"text\":\"\\n\\t\"}]}",
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(error as? BatchSelectionError, .emptyPasteText)
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                #"{"paste_items":[{"type":"text","text":"\#(String(repeating: "a", count: 4001))"}]}"#,
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(
                error as? BatchSelectionError,
                .pasteTextTooLong(limit: 4000, actual: 4001)
            )
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                #"{"paste_items":[{"type":"text","text":"\#(String(repeating: "a", count: 4000))"},{"type":"text","text":"\#(String(repeating: "b", count: 4000))"},{"type":"text","text":"c"}]}"#,
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(error as? BatchSelectionError, .pasteTextTotalTooLong(limit: 8000, actual: 8001))
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                #"{"paste_items":[{"type":"bogus","handle":"item_1"}]}"#,
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(error as? BatchSelectionError, .malformedPasteItemType)
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                #"{"paste_items":[{"type":"handle","text":"item_1"}]}"#,
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(error as? BatchSelectionError, .malformedPasteHandle)
        }
        XCTAssertThrowsError(
            try parseAndValidateSelection(
                #"{"paste_items":[{"type":"text","text":123}],"item_3":""}"#,
                allowedHandles: ["item_1"]
            )
        ) { error in
            XCTAssertEqual(error as? BatchSelectionError, .malformedPasteText)
        }
    }

    func testResolveSelectionSupportsGeneratedTextItems() throws {
        let root = try makeTempDirectory()
        try writeSnapshot(
            root: root,
            id: "plain",
            itemCount: 1,
            renderedKind: "plain-text",
            types: ["public.utf8-plain-text"]
        )
        try writePayload(
            root: root,
            snapshotID: "plain",
            itemIndex: 0,
            typeIndex: 0,
            uti: "public.utf8-plain-text",
            raw: Data("hello".utf8),
            decoded: "hello"
        )
        let pair = try assembler(root).build(goal: "transform", snapshots: loadTimeline(root), historyLimit: 20)
        let pasted = assignSyntheticTextHandles(
            to: [
                BatchPastePlanItem(type: .text, text: "prefix: "),
                BatchPastePlanItem(type: .handle, handle: "item_1"),
                BatchPastePlanItem(type: .text, text: "suffix"),
            ]
        )
        let manifest = resolveSelection(selectedItems: pasted, fullRequest: pair.full)

        XCTAssertEqual(
            manifest.generatedTextCharCountByHandle,
            ["generated_text_1": 8, "generated_text_2": 6]
        )
        XCTAssertEqual(manifest.totalGeneratedTextChars, 14)
        XCTAssertEqual(manifest.items.map(\.type), [.text, .handle, .text])
        XCTAssertEqual(manifest.selectedHandles, ["generated_text_1", "item_1", "generated_text_2"])
    }

    func testResolveSelectionReportsOriginalAndDerivedPayloadPathsAndByteMismatches() throws {
        let root = try makeTempDirectory()
        let png = try pngData(width: 2, height: 2)
        let html = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        try writeSnapshotDirectory(root: root, id: "html", itemCount: 1, renderedKind: "html", types: ["public.html"])
        try writeTimeline(root: root, ids: ["html"], renderedKinds: ["html"], types: [["public.html"]])
        try writePayload(root: root, snapshotID: "html", itemIndex: 0, typeIndex: 0, uti: "public.html", raw: Data(html.utf8), decoded: html, rawExtension: "html")
        let pair = try assembler(root).build(goal: "choose image", snapshots: loadTimeline(root), historyLimit: 20)

        let derivedURL = root.appendingPathComponent("requests/derived-payloads/html/item_1_image_1.png")
        try Data("wrong".utf8).write(to: derivedURL)
        let manifest = resolveSelection(selectedHandles: ["item_1", "item_2"], fullRequest: pair.full)

        XCTAssertEqual(manifest.selectedHandles, ["item_1", "item_2"])
        XCTAssertEqual(manifest.items[0].payloads[0].error, nil)
        XCTAssertEqual(manifest.items[1].payloads[0].rawPath, derivedURL.path)
        XCTAssertEqual(manifest.items[1].payloads[0].error, "byte_size_mismatch")
    }

    private func replay(_ root: URL) -> BatchClipboardHistoryReplay {
        BatchClipboardHistoryReplay(
            inputDirectory: root,
            outputDirectory: root.appendingPathComponent("requests", isDirectory: true)
        )
    }

    private func replay(_ root: URL, visualTags labels: [String]) -> BatchClipboardHistoryReplay {
        BatchClipboardHistoryReplay(
            inputDirectory: root,
            outputDirectory: root.appendingPathComponent("requests", isDirectory: true),
            imageClassifier: ImageContentClassifier(
                cacheDirectory: root.appendingPathComponent("batch-clipboard-history/image-tags", isDirectory: true)
            ) { _ in
                self.visualMetadata(labels: labels)
            }
        )
    }

    private func assembler(_ root: URL) -> BatchClipboardHistoryAssembler {
        BatchClipboardHistoryAssembler(
            inputDirectory: root,
            replayOutputDirectory: root.appendingPathComponent("requests", isDirectory: true)
        )
    }

    private func assembler(_ root: URL, visualTags labels: [String]) -> BatchClipboardHistoryAssembler {
        BatchClipboardHistoryAssembler(
            inputDirectory: root,
            replayOutputDirectory: root.appendingPathComponent("requests", isDirectory: true),
            imageClassifier: ImageContentClassifier(
                cacheDirectory: root.appendingPathComponent("batch-clipboard-history/image-tags", isDirectory: true)
            ) { _ in
                self.visualMetadata(labels: labels)
            }
        )
    }

    private func visualMetadata(labels: [String]) -> ImageVisualMetadata {
        ImageVisualMetadata(
            visualTags: labels.enumerated().map { index, label in
                VisualTag(label: label, identifier: label, confidence: 0.9 - (Double(index) * 0.01))
            },
            visualSummary: labels.isEmpty ? nil : "visual tags: \(labels.joined(separator: ", "))",
            visualTagStatus: labels.isEmpty ? "no_tags" : "ok"
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasteboard-replay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadTimeline(_ root: URL) throws -> [SnapshotSummary] {
        let data = try Data(contentsOf: root.appendingPathComponent("timeline.json"))
        return try JSONDecoder().decode([SnapshotSummary].self, from: data)
    }

    private func writeSnapshot(
        root: URL,
        id: String,
        itemCount: Int = 1,
        renderedKind: String = "plain-text",
        htmlBytes: Int = 0,
        plainTextBytes: Int = 0,
        types: [String],
        sourceURL: String = "",
        isConcealed: Bool = false
    ) throws {
        let snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshotsDir.appendingPathComponent(id, isDirectory: true),
            withIntermediateDirectories: true
        )

        let timeline = """
        [
          {
            "id": "\(id)",
            "observedAt": "2026-04-30T12:00:00Z",
            "changeCount": 42,
            "renderedKind": "\(renderedKind)",
            "itemCount": \(itemCount),
            "htmlBytes": \(htmlBytes),
            "plainTextBytes": \(plainTextBytes),
            "types": \(jsonArray(types)),
            "sourceURL": "\(sourceURL)",
            "hasEmbeddedImage": false,
            "isConcealed": \(isConcealed ? "true" : "false"),
            "preview": ""
          }
        ]
        """
        try timeline.write(to: root.appendingPathComponent("timeline.json"), atomically: true, encoding: .utf8)
    }

    private func writeSnapshotDirectory(
        root: URL,
        id: String,
        itemCount: Int,
        renderedKind: String,
        types: [String],
        isConcealed: Bool = false
    ) throws {
        let snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshotsDir.appendingPathComponent(id, isDirectory: true),
            withIntermediateDirectories: true
        )
        if isConcealed {
            _ = itemCount
        }
    }

    private func writeTimeline(
        root: URL,
        ids: [String],
        renderedKinds: [String]? = nil,
        types: [[String]]? = nil,
        concealed: [Bool]? = nil
    ) throws {
        let entries = ids.enumerated().map { index, id in
            let renderedKind = renderedKinds?[index] ?? "plain-text"
            let itemTypes = types?[index] ?? ["public.utf8-plain-text"]
            let isConcealed = concealed?[index] ?? false
            return """
              {
                "id": "\(id)",
                "observedAt": "2026-04-30T12:00:0\(index)Z",
                "changeCount": \(42 + index),
                "renderedKind": "\(renderedKind)",
                "itemCount": 1,
                "htmlBytes": 0,
                "plainTextBytes": 0,
                "types": \(jsonArray(itemTypes)),
                "sourceURL": "",
                "hasEmbeddedImage": false,
                "isConcealed": \(isConcealed ? "true" : "false"),
                "preview": ""
              }
            """
        }.joined(separator: ",\n")
        try "[\n\(entries)\n]".write(to: root.appendingPathComponent("timeline.json"), atomically: true, encoding: .utf8)
    }

    private func writePayload(
        root: URL,
        snapshotID: String,
        itemIndex: Int,
        typeIndex: Int,
        uti: String,
        raw: Data,
        decoded: String? = nil,
        rawExtension: String = "bin"
    ) throws {
        let itemDir = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent("item-\(itemIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        let basename = "\(String(format: "%02d", typeIndex))-\(uti)"
        try raw.write(to: itemDir.appendingPathComponent("\(basename).raw.\(rawExtension)"), options: .atomic)
        if let decoded {
            try decoded.write(to: itemDir.appendingPathComponent("\(basename).decoded.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func jsonArray(_ values: [String]) -> String {
        let encoded = try! JSONEncoder().encode(values)
        return String(data: encoded, encoding: .utf8)!
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BatchClipboardHistoryReplayTests", code: 1)
        }
        return data
    }

    private func googleSlidesCustomData(shapeID: String, blobID: String) -> Data {
        let textShapeID = "g-text"
        let otherBlobID = "s-blob-v1-IMAGE-other"
        let drawingsInner: [String: Any] = [
            "resolved": [
                [3, textShapeID, 108, [1, 0, 0, 1, 10, 10], [44, 0], "p"],
                [15, textShapeID, NSNull(), 0, "Other text"],
                [3, shapeID, 8, [0.5, 0, 0, 0.5, 100, 200], [49, blobID, 79, -3.1759, 80, 1.7841, 84, 2.0028, 85, -0.3432, 87, 1150, 88, 2048], "p"],
                [44, shapeID, "IMG_9189.png", ""]
            ],
            "unresolved": [
                [3, textShapeID, 108, [1, 0, 0, 1, 10, 10], [44, 0], "slide"],
                [3, shapeID, 8, [0.5, 0, 0, 0.5, 100, 200], [49, blobID, 79, -3.1759, 80, 1.7841, 84, 2.0028, 85, -0.3432, 87, 1150, 88, 2048], "slide"],
                [44, shapeID, "IMG_9189.png", ""]
            ],
            "autotext_content": ["other": [:]],
            "did_remove_empty_picture_placeholders": false,
            "copy_source_supports_inheritance_via_master": true
        ]
        let imageClipInner: [String: Any] = [
            "image_urls": [
                blobID: "https://example.com/image.png",
                otherBlobID: "https://example.com/other.png"
            ],
            "placeholder_ids": [:],
            "cosmo_ids": [
                blobID: 1,
                otherBlobID: 2
            ]
        ]
        return buildChromiumWebCustomData(entries: [
            ChromiumWebCustomDataEntry(
                name: "application/x-vnd.google-docs-document-slice-clip+wrapped",
                value: wrappedGoogleSlidesValue(["resolved": ["full_slide": true]])
            ),
            ChromiumWebCustomDataEntry(
                name: googleDocsDrawingsObjectUTI,
                value: wrappedGoogleSlidesValue(drawingsInner)
            ),
            ChromiumWebCustomDataEntry(
                name: googleDocsImageClipUTI,
                value: wrappedGoogleSlidesValue(imageClipInner)
            ),
            ChromiumWebCustomDataEntry(
                name: googleDocsInternalClipIDUTI,
                value: "clip-id"
            )
        ])
    }

    private func wrappedGoogleSlidesValue(_ inner: [String: Any]) -> String {
        let innerData = compactJSONData(inner)!
        let innerString = String(data: innerData, encoding: .utf8)!
        let outer: [String: Any] = [
            "dih": 1,
            "data": innerString,
            "edi": "edi",
            "edrk": "edrk",
            "dct": "punch",
            "ds": false,
            "cses": false,
            "sm": "other"
        ]
        return String(data: compactJSONData(outer)!, encoding: .utf8)!
    }
}
