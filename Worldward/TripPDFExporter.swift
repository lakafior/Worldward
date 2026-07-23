/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    /// The brand royal blue (`Color.brandRoyal`) as a plain sRGB `CGColor`, used
    /// for section headers and rules so the PDF reads as the same identity as
    /// the app.
    private static let brandColor = CGColor(srgbRed: 0.161, green: 0.350, blue: 0.832, alpha: 1)

    static func render(trip: Trip, options: TripExportOptions = .all) -> Data {
        let name = trip.title.isEmpty ? Str.Trip.untitled : trip.title
        let data = CFDataCreateMutable(nil, 0) as CFMutableData
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        // The formatted text (header/itinerary/packing/notes/attachment manifest),
        // then a full page per image attachment. Page numbers run continuously
        // across both so the footer keeps counting.
        var page = drawTextPages(
            content(for: trip, options: options), footerTitle: name, in: context)
        if options.contains(.attachments) {
            page = drawImagePages(for: trip, footerTitle: name, in: context, startingPage: page)
        }
        context.closePDF()
        return data as Data
    }

    // MARK: Content

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    /// Custom attribute marking a line that gets a horizontal rule drawn under it
    /// at draw time (Core Text carries unknown attributes through to the runs).
    /// Value is one of `Rule`'s raw values.
    private static let ruleKey = NSAttributedString.Key("WorldwardRule")

    private nonisolated enum Rule: String {
        /// The heavier brand-blue rule closing the title block.
        case brand
        /// The hairline separator under a section header.
        case separator
    }

    private static func content(for trip: Trip, options: TripExportOptions) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let name = trip.title.isEmpty ? Str.Trip.untitled : trip.title
        result.append(line(name, .title))

        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = trip.endDate.formatted(date: .abbreviated, time: .omitted)
        let dateLine = start == end ? start : "\(start) – \(end)"
        let header = [trip.flags.isEmpty ? nil : trip.flags, dateLine]
            .compactMap { $0 }
            .joined(separator: "   ·   ")
        if !header.isEmpty { result.append(line(header, .subtitle, rule: .brand)) }

        let stops = trip.sortedStops
        if options.contains(.itinerary), !stops.isEmpty {
            result.append(line(Str.Trip.itineraryLabel, .sectionHeader, rule: .separator))
            // Flat list — places are stops now, so each is its own numbered line
            // with its flag, date, address line and note.
            for (index, stop) in stops.enumerated() {
                let flag = stop.country?.flagEmoji ?? "📍"
                var stopLine = "\(index + 1). \(flag)  \(stop.displayTitle)"
                if let date = stop.date {
                    stopLine += "   —   \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                result.append(line(stopLine, .body))
                if !stop.detail.isEmpty { result.append(line(stop.detail, .subItem)) }
                if !stop.note.isEmpty { result.append(line(stop.note, .note)) }
            }
        }

        if options.contains(.packing), !(trip.packing ?? []).isEmpty {
            result.append(line(Str.Trip.packing, .sectionHeader, rule: .separator))
            let groups = trip.packingGroups
            let useHeadings = groups.contains { $0.container != nil }
            for group in groups {
                if useHeadings {
                    result.append(line(group.container?.name ?? Str.Trip.packingOther, .subHeader))
                }
                for item in group.items {
                    result.append(checklistLine(item))
                }
            }
        }

        if options.contains(.notes), !trip.notes.isEmpty {
            result.append(line(Str.Trip.notesLabel, .sectionHeader, rule: .separator))
            result.append(notesContent(trip.notes))
        }

        // A manifest of every attached file (filename, caption, stop). Image
        // files then follow as full pages; other files appear here only.
        let attachments = trip.sortedAttachments
        if options.contains(.attachments), !attachments.isEmpty {
            result.append(line(Str.Trip.attachmentsLabel, .sectionHeader, rule: .separator))
            for attachment in attachments {
                var line = "•  \(attachment.filename)"
                if !attachment.caption.isEmpty { line += "  —  \(attachment.caption)" }
                if let stop = attachment.item { line += "  (\(stop.displayTitle))" }
                result.append(self.line(line, .body))
            }
        }

        return result
    }

    private static func line(
        _ text: String, _ style: TextStyle, rule: Rule? = nil
    ) -> NSAttributedString {
        var attributes = style.attributes
        if let rule { attributes[ruleKey] = rule.rawValue }
        return NSAttributedString(string: text + "\n", attributes: attributes)
    }

    /// One packing item: a ballot-box glyph, then the title (with a ×quantity
    /// suffix past 1). The box glyphs come from a symbol fallback font and sit
    /// a touch small next to 11 pt Helvetica, so they're drawn slightly larger;
    /// a packed item shows a brand-blue check and grayed-out text, so what's
    /// left to pack stands out at a glance.
    private static func checklistLine(_ item: PackingItem) -> NSAttributedString {
        let style = TextStyle.checklistItem
        var boxAttributes = style.attributes
        boxAttributes[fontKey] = CTFontCreateWithName("Helvetica" as CFString, 12.5, nil)
        if item.isPacked { boxAttributes[colorKey] = brandColor }
        var textAttributes = style.attributes
        if item.isPacked { textAttributes[colorKey] = CGColor(gray: 0.45, alpha: 1) }

        let count = item.quantity > 1 ? "   ×\(item.quantity)" : ""
        let result = NSMutableAttributedString(
            string: (item.isPacked ? "☑" : "☐") + "  ", attributes: boxAttributes)
        result.append(
            NSAttributedString(string: "\(item.title)\(count)\n", attributes: textAttributes))
        return result
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

    /// Internal (not private): `TripNotesPreview` in `TripViews.swift` reuses
    /// these two classifiers so the in-app notes rendering and the PDF agree on
    /// what counts as a heading or bullet.
    static func headingText(_ line: String) -> String? {
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

    static func bulletText(_ line: String) -> String? {
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
    /// one PDF page per frame, into an existing context — returning the last page
    /// number so image pages can keep the footer counting. A raw
    /// `CGContext(consumer:)` — rather than `UIGraphicsPDFRenderer` — already uses
    /// the bottom-left-origin, y-up coordinate space `CTFrameDraw` and
    /// `context.draw(_:in:)` expect, so no manual flip is needed.
    private static func drawTextPages(
        _ text: NSAttributedString, footerTitle: String, in context: CGContext
    ) -> Int {
        let mediaBox = CGRect(origin: .zero, size: pageSize)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: mediaBox.insetBy(dx: margin, dy: margin), transform: nil)

        var index = 0
        var page = 0
        let length = text.length
        while index < length {
            page += 1
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(index, 0), path, nil)
            CTFrameDraw(frame, context)
            drawRules(in: frame, textRect: path.boundingBox, context: context)
            drawFooter(in: context, page: page, title: footerTitle)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            // Guards against an infinite loop if a page somehow fits nothing.
            guard visible.length > 0 else { break }
            index += visible.length
        }
        return page
    }

    /// One page per image attachment: the image fit within the margins with a
    /// caption beneath it. Non-image files (PDFs, passes) stay in the manifest
    /// only — embedding those would need PDFKit and defeats the single-code-path
    /// Core Graphics approach. Returns the last page number.
    private static func drawImagePages(
        for trip: Trip, footerTitle: String, in context: CGContext, startingPage: Int
    ) -> Int {
        let mediaBox = CGRect(origin: .zero, size: pageSize)
        let content = mediaBox.insetBy(dx: margin, dy: margin)
        var page = startingPage
        for attachment in trip.sortedAttachments where isImage(attachment.filename) {
            guard let image = decodeImage(attachment.data) else { continue }
            page += 1
            context.beginPDFPage(nil)
            // Reserve a strip at the bottom of the content area for the caption.
            let captionGap: CGFloat = 22
            let area = CGRect(
                x: content.minX, y: content.minY + captionGap,
                width: content.width, height: content.height - captionGap)
            context.draw(image, in: aspectFit(width: image.width, height: image.height, in: area))
            let caption =
                attachment.caption.isEmpty
                ? attachment.filename : "\(attachment.filename)   —   \(attachment.caption)"
            drawCaption(caption, in: context, y: content.minY)
            drawFooter(in: context, page: page, title: footerTitle)
            context.endPDFPage()
        }
        return page
    }

    /// Whether a filename is a raster image the PDF can embed as a page, decided
    /// by its uniform type rather than a hand-kept extension list.
    private static func isImage(_ filename: String) -> Bool {
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The largest rect with the image's aspect ratio that fits in `bounds`, centered.
    private static func aspectFit(width: Int, height: Int, in bounds: CGRect) -> CGRect {
        guard width > 0, height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// A centered gray caption line with its baseline at `y`.
    private static func drawCaption(_ text: String, in context: CGContext, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            fontKey: CTFontCreateWithName("Helvetica" as CFString, 9.5, nil),
            colorKey: CGColor(gray: 0.4, alpha: 1),
        ]
        let ctLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        context.textPosition = CGPoint(x: (pageSize.width - CGFloat(width)) / 2, y: y)
        CTLineDraw(ctLine, context)
    }

    /// The `Rule` marker of a laid-out line, read from its first glyph run
    /// (every run in a marked line carries the attribute).
    private static func rule(of line: CTLine) -> Rule? {
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let raw = attributes[ruleKey] as? String else { return nil }
        return Rule(rawValue: raw)
    }

    /// Strokes the horizontal rules under lines marked with `ruleKey`: a heavier
    /// brand-blue rule closing the title block, hairline separators under section
    /// headers. When a marked line wraps, only its last fragment gets the rule
    /// (each fragment carries the same attribute). Line origins come back
    /// relative to the frame path's origin, hence the `textRect` offsets.
    private static func drawRules(in frame: CTFrame, textRect: CGRect, context: CGContext) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        for (index, (line, origin)) in zip(lines, origins).enumerated() {
            guard let kind = rule(of: line) else { continue }
            if index + 1 < lines.count, rule(of: lines[index + 1]) == kind { continue }

            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            let y = textRect.minY + origin.y - descent - (kind == .brand ? 7 : 3)
            context.setStrokeColor(
                kind == .brand ? brandColor : CGColor(gray: 0.82, alpha: 1))
            context.setLineWidth(kind == .brand ? 1.5 : 0.6)
            context.move(to: CGPoint(x: textRect.minX, y: y))
            context.addLine(to: CGPoint(x: textRect.maxX, y: y))
            context.strokePath()
        }
    }

    /// A small gray footer on every page: the trip title on the left (truncated
    /// to leave room), the page number on the right.
    private static func drawFooter(in context: CGContext, page: Int, title: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            fontKey: CTFontCreateWithName("Helvetica" as CFString, 8.5, nil),
            colorKey: CGColor(gray: 0.55, alpha: 1),
        ]
        let baseline: CGFloat = 30

        let pageLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\(page)", attributes: attributes))
        let pageWidth = CTLineGetTypographicBounds(pageLine, nil, nil, nil)
        context.textPosition = CGPoint(
            x: pageSize.width - margin - CGFloat(pageWidth), y: baseline)
        CTLineDraw(pageLine, context)

        let titleLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: title, attributes: attributes))
        let available = Double(pageSize.width - 2 * margin - CGFloat(pageWidth) - 12)
        let truncated =
            CTLineCreateTruncatedLine(titleLine, available, .end, nil) ?? titleLine
        context.textPosition = CGPoint(x: margin, y: baseline)
        CTLineDraw(truncated, context)
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
            case .sectionHeader: TripPDFRenderer.brandColor
            default: CGColor(gray: 0.08, alpha: 1)
            }
        }

        private var paragraphStyle: CTParagraphStyle {
            switch self {
            case .title: TextStyle.paragraphStyle(spacingAfter: 4)
            case .subtitle: TextStyle.paragraphStyle(spacingAfter: 20)
            case .sectionHeader: TextStyle.paragraphStyle(spacingBefore: 16, spacingAfter: 10)
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
