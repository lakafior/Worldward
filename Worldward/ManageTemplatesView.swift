/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// Manages the shared catalog of saved packing templates: rename a template
/// inline, delete one (swipe), and drill in to edit its items. Templates are
/// global — saved from any trip's packing list and appliable to any other trip
/// via its "Start from…" menu.
struct ManageTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PackingTemplate.name) private var templates: [PackingTemplate]

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No templates yet",
                        systemImage: "list.bullet.rectangle.portrait",
                        description: Text(
                            "Save a trip's packing list as a template to reuse it on future trips.")
                    )
                } else {
                    Section {
                        ForEach(templates) { template in
                            NavigationLink {
                                TemplateDetailView(template: template)
                            } label: {
                                TemplateRow(template: template)
                            }
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        Text("Templates are shared across all your trips.")
                    }
                }
            }
            .navigationTitle("Templates")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(templates[index]) }
    }
}

/// A summary row for one template: its name and item count.
private struct TemplateRow: View {
    let template: PackingTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(template.name.isEmpty ? "Untitled" : template.name)
                .font(.headline)
            Text("^[\(template.items.count) item](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Edits a single template: rename it and add, remove, or tweak its items
/// (title, quantity, and which container they belong in).
private struct TemplateDetailView: View {
    @Bindable var template: PackingTemplate
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PackingContainer.sortOrder) private var containers: [PackingContainer]
    @State private var newItemTitle = ""

    private var orderedItems: [PackingTemplateItem] {
        template.items.sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section("Name") {
                TextField("Template name", text: $template.name)
            }

            Section("Items") {
                if template.items.isEmpty {
                    Text("No items").foregroundStyle(.secondary)
                } else {
                    ForEach(orderedItems) { item in
                        TemplateItemRow(item: item, containerNames: containers.map(\.name))
                    }
                    .onDelete(perform: deleteItems)
                }

                HStack {
                    TextField("Add item", text: $newItemTitle)
                        .onSubmit(addItem)
                    Button("Add", action: addItem)
                        .disabled(newItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle(template.name.isEmpty ? "Template" : template.name)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let order = (template.items.map(\.order).max() ?? -1) + 1
        let item = PackingTemplateItem(title: title, order: order, template: template)
        modelContext.insert(item)
        template.items.append(item)
        newItemTitle = ""
    }

    private func deleteItems(at offsets: IndexSet) {
        let ordered = orderedItems
        for index in offsets { modelContext.delete(ordered[index]) }
    }
}

/// A single editable template item: an inline title, a quantity stepper, and a
/// menu to file it into a container by name (matching the trip packing row).
private struct TemplateItemRow: View {
    @Bindable var item: PackingTemplateItem
    let containerNames: [String]

    var body: some View {
        HStack {
            TextField("Item", text: $item.title)

            if item.quantity > 1 {
                Text("×\(item.quantity)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Stepper("Quantity", value: $item.quantity, in: 1...99)
                .labelsHidden()

            Menu {
                Picker("Container", selection: $item.containerName) {
                    Text("Ungrouped").tag("")
                    ForEach(containerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } label: {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}
