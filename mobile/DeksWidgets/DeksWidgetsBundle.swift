import SwiftUI
import WidgetKit

/// Widget extension entry point. Today only the Capture Live Activity
/// lives here, but the bundle can host home-screen widgets later without
/// adding a second extension target.
@main
struct DeksWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CaptureLiveActivity()
    }
}
