import Foundation
import FoundationModels
import Observation

/// Apple Foundation Models integration.
///
/// Three jobs:
///  1. **Preset generation** – describe a look in natural language, get a typed
///     `EffectPreset` back through guided generation (`@Generable`).
///  2. **Director chat** – a tool-calling session that can switch presets, toggle
///     layers, recolor the palette, rebind gestures and change the mesh mode.
///  3. **Narration** – a one-line poetic caption of what Vision currently sees.
@MainActor
@Observable
final class EffectDirector {

    enum Status: Equatable {
        case checking
        case ready
        case unavailable(String)

        var isReady: Bool { self == .ready }
    }

    struct Message: Identifiable, Hashable {
        enum Role { case user, assistant, tool, system }
        let id = UUID()
        var role: Role
        var text: String
        var date = Date()
    }

    private(set) var status: Status = .checking
    private(set) var isBusy = false
    private(set) var messages: [Message] = []
    private(set) var generatedPreset: EffectPreset?
    private(set) var narration: String = ""
    private(set) var lastError: String?
    var narrationEnabled = false

    private weak var app: AppModel?
    private var chatSession: LanguageModelSession?
    private var narrationTask: Task<Void, Never>?

    init() {}

    func attach(to app: AppModel) {
        self.app = app
        refreshAvailability()
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            status = .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            status = .unavailable("Apple Intelligence가 꺼져 있습니다. 시스템 설정에서 켜 주세요.")
        case .unavailable(.deviceNotEligible):
            status = .unavailable("이 Mac은 Apple Intelligence를 지원하지 않습니다.")
        case .unavailable(.modelNotReady):
            status = .unavailable("온디바이스 모델을 아직 내려받는 중입니다. 잠시 후 다시 시도하세요.")
        case .unavailable(let other):
            status = .unavailable("모델을 사용할 수 없습니다: \(String(describing: other))")
        }
    }

    // MARK: Preset generation

    private static let presetInstructions = """
    You design visual effect presets for "Mirage", a macOS app that tracks the user's hands and body \
    with the camera and draws effects over the video. Available layers: trails, sparks, skeleton, \
    lightPainting, forceField, distortion, kaleidoscope, constellation, auraOutline, wireframeSkin, faceMesh. \
    Gestures: openPalm, fist, pinch, point, peace, thumbsUp, rockOn, okSign, swipeLeft, swipeRight, swipeUp, \
    swipeDown, wave, spread, squeeze, clap. Actions: burst, attract, repel, paint, clearCanvas, nextPalette, \
    cyclePreset, toggleKaleidoscope, toggleMesh, freezeFrame, snapshot. \
    Pick layers that match the mood, choose a cohesive palette of hex colors, and bind at least \
    four gestures to sensible actions (fist usually attracts, open palm usually repels, pinch paints). \
    Write the name and mood in the same language as the user's description.
    """

    func generatePreset(from description: String) async {
        guard status.isReady, !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let session = LanguageModelSession(instructions: Self.presetInstructions)
            let response = try await session.respond(
                to: "Design a preset for this description: \(description)",
                generating: EffectPreset.self,
                options: GenerationOptions(temperature: 0.8)
            )
            var preset = response.content
            if preset.bindings.isEmpty { preset.bindings = EffectPreset.defaultBindings }
            generatedPreset = preset
            messages.append(Message(role: .system, text: "프리셋 ‘\(preset.name)’ 생성 완료 — \(preset.mood)"))
        } catch {
            lastError = Self.describe(error)
            messages.append(Message(role: .system, text: "프리셋 생성 실패: \(lastError ?? "")"))
        }
    }

    // MARK: Chat with tools

    private func makeChatSession() -> LanguageModelSession? {
        guard let app else { return nil }
        let tools: [any Tool] = [
            ApplyPresetTool(app: app),
            SetLayersTool(app: app),
            SetPaletteTool(app: app),
            BindGestureTool(app: app),
            SetMeshModeTool(app: app),
            SceneStatusTool(app: app)
        ]
        let instructions = """
        You are the effects director inside "Mirage", a macOS camera app that tracks hands and body \
        with Apple Vision and draws interactive effects. Use the tools to change what the user sees: \
        switch presets, enable or disable layers, recolor, rebind gestures, or change the body mesh mode. \
        When the user asks what is happening, call sceneStatus. Answer briefly, in the user's language. \
        Built-in presets: \(EffectPreset.builtIn.map(\.name).joined(separator: ", ")).
        """
        return LanguageModelSession(tools: tools, instructions: instructions)
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, status.isReady, !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        messages.append(Message(role: .user, text: trimmed))
        if chatSession == nil { chatSession = makeChatSession() }
        guard let session = chatSession else { return }
        do {
            let response = try await session.respond(to: trimmed)
            messages.append(Message(role: .assistant, text: response.content))
        } catch LanguageModelError.contextSizeExceeded {
            chatSession = makeChatSession()
            messages.append(Message(role: .system, text: "대화가 길어져 세션을 새로 시작했습니다. 다시 보내 주세요."))
        } catch {
            lastError = Self.describe(error)
            messages.append(Message(role: .system, text: "오류: \(lastError ?? "")"))
        }
    }

    func resetChat() {
        chatSession = nil
        messages.removeAll()
    }

    func noteToolResult(_ text: String) {
        messages.append(Message(role: .tool, text: text))
    }

    // MARK: Narration

    func startNarration() {
        narrationTask?.cancel()
        narrationEnabled = true
        narrationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.narrateOnce()
                try? await Task.sleep(for: .seconds(7))
            }
        }
    }

    func stopNarration() {
        narrationEnabled = false
        narrationTask?.cancel()
        narrationTask = nil
        narration = ""
    }

    private func narrateOnce() async {
        guard status.isReady, let app else { return }
        let summary = app.sceneSummary()
        do {
            let session = LanguageModelSession(instructions: """
            You narrate a live camera scene for a visual-effects app in ONE short poetic sentence \
            (max 18 words), in Korean. No hashtags, no quotes, no emoji.
            """)
            let response = try await session.respond(to: summary, options: GenerationOptions(temperature: 1.0))
            if !Task.isCancelled {
                narration = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Narration is decorative; swallow errors quietly.
        }
    }

    // MARK: Helpers

    private static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return "컨텍스트 창 초과"
            case .guardrailViolation: return "가드레일에 걸린 요청입니다."
            case .refusal: return "모델이 이 요청에는 답하지 않았습니다."
            case .unsupportedLanguageOrLocale: return "지원하지 않는 언어입니다."
            case .rateLimited: return "요청이 너무 잦습니다. 잠시 후 다시 시도하세요."
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Tools

nonisolated struct ApplyPresetTool: Tool {
    let name = "applyPreset"
    let description = "Switches to one of the built-in effect presets by name."
    let app: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Preset name, e.g. Ember, Neon Wire, Glass Lens, Kaleido, Light Painter, Aurora Skin")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            if let preset = EffectPreset.builtIn.first(where: { $0.name.lowercased() == arguments.name.lowercased() })
                ?? EffectPreset.builtIn.first(where: { $0.name.lowercased().contains(arguments.name.lowercased()) }) {
                app.apply(preset: preset)
                app.director.noteToolResult("applyPreset → \(preset.name)")
                return "Applied preset \(preset.name). Layers: \(preset.layers.map(\.rawValue).joined(separator: ", "))."
            }
            return "No preset named \(arguments.name). Available: \(EffectPreset.builtIn.map(\.name).joined(separator: ", "))."
        }
    }
}

