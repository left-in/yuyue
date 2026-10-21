#!/usr/bin/env python3
"""English singular and plural for counted words, written into the Apple catalog.

scripts/l10n-plurals.json lists, for each key, either {"one": …, "other": …} (a key with one
count) or {"text": "…%#@n@…", "subs": {"n": [argument, specifier, one, other]}} (a key with
several values, each count chosen on its own; `%arg` stands for the count). The Android app
reads the same catalog (scripts/l10n-android.py).

usage: l10n-plurals.py
"""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(root, 'apple/Yuyue/Localizable.xcstrings')
cat = json.load(open(path, encoding='utf-8'))
table = json.load(open(os.path.join(root, 'scripts/l10n-plurals.json'), encoding='utf-8'))


def unit(s):
    return {'stringUnit': {'state': 'translated', 'value': s}}


for key, p in table.items():
    entry = cat['strings'].setdefault(key, {})
    if 'subs' in p:
        en = unit(p['text'])
        en['substitutions'] = {
            name: {'argNum': n, 'formatSpecifier': spec,
                   'variations': {'plural': {'one': unit(one), 'other': unit(other)}}}
            for name, (n, spec, one, other) in p['subs'].items()
        }
    else:
        en = {'variations': {'plural': {'one': unit(p['one']), 'other': unit(p['other'])}}}
    entry.setdefault('localizations', {})['en'] = en
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cat, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
    f.write('\n')
