import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - CSV table

/// A parsed spreadsheet: delimiter auto-detected, quoted fields unescaped, and an
/// optional header row recognised by common column names (in several languages,
/// so a Polish "Kraj;Data" export is as welcome as "Country,Date"). Deliberately
/// forgiving — ragged rows, stray quotes, and blank lines all survive.
struct CSVTable {
    /// Header cells, or `nil` when the first row already looks like data.
    let headers: [String]?
    /// Data rows (the header excluded). Rows may be ragged; read via `cell(_:_:)`.
    let rows: [[String]]

    var columnCount: Int { max(headers?.count ?? 0, rows.map(\.count).max() ?? 0) }

    /// The cell at `row[column]`, or an empty string when the row is too short.
    func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }

    /// A user-facing label for a column: its header name, or "Column N".
    func columnLabel(_ column: Int) -> String {
        if let header = headers?[safe: column], !header.isEmpty { return header }
        return String(localized: "Column \(column + 1)", comment: "Fallback CSV column name")
    }

    /// Column names that mark a first row as a header. Matched case-insensitively
    /// as substrings, and multilingual on purpose: spreadsheets arrive in the
    /// user's language, not the app's.
    private static let headerKeywords: [String] = [
        "country", "nation", "name", "place", "iso", "code",
        "date", "when", "year", "visited", "status", "note", "comment", "description",
        "kraj", "państwo", "data", "rok", "notatki",  // Polish
        "land", "datum", "jahr",  // German
        "pays", "année",  // French
        "país", "fecha", "año",  // Spanish
    ]

    /// Parses `text` into a table, or `nil` when it contains no usable rows.
    static func parse(_ text: String) -> CSVTable? {
        let delimiter = detectDelimiter(in: text)
        var rows = tokenize(text, delimiter: delimiter)
        rows.removeAll { row in row.allSatisfy(\.isEmpty) }
        guard !rows.isEmpty else { return nil }

        let first = rows[0]
        let isHeader = first.contains { cell in
            let lowered = cell.lowercased()
            return Self.headerKeywords.contains { lowered.contains($0) }
        }
        if isHeader {
            return CSVTable(headers: first, rows: Array(rows.dropFirst()))
        }
        return CSVTable(headers: nil, rows: rows)
    }

    /// Picks the separator that appears most in the first few lines — comma,
    /// semicolon (European Excel), or tab. Comma wins ties.
    private static func detectDelimiter(in text: String) -> Character {
        let sample = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .prefix(10)
        var best: Character = ","
        var bestCount = 0
        for candidate: Character in [",", ";", "\t"] {
            let count = sample.reduce(0) { total, line in
                total + line.count(where: { $0 == candidate })
            }
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        return best
    }

    /// Splits `text` into rows and fields: RFC-4180 quotes with `""` escapes,
    /// any newline convention, whitespace trimmed. A stray quote mid-field is
    /// kept as-is rather than derailing the rest of the file.
    private static func tokenize(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        func endField() {
            row.append(field.trimmingCharacters(in: .whitespaces))
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if inQuotes {
                if char == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(char)
                }
                i += 1
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                inQuotes = true
            case "\"":
                field.append(char)
            case delimiter:
                endField()
            // A CRLF pair is a *single* Swift grapheme cluster, so it needs its
            // own literal — it matches neither "\n" nor "\r".
            case "\n", "\r", "\r\n":
                endRow()
            default:
                field.append(char)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Import engine

/// Turns a `CSVTable` into an additive import: fuzzy country resolution, a
/// forgiving date parse, and per-country plans the preview sheet can show before
/// anything is written. Unlike the JSON backup (a wholesale replace), a CSV
/// import only *fills in* — it never downgrades a status or deletes a visit —
/// because its job is migrating data from another tracker into a live catalog.
@MainActor
enum CSVTransfer {

    /// Which table column feeds which field. Only the country column is
    /// required; everything else is optional, matching the roadmap's "forgiving
    /// importer (optional date column)".
    struct Mapping: Equatable {
        var country: Int = 0
        var date: Int?
        var status: Int?
        var notes: Int?
    }

    /// Everything the import would do to one country, shown in the preview.
    struct CountryPlan: Identifiable {
        let country: Country
        /// Distinct visit days to add (already deduped against each other;
        /// deduped against existing visits again at apply time).
        let dates: [Date]
        /// Notes keyed by visit day, applied to the created visits.
        let notesByDate: [Date: String]
        /// Notes from undated rows, appended to the country's own notes.
        let undatedNotes: [String]
        /// The strongest status named across the country's rows, if any.
        let status: CountryStatus?
        var id: String { country.id }
    }

    /// The resolved outcome of a parse pass: what will import and what didn't match.
    struct Plan {
        var countries: [CountryPlan] = []
        /// Distinct country names that resolved to nothing, in file order.
        var unmatched: [String] = []
        var totalRows = 0
        var datedVisits: Int { countries.reduce(0) { $0 + $1.dates.count } }
    }

    // MARK: Column guessing

    /// Guesses the column mapping from headers first, then from what the values
    /// actually parse as — so a headerless file still lands on the right columns.
    static func guessMapping(table: CSVTable, countries: [Country]) -> Mapping {
        var mapping = Mapping()
        var claimed = Set<Int>()

        func headerMatch(_ keywords: [String]) -> Int? {
            guard let headers = table.headers else { return nil }
            return headers.indices.first { index in
                guard !claimed.contains(index) else { return false }
                let lowered = headers[index].lowercased()
                return keywords.contains { lowered.contains($0) }
            }
        }
        /// The unclaimed column whose sampled values most often satisfy `test`,
        /// provided at least `threshold` of its non-empty samples do.
        func valueMatch(threshold: Double, _ test: (String) -> Bool) -> Int? {
            var best: (index: Int, ratio: Double)?
            for column in 0..<table.columnCount where !claimed.contains(column) {
                let samples = table.rows.prefix(30).map { table.cell($0, column) }
                    .filter { !$0.isEmpty }
                guard !samples.isEmpty else { continue }
                let ratio = Double(samples.count(where: test)) / Double(samples.count)
                if ratio >= threshold, ratio > (best?.ratio ?? 0) {
                    best = (column, ratio)
                }
            }
            return best?.index
        }

        let countryColumn =
            headerMatch(["country", "kraj", "państwo", "land", "pays", "país", "nation", "name", "place"])
            ?? valueMatch(threshold: 0.4) { resolveCountry($0, in: countries) != nil }
        mapping.country = countryColumn ?? 0
        claimed.insert(mapping.country)

        mapping.date =
            headerMatch(["date", "data", "datum", "fecha", "when", "visited on", "year", "rok", "jahr", "année", "año"])
            ?? valueMatch(threshold: 0.5) { parseDate($0) != nil }
        if let date = mapping.date { claimed.insert(date) }

        mapping.status =
            headerMatch(["status"])
            ?? valueMatch(threshold: 0.5) { parseStatus($0) != nil }
        if let status = mapping.status { claimed.insert(status) }

        mapping.notes = headerMatch(["note", "notatki", "comment", "description", "memo"])
        return mapping
    }

    // MARK: Field parsing

    /// Resolves a cell to a catalog country: ISO alpha-2/alpha-3 code first, then
    /// the same fuzzy name match the visit-log parser uses. Leading flag emoji or
    /// other decoration is trimmed away.
    static func resolveCountry(_ raw: String, in countries: [Country]) -> Country? {
        let query = raw.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !query.isEmpty else { return nil }

        if query.count == 2 || query.count == 3 {
            let upper = query.uppercased()
            if let byCode = countries.first(where: { $0.id == upper || $0.iso3 == upper }) {
                return byCode
            }
        }
        return VisitLogParser.resolve(query, in: countries)
    }

    /// Parses a date cell leniently: the user's own short/medium formats first,
    /// then common explicit formats (day-first before month-first, since ambiguous
    /// numeric dates are far more often European in this context), then a bare
    /// year. Returns `nil` rather than guessing wildly.
    static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        // A bare integer is only a year if it's plausible as one.
        if let year = Int(value) {
            guard (1900...2100).contains(year) else { return nil }
            return Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))
        }

        for style in [DateFormatter.Style.short, .medium, .long] {
            let formatter = DateFormatter()
            formatter.dateStyle = style
            formatter.timeStyle = .none
            if let date = formatter.date(from: value) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in [
            "yyyy-MM-dd", "yyyy/MM/dd", "dd.MM.yyyy", "d.M.yyyy", "dd-MM-yyyy",
            "dd/MM/yyyy", "d/M/yyyy", "MM/dd/yyyy", "MMM d, yyyy", "d MMM yyyy", "yyyy-MM",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Parses a status cell against the app's own status names (raw values and
    /// localized labels, so our own CSV export round-trips) plus common English
    /// synonyms other trackers use.
    static func parseStatus(_ raw: String) -> CountryStatus? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }

        for status in CountryStatus.allCases {
            if status.rawValue.lowercased() == value || status.label.lowercased() == value {
                return status
            }
        }
        switch value {
        case "been", "been there": return .visited
        case "lived there": return .lived
        case "living there", "home": return .living
        case "passed through", "transit", "layover", "stopover": return .crossed
        default: return nil
        }
    }

    // MARK: Planning

    /// Resolves every row through `mapping` into per-country plans plus the list
    /// of names that matched nothing.
    static func plan(table: CSVTable, mapping: Mapping, countries: [Country]) -> Plan {
        var plan = Plan()
        var plansByID: [String: (country: Country, days: [Date: String], undated: [String], status: CountryStatus?)] = [:]
        var order: [String] = []
        var unmatchedSeen = Set<String>()
        let calendar = Calendar.current
        let statusRank: (CountryStatus) -> Int = { CountryStatus.allCases.firstIndex(of: $0) ?? 0 }

        for row in table.rows {
            let rawName = table.cell(row, mapping.country)
            guard !rawName.isEmpty else { continue }
            plan.totalRows += 1

            guard let country = resolveCountry(rawName, in: countries) else {
                if unmatchedSeen.insert(rawName).inserted { plan.unmatched.append(rawName) }
                continue
            }

            var entry = plansByID[country.id] ?? (country, [:], [], nil)
            if plansByID[country.id] == nil { order.append(country.id) }

            let notes = mapping.notes.map { table.cell(row, $0) } ?? ""
            let date = mapping.date.flatMap { parseDate(table.cell(row, $0)) }
            if let date {
                let day = calendar.startOfDay(for: date)
                // Several rows on the same day merge; the first non-empty note wins.
                if entry.days[day] == nil || entry.days[day]?.isEmpty == true {
                    entry.days[day] = notes
                }
            } else if !notes.isEmpty {
                entry.undated.append(notes)
            }

            if let status = mapping.status.flatMap({ parseStatus(table.cell(row, $0)) }),
                status.isVisited,
                statusRank(status) > (entry.status.map(statusRank) ?? -1)
            {
                entry.status = status
            }
            plansByID[country.id] = entry
        }

        plan.countries = order.compactMap { id in
            guard let entry = plansByID[id] else { return nil }
            return CountryPlan(
                country: entry.country,
                dates: entry.days.keys.sorted(),
                notesByDate: entry.days,
                undatedNotes: entry.undated,
                status: entry.status)
        }
        return plan
    }

    // MARK: Applying

    /// Writes a plan into the store additively. Statuses only fill in where the
    /// country is still unvisited (hand-set data always wins), visits are skipped
    /// when the country already has one that day (so re-importing the same file
    /// is idempotent), and notes append rather than overwrite.
    /// Returns how many countries were touched and how many visits were created.
    @discardableResult
    static func apply(_ plan: Plan, in context: ModelContext) throws -> (countries: Int, visits: Int) {
        let calendar = Calendar.current
        var countriesTouched = 0
        var visitsAdded = 0

        for entry in plan.countries {
            let country = entry.country
            var touched = false

            if country.status == .notVisited {
                country.status = entry.status ?? .visited
                country.statusIsImported = true
                touched = true
            }

            let existingDays = Set(
                country.visits.map { calendar.startOfDay(for: $0.date) }
                    + (country.visitDate.map { [calendar.startOfDay(for: $0)] } ?? []))
            for day in entry.dates where !existingDays.contains(day) {
                let visit = Visit(
                    date: day, notes: entry.notesByDate[day] ?? "",
                    country: country, isImported: true)
                context.insert(visit)
                visitsAdded += 1
                touched = true
            }

            for note in entry.undatedNotes where !country.notes.contains(note) {
                country.notes = country.notes.isEmpty ? note : country.notes + "\n" + note
                touched = true
            }

            if touched { countriesTouched += 1 }
        }

        try context.save()
        return (countriesTouched, visitsAdded)
    }

    // MARK: Exporting

    /// A CSV of every visited country and its visits — the outward-facing
    /// counterpart of the JSON backup, for spreadsheets and other trackers.
    /// Uses the same `Country,Status,Date,Notes` header the importer's column
    /// guesser recognises, so an export round-trips cleanly.
    static func export(countries: [Country]) -> String {
        var lines = ["Country,Status,Date,Notes"]
        for country in countries.sorted(by: { $0.name < $1.name }) where country.isVisited {
            let name = escape(country.name)
            let status = escape(country.status.label)
            if country.visits.isEmpty {
                lines.append("\(name),\(status),,")
            }
            for visit in country.visits.sorted(by: { $0.date < $1.date }) {
                let date = visit.date.formatted(date: .numeric, time: .omitted)
                let notes = escape(visit.notes)
                lines.append("\(name),\(status),\(date),\(notes)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Escapes a CSV field (quotes it when it contains a comma, quote, or newline).
    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

/// A minimal `FileDocument` carrying CSV text, so `fileExporter` can write it
/// natively on both platforms — `JSONDocument`'s CSV sibling.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents,
            let text = String(data: contents, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
