import Foundation
import RealityKit
import SwiftUI
import simd
import OSLog

/// Drives a RealityKit scene that sits exactly over the video rectangle and
/// attaches mesh parts to body bones detected by Vision.
///
/// Camera model: a virtual perspective camera at the origin looking down -Z with
/// a vertical FOV of `fovDegrees`. Everything is placed on the plane z = -distance,
/// so a view-normalized point maps linearly to world space:
///     x = (nx - 0.5) * planeWidth,  y = (0.5 - ny) * planeHeight
///
/// Blender workflow: name objects after `MeshSlot` raw values (head, torso,
/// leftUpperArm, leftForearm, rightUpperArm, rightForearm, leftThigh, leftShin,
/// rightThigh, rightShin, leftHand, rightHand), author each part centered at its
/// origin with +Y running along the bone, export as USDZ, import in the Mesh panel.
/// Parts are rescaled so their Y extent equals the detected bone length. A file
/// without slot names is treated as one whole-body model anchored to the torso.
@MainActor
final class MeshRigController {
    let root = Entity()
    let cameraEntity = Entity()
    let fovDegrees: Float = 60
    let distance: Float = 2.0

    private var slotContainers: [MeshSlot: Entity] = [:]
    private var placeholders: [MeshSlot: ModelEntity] = [:]
    private var importedParts: [MeshSlot: Entity] = [:]
    private var importedWhole: Entity?
    private var isConfigured = false
    private var smoothed: [MeshSlot: (mid: SIMD3<Float>, angle: Float, length: Float)] = [:]
    private let log = Logger(subsystem: "Mirage", category: "MeshRig")

    private(set) var loadedFileName: String?
    private(set) var loadedSlotNames: [MeshSlot] = []
    private(set) var loadError: String?

    // MARK: Scene setup

    func configure(in content: inout RealityViewCameraContent) {
        guard !isConfigured else { return }
        isConfigured = true

        var camera = PerspectiveCameraComponent()
        camera.fieldOfViewInDegrees = fovDegrees
        camera.fieldOfViewOrientation = .vertical
        camera.near = 0.05
        camera.far = 20
        cameraEntity.components.set(camera)
        cameraEntity.position = .zero
        cameraEntity.look(at: SIMD3<Float>(0, 0, -1), from: .zero, relativeTo: nil)
        content.add(cameraEntity)

        for slot in MeshSlot.allCases {
            let container = Entity()
            container.name = "slot.\(slot.rawValue)"
            container.isEnabled = false
            root.addChild(container)
            slotContainers[slot] = container

            let placeholder = Self.makePlaceholder(for: slot)
            container.addChild(placeholder)
            placeholders[slot] = placeholder
        }
        content.add(root)
    }

    private static func makePlaceholder(for slot: MeshSlot) -> ModelEntity {
        let mesh: MeshResource
        switch slot {
        case .head:
            mesh = .generateSphere(radius: 0.5)
        case .leftHand, .rightHand:
            mesh = .generateBox(size: SIMD3<Float>(0.8, 1, 0.3), cornerRadius: 0.15)
        default:
            mesh = .generateBox(size: SIMD3<Float>(1, 1, 1), cornerRadius: 0.35)
        }
        var material = UnlitMaterial(color: .init(red: 0.0, green: 0.94, blue: 1.0, alpha: 0.55))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "placeholder.\(slot.rawValue)"
        return entity
    }

    // MARK: Import

    func load(url: URL, fileName: String) async {
        loadError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let entity = try await Entity(contentsOf: url)
            install(model: entity, fileName: fileName)
        } catch {
            loadError = "모델을 열 수 없습니다: \(error.localizedDescription)"
            log.error("Rig load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearImported() {
        for (_, part) in importedParts { part.removeFromParent() }
        importedParts.removeAll()
        importedWhole?.removeFromParent()
        importedWhole = nil
        loadedFileName = nil
        loadedSlotNames = []
    }

    private func install(model: Entity, fileName: String) {
        clearImported()
        loadedFileName = fileName

        // Look for parts named after slots anywhere in the hierarchy (case-insensitive).
        var found: [MeshSlot: Entity] = [:]
        var stack: [Entity] = [model]
        while let e = stack.popLast() {
            let lower = e.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ".", with: "")
            for slot in MeshSlot.allCases where found[slot] == nil {
                let key = slot.rawValue.lowercased()
                if lower == key || lower.hasPrefix(key) { found[slot] = e }
            }
            stack.append(contentsOf: e.children)
        }

        if found.isEmpty {
            // Whole model → torso slot, normalized so that its height == 1 bone unit.
            let normalized = Self.normalized(model)
            slotContainers[.torso]?.addChild(normalized)
            importedWhole = normalized
            loadedSlotNames = [.torso]
            log.info("Rig: whole model attached to torso")
        } else {
            for (slot, part) in found {
                part.removeFromParent()
                let normalized = Self.normalized(part)
                slotContainers[slot]?.addChild(normalized)
                importedParts[slot] = normalized
            }
            loadedSlotNames = Array(found.keys).sorted { $0.rawValue < $1.rawValue }
            log.info("Rig: attached parts \(self.loadedSlotNames.map(\.rawValue).joined(separator: ","), privacy: .public)")
        }
    }

