/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The seven canonical continents, as a typed enum. Replaces raw string constants
/// throughout the codebase so continent comparisons and lookups are type-safe.
enum Continent: String, CaseIterable, Identifiable, Codable {
    case europe = "Europe"
    case asia = "Asia"
    case africa = "Africa"
    case northAmerica = "North America"
    case southAmerica = "South America"
    case australiaOceania = "Australia and Oceania"
    case antarctica = "Antarctica"

    var id: String { rawValue }

    /// The continent name in the user's language. Continent names mostly flow
    /// through `String`-typed view parameters (which SwiftUI renders verbatim,
    /// with no catalog lookup), so localization needs this explicit dynamic
    /// lookup; the raw English value is the catalog key.
    var localizedName: String {
        String(localized: String.LocalizationValue(rawValue))
    }
}

/// Authoritative ISO 3166-1 alpha-2 → continent lookup, in English.
///
/// The bundled GeoJSON only carries ISO codes and country names — it has no
/// continent field — so the continent is derived from the country code here.
/// This covers every country in `countries.geojson`, which is why no record
/// is left without a continent.
enum Continents {
    nonisolated static let unknown = "Unknown"

    /// Looks up the English continent name for an ISO alpha-2 code,
    /// returning `Unknown` for codes that are not recognised.
    /// `nonisolated` so the background seeding task can call it.
    nonisolated static func name(for isoAlpha2: String) -> String {
        byISO[isoAlpha2] ?? unknown
    }

    /// The typed `Continent` for a given ISO alpha-2 code, if recognised.
    nonisolated static func typed(for isoAlpha2: String) -> Continent? {
        byISO[isoAlpha2].flatMap(Continent.init(rawValue:))
    }

