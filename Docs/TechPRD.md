# Mirage — Technical PRD

| | |
|---|---|
| 문서 버전 | 1.0 (2026-10-02) |
| 대상 플랫폼 | macOS 27+, Apple Silicon (개발·실측: MacBook Air M4, macOS 27.0.1) |
| 상태 | v1 구현 완료, 실기 검증 완료 (스크린샷: `Docs/screenshots`) |
| 라이선스 | Apache-2.0 |

---

## 1. 문제 정의와 목표

### 1.1 한 줄 요약
MacBook 내장 카메라만으로 **손가락·몸·실루엣·얼굴을 실시간 인식**하고, **제스처에 즉시 반응하는 시각 이펙트**를 체험하며, **내 몸 위에 메시(와이어프레임 또는 Blender 제작 USDZ)를 입히는** 개인용 데스크톱 앱.

### 1.2 목표 (Goals)
| ID | 목표 | 측정 |
|---|---|---|
| G1 | Apple Vision이 제공하는 신체 인식 요청을 **가능한 최대한** 동시에 활용한다 | 손·몸 2D·몸 3D·세그멘테이션·윤곽·얼굴 6종 사용 |
| G2 | 손 제스처 ≥ 12종을 떨림 없이 인식해 이펙트에 바인딩한다 | 16종, 히스테리시스 3/4 프레임 |
| G3 | 다양한 시각 이펙트를 **레이어**로 겹쳐 프리셋으로 저장·전환한다 | 11 레이어, 6 내장 프리셋 + 사용자 프리셋 |
| G4 | 트래킹이 충분하면 **몸 위에 메시**를 입히고, 외부 제작 USDZ를 뼈대에 붙일 수 있다 | 와이어프레임 스킨 + 12 슬롯 USDZ 리그 |
| G5 | Apple FoundationModels를 **구조화 생성·도구 호출**에 실질적으로 활용한다 | `@Generable` 프리셋, Tool 6종, 내레이션 |
| G6 | 모든 처리가 **온디바이스**이며 네트워크를 쓰지 않는다 | 네트워크 엔타이틀먼트 없음 |
| G7 | 분석 ≥ 15 fps, 렌더 ≥ 60 fps | 실측 11–21 fps / 56–117 fps (아래 §8) |

### 1.3 비목표 (Non-goals, v1)
- 다중 사용자(2인 이상) 구분·추적 — 세그멘테이션은 단일 마스크, 몸 포즈는 첫 관측만 사용.
- 정밀한 3D 메시 리깅(스킨 웨이트, 관절 회전 보간). v1 리그는 2D 포즈 평면 추종.
- iOS/visionOS 빌드. `SUPPORTED_PLATFORMS = macosx`.
- 영상 녹화·공유. 정지 스냅샷(PNG)만 제공.
- 클라우드 모델(PCC). 온디바이스 `SystemLanguageModel`만.

### 1.4 사용자 시나리오
1. **첫 실행**: 카메라 권한 허용 → Ember 프리셋 → 손을 펴면 손끝에서 불씨, 주먹을 쥐면 입자가 빨려 든다.
2. **놀이**: 브이로 폭발, 스와이프로 캔버스 지우기, 엄지척으로 팔레트 전환, 양손 벌리기로 만화경.
3. **메시 체험**: 메시 탭에서 와이어프레임 밀도를 올리고, Blender에서 만든 `suit.usdz`를 가져와 뼈대에 붙인다.
4. **디렉터**: “밤바다 느낌, 주먹이면 빨려드는” 한 문장으로 프리셋을 만들고 적용한다. “지금 뭐가 보여?”로 장면 상태를 묻는다.
5. **데모**: 카메라 없는 자리에서 데모 토글로 합성 포즈를 재생해 이펙트·메시를 점검한다.

---

## 2. 시스템 아키텍처

![architecture](diagrams/architecture-layers.svg)

```
AVCaptureSession ─▶ AsyncStream<CameraFrame> ─▶ [detached loop]
   VisionPipeline.analyze (actor, async let ×5) ─▶ FrameAnalysis
   GestureRecognizer.process ─▶ HandGestureState[] + GestureEvent[]
   FrameProcessor.render (Core Image) ─▶ CGImage
   ─▶ MainActor publish ─▶ AppModel (@Observable)
         ├─ StageCanvas (TimelineView 60fps): EffectEngine.step + StageRenderer.drawAll
         ├─ MeshRigView (RealityView): MeshRigController.update
         └─ EffectDirector (FoundationModels)
```

