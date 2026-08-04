/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - App navigation
//
/// Where the app can be: the two country-list modes, the iOS tab identities,
/// and (on macOS) the in-window destinations the menu bar commands drive.
/// Plain top-level enums — they were already internal, so living in their own
/// file costs nothing.

/// Whether the country list is showing where you've **been** or where you're
/// **going** (your wishlist/planning). Drives the segmented control and which
/// countries the list shows when not searching.
enum BrowseMode: String, CaseIterable, Identifiable {
    case been = "Been"
    case going = "Going"
    var id: String { rawValue }
}

/// The app's top-level sections, shown as iOS tabs. macOS has no tab
/// selection: the sidebar holds the lists and the map owns the detail column.
enum AppTab: Hashable {
    case map, been, going
}

#if os(macOS)
    /// The in-window destinations that push over the map on macOS, replacing
    /// the old auxiliary windows so everything lives in the main window.
    enum MacDestination: Hashable {
        /// Statistics + achievements dashboard (see `TravelsDashboardView`).
        case travels
        /// On-device travel Q&A.
        case chat
    }

    /// Lets the macOS menu bar commands (see `WorldwardCommands`) drive the main
    /// window's navigation stack without a shared model.
    extension FocusedValues {
        @Entry var macDestinations: Binding<[MacDestination]>?
        /// Lets the "View ▸ Filter" menu commands (see `MapFilterCommands`) read
        /// and change the map filter of whichever main window is key.
        @Entry var mapFilter: Binding<MapFilter>?
    }
#endif
