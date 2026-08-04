/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// Manages the shared catalog of packing containers (bags/cases): rename them
/// inline, reorder by dragging, delete (which leaves the items behind, just
/// ungrouped), pick an icon, and add new ones. Containers are global, so changes
/// here apply to every trip.
struct ManageContainersView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PackingContainer.sortOrder) private var containers: [PackingContainer]

    @State private var newName = ""
    /// The container whose icon is being chosen, driving the icon-picker sheet.
    @State private var iconEditing: PackingContainer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(containers) { container in
                        ContainerEditRow(container: container) { iconEditing = container }
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                } footer: {
                    Text(
                        "Containers are shared across all your trips. Deleting one keeps its "
                            + "items — they just become ungrouped.")
                }

                Section("Add a container") {
                    HStack {
                        TextField("Name", text: $newName)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Containers")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $iconEditing) { container in
                ContainerIconPicker(container: container)
            }
        }
        // A `List` has no intrinsic height, so a Mac sheet built around one
        // collapses to nothing — the containers were there, the rows just had
        // no room to lay out, and the sheet read as an empty list.
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let order = (containers.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(PackingContainer(name: name, sortOrder: order))
        newName = ""
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(containers[index]) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = containers
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, container) in ordered.enumerated() { container.sortOrder = index }
    }
}

/// A single editable container row: a tappable icon and an inline-editable name.
private struct ContainerEditRow: View {
    @Bindable var container: PackingContainer
    let onEditIcon: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEditIcon) {
                Image(systemName: container.symbolName)
                    .font(.body)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.tint)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            TextField("Name", text: $container.name)
        }
    }
}

/// A grid of travel-themed SF Symbols for choosing a container's icon.
private struct ContainerIconPicker: View {
    @Bindable var container: PackingContainer
    @Environment(\.dismiss) private var dismiss

    /// Curated, widely-available SF Symbols that read as bags, cases or kit.
    private static let symbols = [
        "suitcase.fill", "suitcase.rolling.fill", "backpack.fill", "handbag.fill",
        "briefcase.fill", "bag.fill", "case.fill", "cross.case.fill",
        "shippingbox.fill", "basket.fill", "tray.fill", "tshirt.fill",
        "camera.fill", "shoeprints.fill", "comb.fill", "powerplug.fill",
    ]

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            container.symbolName = symbol
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.title2)
                                .frame(width: 60, height: 60)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            container.symbolName == symbol
                                                ? AnyShapeStyle(.tint.opacity(0.2))
                                                : AnyShapeStyle(.gray.opacity(0.12)))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            container.symbolName == symbol
                                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                            lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        // The SF Symbol's own localized description names each
                        // icon; the trait marks the current choice, otherwise
                        // shown by ring color alone.
                        .accessibilityAddTraits(
                            container.symbolName == symbol ? .isSelected : [])
                    }
                }
                .padding()
            }
            .navigationTitle("Choose Icon")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // Same reason as the containers sheet: a `ScrollView` around a lazy grid
        // has no height of its own for a Mac sheet to size itself to.
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 380)
        #endif
    }
}
