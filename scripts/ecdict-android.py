#!/usr/bin/env python3
"""The Android app's English dictionary, from ECDICT (MIT): Android has no system dictionary
like Apple's, so 点词 looks words up here.

Keeps the words worth having on a phone — the 60,000 commonest (by BNC and modern frequency)
and every word on an exam list — each with its phonetic and up to three lines of Chinese senses,
and the inflected forms that point back to their word. Writes one sorted TSV:

  word \t phonetic \t senses (lines joined with \\n)
  form \t =word

usage: python3 -I ecdict-android.py <ecdict.csv> <out.tsv>
"""
import csv, re, sys

csv.field_size_limit(1 << 24)
src, out = sys.argv[1], sys.argv[2]
LIMIT = 60000
words = {}
forms = {}
with open(src, encoding='utf-8') as f:
    for r in csv.DictReader(f):
        w = r['word'].strip()
        if not w or not re.fullmatch(r"[A-Za-z][A-Za-z' -]*", w) or len(w) > 40:
            continue
        bnc = int(r['bnc'] or 0)
        frq = int(r['frq'] or 0)
        common = (0 < bnc <= LIMIT) or (0 < frq <= LIMIT)
        if not (common or r['tag'].strip()):
            continue
        lines = []
        for line in r['translation'].replace('\\n', '\n').split('\n'):
            line = line.strip()
            if not line or line.startswith('[网络]') or line.startswith('[人名]') or line.startswith('[地名]'):
                continue
            lines.append(line[:80])
            if len(lines) == 3:
                break
        if not lines:
            continue
        key = w.lower()
        rank = min(x for x in (bnc, frq, 10**9) if x > 0)
        if key in words and words[key][2] <= rank:
            continue
        words[key] = (r['phonetic'].strip(), '\\n'.join(lines), rank)
        for part in r['exchange'].split('/'):
            kind, _, form = part.partition(':')
            form = form.strip().lower()
            # Past, participles, -ing, third person, plural, comparative, superlative.
            if kind in ('p', 'd', 'i', '3', 's', 'r', 't') and form and form != key:
                forms.setdefault(form, key)
with open(out, 'w', encoding='utf-8') as f:
    f.write('# From ECDICT (https://github.com/skywind3000/ECDICT), MIT License, Copyright (c) Linwei.\n')
    rows = [(w, f"{p}\t{s}") for w, (p, s, _) in words.items()]
    rows += [(form, f"={w}") for form, w in forms.items() if form not in words]
    for w, rest in sorted(rows):
        f.write(f"{w}\t{rest}\n")
print(len(words), 'words,', sum(1 for x in forms if x not in words), 'forms')