### 2.1 동시성 모델
| 구성요소 | 격리 | 이유 |
|---|---|---|
| `CameraService` | `nonisolated final class`, 전용 `DispatchQueue` | AVFoundation 델리게이트는 지정 큐에서 호출 |
| `VisionPipeline` | `actor` | 요청 객체·캐시 보호, 내부에서 `async let` 병렬 |
| 카메라 루프 | `Task.detached(.userInitiated)` | 60 fps Canvas가 메인 액터를 점유해도 분석이 굶지 않도록 |
| `GestureRecognizer` | 루프 태스크 소유 (nonisolated class) | 상태 머신, 단일 소비자 |
| `FrameProcessor` | `@unchecked Sendable` (CIContext 내부 동기화) | Metal CIContext 재사용 |
| `AppModel`, `EffectEngine`, `MeshRigController`, `EffectDirector` | `@MainActor` | UI 상태 |
| 데이터 타입 (`Models.swift`) | `nonisolated struct/enum` + `Sendable` | 기본 MainActor 격리 프로젝트에서 액터 간 전달 |

프레임 드롭 정책: `AsyncStream(bufferingPolicy: .bufferingNewest(1))` — 소비자가 느리면 항상 최신 프레임만 처리한다.

### 2.2 좌표 규약
- Vision: 정규화, 좌하단 원점. 얼굴 랜드마크는 바운딩 박스 기준.
- **뷰 정규화(View-normalized)**: 0…1, 좌상단 원점, `mirror` 설정 반영. `VisionPipeline.viewPoint/viewRect`에서 단 한 번 변환.
- 렌더: `StageRenderer.pt()`가 비디오 사각형(aspect-fit)으로 스케일.
- RealityKit: `MeshRigController.world()`가 가상 카메라 평면으로 선형 변환.
- Chirality는 거울 처리 **전** 이미지 기준이므로 실제 왼/오른손과 일치한다.

---

## 3. 기능 명세

### 3.1 인식 (Vision)
| 요청 | 설정 | 출력 모델 | 비고 |
|---|---|---|---|
| `DetectHumanHandPoseRequest` | `maximumHandCount` 1–4 (기본 2) | `HandSnapshot{id, side, joints[21], confidence}` | 동일 chirality 중복 시 신뢰도 높은 쪽 유지 |
| `DetectHumanBodyPoseRequest` | — | `BodySnapshot{joints[19]}` | 관절 표시 임계 0.45 (화면 밖 추정 관절 제거) |
| `DetectHumanBodyPose3DRequest` | 옵션(기본 off) | `Body3DSnapshot{positions[17], bodyHeight}` | 추후 리그 깊이에 사용 |
| `GeneratePersonSegmentationRequest` | fast/balanced/accurate (기본 balanced) | `MaskImage` (CIMaskToAlpha → CGImage) | OS 27: `CVReadOnlyPixelBuffer.withUnsafeBuffer` |
| `DetectContoursRequest` | 마스크 CIImage 입력, maxDim 320, ε 0.004 | `[[CGPoint]]` 실루엣 폴리곤 | 점 24개 미만 윤곽 무시 |
| `DetectFaceLandmarksRequest` | 기본 on | `FaceSnapshot{boundingBox, regions[10], roll, yaw}` | `pointsInImageCoordinates(1×1, .upperLeft)` 트릭 |

무거운 요청(세그멘테이션·윤곽·얼굴·3D)은 `heavyRequestCadence = 2`로 격프레임 실행·캐시.

### 3.2 제스처
| 종류 | 판정 |
|---|---|
| 손가락 펼침 | `|tip−wrist| / |PIP−wrist| > 1.55`; 엄지는 `|thumbTip−indexMCP| > 0.9·palmSize` |
| 핀치 | `1 − |thumbTip−indexTip| / (0.45·palmSize)`, > 0.55 |
| openPalm | 비엄지 4개 이상 펼침 |
| fist / thumbsUp | 비엄지 0개 펼침 (+ 엄지 위) |
| point / peace / rockOn / okSign | 펼친 손가락 집합 매칭 |
| swipe ← → ↑ ↓ | 0.35 s 내 이동 > 0.22, 축 지배 1.4× |
| wave | 펼친 손, 1.2 s 내 x 반전 ≥ 3, 진폭 > 0.25 |
| spread / squeeze | 0.6 s 내 양손 거리 변화 ±0.18 |
| clap | 거리 < 0.09, 0.2 s 전 2.5× 이상 |
| 히스테리시스 | 발동 3프레임, 해제 4프레임, 동적 쿨다운 0.8 s |

