/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        UpcomingTripWidget()
        PackingListWidget()
        // Lock Screen accessories and the Control Center control are iOS-only
        // (see WorldwardWidgets.swift).
        #if os(iOS)
            AccessoryWidget()
            NextTripAccessoryWidget()
            MarkHereControl()
        #endif
    }
}
