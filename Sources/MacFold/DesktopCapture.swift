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
    // This identity belongs to our process, not a window or Space. Keep it when
    // settings are closed or moved offscreen so every new stream excludes us.
    private var ownApplication: SCRunningApplication?
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var isRunning: Bool { stream != nil || starting }

    @MainActor private func availableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        if let own = content.applications.first(where: { $0.processID == getpid() }) {
            ownApplication = own
        }
        return content
    }

    @MainActor func verifyAccess() async throws {
        let content = try await availableContent()
        guard !content.displays.isEmpty else { throw AppError.message("No capturable display is available.") }
        guard ownApplication != nil else { throw AppError.message("Cannot safely exclude Mac Fold from capture. Please reopen the app.") }
    }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        let available: SCShareableContent
        do { available = try await availableContent() }
        catch { guard token == generation else { return }; throw error }
        guard token == generation else { return }
        guard let display = available.displays.first(where:{$0.displayID == displayID}) else {
            throw AppError.message("The built-in display is not available.")
        }
        // Exclude our own application explicitly, avoiding recursive capture of the overlay.
        guard let ownApplication else { throw AppError.message("Cannot safely exclude Mac Fold from capture. Please reopen the app.") }
        let filter = SCContentFilter(display:display, excludingApplications:[ownApplication], exceptingWindows:[])
        logger.notice("Capture prepared with process exclusion; app active: \(NSApp.isActive,privacy:.public).")
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
        frames.acceptStream(ObjectIdentifier(newStream))
        do {
            try await newStream.startCapture()
            if token == generation { logger.notice("Live screen stream started.") }
            if token != generation { try? await newStream.stopCapture() }
        } catch {
            guard token == generation else { return }
            stream = nil; frames.invalidateStream()
            throw error
        }
    }

    @MainActor func stop() {
        generation += 1; starting = false
        let previous = stream; stream = nil
        frames.invalidateStream()
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue:rawStatus) else { return }
        let identity = ObjectIdentifier(stream)
        if status == .complete, let buffer = sampleBuffer.imageBuffer {
            // No per-frame main-queue block or buffer backlog. Identity and put
            // are atomic with stop(), so old callbacks cannot resurrect frames.
            if frames.put(buffer,from:identity) == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.logger.notice("First complete live desktop frame received.")
                    self.onFirstFrame?()
                }
            }
        } else if status == .blank || status == .suspended || status == .stopped {
            if frames.clear(from:identity) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.onUnavailable?()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.frames.invalidateStream()
            self.onFailure?(error.localizedDescription)
        }
    }
}
