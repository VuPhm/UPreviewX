import Foundation

/// Supported target codecs reserved for future video conversion functionality.
public enum TargetVideoCodec: String, Codable, CaseIterable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"
    case prores422 = "prores_422"
}

/// Immutable specification for a future media conversion job.
public struct ConversionJobRequest: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let targetCodec: TargetVideoCodec
    public let preferHardwareEncoding: Bool

    public init(
        sourceURL: URL,
        destinationURL: URL,
        targetCodec: TargetVideoCodec,
        preferHardwareEncoding: Bool = true
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.targetCodec = targetCodec
        self.preferHardwareEncoding = preferHardwareEncoding
    }
}

/// Progress snapshot for a future conversion operation.
public struct ConversionProgress: Codable, Equatable, Sendable {
    public let fractionCompleted: Double
    public let encodedFrames: Int64
    public let speedMultiplier: Double

    public init(fractionCompleted: Double, encodedFrames: Int64, speedMultiplier: Double) {
        self.fractionCompleted = fractionCompleted
        self.encodedFrames = encodedFrames
        self.speedMultiplier = speedMultiplier
    }
}

/// Errors reported by a `ConversionServiceProtocol` implementation.
public enum ConversionServiceError: Error, LocalizedError, Equatable, Sendable {
    case notImplementedInMVP
    case unsupportedInput(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notImplementedInMVP:
            return "Video conversion is reserved for a future release and is not enabled in the MVP."
        case .unsupportedInput(let reason):
            return "Unsupported input media: \(reason)"
        case .cancelled:
            return "Conversion was cancelled."
        }
    }
}

/// Independent conversion service interface reserved for future expansion.
/// Kept strictly decoupled from `PlaybackEngineProtocol` and AppKit UI components.
public protocol ConversionServiceProtocol: AnyObject {
    var isAvailable: Bool { get }
    func startConversion(
        request: ConversionJobRequest,
        onProgress: @escaping (ConversionProgress) -> Void,
        completion: @escaping (Result<URL, ConversionServiceError>) -> Void
    )
    func cancelActiveConversion()
}

/// Placeholder no-op implementation used in MVP builds.
public final class ReservedConversionService: ConversionServiceProtocol {
    public init() {}

    public var isAvailable: Bool { false }

    public func startConversion(
        request: ConversionJobRequest,
        onProgress: @escaping (ConversionProgress) -> Void,
        completion: @escaping (Result<URL, ConversionServiceError>) -> Void
    ) {
        completion(.failure(.notImplementedInMVP))
    }

    public func cancelActiveConversion() {}
}

