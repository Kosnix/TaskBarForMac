import AppKit
import SwiftUI

private struct BarIDKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// Which taskbar (one per screen) a view lives in — keys the frame
    /// dictionaries on `WindowManager` so two bars showing the same app
    /// don't overwrite each other's icon positions.
    var barID: String {
        get { self[BarIDKey.self] }
        set { self[BarIDKey.self] = newValue }
    }
}

enum BarFrames {
    static func key(_ barID: String, _ id: String) -> String { "\(barID)|\(id)" }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
