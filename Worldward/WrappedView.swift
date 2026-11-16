/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Year facts

/// The handful of year-specific facts the Wrapped recap celebrates, derived in
/// one pass over the catalog (plus the already-computed `TravelStats`). A pure
/// value type computed when the recap opens — nothing is persisted and nothing
/// runs at launch.
struct WrappedFacts {
    let year: Int
    /// The year's visited countries as `(flag, name)`, alphabetical.
    let countryNames: [(flag: String, name: String)]
    let visitCount: Int
    /// Countries recorded this year that had never appeared in any earlier year.
    let newCountries: [(flag: String, name: String)]
    /// Localized names of the continents reached this year.
    let continents: [String]
    /// The month with the most recorded visits, when any visit is dated.
    let busiestMonth: (name: String, visits: Int)?
    /// The country visited most often this year, when it drew repeat visits.
    let topCountry: (flag: String, name: String, visits: Int)?
    /// Distinct countries ever visited by the end of this year.
    let lifetimeCountries: Int

    var countryCount: Int { countryNames.count }

    init(countries: [Country], stats: TravelStats, year: Int) {
        self.year = year
        self.countryNames = stats.countries(inYear: year)

        let yearIDs = stats.countryIDsByYear[year] ?? []
        let earlierIDs = stats.countryIDsByYear
            .filter { $0.key < year }
            .reduce(into: Set<String>()) { $0.formUnion($1.value) }
        self.lifetimeCountries = earlierIDs.union(yearIDs).count

        let calendar = Calendar.current
        var visitsByMonth: [Int: Int] = [:]
        var visitsByCountry: [String: Int] = [:]
        var visitCount = 0
        var newCountries: [(flag: String, name: String)] = []
        var continentNames = Set<String>()

        for country in countries {
            if yearIDs.contains(country.id) {
                continentNames.insert(
                    Continent(rawValue: country.continent)?.localizedName ?? country.continent)
                if !earlierIDs.contains(country.id) {
                    newCountries.append((country.flagEmoji, country.localizedName))
                }
            }

            for date in country.allVisitDates
            where calendar.component(.year, from: date) == year {
                visitCount += 1
                visitsByMonth[calendar.component(.month, from: date), default: 0] += 1
                visitsByCountry[country.id, default: 0] += 1
            }
        }

        self.visitCount = visitCount
        self.newCountries = newCountries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.continents = continentNames.sorted()

        // Ties break toward the earlier month so the answer is stable.
        if let busiest = visitsByMonth.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
            busiest.value > 0
        {
            self.busiestMonth = (calendar.monthSymbols[busiest.key - 1], busiest.value)
        } else {
            self.busiestMonth = nil
        }

        // Repeat visits are the story; a single visit isn't a "most visited".
        if let top = visitsByCountry.max(by: { $0.value < $1.value }), top.value >= 2,
            let country = countries.first(where: { $0.id == top.key })
        {
            self.topCountry = (country.flagEmoji, country.localizedName, top.value)
        } else {
            self.topCountry = nil
        }
    }
}

// MARK: - Wrapped view

/// The December "Wrapped": a full-screen, stories-style animated recap of one
/// year's travels. Tap (or swipe) through a handful of celebratory pages built
/// from `WrappedFacts`, ending with the on-device AI recap and the existing
/// year-in-review share card. Pages with nothing to say are skipped.
struct WrappedView: View {
    let stats: TravelStats
    let yearStat: TravelStats.YearStat
    private let facts: WrappedFacts

    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex = 0
    @State private var showShare = false

    /// Pages slide in from the trailing edge; with Reduce Motion on they
    /// crossfade in place (the per-element reveals already honor it).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The AI recap, generated eagerly on appear so it's usually ready by the
    /// time the reader taps through to its page.
    @State private var insights = TravelInsights()
    @State private var translator = AppTranslator()
    @State private var recapText: String?
    @State private var recapFailed = false

    init(countries: [Country], stats: TravelStats, year: TravelStats.YearStat) {
        self.stats = stats
        self.yearStat = year
        self.facts = WrappedFacts(countries: countries, stats: stats, year: year.year)
    }

