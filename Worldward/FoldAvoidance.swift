/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Fold avoidance (iPhone Duo)

extension View {
    /// Keeps this view's *content* (centred controls, the map camera's framing)
    /// clear of an active vertical fold, such as the iPhone Duo held half-open
    /// like a book: while the fold is active, the leading side up to and
    /// including the fold becomes safe-area padding, so centred content
    /// re-centres in the trailing half. The view's own frame (and any
    /// full-bleed background, like the map tiles) is untouched.
    ///
    /// A no-op everywhere else: flat or folded, no hinge, earlier systems,
    /// and macOS. A horizontal fold (tabletop) needs nothing — the map's
    /// controls already sit at the top and bottom edges, away from it.
    func avoidingActiveFold() -> some View {
        #if os(iOS)
            modifier(FoldAvoidance())
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct FoldAvoidance: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 27.1, *) {
                content.modifier(ActiveFoldPadding())
            } else {
                content
            }
        }
    }

    @available(iOS 27.1, *)
    private struct ActiveFoldPadding: ViewModifier {
        /// Leading inset that clears the fold, or 0 when no vertical fold is
        /// active. Measured from the leading edge (`reservedRegions` mirrors
        /// for right-to-left by default), so the trailing half wins in both.
        @State private var leadingInset: CGFloat = 0

        func body(content: Content) -> some View {
            content
                .safeAreaPadding(.leading, leadingInset)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    Self.inset(for: proxy)
                } action: { inset in
                    leadingInset = inset
                }
        }

        /// The inset for the first active, vertical (taller-than-wide)
        /// division inside the view — only active regions displace content.
        nonisolated private static func inset(for proxy: GeometryProxy) -> CGFloat {
            let fold = proxy.reservedRegions(kind: .division)
                .first { $0.isActive && $0.frame.height > $0.frame.width }
            guard let fold, fold.frame.maxX > 0, fold.frame.maxX < proxy.size.width else { return 0 }
            return fold.frame.maxX
        }
    }
#endif
