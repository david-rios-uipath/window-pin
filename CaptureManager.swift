import Cocoa
import Carbon
import ScreenCaptureKit
import AVFoundation

// MARK: - Screen Capture Manager (from Topit)

class CaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    var capturing = false
    var onError: (() -> Void)?

    // Match display refresh rate (120 on ProMotion); SCStream only emits on change so idle cost is nil
    private func makeConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        return config
    }

    func startCapture(window: SCWindow) async throws {
        if stream != nil { return }
        let config = makeConfig()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 14, *) {
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else {
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await stream?.startCapture()
        capturing = true
    }

    func stopCapture() {
        guard let s = stream else { return }
        s.stopCapture { _ in }
        stream = nil
        capturing = false
    }

    func updateCaptureSize(width: Int, height: Int) {
        guard let s = stream else { return }
        let config = makeConfig()
        config.width  = width
        config.height = height
        s.updateConfiguration(config) { err in
            if let err = err { print("[WARN] updateConfig: \(err)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, outputType == .screen else { return }
        // enqueue is thread-safe; skipping the main-queue hop saves up to a frame of latency.
        // The layer keeps the last frame, so no static fallback layer is needed.
        videoLayer.enqueue(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[WARN] Capture stopped: \(error)")
        DispatchQueue.main.async {
            self.stream = nil
            self.capturing = false
            self.onError?()
        }
    }
}
