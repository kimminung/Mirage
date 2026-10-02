import SwiftUI
import Observation
import AVFoundation
import OSLog
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable, Identifiable {
    case effects, gestures, mesh, director, settings
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .effects: "이펙트"
        case .gestures: "제스처"
        case .mesh: "메시"
        case .director: "디렉터"
        case .settings: "설정"
        }
    }
    var symbolName: String {
        switch self {
        case .effects: "sparkles"
        case .gestures: "hand.raised.fingers.spread"
        case .mesh: "cube.transparent"
        case .director: "apple.intelligence"
        case .settings: "gearshape"
        }
    }
}

/// Orchestrates camera → Vision → gestures → effects, and owns all user settings.
@MainActor
@Observable
final class AppModel {

    // MARK: Persisted settings

    var visionConfig = VisionConfig() { didSet { persist() } }
    var meshSettings = MeshRigSettings() { didSet { persist() } }
    var preset: EffectPreset = EffectPreset.builtIn[0] { didSet { persist() } }
    var customPresets: [EffectPreset] = [] { didSet { persist() } }
    var selectedCameraID: String? { didSet { persist() } }
    var showHUD = true { didSet { persist() } }
    var showStats = true { didSet { persist() } }

    // MARK: Session state

    var demoMode = false
    var kaleidoscopeOn = false
    var frozen = false
    var sidebarTab: SidebarTab = .effects
    var snapshotRequest: UUID?
    var errorMessage: String?

