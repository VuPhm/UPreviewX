import Foundation
import CoreGraphics

/// Snapshot of decoder path, display geometry, timing, and resource diagnostics.
public struct PlaybackDiagnostics: Codable, Equatable, Sendable {
    public var fileName: String
    public var fileSizeMB: Double
    public var containerFormat: String
    public var codecName: String
    public var codecDescription: String
    public var pixelFormat: String
    public var hwFormat: String
    public var hwdecCurrent: String
    public var hwdecInterop: String
    public var rawWidth: Int
    public var rawHeight: Int
    public var width: Int
    public var height: Int
    public var rotationDegrees: Int
    public var sampleAspectRatio: Double
    public var videoBitrateMbps: Double
    public var nominalFPS: Double
    public var estimatedFPS: Double
    public var droppedFrames: Int64
    public var decoderDroppedFrames: Int64
    public var avSyncDiffMs: Double
    public var engineInitLatencyMs: Double
    public var firstFrameLatencyMs: Double
    public var lastSeekLatencyMs: Double
    public var cpuUsagePercent: Double
    public var residentMemoryMB: Double
    public var peakMemoryMB: Double
    public var activeGPU: String
    public var isFastPreviewMode: Bool

    public init(
        fileName: String = "—",
        fileSizeMB: Double = 0,
        containerFormat: String = "—",
        codecName: String = "—",
        codecDescription: String = "—",
        pixelFormat: String = "—",
        hwFormat: String = "",
        hwdecCurrent: String = "no",
        hwdecInterop: String = "",
        rawWidth: Int = 0,
        rawHeight: Int = 0,
        width: Int = 0,
        height: Int = 0,
        rotationDegrees: Int = 0,
        sampleAspectRatio: Double = 1.0,
        videoBitrateMbps: Double = 0,
        nominalFPS: Double = 0,
        estimatedFPS: Double = 0,
        droppedFrames: Int64 = 0,
        decoderDroppedFrames: Int64 = 0,
        avSyncDiffMs: Double = 0,
        engineInitLatencyMs: Double = 0,
        firstFrameLatencyMs: Double = 0,
        lastSeekLatencyMs: Double = 0,
        cpuUsagePercent: Double = 0,
        residentMemoryMB: Double = 0,
        peakMemoryMB: Double = 0,
        activeGPU: String = "Intel UHD Graphics 630",
        isFastPreviewMode: Bool = false
    ) {
        self.fileName = fileName
        self.fileSizeMB = fileSizeMB
        self.containerFormat = containerFormat
        self.codecName = codecName
        self.codecDescription = codecDescription
        self.pixelFormat = pixelFormat
        self.hwFormat = hwFormat
        self.hwdecCurrent = hwdecCurrent
        self.hwdecInterop = hwdecInterop
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.sampleAspectRatio = sampleAspectRatio
        self.videoBitrateMbps = videoBitrateMbps
        self.nominalFPS = nominalFPS
        self.estimatedFPS = estimatedFPS
        self.droppedFrames = droppedFrames
        self.decoderDroppedFrames = decoderDroppedFrames
        self.avSyncDiffMs = avSyncDiffMs
        self.engineInitLatencyMs = engineInitLatencyMs
        self.firstFrameLatencyMs = firstFrameLatencyMs
        self.lastSeekLatencyMs = lastSeekLatencyMs
        self.cpuUsagePercent = cpuUsagePercent
        self.residentMemoryMB = residentMemoryMB
        self.peakMemoryMB = peakMemoryMB
        self.activeGPU = activeGPU
        self.isFastPreviewMode = isFastPreviewMode
    }

    /// True if VideoToolbox hardware decoding is actively used for the current stream.
    public var isHardwareAccelerated: Bool {
        let normalized = hwdecCurrent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "no" && normalized != "none"
    }

    /// Human-readable summary of the active decoding path.
    public var decodePathSummary: String {
        if isHardwareAccelerated {
            return "Hardware (\(hwdecCurrent))"
        } else if isFastPreviewMode {
            return "Software (Fast Preview Mode)"
        } else {
            return "Software (FFmpeg/dav1d fallback)"
        }
    }

    /// Display resolution summary accounting for rotation and sample aspect ratio.
    public var resolutionSummary: String {
        guard width > 0 && height > 0 else { return "—" }
        if rotationDegrees != 0 || (rawWidth > 0 && rawHeight > 0 && (rawWidth != width || rawHeight != height)) {
            return "\(width)×\(height) (coded \(rawWidth)×\(rawHeight), rot \(rotationDegrees)°)"
        }
        return "\(width)×\(height)"
    }

    /// Computes the effective display dimensions from coded size, DAR/SAR size, and rotation metadata.
    public static func effectiveDisplaySize(
        codedWidth: Int,
        codedHeight: Int,
        darWidth: Int,
        darHeight: Int,
        rotationDegrees: Int
    ) -> CGSize {
        let baseW = darWidth > 0 ? darWidth : codedWidth
        let baseH = darHeight > 0 ? darHeight : codedHeight
        guard baseW > 0 && baseH > 0 else { return .zero }

        let normRot = ((rotationDegrees % 360) + 360) % 360
        if normRot == 90 || normRot == 270 {
            return CGSize(width: CGFloat(baseH), height: CGFloat(baseW))
        }
        return CGSize(width: CGFloat(baseW), height: CGFloat(baseH))
    }
}
