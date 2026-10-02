import Foundation
import CoreGraphics
import FoundationModels

// MARK: - Coordinate conventions
//
// Every point in these models is "view-normalized": x and y in 0...1,
// origin at the TOP-LEFT of the displayed (optionally mirrored) frame.
// The Vision pipeline converts from Vision's bottom-left origin once,
// so gesture logic, effects and the mesh rig never think about flips.

nonisolated struct TrackedPoint: Sendable, Hashable, Codable {
    var x: CGFloat
    var y: CGFloat
    var confidence: Float

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - Hands

nonisolated enum HandSide: String, Codable, Sendable, CaseIterable {
    case left, right, unknown

    var displayName: String {
        switch self {
        case .left: "왼손"
        case .right: "오른손"
        case .unknown: "손"
        }
    }
}

nonisolated enum HandJoint: String, CaseIterable, Codable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    static let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
    static let knuckles: [HandJoint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]

    /// Skeleton bones used for drawing and for the hand mesh slot.
    static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]
}

nonisolated enum Finger: String, CaseIterable, Codable, Sendable {
    case thumb, index, middle, ring, little

    var tip: HandJoint {
        switch self {
        case .thumb: .thumbTip
        case .index: .indexTip
        case .middle: .middleTip
        case .ring: .ringTip
        case .little: .littleTip
        }
    }

    var base: HandJoint {
        switch self {
        case .thumb: .thumbCMC
        case .index: .indexMCP
        case .middle: .middleMCP
        case .ring: .ringMCP
        case .little: .littleMCP
        }
    }

    var middleJoint: HandJoint {
        switch self {
        case .thumb: .thumbMP
        case .index: .indexPIP
        case .middle: .middlePIP
        case .ring: .ringPIP
        case .little: .littlePIP
        }
    }
}

nonisolated struct HandSnapshot: Sendable, Identifiable, Hashable {
    var id: String
    var side: HandSide
    var joints: [HandJoint: TrackedPoint]
    var confidence: Float

    func point(_ joint: HandJoint, minimumConfidence: Float = 0.3) -> CGPoint? {
        guard let p = joints[joint], p.confidence >= minimumConfidence else { return nil }
        return p.cgPoint
    }

    /// Mean of wrist + four knuckles. Falls back to whatever is available.
    var palmCenter: CGPoint {
        let candidates = ([.wrist] + HandJoint.knuckles).compactMap { point($0) }
        guard !candidates.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = candidates.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(candidates.count), y: sum.y / CGFloat(candidates.count))
    }

    /// Distance wrist -> middle knuckle, a scale-invariant "hand size" in view units.
    var palmSize: CGFloat {
        guard let w = point(.wrist), let m = point(.middleMCP) else { return 0.08 }
        return max(0.02, hypot(w.x - m.x, w.y - m.y))
    }

    var boundingBox: CGRect {
        let pts = joints.values.map(\.cgPoint)
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Body

nonisolated enum BodyJoint: String, CaseIterable, Codable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case neck, leftShoulder, rightShoulder
    case leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, root
    case leftKnee, rightKnee, leftAnkle, rightAnkle

    static let bones: [(BodyJoint, BodyJoint)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
}

nonisolated struct BodySnapshot: Sendable, Hashable {
    var joints: [BodyJoint: TrackedPoint]

    func point(_ joint: BodyJoint, minimumConfidence: Float = 0.45) -> CGPoint? {
        guard let p = joints[joint], p.confidence >= minimumConfidence else { return nil }
        return p.cgPoint
    }

    /// Midpoint between the shoulders, or nil when the torso isn't visible.
    var shoulderCenter: CGPoint? {
        guard let l = point(.leftShoulder), let r = point(.rightShoulder) else { return point(.neck) }
        return CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
    }

    var hipCenter: CGPoint? {
        if let root = point(.root) { return root }
        guard let l = point(.leftHip), let r = point(.rightHip) else { return nil }
        return CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
    }

    var shoulderWidth: CGFloat {
        guard let l = point(.leftShoulder), let r = point(.rightShoulder) else { return 0.2 }
        return max(0.05, hypot(l.x - r.x, l.y - r.y))
    }
}

/// Camera-relative 3D joints from `DetectHumanBodyPose3DRequest` (meters).
nonisolated struct Body3DSnapshot: Sendable {
    var positions: [String: SIMD3<Float>]
    var bodyHeight: Float
}

// MARK: - Face

nonisolated struct FaceSnapshot: Sendable, Hashable {
    var boundingBox: CGRect
    /// Each region is a polyline in view-normalized coordinates. `closed` says whether to close it.
    var regions: [FaceRegion]
    var roll: CGFloat?
    var yaw: CGFloat?
}

nonisolated struct FaceRegion: Sendable, Hashable {
    var name: String
    var points: [CGPoint]
    var closed: Bool

    static func == (lhs: FaceRegion, rhs: FaceRegion) -> Bool {
        lhs.name == rhs.name && lhs.closed == rhs.closed && lhs.points.count == rhs.points.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(points.count)
    }
}

// MARK: - Frame analysis

/// Wrapper so a CGImage can travel between the Vision actor and the main actor.
nonisolated struct MaskImage: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
}

