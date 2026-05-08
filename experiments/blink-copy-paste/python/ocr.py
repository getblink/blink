from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any


def _image_size_pixels(image_path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    width = None
    height = None
    for raw_line in (result.stdout or "").splitlines():
        line = raw_line.strip()
        if line.startswith("pixelWidth:"):
            width = int(line.split(":", 1)[1].strip())
        elif line.startswith("pixelHeight:"):
            height = int(line.split(":", 1)[1].strip())
    if not width or not height:
        raise ValueError(f"Failed to read image size for {image_path}.")
    return width, height


def recognize_text(
    image_path: Path,
    *,
    uses_language_correction: bool = True,
) -> dict[str, Any]:
    try:
        import Quartz
        import Vision
        from Cocoa import NSURL
    except ImportError as exc:
        return {"status": "error", "error": f"Vision import failed: {exc}"}

    try:
        width, height = _image_size_pixels(image_path)
        url = NSURL.fileURLWithPath_(str(image_path))
        ci_image = Quartz.CIImage.imageWithContentsOfURL_(url)
        if ci_image is None:
            return {"status": "error", "error": f"Unable to load image: {image_path}"}

        request = Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
        request.setUsesLanguageCorrection_(bool(uses_language_correction))
        handler = Vision.VNImageRequestHandler.alloc().initWithCIImage_options_(
            ci_image, None
        )
        success, error = handler.performRequests_error_([request], None)
        if not success:
            return {"status": "error", "error": str(error or "Vision request failed")}

        blocks: list[dict[str, Any]] = []
        full_text_lines: list[str] = []
        for observation in request.results() or []:
            candidates = observation.topCandidates_(1) or []
            if not candidates:
                continue
            top_candidate = candidates[0]
            text = str(top_candidate.string() or "").strip()
            if not text:
                continue
            bbox = observation.boundingBox()
            pixel_width = round(float(bbox.size.width) * width, 2)
            pixel_height = round(float(bbox.size.height) * height, 2)
            pixel_x = round(float(bbox.origin.x) * width, 2)
            pixel_y = round(height - ((float(bbox.origin.y) + float(bbox.size.height)) * height), 2)
            blocks.append(
                {
                    "text": text,
                    "bbox_pixels": {
                        "x": pixel_x,
                        "y": pixel_y,
                        "width": pixel_width,
                        "height": pixel_height,
                    },
                    "confidence": round(float(top_candidate.confidence()), 4),
                }
            )
            full_text_lines.append(text)

        return {
            "status": "ok",
            "image_size_pixels": {"width": width, "height": height},
            "blocks": blocks,
            "full_text": "\n".join(full_text_lines),
        }
    except Exception as exc:
        return {"status": "error", "error": str(exc)}
