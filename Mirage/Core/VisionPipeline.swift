import Foundation
import Vision
import CoreImage
import CoreVideo
import OSLog

/// Runs every enabled Vision request on a frame, concurrently, and folds the
/// results into a `FrameAnalysis` in view-normalized coordinates.
///
/// Requests used (all on-device, Vision Swift API):
///  - DetectHumanHandPoseRequest      21 joints x N hands + chirality
///  - DetectHumanBodyPoseRequest      19 body joints (2D)
///  - DetectHumanBodyPose3DRequest    17 joints in camera space (meters)
///  - GeneratePersonSegmentationRequest  person alpha mask
///  - DetectContoursRequest           silhouette polygons from the mask
///  - DetectFaceLandmarksRequest      76-point face landmarks
actor VisionPipeline {
    private let log = Logger(subsystem: "Mirage", category: "Vision")
    private let frameProcessor = FrameProcessor()

    private var handRequest = DetectHumanHandPoseRequest()
    private let bodyRequest = DetectHumanBodyPoseRequest()
    private let body3DRequest = DetectHumanBodyPose3DRequest()
    private var segmentationRequest = GeneratePersonSegmentationRequest()
    private let faceRequest = DetectFaceLandmarksRequest()
    private var contoursRequest = DetectContoursRequest()

    /// Heavy requests (segmentation, contours, face landmarks) run every N-th frame and
    /// their last results are reused in between. Hands and body run on every frame.
    var heavyRequestCadence = 2
    private var frameIndex = 0
    private var cachedMask: MaskImage?
    private var cachedContours: [[CGPoint]] = []
    private var cachedFaces: [FaceSnapshot] = []
    private var cachedTimings: [String: Double] = [:]

    init() {
        handRequest.maximumHandCount = 2
        segmentationRequest.qualityLevel = .balanced
        contoursRequest.contrastAdjustment = 1.0
        contoursRequest.detectsDarkOnLight = false
        contoursRequest.maximumImageDimension = 320
    }

    func analyze(_ frame: CameraFrame, config: VisionConfig) async -> FrameAnalysis {
        let start = CFAbsoluteTimeGetCurrent()
        var analysis = FrameAnalysis(timestamp: frame.timestamp, imageSize: frame.size)
        let mirror = config.mirror
        let pb = frame.pixelBuffer

        handRequest.maximumHandCount = max(1, min(4, config.maxHands))
        switch config.segmentationQuality {
        case .fast: segmentationRequest.qualityLevel = .fast
        case .balanced: segmentationRequest.qualityLevel = .balanced
        case .accurate: segmentationRequest.qualityLevel = .accurate
        }

        frameIndex &+= 1
        let runHeavy = frameIndex % max(1, heavyRequestCadence) == 0

        // Kick everything off concurrently; each stage records its own timing.
        async let handsResult: ([HandSnapshot], Double) = config.hands ? detectHands(pb, mirror: mirror, minConf: config.minimumJointConfidence) : ([], 0)
        async let bodyResult: (BodySnapshot?, Double) = config.body ? detectBody(pb, mirror: mirror) : (nil, 0)
        async let body3DResult: (Body3DSnapshot?, Double) = (config.body3D && runHeavy) ? detectBody3D(pb) : (nil, 0)
        async let maskResult: (MaskImage?, [[CGPoint]], Double, Double) = (config.segmentation && runHeavy) ? segmentPerson(pb, mirror: mirror, contours: config.contours) : (nil, [], 0, 0)
        async let faceResult: ([FaceSnapshot], Double) = (config.faceLandmarks && runHeavy) ? detectFaces(pb, mirror: mirror) : ([], 0)

        let (hands, handMs) = await handsResult
        let (body, bodyMs) = await bodyResult
        let (body3D, body3DMs) = await body3DResult
        let (mask, contours, segMs, contourMs) = await maskResult
        let (faces, faceMs) = await faceResult

        if runHeavy {
            cachedMask = config.segmentation ? mask : nil
            cachedContours = config.segmentation && config.contours ? contours : []
            cachedFaces = config.faceLandmarks ? faces : []
            cachedTimings = ["segmentation": segMs, "contours": contourMs, "face": faceMs, "body3D": body3DMs]
        }

        analysis.hands = hands
        analysis.body = body
        analysis.body3D = body3D
        analysis.personMask = cachedMask
        analysis.contours = cachedContours
        analysis.faces = cachedFaces
        analysis.stageTimings = cachedTimings.merging(["hands": handMs, "body": bodyMs]) { $1 }
        analysis.processingMillis = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return analysis
    }

    // MARK: Hands

    private func detectHands(_ pb: CVPixelBuffer, mirror: Bool, minConf: Float) async -> ([HandSnapshot], Double) {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let observations = try await handRequest.perform(on: pb, orientation: nil)
            var hands: [HandSnapshot] = []
            var unknownIndex = 0
            for obs in observations {
                var joints: [HandJoint: TrackedPoint] = [:]
                for (name, joint) in obs.allJoints() {
                    guard let mapped = Self.mapHandJoint(name) else { continue }
                    let p = Self.viewPoint(joint.location, mirror: mirror)
                    joints[mapped] = TrackedPoint(x: p.x, y: p.y, confidence: joint.confidence)
                }
                let side: HandSide
                switch obs.chirality {
                case .left: side = .left
                case .right: side = .right
                default: side = .unknown
                }
                let id: String
                if side == .unknown {
                    id = "hand-\(unknownIndex)"
                    unknownIndex += 1
                } else {
                    id = "hand-\(side.rawValue)"
                }
                let avgConf = joints.values.map(\.confidence).reduce(0, +) / Float(max(1, joints.count))
                hands.append(HandSnapshot(id: id, side: side, joints: joints, confidence: avgConf))
            }
            // Vision occasionally reports the same chirality twice; keep the most confident.
            var seen: [String: HandSnapshot] = [:]
            for h in hands where (seen[h.id]?.confidence ?? -1) < h.confidence { seen[h.id] = h }
            return (Array(seen.values).sorted { $0.id < $1.id }, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        } catch {
            log.error("Hand pose failed: \(error.localizedDescription, privacy: .public)")
            return ([], (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
    }

    private static func mapHandJoint(_ name: HumanHandPoseObservation.JointName) -> HandJoint? {
        switch name {
        case .wrist: .wrist
        case .thumbCMC: .thumbCMC
        case .thumbMP: .thumbMP
        case .thumbIP: .thumbIP
        case .thumbTip: .thumbTip
        case .indexMCP: .indexMCP
        case .indexPIP: .indexPIP
        case .indexDIP: .indexDIP
        case .indexTip: .indexTip
        case .middleMCP: .middleMCP
        case .middlePIP: .middlePIP
        case .middleDIP: .middleDIP
        case .middleTip: .middleTip
        case .ringMCP: .ringMCP
        case .ringPIP: .ringPIP
        case .ringDIP: .ringDIP
        case .ringTip: .ringTip
        case .littleMCP: .littleMCP
        case .littlePIP: .littlePIP
        case .littleDIP: .littleDIP
        case .littleTip: .littleTip
        default: nil
        }
    }

    // MARK: Body

    private func detectBody(_ pb: CVPixelBuffer, mirror: Bool) async -> (BodySnapshot?, Double) {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let observations = try await bodyRequest.perform(on: pb, orientation: nil)
            guard let obs = observations.first else { return (nil, (CFAbsoluteTimeGetCurrent() - t) * 1000) }
            var joints: [BodyJoint: TrackedPoint] = [:]
            for (name, joint) in obs.allJoints() {
                guard let mapped = Self.mapBodyJoint(name) else { continue }
                let p = Self.viewPoint(joint.location, mirror: mirror)
                joints[mapped] = TrackedPoint(x: p.x, y: p.y, confidence: joint.confidence)
            }
            return (BodySnapshot(joints: joints), (CFAbsoluteTimeGetCurrent() - t) * 1000)
        } catch {
            log.error("Body pose failed: \(error.localizedDescription, privacy: .public)")
            return (nil, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
    }

    private static func mapBodyJoint(_ name: HumanBodyPoseObservation.JointName) -> BodyJoint? {
        switch name {
        case .nose: .nose
        case .leftEye: .leftEye
        case .rightEye: .rightEye
        case .leftEar: .leftEar
        case .rightEar: .rightEar
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .root: .root
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        default: nil
        }
    }

    private func detectBody3D(_ pb: CVPixelBuffer) async -> (Body3DSnapshot?, Double) {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let observations = try await body3DRequest.perform(on: pb, orientation: nil)
            guard let obs = observations.first else { return (nil, (CFAbsoluteTimeGetCurrent() - t) * 1000) }
            var positions: [String: SIMD3<Float>] = [:]
            for (name, joint) in obs.allJoints() {
                let m = joint.position
                positions[String(describing: name)] = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            }
            let height = Float(obs.bodyHeight.converted(to: .meters).value)
            return (Body3DSnapshot(positions: positions, bodyHeight: height), (CFAbsoluteTimeGetCurrent() - t) * 1000)
        } catch {
            log.error("Body 3D failed: \(error.localizedDescription, privacy: .public)")
            return (nil, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
    }

    // MARK: Segmentation + contours

    private func segmentPerson(_ pb: CVPixelBuffer, mirror: Bool, contours: Bool) async -> (MaskImage?, [[CGPoint]], Double, Double) {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let obs = try await segmentationRequest.perform(on: pb, orientation: nil)
            // OS 27 returns a CVReadOnlyPixelBuffer; unwrap the underlying CVPixelBuffer for Core Image.
            let maskBuffer: CVPixelBuffer = obs.pixelBuffer.withUnsafeBuffer { $0 }
            let segMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            let image = frameProcessor.alphaMask(from: maskBuffer, mirror: mirror)

            var polygons: [[CGPoint]] = []
            var contourMs = 0.0
            if contours {
                let t2 = CFAbsoluteTimeGetCurrent()
                let ci = CIImage(cvPixelBuffer: maskBuffer)
                if let contourObs = try? await contoursRequest.perform(on: ci, orientation: nil) {
                    for contour in contourObs.topLevelContours {
                        // Skip tiny specks, keep the silhouette(s).
                        guard contour.pointCount >= 24 else { continue }
                        let simplified = (try? contour.polygonApproximation(epsilon: 0.004)) ?? contour
                        let pts = simplified.normalizedPoints.map { Self.viewPoint(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)), mirror: mirror) }
                        polygons.append(pts)
                    }
                }
                contourMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000
            }
            return (image, polygons, segMs, contourMs)
        } catch {
            log.error("Segmentation failed: \(error.localizedDescription, privacy: .public)")
            return (nil, [], (CFAbsoluteTimeGetCurrent() - t) * 1000, 0)
        }
    }

    // MARK: Faces

    private func detectFaces(_ pb: CVPixelBuffer, mirror: Bool) async -> ([FaceSnapshot], Double) {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let observations = try await faceRequest.perform(on: pb, orientation: nil)
            var faces: [FaceSnapshot] = []
            for obs in observations {
                let bb = obs.boundingBox.cgRect // normalized, lower-left origin
                let viewBox = Self.viewRect(bb, mirror: mirror)
                var regions: [FaceRegion] = []
                if let lm = obs.landmarks {
                    let named: [(String, FaceObservation.Landmarks2D.Region?)] = [
                        ("faceContour", lm.faceContour), ("leftEye", lm.leftEye), ("rightEye", lm.rightEye),
                        ("leftEyebrow", lm.leftEyebrow), ("rightEyebrow", lm.rightEyebrow), ("nose", lm.nose),
                        ("noseCrest", lm.noseCrest), ("outerLips", lm.outerLips), ("innerLips", lm.innerLips),
                        ("medianLine", lm.medianLine)
                    ]
                    for (name, region) in named {
                        guard let region else { continue }
                        // Using a 1x1 "image" yields normalized full-frame coordinates with an upper-left origin.
                        let pts = region.pointsInImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
                            .map { CGPoint(x: mirror ? 1 - $0.x : $0.x, y: $0.y) }
                        regions.append(FaceRegion(name: name, points: pts, closed: region.pointsClassification == .closedPath))
                    }
                }
                faces.append(FaceSnapshot(boundingBox: viewBox, regions: regions,
                                          roll: CGFloat(obs.roll.converted(to: .radians).value),
                                          yaw: CGFloat(obs.yaw.converted(to: .radians).value)))
            }
            return (faces, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        } catch {
            log.error("Face landmarks failed: \(error.localizedDescription, privacy: .public)")
            return ([], (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
    }

    // MARK: Coordinate conversion

    /// Vision normalized point (bottom-left origin) -> view-normalized (top-left, optionally mirrored).
    nonisolated static func viewPoint(_ p: NormalizedPoint, mirror: Bool) -> CGPoint {
        CGPoint(x: mirror ? 1 - CGFloat(p.x) : CGFloat(p.x), y: 1 - CGFloat(p.y))
    }

    nonisolated static func viewPoint(_ p: CGPoint, mirror: Bool) -> CGPoint {
        CGPoint(x: mirror ? 1 - p.x : p.x, y: 1 - p.y)
    }

    nonisolated static func viewRect(_ r: CGRect, mirror: Bool) -> CGRect {
        let x = mirror ? 1 - r.maxX : r.minX
        let y = 1 - r.maxY
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }
}
