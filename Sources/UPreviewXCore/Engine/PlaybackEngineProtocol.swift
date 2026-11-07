import Foundation
import CoreGraphics

/// Errors emitted by the playback engine.
public enum PlaybackEngineError: Error, LocalizedError, Equatable {
    case initializationFailed(String)
    case fileNotFound(URL)
    case loadFailed(String)
    case renderContextFailed(String)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg):
            return "Failed to initialize playback engine: \(msg)"
        case .fileNotFound(let url):
            return "The file \"\(url.lastPathComponent)\" could not be found."
        case .loadFailed(let msg):
            return "Unable to play media file: \(msg)"
        case .renderContextFailed(let msg):
            return "Failed to initialize video renderer: \(msg)"
        }
    }
}

/// Delegate callbacks emitted by a `PlaybackEngineProtocol` instance on the main thread.
public protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngineDidLoadFile(_ engine: PlaybackEngineProtocol)
    func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePosition position: Double, duration: Double)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePause isPaused: Bool)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVolume volume: Double, isMuted: Bool)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVideoSize size: CGSize)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didCompleteSeek latencyMs: Double)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateDiagnostics diagnostics: PlaybackDiagnostics)
    func playbackEngine(_ engine: PlaybackEngineProtocol, didEncounterError error: PlaybackEngineError)
    func playbackEngineDidReachEndOfFile(_ engine: PlaybackEngineProtocol)
}

/// Isolated playback engine interface decoupled from AppKit window management and conversion services.
public protocol PlaybackEngineProtocol: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }
    var currentURL: URL? { get }
    var isPaused: Bool { get }
    var position: Double { get }
    var duration: Double { get }
    var volume: Double { get }
    var isMuted: Bool { get }
    var videoSize: CGSize { get }
    var isFastPreviewMode: Bool { get }
    var diagnostics: PlaybackDiagnostics { get }

    func initialize() throws
    func load(url: URL) throws
    func play()
    func pause()
    func togglePlayPause()
    func seek(to seconds: Double, exact: Bool)
    func seekRelative(_ deltaSeconds: Double, exact: Bool)
    func setVolume(_ volume: Double)
    func toggleMute()
    func setFastPreviewMode(_ enabled: Bool)
    func toggleFastPreviewMode()
    func refreshDiagnostics()
    func shutdown()
}
