#!/usr/bin/env python3
"""
Localization Manager for .xcstrings files
==========================================
Helps manage translations in Apple's .xcstrings format.

Usage:
  # Check which strings are missing translations
  python3 locman.py Localizable.xcstrings --check

  # Fill missing translations using English as fallback
  python3 locman.py Localizable.xcstrings --fill

  # Add a new language by providing a translations file
  python3 locman.py Localizable.xcstrings --add-language ro --from romanian.json

  # Only process specific languages
  python3 locman.py Localizable.xcstrings --check --langs ro,hu
"""

import json
import os
import re
import sys

# ──────────────────────────────────────────────
# Format-only keys that don't need translation
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


def load_xcstrings(path):
    """Load an .xcstrings file and return the parsed data."""
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_xcstrings(path, data):
    """Save the .xcstrings file."""
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def get_non_empty_keys(data):
    """Return all non-empty string keys."""
    return [k for k in data.get("strings", {}) if k != ""]


def is_format_only(key):
    """Check if a key is a pure format specifier that doesn't need translation."""
    return key in FORMAT_ONLY


def get_languages(data, exclude_en=True):
    """Get all languages present in the file."""
    langs = set()
    for key, value in data.get("strings", {}).items():
        for lang in value.get("localizations", {}):
            langs.add(lang)
    if exclude_en and "en" in langs:
        langs.remove("en")
    return sorted(langs)


def check_missing(data, langs=None):
    """
    Check which strings are missing translations.
    Returns dict: { 'lang_code': [missing_keys] }
    """
    strings = data.get("strings", {})
    if langs is None:
        langs = get_languages(data)

    result = {}
    for lang in langs:
        missing = []
        for key, value in strings.items():
            if key == "":
                continue
            if lang not in value.get("localizations", {}):
                missing.append(key)
        if missing:
            result[lang] = missing

    return result


def fill_missing(data, fill_source="en", verbose=False):
    """
    Fill missing translations using a source language as fallback.

    - For format-only keys: copies the English value.
    - For other missing keys: copies from fill_source language.

    Returns dict: { 'lang': count_filled }
    """
    strings = data.get("strings", {})
    filled = {}

    for lang in get_languages(data):
        count = 0
        for key, value in strings.items():
            if key == "":
                continue
            locs = value.get("localizations", {})
            if lang not in locs:
                # Determine the value to use
                if is_format_only(key):
                    # Use English value
                    src_val = locs.get("en", {}).get("stringUnit", {}).get("value", key)
                elif fill_source in locs:
                    src_val = locs[fill_source]["stringUnit"]["value"]
                elif "en" in locs:
                    src_val = locs["en"]["stringUnit"]["value"]
                else:
                    src_val = key

                # If source is the same as target, this is a no-op
                if lang == fill_source:
                    continue

                locs[lang] = {
                    "stringUnit": {
                        "state": "translated" if lang != "en" else "new",
                        "value": src_val,
                    }
                }
                count += 1

        if count > 0:
            filled[lang] = count
            if verbose:
                print(f"  {lang}: filled {count} missing strings")

    return filled


def add_new_language(data, lang_code, translations, source_lang="en"):
    """
    Add a new language with provided translations.

    Args:
        data: Parsed xcstrings data
        lang_code: Language code (e.g., 'ro', 'ko')
        translations: Dict mapping English keys to translated values
        source_lang: Language code of the source keys in translations dict

    Returns dict: { 'added': count, 'unmatched': [keys] }
    """
    strings = data.get("strings", {})
    added = 0
    unmatched = []

    for key, value in strings.items():
        if key == "":
            continue

        locs = value.get("localizations", {})
        if lang_code in locs:
            continue  # Already translated

        # Look up the translation
        trans = translations.get(key)
        if trans is not None:
            locs[lang_code] = {"stringUnit": {"state": "translated", "value": trans}}
            added += 1
        elif is_format_only(key):
            # Format-only: copy English value
            en_val = locs.get("en", {}).get("stringUnit", {}).get("value", key)
            locs[lang_code] = {"stringUnit": {"state": "translated", "value": en_val}}
            added += 1
        else:
            unmatched.append(key)

    return {"added": added, "unmatched": unmatched}


def print_report(data, verbose=True):
    """Print a translation coverage report."""
    total = len(get_non_empty_keys(data))
    langs = get_languages(data)

    print(f"\n{'─' * 50}")
    print(f"  Total translatable strings: {total}")
    print(f"  Total languages: {len(langs) + 1} (incl. English)")
    print(f"{'─' * 50}")
    print()

    # English
    en_count = sum(
        1 for v in data["strings"].values() if "en" in v.get("localizations", {})
    )
    print(
        f"  {'✅' if en_count == total else '⚠️'}  en: {en_count}/{total} ({(en_count / total) * 100:.0f}%)"
    )

    for lang in langs:
        count = sum(
            1 for v in data["strings"].values() if lang in v.get("localizations", {})
        )
        pct = (count / total) * 100
        flag = "✅" if count == total else "⚠️"
        print(f"  {flag}  {lang}: {count}/{total} ({pct:.0f}%)")

    print()


