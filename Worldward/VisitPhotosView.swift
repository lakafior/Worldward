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
///
/// The identifiers are resolved to assets in a single library fetch per strip
/// (not one per thumbnail), and the shared thumbnail cache is warmed for the
/// whole strip so scrolling back and forth reuses decoded images.
struct VisitPhotosView: View {
    let identifiers: [String]
    /// When provided, each thumbnail gains a context-menu action to detach the
    /// photo from the visit. The photo itself is never touched — only the stored
    /// identifier is removed. `nil` (the default) keeps the strip read-only, as
    /// the timeline and import preview use it.
    var onRemove: ((String) -> Void)? = nil

    @State private var assets: [PHAsset] = []
    @State private var viewerAsset: PHAsset?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy so a long strip only requests the thumbnails actually on
            // screen; the cache warmed below makes the rest instant anyway.
            LazyHStack(spacing: 6) {
                ForEach(assets) { asset in
                    PhotoThumbnail(asset: asset) { viewerAsset = $0 }
                        .contextMenu {
                            if let onRemove {
                                Button(role: .destructive) {
                                    onRemove(asset.localIdentifier)
                                } label: {
                                    Label("Remove from Visit", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .task(id: identifiers) { resolveAssets() }
        .onDisappear { PhotoThumbnail.stopCaching(assets) }
        .sheet(item: $viewerAsset) { asset in
            PhotoViewer(asset: asset)
        }
    }

    /// Resolves the stored identifiers to assets in one fetch, preserving their
    /// order and skipping photos deleted from the library, then warms the
    /// shared thumbnail cache for the strip.
    private func resolveAssets() {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        assets = identifiers.compactMap { byID[$0] }
        PhotoThumbnail.startCaching(assets)
    }
}

/// A single square thumbnail served by the shared caching manager. In-flight
/// requests are cancelled when the thumbnail scrolls away before they land.
private struct PhotoThumbnail: View {
    let asset: PHAsset
    let onTap: (PHAsset) -> Void

    @State private var image: Image?
    @State private var requestID: PHImageRequestID?

    private static let side: CGFloat = 56
    /// 2x the display size for crisp thumbnails on retina displays.
    private static let targetSize = CGSize(width: side * 2, height: side * 2)

    /// One caching manager + options shared by every strip in the app, so the
    /// timeline, country details, and import preview all draw from (and warm)
    /// the same decoded-thumbnail pool.
    private static let manager = PHCachingImageManager()
    private static let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return options
    }()

    /// Pre-decodes thumbnails for a strip's assets (parameters must mirror the
    /// per-thumbnail request for the cache to be hit).
    static func startCaching(_ assets: [PHAsset]) {
        manager.startCachingImages(
            for: assets, targetSize: targetSize, contentMode: .aspectFill, options: options)
    }

    /// Releases a strip's cached thumbnails once it leaves the screen.
    static func stopCaching(_ assets: [PHAsset]) {
        manager.stopCachingImages(
            for: assets, targetSize: targetSize, contentMode: .aspectFill, options: options)
    }

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
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { onTap(asset) }
        .accessibilityLabel(Text("Photo"))
        .accessibilityAddTraits(.isButton)
        .onAppear { load() }
        .onDisappear { cancelRequest() }
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        requestID = Self.manager.requestImage(
            for: asset, targetSize: Self.targetSize, contentMode: .aspectFill,
            options: Self.options
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in self.image = Image(platformImage: result) }
        }
    }

    private func cancelRequest() {
        if let requestID { Self.manager.cancelImageRequest(requestID) }
        requestID = nil
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
                .accessibilityLabel(Text("Close"))
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
