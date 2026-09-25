#!/usr/bin/env python3
"""Merges newly extracted strings into Localizable.xcstrings.

Xcode extracts every localizable string in the app into .stringsdata files while
it builds. This pulls those keys into the catalog, keeps existing translations,
and lists what still needs a German version — so a new string can never quietly
ship untranslated.

Usage: ./build.sh && python3 tools/sync-strings.py [path-to-derived-data] [--prune]
"""
import glob, json, os, subprocess, sys


def string_units(node):
    """Every translated unit under a localization.

    A string with a singular and a plural keeps its text in `variations` (or in
    `substitutions`, when only part of the sentence counts) and has no unit of
    its own. Looking only at the top level would report every one of them as
    untranslated.
    """
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield node["stringUnit"]
        for name, value in node.items():
            if name != "stringUnit":
                yield from string_units(value)


def is_translated(localization):
    units = list(string_units(localization))
    return bool(units) and all(u.get("state") == "translated" for u in units)


root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
prune = "--prune" in sys.argv
derived = args[0] if args else os.path.join(root, "build")
catalog_path = os.path.join(root, "App/Resources/Localizable.xcstrings")

# Every target is built from the same sources, so any one's extraction is
# complete; scanning all of them keeps this working whichever was built last,
# including a build of your own from project.local.yml.
pattern = os.path.join(derived, "Build/Intermediates.noindex/MacBench.build",
                       "*/*.build/Objects-normal/*/*.stringsdata")
found = []
for path in sorted(glob.glob(pattern)):
    raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True).stdout
    if not raw.strip():
        continue
    for entries in json.loads(raw).get("tables", {}).values():
        for entry in entries:
            if entry["key"] and entry["key"] not in found:
                found.append(entry["key"])

if not found:
    sys.exit(f"No extracted strings under {derived} — build first.")

catalog = json.load(open(catalog_path))
strings = catalog["strings"]
for key in found:
    strings.setdefault(key, {"extractionState": "manual", "localizations": {}})

stale = [k for k in strings if k not in found]
if prune:
    for key in stale:
        del strings[key]
missing = [k for k in found
           if not is_translated(strings[k].get("localizations", {}).get("de", {}))]

catalog["strings"] = {k: strings[k] for k in sorted(strings)}
json.dump(catalog, open(catalog_path, "w"), indent=2, ensure_ascii=False)
open(catalog_path, "a").write("\n")

print(f"{len(found)} strings in use, {len(strings)} in the catalog")
if stale:
    print("\nremoved (no longer used):" if prune else "\nno longer used (pass --prune to remove):")
    for key in stale:
        print("  ", json.dumps(key, ensure_ascii=False))
if missing:
    print("\nMISSING GERMAN:")
    for key in missing:
        print("  ", json.dumps(key, ensure_ascii=False))
    sys.exit(1)
