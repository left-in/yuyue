#!/usr/bin/env python3
"""English for the Android app, from the same catalog the Apple app uses.

Kotlin code says `t("已导入 %lld 本书", n)`: the Chinese is the key, exactly as in
apple/Yuyue/Localizable.xcstrings (Swift format specifiers and all). Words only Android has go in
android/app/src/main/l10n/extra-en.json. Writes one JSON table, key -> English, where a plural is
{"one": …, "other": …} and a key with several counts is {"text": "…%#@n@…", "subs": {"n":
[argument, specifier, one, other]}} (see scripts/l10n-plurals.py).

usage: l10n-android.py OUT.json
"""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cat = json.load(open(os.path.join(root, 'apple/Yuyue/Localizable.xcstrings'), encoding='utf-8'))
out = {}
for key, entry in cat['strings'].items():
    en = entry.get('localizations', {}).get('en')
    if not en:
        continue
    if 'substitutions' in en:
        out[key] = {'text': en['stringUnit']['value'], 'subs': {
            name: [s['argNum'], s['formatSpecifier'], s['variations']['plural']['one']['stringUnit']['value'],
                   s['variations']['plural']['other']['stringUnit']['value']]
            for name, s in en['substitutions'].items()}}
    elif 'stringUnit' in en:
        out[key] = en['stringUnit']['value']
    elif 'variations' in en and 'plural' in en['variations']:
        p = en['variations']['plural']
        out[key] = {k: v['stringUnit']['value'] for k, v in p.items()}
extra = os.path.join(root, 'android/app/src/main/l10n/extra-en.json')
if os.path.exists(extra):
    out.update(json.load(open(extra, encoding='utf-8')))
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
json.dump(out, open(sys.argv[1], 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'), sort_keys=True)
