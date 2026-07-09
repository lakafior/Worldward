/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Photos
import SwiftUI

#if canImport(AppKit)
    import AppKit
    typealias PlatformImage = NSImage
#elseif canImport(UIKit)
    import UIKit
    typealias PlatformImage = UIImage
#endif

extension Image {
    /// Build a SwiftUI image from the platform-native image type returned by PhotoKit.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
            self.init(nsImage: platformImage)
        #else
            self.init(uiImage: platformImage)
        #endif
    }
}

/// `PHAsset` carries a stable `localIdentifier`, which makes it a natural
/// `Identifiable` for driving a `.sheet(item:)` full-size viewer.
extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

/// A horizontal strip of photo thumbnails for a visit, loaded from the photo
/// library by their stable identifiers. Tapping a thumbnail opens a full-size
/// viewer in a sheet. Photos that no longer exist are simply skipped.
struct VisitPhotosView: View {
    let identifiers: [String]
    /// When provided, each thumbnail gains a context-menu action to detach the
    /// photo from the visit. The photo itself is never touched — only the stored
    /// identifier is removed. `nil` (the default) keeps the strip read-only, as
    /// the timeline and import preview use it.
    var onRemove: ((String) -> Void)? = nil

    @State private var viewerAsset: PHAsset?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(identifiers, id: \.self) { identifier in
                    PhotoThumbnail(identifier: identifier) { asset in
                        viewerAsset = asset
                    }
                    .contextMenu {
                        if let onRemove {
                            Button(role: .destructive) {
                                onRemove(identifier)
                            } label: {
                                Label("Remove from Visit", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .sheet(item: $viewerAsset) { asset in
            PhotoViewer(asset: asset)
        }
    }
}

/// A single square thumbnail that resolves its asset and image lazily.
private struct PhotoThumbnail: View {
    let identifier: String
    let onTap: (PHAsset) -> Void

    @State private var image: Image?
    @State private var asset: PHAsset?

    private let side: CGFloat = 56

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            if let asset { onTap(asset) }
        }
        .task(id: identifier) {
            await load()
        }
    }

    private func load() async {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetched.firstObject else { return }
        self.asset = asset

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        // 2x the display size for crisp thumbnails on retina displays.
        let target = CGSize(width: side * 2, height: side * 2)
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFill, options: options
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in self.image = Image(platformImage: result) }
        }
    }
}

/// Full-size viewer for a single asset, shown in a sheet.
private struct PhotoViewer: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss

    @State private var image: Image?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            ZStack {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 520, minHeight: 440)
        .task {
            await loadFull()
        }
    }

    private func loadFull() async {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: asset, targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit, options: options
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in self.image = Image(platformImage: result) }
        }
    }
}
