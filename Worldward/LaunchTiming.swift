/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// DEBUG-only launch instrumentation: prints how many milliseconds after the
/// first mark each launch phase completes, so cold-start regressions can be
/// attributed to a phase (store setup, geometry build, seeding, MapKit init)
/// instead of guessed at. Compiled out of release builds entirely.
///
/// The zero point is the first `mark` call — place one as early as possible
/// (the `App` initializer), then read the console:
///     [launch]       0 ms  app init
///     [launch]     142 ms  model container ready
///     ...
enum LaunchClock {
    #if DEBUG
        nonisolated private static let start = ContinuousClock.now
    #endif

    @inline(__always)
    nonisolated static func mark(_ label: @autoclosure () -> String) {
        #if DEBUG
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            // stderr, not print: stdout is fully buffered when redirected to a
            // file, so timings would vanish if the process is killed.
            FileHandle.standardError.write(
                Data(String(format: "[launch] %7.0f ms  %@\n", ms, label()).utf8))
        #endif
    }
}
