import SwiftUI

/// The camera stage: video + all effect layers + HUD, with the optional
/// RealityKit rig layered exactly over the video rectangle.
struct StageView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let rect = Self.videoRect(in: geo.size, aspect: app.analysis?.imageSize ?? CGSize(width: 16, height: 9))
            ZStack {
                Color.black
                TimelineView(.animation) { timeline in
                    StageCanvas(now: timeline.date.timeIntervalSinceReferenceDate, rect: rect)
                }
                if app.meshSettings.mode.showsRig {
                    MeshRigView(aspect: rect.width / max(1, rect.height))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                if app.showHUD {
                    StageHUD(rect: rect)
                }
            }
            .onChange(of: app.snapshotRequest) { _, request in
                guard request != nil else { return }
                let renderer = ImageRenderer(content: StageCanvas(now: Date().timeIntervalSinceReferenceDate, rect: CGRect(origin: .zero, size: rect.size))
                    .environment(app)
                    .frame(width: rect.width, height: rect.height))
                renderer.scale = 2
                if let cg = renderer.cgImage { app.saveSnapshot(cg) }
            }
        }
        .background(Color.black)
    }

    static func videoRect(in size: CGSize, aspect: CGSize) -> CGRect {
        let a = aspect.width / max(1, aspect.height)
        var w = size.width
        var h = w / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Canvas

struct StageCanvas: View {
    @Environment(AppModel.self) private var app
    let now: TimeInterval
    let rect: CGRect

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            let kaleido = app.kaleidoscopeOn && app.preset.contains(.kaleidoscope)
            app.engine.step(now: now, preset: app.preset, hands: app.handStates, analysis: app.analysis, kaleidoscopeOn: kaleido)
            var renderer = StageRenderer(context: context, rect: rect, now: now, app: app)
            renderer.drawAll()
        }
    }
}

/// All Canvas drawing lives here so it can also be used by `ImageRenderer` for snapshots.
@MainActor
struct StageRenderer {
    var context: GraphicsContext
    let rect: CGRect
    let now: TimeInterval
    let app: AppModel

    private var colors: [Color]
    private let preset: EffectPreset
    private let analysis: FrameAnalysis?

    init(context: GraphicsContext, rect: CGRect, now: TimeInterval, app: AppModel) {
        self.context = context
        self.rect = rect
        self.now = now
        self.app = app
        self.preset = app.preset
        self.analysis = app.analysis
        let rgba = app.preset.palette.rgbaColors
        let offset = app.engine.paletteOffset
        colors = (0..<max(1, rgba.count)).map { i in
            let c = rgba[(i + offset) % rgba.count]
            return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }
    }

