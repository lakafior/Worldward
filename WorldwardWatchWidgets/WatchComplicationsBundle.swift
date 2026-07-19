/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import WidgetKit

/// The complications Worldward offers on the watch face. All read the same
/// compact snapshot the watch app maintains through the App Group.
@main
struct WatchComplicationsBundle: WidgetBundle {
    var body: some Widget {
        CountriesComplication()
        NextTripComplication()
        PackingComplication()
    }
}
