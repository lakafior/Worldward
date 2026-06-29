#!/usr/bin/env python3
"""
Localization Manager for .xcstrings files
==========================================
Helps manage translations in Apple's .xcstrings format.

Usage:
  # Quick overview
  python3 locman.py Localizable.xcstrings

  # Check which strings are missing
  python3 locman.py Localizable.xcstrings --check
  python3 locman.py Localizable.xcstrings --check --langs de,fr

  # Fill missing translations (copies from source language as fallback)
  python3 locman.py Localizable.xcstrings --fill

  # Add English text to new untranslated keys
  python3 locman.py Localizable.xcstrings --init

  # Generate a translator template for a new language
  python3 locman.py Localizable.xcstrings --generate-template ro

  # Apply a completed translation file
  python3 locman.py Localizable.xcstrings --add-language ro --from romanian.json

  # Quick translate: apply a simple key-value JSON to one language
  python3 locman.py Localizable.xcstrings --translate ro --from ro_translations.json
"""

import json
import os
import sys

# ──────────────────────────────────────────────
# Format-only keys that DON'T need translation
# (pure placeholders like %@, %lld, ×%lld)
# ──────────────────────────────────────────────
FORMAT_ONLY = {
    "%@",
    "%@  %@",
    "%@ · %lld/%lld",
    "%@ %@",
    "%@ %lld",
    "%lld",
    "%lld / %lld",
    "%lld %@",
    "%lld%%",
    "×%lld",
}


# ── Helpers ──


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def non_empty_keys(data):
    return [k for k in data.get("strings", {}) if k != ""]


def is_format_only(key):
    return key in FORMAT_ONLY


def get_languages(data, exclude_en=True):
    langs = set()
    for value in data.get("strings", {}).values():
        for lang in value.get("localizations", {}):
            langs.add(lang)
    if exclude_en and "en" in langs:
        langs.remove("en")
    return sorted(langs)


def ensure_localizations(entry):
    """Make sure a string entry has a 'localizations' dict."""
    if "localizations" not in entry:
        entry["localizations"] = {}
    return entry["localizations"]


# ── Core ──


def check_missing(data, langs=None):
    """
    Returns { lang: [missing_keys] } for all non-English languages.
    Also reports keys that have NO localizations at all.
    """
    strings = data.get("strings", {})
    if langs is None:
        langs = get_languages(data)

    # Keys with zero localizations (app-generated, never touched)
    untranslated = []
    for key, value in strings.items():
        if key == "":
            continue
        locs = value.get("localizations", {})
        if not locs:
            untranslated.append(key)

    result = {}
    for lang in langs:
        missing = []
        for key, value in strings.items():
            if key == "":
                continue
            locs = value.get("localizations", {})
            if not locs or lang not in locs:
                missing.append(key)
        if missing:
            result[lang] = missing

    return result, untranslated


def init_english(data, verbose=False):
    """
    For keys that have NO localizations at all, add an English entry.
    This is needed before --fill or anything else can work.
    """
    strings = data.get("strings", {})
    count = 0
    for key, value in strings.items():
        if key == "":
            continue
        locs = ensure_localizations(value)
        if "en" not in locs:
            locs["en"] = {"stringUnit": {"state": "new", "value": key}}
            count += 1
            if verbose:
                print(f"  en: added '{key[:60]}...'")
    return count


def fill_missing(data, fill_source="en", verbose=False):
    """
    Fill missing translations for ALL languages using a source language.
    Handles keys that don't even have a localizations dict yet.
    """
    strings = data.get("strings", {})
    filled = {}

    for lang in get_languages(data):
        count = 0
        for key, value in strings.items():
            if key == "":
                continue
            locs = ensure_localizations(value)

            if lang in locs:
                continue  # Already translated

            # Determine source value
            if is_format_only(key):
                src_val = locs.get("en", {}).get("stringUnit", {}).get("value", key)
            elif fill_source in locs:
                src_val = locs[fill_source]["stringUnit"]["value"]
            elif "en" in locs:
                src_val = locs["en"]["stringUnit"]["value"]
            else:
                src_val = key

            if lang == fill_source:
                continue

            locs[lang] = {
                "stringUnit": {
                    "state": "translated" if lang != "en" else "new",
                    "value": src_val,
                }
            }
            count += 1

        if count:
            filled[lang] = count
            if verbose:
                print(f"  {lang}: filled {count}")

    return filled


