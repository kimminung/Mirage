import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics
import Metal

/// Core Image work: camera frame -> CGImage (with optional hand-driven filters),
/// segmentation mask -> alpha CGImage. Thread-safe; CIContext is internally synchronized.
nonisolated final class FrameProcessor: @unchecked Sendable {
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Mirage"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    nonisolated struct FilterParams: Sendable {
        /// Palm centers in view-normalized coords with a signed strength:
        /// positive = bulge (open palm), negative = pinch inward (fist). Radius in view units.
        var bumps: [(center: CGPoint, radius: CGFloat, scale: CGFloat)] = []
        var kaleidoscope: (center: CGPoint, angle: CGFloat, count: Int)? = nil
        var freeze = false
    }

    /// Renders the camera frame, mirrored to selfie orientation, applying filters.
    func render(_ pixelBuffer: CVPixelBuffer, mirror: Bool, params: FilterParams) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        if mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
        }

        // Filters operate in Core Image's bottom-left coordinate space.
        func ciPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * extent.width, y: (1 - p.y) * extent.height)
        }

        for bump in params.bumps {
            let filter = CIFilter.bumpDistortion()
            filter.inputImage = image
            filter.center = ciPoint(bump.center)
            filter.radius = Float(bump.radius * extent.height)
            filter.scale = Float(max(-0.9, min(0.9, bump.scale)))
            if let out = filter.outputImage { image = out.cropped(to: extent) }
        }

        if let k = params.kaleidoscope {
            let filter = CIFilter.kaleidoscope()
            filter.inputImage = image
            filter.center = ciPoint(k.center)
            filter.angle = Float(k.angle)
            filter.count = k.count
            if let out = filter.outputImage { image = out.cropped(to: extent) }
        }

        return context.createCGImage(image, from: extent, format: .BGRA8, colorSpace: colorSpace)
    }

    /// Converts a OneComponent8 person mask into an alpha-only CGImage in view orientation.
    func alphaMask(from maskBuffer: CVPixelBuffer, mirror: Bool) -> MaskImage? {
        var image = CIImage(cvPixelBuffer: maskBuffer)
        let extent = image.extent
        if mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
        }
        // Mask luminance -> alpha; keeps white where the person is.
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = image
        guard let out = toAlpha.outputImage,
              let cg = context.createCGImage(out, from: extent, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return MaskImage(image: cg, size: extent.size)
    }

    /// Simple frame -> CGImage for snapshots.
    func snapshot(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