    /// One recap page. The list is fixed per show; empty facts drop their page.
    private enum Page: Hashable {
        case cover, countries, newCountries, continents, month, topCountry, recap, finale
    }

    private var pages: [Page] {
        var pages: [Page] = [.cover, .countries]
        if !facts.newCountries.isEmpty { pages.append(.newCountries) }
        if !facts.continents.isEmpty { pages.append(.continents) }
        if facts.busiestMonth != nil { pages.append(.month) }
        if facts.topCountry != nil { pages.append(.topCountry) }
        if insights.isAvailable { pages.append(.recap) }
        pages.append(.finale)
        return pages
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .task {
                        #if DEBUG
                            // Screenshot capture: the cover page is nearly empty, so
                            // open straight onto the countries page instead.
                            if ScreenshotSupport.isCapturing(.wrapped),
                                let index = pages.firstIndex(of: .countries)
                            {
                                pageIndex = index
                            }
                        #endif
                    }

                LinearGradient(
                    colors: [.brandRoyal, Color(.displayP3, red: 0.05, green: 0.08, blue: 0.25)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                // Keyed on the page so paging swaps the whole content view,
                // letting the insertion/removal transition run.
                pageContent(pages[min(pageIndex, pages.count - 1)])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .id(pageIndex)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .contentShape(Rectangle())
            // Stories navigation: tap the left quarter to go back, anywhere
            // else to advance; swiping works in both directions too.
            .onTapGesture { location in
                if location.x < proxy.size.width * 0.25 {
                    retreat()
                } else {
                    advance()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    value.translation.width < 0 ? advance() : retreat()
                })
            // The tap zones and swipes are invisible to VoiceOver, Voice
            // Control, and Switch Control; expose paging as named actions.
            .accessibilityAction(named: Text("Next page", comment: "Accessibility action: advance the Wrapped recap")) {
                advance()
            }
            .accessibilityAction(named: Text("Previous page", comment: "Accessibility action: go back one Wrapped page")) {
                retreat()
            }
        }
        .overlay(alignment: .top) { header }
        .foregroundStyle(.white)
        .appTranslation(translator)
        .task { await generateRecap() }
        .sheet(isPresented: $showShare) {
            ShareCustomizationView(stats: stats, tints: yearTints, year: yearStat)
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 680)
        #endif
    }

    // MARK: Chrome

    /// Segmented progress bar (one capsule per page) plus the close button.
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index <= pageIndex ? 0.9 : 0.3))
                        .frame(height: 3)
                }
            }
            // The capsules are a visual progress strip; read it as one element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    "Page \(pageIndex + 1) of \(pages.count)",
                    comment: "Accessibility: position within the Wrapped recap"))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close", comment: "Accessibility: close the Wrapped recap"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func advance() {
        guard pageIndex < pages.count - 1 else { return }
        withAnimation(.spring(duration: 0.5)) { pageIndex += 1 }
    }

    private func retreat() {
        guard pageIndex > 0 else { return }
        withAnimation(.spring(duration: 0.5)) { pageIndex -= 1 }
    }

    /// Map tints restricted to this year's countries, so the share card
    /// highlights the year rather than the all-time footprint.
    private var yearTints: [String: Int] {
        let ids = stats.countryIDsByYear[facts.year] ?? []
        return stats.statusTints.filter { ids.contains($0.key) }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        switch page {
        case .cover: coverPage
        case .countries: countriesPage
        case .newCountries: newCountriesPage
        case .continents: continentsPage
        case .month: monthPage
        case .topCountry: topCountryPage
        case .recap: recapPage
        case .finale: finalePage
        }
    }

    private var coverPage: some View {
        VStack(spacing: 16) {
            Text("🌍")
                .font(.system(size: 72))
                .wrappedReveal(delay: 0)
            Text(String(facts.year))
                .font(.system(size: 88, weight: .heavy, design: .rounded))
                .wrappedReveal(delay: 0.2)
            Text("Your year in travel", comment: "Wrapped cover page subtitle")
                .font(.title3.weight(.semibold))
                .opacity(0.85)
                .wrappedReveal(delay: 0.4)
            Text("Tap to begin", comment: "Wrapped cover page hint")
                .font(.footnote)
                .opacity(0.6)
                .padding(.top, 24)
                .wrappedReveal(delay: 1.0)
        }
    }

    private var countriesPage: some View {
        VStack(spacing: 16) {
            Text("You visited", comment: "Wrapped: overline above the year's country count")
                .font(.title3.weight(.semibold))
                .opacity(0.85)
                .wrappedReveal(delay: 0)
            CountUpText(value: facts.countryCount)
                .wrappedReveal(delay: 0.2)
            Text(
                facts.countryCount == 1
                    ? String(localized: "country", comment: "Wrapped: singular country word")
                    : String(localized: "countries", comment: "Wrapped: plural countries word")
            )
            .font(.title2.weight(.bold))
            .wrappedReveal(delay: 0.3)
            Text(facts.countryNames.map(\.flag).joined(separator: " "))
                .font(.title)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .padding(.top, 12)
                .wrappedReveal(delay: 0.7)
        }
    }

    private var newCountriesPage: some View {
        VStack(spacing: 16) {
            CountUpText(value: facts.newCountries.count)
                .wrappedReveal(delay: 0)
            Text(
                facts.newCountries.count == 1
                    ? String(
                        localized: "country for the very first time",
                        comment: "Wrapped: below the count of first-ever countries, singular")
                    : String(
                        localized: "countries for the very first time",
                        comment: "Wrapped: below the count of first-ever countries, plural")
            )
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .wrappedReveal(delay: 0.3)
            VStack(spacing: 6) {
                ForEach(facts.newCountries.prefix(6), id: \.name) { country in
                    Text("\(country.flag) \(country.name)")
                        .font(.headline)
                }
                if facts.newCountries.count > 6 {
                    Text(
                        "…and \(facts.newCountries.count - 6) more",
                        comment: "Wrapped: overflow line under the new-countries list"
                    )
                    .font(.subheadline)
                    .opacity(0.7)
                }
            }
            .padding(.top, 12)
            .wrappedReveal(delay: 0.7)
        }
    }

    private var continentsPage: some View {
        VStack(spacing: 16) {
            Text(
                "Your travels spanned",
                comment: "Wrapped: overline above the year's continent count"
            )
            .font(.title3.weight(.semibold))
            .opacity(0.85)
            .wrappedReveal(delay: 0)
            CountUpText(value: facts.continents.count)
                .wrappedReveal(delay: 0.2)
            Text(
                facts.continents.count == 1
                    ? String(localized: "continent", comment: "Wrapped: singular continent word")
                    : String(localized: "continents", comment: "Wrapped: plural continents word")
            )
            .font(.title2.weight(.bold))
            .wrappedReveal(delay: 0.3)
            Text(facts.continents.joined(separator: " · "))
                .font(.headline)
                .multilineTextAlignment(.center)
                .opacity(0.85)
                .padding(.top, 12)
                .wrappedReveal(delay: 0.7)
        }
    }

    @ViewBuilder private var monthPage: some View {
        if let month = facts.busiestMonth {
            VStack(spacing: 16) {
                Text("Your busiest month was", comment: "Wrapped: overline above the month name")
                    .font(.title3.weight(.semibold))
                    .opacity(0.85)
                    .wrappedReveal(delay: 0)
                Text(month.name)
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .wrappedReveal(delay: 0.3)
                Text(
                    month.visits == 1
                        ? String(
                            localized: "1 recorded visit",
                            comment: "Wrapped: visit count under the busiest month, singular")
                        : String(
                            localized: "\(month.visits) recorded visits",
                            comment: "Wrapped: visit count under the busiest month, plural")
                )
                .font(.title3.weight(.semibold))
                .opacity(0.85)
                .wrappedReveal(delay: 0.6)
            }
        }
    }

    @ViewBuilder private var topCountryPage: some View {
        if let top = facts.topCountry {
            VStack(spacing: 16) {
                Text("You kept coming back to", comment: "Wrapped: overline above the top country")
                    .font(.title3.weight(.semibold))
                    .opacity(0.85)
                    .wrappedReveal(delay: 0)
                Text(top.flag)
                    .font(.system(size: 88))
                    .wrappedReveal(delay: 0.3)
                Text(top.name)
                    .font(.largeTitle.weight(.heavy))
                    .multilineTextAlignment(.center)
                    .wrappedReveal(delay: 0.4)
                Text(
                    "\(top.visits) visits this year",
                    comment: "Wrapped: visit count under the most-visited country"
                )
                .font(.title3.weight(.semibold))
                .opacity(0.85)
                .wrappedReveal(delay: 0.7)
            }
        }
    }

    private var recapPage: some View {
        VStack(spacing: 20) {
            Text("✨")
                .font(.system(size: 56))
                .wrappedReveal(delay: 0)
            Text("Your year, in words", comment: "Wrapped: header of the AI recap page")
                .font(.title2.weight(.bold))
                .wrappedReveal(delay: 0.2)
            Group {
                if let recapText {
                    Text(recapText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                } else if recapFailed {
                    Text(fallbackRecap)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 12)
                }
            }
            .wrappedReveal(delay: 0.4)
        }
    }

    private var finalePage: some View {
        VStack(spacing: 20) {
            Text("That's a wrap on \(String(facts.year))", comment: "Wrapped: finale headline")
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
                .wrappedReveal(delay: 0)
            Text(
                facts.lifetimeCountries == 1
                    ? String(
                        localized: "1 country and counting — see you out there.",
                        comment: "Wrapped: finale line with the lifetime country total, singular")
                    : String(
                        localized:
                            "\(facts.lifetimeCountries) countries and counting — see you out there.",
                        comment: "Wrapped: finale line with the lifetime country total, plural")
            )
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .opacity(0.85)
            .wrappedReveal(delay: 0.3)

            VStack(spacing: 12) {
                Button {
                    showShare = true
                } label: {
                    Label(
                        String(localized: "Share This Year", comment: "Wrapped: share button"),
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
            .wrappedReveal(delay: 0.7)
        }
    }

    // MARK: AI recap

    /// Generates the year recap through the on-device model, then translates it
    /// into the device language. Failures fall back to `fallbackRecap`.
    private func generateRecap() async {
        guard insights.isAvailable, recapText == nil else { return }
        #if DEBUG
            // Screenshot capture: translating the recap raises the system Translate sheet,
            // which the simulator can't serve (it shows an error over the page).
            if ScreenshotSupport.isActive { return }
        #endif
        do {
            let names = facts.countryNames.prefix(30).map { "\($0.flag) \($0.name)" }
            let recap = try await insights.yearInReview(
                year: facts.year, countries: Array(names), visits: facts.visitCount)
            recapText = await translator.translate(recap)
        } catch {
            recapFailed = true
        }
    }

    /// A plain, locally-built recap shown if generation fails mid-show.
    private var fallbackRecap: String {
        let countryWord =
            facts.countryCount == 1
            ? String(localized: "country", comment: "Wrapped: singular country word")
            : String(localized: "countries", comment: "Wrapped: plural countries word")
        return String(
            localized: "What a year — \(facts.countryCount) \(countryWord) explored in \(String(facts.year)).",
            comment: "Wrapped: static recap shown when AI generation fails")
    }
}

extension View {
    /// Presents the Wrapped recap immersively: a full-screen cover on iOS, or a
    /// large sheet on macOS (which has no full-screen cover).
    func wrappedCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        #if os(macOS)
            sheet(item: item, content: content)
        #else
            fullScreenCover(item: item, content: content)
        #endif
    }
}

// MARK: - Animation helpers

/// Fades and floats content in once, after `delay` — the staged entrance every
/// Wrapped page is built from. Honors Reduce Motion by appearing instantly.
private struct WrappedReveal: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(duration: 0.7).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    fileprivate func wrappedReveal(delay: Double) -> some View {
        modifier(WrappedReveal(delay: delay))
    }
}

/// A big rolling-digits counter that animates from 0 to `value` on appear.
private struct CountUpText: View {
    let value: Int
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("\(shown)")
            .font(.system(size: 96, weight: .heavy, design: .rounded))
            .contentTransition(.numericText(value: Double(shown)))
            .monospacedDigit()
            .onAppear {
                if reduceMotion {
                    shown = value
                } else {
                    withAnimation(.spring(duration: 1.2).delay(0.3)) { shown = value }
                }
            }
    }
}
