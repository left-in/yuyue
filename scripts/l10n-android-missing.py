#!/usr/bin/env python3
"""Chinese keys the Android code uses (t("…")) that have no English yet, in the Apple catalog
or android/app/src/main/l10n/extra-en.json. Prints them as JSON to fill in extra-en.json.

The Kotlin keys use Swift's specifiers (%@, %lld) so they match the catalog."""
import glob, json, os, re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cat = json.load(open(os.path.join(root, 'apple/Yuyue/Localizable.xcstrings'), encoding='utf-8'))['strings']
have = {k for k, v in cat.items() if 'en' in v.get('localizations', {})}
extra = json.load(open(os.path.join(root, 'android/app/src/main/l10n/extra-en.json'), encoding='utf-8'))
have |= set(extra)
key = re.compile(r'\bt\(\s*"((?:[^"\\]|\\.)*)"')
han = re.compile('[㐀-鿿]')
missing = {}
for f in glob.glob(os.path.join(root, 'android/app/src/main/java/app/**/*.kt'), recursive=True):
    for m in key.finditer(open(f, encoding='utf-8').read()):
        k = m.group(1).encode().decode('unicode_escape').encode('latin1').decode('utf-8') if '\\' in m.group(1) else m.group(1)
        if han.search(k) and k not in have:
            missing.setdefault(k, os.path.relpath(f, root))
print(json.dumps({k: "" for k in sorted(missing)}, ensure_ascii=False, indent=1))