nonisolated struct SetLayersTool: Tool {
    let name = "setLayers"
    let description = "Enables and/or disables effect layers on the current preset."
    let app: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Layers to turn on", .maximumCount(6))
        var enable: [EffectLayer]
        @Guide(description: "Layers to turn off", .maximumCount(6))
        var disable: [EffectLayer]
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            var preset = app.preset
            for l in arguments.enable where !preset.layers.contains(l) { preset.layers.append(l) }
            preset.layers.removeAll { arguments.disable.contains($0) }
            if preset.layers.isEmpty { preset.layers = [.sparks] }
            app.apply(preset: preset, keepName: true)
            app.director.noteToolResult("setLayers → \(preset.layers.map(\.rawValue).joined(separator: ", "))")
            return "Layers now: \(preset.layers.map(\.rawValue).joined(separator: ", "))."
        }
    }
}

nonisolated struct SetPaletteTool: Tool {
    let name = "setPalette"
    let description = "Replaces the effect color palette with 2 to 4 hex colors."
    let app: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Hex colors like #FF6A00", .minimumCount(2), .maximumCount(4))
        var hexColors: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            var preset = app.preset
            preset.palette = arguments.hexColors
            app.apply(preset: preset, keepName: true)
            app.director.noteToolResult("setPalette → \(arguments.hexColors.joined(separator: " "))")
            return "Palette set to \(arguments.hexColors.joined(separator: ", "))."
        }
    }
}

nonisolated struct BindGestureTool: Tool {
    let name = "bindGesture"
    let description = "Binds a gesture to an action in the current preset."
    let app: AppModel

    @Generable
    struct Arguments {
        var gesture: GestureKind
        var action: GestureAction
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            var preset = app.preset
            preset.bindings.removeAll { $0.gesture == arguments.gesture }
            preset.bindings.append(GestureBinding(gesture: arguments.gesture, action: arguments.action))
            app.apply(preset: preset, keepName: true)
            app.director.noteToolResult("bindGesture → \(arguments.gesture.rawValue) = \(arguments.action.rawValue)")
            return "\(arguments.gesture.rawValue) now triggers \(arguments.action.rawValue)."
        }
    }
}

nonisolated struct SetMeshModeTool: Tool {
    let name = "setMeshMode"
    let description = "Changes how the body mesh is shown: off, wireframe, rigged (3D USDZ), or both."
    let app: AppModel

    @Generable
    struct Arguments {
        var mode: MeshMode
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            app.meshSettings.mode = arguments.mode
            app.director.noteToolResult("setMeshMode → \(arguments.mode.rawValue)")
            return "Mesh mode is now \(arguments.mode.rawValue)."
        }
    }
}

nonisolated struct SceneStatusTool: Tool {
    let name = "sceneStatus"
    let description = "Reports what the camera and Vision currently see: hands, gestures, body, timings."
    let app: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Include per-stage Vision timings")
        var includeTimings: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            var text = app.sceneSummary()
            if arguments.includeTimings, let a = app.analysis {
                let timings = a.stageTimings.filter { $0.value > 0 }.map { "\($0.key) \(Int($0.value))ms" }.sorted().joined(separator: ", ")
                text += " Timings: \(timings)."
            }
            app.director.noteToolResult("sceneStatus")
            return text
        }
    }
}
