import Foundation
import CoreGraphics

/// Synthesizes a plausible `FrameAnalysis` (two waving hands, a standing body,
/// a silhouette mask + contour) so the effects, gestures and mesh rig can be
/// exercised and screenshotted without a camera or a person in front of it.
nonisolated struct DemoPoseSource {
    let imageSize = CGSize(width: 1280, height: 720)
    private var maskCache: (key: Int, mask: MaskImage)?

    mutating func analysis(at t: TimeInterval) -> FrameAnalysis {
        var a = FrameAnalysis(timestamp: t, imageSize: imageSize)
        let body = Self.body(at: t)
        a.body = body
        a.hands = [Self.hand(side: .left, body: body, t: t), Self.hand(side: .right, body: body, t: t)]
        let silhouette = Self.silhouette(body: body, hands: a.hands)
        a.contours = [silhouette]
        // Re-render the mask only ~10x per second; it's a CPU bitmap.
        let key = Int(t * 10)
        if let cached = maskCache, cached.key == key {
            a.personMask = cached.mask
        } else if let mask = Self.rasterize(polygon: silhouette, size: CGSize(width: 320, height: 180)) {
            maskCache = (key, mask)
            a.personMask = mask
        }
        a.faces = [Self.face(body: body)]
        a.processingMillis = 0
        a.stageTimings = ["demo": 0]
        return a
    }

    // MARK: Body

    private static func body(at t: TimeInterval) -> BodySnapshot {
        let sway = CGFloat(sin(t * 0.7)) * 0.015
        let bob = CGFloat(sin(t * 1.4)) * 0.006
        let cx: CGFloat = 0.5 + sway
        func P(_ x: CGFloat, _ y: CGFloat, _ c: Float = 0.95) -> TrackedPoint { TrackedPoint(x: x, y: y + bob, confidence: c) }

        let leftWave = CGFloat(sin(t * 2.2))
        let rightWave = CGFloat(sin(t * 1.6 + 1.0))

        var j: [BodyJoint: TrackedPoint] = [:]
        j[.nose] = P(cx, 0.22)
        j[.leftEye] = P(cx + 0.02, 0.20)
        j[.rightEye] = P(cx - 0.02, 0.20)
        j[.leftEar] = P(cx + 0.045, 0.215)
        j[.rightEar] = P(cx - 0.045, 0.215)
        j[.neck] = P(cx, 0.31)
        j[.leftShoulder] = P(cx + 0.11, 0.34)
        j[.rightShoulder] = P(cx - 0.11, 0.34)
        // Arms raised and waving.
        j[.leftElbow] = P(cx + 0.2, 0.30 + leftWave * 0.03)
        j[.leftWrist] = P(cx + 0.27 + leftWave * 0.04, 0.16 + leftWave * 0.05)
        j[.rightElbow] = P(cx - 0.2, 0.32 + rightWave * 0.03)
        j[.rightWrist] = P(cx - 0.27 + rightWave * 0.04, 0.18 + rightWave * 0.05)
        j[.leftHip] = P(cx + 0.07, 0.66)
        j[.rightHip] = P(cx - 0.07, 0.66)
        j[.root] = P(cx, 0.66)
        j[.leftKnee] = P(cx + 0.08, 0.86, 0.6)
        j[.rightKnee] = P(cx - 0.08, 0.86, 0.6)
        j[.leftAnkle] = P(cx + 0.085, 1.02, 0.2)
        j[.rightAnkle] = P(cx - 0.085, 1.02, 0.2)
        return BodySnapshot(joints: j)
    }

    // MARK: Hands

    private static func hand(side: HandSide, body: BodySnapshot, t: TimeInterval) -> HandSnapshot {
        let wristJoint: BodyJoint = side == .left ? .leftWrist : .rightWrist
        let wrist = body.point(wristJoint) ?? CGPoint(x: 0.5, y: 0.5)
        let size: CGFloat = 0.075
        let dirSign: CGFloat = side == .left ? 1 : -1
        // Hand points up-and-outward; fingers curl over time to cycle through gestures.
        let phase = (t * 0.35 + (side == .left ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
        let curl: CGFloat
        switch phase {
        case 0..<0.3: curl = 0              // open palm
        case 0.3..<0.5: curl = 0.9          // fist
        case 0.5..<0.7: curl = 0            // open
        default: curl = 0.5                 // half (pinch-ish)
        }
        let isPeace = phase >= 0.7
        let isPinch = phase >= 0.3 && phase < 0.5 && side == .right

        var j: [HandJoint: TrackedPoint] = [:]
        func P(_ p: CGPoint, _ c: Float = 0.9) -> TrackedPoint { TrackedPoint(x: p.x, y: p.y, confidence: c) }
        let up = CGPoint(x: 0.15 * dirSign, y: -1)   // palm axis
        let right = CGPoint(x: 1, y: 0.15 * dirSign) // across the palm

        j[.wrist] = P(wrist)
        let fingers: [(Finger, CGFloat, CGFloat)] = [   // (finger, lateral offset, length factor)
            (.thumb, -1.1 * dirSign, 0.75), (.index, -0.55 * dirSign, 1.0), (.middle, -0.15 * dirSign, 1.1),
            (.ring, 0.25 * dirSign, 1.0), (.little, 0.65 * dirSign, 0.8)
        ]
        for (finger, lateral, lengthFactor) in fingers {
            let base = wrist + up * size + right * (lateral * size * 0.45)
            var fingerCurl = curl
            if isPeace && (finger == .index || finger == .middle) { fingerCurl = 0 }
            if isPeace && (finger == .ring || finger == .little) { fingerCurl = 0.9 }
            if finger == .thumb { fingerCurl = min(curl, 0.4) }
            let seg = size * 0.33 * lengthFactor
            let c = fingerCurl
            // Each segment bends progressively more as curl increases.
            let d1 = up * (1 - c * 0.6) + right * (c * 0.4 * (lateral < 0 ? 1 : -1)) * 0
            let p1 = base + d1 * seg
            let d2 = up * (1 - c * 1.2) + CGPoint(x: 0, y: c * 0.8) * 1
            let p2 = p1 + d2 * seg
            let p3 = p2 + (up * (1 - c * 1.8) + CGPoint(x: 0, y: c * 1.2)) * seg
            switch finger {
            case .thumb:
                var tipPt = p3
                if isPinch, let idx = j[.indexTip] { tipPt = CGPoint(x: idx.x, y: idx.y) }
                j[.thumbCMC] = P(base); j[.thumbMP] = P(p1); j[.thumbIP] = P(p2); j[.thumbTip] = P(tipPt)
            case .index:
                j[.indexMCP] = P(base); j[.indexPIP] = P(p1); j[.indexDIP] = P(p2); j[.indexTip] = P(p3)
            case .middle:
                j[.middleMCP] = P(base); j[.middlePIP] = P(p1); j[.middleDIP] = P(p2); j[.middleTip] = P(p3)
            case .ring:
                j[.ringMCP] = P(base); j[.ringPIP] = P(p1); j[.ringDIP] = P(p2); j[.ringTip] = P(p3)
            case .little:
                j[.littleMCP] = P(base); j[.littlePIP] = P(p1); j[.littleDIP] = P(p2); j[.littleTip] = P(p3)
            }
        }
        if isPinch, let idx = j[.indexTip] { j[.thumbTip] = idx }
        return HandSnapshot(id: "hand-\(side.rawValue)", side: side, joints: j, confidence: 0.9)
    }

    // MARK: Face

    private static func face(body: BodySnapshot) -> FaceSnapshot {
        let nose = body.point(.nose) ?? CGPoint(x: 0.5, y: 0.22)
        let box = CGRect(x: nose.x - 0.055, y: nose.y - 0.08, width: 0.11, height: 0.16)
        func ring(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ n: Int) -> [CGPoint] {
            (0..<n).map { i in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
            }
        }
        let regions = [
            FaceRegion(name: "faceContour", points: ring(CGPoint(x: nose.x, y: nose.y), 0.055, 0.08, 18).filter { $0.y > nose.y - 0.04 }, closed: false),
            FaceRegion(name: "leftEye", points: ring(CGPoint(x: nose.x + 0.022, y: nose.y - 0.02), 0.012, 0.006, 8), closed: true),
            FaceRegion(name: "rightEye", points: ring(CGPoint(x: nose.x - 0.022, y: nose.y - 0.02), 0.012, 0.006, 8), closed: true),
            FaceRegion(name: "outerLips", points: ring(CGPoint(x: nose.x, y: nose.y + 0.04), 0.02, 0.008, 10), closed: true),
            FaceRegion(name: "noseCrest", points: [CGPoint(x: nose.x, y: nose.y - 0.03), nose], closed: false)
        ]
        return FaceSnapshot(boundingBox: box, regions: regions, roll: 0, yaw: 0)
    }

    // MARK: Silhouette

    private static func silhouette(body: BodySnapshot, hands: [HandSnapshot]) -> [CGPoint] {
        // Build a thick polyline hull around the skeleton: sample circles around joints & bones.
        var pts: [CGPoint] = []
        let radii: [BodyJoint: CGFloat] = [
            .nose: 0.075, .neck: 0.05, .leftShoulder: 0.06, .rightShoulder: 0.06,
            .leftElbow: 0.04, .rightElbow: 0.04, .leftWrist: 0.035, .rightWrist: 0.035,
            .leftHip: 0.075, .rightHip: 0.075, .root: 0.09, .leftKnee: 0.05, .rightKnee: 0.05,
            .leftAnkle: 0.045, .rightAnkle: 0.045
        ]
        for (joint, r) in radii {
            guard let c = body.point(joint, minimumConfidence: 0) else { continue }
            for i in 0..<10 {
                let a = CGFloat(i) / 10 * 2 * .pi
                pts.append(CGPoint(x: c.x + cos(a) * r * 0.5625, y: c.y + sin(a) * r))
            }
        }
        for hand in hands {
            for (_, p) in hand.joints { pts.append(p.cgPoint) }
            let c = hand.palmCenter
            for i in 0..<8 {
                let a = CGFloat(i) / 8 * 2 * .pi
                pts.append(CGPoint(x: c.x + cos(a) * 0.035, y: c.y + sin(a) * 0.06))
            }
        }
        return convexHull(pts).map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private static func rasterize(polygon: [CGPoint], size: CGSize) -> MaskImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let path = CGMutablePath()
        // CGContext origin is bottom-left; flip y.
        let pts = polygon.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
        guard let first = pts.first else { return nil }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return nil }
        return MaskImage(image: image, size: size)
    }
}
