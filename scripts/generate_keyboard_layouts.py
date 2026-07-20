#!/usr/bin/env python3
"""Generate KeyboardLayoutData.swift from FlorisBoard layout data.

FlorisBoard (https://github.com/florisboard/florisboard) is Apache-2.0;
the generated file retains the attribution notice. Run from repo root:

    python3 scripts/generate_keyboard_layouts.py

Downloads the layout/popup JSON straight from the FlorisBoard main branch
and rewrites Whishpermate/WhisperMateKeyboard/KeyboardLayoutData.swift.
"""

import json
import urllib.request
from pathlib import Path

BASE = "https://raw.githubusercontent.com/florisboard/florisboard/main/app/src/main/assets/ime/keyboard"
OUT = Path(__file__).resolve().parent.parent / "Whishpermate/WhisperMateKeyboard/KeyboardLayoutData.swift"

# language code -> (native name, toggle label, floris characters layout, floris popup mapping)
# Layout/popup pairing follows FlorisBoard's own subtypePresets (extension.json).
LANGUAGES = [
    ("en", "English", "EN", "qwerty", "en"),
    ("ru", "Русский", "РУ", "jcuken_russian", "ru"),
    ("uk", "Українська", "УК", "jcuken_ukrainian", "uk"),
    ("be", "Беларуская", "БЕ", None, None),  # hand-authored below
    ("es", "Español", "ES", "spanish", "es"),
    ("fr", "Français", "FR", "azerty", "fr"),
    ("de", "Deutsch", "DE", "qwertz", "de"),
    ("it", "Italiano", "IT", "qwerty", "it"),
    ("pt", "Português", "PT", "qwerty", "pt"),
    ("nl", "Nederlands", "NL", "qwerty", None),  # hand-authored popups below
    ("pl", "Polski", "PL", "qwerty", "pl"),
    ("cs", "Čeština", "CS", "qwertz", "cs"),
    ("sv", "Svenska", "SV", "swedish_finnish", "sv"),
    ("fi", "Suomi", "FI", "swedish_finnish", "fi"),
    ("tr", "Türkçe", "TR", "qwerty", "tr"),
    ("el", "Ελληνικά", "ΕΛ", "greek", "el"),
    ("ar", "العربية", "AR", "arabic", "ar"),
    ("hi", "हिन्दी", "हि", "hindi_in", "hi-IN"),
]

BELARUSIAN_ROWS = [
    list("йцукенгшўзх"),
    list("фывапролджэ"),
    list("ячсмітьбю"),
]
BELARUSIAN_POPUPS = {"е": ["ё"], "і": ["и"], "ь": ["ъ"]}

DUTCH_POPUPS = {
    "a": ["á", "à", "â", "ä"],
    "e": ["é", "è", "ë", "ê"],
    "i": ["í", "ì", "ï", "î"],
    "o": ["ó", "ò", "ö", "ô"],
    "u": ["ú", "ù", "ü", "û"],
    "n": ["ñ"],
    "c": ["ç"],
}

TURKISH_UPPER = {"i": "İ", "ı": "I"}


def fetch(path):
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def upper(ch, lang):
    if lang == "tr":
        return "".join(TURKISH_UPPER.get(c, c.upper()) for c in ch)
    return ch.upper()


def parse_layout(data, lang):
    rows = []
    inline_popups = {}
    for raw_row in data:
        row = []
        for key in raw_row:
            kind = key.get("$", "text_key")
            if kind == "case_selector":
                lower = key["lower"]["label"]
                up = key["upper"]["label"]
            elif kind in ("text_key", "auto_text_key"):
                lower = key["label"]
                up = upper(lower, lang) if kind == "auto_text_key" else lower
            else:
                continue  # selectors/pseudo keys we do not render
            if popup := key.get("popup"):
                alts = [p["label"] for p in popup.get("relevant", []) if "label" in p]
                if alts:
                    inline_popups[lower] = alts
            row.append((lower, up))
        rows.append(row)
    return rows, inline_popups