def generate_template(data, lang_code, output_path=None):
    """
    Generate a JSON template file for a new language.
    Contains all English keys with empty values for a translator to fill in.
    """
    strings = data.get("strings", {})
    template = {}

    for key, value in strings.items():
        if key == "":
            continue
        if is_format_only(key):
            continue  # Skip format-only, they don't need translation

        # Get English or first available value as hint
        locs = value.get("localizations", {})
        hint = locs.get("en", {}).get("stringUnit", {}).get("value", key)
        comment = value.get("comment", "")

        entry = {"hint": hint}
        if comment:
            entry["comment"] = comment

        template[key] = entry

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(template, f, indent=2, ensure_ascii=False)
        print(f"Template written to: {output_path}")
        print(f"Total entries: {len(template)}")

    return template


def load_template_translations(template_path):
    """
    Load a completed translation template back.
    Expects a JSON file with keys and "translation" field filled in.
    """
    with open(template_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    result = {}
    for key, entry in data.items():
        if "translation" in entry and entry["translation"]:
            result[key] = entry["translation"]

    return result


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Localization Manager for .xcstrings files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("xcstrings", help="Path to the .xcstrings file")

    # Mutually exclusive modes
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
        "--add-language",
        metavar="CODE",
        help="Add a new language from a translations file",
    )
    group.add_argument(
        "--generate-template",
        metavar="CODE",
        help="Generate a translation template for a new language",
    )
    group.add_argument(
        "--report", action="store_true", help="Show translation coverage report"
    )

    parser.add_argument(
        "--langs", default=None, help="Comma-separated language codes to process"
    )
    parser.add_argument(
        "--from",
        dest="from_file",
        default=None,
        help="Translations JSON file for --add-language",
    )
    parser.add_argument(
        "--source", default="en", help="Source language for --fill (default: en)"
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()

    if not os.path.exists(args.xcstrings):
        print(f"Error: File not found: {args.xcstrings}")
        sys.exit(1)

    data = load_xcstrings(args.xcstrings)

    # Parse language filter
    lang_filter = None
    if args.langs:
        lang_filter = [l.strip() for l in args.langs.split(",")]

    if args.report or not any(
        [args.check, args.fill, args.add_language, args.generate_template]
    ):
        print_report(data)

    if args.check:
        missing = check_missing(data, langs=lang_filter)
        if not missing:
            print("✅ All selected languages have 100% translation coverage!")
        else:
            for lang, keys in sorted(missing.items()):
                print(f"\n⚠️  {lang} is missing {len(keys)} translations:")
                for k in keys:
                    print(f"    {repr(k[:70])}")

    if args.fill:
        print(f"\nFilling missing translations using '{args.source}' as source...")
        filled = fill_missing(data, fill_source=args.source, verbose=True)
        if filled:
            save_xcstrings(args.xcstrings, data)
            print(f"\n✅ Saved to: {args.xcstrings}")
        else:
            print("Nothing to fill.")

    if args.generate_template:
        out_path = f"template_{args.generate_template}.json"
        generate_template(data, args.generate_template, output_path=out_path)

    if args.add_language:
        if not args.from_file:
            print("Error: --add-language requires --from <translations_file>")
            sys.exit(1)

        lang = args.add_language
        translations = load_template_translations(args.from_file)

        if not translations:
            # Try loading as simple key-value JSON
            with open(args.from_file, "r", encoding="utf-8") as f:
                raw = json.load(f)
            # If it's a flat dict, use it directly
            if isinstance(raw, dict) and all(isinstance(v, str) for v in raw.values()):
                translations = raw

        print(f"Adding language: {lang}")
        print(f"Loaded {len(translations)} translations from: {args.from_file}")

        result = add_new_language(data, lang, translations)
        print(f"  Added: {result['added']}")
        if result["unmatched"]:
            print(f"  Unmatched keys ({len(result['unmatched'])}):")
            for k in result["unmatched"][:10]:
                print(f"    - {repr(k[:60])}")
            if len(result["unmatched"]) > 10:
                print(f"    ... and {len(result['unmatched']) - 10} more")

        save_xcstrings(args.xcstrings, data)
        print(f"✅ Saved to: {args.xcstrings}")


if __name__ == "__main__":
    main()
