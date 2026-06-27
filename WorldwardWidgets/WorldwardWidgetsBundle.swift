import SwiftUI
import WidgetKit

/// The widgets Worldward offers in the gallery. All read the same shared snapshot
/// the app maintains via the App Group.
@main
struct WorldwardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TravelSnapshotWidget()
        FlagStripWidget()
        MiniMapWidget()
        // Lock Screen accessories are iOS-only (see WorldwardWidgets.swift).
        #if os(iOS)
            AccessoryWidget()
        #endif
    }
}
