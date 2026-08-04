/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import QuickLook
#endif

// MARK: - Trip editor rows
//
// The leaf views the trip editor composes: one row per itinerary stop, packing
// item, attachment, link and contact, plus the packing options menu and the
// notes preview. Each takes its data through an explicit initializer and owns
// no part of `TripDetailView`'s state, so moving them out of `TripViews.swift`
// costs nothing but the `private` on their own type names.

/// The packing header's overflow menu — "Start from…", "Save as template…" and
/// "Clear list" — extracted from `TripDetailView` so the queries backing it stay
/// out of the editor's body.
///
/// Working out whether another trip could seed this one means reading every
/// trip's `packing` relationship. Done in `TripDetailView` that registered
/// Observation on every trip's items, so ticking a box in *any* trip (widget,
/// watch, Reminders sync) invalidated the open editor, and every editor render —
/// each keystroke in the add-item field included — re-walked the whole store.
/// Here the walk is confined to a menu button, and `Equatable` keeps it from
/// re-running when the parent redraws for unrelated reasons.
struct PackingOptionsMenu: View, Equatable {
    let trip: Trip
    let applyTemplate: (PackingTemplate) -> Void
    let copyPacking: (Trip) -> Void
    let saveAsTemplate: () -> Void
    let clearList: () -> Void

    /// Saved packing templates, offered in the "Start from…" menu.
    @Query(sort: \PackingTemplate.name) private var templates: [PackingTemplate]
    /// Every trip, so the "Start from…" menu can copy another trip's packing list.
    @Query private var allTrips: [Trip]

