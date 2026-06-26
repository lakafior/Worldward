import SwiftUI
import WidgetKit

/// The widgets Worldward offers in the gallery. Both read the same shared
/// snapshot the app maintains via the App Group.
@main
struct WorldwardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TravelSnapshotWidget()
        FlagStripWidget()
    }
}