nonisolated struct FrameAnalysis: Sendable {
    var timestamp: TimeInterval
    var imageSize: CGSize
    var hands: [HandSnapshot] = []
    var body: BodySnapshot?
    var body3D: Body3DSnapshot?
    var faces: [FaceSnapshot] = []
    var personMask: MaskImage?
    /// Silhouette polygons in view-normalized coordinates.
    var contours: [[CGPoint]] = []
    var processingMillis: Double = 0
    var stageTimings: [String: Double] = [:]

    static let empty = FrameAnalysis(timestamp: 0, imageSize: CGSize(width: 1280, height: 720))
}

// MARK: - Gestures

@Generable(description: "A hand gesture the camera can recognize")
nonisolated enum GestureKind: String, CaseIterable, Codable, Sendable {
    // Static (single hand)
    case openPalm, fist, pinch, point, peace, thumbsUp, rockOn, okSign
    // Dynamic (single hand)
    case swipeLeft, swipeRight, swipeUp, swipeDown, wave
    // Two hands
    case spread, squeeze, clap

    var displayName: String {
        switch self {
        case .openPalm: "보자기 (손바닥)"
        case .fist: "주먹"
        case .pinch: "핀치"
        case .point: "포인팅"
        case .peace: "브이"
        case .thumbsUp: "엄지척"
        case .rockOn: "락온 🤘"
        case .okSign: "OK 👌"
        case .swipeLeft: "스와이프 ←"
        case .swipeRight: "스와이프 →"
        case .swipeUp: "스와이프 ↑"
        case .swipeDown: "스와이프 ↓"
        case .wave: "흔들기"
        case .spread: "양손 벌리기"
        case .squeeze: "양손 모으기"
        case .clap: "박수"
        }
    }

    var symbolName: String {
        switch self {
        case .openPalm: "hand.raised.fill"
        case .fist: "hand.thumbsup.fill"
        case .pinch: "hand.pinch.fill"
        case .point: "hand.point.up.left.fill"
        case .peace: "hand.wave.fill"
        case .thumbsUp: "hand.thumbsup.fill"
        case .rockOn: "guitars.fill"
        case .okSign: "circle.circle"
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        case .swipeUp: "arrow.up"
        case .swipeDown: "arrow.down"
        case .wave: "hand.wave"
        case .spread: "arrow.left.and.right"
        case .squeeze: "arrow.right.and.line.vertical.and.arrow.left"
        case .clap: "hands.clap.fill"
        }
    }

    var isDynamic: Bool {
        switch self {
        case .swipeLeft, .swipeRight, .swipeUp, .swipeDown, .wave, .spread, .squeeze, .clap: true
        default: false
        }
    }

    var isTwoHanded: Bool {
        switch self {
        case .spread, .squeeze, .clap: true
        default: false
        }
    }
}

nonisolated struct GestureEvent: Sendable, Identifiable, Hashable {
    var id = UUID()
    var kind: GestureKind
    var side: HandSide
    var position: CGPoint
    /// 0...1 where meaningful (pinch depth, swipe speed), else 1.
    var strength: CGFloat = 1
    var timestamp: TimeInterval
}

