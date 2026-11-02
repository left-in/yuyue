#!/usr/bin/env python3
"""The phrases whose reading the per-character default gets wrong (行长 háng zhǎng, 银行 yín háng),
for the core's 读音 (core/yuyue-core/data/pinyin-phrases.txt).

From pypinyin's phrase list (MIT, github.com/mozillazg/python-pinyin): a phrase is kept only when
some character in it reads otherwise than that character's first reading. One line a phrase:
the phrase, a tab, its syllables with the tone as a number (hang2 zhang3), space-separated.

usage: pinyin-phrases.py <pypinyin package dir> OUT
"""
import json, os, sys, unicodedata

pkg, out = sys.argv[1], sys.argv[2]
phrases = json.load(open(os.path.join(pkg, 'phrases_dict.json'), encoding='utf-8'))
chars = json.load(open(os.path.join(pkg, 'pinyin_dict.json'), encoding='utf-8'))

MARKS = {'̄': '1', '́': '2', '̌': '3', '̀': '4'}

def numbered(syl):
    d = unicodedata.normalize('NFD', syl)
    tone = next((MARKS[c] for c in d if c in MARKS), '5')
    base = ''.join(c for c in d if c not in MARKS).replace('ü', 'v').replace('ü', 'v')
    return base + tone

def plain(syl):
    return numbered(syl)[:-1]

def default(c):
    v = chars.get(str(ord(c)))
    return plain(v.split(',')[0]) if v else None

kept = []
for p, readings in phrases.items():
    syls = [r[0] for r in readings]
    if len(syls) != len(p):
        continue
    if any(default(c) not in (None, plain(s)) for c, s in zip(p, syls)):
        kept.append(f"{p}\t{' '.join(numbered(s) for s in syls)}")
kept.sort()
with open(out, 'w', encoding='utf-8') as f:
    f.write('# From pypinyin (MIT License, Copyright (c) 2016 mozillazg, 闲耘): phrases read otherwise than their characters.\n')
    f.write('\n'.join(kept) + '\n')
print(len(kept), 'of', len(phrases))
