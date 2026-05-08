import AppKit
import CryptoKit
import Foundation

enum ImageDiagnostics {
    static func makePayload(pngData: Data) -> (screenshot: [String: Any], diagnostics: [String: Any])? {
        guard let bitmap = NSBitmapImageRep(data: pngData) else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let maxSamples = 40_000
        let totalPixels = max(1, width * height)
        let step = max(1, Int(sqrt(Double(totalPixels) / Double(maxSamples))))

        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        var nearBlack = 0
        var nearWhite = 0
        var uniqueColors = Set<UInt32>()

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let luma = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                sum += luma
                sumSquares += luma * luma
                count += 1
                if luma <= 0.04 { nearBlack += 1 }
                if luma >= 0.96 { nearWhite += 1 }

                if uniqueColors.count < 512 {
                    let colorKey =
                        (UInt32(Int(red * 255.0)) << 16)
                        | (UInt32(Int(green * 255.0)) << 8)
                        | UInt32(Int(blue * 255.0))
                    uniqueColors.insert(colorKey)
                }
            }
        }

        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        let variance = max(0.0, (sumSquares / Double(count)) - (mean * mean))
        let stddev = sqrt(variance)
        let nearBlackRatio = Double(nearBlack) / Double(count)
        let nearWhiteRatio = Double(nearWhite) / Double(count)
        let blankLikely =
            nearBlackRatio >= 0.98
            || nearWhiteRatio >= 0.98
            || stddev <= 0.015
            || uniqueColors.count <= 4

        let screenshot: [String: Any] = [
            "mime_type": "image/png",
            "byte_size": pngData.count,
            "width": width,
            "height": height,
            "sha256": SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined(),
        ]
        let diagnostics: [String: Any] = [
            "mean_luma": mean,
            "luma_stddev": stddev,
            "near_black_ratio": nearBlackRatio,
            "near_white_ratio": nearWhiteRatio,
            "sample_unique_color_count": uniqueColors.count,
            "blank_likely": blankLikely,
        ]
        return (screenshot, diagnostics)
    }
}