/// Per-hand continuous state published every analyzed frame.
nonisolated struct HandGestureState: Sendable, Identifiable, Hashable {
    var id: String
    var side: HandSide
    var staticGesture: GestureKind?
    var pinchStrength: CGFloat
    var openness: CGFloat
    var extended: [Finger]
    var palmCenter: CGPoint
    var palmSize: CGFloat
    var velocity: CGVector
    var holdDuration: TimeInterval
}

// MARK: - Effects

@Generable(description: "A visual layer drawn over the camera image")
nonisolated enum EffectLayer: String, CaseIterable, Codable, Sendable, Identifiable {
    case trails, sparks, skeleton, lightPainting, forceField
    case distortion, kaleidoscope, constellation, auraOutline, wireframeSkin, faceMesh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trails: "손끝 리본 트레일"
        case .sparks: "스파크 파티클"
        case .skeleton: "네온 스켈레톤"
        case .lightPainting: "라이트 페인팅"
        case .forceField: "포스 필드 (리플)"
        case .distortion: "손바닥 왜곡 렌즈"
        case .kaleidoscope: "만화경"
        case .constellation: "별자리 연결선"
        case .auraOutline: "실루엣 오라"
        case .wireframeSkin: "와이어프레임 스킨"
        case .faceMesh: "페이스 랜드마크"
        }
    }

    var detail: String {
        switch self {
        case .trails: "다섯 손끝이 지나간 자리에 색 리본이 남습니다."
        case .sparks: "손끝에서 입자가 튀고, 주먹은 끌어당기고 손바닥은 밀어냅니다."
        case .skeleton: "Vision 손/몸 관절 21+19개를 네온 라인으로 그립니다."
        case .lightPainting: "핀치로 허공에 그림을 그리고 브이로 지웁니다."
        case .forceField: "손바닥을 펴면 동심원 충격파가 퍼집니다."
        case .distortion: "Core Image 범프 렌즈가 손바닥을 따라다니며 주먹이면 빨려듭니다."
        case .kaleidoscope: "양손 사이 중심으로 6면 만화경이 펼쳐집니다."
        case .constellation: "손끝 근처 입자들을 선으로 이어 별자리를 만듭니다."
        case .auraOutline: "사람 세그멘테이션 윤곽을 따라 빛나는 테두리를 그립니다."
        case .wireframeSkin: "실루엣 안쪽에 삼각 메시를 입히고 손이 가까우면 밀립니다."
        case .faceMesh: "76개 얼굴 랜드마크 윤곽을 그립니다."
        }
    }

    var symbolName: String {
        switch self {
        case .trails: "scribble.variable"
        case .sparks: "sparkles"
        case .skeleton: "figure.wave"
        case .lightPainting: "paintbrush.pointed.fill"
        case .forceField: "circle.hexagongrid"
        case .distortion: "camera.filters"
        case .kaleidoscope: "hexagon.fill"
        case .constellation: "star.circle"
        case .auraOutline: "person.crop.rectangle"
        case .wireframeSkin: "grid"
        case .faceMesh: "faceid"
        }
    }

    /// Layers that need the person-segmentation mask.
    var needsMask: Bool { self == .auraOutline || self == .wireframeSkin }
}

@Generable(description: "What happens when a gesture is recognized")
nonisolated enum GestureAction: String, CaseIterable, Codable, Sendable {
    case none, burst, attract, repel, paint, clearCanvas, nextPalette, cyclePreset
    case toggleKaleidoscope, toggleMesh, freezeFrame, snapshot

    var displayName: String {
        switch self {
        case .none: "없음"
        case .burst: "입자 폭발"
        case .attract: "끌어당김"
        case .repel: "밀어냄"
        case .paint: "그리기"
        case .clearCanvas: "캔버스 지우기"
        case .nextPalette: "팔레트 전환"
        case .cyclePreset: "다음 프리셋"
        case .toggleKaleidoscope: "만화경 토글"
        case .toggleMesh: "메시 토글"
        case .freezeFrame: "프레임 정지"
        case .snapshot: "스냅샷 저장"
        }
    }
}

@Generable(description: "Binds one gesture to one action")
nonisolated struct GestureBinding: Codable, Sendable, Hashable, Identifiable {
    var gesture: GestureKind
    var action: GestureAction

    var id: String { gesture.rawValue }
}