def add_language(data, lang_code, translations):
    """
    Add a new language from a { key: translation } dict.
    Returns { added: n, unmatched: [keys] }
    """
    strings = data.get("strings", {})
    added = 0
    unmatched = []

    for key, value in strings.items():
        if key == "":
            continue
        locs = ensure_localizations(value)
        if lang_code in locs:
            continue

        trans = translations.get(key)
        if trans is not None:
            locs[lang_code] = {"stringUnit": {"state": "translated", "value": trans}}
            added += 1
        elif is_format_only(key):
            en_val = locs.get("en", {}).get("stringUnit", {}).get("value", key)
            locs[lang_code] = {"stringUnit": {"state": "translated", "value": en_val}}
            added += 1
        else:
            unmatched.append(key)

    return {"added": added, "unmatched": unmatched}


# ── Templates & Reports ──


def generate_template(data, output_path=None):
    """Generate a translator-friendly JSON template for a new language."""
    strings = data.get("strings", {})
    template = {}

    for key, value in strings.items():
        if key == "":
            continue
        if is_format_only(key):
            continue

        locs = value.get("localizations", {})
        hint = locs.get("en", {}).get("stringUnit", {}).get("value", key)
        comment = value.get("comment", "")

        entry = {"hint": hint, "translation": ""}
        if comment:
            entry["comment"] = comment
        template[key] = entry

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(template, f, indent=2, ensure_ascii=False)
        print(f"📝 Template written to: {output_path}")
        print(f"   Total entries: {len(template)}")
        print(f"   Fill in the 'translation' fields, then run:")
        print(
            f"   python3 locman.py {sys.argv[1]} --add-language <code> --from {output_path}"
        )

    return template


def load_translations(path):
    """Load translations from a file. Supports template format or simple dict."""
    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    # Template format: { key: { hint, translation, comment } }
    if isinstance(raw, dict):
        # Check if it's template format
        sample = next(iter(raw.values()), {})
        if isinstance(sample, dict) and "translation" in sample:
            return {k: v["translation"] for k, v in raw.items() if v.get("translation")}
        # Simple format: { key: "translation" }
        if all(isinstance(v, str) for v in raw.values()):
            return raw

    return {}


def print_report(data):
    """Print coverage report."""
    total = len(non_empty_keys(data))
    langs = get_languages(data)
    _, untranslated = check_missing(data)

    print(f"\n{'─' * 52}")
    print(f"  Total strings: {total}")
    print(f"  Languages:     {len(langs) + 1}")
    if untranslated:
        print(
            f"  ⚠️  {len(untranslated)} keys have NO translations at all (run --init first)"
        )
    print(f"{'─' * 52}")

    en_count = sum(
        1 for v in data["strings"].values() if "en" in v.get("localizations", {})
    )
    flag = "✅" if en_count == total else "⚠️"
    print(f"  {flag}  en: {en_count}/{total} ({(en_count / total) * 100:.0f}%)")

    for lang in langs:
        count = sum(
            1 for v in data["strings"].values() if lang in v.get("localizations", {})
        )
        pct = (count / total) * 100
        flag = "✅" if count == total else "⚠️"
        print(f"  {flag}  {lang}: {count}/{total} ({pct:.0f}%)")

    print()


