import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Errors surfaced to the user when capturing or saving fails.
enum RecorderError: LocalizedError {
    case displayNotFound, noFrames, encoderFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The selected display is no longer available."
        case .noFrames: return "No frames were captured."
        case .encoderFailed: return "ImageIO could not encode the GIF."
        }
    }
}

/// Captures a display region with SCStream and spools frames to disk as JPEGs to bound memory.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame { let url: URL; let time: Double }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegionGifRecorder-\(UUID().uuidString)", isDirectory: true)
    var onStop: ((Error) -> Void)?
    private(set) var droppedFrames = 0

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "regiongif.sample")
    private let writerQueue = DispatchQueue(label: "regiongif.writer", qos: .userInitiated)
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var pending = 0              // guarded by `lock`
    private var frames: [Frame] = []     // writerQueue only
    private var firstTime: Double?       // sampleQueue only
    private var index = 0                // sampleQueue only

    func start(displayID: CGDirectDisplayID, sourceRect: CGRect, size: CGSize, fps: Int, showsCursor: Bool) async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }
        // Exclude our own overlay/outline windows from the capture.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(2, Int(size.width))
        config.height = max(2, Int(size.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture and returns every frame written so far, after the writer queue drains.
    func stop() async -> [Frame] {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.writerQueue.async { continuation.resume(returning: self.frames) }
            }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Skip frames when the encoder falls behind instead of queueing unbounded images.
        lock.lock()
        let busy = pending >= 3
        if !busy { pending += 1 }
        lock.unlock()
        if busy { droppedFrames += 1; return }

        let time = sampleBuffer.presentationTimeStamp.seconds
        let base = firstTime ?? time
        firstTime = base
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let image = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: rect) else {
            finishWrite()
            return
        }
        let url = tempDir.appendingPathComponent(String(format: "%05d.jpg", index))
        index += 1
        writerQueue.async {
            if Self.writeJPEG(image, to: url) { self.frames.append(Frame(url: url, time: time - base)) }
            self.finishWrite()
        }
    }

    private func finishWrite() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

/// Assembles spooled frames into a looping GIF with per-frame delays taken from capture timestamps.
enum GifEncoder {
    static func write(frames: [ScreenRecorder.Frame], scratch: URL, folder: URL, loopCount: Int, fps: Int) throws -> URL {
        guard !frames.isEmpty else { throw RecorderError.noFrames }
        let temp = scratch.appendingPathComponent("output.gif")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw RecorderError.encoderFailed
        }
        let gifKey = kCGImagePropertyGIFDictionary as String
        CGImageDestinationSetProperties(dest, [gifKey: [kCGImagePropertyGIFLoopCount as String: loopCount]] as CFDictionary)

        // GIF delays are in centiseconds; carry the rounding error forward so total duration stays accurate.
        var carry = 0.0
        for (i, frame) in frames.enumerated() {
            let raw = i + 1 < frames.count ? frames[i + 1].time - frame.time : 1.0 / Double(fps)
            let wanted = raw + carry
            let delay = max(0.02, (wanted * 100).rounded() / 100)
            carry = wanted - delay
            guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let props = [gifKey: [kCGImagePropertyGIFDelayTime as String: delay,
                                  kCGImagePropertyGIFUnclampedDelayTime as String: delay]]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw RecorderError.encoderFailed }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Recording \(formatter.string(from: Date()))"
        var target = folder.appendingPathComponent("\(stem).gif")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) \(n).gif")
            n += 1
        }
        try fm.moveItem(at: temp, to: target)
        return target
    }
}