@Generable(description: "A complete visual effect preset for a camera gesture app")
nonisolated struct EffectPreset: Codable, Sendable, Hashable, Identifiable {
    @Guide(description: "Short evocative preset name, 1-3 words")
    var name: String

    @Guide(description: "One sentence describing the mood of the visuals")
    var mood: String

    @Guide(description: "Which layers are enabled", .minimumCount(1), .maximumCount(6))
    var layers: [EffectLayer]

    @Guide(description: "2 to 4 hex colors such as #FF6A00", .minimumCount(2), .maximumCount(4))
    var palette: [String]

    @Guide(description: "Particle emission amount", .range(1...10))
    var intensity: Int

    @Guide(description: "How long trails and paint persist", .range(1...10))
    var persistence: Int

    @Guide(description: "Gesture to action bindings", .maximumCount(8))
    var bindings: [GestureBinding]

    var id: String { name }

    func action(for gesture: GestureKind) -> GestureAction {
        bindings.first(where: { $0.gesture == gesture })?.action ?? .none
    }

    func contains(_ layer: EffectLayer) -> Bool { layers.contains(layer) }
}

extension EffectPreset {
    static let defaultBindings: [GestureBinding] = [
        GestureBinding(gesture: .peace, action: .burst),
        GestureBinding(gesture: .fist, action: .attract),
        GestureBinding(gesture: .openPalm, action: .repel),
        GestureBinding(gesture: .pinch, action: .paint),
        GestureBinding(gesture: .swipeLeft, action: .clearCanvas),
        GestureBinding(gesture: .thumbsUp, action: .nextPalette),
        GestureBinding(gesture: .swipeRight, action: .cyclePreset),
        GestureBinding(gesture: .spread, action: .toggleKaleidoscope)
    ]

    static let builtIn: [EffectPreset] = [
        EffectPreset(
            name: "Ember",
            mood: "따뜻한 불씨가 손끝을 따라 흩날립니다.",
            layers: [.trails, .sparks, .skeleton, .forceField],
            palette: ["#FF6A00", "#FFB347", "#FFE066", "#FF3D3D"],
            intensity: 7, persistence: 5,
            bindings: defaultBindings
        ),
        EffectPreset(
            name: "Neon Wire",
            mood: "어두운 방 안에 네온 뼈대와 와이어 피부만 떠 있습니다.",
            layers: [.skeleton, .wireframeSkin, .auraOutline, .constellation],
            palette: ["#00F0FF", "#FF00E5", "#7CFF00"],
            intensity: 4, persistence: 4,
            bindings: defaultBindings
        ),
        EffectPreset(
            name: "Glass Lens",
            mood: "손바닥이 유리 렌즈가 되어 공간을 구부립니다.",
            layers: [.distortion, .trails, .forceField],
            palette: ["#9AE6FF", "#FFFFFF", "#5B8CFF"],
            intensity: 5, persistence: 3,
            bindings: defaultBindings
        ),
        EffectPreset(
            name: "Kaleido",
            mood: "양손을 벌리면 만화경이 열립니다.",
            layers: [.kaleidoscope, .sparks, .trails],
            palette: ["#FF4FD8", "#FFD84F", "#4FFFE0", "#8A4FFF"],
            intensity: 6, persistence: 6,
            bindings: defaultBindings
        ),
        EffectPreset(
            name: "Light Painter",
            mood: "핀치로 허공에 빛을 그리는 조용한 스튜디오.",
            layers: [.lightPainting, .trails, .constellation],
            palette: ["#FFFFFF", "#FFE9A6", "#A6D8FF"],
            intensity: 3, persistence: 10,
            bindings: defaultBindings
        ),
        EffectPreset(
            name: "Aurora Skin",
            mood: "실루엣 위로 오로라가 흐릅니다.",
            layers: [.auraOutline, .wireframeSkin, .sparks, .faceMesh],
            palette: ["#43FFB0", "#4FB0FF", "#B04FFF", "#FF4FA0"],
            intensity: 5, persistence: 7,
            bindings: defaultBindings
        )
    ]
}

// MARK: - Mesh rig

