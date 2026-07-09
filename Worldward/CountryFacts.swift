/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Types

/// Which side of the road traffic drives on.
enum DrivingSide: String, Sendable, CaseIterable, Codable {
    case left = "left"
    case right = "right"

    var label: String {
        switch self {
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        }
    }

    /// A compact prompt fragment for the AI assistant.
    var promptHint: String {
        switch self {
        case .left: "drives on the left"
        case .right: "drives on the right"
        }
    }
}

/// A concise bundle of static, offline facts about a country — currency, languages,
/// plug types, driving side, and emergency number. Every property is `Sendable` so
/// the dictionary can be read from any actor without copying.
struct CountryFacts: Sendable, Equatable {
    /// Local currency name with ISO 4217 code, e.g. "Euro (EUR)".
    var currency: String
    /// Official or major languages spoken.
    var languages: [String]
    /// IEC plug types used, e.g. `["E", "F"]`.
    var plugTypes: [String]
    /// Which side of the road to drive on.
    var drivingSide: DrivingSide
    /// National emergency telephone number.
    var emergencyNumber: String
}

// MARK: - Database

/// Bundled offline lookup table of country facts, keyed by ISO 3166-1 alpha-2 code.
/// Every key in `Continents.byISO` has a corresponding entry here.
///
/// The dictionary is `nonisolated` so it can be read from background contexts
/// (seeding, AI prompt building) without actor hops.
enum CountryFactsDB {
    /// Looks up facts for a given ISO alpha-2 code, or `nil` if not recognised.
    nonisolated static func facts(for isoAlpha2: String) -> CountryFacts? {
        byISO[isoAlpha2]
    }

    /// All country facts keyed by ISO alpha-2.
    nonisolated static let byISO: [String: CountryFacts] = {
        var db: [String: CountryFacts] = [:]
        for entry in allEntries {
            db[entry.0] = entry.1
        }
        return db
    }()

    /// Flat list so the compiler can type-check manageable chunks.
    /// Organised by continent, mirroring `Continents.byISO`.
    private nonisolated static let allEntries: [(String, CountryFacts)] =

        // MARK: - Europe

