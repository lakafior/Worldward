/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

#if os(macOS)

/// About panel shown in a standalone window triggered from the app menu.
struct AboutView: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // App icon and name
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.top, 24)

            Text("Worldward")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 12)

            Text(versionString)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Info rows
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("License", value: "MPL 2.0")
                LabeledContent("Author", value: "Smigi")
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            // Links
            VStack(spacing: 8) {
                Link(destination: URL(string: "https://worldward.smigi.net")!) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: URL(string: "https://worldward.smigi.net/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://github.com/lakafior/Worldward")!) {
                    Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .buttonStyle(.link)
            .padding(.top, 16)

            Spacer()
        }
        .frame(width: 320, height: 380)
    }
}

#Preview {
    AboutView()
}

#endif