def parse_popups(mapping, rows):
    """Popup file 'all' section -> {base: [alts]}, limited to keys in the layout."""
    layout_chars = {lower for row in rows for lower, _ in row}
    result = {}
    for base, entry in mapping.get("all", {}).items():
        if base.startswith("~") or base not in layout_chars:
            continue
        alts = []
        if main := entry.get("main"):
            if "label" in main:
                alts.append(main["label"])
        for p in entry.get("relevant", []):
            if "label" in p:
                alts.append(p["label"])
        if alts:
            result[base] = alts
    return result


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    layout_cache = {}
    popup_cache = {}
    blocks = []

    for code, name, toggle, layout_name, popup_name in LANGUAGES:
        if layout_name is None:
            rows = [[(c, upper(c, code)) for c in row] for row in BELARUSIAN_ROWS]
            popups = dict(BELARUSIAN_POPUPS)
        else:
            if layout_name not in layout_cache:
                layout_cache[layout_name] = fetch(
                    f"org.florisboard.layouts/layouts/characters/{layout_name}.json"
                )
            rows, popups = parse_layout(layout_cache[layout_name], code)
            if popup_name:
                if popup_name not in popup_cache:
                    popup_cache[popup_name] = fetch(
                        f"org.florisboard.localization/popupMappings/{popup_name}.json"
                    )
                file_popups = parse_popups(popup_cache[popup_name], rows)
                file_popups.update(popups)  # inline layout popups win
                popups = file_popups
            if code == "nl":
                popups = {**DUTCH_POPUPS, **popups}

        row_lines = []
        for row in rows:
            keys = ", ".join(
                f".init({swift_str(lo)}, {swift_str(up)})" if lo != up else f".init({swift_str(lo)})"
                for lo, up in row
            )
            row_lines.append(f"                [{keys}],")
        popup_lines = [
            f"                {swift_str(base)}: [{', '.join(swift_str(a) for a in alts)}],"
            for base, alts in sorted(popups.items())
        ]
        popup_body = "\n".join(popup_lines) if popup_lines else "                :"
        blocks.append(
            f"""        KeyboardTypingLayout(
            code: {swift_str(code)},
            name: {swift_str(name)},
            toggleLabel: {swift_str(toggle)},
            rows: [
{chr(10).join(row_lines)}
            ],
            popups: [
{popup_body}
            ]
        ),"""
        )

    OUT.write_text(
        f"""// Generated by scripts/generate_keyboard_layouts.py — do not edit by hand.
//
// Layout and long-press accent data derived from FlorisBoard
// (https://github.com/florisboard/florisboard), licensed under the
// Apache License 2.0. Copyright the FlorisBoard contributors.

struct KeyboardTypingKey: Hashable {{
    let lower: String
    let upper: String

    init(_ lower: String, _ upper: String? = nil) {{
        self.lower = lower
        self.upper = upper ?? lower
    }}

    func label(shifted: Bool) -> String {{
        shifted ? upper : lower
    }}
}}

struct KeyboardTypingLayout: Identifiable, Hashable {{
    let code: String
    let name: String
    let toggleLabel: String
    let rows: [[KeyboardTypingKey]]
    let popups: [String: [String]]

    var id: String {{ code }}

    /// False for scripts without letter case (Arabic); the shift key is hidden.
    var hasCase: Bool {{
        rows.contains {{ row in row.contains {{ $0.lower != $0.upper }} }}
    }}

    func alternates(for key: KeyboardTypingKey, shifted: Bool) -> [String] {{
        guard let alts = popups[key.lower] else {{ return [] }}
        return shifted ? alts.map {{ $0.uppercased() }} : alts
    }}
}}

enum KeyboardLayoutData {{
    static let layouts: [KeyboardTypingLayout] = [
{chr(10).join(blocks)}
    ]

    static func layout(for code: String) -> KeyboardTypingLayout? {{
        layouts.first {{ $0.code == code }}
    }}
}}
"""
    )
    print(f"Wrote {OUT} ({len(LANGUAGES)} layouts)")


if __name__ == "__main__":
    main()
