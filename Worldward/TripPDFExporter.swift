/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreText
import Foundation

/// Renders a trip's itinerary as a formatted, paginated PDF — the PDFKit-era
/// counterpart to `Trip.markdownSummary` (see `ExportableTripPDF` in
/// `TripViews.swift`), covering the same sections: header, Itinerary, Packing,
/// Notes.
///
/// Built directly on Core Text + Core Graphics rather than PDFKit itself:
/// PDFKit's `PDFDocument`/`PDFPage` are for viewing and manipulating PDFs that
/// already exist, not for authoring formatted text into new ones. A `CGContext`
/// created straight from a data consumer draws real vector, searchable text and
/// paginates with a single code path shared by iOS and macOS — no UIKit/AppKit
/// needed at all.
///
/// `nonisolated` throughout: `ExportableTripPDF`'s `init` (in `TripViews.swift`)
/// runs in a nonisolated context because it's called from `Transferable`'s
/// nonisolated `transferRepresentation`, so this whole call chain must be too.
/// Safe here since it only touches `Trip`'s own (already nonisolated) model
/// properties and plain Core Text/Core Graphics calls.
nonisolated enum TripPDFRenderer {
    /// US Letter for US-region locales, A4 (the global default) everywhere else.
    private static var pageSize: CGSize {
        Locale.current.measurementSystem == .us
            ? CGSize(width: 612, height: 792)
            : CGSize(width: 595, height: 842)
    }
    private static let margin: CGFloat = 54

    static func render(trip: Trip) -> Data {
        paginate(content(for: trip))
    }

    // MARK: Content

    private static func content(for trip: Trip) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let name = trip.title.isEmpty ? "Untitled Trip" : trip.title
        result.append(line(name, .title))

        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = trip.endDate.formatted(date: .abbreviated, time: .omitted)
        let dateLine = start == end ? start : "\(start) – \(end)"
        let header = [trip.flags.isEmpty ? nil : trip.flags, dateLine]
            .compactMap { $0 }
            .joined(separator: "   ·   ")
        if !header.isEmpty { result.append(line(header, .subtitle)) }

        let stops = trip.sortedStops
        if !stops.isEmpty {
            result.append(line("Itinerary", .sectionHeader))
            for (index, stop) in stops.enumerated() {
                let flag = stop.country?.flagEmoji ?? "📍"
                var stopLine = "\(index + 1). \(flag)  \(stop.displayTitle)"
                if let date = stop.date {
                    stopLine += "   —   \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                result.append(line(stopLine, .body))
                if !stop.note.isEmpty { result.append(line(stop.note, .note)) }
                for place in stop.sortedPlaces {
                    result.append(line("📍  \(place.title)", .subItem))
                }
            }
        }

        if !trip.packing.isEmpty {
            result.append(line("Packing", .sectionHeader))
            let groups = trip.packingGroups
            let useHeadings = groups.contains { $0.container != nil }
            for group in groups {
                if useHeadings {
                    result.append(line(group.container?.name ?? "Other", .subHeader))
                }
                for item in group.items {
                    let count = item.quantity > 1 ? "   ×\(item.quantity)" : ""
                    let box = item.isPacked ? "☑" : "☐"
                    result.append(line("\(box)  \(item.title)\(count)", .checklistItem))
                }
            }
        }

        if !trip.notes.isEmpty {
            result.append(line("Notes", .sectionHeader))
            result.append(notesContent(trip.notes))
        }

        return result
    }

    private static func line(_ text: String, _ style: TextStyle) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: style.attributes)
    }

    /// Trip notes often come from `TripPlanner.suggestNotes`, which returns
    /// Markdown (a bold heading per country, then a bulleted list). Renders that
    /// minimal subset — `# `/`## ` headers, a line that's entirely `**bold**`,
    /// `- `/`* ` bullets, and inline `**bold**` spans — rather than dumping the
    /// raw asterisks and dashes as plain text.
    private static func notesContent(_ notes: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for rawLine in notes.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let heading = headingText(trimmed) {
                result.append(inlineMarkdown(heading, style: .subHeader))
            } else if let bullet = bulletText(trimmed) {
                result.append(inlineMarkdown(bullet, style: .bullet, prefix: "•  "))
            } else {
                result.append(inlineMarkdown(trimmed, style: .body))
            }
        }
        return result
    }

    private static func headingText(_ line: String) -> String? {
        if line.hasPrefix("### ") { return String(line.dropFirst(4)) }
        if line.hasPrefix("## ") { return String(line.dropFirst(3)) }
        if line.hasPrefix("# ") { return String(line.dropFirst(2)) }
        // A line that's *entirely* a bold span (e.g. "**France**") reads as a
        // heading too — that's how `suggestNotes` marks its country headings.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2))
        }
        return nil
    }

    private static func bulletText(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        return nil
    }

    /// Renders `**bold**` spans inline within an otherwise plain-text line.
    private static func inlineMarkdown(
        _ text: String, style: TextStyle, prefix: String = ""
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: prefix, attributes: style.attributes)
        for (index, part) in text.components(separatedBy: "**").enumerated() where !part.isEmpty {
            result.append(
                NSAttributedString(string: part, attributes: style.attributes(bold: index % 2 == 1)))
        }
        result.append(NSAttributedString(string: "\n", attributes: style.attributes))
        return result
    }

    // MARK: Pagination

    /// Draws `text` across as many Core Text frames as it takes to exhaust it,
    /// one PDF page per frame. A raw `CGContext(consumer:)` — rather than
    /// `UIGraphicsPDFRenderer` — already uses the bottom-left-origin, y-up
    /// coordinate space `CTFrameDraw` expects, so no manual flip is needed.
    private static func paginate(_ text: NSAttributedString) -> Data {
        let data = CFDataCreateMutable(nil, 0) as CFMutableData
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: mediaBox.insetBy(dx: margin, dy: margin), transform: nil)

        var index = 0
        let length = text.length
        while index < length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(index, 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            // Guards against an infinite loop if a page somehow fits nothing.
            guard visible.length > 0 else { break }
            index += visible.length
        }
        context.closePDF()

        return data as Data
    }

    // MARK: Styles

    private nonisolated enum TextStyle {
        case title, subtitle, sectionHeader, subHeader, body, note, subItem, checklistItem, bullet

        /// The style's default attributes (bold iff the style reads as a heading).
        var attributes: [NSAttributedString.Key: Any] { attributes(bold: isBoldByDefault) }

        /// Attributes with an explicit bold override, for inline `**bold**` spans
        /// within an otherwise plain-text line.
        func attributes(bold: Bool) -> [NSAttributedString.Key: Any] {
            [
                NSAttributedString.Key(kCTFontAttributeName as String): font(bold: bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
            ]
        }

        private var isBoldByDefault: Bool {
            switch self {
            case .title, .sectionHeader, .subHeader: true
            default: false
            }
        }

        private var fontSize: CGFloat {
            switch self {
            case .title: 22
            case .subtitle: 12
            case .sectionHeader: 15
            case .subHeader: 12
            case .body, .checklistItem, .bullet: 11
            case .note, .subItem: 10
            }
        }

        private func font(bold: Bool) -> CTFont {
            CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, fontSize, nil)
        }

        private var color: CGColor {
            switch self {
            case .subtitle, .note, .subItem: CGColor(gray: 0.42, alpha: 1)
            default: CGColor(gray: 0.08, alpha: 1)
            }
        }

        private var paragraphStyle: CTParagraphStyle {
            switch self {
            case .title: TextStyle.paragraphStyle(spacingAfter: 4)
            case .subtitle: TextStyle.paragraphStyle(spacingAfter: 16)
            case .sectionHeader: TextStyle.paragraphStyle(spacingBefore: 14, spacingAfter: 8)
            case .subHeader: TextStyle.paragraphStyle(spacingBefore: 10, spacingAfter: 4)
            case .body: TextStyle.paragraphStyle(spacingAfter: 3)
            case .checklistItem, .bullet: TextStyle.paragraphStyle(headIndent: 14, spacingAfter: 3)
            case .note, .subItem: TextStyle.paragraphStyle(headIndent: 18, spacingAfter: 2)
            }
        }

        private static func paragraphStyle(
            headIndent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 4
        ) -> CTParagraphStyle {
            let values: [CGFloat] = [headIndent, headIndent, spacingBefore, spacingAfter]
            return values.withUnsafeBufferPointer { buf in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size,
                        value: buf.baseAddress!),
                    CTParagraphStyleSetting(
                        spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size,
                        value: buf.baseAddress! + 1),
                    CTParagraphStyleSetting(
                        spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size,
                        value: buf.baseAddress! + 2),
                    CTParagraphStyleSetting(
                        spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size,
                        value: buf.baseAddress! + 3),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }
}
