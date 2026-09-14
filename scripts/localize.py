#!/usr/bin/env python3
"""Compile the source String Catalog to SwiftPM-compatible .strings files.

SwiftPM's command-line resource processing does not compile .xcstrings; Xcode is
not required for this deterministic conversion (there are no plural entries).
"""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
catalog = json.loads((root / "Sources/AIUsage/Resources/Localizable.xcstrings").read_text())
used = set()
for source in (root / "Sources").rglob("*.swift"):
    used.update(re.findall(r'\b(?:L|localized)\("([^"\\]*)"\s*[,)]', source.read_text()))
missing = used - catalog["strings"].keys()
if missing:
    raise SystemExit("Missing catalog entries: " + repr(sorted(missing)))
source_language = catalog["sourceLanguage"]
languages = {source_language} | {language for entry in catalog["strings"].values() for language in entry.get("localizations", {})}
for language in sorted(languages):
    lines = ["/* Generated from Localizable.xcstrings. Do not edit. */"]
    for key, entry in sorted(catalog["strings"].items()):
        if language == source_language:
            value = key
        else:
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            value = unit.get("value")
            if not value or unit.get("state") != "translated":
                raise SystemExit(f"Missing translation: {language}: {key}")
        # A translation must keep every format argument used by the UI.
        placeholders = lambda text: sorted(re.findall(r'%(?:\d+\$)?[@diufgs]', text))
        if placeholders(value) != placeholders(key):
            raise SystemExit(f"Mismatched format arguments: {language}: {key}")
        lines.append(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";")
    target = root / f"Sources/AIUsageCore/Resources/{language}.lproj/Localizable.strings"
    content = "\n".join(lines) + "\n"
    if "--check" in sys.argv:
        if not target.exists() or target.read_text() != content:
            raise SystemExit(f"Outdated translations: {target}")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
print(f"String Catalog: {len(catalog['strings'])} entries, languages: {', '.join(sorted(languages))}")
