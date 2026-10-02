import SwiftUI

/// Mirage — your hands, made visible.
/// Camera → Vision (hands, body, segmentation, face) → gestures → effects → mesh.
@main
struct MirageApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1380, height: 820)
        .commands {
            CommandMenu("Mirage") {
                Button("다음 프리셋") { app.cyclePreset() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("라이트 페인팅 지우기") { app.engine.clearStrokes() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("모든 입자 지우기") { app.engine.clearAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button(app.frozen ? "프레임 재개" : "프레임 정지") { app.frozen.toggle() }
                    .keyboardShortcut(.space, modifiers: .command)
                Button("스냅샷 저장…") { app.snapshotRequest = UUID() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Toggle("HUD 표시", isOn: Binding(get: { app.showHUD }, set: { app.showHUD = $0 }))
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