    private func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }

    private func pt(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    private func len(_ v: CGFloat) -> CGFloat { v * rect.height }

    mutating func drawAll() {
        drawBackground()
        if preset.contains(.auraOutline) { drawAuraOutline() }
        if preset.contains(.wireframeSkin) || app.meshSettings.mode.showsWireframe { drawWireframeSkin() }
        if preset.contains(.lightPainting) { drawStrokes() }
        if preset.contains(.trails) { drawTrails() }
        if preset.contains(.constellation) { drawConstellation() }
        if preset.contains(.sparks) || preset.contains(.constellation) { drawParticles() }
        if preset.contains(.forceField) { drawRipples() }
        if preset.contains(.skeleton) { drawSkeleton() }
        if preset.contains(.faceMesh) { drawFaces() }
        drawBursts()
    }

    // MARK: Background / video

    private mutating func drawBackground() {
        if let image = app.frameImage {
            context.draw(Image(decorative: image, scale: 1), in: rect)
            if app.frozen {
                context.fill(Path(rect), with: .color(.black.opacity(0.15)))
            }
        } else {
            // Demo / no camera: a slow-moving dark gradient.
            let t = now * 0.1
            let c0 = Color(hue: (0.6 + sin(t) * 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.18)
            let c1 = Color(hue: (0.75 + cos(t * 0.7) * 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.08)
            context.fill(Path(rect), with: .linearGradient(Gradient(colors: [c0, c1]), startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            // Faint floor grid for depth.
            var grid = Path()
            for i in 0...12 {
                let x = rect.minX + rect.width * CGFloat(i) / 12
                grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for i in 0...7 {
                let y = rect.minY + rect.height * CGFloat(i) / 7
                grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
        }
    }

    // MARK: Aura outline

    private mutating func drawAuraOutline() {
        guard let contours = analysis?.contours, !contours.isEmpty else { return }
        var path = Path()
        for poly in contours where poly.count > 2 {
            path.move(to: pt(poly[0]))
            for p in poly.dropFirst() { path.addLine(to: pt(p)) }
            path.closeSubpath()
        }
        let hueShift = Int(now * 0.8) % colors.count
        var glow = context
        glow.addFilter(.blur(radius: len(0.02)))
        glow.blendMode = .plusLighter
        glow.stroke(path, with: .color(color(hueShift).opacity(0.9)), lineWidth: len(0.018))
        var glow2 = context
        glow2.addFilter(.blur(radius: len(0.006)))
        glow2.blendMode = .plusLighter
        glow2.stroke(path, with: .color(color(hueShift + 1).opacity(0.8)), lineWidth: len(0.006))
        context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
    }

    // MARK: Wireframe skin

    private mutating func drawWireframeSkin() {
        guard let analysis else { return }
        let settings = app.meshSettings

        // Region: union of contour boxes, else body joints.
        var box: CGRect?
        for poly in analysis.contours {
            guard let f = poly.first else { continue }
            var b = CGRect(origin: f, size: .zero)
            for p in poly { b = b.union(CGRect(origin: p, size: .zero)) }
            box = box.map { $0.union(b) } ?? b
        }
        if box == nil, let body = analysis.body {
            let pts = body.joints.values.map(\.cgPoint)
            if let f = pts.first {
                var b = CGRect(origin: f, size: .zero)
                for p in pts { b = b.union(CGRect(origin: p, size: .zero)) }
                box = b.insetBy(dx: -0.08, dy: -0.1)
            }
        }
        guard let region = box?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), region.width > 0.02, region.height > 0.02 else { return }

        let cols = max(4, min(40, settings.wireframeDensity))
        let rows = max(4, min(60, Int(CGFloat(cols) * (region.height / region.width) * (rect.width / rect.height))))
        let hands = app.handStates
        let t = CGFloat(now)

        var verts: [[CGPoint]] = []
        verts.reserveCapacity(rows + 1)
        for r in 0...rows {
            var row: [CGPoint] = []
            row.reserveCapacity(cols + 1)
            for c in 0...cols {
                var v = CGPoint(x: region.minX + region.width * CGFloat(c) / CGFloat(cols),
                                y: region.minY + region.height * CGFloat(r) / CGFloat(rows))
                if settings.breathing {
                    v.x += sin(t * 2.0 + v.y * 9 + v.x * 4) * 0.004
                    v.y += cos(t * 1.6 + v.x * 11) * 0.003
                }
                if settings.handPush {
                    for h in hands {
                        let d = v - h.palmCenter
                        let dist = hypot(d.x, d.y)
                        let radius = h.palmSize * 2.6
                        if dist < radius && dist > 0.0001 {
                            let push = (radius - dist) * 0.55 * (h.staticGesture == .fist ? -0.6 : 1)
                            v.x += d.x / dist * push
                            v.y += d.y / dist * push
                        }
                    }
                }
                row.append(v)
            }
            verts.append(row)
        }

        var mesh = Path()
        for r in 0..<rows {
            for c in 0..<cols {
                let a = pt(verts[r][c]), b = pt(verts[r][c + 1]), d = pt(verts[r + 1][c])
                mesh.move(to: a); mesh.addLine(to: b)
                mesh.move(to: a); mesh.addLine(to: d)
                // Diagonal gives the triangulated look.
                mesh.move(to: b); mesh.addLine(to: d)
            }
            mesh.move(to: pt(verts[r][cols])); mesh.addLine(to: pt(verts[r + 1][cols]))
        }
        for c in 0..<cols { mesh.move(to: pt(verts[rows][c])); mesh.addLine(to: pt(verts[rows][c + 1])) }

        let rgba = [settings.wireframeColor].rgbaColors[0]
        let wire = Color(red: rgba.r, green: rgba.g, blue: rgba.b)
        let opacity = settings.wireframeOpacity

        var dots = Path()
        for row in verts { for v in row { dots.addEllipse(in: CGRect(origin: pt(v), size: .zero).insetBy(dx: -1.2, dy: -1.2)) } }

        // A copy of the context shares the drawing surface, so clipping the copy is enough.
        var ctx = context
        if let mask = analysis.personMask {
            let maskImage = Image(decorative: mask.image, scale: 1)
            let r = rect
            ctx.clipToLayer(opacity: 1) { layer in
                layer.draw(maskImage, in: r)
            }
        } else if !analysis.contours.isEmpty {
            var clip = Path()
            for poly in analysis.contours where poly.count > 2 {
                clip.move(to: pt(poly[0]))
                for p in poly.dropFirst() { clip.addLine(to: pt(p)) }
                clip.closeSubpath()
            }
            ctx.clip(to: clip)
        }

        var glow = ctx
        glow.addFilter(.blur(radius: 3))
        glow.blendMode = .plusLighter
        glow.stroke(mesh, with: .color(wire.opacity(0.5 * opacity)), lineWidth: 2.5)
        ctx.stroke(mesh, with: .color(wire.opacity(opacity)), lineWidth: 0.8)
        ctx.fill(dots, with: .color(.white.opacity(0.7 * opacity)))
    }

    // MARK: Strokes (light painting)

    private mutating func drawStrokes() {
        for stroke in app.engine.strokes where stroke.points.count > 1 {
            var path = Path()
            path.move(to: pt(stroke.points[0]))
            for p in stroke.points.dropFirst() { path.addLine(to: pt(p)) }
            var glow = context
            glow.addFilter(.blur(radius: 6))
            glow.blendMode = .plusLighter
            glow.stroke(path, with: .color(color(stroke.colorIndex).opacity(0.9)), style: StrokeStyle(lineWidth: stroke.width * 2.2, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: stroke.width * 0.6, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Trails

    private mutating func drawTrails() {
        let keep = 0.25 + CGFloat(preset.persistence) / 10 * 0.9
        var index = 0
        var glow = context
        glow.blendMode = .plusLighter
        for (_, trail) in app.engine.trails.sorted(by: { $0.key < $1.key }) {
            let pts = trail.points
            guard pts.count > 1 else { continue }
            let c = color(index)
            index += 1
            for i in 1..<pts.count {
                let age = CGFloat(now - pts[i].t)
                let life = max(0, 1 - age / keep)
                guard life > 0 else { continue }
                var seg = Path()
                seg.move(to: pt(pts[i - 1].p)); seg.addLine(to: pt(pts[i].p))
                glow.stroke(seg, with: .color(c.opacity(0.85 * life)), style: StrokeStyle(lineWidth: 1 + 6 * life, lineCap: .round))
            }
        }
    }

    // MARK: Particles

    private mutating func drawParticles() {
        var ctx = context
        ctx.blendMode = .plusLighter
        var paths: [Path] = Array(repeating: Path(), count: colors.count)
        var halos: [Path] = Array(repeating: Path(), count: colors.count)
        for p in app.engine.particles {
            let life = max(0, min(1, p.life / p.maxLife))
            let center = pt(p.position)
            let r = p.size * (0.4 + life)
            let i = ((p.colorIndex % colors.count) + colors.count) % colors.count
            paths[i].addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if p.size > 3 {
                let hr = r * 2.6
                halos[i].addEllipse(in: CGRect(x: center.x - hr, y: center.y - hr, width: hr * 2, height: hr * 2))
            }
        }
        for i in 0..<colors.count {
            ctx.fill(halos[i], with: .color(colors[i].opacity(0.12)))
            ctx.fill(paths[i], with: .color(colors[i].opacity(0.9)))
        }
    }

    // MARK: Constellation

    private mutating func drawConstellation() {
        guard let analysis else { return }
        var lines = Path()
        var count = 0
        for hand in analysis.hands {
            for tip in HandJoint.tips {
                guard let t = hand.point(tip) else { continue }
                var local = 0
                for p in app.engine.particles where local < 14 {
                    let d = t.distance(to: p.position)
                    if d < 0.11 {
                        lines.move(to: pt(t)); lines.addLine(to: pt(p.position))
                        local += 1; count += 1
                    }
                }
            }
        }
        guard count > 0 else { return }
        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.stroke(lines, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
    }

    // MARK: Ripples

    private mutating func drawRipples() {
        var ctx = context
        ctx.blendMode = .plusLighter
        for r in app.engine.ripples {
            let progress = r.age / r.maxAge
            let radius = len(0.03 + progress * 0.28)
            let c = pt(r.center)
            let circle = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            ctx.stroke(circle, with: .color(color(r.colorIndex).opacity(0.9 * (1 - progress))), lineWidth: 3 * (1 - progress) + 0.5)
        }
    }

    // MARK: Skeleton

    private mutating func drawSkeleton() {
        guard let analysis else { return }
        for (i, hand) in analysis.hands.enumerated() {
            var bones = Path()
            for (a, b) in HandJoint.bones {
                guard let pa = hand.point(a), let pb = hand.point(b) else { continue }
                bones.move(to: pt(pa)); bones.addLine(to: pt(pb))
            }
            var joints = Path()
            for (_, j) in hand.joints where j.confidence > 0.3 {
                let c = pt(j.cgPoint)
                joints.addEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            }
            let col = color(hand.side == .right ? 1 : (hand.side == .left ? 0 : 2 + i))
            var glow = context
            glow.addFilter(.blur(radius: 5))
            glow.blendMode = .plusLighter
            glow.stroke(bones, with: .color(col.opacity(0.8)), lineWidth: 6)
            context.stroke(bones, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(joints, with: .color(col))
            // Fingertip rings.
            var tips = Path()
            for tip in HandJoint.tips { if let p = hand.point(tip) { let c = pt(p); tips.addEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)) } }
            context.stroke(tips, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
        }
        if let body = analysis.body {
            var bones = Path()
            for (a, b) in BodyJoint.bones {
                guard let pa = body.point(a), let pb = body.point(b) else { continue }
                bones.move(to: pt(pa)); bones.addLine(to: pt(pb))
            }
            var joints = Path()
            for (_, j) in body.joints where j.confidence > 0.45 {
                let c = pt(j.cgPoint)
                joints.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            }
            var glow = context
            glow.addFilter(.blur(radius: 7))
            glow.blendMode = .plusLighter
            glow.stroke(bones, with: .color(color(2).opacity(0.75)), lineWidth: 9)
            context.stroke(bones, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.fill(joints, with: .color(color(2)))
        }
    }

    // MARK: Faces

    private mutating func drawFaces() {
        guard let faces = analysis?.faces else { return }
        for face in faces {
            var path = Path()
            for region in face.regions where region.points.count > 1 {
                path.move(to: pt(region.points[0]))
                for p in region.points.dropFirst() { path.addLine(to: pt(p)) }
                if region.closed { path.closeSubpath() }
            }
            var glow = context
            glow.addFilter(.blur(radius: 3))
            glow.blendMode = .plusLighter
            glow.stroke(path, with: .color(color(3).opacity(0.8)), lineWidth: 3)
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1)
            var dots = Path()
            for region in face.regions { for p in region.points { let c = pt(p); dots.addEllipse(in: CGRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)) } }
            context.fill(dots, with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Bursts (gesture labels)

    private mutating func drawBursts() {
        for b in app.engine.bursts {
            let progress = b.age / 1.4
            var p = pt(b.position)
            p.y -= len(0.06) * progress + len(0.05)
            let text = Text(b.text)
                .font(.system(size: 18 + 10 * (1 - progress), weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(Double(1 - progress)))
            context.draw(text, at: p, anchor: .center)
        }
    }
}

// MARK: - HUD

struct StageHUD: View {
    @Environment(AppModel.self) private var app
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(app.preset.name, systemImage: "sparkles")
                        .font(.headline)
                    Text(app.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if app.frozen {
                        Label("정지", systemImage: "pause.fill").font(.caption).foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                ForEach(app.handStates) { hand in
                    HStack(spacing: 8) {
                        Image(systemName: hand.staticGesture?.symbolName ?? "hand.raised")
                            .frame(width: 18)
                        Text(hand.side.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(hand.staticGesture?.displayName ?? "—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(hand.openness))
                            .frame(width: 60)
                            .tint(.cyan)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(14)

            VStack(alignment: .trailing, spacing: 6) {
                Spacer()
                if !app.director.narration.isEmpty {
                    Text(app.director.narration)
                        .font(.system(.title3, design: .serif).italic())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                HStack {
                    if let err = app.errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if app.showStats {
                        StatsView()
                    }
                }
            }
            .padding(14)
        }
        .allowsHitTesting(false)
    }
}

struct StatsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 10) {
                stat("카메라", String(format: "%.0f fps", app.cameraFPS))
                stat("Vision", String(format: "%.0f ms", app.visionMillis))
                stat("렌더", String(format: "%.0f fps", app.engine.measuredFPS))
                stat("입자", "\(app.engine.particles.count)")
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
    }
}
