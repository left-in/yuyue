#!/usr/bin/env python3
"""English for the Apple catalog: lists the keys without it, or fills them in.

  l10n-apple.py            prints the keys in apple/Yuyue/Localizable.xcstrings that have no
                           English yet, as JSON to fill in
  l10n-apple.py FILE.json  writes the English in FILE.json (key -> English) into the catalog

Run `xcodebuild -exportLocalizations …` (or build in Xcode) first, so new keys are in the catalog.
"""
import json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(root, 'apple/Yuyue/Localizable.xcstrings')
cat = json.load(open(path, encoding='utf-8'))
strings = cat['strings']
if len(sys.argv) < 2:
    # Keys with Chinese in them that the code still uses (Xcode marks the rest stale).
    missing = {k: '' for k, v in strings.items()
               if re.search('[\u3400-\u9fff]', k) and v.get('extractionState') != 'stale'
               and v.get('shouldTranslate', True) and 'en' not in v.get('localizations', {})}
    print(json.dumps(missing, ensure_ascii=False, indent=1))
    sys.exit()
for key, en in json.load(open(sys.argv[1], encoding='utf-8')).items():
    if key not in strings:
        strings[key] = {}
    strings[key].setdefault('localizations', {})['en'] = {'stringUnit': {'state': 'translated', 'value': en}}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cat, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
    f.write('\n')
