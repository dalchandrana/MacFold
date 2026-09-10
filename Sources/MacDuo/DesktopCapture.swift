import AppKit
import ScreenCaptureKit
import CoreMedia
import OSLog

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()
    private let logger = Logger(subsystem:"local.lidflow.mac",category:"capture")
    private var stream: SCStream?
    private let queue = DispatchQueue(label:"local.lidflow.frames",qos:.userInteractive)
    private var generation = 0
    private var starting = false
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    private var hasFrame = false
    var isRunning: Bool { stream != nil || starting }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        let available: SCShareableContent
        do { available = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true) }
        catch { guard token == generation else { return }; throw error }
        guard token == generation else { return }
        guard let display = available.displays.first(where:{$0.displayID == displayID}) else {
            throw AppError.message("The built-in display is not available.")
        }
        // Exclude our own application explicitly, avoiding recursive capture of the overlay.
        let ownApp = available.applications.filter { $0.processID == getpid() }
        guard !ownApp.isEmpty else { throw AppError.message("Cannot safely exclude Mac Duo from capture. Please reopen the app.") }
        let filter = SCContentFilter(display:display, excludingApplications:ownApp, exceptingWindows:[])
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value:1,timescale:Int32(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        let newStream = SCStream(filter:filter,configuration:config,delegate:self)
        try newStream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        stream = newStream
        do {
            try await newStream.startCapture()
            if token == generation { logger.notice("Live screen stream started.") }
            if token != generation { try? await newStream.stopCapture() }
        } catch {
            guard token == generation else { return }
            stream = nil; frames.clear()
            throw error
        }
    }

    @MainActor func stop() {
        generation += 1; starting = false
        let previous = stream; stream = nil
        frames.clear(); hasFrame = false
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue:rawStatus) else { return }
        let buffer = sampleBuffer.imageBuffer
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            if status == .complete, let buffer {
                self.frames.put(buffer)
                if !self.hasFrame {
                    self.hasFrame = true
                    self.logger.notice("First complete live desktop frame received.")
                    self.onFirstFrame?()
                }
            } else if status == .blank || status == .suspended || status == .stopped {
                self.frames.clear(); self.hasFrame = false; self.onUnavailable?()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.frames.clear(); self.hasFrame = false
            self.onFailure?(error.localizedDescription)
        }
    }
}
