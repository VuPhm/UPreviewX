import AppKit
import UniformTypeIdentifiers
import UPreviewXCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [PlayerWindowController] = []
    private var didOpenInitialFile = false
    private var showDiagnosticsByDefault = false
    private var enableFastPreviewByDefault = false
    private var benchmarkTargets: [URL] = []
    private var isBenchmarkMode = false
    public let appLaunchTimestamp = CFAbsoluteTimeGetCurrent()

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        setupMainMenu()
        parseCommandLineArguments()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if isBenchmarkMode && !benchmarkTargets.isEmpty {
            runBenchmarkSuite(urls: benchmarkTargets)
            return
        }

        // Wait briefly for Finder AppleEvent open-file delivery before showing Open Panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            if !self.didOpenInitialFile && self.windowControllers.isEmpty {
                self.promptToOpenFile(terminateOnCancelIfNoWindows: true)
            }
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard !isBenchmarkMode else { return }
        didOpenInitialFile = true
        for url in urls where url.isFileURL {
            openVideoWindow(for: url)
        }
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !isBenchmarkMode else { return true }
        didOpenInitialFile = true
        let url = URL(fileURLWithPath: filename)
        openVideoWindow(for: url)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return UserSettings.shared.quitWhenLastWindowCloses
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        for controller in windowControllers {
            controller.engine.shutdown()
        }
        windowControllers.removeAll()
    }

    // MARK: - Window & File Opening

    private func openVideoWindow(for url: URL) {
        let controller: PlayerWindowController
        if let existing = windowControllers.first {
            controller = existing
        } else {
            let newController = PlayerWindowController(showDiagnostics: showDiagnosticsByDefault)
            if enableFastPreviewByDefault || UserSettings.shared.fastPreviewModeByDefault {
                newController.engine.setFastPreviewMode(true)
            }
            newController.onWindowWillClose = { [weak self] closed in
                self?.windowControllers.removeAll { $0 === closed }
                if self?.windowControllers.isEmpty == true && UserSettings.shared.quitWhenLastWindowCloses {
                    NSApp.terminate(nil)
                }
            }
            windowControllers.append(newController)
            controller = newController
        }
        controller.openMedia(url: url)
    }

    @objc public func openDocument(_ sender: Any?) {
        promptToOpenFile(terminateOnCancelIfNoWindows: windowControllers.isEmpty)
    }

    @objc public func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.showSettings()
    }

    @objc public func saveCurrentFrame(_ sender: Any?) {
        windowControllers.first?.captureCurrentFrame()
    }

    @objc public func fastForward(_ sender: Any?) {
        windowControllers.first?.engine.seekRelative(5.0, exact: false)
    }

    @objc public func rewind(_ sender: Any?) {
        windowControllers.first?.engine.seekRelative(-5.0, exact: false)
    }

    @objc public func toggleDiagnostics(_ sender: Any?) {
        windowControllers.first?.toggleDiagnosticsOverlay()
    }

    @objc public func toggleFastPreview(_ sender: Any?) {
        windowControllers.first?.toggleFastPreviewMode()
    }

    @objc public func toggleFullscreen(_ sender: Any?) {
        windowControllers.first?.toggleFullscreen()
    }

    @objc public func togglePlayPause(_ sender: Any?) {
        windowControllers.first?.engine.togglePlayPause()
    }

    @objc public func toggleSpeed(_ sender: Any?) {
        windowControllers.first?.toggleSpeed()
    }

    private func promptToOpenFile(terminateOnCancelIfNoWindows: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Open Video Preview"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .movie,
            .video,
            .mpeg4Movie,
            .quickTimeMovie,
            .avi
        ]
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            didOpenInitialFile = true
            openVideoWindow(for: url)
        } else if terminateOnCancelIfNoWindows && windowControllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // MARK: - CLI & Benchmark Runner

    private func parseCommandLineArguments() {
        let args = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["UPREVIEWX_DEV"] == "1" {
            showDiagnosticsByDefault = true
        }

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--diagnostics" || arg == "-d" {
                showDiagnosticsByDefault = true
            } else if arg == "--fast-preview" {
                enableFastPreviewByDefault = true
            } else if arg == "--benchmark" && idx + 1 < args.count {
                isBenchmarkMode = true
                showDiagnosticsByDefault = true
                benchmarkTargets.append(URL(fileURLWithPath: args[idx + 1]))
                idx += 1
            } else if arg == "--thumbnail" && idx + 2 < args.count {
                let inputURL = URL(fileURLWithPath: args[idx + 1])
                let outputURL = URL(fileURLWithPath: args[idx + 2])
                idx += 2
                var targetDim: CGFloat = 512
                if idx + 2 < args.count && args[idx + 1] == "--size", let dim = Double(args[idx + 2]) {
                    targetDim = CGFloat(dim)
                    idx += 2
                }
                let res = VideoThumbnailService.shared.generateThumbnailToFile(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    targetSize: CGSize(width: targetDim, height: targetDim)
                )
                switch res {
                case .success(let saved):
                    print("THUMBNAIL_GENERATED:\(saved.path)")
                    exit(0)
                case .failure(let error):
                    fputs("THUMBNAIL_ERROR:\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            } else if arg == "--benchmark-suite" && idx + 1 < args.count {
                isBenchmarkMode = true
                showDiagnosticsByDefault = true
                let dirURL = URL(fileURLWithPath: args[idx + 1])
                if let items = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
                    let mediaExts: Set<String> = ["mp4", "mov", "mkv", "webm", "m4v", "avi"]
                    let sorted = items
                        .filter { mediaExts.contains($0.pathExtension.lowercased()) }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    benchmarkTargets.append(contentsOf: sorted)
                }
                idx += 1
            } else if !arg.hasPrefix("-") {
                let candidate = URL(fileURLWithPath: arg)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    didOpenInitialFile = true
                    DispatchQueue.main.async { [weak self] in
                        self?.openVideoWindow(for: candidate)
                    }
                }
            } else if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" {
                idx += 1
            }
            idx += 1
        }
    }

    private func runBenchmarkSuite(urls: [URL]) {
        let controller = PlayerWindowController(showDiagnostics: true)
        if enableFastPreviewByDefault {
            controller.engine.setFastPreviewMode(true)
        }
        windowControllers.append(controller)
        let coldStartWindowMs = (CFAbsoluteTimeGetCurrent() - appLaunchTimestamp) * 1000.0
        var coldLaunchFirstFrameMs: Double = 0
        var results: [[String: Any]] = []

        func runNext(index: Int) {
            if index >= urls.count {
                if let jsonData = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    print("BENCHMARK_JSON_BEGIN")
                    print(jsonStr)
                    print("BENCHMARK_JSON_END")
                }
                controller.close()
                NSApp.terminate(nil)
                return
            }

            let url = urls[index]
            controller.onFirstFrameRendered = { [weak self] diag in
                guard let self = self else { return }
                if index == 0 && coldLaunchFirstFrameMs == 0 {
                    coldLaunchFirstFrameMs = (CFAbsoluteTimeGetCurrent() - self.appLaunchTimestamp) * 1000.0
                }
            }
            controller.openMedia(url: url)

            // Phase 1: Play for 2.2s to measure steady-state playback FPS, CPU, GPU, and adaptive window geometry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                controller.engine.refreshDiagnostics()
                let steadyDiag = controller.engine.diagnostics
                let steadyFPS = steadyDiag.estimatedFPS
                let steadyCPU = steadyDiag.cpuUsagePercent
                let steadyDrops = steadyDiag.droppedFrames
                let steadyDecDrops = steadyDiag.decoderDroppedFrames

                let dur = max(4.0, controller.engine.duration)
                let scrubTarget = min(dur * 0.55, max(1.5, dur - 1.0))

                // Phase 2: Fast keyframe scrub seek (simulating timeline drag)
                controller.engine.seek(to: scrubTarget, exact: false)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let keyframeSeekMs = controller.engine.diagnostics.lastSeekLatencyMs
                    let exactTarget = min(dur * 0.30, max(1.0, dur - 1.5))

                    // Phase 3: Accurate seek on release
                    controller.engine.seek(to: exactTarget, exact: true)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        controller.engine.refreshDiagnostics()
                        let d = controller.engine.diagnostics
                        let winFrame = controller.window?.frame ?? .zero
                        let winAspect = winFrame.height > 0 ? (winFrame.width / winFrame.height) : 0
                        let vidAspect = d.height > 0 ? (Double(d.width) / Double(d.height)) : 0

                        // Phase 4: Test steady-state pause CPU and thumbnail generation
                        controller.engine.pause()
                        let thumbStart = CFAbsoluteTimeGetCurrent()
                        var thumbMs: Double = 0
                        let sema = DispatchSemaphore(value: 0)
                        VideoThumbnailService.shared.generateThumbnail(for: url, targetSize: CGSize(width: 320, height: 320), completionQueue: nil) { _ in
                            thumbMs = (CFAbsoluteTimeGetCurrent() - thumbStart) * 1000.0
                            sema.signal()
                        }
                        _ = sema.wait(timeout: .now() + 2.5)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            controller.engine.refreshDiagnostics()
                            let pausedDiag = controller.engine.diagnostics
                            let pausedCPU = pausedDiag.cpuUsagePercent

                            let entry: [String: Any] = [
                                "file": d.fileName,
                                "fileSizeMB": round(d.fileSizeMB * 10) / 10,
                                "container": d.containerFormat,
                                "codec": d.codecName,
                                "codecDescription": d.codecDescription,
                                "pixelFormat": d.pixelFormat,
                                "hwFormat": d.hwFormat,
                                "hwdecCurrent": d.hwdecCurrent,
                                "isHardwareAccelerated": d.isHardwareAccelerated,
                                "isFastPreviewMode": d.isFastPreviewMode,
                                "decodePath": d.decodePathSummary,
                                "activeGPU": d.activeGPU,
                                "codedResolution": "\(d.rawWidth)×\(d.rawHeight)",
                                "rotationDegrees": d.rotationDegrees,
                                "displayResolution": "\(d.width)×\(d.height)",
                                "videoAspectRatio": round(vidAspect * 1000) / 1000,
                                "windowSize": "\(Int(winFrame.width))×\(Int(winFrame.height))",
                                "windowAspectRatio": round(Double(winAspect) * 1000) / 1000,
                                "videoBitrateMbps": round(d.videoBitrateMbps * 10) / 10,
                                "nominalFPS": round(d.nominalFPS * 100) / 100,
                                "effectiveFPS": round((steadyFPS > 0 ? steadyFPS : d.estimatedFPS) * 100) / 100,
                                "droppedFrames": steadyDrops,
                                "decoderDroppedFrames": steadyDecDrops,
                                "avSyncDiffMs": round(d.avSyncDiffMs * 100) / 100,
                                "coldStartWindowMs": round(coldStartWindowMs * 100) / 100,
                                "coldLaunchFirstFrameMs": round(coldLaunchFirstFrameMs * 100) / 100,
                                "engineInitLatencyMs": round(d.engineInitLatencyMs * 100) / 100,
                                "firstFrameLatencyMs": round(d.firstFrameLatencyMs * 100) / 100,
                                "seekKeyframeLatencyMs": round(keyframeSeekMs * 100) / 100,
                                "seekExactLatencyMs": round(d.lastSeekLatencyMs * 100) / 100,
                                "thumbnailLatencyMs": round(thumbMs * 100) / 100,
                                "cpuUsagePercent": round((steadyCPU > 0 ? steadyCPU : d.cpuUsagePercent) * 10) / 10,
                                "pausedCpuPercent": round(pausedCPU * 10) / 10,
                                "residentMemoryMB": round(d.residentMemoryMB * 10) / 10,
                                "peakMemoryMB": round(d.peakMemoryMB * 10) / 10
                            ]
                            results.append(entry)
                            runNext(index: index + 1)
                        }
                    }
                }
            }
        }

        runNext(index: 0)
    }

    // MARK: - Main Menu Construction

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About UPreviewX", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide UPreviewX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit UPreviewX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let saveFrameItem = NSMenuItem(title: "Save Current Frame", action: #selector(saveCurrentFrame(_:)), keyEquivalent: "s")
        saveFrameItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveFrameItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Playback Menu
        let playbackMenuItem = NSMenuItem()
        mainMenu.addItem(playbackMenuItem)
        let playbackMenu = NSMenu(title: "Playback")
        let playPauseItem = NSMenuItem(title: "Play / Pause", action: #selector(togglePlayPause(_:)), keyEquivalent: " ")
        playPauseItem.keyEquivalentModifierMask = []
        playbackMenu.addItem(playPauseItem)
        let speedItem = NSMenuItem(title: "Toggle 1× / 2× Playback", action: #selector(toggleSpeed(_:)), keyEquivalent: "")
        playbackMenu.addItem(speedItem)
        playbackMenu.addItem(withTitle: "Fast-Forward 5s", action: #selector(fastForward(_:)), keyEquivalent: "")
        playbackMenu.addItem(withTitle: "Rewind 5s", action: #selector(rewind(_:)), keyEquivalent: "")
        playbackMenuItem.submenu = playbackMenu

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(toggleFullscreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(withTitle: "Toggle Decoder Diagnostics", action: #selector(toggleDiagnostics(_:)), keyEquivalent: "i")
        let fastPreviewItem = NSMenuItem(title: "Toggle Fast Preview Mode (Software 4K)", action: #selector(toggleFastPreview(_:)), keyEquivalent: "p")
        fastPreviewItem.keyEquivalentModifierMask = []
        viewMenu.addItem(fastPreviewItem)
        viewMenuItem.submenu = viewMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