    nonisolated static let byISO: [String: String] = [
        // Europe (52)
        "AD": "Europe", "AL": "Europe", "AT": "Europe", "AX": "Europe",
        "BA": "Europe", "BE": "Europe", "BG": "Europe", "BY": "Europe",
        "CH": "Europe", "CY": "Europe", "CZ": "Europe", "DE": "Europe",
        "DK": "Europe", "EE": "Europe", "ES": "Europe", "FI": "Europe",
        "FR": "Europe", "NO": "Europe",
        "FO": "Europe", "GB": "Europe", "GG": "Europe", "GI": "Europe", "GL": "Europe",
        "GR": "Europe", "HR": "Europe", "HU": "Europe", "IE": "Europe",
        "IM": "Europe", "IS": "Europe", "IT": "Europe", "JE": "Europe",
        "LI": "Europe", "LT": "Europe", "LU": "Europe", "LV": "Europe",
        "MC": "Europe", "MD": "Europe", "ME": "Europe", "MK": "Europe",
        "MT": "Europe", "NL": "Europe", "PL": "Europe", "PT": "Europe",
        "RO": "Europe", "RS": "Europe", "SE": "Europe", "SI": "Europe",
        "SK": "Europe", "SM": "Europe", "UA": "Europe", "VA": "Europe",
        // Asia (52)
        "AE": "Asia", "AF": "Asia", "AM": "Asia",
        "AZ": "Asia", "BD": "Asia", "BH": "Asia", "BN": "Asia",
        "BT": "Asia", "CN": "Asia", "GE": "Asia",
        "HK": "Asia", "ID": "Asia", "IL": "Asia", "IN": "Asia",
        "IO": "Asia", "IQ": "Asia", "IR": "Asia", "JO": "Asia",
        "JP": "Asia", "KG": "Asia", "KH": "Asia", "KP": "Asia",
        "KR": "Asia", "KW": "Asia", "KZ": "Asia", "LA": "Asia",
        "LB": "Asia", "LK": "Asia", "MM": "Asia", "MN": "Asia",
        "MO": "Asia", "MV": "Asia", "MY": "Asia", "NP": "Asia",
        "OM": "Asia", "PH": "Asia", "PK": "Asia", "PS": "Asia",
        "QA": "Asia", "RU": "Asia", "SA": "Asia", "SG": "Asia",
        "SY": "Asia", "TH": "Asia", "TJ": "Asia", "TL": "Asia",
        "TM": "Asia", "TR": "Asia", "TW": "Asia", "UZ": "Asia",
        "VN": "Asia", "YE": "Asia",
        // Africa (56)
        "AO": "Africa", "BF": "Africa", "BI": "Africa", "BJ": "Africa",
        "BW": "Africa", "CD": "Africa", "CF": "Africa", "CG": "Africa",
        "CI": "Africa", "CM": "Africa", "CV": "Africa", "DJ": "Africa",
        "DZ": "Africa", "EG": "Africa", "EH": "Africa", "ER": "Africa",
        "ET": "Africa", "GA": "Africa", "GH": "Africa", "GM": "Africa",
        "GN": "Africa", "GQ": "Africa", "GW": "Africa", "KE": "Africa",
        "KM": "Africa", "LR": "Africa", "LS": "Africa", "LY": "Africa",
        "MA": "Africa", "MG": "Africa", "ML": "Africa", "MR": "Africa",
        "MU": "Africa", "MW": "Africa", "MZ": "Africa", "NA": "Africa",
        "NE": "Africa", "NG": "Africa", "RW": "Africa", "SC": "Africa",
        "SD": "Africa", "SH": "Africa", "SL": "Africa", "SN": "Africa",
        "SO": "Africa", "SS": "Africa", "ST": "Africa", "SZ": "Africa",
        "TD": "Africa", "TG": "Africa", "TN": "Africa", "TZ": "Africa",
        "UG": "Africa", "ZA": "Africa", "ZM": "Africa", "ZW": "Africa",
        // North America (37)
        "AG": "North America", "AI": "North America", "AW": "North America", "BB": "North America",
        "BL": "North America", "BM": "North America", "BS": "North America", "BZ": "North America",
        "CA": "North America", "CR": "North America", "CU": "North America", "CW": "North America",
        "DM": "North America", "DO": "North America", "GD": "North America",
        "GT": "North America", "HN": "North America", "HT": "North America", "JM": "North America",
        "KN": "North America", "KY": "North America", "LC": "North America", "MF": "North America",
        "MS": "North America", "MX": "North America", "NI": "North America", "PA": "North America",
        "PM": "North America", "PR": "North America", "SV": "North America", "SX": "North America",
        "TC": "North America", "TT": "North America", "US": "North America", "VC": "North America",
        "VG": "North America", "VI": "North America",
        // South America (13)
        "AR": "South America", "BO": "South America", "BR": "South America", "CL": "South America",
        "CO": "South America", "EC": "South America", "FK": "South America", "GY": "South America",
        "PE": "South America", "PY": "South America", "SR": "South America", "UY": "South America",
        "VE": "South America",
        // Australia and Oceania (25)
        "AS": "Australia and Oceania", "AU": "Australia and Oceania", "CK": "Australia and Oceania",
        "FJ": "Australia and Oceania",
        "FM": "Australia and Oceania", "GU": "Australia and Oceania", "KI": "Australia and Oceania",
        "MH": "Australia and Oceania",
        "MP": "Australia and Oceania", "NC": "Australia and Oceania", "NF": "Australia and Oceania",
        "NR": "Australia and Oceania",
        "NU": "Australia and Oceania", "NZ": "Australia and Oceania", "PF": "Australia and Oceania",
        "PG": "Australia and Oceania",
        "PN": "Australia and Oceania", "PW": "Australia and Oceania", "SB": "Australia and Oceania",
        "TO": "Australia and Oceania",
        "TV": "Australia and Oceania", "UM": "Australia and Oceania", "VU": "Australia and Oceania",
        "WF": "Australia and Oceania",
        "WS": "Australia and Oceania",
        // Antarctica (1)
        // Only the continent itself. Natural Earth also ships three sub-antarctic
        // territories here (South Georgia, Heard Island, French Southern Lands);
        // they're intentionally omitted so Antarctica reads as one country on one
        // continent. Dropping them from this table also removes them from the
        // catalog — `seedDatabase` skips ids absent here, and `reconcileDatabase`
        // deletes any an older build already stored.
        "AQ": "Antarctica",
        // Fallback alpha-2 codes for records the dataset ships with `-99`.
        "XK": "Europe",  // Kosovo
        "CP": "Australia and Oceania",  // Clipperton Island
    ]
}