    private(set) var isRunning = false
    private(set) var frameImage: CGImage?
    private(set) var analysis: FrameAnalysis?
    private(set) var handStates: [HandGestureState] = []
    private(set) var eventLog: [GestureEvent] = []
    private(set) var cameraFPS: Double = 0
    private(set) var visionMillis: Double = 0
    private(set) var statusText = "대기 중"
    private(set) var cameras: [CameraDevice] = []
    private(set) var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)

    let engine = EffectEngine()
    let director = EffectDirector()
    let rig = MeshRigController()

    private let camera = CameraService()
    private let pipeline = VisionPipeline()
    private let demoRecognizer = GestureRecognizer()
    private let processor = FrameProcessor()
    private let log = Logger(subsystem: "Mirage", category: "App")

    private var loopTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var demo = DemoPoseSource()
    private var fpsCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var isLoadingPersisted = false
    private var launchTab: SidebarTab?

    var allPresets: [EffectPreset] { EffectPreset.builtIn + customPresets }

    // MARK: Init

    init() {
        loadPersisted()
        cameras = CameraService.availableDevices()
        director.attach(to: self)
        parseLaunchArguments()
        if let tab = launchTab { sidebarTab = tab }
        if let bookmark = meshSettings.rigBookmark {
            Task { await reloadRig(from: bookmark) }
        }
    }

    private func parseLaunchArguments() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("-demo") { demoMode = true }
        if let tab = value(after: "-tab"), let t = SidebarTab(rawValue: tab) { launchTab = t }
        if let name = value(after: "-preset"), let p = allPresets.first(where: { $0.name.lowercased() == name.lowercased() }) {
            apply(preset: p)
        }
        if let mode = value(after: "-mesh"), let m = MeshMode(rawValue: mode) { meshSettings.mode = m }
        if args.contains("-kaleido") { kaleidoscopeOn = true }
        if args.contains("-narrate") { director.startNarration() }
        // Debug helpers for automated screenshots / smoke tests of the Foundation Models paths.
        if let text = value(after: "-direct") {
            Task { try? await Task.sleep(for: .seconds(2)); await director.generatePreset(from: text) }
        }
        if let text = value(after: "-say") {
            Task { try? await Task.sleep(for: .seconds(2)); await director.send(text) }
        }
    }

    // MARK: Start / stop

    func startIfNeeded() async {
        guard !isRunning else { return }
        await start()
    }

    func start() async {
        errorMessage = nil
        if demoMode {
            startDemo()
            return
        }
        statusText = "카메라 여는 중…"
        do {
            try await camera.start(deviceID: selectedCameraID)
            cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
            isRunning = true
            statusText = "추적 중"
            loopTask?.cancel()
            // The whole camera → Vision → Core Image chain runs off the main actor so the
            // 60 fps Canvas can't starve it; only the final publish hops to the main actor.
            let camera = self.camera
            let pipeline = self.pipeline
            let processor = self.processor
            loopTask = Task.detached(priority: .userInitiated) { [weak self] in
                let recognizer = GestureRecognizer()
                for await frame in camera.frames {
                    if Task.isCancelled { break }
                    guard let self, let settings = await self.frameSettings() else { break }
                    let analysis = await pipeline.analyze(frame, config: settings.config)
                    if Task.isCancelled { break }
                    let output = recognizer.process(analysis)
                    let params = Self.filterParams(hands: output.states, settings: settings)
                    let image = settings.frozen ? nil : processor.render(frame.pixelBuffer, mirror: settings.config.mirror, params: params)
                    await self.publish(analysis: analysis, output: output, image: image)
                }
            }
        } catch {
            cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
            errorMessage = error.localizedDescription
            statusText = "카메라 사용 불가 — 데모 모드로 전환합니다"
            log.error("Camera start failed: \(error.localizedDescription, privacy: .public)")
            demoMode = true
            startDemo()
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        demoTask?.cancel(); demoTask = nil
        camera.stop()
        isRunning = false
        statusText = "정지됨"
    }

    func restartCamera() async {
        stop()
        frameImage = nil
        await start()
    }

    func toggleDemoMode() async {
        demoMode.toggle()
        await restartCamera()
    }

    private func startDemo() {
        isRunning = true
        statusText = "데모 모드 (합성 포즈)"
        frameImage = nil
        demoRecognizer.reset()
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                var a = self.demo.analysis(at: now)
                a.imageSize = CGSize(width: 1280, height: 720)
                self.ingest(analysis: a)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: Per-frame processing

    /// Everything the background loop needs from the main actor for one frame.
    nonisolated struct FrameSettings: Sendable {
        var config: VisionConfig
        var preset: EffectPreset
        var kaleidoscopeOn: Bool
        var frozen: Bool
        var kaleidoscopeAngle: CGFloat
    }

    /// Returns nil once the session has been stopped, which ends the loop.
    private func frameSettings() -> FrameSettings? {
        guard isRunning else { return nil }
        return FrameSettings(config: visionConfig, preset: preset, kaleidoscopeOn: kaleidoscopeOn,
                             frozen: frozen, kaleidoscopeAngle: engine.kaleidoscopeAngle)
    }

    private func publish(analysis: FrameAnalysis, output: GestureRecognizer.Output, image: CGImage?) {
        guard isRunning else { return }
        fpsCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsWindowStart >= 1 {
            cameraFPS = Double(fpsCount) / (now - fpsWindowStart)
            fpsCount = 0
            fpsWindowStart = now
        }
        if let image { frameImage = image }
        self.analysis = analysis
        handStates = output.states
        visionMillis = analysis.processingMillis
        handle(events: output.events)
    }

    private func ingest(analysis: FrameAnalysis) {
        let output = demoRecognizer.process(analysis)
        self.analysis = analysis
        handStates = output.states
        visionMillis = analysis.processingMillis
        handle(events: output.events)
    }

    nonisolated private static func filterParams(hands: [HandGestureState], settings: FrameSettings) -> FrameProcessor.FilterParams {
        var params = FrameProcessor.FilterParams()
        let preset = settings.preset
        params.freeze = settings.frozen
        if preset.contains(.distortion) {
            for h in hands {
                let scale: CGFloat
                switch h.staticGesture {
                case .fist: scale = -0.65
                case .openPalm: scale = 0.55
                case .pinch: scale = -0.3
                default: scale = 0.15 + h.openness * 0.3
                }
                params.bumps.append((center: h.palmCenter, radius: h.palmSize * 2.4, scale: scale))
            }
        }
        if settings.kaleidoscopeOn && preset.contains(.kaleidoscope) {
            let center: CGPoint
            if hands.count >= 2 {
                center = CGPoint(x: (hands[0].palmCenter.x + hands[1].palmCenter.x) / 2, y: (hands[0].palmCenter.y + hands[1].palmCenter.y) / 2)
            } else if let h = hands.first {
                center = h.palmCenter
            } else {
                center = CGPoint(x: 0.5, y: 0.5)
            }
            params.kaleidoscope = (center: center, angle: settings.kaleidoscopeAngle, count: 6)
        }
        return params
    }

    // MARK: Gesture events

    private func handle(events: [GestureEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            eventLog.insert(event, at: 0)
            engine.handle(event: event, preset: preset)
            switch preset.action(for: event.kind) {
            case .cyclePreset: cyclePreset()
            case .toggleKaleidoscope: kaleidoscopeOn.toggle()
            case .toggleMesh:
                let all = MeshMode.allCases
                let i = all.firstIndex(of: meshSettings.mode) ?? 0
                meshSettings.mode = all[(i + 1) % all.count]
            case .freezeFrame: frozen.toggle()
            case .snapshot: snapshotRequest = UUID()
            default: break
            }
        }
        if eventLog.count > 40 { eventLog.removeLast(eventLog.count - 40) }
    }

    // MARK: Presets

    func apply(preset newPreset: EffectPreset, keepName: Bool = false) {
        var p = newPreset
        if keepName { p.name = preset.name }
        preset = p
        if p.contains(.kaleidoscope) && !kaleidoscopeOn { kaleidoscopeOn = true }
        if !p.contains(.kaleidoscope) { kaleidoscopeOn = false }
        engine.clearStrokes()
    }

    func cyclePreset() {
        let all = allPresets
        guard !all.isEmpty else { return }
        let i = all.firstIndex(where: { $0.name == preset.name }) ?? -1
        apply(preset: all[(i + 1) % all.count])
    }

    func toggle(layer: EffectLayer) {
        var p = preset
        if let i = p.layers.firstIndex(of: layer) { p.layers.remove(at: i) } else { p.layers.append(layer) }
        preset = p
        if layer == .kaleidoscope { kaleidoscopeOn = p.contains(.kaleidoscope) }
    }

    func setBinding(_ gesture: GestureKind, action: GestureAction) {
        var p = preset
        p.bindings.removeAll { $0.gesture == gesture }
        if action != .none { p.bindings.append(GestureBinding(gesture: gesture, action: action)) }
        preset = p
    }

    func saveCurrentAsCustomPreset(named name: String) {
        var p = preset
        p.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom \(customPresets.count + 1)" : name
        customPresets.removeAll { $0.name == p.name }
        customPresets.append(p)
        preset = p
    }

    func deleteCustomPreset(_ p: EffectPreset) {
        customPresets.removeAll { $0.name == p.name }
    }

    // MARK: Mesh rig import

    func importRig(from url: URL) async {
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            meshSettings.rigBookmark = bookmark
            meshSettings.rigFileName = url.lastPathComponent
            await rig.load(url: url, fileName: url.lastPathComponent)
            if rig.loadError == nil, !meshSettings.mode.showsRig { meshSettings.mode = .both }
        } catch {
            errorMessage = "파일 북마크를 만들 수 없습니다: \(error.localizedDescription)"
        }
    }

    func removeRig() {
        rig.clearImported()
        meshSettings.rigBookmark = nil
        meshSettings.rigFileName = nil
    }

    private func reloadRig(from bookmark: Data) async {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        await rig.load(url: url, fileName: url.lastPathComponent)
    }

    // MARK: Scene summary (for the director + narration)

    func sceneSummary() -> String {
        var parts: [String] = []
        if handStates.isEmpty {
            parts.append("No hands visible.")
        } else {
            let hands = handStates.map { h -> String in
                var s = "\(h.side.rawValue) hand"
                if let g = h.staticGesture { s += " doing \(g.rawValue)" }
                s += String(format: " (openness %.0f%%, pinch %.0f%%)", h.openness * 100, h.pinchStrength * 100)
                return s
            }
            parts.append("Hands: " + hands.joined(separator: "; ") + ".")
        }
        if let body = analysis?.body {
            parts.append(String(format: "Body visible, shoulder width %.2f of frame.", body.shoulderWidth))
        } else {
            parts.append("No body detected.")
        }
        if let faces = analysis?.faces, !faces.isEmpty { parts.append("\(faces.count) face(s).") }
        let recent = eventLog.prefix(5).map(\.kind.rawValue)
        if !recent.isEmpty { parts.append("Recent gestures: \(recent.joined(separator: ", ")).") }
        parts.append("Preset \(preset.name) with layers \(preset.layers.map(\.rawValue).joined(separator: ", ")). Mesh mode \(meshSettings.mode.rawValue).")
        parts.append(String(format: "Camera %.0f fps, Vision %.0f ms, render %.0f fps.", cameraFPS, visionMillis, engine.measuredFPS))
        if demoMode { parts.append("Demo mode with synthetic poses.") }
        return parts.joined(separator: " ")
    }

    // MARK: Snapshot

    func saveSnapshot(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Mirage-\(Int(Date().timeIntervalSince1970)).png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.processor.snapshot(image, to: url)
            } catch {
                self?.errorMessage = "스냅샷 저장 실패: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var visionConfig: VisionConfig
        var meshSettings: MeshRigSettings
        var preset: EffectPreset
        var customPresets: [EffectPreset]
        var selectedCameraID: String?
        var showHUD: Bool
        var showStats: Bool
    }

    private static let defaultsKey = "mirage.settings.v1"

    private func persist() {
        guard !isLoadingPersisted else { return }
        let p = Persisted(visionConfig: visionConfig, meshSettings: meshSettings, preset: preset,
                          customPresets: customPresets, selectedCameraID: selectedCameraID,
                          showHUD: showHUD, showStats: showStats)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        isLoadingPersisted = true
        visionConfig = p.visionConfig
        meshSettings = p.meshSettings
        preset = p.preset
        customPresets = p.customPresets
        selectedCameraID = p.selectedCameraID
        showHUD = p.showHUD
        showStats = p.showStats
        isLoadingPersisted = false
    }

    func resetSettings() {
        isLoadingPersisted = true
        visionConfig = VisionConfig()
        meshSettings = MeshRigSettings()
        preset = EffectPreset.builtIn[0]
        customPresets = []
        selectedCameraID = nil
        showHUD = true
        showStats = true
        isLoadingPersisted = false
        persist()
    }
}
