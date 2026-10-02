import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import OSLog

/// One camera frame. CVPixelBuffer isn't formally Sendable, but we never mutate it.
nonisolated struct CameraFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
    var size: CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }
}

nonisolated struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isContinuityCamera: Bool
}

nonisolated enum CameraError: LocalizedError {
    case permissionDenied
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "카메라 접근이 거부되었습니다. 시스템 설정 > 개인정보 보호 > 카메라에서 Mirage를 허용해 주세요."
        case .noDevice: "사용 가능한 카메라가 없습니다."
        case .cannotAddInput: "카메라 입력을 세션에 추가할 수 없습니다."
        case .cannotAddOutput: "비디오 출력을 세션에 추가할 수 없습니다."
        }
    }
}

/// AVFoundation capture wrapped as an AsyncStream of frames.
/// Runs entirely off the main actor; the delegate callback arrives on `queue`.
nonisolated final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirage.camera.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var continuation: AsyncStream<CameraFrame>.Continuation?
    private let log = Logger(subsystem: "Mirage", category: "Camera")

    /// Newest-frame-wins stream. Consumers that fall behind simply skip frames.
    let frames: AsyncStream<CameraFrame>

    override init() {
        var cont: AsyncStream<CameraFrame>.Continuation?
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        super.init()
        continuation = cont
    }

    // MARK: Discovery

    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, isContinuityCamera: $0.isContinuityCamera)
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: Lifecycle

    func start(deviceID: String?) async throws {
        guard await Self.requestAccess() else { throw CameraError.permissionDenied }

        let device: AVCaptureDevice?
        if let deviceID, let d = AVCaptureDevice(uniqueID: deviceID) {
            device = d
        } else {
            device = AVCaptureDevice.systemPreferredCamera
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }
        guard let device else { throw CameraError.noDevice }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configure(with: device)
                    if !session.isRunning { session.startRunning() }
                    log.info("Camera started: \(device.localizedName, privacy: .public)")
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }

        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        // Prefer 30 fps when the format allows it; keeps Vision load predictable.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
            do {
                try device.lockForConfiguration()
                let fps = min(30.0, range.maxFrameRate)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.unlockForConfiguration()
            } catch {
                log.error("Frame-rate lock failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Delegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        continuation?.yield(CameraFrame(pixelBuffer: pb, timestamp: ts))
    }
}
