import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            StageView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SidePanel()
                .frame(width: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if app.isRunning { app.stop() } else { Task { await app.start() } }
                } label: {
                    Label(app.isRunning ? "정지" : "시작", systemImage: app.isRunning ? "stop.fill" : "play.fill")
                }
                .help(app.isRunning ? "카메라/추적 정지" : "카메라/추적 시작")

                Toggle(isOn: Binding(get: { app.demoMode }, set: { _ in Task { await app.toggleDemoMode() } })) {
                    Label("데모", systemImage: "figure.wave")
                }
                .help("합성 포즈로 데모 재생")
            }
            ToolbarItemGroup(placement: .principal) {
                Picker("프리셋", selection: Binding(
                    get: { app.preset.name },
                    set: { name in if let p = app.allPresets.first(where: { $0.name == name }) { app.apply(preset: p) } }
                )) {
                    ForEach(app.allPresets) { p in Text(p.name).tag(p.name) }
                }
                .frame(minWidth: 160)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $app.visionConfig.mirror) { Label("거울", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("거울 모드")
                Toggle(isOn: $app.kaleidoscopeOn) { Label("만화경", systemImage: "hexagon") }
                    .disabled(!app.preset.contains(.kaleidoscope))
                    .help("만화경 (레이어가 켜져 있을 때)")
                Toggle(isOn: $app.frozen) { Label("정지 화면", systemImage: "pause.circle") }
                    .help("비디오 프레임 정지 (추적은 계속)")
                Button { app.snapshotRequest = UUID() } label: { Label("스냅샷", systemImage: "camera.shutter.button") }
                    .help("현재 화면을 PNG로 저장")
            }
        }
        .navigationTitle("Mirage")
        .task { await app.startIfNeeded() }
        .frame(minWidth: 1100, minHeight: 680)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
