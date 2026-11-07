import Foundation

/// Snapshot of decoder path, timing, and resource diagnostics.
public struct PlaybackDiagnostics: Codable, Equatable, Sendable {
    public var fileName: String
    public var containerFormat: String
    public var codecName: String
    public var codecDescription: String
    public var pixelFormat: String
    public var hwFormat: String
    public var hwdecCurrent: String
    public var hwdecInterop: String
    public var width: Int
    public var height: Int
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
    public var activeGPU: String

    public init(
        fileName: String = "—",
        containerFormat: String = "—",
        codecName: String = "—",
        codecDescription: String = "—",
        pixelFormat: String = "—",
        hwFormat: String = "",
        hwdecCurrent: String = "no",
        hwdecInterop: String = "",
        width: Int = 0,
        height: Int = 0,
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
        activeGPU: String = "Intel UHD Graphics 630"
    ) {
        self.fileName = fileName
        self.containerFormat = containerFormat
        self.codecName = codecName
        self.codecDescription = codecDescription
        self.pixelFormat = pixelFormat
        self.hwFormat = hwFormat
        self.hwdecCurrent = hwdecCurrent
        self.hwdecInterop = hwdecInterop
        self.width = width
        self.height = height
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
        self.activeGPU = activeGPU
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
        } else {
            return "Software (FFmpeg/dav1d fallback)"
        }
    }

    public var resolutionSummary: String {
        guard width > 0 && height > 0 else { return "—" }
        return "\(width)×\(height)"
    }
}