/// A body "slot" a Blender-authored part can attach to. Each slot is a bone
/// defined by two joints; the part is positioned at the midpoint, rotated to
/// the bone direction and scaled to its length.
nonisolated enum MeshSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case head, torso
    case leftUpperArm, leftForearm, rightUpperArm, rightForearm
    case leftThigh, leftShin, rightThigh, rightShin
    case leftHand, rightHand

    var id: String { rawValue }

    /// Body joints that define the bone (start, end). Hands use hand joints instead.
    var bone: (BodyJoint, BodyJoint)? {
        switch self {
        case .head: (.neck, .nose)
        case .torso: (.root, .neck)
        case .leftUpperArm: (.leftShoulder, .leftElbow)
        case .leftForearm: (.leftElbow, .leftWrist)
        case .rightUpperArm: (.rightShoulder, .rightElbow)
        case .rightForearm: (.rightElbow, .rightWrist)
        case .leftThigh: (.leftHip, .leftKnee)
        case .leftShin: (.leftKnee, .leftAnkle)
        case .rightThigh: (.rightHip, .rightKnee)
        case .rightShin: (.rightKnee, .rightAnkle)
        case .leftHand, .rightHand: nil
        }
    }

    var handSide: HandSide? {
        switch self {
        case .leftHand: .left
        case .rightHand: .right
        default: nil
        }
    }

    /// Thickness relative to bone length for the procedural placeholder.
    var placeholderThickness: Float {
        switch self {
        case .head: 0.9
        case .torso: 0.55
        case .leftHand, .rightHand: 0.7
        default: 0.28
        }
    }

    var displayName: String {
        switch self {
        case .head: "머리"
        case .torso: "몸통"
        case .leftUpperArm: "왼 위팔"
        case .leftForearm: "왼 아래팔"
        case .rightUpperArm: "오른 위팔"
        case .rightForearm: "오른 아래팔"
        case .leftThigh: "왼 허벅지"
        case .leftShin: "왼 정강이"
        case .rightThigh: "오른 허벅지"
        case .rightShin: "오른 정강이"
        case .leftHand: "왼손"
        case .rightHand: "오른손"
        }
    }
}

@Generable(description: "How the body mesh is displayed")
nonisolated enum MeshMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, wireframe, rigged, both
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: "끄기"
        case .wireframe: "와이어프레임 스킨"
        case .rigged: "3D 리그 (USDZ)"
        case .both: "둘 다"
        }
    }
    var showsWireframe: Bool { self == .wireframe || self == .both }
    var showsRig: Bool { self == .rigged || self == .both }
}

nonisolated struct MeshRigSettings: Codable, Sendable, Equatable {
    var mode: MeshMode = .wireframe
    var wireframeDensity: Int = 14
    var wireframeColor: String = "#00F0FF"
    var wireframeOpacity: Double = 0.75
    var breathing: Bool = true
    var handPush: Bool = true
    /// Bookmark to the imported USDZ/USDC/USDA/OBJ file.
    var rigBookmark: Data?
    var rigFileName: String?
    var enabledSlots: Set<MeshSlot> = Set(MeshSlot.allCases)
    var rigScale: Double = 1.0
    var showPlaceholders: Bool = true
}

// MARK: - Vision configuration

nonisolated enum SegmentationQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fast: "빠름"
        case .balanced: "균형"
        case .accurate: "정밀"
        }
    }
}

nonisolated struct VisionConfig: Codable, Sendable, Equatable {
    var hands = true
    var maxHands = 2
    var body = true
    var body3D = false
    var segmentation = true
    var segmentationQuality: SegmentationQuality = .balanced
    var faceLandmarks = true
    var contours = true
    var mirror = true
    var minimumJointConfidence: Float = 0.3
}

// MARK: - Helpers

nonisolated extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
    func lerp(to other: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }
}

nonisolated extension Array where Element == String {
    /// Hex palette -> RGBA tuples 0...1 (invalid strings become white).
    var rgbaColors: [(r: Double, g: Double, b: Double, a: Double)] {
        map { hex in
            var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else {
                return (1, 1, 1, 1)
            }
            if s.count == 6 {
                return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
            }
            return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }
}
