import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Container

struct SidePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: $app.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.symbolName).tag(tab)
                        .help(tab.displayName)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                switch app.sidebarTab {
                case .effects: EffectsPanel()
                case .gestures: GesturesPanel()
                case .mesh: MeshPanel()
                case .director: DirectorPanel()
                case .settings: SettingsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }
}

private struct PanelHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @Environment(AppModel.self) private var app
    @State private var newPresetName = ""

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "이펙트", subtitle: "프리셋을 고르고 레이어를 겹쳐 쌓으세요.")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(app.allPresets) { preset in
                        Button { app.apply(preset: preset) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 3) {
                                    ForEach(Array(preset.palette.rgbaColors.enumerated()), id: \.offset) { _, c in
                                        Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 10, height: 10)
                                    }
                                }
                                Text(preset.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(preset.layers.count)개 레이어").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(app.preset.name == preset.name ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(app.preset.name == preset.name ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if app.customPresets.contains(where: { $0.name == preset.name }) {
                                Button("삭제", role: .destructive) { app.deleteCustomPreset(preset) }
                            }
                        }
                    }
                }

                Text(app.preset.mood).font(.callout).foregroundStyle(.secondary)

                GroupBox("레이어") {
                    VStack(spacing: 6) {
                        ForEach(EffectLayer.allCases) { layer in
                            Toggle(isOn: Binding(
                                get: { app.preset.contains(layer) },
                                set: { _ in app.toggle(layer: layer) }
                            )) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: layer.symbolName).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(layer.displayName).font(.subheadline)
                                        Text(layer.detail).font(.caption2).foregroundStyle(.secondary)
                                        if layer.needsMask && !app.visionConfig.segmentation {
                                            Text("설정에서 사람 세그멘테이션을 켜야 합니다.").font(.caption2).foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }

                GroupBox("팔레트") {
                    HStack(spacing: 10) {
                        ForEach(Array(app.preset.palette.indices), id: \.self) { i in
                            ColorPicker("", selection: Binding(
                                get: {
                                    let c = [app.preset.palette[i]].rgbaColors[0]
                                    return Color(red: c.r, green: c.g, blue: c.b)
                                },
                                set: { newColor in
                                    var p = app.preset
                                    p.palette[i] = newColor.hexString
                                    app.preset = p
                                }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        }
                        Spacer()
                        Button { var p = app.preset; if p.palette.count < 4 { p.palette.append("#FFFFFF"); app.preset = p } } label: { Image(systemName: "plus") }
                            .disabled(app.preset.palette.count >= 4)
                        Button { var p = app.preset; if p.palette.count > 2 { p.palette.removeLast(); app.preset = p } } label: { Image(systemName: "minus") }
                            .disabled(app.preset.palette.count <= 2)
                    }
                }

                GroupBox("강도") {
                    VStack(alignment: .leading) {
                        LabeledContent("입자 세기 \(app.preset.intensity)") {
                            Slider(value: Binding(get: { Double(app.preset.intensity) }, set: { var p = app.preset; p.intensity = Int($0.rounded()); app.preset = p }), in: 1...10, step: 1)
                        }
                        LabeledContent("잔상 길이 \(app.preset.persistence)") {
                            Slider(value: Binding(get: { Double(app.preset.persistence) }, set: { var p = app.preset; p.persistence = Int($0.rounded()); app.preset = p }), in: 1...10, step: 1)
                        }
                        Toggle("만화경 켜기 (레이어 필요)", isOn: $app.kaleidoscopeOn)
                            .disabled(!app.preset.contains(.kaleidoscope))
                    }
                }

                HStack {
                    TextField("내 프리셋 이름", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                    Button("저장") { app.saveCurrentAsCustomPreset(named: newPresetName); newPresetName = "" }
                }
                HStack {
                    Button("라이트 페인팅 지우기") { app.engine.clearStrokes() }
                    Button("모든 입자 지우기") { app.engine.clearAll() }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
    }
}

// MARK: - Gestures

struct GesturesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "제스처", subtitle: "Vision 손 포즈 21개 관절로 인식합니다. 제스처마다 동작을 바꿀 수 있어요.")

                GroupBox("지금 보이는 손") {
                    if app.handStates.isEmpty {
                        Text("손이 보이면 여기에 상태가 표시됩니다.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(app.handStates) { h in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(h.side.displayName).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(h.staticGesture?.displayName ?? "인식 중…").foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    ForEach(Finger.allCases, id: \.self) { f in
                                        Capsule()
                                            .fill(h.extended.contains(f) ? Color.cyan : Color.primary.opacity(0.15))
                                            .frame(height: 6)
                                    }
                                }
                                HStack {
                                    Text(String(format: "펼침 %.0f%%", h.openness * 100))
                                    Text(String(format: "핀치 %.0f%%", h.pinchStrength * 100))
                                    Text(String(format: "속도 %.2f", hypot(h.velocity.dx, h.velocity.dy)))
                                }
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                GroupBox("바인딩 (현재 프리셋)") {
                    VStack(spacing: 4) {
                        ForEach(GestureKind.allCases, id: \.self) { g in
                            HStack {
                                Image(systemName: g.symbolName).frame(width: 18)
                                    .foregroundStyle(isActive(g) ? Color.cyan : .primary)
                                Text(g.displayName).font(.subheadline)
                                if g.isDynamic { Text("동적").font(.caption2).padding(.horizontal, 4).background(Color.primary.opacity(0.1), in: Capsule()) }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { app.preset.action(for: g) },
                                    set: { app.setBinding(g, action: $0) }
                                )) {
                                    ForEach(GestureAction.allCases, id: \.self) { a in Text(a.displayName).tag(a) }
                                }
                                .labelsHidden()
                                .frame(width: 130)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                GroupBox("최근 이벤트") {
                    if app.eventLog.isEmpty {
                        Text("아직 이벤트가 없습니다.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(app.eventLog.prefix(12)) { e in
                            HStack {
                                Image(systemName: e.kind.symbolName).frame(width: 16)
                                Text(e.kind.displayName)
                                Text(e.side.displayName).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", e.strength * 100)).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }

                GroupBox("인식 팁") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• 손바닥이 카메라를 향하게 하고 팔꿈치 높이 정도에서 움직이면 가장 안정적입니다.")
                        Text("• 핀치는 엄지·검지 끝 거리로, 주먹/보자기는 손가락 펼침 비율로 판정합니다.")
                        Text("• 스와이프는 0.35초 안에 화면 22% 이상 이동, 흔들기는 1.2초 안에 좌우 반전 3회입니다.")
                        Text("• 정적 제스처는 3프레임 유지 후 발동, 4프레임 사라지면 해제됩니다(히스테리시스).")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func isActive(_ g: GestureKind) -> Bool {
        app.handStates.contains { $0.staticGesture == g } || app.eventLog.first.map { $0.kind == g && Date().timeIntervalSinceReferenceDate - $0.timestamp < 1 } == true
    }
}

// MARK: - Mesh

struct MeshPanel: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "메시", subtitle: "실루엣 위에 와이어프레임을 입히거나, Blender에서 만든 USDZ를 뼈대에 붙입니다.")

                Picker("모드", selection: $app.meshSettings.mode) {
                    ForEach(MeshMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .pickerStyle(.menu)

                GroupBox("와이어프레임 스킨") {
                    VStack(alignment: .leading) {
                        LabeledContent("밀도 \(app.meshSettings.wireframeDensity)") {
                            Slider(value: Binding(get: { Double(app.meshSettings.wireframeDensity) }, set: { app.meshSettings.wireframeDensity = Int($0.rounded()) }), in: 4...40, step: 1)
                        }
                        LabeledContent("불투명도") {
                            Slider(value: $app.meshSettings.wireframeOpacity, in: 0.1...1)
                        }
                        LabeledContent("색") {
                            ColorPicker("", selection: Binding(
                                get: { let c = [app.meshSettings.wireframeColor].rgbaColors[0]; return Color(red: c.r, green: c.g, blue: c.b) },
                                set: { app.meshSettings.wireframeColor = $0.hexString }
                            ), supportsOpacity: false).labelsHidden()
                        }
                        Toggle("호흡 애니메이션", isOn: $app.meshSettings.breathing)
                        Toggle("손이 가까우면 밀어내기 (주먹은 당김)", isOn: $app.meshSettings.handPush)
                        if !app.visionConfig.segmentation {
                            Text("사람 세그멘테이션이 꺼져 있어 몸 윤곽 대신 관절 박스로 클리핑합니다.").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                GroupBox("3D 리그 (RealityKit)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { showImporter = true } label: { Label("USDZ 가져오기", systemImage: "square.and.arrow.down") }
                            if app.meshSettings.rigFileName != nil {
                                Button(role: .destructive) { app.removeRig() } label: { Label("제거", systemImage: "trash") }
                            }
                        }
                        if let name = app.meshSettings.rigFileName {
                            Label(name, systemImage: "cube.fill").font(.caption)
                            if !app.rig.loadedSlotNames.isEmpty {
                                Text("연결된 슬롯: " + app.rig.loadedSlotNames.map(\.displayName).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("파일이 없으면 반투명 플레이스홀더 블록이 뼈대를 따라갑니다.").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let err = app.rig.loadError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        }
                        LabeledContent(String(format: "크기 %.2f×", app.meshSettings.rigScale)) {
                            Slider(value: $app.meshSettings.rigScale, in: 0.3...2.5)
                        }
                        Toggle("플레이스홀더 표시", isOn: $app.meshSettings.showPlaceholders)
                    }
                }

                GroupBox("슬롯") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                        ForEach(MeshSlot.allCases) { slot in
                            Toggle(slot.displayName, isOn: Binding(
                                get: { app.meshSettings.enabledSlots.contains(slot) },
                                set: { on in
                                    var s = app.meshSettings.enabledSlots
                                    if on { s.insert(slot) } else { s.remove(slot) }
                                    app.meshSettings.enabledSlots = s
                                }
                            ))
                            .font(.caption)
                        }
                    }
                }

                GroupBox("Blender 제작 가이드") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 파트별 오브젝트 이름을 슬롯 이름과 똑같이 짓습니다: head, torso, leftUpperArm, leftForearm, rightUpperArm, rightForearm, leftThigh, leftShin, rightThigh, rightShin, leftHand, rightHand.")
                        Text("2. 각 파트는 원점 중심, +Y 축이 뼈 방향(시작→끝)이 되도록 모델링합니다. 길이는 임의여도 됩니다 — Y 길이가 뼈 길이에 맞춰 자동 스케일됩니다.")
                        Text("3. File ▸ Export ▸ USD (.usdz) 로 내보낸 뒤 여기서 가져옵니다. 슬롯 이름이 하나도 없으면 전체를 몸통에 붙입니다.")
                        Text("4. 카메라는 세로 FOV 60°, 평면 거리 2 m의 가상 카메라입니다. 깊이(Z)는 모두 같은 평면이며 2D 포즈를 따릅니다.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.modelTypes) { result in
            if case .success(let url) = result {
                Task { await app.importRig(from: url) }
            }
        }
    }

    static var modelTypes: [UTType] {
        var types: [UTType] = [.usdz, .realityFile]
        if let usd = UTType("com.pixar.universal-scene-description") { types.append(usd) }
        if let usdc = UTType(filenameExtension: "usdc") { types.append(usdc) }
        if let usda = UTType(filenameExtension: "usda") { types.append(usda) }
        return types
    }
}

// MARK: - Director (Foundation Models)

struct DirectorPanel: View {
    @Environment(AppModel.self) private var app
    @State private var describeText = "손끝에서 푸른 불꽃이 튀고, 주먹을 쥐면 모두 빨려 들어가는 밤바다 느낌"
    @State private var chatText = ""

    var body: some View {
        @Bindable var director = app.director
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "디렉터", subtitle: "Apple Foundation Models(온디바이스)로 프리셋을 설계하고 도구 호출로 장면을 바꿉니다.")

                statusBadge

                GroupBox("말로 프리셋 만들기") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $describeText)
                            .font(.body)
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button {
                                Task { await app.director.generatePreset(from: describeText) }
                            } label: {
                                Label("프리셋 생성", systemImage: "wand.and.stars")
                            }
                            .disabled(!app.director.status.isReady || app.director.isBusy)
                            if app.director.isBusy { ProgressView().controlSize(.small) }
                        }
                        if let p = app.director.generatedPreset {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(p.name).font(.headline)
                                    Spacer()
                                    HStack(spacing: 3) {
                                        ForEach(Array(p.palette.rgbaColors.enumerated()), id: \.offset) { _, c in
                                            Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 12, height: 12)
                                        }
                                    }
                                }
                                Text(p.mood).font(.caption).foregroundStyle(.secondary)
                                Text("레이어: " + p.layers.map(\.displayName).joined(separator: ", ")).font(.caption2)
                                Text("바인딩: " + p.bindings.map { "\($0.gesture.displayName)→\($0.action.displayName)" }.joined(separator: ", ")).font(.caption2)
                                HStack {
                                    Button("적용") { app.apply(preset: p) }
                                    Button("저장 + 적용") { app.apply(preset: p); app.saveCurrentAsCustomPreset(named: p.name) }
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                GroupBox("디렉터와 대화 (도구 호출)") {
                    VStack(alignment: .leading, spacing: 8) {
                        if app.director.messages.isEmpty {
                            Text("예: “만화경 켜고 팔레트를 보라/금색으로”, “지금 뭐가 보여?”, “브이를 하면 스냅샷 찍게 해줘”, “메시를 리그 모드로”")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(app.director.messages.suffix(14)) { m in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: icon(for: m.role)).frame(width: 14).foregroundStyle(.secondary)
                                Text(m.text).font(.callout).textSelection(.enabled)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(m.role == .user ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        HStack {
                            TextField("디렉터에게 지시…", text: $chatText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { send() }
                            Button { send() } label: { Image(systemName: "paperplane.fill") }
                                .disabled(!app.director.status.isReady || app.director.isBusy || chatText.isEmpty)
                            Button { app.director.resetChat() } label: { Image(systemName: "arrow.counterclockwise") }
                                .help("대화 초기화")
                        }
                    }
                }

                GroupBox("장면 내레이션") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("7초마다 장면을 한 줄 시로 읊기", isOn: Binding(
                            get: { app.director.narrationEnabled },
                            set: { on in on ? app.director.startNarration() : app.director.stopNarration() }
                        ))
                        .disabled(!app.director.status.isReady)
                        if !app.director.narration.isEmpty {
                            Text(app.director.narration).font(.callout.italic()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            switch app.director.status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("모델 확인 중…")
            case .ready:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("온디바이스 모델 준비됨 (SystemLanguageModel)")
            case .unavailable(let reason):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(reason)
            }
            Spacer()
            Button { app.director.refreshAvailability() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for role: EffectDirector.Message.Role) -> String {
        switch role {
        case .user: "person.fill"
        case .assistant: "apple.intelligence"
        case .tool: "wrench.and.screwdriver.fill"
        case .system: "info.circle"
        }
    }

    private func send() {
        let text = chatText
        chatText = ""
        Task { await app.director.send(text) }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "설정", subtitle: "카메라와 Vision 요청을 켜고 끕니다. 모두 온디바이스에서 처리됩니다.")

                GroupBox("카메라") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("장치", selection: Binding(
                            get: { app.selectedCameraID ?? "" },
                            set: { app.selectedCameraID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("시스템 기본").tag("")
                            ForEach(app.cameras) { cam in
                                Text(cam.name + (cam.isContinuityCamera ? " (Continuity)" : "")).tag(cam.id)
                            }
                        }
                        Toggle("거울 모드 (셀피처럼 좌우 반전)", isOn: $app.visionConfig.mirror)
                        Toggle("데모 모드 (합성 포즈, 카메라 불필요)", isOn: Binding(
                            get: { app.demoMode },
                            set: { _ in Task { await app.toggleDemoMode() } }
                        ))
                        HStack {
                            Button(app.isRunning ? "정지" : "시작") {
                                if app.isRunning { app.stop() } else { Task { await app.start() } }
                            }
                            Button("카메라 다시 열기") { Task { await app.restartCamera() } }
                        }
                        .controlSize(.small)
                        Text("권한 상태: \(authorizationText)").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Vision 요청") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("손 포즈 (DetectHumanHandPoseRequest)", isOn: $app.visionConfig.hands)
                        Stepper("최대 손 개수: \(app.visionConfig.maxHands)", value: $app.visionConfig.maxHands, in: 1...4)
                        Toggle("몸 포즈 2D (DetectHumanBodyPoseRequest)", isOn: $app.visionConfig.body)
                        Toggle("몸 포즈 3D (DetectHumanBodyPose3DRequest)", isOn: $app.visionConfig.body3D)
                        Toggle("사람 세그멘테이션 (GeneratePersonSegmentationRequest)", isOn: $app.visionConfig.segmentation)
                        Picker("세그멘테이션 품질", selection: $app.visionConfig.segmentationQuality) {
                            ForEach(SegmentationQuality.allCases) { q in Text(q.displayName).tag(q) }
                        }
                        .disabled(!app.visionConfig.segmentation)
                        Toggle("윤곽선 (DetectContoursRequest, 마스크 기반)", isOn: $app.visionConfig.contours)
                            .disabled(!app.visionConfig.segmentation)
                        Toggle("얼굴 랜드마크 (DetectFaceLandmarksRequest)", isOn: $app.visionConfig.faceLandmarks)
                        LabeledContent(String(format: "관절 최소 신뢰도 %.2f", app.visionConfig.minimumJointConfidence)) {
                            Slider(value: Binding(get: { Double(app.visionConfig.minimumJointConfidence) }, set: { app.visionConfig.minimumJointConfidence = Float($0) }), in: 0.05...0.8)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                GroupBox("단계별 처리 시간") {
                    if let timings = app.analysis?.stageTimings {
                        VStack(spacing: 2) {
                            ForEach(timings.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack {
                                    Text(k).font(.caption)
                                    Spacer()
                                    Text(v > 0 ? String(format: "%.1f ms", v) : "꺼짐").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Text("합계 (병렬)").font(.caption.weight(.semibold))
                                Spacer()
                                Text(String(format: "%.1f ms", app.visionMillis)).font(.caption.monospacedDigit())
                            }
                        }
                    } else {
                        Text("프레임이 들어오면 표시됩니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let b3 = app.analysis?.body3D {
                        Text(String(format: "3D 추정 신장 %.2f m · 관절 %d개", b3.bodyHeight, b3.positions.count)).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                GroupBox("화면") {
                    Toggle("HUD 표시", isOn: $app.showHUD)
                    Toggle("성능 수치 표시", isOn: $app.showStats)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Button("설정 초기화", role: .destructive) { app.resetSettings() }
                    .controlSize(.small)

                Text("Mirage · Apache-2.0 · 모든 영상은 이 Mac을 떠나지 않습니다.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    private var authorizationText: String {
        switch app.cameraAuthorization {
        case .authorized: "허용됨"
        case .denied: "거부됨 — 시스템 설정 > 개인정보 보호 > 카메라"
        case .restricted: "제한됨"
        case .notDetermined: "아직 묻지 않음"
        @unknown default: "알 수 없음"
        }
    }
}

// MARK: - Color helpers

extension Color {
    /// Hex string like #RRGGBB (sRGB).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        let r = Int((ns.redComponent * 255).rounded()), g = Int((ns.greenComponent * 255).rounded()), b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