출력: `HandGestureState`(연속) + `GestureEvent`(이산). 이벤트는 프리셋 바인딩을 거쳐 `EffectEngine.handle`과 `AppModel` 동작(프리셋 순환, 만화경/메시 토글, 정지, 스냅샷)으로 분기.

### 3.3 이펙트 레이어
`EffectLayer` 11종 — trails, sparks, skeleton, lightPainting, forceField, distortion, kaleidoscope, constellation, auraOutline, wireframeSkin, faceMesh.
`EffectPreset{name, mood, layers, palette(2–4 hex), intensity 1–10, persistence 1–10, bindings}` — `@Generable` + `Codable`.

렌더 순서: 배경(비디오/데모 그라디언트) → 오라 → 와이어프레임 → 스트로크 → 트레일 → 별자리 → 입자 → 리플 → 스켈레톤 → 얼굴 → 버스트 라벨. 글로우는 `GraphicsContext.addFilter(.blur)` + `.plusLighter`.

입자 시뮬레이션(`EffectEngine`): 최대 1,800개, 끌어당김 `f ∝ palmSize/(d²+0.05)`, 밀어냄은 `4·palmSize` 반경 내, 드래그 `0.25^dt`, 중력 0.012.

### 3.4 메시
**와이어프레임 스킨**: 영역 = 윤곽 bbox 합집합(대안: 관절 bbox), 밀도 4–40, 호흡 변위, 손 밀어내기(주먹은 당김), `clipToLayer(마스크)`.
**USDZ 리그**: `PerspectiveCameraComponent` 60° 세로 FOV, 평면 z=−2 m. 12 `MeshSlot`(뼈 정의는 `MeshSlot.bone`). 파트 정규화(중심 정렬, Y extent = 1) 후 뼈 길이 × `rigScale`. 스무딩 k=0.45. 슬롯 이름 미발견 시 전체 모델 → torso(×2.4). 파일은 보안 범위 북마크로 영속화.

### 3.5 디렉터 (FoundationModels)
| 경로 | API | 비고 |
|---|---|---|
| 프리셋 생성 | `LanguageModelSession(instructions:)` + `respond(to:generating: EffectPreset.self, options: temperature 0.8)` | 바인딩 비면 기본 바인딩 보충 |
| 대화 | `LanguageModelSession(tools:instructions:)` + `respond(to:)` | 도구: applyPreset, setLayers, setPalette, bindGesture, setMeshMode, sceneStatus. `LanguageModelError.contextSizeExceeded` 시 세션 재생성 |
| 내레이션 | 7 s 주기, 매번 새 세션, temperature 1.0 | 실패는 무시 |
| 가용성 | `SystemLanguageModel.default.availability` 스위치 | 사유 문구 UI 표시 |

도구는 `Sendable struct`가 `AppModel`(MainActor)을 보유하고 `MainActor.run`으로 상태를 바꾼다.

### 3.6 설정·영속화
`UserDefaults["mirage.settings.v1"]`에 JSON: `VisionConfig`, `MeshRigSettings`, 현재 `EffectPreset`, 사용자 프리셋, 카메라 ID, HUD/통계 표시.

### 3.7 데모 모드
`DemoPoseSource`: 흔드는 양손(제스처 주기 순환), 서 있는 몸, 볼록 껍질 실루엣 + 320×180 래스터 마스크, 얼굴 영역. 카메라 실패 시 자동 전환.

---

## 4. 비기능 요구사항
| 항목 | 요구 | 구현 |
|---|---|---|
| 프라이버시 | 영상 외부 전송 없음, 카메라 사용 설명 명시 | 샌드박스 + 카메라 엔타이틀먼트, 네트워크 권한 없음 |
| 성능 | 분석 ≥ 15 fps 목표, 렌더 60 fps | 격프레임 캐시, 분리 루프, 입자 상한 |
| 복원력 | 카메라 실패/권한 거부 시 앱 사용 가능 | 데모 모드 자동 전환 + 에러 배너 |
| 접근성 | 다크 모드, HUD 토글, 한국어 UI | `preferredColorScheme(.dark)`, ⇧⌘H |
| 유지보수 | 외부 의존성 0, 파일당 단일 책임 | SPM 0개, Core/App 분리 |

