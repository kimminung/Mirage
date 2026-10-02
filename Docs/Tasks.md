# Mirage — Tasks

상태: ✅ 완료 · 🔄 진행/검증 중 · ⬜ 예정 · 💡 아이디어
기준일 2026-10-02.

## M0 — 프로젝트 준비
- ✅ 앱 이름 **Mirage** 확정, 표시 이름/`CFBundleDisplayName` 설정
- ✅ 빌드 설정: macOS 전용, 샌드박스 + 카메라 엔타이틀먼트, 사용자 파일 readwrite, 카메라 사용 설명
- ✅ Apache-2.0 `LICENSE`, `NOTICE`, `.gitignore`
- ✅ `git init -b main` (첫 커밋은 GitHub Desktop에서)

## M1 — 캡처 & 인식
- ✅ `CameraService`: AVCaptureSession 720p BGRA, 30 fps 고정, Continuity/external 디스커버리, AsyncStream(bufferingNewest 1)
- ✅ `VisionPipeline` actor: 손·몸·몸3D·세그멘테이션·윤곽·얼굴 6요청 `async let` 동시 실행
- ✅ 뷰 정규화 좌표 변환 + 거울 모드, chirality 유지
- ✅ 무거운 요청 격프레임 캐시(`heavyRequestCadence`)
- ✅ OS 27 API 대응 (`CVReadOnlyPixelBuffer`, `Measurement` 반환형)
- 🔄 몸 3D 결과를 UI 외 용도(리그 깊이)로 활용 — 수집만 됨
- ⬜ 세그멘테이션 입력 다운스케일 옵션으로 fps 추가 확보

## M2 — 제스처
- ✅ 특징 추출(펼침 비율, 핀치, 펼침도, 엄지 위)
- ✅ 정적 8종 분류 + 히스테리시스(3/4 프레임)
- ✅ 동적 5종(스와이프 4, 흔들기), 양손 3종(벌리기·모으기·박수), 쿨다운
- ✅ 제스처 → 동작 바인딩(프리셋별, UI/디렉터에서 편집)
- 🔄 실사용 오분류 튜닝: 손등이 보일 때 핀치/주먹 혼동 사례 수집 필요
- ⬜ 사용자 정의 제스처 녹화 + Create ML 분류기 슬롯

## M3 — 이펙트
- ✅ `EffectEngine`: 입자(끌어당김/밀어냄), 리본 트레일, 라이트 페인팅, 리플, 버스트 라벨, 팔레트 오프셋
- ✅ `StageRenderer` 11 레이어: trails · sparks · skeleton · lightPainting · forceField · distortion · kaleidoscope · constellation · auraOutline · wireframeSkin · faceMesh
- ✅ Core Image 프레임 필터: 거울, 손바닥 범프 렌즈(주먹 흡입), 만화경
- ✅ 내장 프리셋 6종 + 사용자 프리셋 저장/삭제, 팔레트 편집, 강도/잔상 슬라이더
- ✅ 스냅샷(ImageRenderer 2×, NSSavePanel), 프레임 정지, HUD/통계 토글, 키보드 단축키
- ⬜ 오디오 반응(마이크 레벨 → 입자 세기) — 마이크 권한 추가 필요
- 💡 GPU 입자(Metal compute)로 상한 1,800 → 50k

## M4 — 메시
- ✅ 와이어프레임 스킨: 마스크 `clipToLayer`, 밀도/색/불투명도/호흡/손 밀어내기
- ✅ RealityKit 리그: 가상 카메라, 12 슬롯, 플레이스홀더, USDZ 가져오기(보안 범위 북마크), 파트 정규화, 스무딩
- ✅ Blender 제작 가이드(패널 + README + 다이어그램)
- 🔄 실제 Blender USDZ로 end-to-end 검증 (플레이스홀더로만 확인됨 — 사용자 메시 대기)
- ⬜ 몸 3D로 파트 깊이/회전 적용
- ⬜ 손가락별 글러브 슬롯

## M5 — 디렉터 (FoundationModels)
- ✅ 가용성 체크 + 사유 표시
- ✅ `@Generable EffectPreset` 가이드 생성 → 적용/저장 (실측 ‘BlueFistWave’ 생성 확인)
- ✅ 도구 6종 + 대화, 컨텍스트 초과 시 세션 재생성 (실측 applyPreset·sceneStatus·setPalette 연쇄 호출 확인)
- ✅ 7초 주기 장면 내레이션 (한국어 한 줄)
- ⬜ 스트리밍 응답(`streamResponse`)으로 대화 체감 지연 개선
- 💡 프리셋 생성에 현재 장면 이미지(`Attachment`) 첨부

## M6 — 데모·문서·배포
- ✅ 데모 모드(합성 포즈/마스크/얼굴), 카메라 실패 시 자동 전환
- ✅ 실행 인자(`-demo -tab -preset -mesh -kaleido -narrate -direct -say`)로 스크린샷 자동화
- ✅ 스크린샷 8종 (`Docs/screenshots`), 다이어그램 5종 (`Docs/diagrams`)
- ✅ README (KR + EN summary), Tech PRD, Tasks
- ⬜ GitHub 첫 커밋/푸시 (GitHub Desktop)
- ⬜ 앱 아이콘(Assets.xcassets) 디자인
- ⬜ Swift Testing 타깃: 제스처 분류기(합성 손), 좌표 변환, 프리셋 Codable/Generable 라운드트립
- ⬜ 서명·공증 후 DMG 배포 스크립트

## 알려진 이슈
- ✅ **수정됨 (2026-10-02 14:50)**: 앱이 "튕기던" 원인은 과부하가 아니라 `EffectsPanel` 팔레트 ColorPicker 바인딩의 배열 인덱스 범위 초과(EXC_BREAKPOINT, 크래시 리포트 `MyApp-2026-10-02-142950.ips`). 팔레트 색 수가 줄어드는 순간(4색→3색 프리셋 전환, − 버튼, 디렉터 setPalette)에 옛 인덱스로 접근했음. getter/setter에 범위 가드 추가. 같은 커밋에서 라이트 페인팅 스트로크 상한(200개 / 20k 점)도 추가.
- 손이 카메라에 매우 가까우면(어깨 미검출) 몸통 슬롯이 숨겨져 리그 파트가 보이지 않음 — 의도된 동작이나 안내 필요.
- 데모 모드 실루엣은 볼록 껍질이라 겨드랑이 사이도 채워짐(데모 한정).
- `GenerationError` deprecated 경고는 `LanguageModelError`로 교체 완료; 다른 경고 없음.