        entry("AD", "Euro (EUR)", ["Catalan"], ["C", "F"], .right, "112")
        + entry("AL", "Albanian lek (ALL)", ["Albanian"], ["C", "F"], .right, "112")
        + entry("AT", "Euro (EUR)", ["German"], ["C", "F"], .right, "112")
        + entry("AX", "Euro (EUR)", ["Swedish"], ["C", "F"], .right, "112")
        + entry("BA", "Bosnia and Herzegovina convertible mark (BAM)", ["Bosnian", "Croatian", "Serbian"], ["C", "F"], .right, "112")
        + entry("BE", "Euro (EUR)", ["Dutch", "French", "German"], ["C", "E"], .right, "112")
        + entry("BG", "Bulgarian lev (BGN)", ["Bulgarian"], ["C", "F"], .right, "112")
        + entry("BY", "Belarusian ruble (BYN)", ["Belarusian", "Russian"], ["C", "F"], .right, "112")
        + entry("CH", "Swiss franc (CHF)", ["German", "French", "Italian", "Romansh"], ["C", "J"], .right, "112")
        + entry("CY", "Euro (EUR)", ["Greek", "Turkish"], ["C", "G"], .left, "112")
        + entry("CZ", "Czech koruna (CZK)", ["Czech"], ["C", "E"], .right, "112")
        + entry("DE", "Euro (EUR)", ["German"], ["C", "F"], .right, "112")
        + entry("DK", "Danish krone (DKK)", ["Danish"], ["C", "E", "F", "K"], .right, "112")
        + entry("EE", "Euro (EUR)", ["Estonian"], ["C", "F"], .right, "112")
        + entry("ES", "Euro (EUR)", ["Spanish", "Catalan", "Galician", "Basque"], ["C", "F"], .right, "112")
        + entry("FI", "Euro (EUR)", ["Finnish", "Swedish"], ["C", "F"], .right, "112")
        + entry("FR", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")
        + entry("FO", "Faroese króna (FOK)", ["Faroese", "Danish"], ["C", "E", "F", "K"], .right, "112")
        + entry("GB", "Pound sterling (GBP)", ["English", "Welsh", "Scottish Gaelic"], ["C", "G"], .left, "999")
        + entry("GG", "Pound sterling (GBP)", ["English"], ["C", "G"], .left, "999")
        + entry("GI", "Gibraltar pound (GIP)", ["English"], ["C", "G"], .right, "112")
        + entry("GL", "Danish krone (DKK)", ["Greenlandic", "Danish"], ["C", "E", "F", "K"], .right, "112")
        + entry("GR", "Euro (EUR)", ["Greek"], ["C", "F"], .right, "112")
        + entry("HR", "Euro (EUR)", ["Croatian"], ["C", "F"], .right, "112")
        + entry("HU", "Hungarian forint (HUF)", ["Hungarian"], ["C", "F"], .right, "112")
        + entry("IE", "Euro (EUR)", ["Irish", "English"], ["C", "G"], .left, "112")
        + entry("IM", "Pound sterling (GBP)", ["English", "Manx"], ["C", "G"], .left, "999")
        + entry("IS", "Icelandic króna (ISK)", ["Icelandic"], ["C", "F"], .right, "112")
        + entry("IT", "Euro (EUR)", ["Italian"], ["C", "F", "L"], .right, "112")
        + entry("JE", "Pound sterling (GBP)", ["English", "Jèrriais"], ["C", "G"], .left, "999")
        + entry("LI", "Swiss franc (CHF)", ["German"], ["C", "J"], .right, "112")
        + entry("LT", "Euro (EUR)", ["Lithuanian"], ["C", "F"], .right, "112")
        + entry("LU", "Euro (EUR)", ["Luxembourgish", "French", "German"], ["C", "F"], .right, "112")
        + entry("LV", "Euro (EUR)", ["Latvian"], ["C", "F"], .right, "112")
        + entry("MC", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")
        + entry("MD", "Moldovan leu (MDL)", ["Romanian"], ["C", "F"], .right, "112")
        + entry("ME", "Euro (EUR)", ["Montenegrin"], ["C", "F"], .right, "112")
        + entry("MK", "Macedonian denar (MKD)", ["Macedonian"], ["C", "F"], .right, "112")
        + entry("MT", "Euro (EUR)", ["Maltese", "English"], ["C", "G"], .left, "112")
        + entry("NL", "Euro (EUR)", ["Dutch"], ["C", "F"], .right, "112")
        + entry("NO", "Norwegian krone (NOK)", ["Norwegian"], ["C", "F"], .right, "112")
        + entry("PL", "Polish złoty (PLN)", ["Polish"], ["C", "E"], .right, "112")
        + entry("PT", "Euro (EUR)", ["Portuguese"], ["C", "F"], .right, "112")
        + entry("RO", "Romanian leu (RON)", ["Romanian"], ["C", "F"], .right, "112")
        + entry("RS", "Serbian dinar (RSD)", ["Serbian"], ["C", "F"], .right, "112")
        + entry("SE", "Swedish krona (SEK)", ["Swedish"], ["C", "F"], .right, "112")
        + entry("SI", "Euro (EUR)", ["Slovene"], ["C", "F"], .right, "112")
        + entry("SK", "Euro (EUR)", ["Slovak"], ["C", "E"], .right, "112")
        + entry("SM", "Euro (EUR)", ["Italian"], ["C", "F", "L"], .right, "112")
        + entry("UA", "Ukrainian hryvnia (UAH)", ["Ukrainian"], ["C", "F"], .right, "112")
        + entry("VA", "Euro (EUR)", ["Italian", "Latin"], ["C", "F", "L"], .right, "112")
        + entry("XK", "Euro (EUR)", ["Albanian", "Serbian"], ["C", "F"], .right, "112")

        // MARK: - Asia

        + entry("AE", "UAE dirham (AED)", ["Arabic"], ["C", "G"], .right, "998")
        + entry("AF", "Afghan afghani (AFN)", ["Pashto", "Dari"], ["C", "D"], .right, "112")
        + entry("AM", "Armenian dram (AMD)", ["Armenian"], ["C", "F"], .right, "112")
        + entry("AZ", "Azerbaijani manat (AZN)", ["Azerbaijani"], ["C", "F"], .right, "112")
        + entry("BD", "Bangladeshi taka (BDT)", ["Bengali"], ["A", "C", "D"], .left, "999")
        + entry("BH", "Bahraini dinar (BHD)", ["Arabic"], ["C", "G"], .right, "999")
        + entry("BN", "Brunei dollar (BND)", ["Malay"], ["C", "G"], .left, "991")
        + entry("BT", "Bhutanese ngultrum (BTN)", ["Dzongkha"], ["C", "D", "G"], .left, "112")
        + entry("CN", "Chinese yuan (CNY)", ["Mandarin Chinese"], ["A", "C", "I"], .right, "110")
        + entry("GE", "Georgian lari (GEL)", ["Georgian"], ["C", "F"], .right, "112")
        + entry("HK", "Hong Kong dollar (HKD)", ["Chinese", "English"], ["C", "G"], .left, "999")
        + entry("ID", "Indonesian rupiah (IDR)", ["Indonesian"], ["A", "C", "F", "G"], .left, "112")
        + entry("IL", "Israeli new shekel (ILS)", ["Hebrew", "Arabic"], ["C", "H"], .right, "100")
        + entry("IN", "Indian rupee (INR)", ["Hindi", "English"], ["C", "D", "M"], .left, "112")
        + entry("IO", "United States dollar (USD)", ["English"], ["C", "G"], .right, "999")
        + entry("IQ", "Iraqi dinar (IQD)", ["Arabic", "Kurdish"], ["C", "D", "G"], .right, "112")
        + entry("IR", "Iranian rial (IRR)", ["Persian"], ["C", "F"], .right, "110")
        + entry("JO", "Jordanian dinar (JOD)", ["Arabic"], ["C", "D", "F", "G"], .right, "911")
        + entry("JP", "Japanese yen (JPY)", ["Japanese"], ["A", "B"], .left, "110")
        + entry("KG", "Kyrgyz som (KGS)", ["Kyrgyz", "Russian"], ["C", "F"], .right, "112")
        + entry("KH", "Cambodian riel (KHR)", ["Khmer"], ["A", "C", "G"], .right, "117")
        + entry("KP", "North Korean won (KPW)", ["Korean"], ["C"], .right, "112")
        + entry("KR", "South Korean won (KRW)", ["Korean"], ["C", "F"], .right, "112")
        + entry("KW", "Kuwaiti dinar (KWD)", ["Arabic"], ["C", "G"], .right, "112")
        + entry("KZ", "Kazakhstani tenge (KZT)", ["Kazakh", "Russian"], ["C", "F"], .right, "112")
        + entry("LA", "Lao kip (LAK)", ["Lao"], ["A", "B", "C", "F"], .right, "1190")
        + entry("LB", "Lebanese pound (LBP)", ["Arabic"], ["A", "B", "C", "D", "G"], .right, "112")
        + entry("LK", "Sri Lankan rupee (LKR)", ["Sinhala", "Tamil"], ["C", "D", "G"], .left, "119")
        + entry("MM", "Myanmar kyat (MMK)", ["Burmese"], ["A", "C", "D", "F", "G"], .right, "999")
        + entry("MN", "Mongolian tögrög (MNT)", ["Mongolian"], ["C", "E"], .right, "112")
        + entry("MO", "Macanese pataca (MOP)", ["Chinese", "Portuguese"], ["C", "F"], .left, "999")
        + entry("MV", "Maldivian rufiyaa (MVR)", ["Dhivehi"], ["C", "D", "G", "J", "K", "L"], .left, "112")
        + entry("MY", "Malaysian ringgit (MYR)", ["Malay"], ["C", "G"], .left, "999")
        + entry("NP", "Nepalese rupee (NPR)", ["Nepali"], ["C", "D", "M"], .left, "112")
        + entry("OM", "Omani rial (OMR)", ["Arabic"], ["C", "G"], .right, "9999")
        + entry("PH", "Philippine peso (PHP)", ["Filipino", "English"], ["A", "B", "C"], .right, "911")
        + entry("PK", "Pakistani rupee (PKR)", ["Urdu", "English"], ["C", "D"], .left, "1122")
        + entry("PS", "Israeli new shekel (ILS)", ["Arabic"], ["C", "H"], .right, "100")
        + entry("QA", "Qatari riyal (QAR)", ["Arabic"], ["C", "G"], .right, "999")
        + entry("RU", "Russian ruble (RUB)", ["Russian"], ["C", "F"], .right, "112")
        + entry("SA", "Saudi riyal (SAR)", ["Arabic"], ["A", "B", "C", "G"], .right, "911")
        + entry("SG", "Singapore dollar (SGD)", ["English", "Chinese", "Malay", "Tamil"], ["C", "G"], .left, "999")
        + entry("SY", "Syrian pound (SYP)", ["Arabic"], ["C", "E", "F", "L"], .right, "112")
        + entry("TH", "Thai baht (THB)", ["Thai"], ["A", "B", "C", "O"], .left, "191")
        + entry("TJ", "Tajikistani somoni (TJS)", ["Tajik"], ["C", "F"], .right, "112")
        + entry("TL", "United States dollar (USD)", ["Tetum", "Portuguese"], ["C", "E", "F", "I"], .right, "112")
        + entry("TM", "Turkmenistani manat (TMT)", ["Turkmen"], ["B", "C", "F"], .right, "112")
        + entry("TR", "Turkish lira (TRY)", ["Turkish"], ["C", "F"], .right, "112")
        + entry("TW", "New Taiwan dollar (TWD)", ["Mandarin Chinese"], ["A", "B"], .right, "112")
        + entry("UZ", "Uzbekistani soʻm (UZS)", ["Uzbek"], ["C", "F"], .right, "112")
        + entry("VN", "Vietnamese đồng (VND)", ["Vietnamese"], ["A", "B", "C"], .right, "113")
        + entry("YE", "Yemeni rial (YER)", ["Arabic"], ["A", "D", "G"], .right, "112")

        // MARK: - Africa

        + entry("AO", "Angolan kwanza (AOA)", ["Portuguese"], ["C", "F"], .right, "113")
        + entry("BF", "West African CFA franc (XOF)", ["French"], ["C", "E"], .right, "112")
        + entry("BI", "Burundian franc (BIF)", ["Kirundi", "French", "English"], ["C", "E"], .right, "112")
        + entry("BJ", "West African CFA franc (XOF)", ["French"], ["C", "E"], .right, "112")
        + entry("BW", "Botswana pula (BWP)", ["English", "Tswana"], ["C", "D", "G", "M"], .left, "911")
        + entry("CD", "Congolese franc (CDF)", ["French"], ["C", "E"], .right, "112")
        + entry("CF", "Central African CFA franc (XAF)", ["French", "Sango"], ["C", "E"], .right, "112")
        + entry("CG", "Central African CFA franc (XAF)", ["French"], ["C", "E"], .right, "112")
        + entry("CI", "West African CFA franc (XOF)", ["French"], ["C", "E"], .right, "112")
        + entry("CM", "Central African CFA franc (XAF)", ["French", "English"], ["C", "E"], .right, "112")
        + entry("CV", "Cape Verdean escudo (CVE)", ["Portuguese"], ["C", "F"], .right, "112")
        + entry("DJ", "Djiboutian franc (DJF)", ["Arabic", "French"], ["C", "E"], .right, "112")
        + entry("DZ", "Algerian dinar (DZD)", ["Arabic", "Berber"], ["C", "F"], .right, "112")
        + entry("EG", "Egyptian pound (EGP)", ["Arabic"], ["C", "F"], .right, "122")
        + entry("EH", "Moroccan dirham (MAD)", ["Arabic", "Spanish"], ["C", "F"], .right, "112")
        + entry("ER", "Eritrean nakfa (ERN)", ["Tigrinya", "Arabic", "English"], ["C"], .right, "112")
        + entry("ET", "Ethiopian birr (ETB)", ["Amharic"], ["C", "F", "G"], .right, "911")
        + entry("GA", "Central African CFA franc (XAF)", ["French"], ["C"], .right, "112")
        + entry("GH", "Ghanaian cedi (GHS)", ["English"], ["C", "D", "G"], .right, "112")
        + entry("GM", "Gambian dalasi (GMD)", ["English"], ["C", "G"], .right, "112")
        + entry("GN", "Guinean franc (GNF)", ["French"], ["C", "F", "K"], .right, "112")
        + entry("GQ", "Central African CFA franc (XAF)", ["Spanish", "French", "Portuguese"], ["C", "E"], .right, "112")
        + entry("GW", "West African CFA franc (XOF)", ["Portuguese"], ["C", "E", "F"], .right, "112")
        + entry("KE", "Kenyan shilling (KES)", ["Swahili", "English"], ["C", "G"], .left, "112")
        + entry("KM", "Comorian franc (KMF)", ["Comorian", "Arabic", "French"], ["C", "E"], .right, "112")
        + entry("LR", "Liberian dollar (LRD)", ["English"], ["A", "B"], .right, "911")
        + entry("LS", "Lesotho loti (LSL)", ["Sesotho", "English"], ["C", "G", "M"], .left, "112")
        + entry("LY", "Libyan dinar (LYD)", ["Arabic"], ["C", "F", "L"], .right, "112")
        + entry("MA", "Moroccan dirham (MAD)", ["Arabic", "Berber"], ["C", "E"], .right, "112")
        + entry("MG", "Malagasy ariary (MGA)", ["Malagasy", "French"], ["C", "D", "E", "F", "J", "K"], .right, "112")
        + entry("ML", "West African CFA franc (XOF)", ["French"], ["C", "E"], .right, "112")
        + entry("MR", "Mauritanian ouguiya (MRU)", ["Arabic"], ["C"], .right, "112")
        + entry("MU", "Mauritian rupee (MUR)", ["English", "French"], ["C", "G"], .left, "112")
        + entry("MW", "Malawian kwacha (MWK)", ["English", "Chichewa"], ["C", "G"], .left, "112")
        + entry("MZ", "Mozambican metical (MZN)", ["Portuguese"], ["C", "F", "M"], .left, "112")
        + entry("NA", "Namibian dollar (NAD)", ["English"], ["C", "D", "G", "M"], .left, "112")
        + entry("NE", "West African CFA franc (XOF)", ["French"], ["C", "E", "F"], .right, "112")
        + entry("NG", "Nigerian naira (NGN)", ["English"], ["C", "D", "G"], .right, "112")
        + entry("RW", "Rwandan franc (RWF)", ["Kinyarwanda", "French", "English"], ["C", "E", "J"], .right, "112")
        + entry("SC", "Seychellois rupee (SCR)", ["Seychellois Creole", "English", "French"], ["C", "G"], .left, "112")
        + entry("SD", "Sudanese pound (SDG)", ["Arabic", "English"], ["C", "D"], .right, "999")
        + entry("SH", "Saint Helena pound (SHP)", ["English"], ["C", "G"], .left, "999")
        + entry("SL", "Sierra Leonean leone (SLL)", ["English"], ["C", "D", "G"], .right, "112")
        + entry("SN", "West African CFA franc (XOF)", ["French"], ["C", "D", "E", "K"], .right, "112")
        + entry("SO", "Somali shilling (SOS)", ["Somali", "Arabic"], ["C"], .right, "112")
        + entry("SS", "South Sudanese pound (SSP)", ["English"], ["C", "D"], .right, "112")
        + entry("ST", "São Tomé and Príncipe dobra (STN)", ["Portuguese"], ["C", "F"], .right, "112")
        + entry("SZ", "Swazi lilangeni (SZL)", ["Swazi", "English"], ["C", "G", "M"], .left, "112")
        + entry("TD", "Central African CFA franc (XAF)", ["French", "Arabic"], ["C", "D", "E", "F"], .right, "112")
        + entry("TG", "West African CFA franc (XOF)", ["French"], ["C"], .right, "112")
        + entry("TN", "Tunisian dinar (TND)", ["Arabic"], ["C", "E"], .right, "112")
        + entry("TZ", "Tanzanian shilling (TZS)", ["Swahili", "English"], ["C", "D", "G"], .left, "112")
        + entry("UG", "Ugandan shilling (UGX)", ["English", "Swahili"], ["C", "G"], .left, "112")
        + entry("ZA", "South African rand (ZAR)", ["Afrikaans", "English", "Zulu", "Xhosa", "Southern Sotho", "Tswana", "Tsonga", "Swazi", "Venda", "Southern Ndebele"], ["C", "D", "G", "M"], .left, "112")
        + entry("ZM", "Zambian kwacha (ZMW)", ["English"], ["C", "D", "G"], .left, "112")
        + entry("ZW", "United States dollar (USD)", ["English", "Shona", "Southern Ndebele"], ["C", "D", "F", "G"], .left, "112")

        // MARK: - North America

        + entry("AG", "East Caribbean dollar (XCD)", ["English"], ["A", "B"], .left, "911")
        + entry("AI", "East Caribbean dollar (XCD)", ["English"], ["A", "B"], .left, "911")
        + entry("AW", "Aruban florin (AWG)", ["Dutch", "Papiamento"], ["A", "B", "F"], .right, "911")
        + entry("BB", "Barbadian dollar (BBD)", ["English"], ["A", "B"], .left, "911")
        + entry("BL", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")
        + entry("BM", "Bermudian dollar (BMD)", ["English"], ["A", "B"], .left, "911")
        + entry("BS", "Bahamian dollar (BSD)", ["English"], ["A", "B"], .left, "911")
        + entry("BZ", "Belize dollar (BZD)", ["English"], ["A", "B", "C"], .right, "911")
        + entry("CA", "Canadian dollar (CAD)", ["English", "French"], ["A", "B"], .right, "911")
        + entry("CR", "Costa Rican colón (CRC)", ["Spanish"], ["A", "B"], .right, "911")
        + entry("CU", "Cuban peso (CUP)", ["Spanish"], ["A", "B", "C", "F", "L"], .right, "911")
        + entry("CW", "Netherlands Antillean guilder (ANG)", ["Dutch", "Papiamento"], ["A", "B"], .right, "911")
        + entry("DM", "East Caribbean dollar (XCD)", ["English"], ["C", "D", "G"], .left, "999")
        + entry("DO", "Dominican peso (DOP)", ["Spanish"], ["A", "B", "C"], .right, "911")
        + entry("GD", "East Caribbean dollar (XCD)", ["English"], ["C", "G"], .left, "911")
        + entry("GT", "Guatemalan quetzal (GTQ)", ["Spanish"], ["A", "B"], .right, "110")
        + entry("HN", "Honduran lempira (HNL)", ["Spanish"], ["A", "B"], .right, "112")
        + entry("HT", "Haitian gourde (HTG)", ["Haitian Creole", "French"], ["A", "B"], .right, "112")
        + entry("JM", "Jamaican dollar (JMD)", ["English"], ["A", "B"], .left, "112")
        + entry("KN", "East Caribbean dollar (XCD)", ["English"], ["C", "D", "G"], .left, "911")
        + entry("KY", "Cayman Islands dollar (KYD)", ["English"], ["A", "B"], .left, "911")
        + entry("LC", "East Caribbean dollar (XCD)", ["English"], ["C", "G"], .left, "911")
        + entry("MF", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")
        + entry("MS", "East Caribbean dollar (XCD)", ["English"], ["A", "B"], .left, "911")
        + entry("MX", "Mexican peso (MXN)", ["Spanish"], ["A", "B"], .right, "911")
        + entry("NI", "Nicaraguan córdoba (NIO)", ["Spanish"], ["A", "B"], .right, "118")
        + entry("PA", "Panamanian balboa (PAB)", ["Spanish"], ["A", "B"], .right, "911")
        + entry("PM", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")
        + entry("PR", "United States dollar (USD)", ["Spanish", "English"], ["A", "B"], .right, "911")
        + entry("SV", "Salvadoran colón (SVC)", ["Spanish"], ["A", "B"], .right, "911")
        + entry("SX", "Netherlands Antillean guilder (ANG)", ["Dutch", "English"], ["A", "B"], .right, "911")
        + entry("TC", "United States dollar (USD)", ["English"], ["A", "B"], .right, "911")
        + entry("TT", "Trinidad and Tobago dollar (TTD)", ["English"], ["A", "B"], .left, "911")
        + entry("US", "United States dollar (USD)", ["English"], ["A", "B"], .right, "911")
        + entry("VC", "East Caribbean dollar (XCD)", ["English"], ["C", "G"], .left, "911")
        + entry("VG", "United States dollar (USD)", ["English"], ["A", "B"], .left, "911")
        + entry("VI", "United States dollar (USD)", ["English", "Spanish"], ["A", "B"], .left, "911")

        // MARK: - South America

        + entry("AR", "Argentine peso (ARS)", ["Spanish"], ["C", "F", "I"], .right, "911")
        + entry("BO", "Bolivian boliviano (BOB)", ["Spanish", "Quechua", "Aymara"], ["A", "B", "C"], .right, "110")
        + entry("BR", "Brazilian real (BRL)", ["Portuguese"], ["C", "N"], .right, "190")
        + entry("CL", "Chilean peso (CLP)", ["Spanish"], ["C", "F", "L"], .right, "131")
        + entry("CO", "Colombian peso (COP)", ["Spanish"], ["A", "B"], .right, "112")
        + entry("EC", "United States dollar (USD)", ["Spanish"], ["A", "B"], .right, "911")
        + entry("FK", "Falkland Islands pound (FKP)", ["English"], ["C", "G"], .left, "999")
        + entry("GY", "Guyanese dollar (GYD)", ["English"], ["A", "B", "C", "D", "G"], .left, "911")
        + entry("PE", "Peruvian sol (PEN)", ["Spanish", "Quechua", "Aymara"], ["A", "B", "C"], .right, "105")
        + entry("PY", "Paraguayan guaraní (PYG)", ["Spanish", "Guaraní"], ["A", "B", "C"], .right, "911")
        + entry("SR", "Surinamese dollar (SRD)", ["Dutch"], ["A", "B", "C", "F"], .left, "112")
        + entry("UY", "Uruguayan peso (UYU)", ["Spanish"], ["C", "F", "L"], .right, "911")
        + entry("VE", "Venezuelan bolívar (VES)", ["Spanish"], ["A", "B"], .right, "911")

        // MARK: - Australia and Oceania

        + entry("AS", "United States dollar (USD)", ["Samoan", "English"], ["A", "B", "F", "I"], .right, "911")
        + entry("AU", "Australian dollar (AUD)", ["English"], ["C", "I"], .left, "000")
        + entry("CK", "New Zealand dollar (NZD)", ["English", "Cook Islands Māori"], ["C", "I"], .left, "112")
        + entry("FJ", "Fijian dollar (FJD)", ["English", "Fijian", "Fiji Hindi"], ["C", "I"], .left, "911")
        + entry("FM", "United States dollar (USD)", ["English"], ["A", "B"], .right, "911")
        + entry("GU", "United States dollar (USD)", ["English", "Chamorro"], ["A", "B"], .right, "911")
        + entry("KI", "Australian dollar (AUD)", ["English", "Gilbertese"], ["C", "I"], .left, "112")
        + entry("MH", "United States dollar (USD)", ["Marshallese", "English"], ["A", "B"], .right, "911")
        + entry("MP", "United States dollar (USD)", ["Chamorro", "English"], ["A", "B"], .right, "911")
        + entry("NC", "CFP franc (XPF)", ["French"], ["C", "E", "F"], .right, "112")
        + entry("NF", "Australian dollar (AUD)", ["English"], ["C", "I"], .left, "112")
        + entry("NR", "Australian dollar (AUD)", ["Nauruan", "English"], ["C", "I"], .left, "112")
        + entry("NU", "New Zealand dollar (NZD)", ["Niuean", "English"], ["C", "I"], .left, "112")
        + entry("NZ", "New Zealand dollar (NZD)", ["English", "Māori", "New Zealand Sign Language"], ["C", "I"], .left, "111")
        + entry("PF", "CFP franc (XPF)", ["French"], ["A", "B", "C", "E", "F"], .right, "112")
        + entry("PG", "Papua New Guinean kina (PGK)", ["English", "Tok Pisin", "Hiri Motu"], ["C", "I"], .left, "112")
        + entry("PN", "New Zealand dollar (NZD)", ["English", "Pitkern"], ["C", "I"], .left, "112")
        + entry("PW", "United States dollar (USD)", ["Palauan", "English"], ["A", "B"], .right, "911")
        + entry("SB", "Solomon Islands dollar (SBD)", ["English"], ["C", "G", "I"], .left, "112")
        + entry("TO", "Tongan paʻanga (TOP)", ["Tongan", "English"], ["C", "I"], .left, "112")
        + entry("TV", "Australian dollar (AUD)", ["Tuvaluan", "English"], ["C", "I"], .left, "112")
        + entry("UM", "United States dollar (USD)", ["English"], ["A", "B"], .right, "911")
        + entry("VU", "Vanuatu vatu (VUV)", ["Bislama", "English", "French"], ["C", "G", "I"], .right, "112")
        + entry("WF", "CFP franc (XPF)", ["French"], ["C", "E", "F"], .right, "112")
        + entry("WS", "Samoan tālā (WST)", ["Samoan", "English"], ["C", "I"], .left, "112")
        + entry("CP", "Euro (EUR)", ["French"], ["C", "E"], .right, "112")

        // MARK: - Antarctica

        + entry("AQ", "No local currency", ["English"], ["C"], .right, "112")  // Research stations

    // MARK: Helper

    /// Wraps one fact entry into a single-element array so `+` concatenation works.
    private nonisolated static func entry(
        _ id: String,
        _ currency: String,
        _ languages: [String],
        _ plugTypes: [String],
        _ drivingSide: DrivingSide,
        _ emergencyNumber: String
    ) -> [(String, CountryFacts)] {
        [(id, CountryFacts(
            currency: currency,
            languages: languages,
            plugTypes: plugTypes,
            drivingSide: drivingSide,
            emergencyNumber: emergencyNumber
        ))]
    }
}
