import Foundation

/// Hardware acceleration preferences for media decoding.
public enum HardwareAccelerationMode: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case disabled = "disabled"

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto (VideoToolbox with Software Fallback)"
        case .disabled:
            return "Disabled (Software Decoding Only)"
        }
    }
}

/// Seeking precision behavior during scrub and fast seeking.
public enum FastSeekingMode: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case keyframesOnly = "keyframes"
    case exact = "exact"

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto (Smart Seeking)"
        case .keyframesOnly:
            return "Fast Keyframes Only"
        case .exact:
            return "Accurate Frame Exact"
        }
    }
}

/// Naming pattern for captured video frames.
public enum CaptureFilenamePattern: String, Codable, CaseIterable, Sendable {
    case sourceAndTimestamp = "sourceAndTimestamp"
    case timestampOnly = "timestampOnly"

    public var displayName: String {
        switch self {
        case .sourceAndTimestamp:
            return "Source name and timestamp (e.g. video_frame_01-23.png)"
        case .timestampOnly:
            return "Timestamp only (e.g. frame_2026-11-09_01-23.png)"
        }
    }
}

public extension Notification.Name {
    static let userSettingsDidChange = Notification.Name("com.upreviewx.userSettingsDidChange")
}

/// Centralized, typed user preferences persisted in `UserDefaults`.
public final class UserSettings {
    public static let shared = UserSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private enum Key {
        static let quitWhenLastWindowCloses = "quitWhenLastWindowCloses"
        static let fitWindowToAspectRatio = "fitWindowToAspectRatio"
        static let rememberLastWindowSize = "rememberLastWindowSize"
        static let lastWindowWidth = "lastWindowWidth"
        static let lastWindowHeight = "lastWindowHeight"

        static let hardwareAcceleration = "hardwareAcceleration"
        static let temporaryFastSpeed = "temporaryFastSpeed"
        static let fastSeekingBehavior = "fastSeekingBehavior"
        static let fastPreviewModeByDefault = "fastPreviewModeByDefault"
        static let autoResumePlaybackOnOpen = "autoResumePlaybackOnOpen"

        static let captureOutputDirectoryPath = "captureOutputDirectoryPath"
        static let captureImageFormat = "captureImageFormat"
        static let captureFilenamePattern = "captureFilenamePattern"
        static let showCaptureConfirmation = "showCaptureConfirmation"
    }

    private func registerDefaults() {
        let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let defaultCaptureDir = picturesURL?.appendingPathComponent("UPreviewX").path ?? "~/Pictures/UPreviewX"

        defaults.register(defaults: [
            Key.quitWhenLastWindowCloses: true,
            Key.fitWindowToAspectRatio: true,
            Key.rememberLastWindowSize: false,
            Key.lastWindowWidth: 960.0,
            Key.lastWindowHeight: 540.0,

            Key.hardwareAcceleration: HardwareAccelerationMode.auto.rawValue,
            Key.temporaryFastSpeed: 2.0,
            Key.fastSeekingBehavior: FastSeekingMode.auto.rawValue,
            Key.fastPreviewModeByDefault: false,
            Key.autoResumePlaybackOnOpen: true,

            Key.captureOutputDirectoryPath: defaultCaptureDir,
            Key.captureImageFormat: "PNG",
            Key.captureFilenamePattern: CaptureFilenamePattern.sourceAndTimestamp.rawValue,
            Key.showCaptureConfirmation: true
        ])
    }

    // MARK: - General Settings

    public var quitWhenLastWindowCloses: Bool {
        get { defaults.bool(forKey: Key.quitWhenLastWindowCloses) }
        set {
            defaults.set(newValue, forKey: Key.quitWhenLastWindowCloses)
            notifyChanged()
        }
    }

    public var fitWindowToAspectRatio: Bool {
        get { defaults.bool(forKey: Key.fitWindowToAspectRatio) }
        set {
            defaults.set(newValue, forKey: Key.fitWindowToAspectRatio)
            notifyChanged()
        }
    }

