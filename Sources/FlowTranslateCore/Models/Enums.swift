import Foundation

/// Audio source type. Distinguishes system audio from the microphone (FR-003).
public enum AudioSourceType: String, Codable, Sendable, CaseIterable {
    case system
    case microphone
}

/// Transcript export format.
public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case markdown
    case plainText
    case srt
    case vtt
    case json
}
