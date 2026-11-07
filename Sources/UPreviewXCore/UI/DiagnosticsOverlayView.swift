import AppKit

/// Developer diagnostics overlay displaying live codec, VideoToolbox vs software decode status,
/// active GPU renderer, frame timing, latency metrics, CPU %, and memory usage.
public final class DiagnosticsOverlayView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "DECODER & PERFORMANCE DIAGNOSTICS")
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

        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .systemGreen

        let headerStack = NSStackView(views: [titleLabel, NSView(), badgeLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY

        detailsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsLabel.textColor = .white
        detailsLabel.maximumNumberOfLines = 14
        detailsLabel.lineBreakMode = .byTruncatingTail

        let mainStack = NSStackView(views: [headerStack, detailsLabel])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 6
        mainStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
    }

    public func update(with diag: PlaybackDiagnostics) {
        if diag.isHardwareAccelerated {
            badgeLabel.stringValue = "HW: \(diag.hwdecCurrent.uppercased())"
            badgeLabel.textColor = .systemGreen
        } else {
            badgeLabel.stringValue = "SW FALLBACK"
            badgeLabel.textColor = .systemOrange
        }

        let pixFmtDisplay = diag.hwFormat.isEmpty ? diag.pixelFormat : "\(diag.pixelFormat) (\(diag.hwFormat))"
        let lines = [
            "File:         \(diag.fileName) [\(diag.containerFormat)]",
            "Video Codec:  \(diag.codecName) (\(diag.codecDescription))",
            "Pixel Format: \(pixFmtDisplay)",
            "Decode Path:  \(diag.decodePathSummary)",
            "Active GPU:   \(diag.activeGPU)",
            String(format: "Resolution:   %@ @ %.2f fps (est %.1f fps)", diag.resolutionSummary, diag.nominalFPS, diag.estimatedFPS),
            String(format: "Frame Drops:  VO: %lld | Dec: %lld | A/V: %+.1f ms", diag.droppedFrames, diag.decoderDroppedFrames, diag.avSyncDiffMs),
            String(format: "Latency:      Init: %.1f ms | 1st Frame: %.1f ms | Seek: %.1f ms", diag.engineInitLatencyMs, diag.firstFrameLatencyMs, diag.lastSeekLatencyMs),
            String(format: "Resources:    CPU: %.1f%% | RSS Memory: %.1f MB", diag.cpuUsagePercent, diag.residentMemoryMB)
        ]
        detailsLabel.stringValue = lines.joined(separator: "\n")
    }
}