    public var rememberLastWindowSize: Bool {
        get { defaults.bool(forKey: Key.rememberLastWindowSize) }
        set {
            defaults.set(newValue, forKey: Key.rememberLastWindowSize)
            notifyChanged()
        }
    }

    public var lastWindowSize: CGSize {
        get {
            let w = defaults.double(forKey: Key.lastWindowWidth)
            let h = defaults.double(forKey: Key.lastWindowHeight)
            return CGSize(width: w > 0 ? w : 960, height: h > 0 ? h : 540)
        }
        set {
            defaults.set(newValue.width, forKey: Key.lastWindowWidth)
            defaults.set(newValue.height, forKey: Key.lastWindowHeight)
        }
    }

    // MARK: - Playback Settings

    public var hardwareAcceleration: HardwareAccelerationMode {
        get {
            guard let raw = defaults.string(forKey: Key.hardwareAcceleration),
                  let mode = HardwareAccelerationMode(rawValue: raw) else {
                return .auto
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.hardwareAcceleration)
            notifyChanged()
        }
    }

    public var temporaryFastSpeed: Double {
        get {
            let val = defaults.double(forKey: Key.temporaryFastSpeed)
            return val > 0 ? val : 2.0
        }
        set {
            let clamped = (newValue >= 3.0) ? 4.0 : 2.0
            defaults.set(clamped, forKey: Key.temporaryFastSpeed)
            notifyChanged()
        }
    }

    public var fastSeekingBehavior: FastSeekingMode {
        get {
            guard let raw = defaults.string(forKey: Key.fastSeekingBehavior),
                  let mode = FastSeekingMode(rawValue: raw) else {
                return .auto
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.fastSeekingBehavior)
            notifyChanged()
        }
    }

    public var fastPreviewModeByDefault: Bool {
        get { defaults.bool(forKey: Key.fastPreviewModeByDefault) }
        set {
            defaults.set(newValue, forKey: Key.fastPreviewModeByDefault)
            notifyChanged()
        }
    }

    public var autoResumePlaybackOnOpen: Bool {
        get { defaults.bool(forKey: Key.autoResumePlaybackOnOpen) }
        set {
            defaults.set(newValue, forKey: Key.autoResumePlaybackOnOpen)
            notifyChanged()
        }
    }

    // MARK: - Frame Capture Settings

    public var captureOutputDirectoryURL: URL {
        get {
            if let path = defaults.string(forKey: Key.captureOutputDirectoryPath), !path.isEmpty {
                let expanded = NSString(string: path).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            return picturesURL?.appendingPathComponent("UPreviewX", isDirectory: true)
                ?? URL(fileURLWithPath: NSString(string: "~/Pictures/UPreviewX").expandingTildeInPath, isDirectory: true)
        }
        set {
            defaults.set(newValue.path, forKey: Key.captureOutputDirectoryPath)
            notifyChanged()
        }
    }

    public var captureImageFormat: String {
        get { defaults.string(forKey: Key.captureImageFormat) ?? "PNG" }
        set {
            defaults.set(newValue, forKey: Key.captureImageFormat)
            notifyChanged()
        }
    }

    public var captureFilenamePattern: CaptureFilenamePattern {
        get {
            guard let raw = defaults.string(forKey: Key.captureFilenamePattern),
                  let pat = CaptureFilenamePattern(rawValue: raw) else {
                return .sourceAndTimestamp
            }
            return pat
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.captureFilenamePattern)
            notifyChanged()
        }
    }

    public var showCaptureConfirmation: Bool {
        get { defaults.bool(forKey: Key.showCaptureConfirmation) }
        set {
            defaults.set(newValue, forKey: Key.showCaptureConfirmation)
            notifyChanged()
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .userSettingsDidChange, object: self)
        }
    }
}