# ── CLI ──


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Localization Manager for .xcstrings files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("xcstrings", help="Path to the .xcstrings file")

    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--check",
        action="store_true",
        help="Check which strings are missing translations",
    )
    group.add_argument(
        "--fill",
        action="store_true",
        help="Fill missing translations using a source language",
    )
    group.add_argument(
        "--init",
        action="store_true",
        help="Add English source text to newly generated keys",
    )
    group.add_argument(
        "--add-language",
        metavar="CODE",
        help="Add a new language from a completed template file",
    )
    group.add_argument(
        "--translate",
        metavar="CODE",
        help="Apply a simple key-value JSON to a specific language",
    )
    group.add_argument(
        "--generate-template",
        metavar="FILE",
        help="Generate a translator template JSON file",
    )
    group.add_argument(
        "--report", action="store_true", help="Show translation coverage report"
    )

    parser.add_argument(
        "--langs", default=None, help="Comma-separated language codes to process"
    )
    parser.add_argument(
        "--from", dest="from_file", default=None, help="Translations JSON file"
    )
    parser.add_argument(
        "--source", default="en", help="Source language for --fill (default: en)"
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()

    if not os.path.exists(args.xcstrings):
        print(f"❌ File not found: {args.xcstrings}")
        sys.exit(1)

    data = load(args.xcstrings)

    lang_filter = None
    if args.langs:
        lang_filter = [l.strip() for l in args.langs.split(",")]

    # Default: show report
    if args.report or not any(
        [
            args.check,
            args.fill,
            args.init,
            args.add_language,
            args.translate,
            args.generate_template,
        ]
    ):
        print_report(data)

    # ── Check ──
    if args.check:
        missing, untranslated = check_missing(data, langs=lang_filter)

        if untranslated:
            print(
                f"\n⚠️  {len(untranslated)} keys have NO localizations at all (run --init to fix):"
            )
            for k in untranslated:
                print(f"    {repr(k[:80])}")

        if not missing:
            print("✅ All selected languages have 100% translation coverage!")
        else:
            for lang, keys in sorted(missing.items()):
                # Separate truly missing from never-translated
                never = [k for k in keys if k in untranslated]
                truly = [k for k in keys if k not in untranslated]
                print(f"\n⚠️  {lang} is missing {len(keys)} translations:")
                if never:
                    print(f"      🆕 {len(never)} need --init first")
                for k in truly:
                    print(f"      {repr(k[:80])}")

    # ── Init ──
    if args.init:
        print("\nAdding English source text to new keys...")
        n = init_english(data, verbose=args.verbose)
        save(args.xcstrings, data)
        print(f"✅ Added English to {n} keys → {args.xcstrings}")

    # ── Fill ──
    if args.fill:
        # First ensure all keys have at least English
        init_english(data)
        print(f"\nFilling missing translations from '{args.source}'...")
        filled = fill_missing(data, fill_source=args.source, verbose=args.verbose)
        if filled:
            save(args.xcstrings, data)
            print(
                f"✅ Filled {sum(filled.values())} gaps across {len(filled)} languages → {args.xcstrings}"
            )
        else:
            print("Nothing to fill — all up to date!")

    # ── Generate template ──
    if args.generate_template:
        generate_template(data, output_path=args.generate_template)

    # ── Add language from template ──
    if args.add_language:
        if not args.from_file:
            print("❌ --add-language requires --from <translations_file>")
            sys.exit(1)
        lang = args.add_language
        translations = load_translations(args.from_file)
        print(f"Adding language: {lang}")
        print(f"Loaded {len(translations)} translations from: {args.from_file}")
        result = add_language(data, lang, translations)
        print(f"  ✅ Added: {result['added']}")
        if result["unmatched"]:
            print(f"  ⚠️  Unmatched ({len(result['unmatched'])}):")
            for k in result["unmatched"][:10]:
                print(f"      {repr(k[:60])}")
            if len(result["unmatched"]) > 10:
                print(f"      ... and {len(result['unmatched']) - 10} more")
        save(args.xcstrings, data)
        print(f"✅ Saved → {args.xcstrings}")

    # ── Quick translate (simple key-value JSON) ──
    if args.translate:
        if not args.from_file:
            print("❌ --translate requires --from <translations_file>")
            sys.exit(1)
        lang = args.translate
        translations = load_translations(args.from_file)
        if not translations:
            print(
                "❌ Could not parse translations file. Expected { key: value } or { key: { translation } }"
            )
            sys.exit(1)
        print(f"Translating into: {lang}")
        print(f"Loaded {len(translations)} translations from: {args.from_file}")
        result = add_language(data, lang, translations)
        print(f"  ✅ Applied: {result['added']}")
        if result["unmatched"]:
            print(f"  ⚠️  Unmatched ({len(result['unmatched'])}):")
            for k in result["unmatched"][:5]:
                print(f"      {repr(k[:60])}")
            if len(result["unmatched"]) > 5:
                print(f"      ... and {len(result['unmatched']) - 5} more")
        save(args.xcstrings, data)
        print(f"✅ Saved → {args.xcstrings}")


if __name__ == "__main__":
    main()