---

## 5. 빌드 설정 (Xcode)
| 설정 | 값 | 이유 |
|---|---|---|
| `SUPPORTED_PLATFORMS` | `macosx` | 카메라/RealityView/파일 패널 macOS 전용 흐름 |
| `ENABLE_APP_SANDBOX` | YES | 배포 안전성 |
| `ENABLE_RESOURCE_ACCESS_CAMERA` | YES | 카메라 엔타이틀먼트 |
| `ENABLE_USER_SELECTED_FILES` | readwrite | USDZ 가져오기(읽기) + 스냅샷 저장(쓰기) |
| `NSCameraUsageDescription` | 설정됨 | TCC 프롬프트 문구 |
| `CFBundleDisplayName` | Mirage | 창 소유자 이름 (스크린샷 자동화에도 사용) |
| `SWIFT_VERSION` / 격리 | 5.0 / MainActor 기본 | 데이터 타입에 `nonisolated` 명시 |

---

## 6. OS 27 API 메모 (구현 중 확인)
- `PixelBufferObservation.pixelBuffer`는 `CVReadOnlyPixelBuffer` → `withUnsafeBuffer { $0 }`로 `CVPixelBuffer` 획득.
- `GeneratePersonSegmentationRequest`에 `outputPixelFormat`은 없음(기본 OneComponent8).
- `HumanBodyPose3DObservation.bodyHeight`는 `Measurement<UnitLength>`, `FaceObservation.roll/yaw`는 `Measurement<UnitAngle>`(비옵셔널).
- `LanguageModelSession.GenerationError`는 deprecated → `LanguageModelError` 사용.
- `RealityView`는 macOS에서 투명 배경으로 SwiftUI 위에 겹칠 수 있음(스크린샷 `demo-rig.png`로 확인).
- SwiftUI `GraphicsContext` 복사본은 같은 표면을 공유하므로, 클리핑은 복사본에 적용하면 된다(`inout` 중첩 접근 오류 회피).

---

## 7. 리스크와 완화
| 리스크 | 영향 | 완화 |
|---|---|---|
| Vision 요청 상호 경합으로 fps 저하 | 반응성 | 격프레임 캐시, 세그멘테이션 fast 옵션, 손 개수 제한 |
| 화면 밖 관절의 저신뢰 추정 | 잘못된 뼈대/리그 | 임계 0.45, 슬롯 자동 숨김 |
| 핀치/주먹 오분류 (손 각도) | 의도치 않은 동작 | 히스테리시스, 쿨다운, 바인딩 사용자 조정 |
| Apple Intelligence 미활성 | 디렉터 불가 | 가용성 사유 표시, 나머지 기능 독립 |
| USDZ 파트 명명 불일치 | 리그 미부착 | 전체 모델 폴백, 패널에 연결된 슬롯 표시 |

---

## 8. 실측 (2026-10-02, MacBook Air M4)
| 지표 | 값 | 출처 |
|---|---|---|
| Vision 합계 | 9–35 ms (워밍업 ~60 ms) | HUD / 설정 탭 단계별 시간 |
| hands / body / segmentation / face / contours | 15.5 / 15.6 / 16.1 / 19.1 / 1.8 ms | `kaleido-settings.png` |
| 분석 fps (사람 있음 / 빈 방) | 11–21 / 30 | HUD |
| 렌더 fps | 56–117 | HUD |
| 프리셋 생성 | ~10 s | `director-generate.png` |
| 도구 호출 3개 포함 대화 | ~15 s | `director-chat.png` |

---

## 9. 향후 (v1.1+)
1. `Body3D` 깊이·회전으로 리그 파트의 z/orientation 부여.
2. 손가락별 글러브 슬롯(현재 손 전체 1슬롯) 및 `HandSkeleton` 기반 손가락 본.
3. 세그멘테이션 마스크를 Metal 셰이더로 직접 샘플링하는 GPU 와이어프레임(현재 Canvas Path).
4. 제스처 녹화 → 사용자 정의 제스처(Create ML 손 포즈 분류기) 학습 파이프라인.
5. 영상 녹화(ReplayKit/AVAssetWriter), 라이브 월페이퍼/스크린세이버 모드.
6. Swift Testing: 제스처 분류기 합성 입력 테스트, 좌표 변환 테스트, 프리셋 Codable 라운드트립.
