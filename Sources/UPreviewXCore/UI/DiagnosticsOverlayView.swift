import AppKit

/// Developer diagnostics overlay displaying live codec, VideoToolbox vs software decode status,
/// active GPU renderer, display geometry, frame timing, latency metrics, CPU %, and memory usage.
public final class DiagnosticsOverlayView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "DECODER & PERFORMANCE")
    private let badgeLabel = NSTextField(labelWithString: "IDLE")
    private let detailsLabel = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        titleLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .systemGreen
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, NSView(), badgeLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY

        detailsLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailsLabel.textColor = .white
        detailsLabel.maximumNumberOfLines = 16
        detailsLabel.lineBreakMode = .byTruncatingTail
        detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let mainStack = NSStackView(views: [headerStack, detailsLabel])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 5
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        let prefWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 290)
        prefWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            prefWidth
        ])
    }

    public func update(with diag: PlaybackDiagnostics) {
        if diag.isHardwareAccelerated {
            badgeLabel.stringValue = "HW: \(diag.hwdecCurrent.uppercased())"
            badgeLabel.textColor = .systemGreen
        } else if diag.isFastPreviewMode {
            badgeLabel.stringValue = "SW: FAST PREVIEW"
            badgeLabel.textColor = .systemYellow
        } else {
            badgeLabel.stringValue = "SW FALLBACK"
            badgeLabel.textColor = .systemOrange
        }

        let pixFmtDisplay = diag.hwFormat.isEmpty ? diag.pixelFormat : "\(diag.pixelFormat) (\(diag.hwFormat))"
        let sizeStr = diag.fileSizeMB > 0 ? String(format: "%.1f MB", diag.fileSizeMB) : "—"
        let brStr = diag.videoBitrateMbps > 0 ? String(format: "%.1f Mbps", diag.videoBitrateMbps) : "—"
        let lines = [
            "File:         \(diag.fileName) (\(sizeStr))",
            "Format/Codec: [\(diag.containerFormat)] \(diag.codecName) (br: \(brStr))",
            "Pixel Format: \(pixFmtDisplay)",
            "Decode Path:  \(diag.decodePathSummary)",
            "Active GPU:   \(diag.activeGPU)",
            "Display Size: \(diag.resolutionSummary)",
            String(format: "Frame Rate:   %.2f fps nominal | %.1f fps effective", diag.nominalFPS, diag.estimatedFPS),
            String(format: "Frame Drops:  VO: %lld | Dec: %lld | A/V: %+.1f ms", diag.droppedFrames, diag.decoderDroppedFrames, diag.avSyncDiffMs),
            String(format: "Latency:      Init: %.1f ms | 1st: %.1f ms | Seek: %.1f ms", diag.engineInitLatencyMs, diag.firstFrameLatencyMs, diag.lastSeekLatencyMs),
            String(format: "Resources:    CPU: %.1f%% | RSS: %.1f MB (Peak %.1f MB)", diag.cpuUsagePercent, diag.residentMemoryMB, diag.peakMemoryMB)
        ]
        detailsLabel.stringValue = lines.joined(separator: "\n")
    }
}
