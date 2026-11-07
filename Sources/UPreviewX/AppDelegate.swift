import AppKit
import UniformTypeIdentifiers
import UPreviewXCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [PlayerWindowController] = []
    private var didOpenInitialFile = false
    private var showDiagnosticsByDefault = false
    private var benchmarkTargets: [URL] = []
    private var isBenchmarkMode = false
    public let appLaunchTimestamp = CFAbsoluteTimeGetCurrent()

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
        didOpenInitialFile = true
        for url in urls where url.isFileURL {
            openVideoWindow(for: url)
        }
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        didOpenInitialFile = true
        let url = URL(fileURLWithPath: filename)
        openVideoWindow(for: url)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
            newController.onWindowWillClose = { [weak self] closed in
                self?.windowControllers.removeAll { $0 === closed }
                if self?.windowControllers.isEmpty == true {
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

    @objc public func toggleDiagnostics(_ sender: Any?) {
        windowControllers.first?.toggleDiagnosticsOverlay()
    }

    @objc public func toggleFullscreen(_ sender: Any?) {
        windowControllers.first?.toggleFullscreen()
    }

    @objc public func togglePlayPause(_ sender: Any?) {
        windowControllers.first?.engine.togglePlayPause()
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
            } else if arg == "--benchmark" && idx + 1 < args.count {
                isBenchmarkMode = true
                showDiagnosticsByDefault = true
                benchmarkTargets.append(URL(fileURLWithPath: args[idx + 1]))
                idx += 1
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
        windowControllers.append(controller)
        let coldStartMs = (CFAbsoluteTimeGetCurrent() - appLaunchTimestamp) * 1000.0
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
            controller.openMedia(url: url)

            // Wait 1.2s of real playback, then trigger an exact seek to 2.5s, then sample diagnostics at 2.2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                controller.engine.seek(to: 2.5, exact: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    controller.engine.refreshDiagnostics()
                    let d = controller.engine.diagnostics
                    let entry: [String: Any] = [
                        "file": d.fileName,
                        "container": d.containerFormat,
                        "codec": d.codecName,
                        "codecDescription": d.codecDescription,
                        "pixelFormat": d.pixelFormat,
                        "hwFormat": d.hwFormat,
                        "hwdecCurrent": d.hwdecCurrent,
                        "isHardwareAccelerated": d.isHardwareAccelerated,
                        "decodePath": d.decodePathSummary,
                        "activeGPU": d.activeGPU,
                        "resolution": d.resolutionSummary,
                        "nominalFPS": round(d.nominalFPS * 100) / 100,
                        "estimatedFPS": round(d.estimatedFPS * 100) / 100,
                        "droppedFrames": d.droppedFrames,
                        "decoderDroppedFrames": d.decoderDroppedFrames,
                        "avSyncDiffMs": round(d.avSyncDiffMs * 100) / 100,
                        "coldStartWindowMs": round(coldStartMs * 100) / 100,
                        "engineInitLatencyMs": round(d.engineInitLatencyMs * 100) / 100,
                        "firstFrameLatencyMs": round(d.firstFrameLatencyMs * 100) / 100,
                        "seekLatencyMs": round(d.lastSeekLatencyMs * 100) / 100,
                        "cpuUsagePercent": round(d.cpuUsagePercent * 10) / 10,
                        "residentMemoryMB": round(d.residentMemoryMB * 10) / 10
                    ]
                    results.append(entry)
                    runNext(index: index + 1)
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
        appMenu.addItem(withTitle: "Hide UPreviewX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit UPreviewX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
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
        playbackMenuItem.submenu = playbackMenu

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(toggleFullscreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(withTitle: "Toggle Decoder Diagnostics", action: #selector(toggleDiagnostics(_:)), keyEquivalent: "i")
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