    /// Wraps an entity so that it is centered and its Y extent is exactly 1.
    private static func normalized(_ entity: Entity) -> Entity {
        let wrapper = Entity()
        wrapper.name = "normalized.\(entity.name)"
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = max(0.0001, bounds.extents.y)
        let scale = 1 / height
        entity.position = -bounds.center * scale
        entity.scale = SIMD3<Float>(repeating: scale)
        wrapper.addChild(entity)
        return wrapper
    }

    // MARK: Per-frame update

    func update(analysis: FrameAnalysis?, settings: MeshRigSettings, aspect: Float, palette: [String]) {
        guard isConfigured else { return }
        let planeHeight = 2 * distance * tan(fovDegrees * .pi / 180 / 2)
        let planeWidth = planeHeight * max(0.1, aspect)
        let hasImport = importedWhole != nil || !importedParts.isEmpty
        let rigVisible = settings.mode.showsRig

        // Tint placeholders with the first palette color.
        if let first = palette.rgbaColors.first {
            for (_, p) in placeholders {
                var m = UnlitMaterial(color: .init(red: first.r, green: first.g, blue: first.b, alpha: 0.55))
                m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
                p.model?.materials = [m]
            }
        }

        func world(_ p: CGPoint) -> SIMD3<Float> {
            SIMD3<Float>(Float(p.x - 0.5) * planeWidth, Float(0.5 - p.y) * planeHeight, -distance)
        }

        for slot in MeshSlot.allCases {
            guard let container = slotContainers[slot] else { continue }
            var enabled = rigVisible && settings.enabledSlots.contains(slot)
            var start: CGPoint?
            var end: CGPoint?

            if let bone = slot.bone, let body = analysis?.body {
                start = body.point(bone.0)
                end = body.point(bone.1)
                if slot == .torso, let s = body.hipCenter, let e = body.shoulderCenter { start = s; end = e }
                if slot == .head, let n = body.point(.neck), let nose = body.point(.nose) {
                    // Head bone: neck -> a bit above the nose so the sphere covers the face.
                    start = n
                    end = CGPoint(x: nose.x + (nose.x - n.x) * 0.6, y: nose.y + (nose.y - n.y) * 0.6)
                }
            } else if let side = slot.handSide, let hand = analysis?.hands.first(where: { $0.side == side }) {
                if let w = hand.point(.wrist), let m = hand.point(.middleMCP) {
                    start = w
                    end = CGPoint(x: m.x + (m.x - w.x) * 0.9, y: m.y + (m.y - w.y) * 0.9)
                }
            }

            guard let s = start, let e = end, enabled else {
                container.isEnabled = false
                continue
            }

            let ws = world(s), we = world(e)
            let mid = (ws + we) / 2
            let dir = we - ws
            let length = max(0.02, simd_length(SIMD2<Float>(dir.x, dir.y)))
            let angle = atan2(dir.y, dir.x) - .pi / 2

            // Exponential smoothing keeps the parts from jittering with Vision noise.
            var sm = smoothed[slot] ?? (mid, angle, length)
            let k: Float = 0.45
            sm.mid += (mid - sm.mid) * k
            var dAngle = angle - sm.angle
            while dAngle > .pi { dAngle -= 2 * .pi }
            while dAngle < -.pi { dAngle += 2 * .pi }
            sm.angle += dAngle * k
            sm.length += (length - sm.length) * k
            smoothed[slot] = sm

            container.isEnabled = true
            container.position = sm.mid
            container.orientation = simd_quatf(angle: sm.angle, axis: SIMD3<Float>(0, 0, 1))

            let thickness = slot.placeholderThickness
            let rigScale = Float(settings.rigScale)
            if let placeholder = placeholders[slot] {
                let showPlaceholder = settings.showPlaceholders && importedParts[slot] == nil && !(slot == .torso && importedWhole != nil)
                placeholder.isEnabled = showPlaceholder || !hasImport
                placeholder.scale = SIMD3<Float>(sm.length * thickness, sm.length, sm.length * thickness) * rigScale
            }
            if let part = importedParts[slot] {
                part.scale = SIMD3<Float>(repeating: sm.length * rigScale)
            }
            if slot == .torso, let whole = importedWhole {
                // Torso bone ≈ 1/2.4 of total height; scale the whole body accordingly.
                whole.scale = SIMD3<Float>(repeating: sm.length * 2.4 * rigScale)
                whole.position = SIMD3<Float>(0, -sm.length * 0.15, 0)
            }
            enabled = true
        }
    }
}

/// SwiftUI host for the rig. Place it exactly over the video rectangle.
struct MeshRigView: View {
    @Environment(AppModel.self) private var app
    let aspect: CGFloat

    var body: some View {
        RealityView { content in
            app.rig.configure(in: &content)
            app.rig.update(analysis: app.analysis, settings: app.meshSettings, aspect: Float(aspect), palette: app.preset.palette)
        } update: { content in
            app.rig.update(analysis: app.analysis, settings: app.meshSettings, aspect: Float(aspect), palette: app.preset.palette)
        }
        .allowsHitTesting(false)
    }
}