    /// The callbacks are excluded deliberately: they reach `TripDetailView`'s
    /// `@State` through its live storage, so an older copy still writes the
    /// current value. Template and trip edits arrive through Observation on the
    /// queries above, which re-runs `body` whatever this returns.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trip === rhs.trip
    }

    /// Other trips whose packing lists could seed this one.
    private var otherPackedTrips: [Trip] {
        allTrips.filter {
            $0.persistentModelID != trip.persistentModelID && !($0.packing ?? []).isEmpty
        }
    }

    /// Whether the menu has anything to offer — otherwise it's hidden rather
    /// than opening onto nothing.
    private var hasPackingOptions: Bool {
        !(trip.packing ?? []).isEmpty || !templates.isEmpty || !otherPackedTrips.isEmpty
    }

    var body: some View {
        if hasPackingOptions {
            Menu {
                startFromMenu
                if !(trip.packing ?? []).isEmpty {
                    Button {
                        saveAsTemplate()
                    } label: {
                        // Was `square.and.arrow.down` — the *download* glyph,
                        // and the mirror image of the Share icon, so the two
                        // opposite actions read as a matched pair. Saving a
                        // reusable list is a stack-of-lists action.
                        Label("Save as template…", systemImage: "rectangle.stack.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        clearList()
                    } label: {
                        Label("Clear list", systemImage: "trash")
                    }
                }
            } label: {
                Label("Packing options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .textCase(nil)
        }
    }

    /// "Start from…" — applies a saved template or copies another trip's packing
    /// list. Hidden entirely when there's nothing to start from.
    @ViewBuilder private var startFromMenu: some View {
        if !templates.isEmpty || !otherPackedTrips.isEmpty {
            Menu {
                if !templates.isEmpty {
                    Section("Templates") {
                        ForEach(templates) { template in
                            Button(template.name.isEmpty ? "Untitled" : template.name) {
                                applyTemplate(template)
                            }
                        }
                    }
                }
                if !otherPackedTrips.isEmpty {
                    Section("Copy from trip") {
                        ForEach(otherPackedTrips) { other in
                            Button(other.title.isEmpty ? "Untitled Trip" : other.title) {
                                copyPacking(other)
                            }
                        }
                    }
                }
            } label: {
                // Three unrelated meanings used to share the tray metaphor: this
                // menu, the "Other" group's icon, and the move-to-container
                // button. The tray now belongs to containers alone; starting from
                // a saved list is a stack-of-lists action, matching "Save as
                // template…" below.
                Label("Start from…", systemImage: "rectangle.stack")
            }
        }
    }
}

/// One attachment row: a type icon, the original filename, and the stored size.
/// The whole row opens the file — Quick Look on iOS, the default app on macOS.
struct AttachmentRow: View {
    let attachment: TripAttachment
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Int64(attachment.byteCount), format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbolName: String {
        switch (attachment.filename as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff": "photo"
        case "pkpass": "wallet.pass"
        default: "doc"
        }
    }
}

/// Read-only rendering of the minimal Markdown subset trip notes use — the same
/// subset `TripPDFRenderer.notesContent` draws in the PDF export: `#`–`###`
/// headings, a line that's entirely `**bold**` (how `suggestNotes` marks its
/// country headings), `-`/`*` bullets, and inline `**bold**`/`*italic*` spans.
/// Line classification is shared with the PDF renderer so the two never
/// disagree; anything unrecognised stays plain text.
struct TripNotesPreview: View {
    let markdown: String

    private enum Line {
        case heading(String)
        case bullet(String)
        case body(String)
    }

    private var lines: [Line] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let heading = TripPDFRenderer.headingText(trimmed) { return .heading(heading) }
            if let bullet = TripPDFRenderer.bulletText(trimmed) { return .bullet(bullet) }
            return .body(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                switch line {
                case .heading(let text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(inline(text))
                    }
                case .body(let text):
                    Text(inline(text))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Styles inline spans (`**bold**`, `*italic*`, `` `code` ``) within one
    /// line; on a parse error the raw text shows as-is.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Minimum tappable size for the small glyph buttons in the trip rows. 44pt is
/// the iOS HIG floor; macOS drives with a pointer, where 44pt would bloat these
/// already-dense nested rows.
///
/// Shared with the itinerary rows `TripDetailView` still builds inline, so it
/// can't be `private` to this file.
#if os(macOS)
    let minimumHitTarget: CGFloat = 28
#else
    let minimumHitTarget: CGFloat = 44
#endif

/// A packing-list row: a tappable check-off control on the left and a "move to
/// container" menu on the right. Editing `item.container` directly persists the
/// change through SwiftData.
struct PackingItemRow: View {
    @Bindable var item: PackingItem
    let containers: [PackingContainer]
    /// Invoked when the user picks "New container…" so the parent can present the
    /// naming alert with this item queued to be filed into the new container.
    let onNewContainer: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Three controls on one line only works while the title has room to breathe.
    /// At accessibility sizes the stepper and menu grow enough to crush it down to
    /// a couple of characters, so the row stacks instead. Keyed on the type size
    /// rather than `ViewThatFits` so a merely *long* item name doesn't reflow the
    /// layout at normal sizes.
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                checkOffControl
                HStack {
                    quantityStepper
                    Spacer()
                    containerMenu
                }
            }
        } else {
            HStack {
                checkOffControl
                Spacer()
                quantityStepper
                containerMenu
            }
        }
    }

    private var checkOffControl: some View {
        Button {
            item.isPacked.toggle()
            #if canImport(WatchConnectivity)
                PackingDeltaSync.send(dedupID: item.dedupID, isPacked: item.isPacked)
            #endif
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isPacked ? .green : .secondary)
                Text(item.title)
                    .strikethrough(item.isPacked)
                    .foregroundStyle(item.isPacked ? .secondary : .primary)
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reads as a switch: "Sunscreen, on/off" — clearer than a button
        // whose label happens to contain a checkmark image.
        .accessibilityLabel(item.title)
        .accessibilityValue(
            item.isPacked
                ? Text("Packed", comment: "Accessibility value: packing item is checked off")
                : Text("Not packed", comment: "Accessibility value: packing item still open"))
        .accessibilityAddTraits(.isToggle)
        // The tactile heart of the screen — you check these off standing over a
        // suitcase, often without looking at the phone.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: item.isPacked)
    }

    private var quantityStepper: some View {
        Stepper("Quantity", value: $item.quantity, in: 1...99)
            .labelsHidden()
    }

    private var containerMenu: some View {
        Menu {
            Picker("Container", selection: containerSelection) {
                // Named for the group the item visibly lands in, matching the
                // "Add item" row's destination menu and the group header itself.
                Text(Str.Trip.packingOther).tag(nil as PersistentIdentifier?)
                ForEach(containers) { container in
                    Label(container.name, systemImage: container.symbolName)
                        .tag(container.persistentModelID as PersistentIdentifier?)
                }
            }
            Divider()
            Button {
                onNewContainer()
            } label: {
                Label("New container…", systemImage: "plus")
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
                // The glyph alone is ~20pt — well under the touch minimum, and it
                // sits a thumb's width from the stepper.
                .frame(width: minimumHitTarget, height: minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Move to container"))
    }

    private var containerSelection: Binding<PersistentIdentifier?> {
        Binding(
            get: { item.container?.persistentModelID },
            set: { id in item.container = containers.first { $0.persistentModelID == id } })
    }
}

/// One country's stops for the itinerary's By-country view: the flag, the
/// localized name, and the stops filed under it. A grouping for *display* only —
/// the stops remain a flat list; this never becomes a stored container.
struct ItineraryCountryGroup: Identifiable {
    let id: String
    let flag: String
    let name: String
    let stops: [ItineraryItem]

    var headerText: String { "\(flag) \(name)" }
}

/// An inline-editable itinerary stop — the single flat unit the itinerary is now
/// built from. It's either a *place* (a pin picked from search, shown with 📍, an
/// address line and an "Open in Apple Maps" button) or a *country / region*
/// marker (shown with its flag). Either way it carries its own optional date,
/// note, and attached files. Places-to-see are no longer nested inside a stop —
/// they *are* stops, siblings in the same list.
struct StopRow: View {
    @Bindable var stop: ItineraryItem
    /// Whether to show the country as a flag chip on this row. Hidden in the
    /// By-country view, where the section header already names the country.
    let showCountryChip: Bool
    /// Queues a file to attach to *this* stop, then opens the shared importer.
    let onAddAttachment: () -> Void
    /// Opens an attached file (Quick Look on iOS, default app on macOS).
    let onOpenAttachment: (TripAttachment) -> Void
    @Environment(\.modelContext) private var modelContext
    /// Whether the note field is on screen. Every other optional field is driven
    /// by its own content — a date shows because there *is* a date — but a note
    /// starts empty, so this bridges the gap between choosing "Add note" and
    /// typing into it.
    @State private var showsNote: Bool
    /// Set when "Add note" is chosen so the freshly revealed field takes focus,
    /// and cleared the moment it does. A plain `onAppear` check would re-grab
    /// focus every time the row scrolled back into view.
    @State private var focusNoteOnAppear = false
    @FocusState private var noteFocused: Bool

    init(
        stop: ItineraryItem,
        showCountryChip: Bool,
        onAddAttachment: @escaping () -> Void,
        onOpenAttachment: @escaping (TripAttachment) -> Void
    ) {
        self.stop = stop
        self.showCountryChip = showCountryChip
        self.onAddAttachment = onAddAttachment
        self.onOpenAttachment = onOpenAttachment
        _showsNote = State(initialValue: !stop.note.isEmpty)
    }

    /// A stop with a coordinate came from place search — render it as a place.
    private var isPlace: Bool { stop.coordinate != nil }

    /// A sensible date for a stop the user just decided to schedule: pick up from
    /// the last dated stop (so a run of stops flows forward from where the plan
    /// left off), else the trip's own start — never today, which is rarely where
    /// a planned trip begins.
    private var defaultStopDate: Date {
        let others = (stop.trip?.sortedStops ?? []).filter { $0 !== stop }
        if let latest = others.compactMap(\.date).max() { return latest }
        return stop.trip?.startDate ?? Date()
    }

    /// The trip's span, used to keep a stop's date inside it — a stop can't fall
    /// before the trip starts or after it ends. `nil` when there's no trip or the
    /// span is somehow inverted, leaving the picker unbounded rather than crashing
    /// on a bad `ClosedRange`.
    private var tripDateRange: ClosedRange<Date>? {
        guard let trip = stop.trip, trip.startDate <= trip.endDate else { return nil }
        return trip.startDate...trip.endDate
    }

    /// Every field is driven by its own content: a stop that carries nothing is a
    /// single line, and each editor appears the moment there's something for it to
    /// hold. Adding any of them is one control — `detailMenu`, on the identity row
    /// — rather than a permanently open row per capability, which left a plain
    /// stop standing nine rows tall with seven of them empty.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            secondaryLine
            if stop.transport != nil { transportEditor }
            if stop.date != nil { dateEditor }
            if showsNote {
                // `.subheadline`, not `.caption`: this is text the user wrote, and
                // the caption styles are for metadata *about* content, not content.
                TextField("Note", text: $stop.note, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...3)
                    .focused($noteFocused)
                    .onAppear {
                        if focusNoteOnAppear {
                            focusNoteOnAppear = false
                            noteFocused = true
                        }
                    }
            }
            attachments
            links
            contacts
        }
        .padding(.vertical, 2)
    }

    /// The stop's date and how long you're staying. Shown only once a date is
    /// set — "Set a date" in `detailMenu` assigns `defaultStopDate`, which is
    /// what reveals this; "Remove date" clears it away again.
    @ViewBuilder private var dateEditor: some View {
        let selection = Binding(get: { stop.date ?? defaultStopDate }, set: { stop.date = $0 })
        // Clamp to the trip's span so a stop's date can't wander outside it;
        // unbounded only when there's no valid range.
        if let range = tripDateRange {
            DatePicker("Date", selection: selection, in: range, displayedComponents: .date)
        } else {
            DatePicker("Date", selection: selection, displayedComponents: .date)
        }
        // How long you're here, inferred from the gap to the next dated stop (the
        // trip's end for the last one). A gray hint, not an editable field — see
        // `ItineraryItem.stayDayCount`.
        if let days = stop.stayDayCount {
            Text("^[\(days) day](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Everything optional a stop can carry, behind one control on the identity
    /// row. Entries drop out as they're taken up — a stop that already has a date
    /// offers to remove it instead — so the menu only ever lists what's actually
    /// available to do next.
    private var detailMenu: some View {
        Menu {
            Button {
                withAnimation(.snappy) { stop.date = stop.date == nil ? defaultStopDate : nil }
            } label: {
                stop.date == nil
                    ? Label("Set a date", systemImage: "calendar")
                    : Label("Remove date", systemImage: "calendar.badge.minus")
            }
            // Once a mode is picked the row shows its own copy of this picker, so
            // the mode can be changed or cleared where it's displayed.
            if stop.transport == nil { transportPicker }
            if !showsNote {
                Button {
                    focusNoteOnAppear = true
                    withAnimation(.snappy) { showsNote = true }
                } label: {
                    Label("Add note", systemImage: "text.alignleft")
                }
            }
            Button(action: onAddAttachment) {
                Label("Attach file", systemImage: "paperclip")
            }
            Button(action: addStopLink) {
                Label("Add link", systemImage: "link")
            }
            Button(action: addStopContact) {
                Label("Add contact", systemImage: "person.crop.circle.badge.plus")
            }
            if isPlace {
                Divider()
                Button(action: openInMaps) {
                    Label("Open in Apple Maps", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // The glyph alone is well under the touch minimum, and it sits
                // beside a text field that would otherwise swallow near misses.
                .frame(width: minimumHitTarget, height: minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Add detail")
        .accessibilityLabel(Text("Add detail"))
    }

    /// "Getting here": how the traveler reaches this stop. Rendered only once a
    /// mode has been picked (from `detailMenu`) — the menu stays on the row so the
    /// mode can be changed or cleared where it shows, and the free-text field takes
    /// flight or bus numbers, times, rental and confirmation details. Boarding
    /// passes go in this stop's attachments.
    @ViewBuilder private var transportEditor: some View {
        Menu {
            transportPicker
        } label: {
            Label {
                Text(stop.transport?.label ?? String(localized: "Getting here"))
            } icon: {
                Image(systemName: stop.transport?.symbolName ?? "arrow.triangle.branch")
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)

        TextField("Flight no., times, confirmation…", text: $stop.transportDetail, axis: .vertical)
            .font(.subheadline)
            .lineLimit(1...3)
    }

    /// The mode list itself, shared by `detailMenu` (which offers it while the stop
    /// has no transport) and `transportEditor` (which offers it afterwards), so the
    /// two can't drift apart.
    private var transportPicker: some View {
        Picker("Getting here", selection: transportSelection) {
            Text("None").tag(TransportMode?.none)
            ForEach(TransportMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbolName)
                    .tag(TransportMode?.some(mode))
            }
        }
    }

    private var transportSelection: Binding<TransportMode?> {
        Binding(
            get: { stop.transport },
            set: { mode in withAnimation(.snappy) { stop.transport = mode } })
    }

    /// Links pinned to this stop (a bus timetable, a ticket page), each openable
    /// and removable. Adding one is in `detailMenu` — a stop with no links shows
    /// nothing here rather than a standing "Add link" button.
    @ViewBuilder private var links: some View {
        ForEach(stop.sortedLinks) { link in
            LinkRow(link: link) { modelContext.delete(link) }
        }
    }

    private func addStopLink() {
        let link = TripLink(order: (stop.links ?? []).count, trip: stop.trip, item: stop)
        modelContext.insert(link)
        if stop.links == nil { stop.links = [] }
        withAnimation(.snappy) { stop.links?.append(link) }
    }

    /// Contacts pinned to this stop — the hotel's front desk on the hotel stop,
    /// a guide on a booked tour. Mirrors `links`.
    @ViewBuilder private var contacts: some View {
        ForEach(stop.sortedContacts) { contact in
            ContactRow(contact: contact) { modelContext.delete(contact) }
        }
    }

    private func addStopContact() {
        let contact = TripContact(
            order: (stop.contacts ?? []).count, trip: stop.trip, item: stop)
        modelContext.insert(contact)
        if stop.contacts == nil { stop.contacts = [] }
        withAnimation(.snappy) { stop.contacts?.append(contact) }
    }

    /// The row's secondary line: the country as a flag chip (the whole point of
    /// "country as an attribute, not a level"), then the address line when the
    /// stop is a searched place. Hidden for country markers, whose flag+name are
    /// already the title, and in the By-country view, where the header names it.
    @ViewBuilder private var secondaryLine: some View {
        let country = showCountryChip && isPlace ? stop.country : nil
        let hasDetail = !stop.detail.isEmpty
        if country != nil || hasDetail {
            HStack(spacing: 6) {
                if let country {
                    Text("\(country.flagEmoji) \(country.localizedName)")
                }
                if country != nil && hasDetail {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
                if hasDetail {
                    Text(stop.detail)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// The stop's identity line: a pin for a place or a flag for a country/region,
    /// then its name. A country marker shows the country name with an optional
    /// custom name trailing; a place shows its own title.
    @ViewBuilder private var identityRow: some View {
        HStack(spacing: 8) {
            Text(isPlace ? "📍" : (stop.country?.flagEmoji ?? "📍"))
            if !isPlace, let country = stop.country {
                // The country *is* this marker's identity — real text, not a grey
                // prompt — with the optional custom name in the trailing value slot.
                Text(country.localizedName)
                    .font(.headline)
                Spacer(minLength: 12)
                TextField("Add a name", text: $stop.title)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            } else {
                // A place (or a country-less stop): whatever it's titled is its
                // only identity, so it stays primary.
                TextField(isPlace ? "Place" : "Stop", text: $stop.title)
                    .font(.headline)
            }
            detailMenu
        }
    }

    /// Files attached to this stop, each openable with a remove button. A List
    /// row can't host `.onDelete`, so each carries its own destructive control.
    /// Attaching one is in `detailMenu`.
    @ViewBuilder private var attachments: some View {
        ForEach(stop.sortedAttachments) { attachment in
            HStack(spacing: 8) {
                AttachmentRow(attachment: attachment) { onOpenAttachment(attachment) }
                Button(role: .destructive) {
                    modelContext.delete(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: minimumHitTarget, height: minimumHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Remove file")
                .accessibilityLabel(Text("Remove file"))
            }
        }
    }

    private func openInMaps() {
        guard let coordinate = stop.coordinate else { return }
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil)
        item.name = stop.displayTitle
        item.openInMaps()
    }
}

/// One editable link row — a title over its URL, an open button when the URL
/// parses, and a remove control. Shared by the trip-level Links section and each
/// stop's own links; both edit the `TripLink` in place, matching how stops and
/// packing items are edited inline rather than through a sheet.
struct LinkRow: View {
    @Bindable var link: TripLink
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $link.title)
                    .font(.subheadline)
                TextField("https://…", text: $link.url)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
            }
            if let resolved = link.resolvedURL {
                Button {
                    openURL(resolved)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help("Open link")
                .accessibilityLabel(Text("Open link"))
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: minimumHitTarget, height: minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Remove link")
            .accessibilityLabel(Text("Remove link"))
        }
    }
}

/// One editable contact: its kind, a name, the number or address, and a button
/// that hands the value to the system — the dialer, WhatsApp, or a mail
/// composer. Mirrors `LinkRow`; the kind leads the row because it drives the
/// icon, the keyboard and what the action button does.
struct ContactRow: View {
    @Bindable var contact: TripContact
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Contact kind", selection: $contact.contactKind) {
                    ForEach(ContactKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                    }
                }
            } label: {
                Image(systemName: contact.contactKind.symbolName)
                    .font(.subheadline)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help("Contact kind")
            .accessibilityLabel(Text("Contact kind"))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $contact.name)
                    .font(.subheadline)
                TextField(contact.contactKind.valuePrompt, text: $contact.value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(keyboardType)
                    #endif
            }

            // Absent until the value parses into something openable, so a
            // half-typed number doesn't offer a call that would fail.
            if let action = contact.actionURL {
                Button {
                    openURL(action)
                } label: {
                    Image(systemName: contact.contactKind.symbolName)
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help(actionLabel)
                .accessibilityLabel(Text(actionLabel))
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: minimumHitTarget, height: minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Remove contact")
            .accessibilityLabel(Text("Remove contact"))
        }
    }

    /// What the action button promises, phrased per kind so VoiceOver announces
    /// "Call" rather than a generic "Open".
    private var actionLabel: String {
        switch contact.contactKind {
        case .phone: String(localized: "Call", comment: "Contact action")
        case .whatsapp: String(localized: "Open WhatsApp", comment: "Contact action")
        case .email: String(localized: "Send email", comment: "Contact action")
        case .other: String(localized: "Open", comment: "Contact action")
        }
    }

    #if !os(macOS)
        private var keyboardType: UIKeyboardType {
            switch contact.contactKind {
            case .phone, .whatsapp: .phonePad
            case .email: .emailAddress
            case .other: .default
            }
        }
    #endif
}
