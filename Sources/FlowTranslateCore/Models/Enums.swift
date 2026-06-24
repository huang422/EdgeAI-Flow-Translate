import Foundation

/// Audio source type. Distinguishes system audio from the microphone (FR-003).
public enum AudioSourceType: String, Codable, Sendable, CaseIterable {
    case system
    case microphone
}

/// Caption position on screen.
public enum CaptionPosition: Codable, Sendable, Equatable {
    case top
    case center
    case bottom
    case custom(x: Double, y: Double)
}

/// Transcript export format.
public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case markdown
    case plainText
    case srt
    case vtt
    case json
}
