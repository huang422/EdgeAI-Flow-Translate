import Foundation

/// The two input level meters, published separately from `CaptureViewModel`.
///
/// Split out for one reason: they change 12 times a second per source, and
/// SwiftUI invalidates every view observing an `ObservableObject` when any of its
/// `@Published` values changes. With the levels on the view model, a running
/// meeting rebuilt the main window *and the Settings window* about 24 times a
/// second — for two 40-point bars.
@MainActor
final class LevelMeters: ObservableObject {
    @Published var mic: Float = 0
    @Published var system: Float = 0
}
