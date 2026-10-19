# Trims ECDICT (MIT) to the words worth glossing above a line: word, level, a short Chinese
# gloss, and its inflected forms. Usage: python3 -I ecdict-trim.py <ecdict.csv> <out.tsv>
import csv, re, sys

ORDER = {"zk": 0, "gk": 1, "cet4": 2, "cet6": 3, "ky": 4, "ielts": 5, "toefl": 5, "gre": 6}
POS = re.compile(r"^(?:n|v|vt|vi|adj|a|adv|ad|prep|conj|pron|int|interj|num|art|abbr|aux|pl|suf|pref)\.\s*")

KIND = {"n.": "n", "v.": "v", "vt.": "v", "vi.": "v", "a.": "a", "adj.": "a", "s.": "a", "ad.": "r", "adv.": "r", "r.": "r"}

def senses(translation, prefer=""):
    """The Chinese senses of the first usable line, and its part of speech; the line for the
    part of speech `prefer` ("a", "n", "v", "r") when there is one."""
    lines = translation.replace("\\n", "\n").split("\n")
    if prefer:
        lines = [l for l in lines if KIND.get((POS.match(l.strip()) or [""])[0].strip()) == prefer] + lines
    for line in lines:
        line = line.strip()
        if not line or line.startswith("[网络]") or line.startswith("[人名]") or line.startswith("[地名]"):
            continue
        pos = POS.match(line)
        line = POS.sub("", line)
        line = re.sub(r"\[[^\]]*\]|（[^）]*）|\([^)]*\)|<[^>]*>", "", line).strip()
        parts = [p.strip(" .…") for p in re.split(r"[；;，,、]", line)]
        parts = [p for p in parts if re.search(r"[\u4e00-\u9fff]", p) and not re.search(r"[A-Za-z]", p)]
        if parts:
            return (pos.group(0).strip() if pos else ""), parts
    return "", []

def usual(definition):
    """The part of speech the English definitions start with: the commonest sense."""
    m = POS.match(definition.strip())
    return KIND.get(m.group(0).strip(), "") if m else ""

def gloss(translation, prefer=""):
    pos, parts = senses(translation, prefer)
    if not parts:
        return None
    # An adverb reads best as 普遍地, an adjective as 亲切的, when the dictionary has it.
    end = {"adv.": "地", "ad.": "地", "adj.": "的", "a.": "的"}.get(pos)
    if end:
        parts = [p for p in parts if p.endswith(end)] + parts
    return parts[0][:6]

# Where the dictionary's first sense reads wrong in a book.
FIXES = {"universally": "普遍地", "cordial": "热忱的"}

rows = []
with open(sys.argv[1], newline="", encoding="utf-8") as f:
    entries = {r["word"]: r for r in csv.DictReader(f)}

def adverb(w, g):
    """universally 宇宙 → 普遍地, from universal 普遍的, when the dictionary's own is off."""
    pos, own = senses(entries[w]["translation"])
    if not w.endswith("ly") or g.endswith("地") or KIND.get(pos) != "r":
        return g
    for base in (w[:-2], w[:-3] + "y", w[:-2] + "e", w[:-4] if w.endswith("ally") else ""):
        b = entries.get(base)
        if not b:
            continue
        adjectives = [p for p in senses(b["translation"])[1] if p.endswith("的")]
        # The sense the adverb itself also gives: universal 普遍的 for universally 普遍.
        shared = [p for p in adjectives if p[:-1] in own]
        if shared or adjectives:
            return ((shared or adjectives)[0][:-1] + "地")[:6]
    return g

if True:
    for r in entries.values():
        w = r["word"]
        if not re.fullmatch(r"[a-z]{3,}", w):
            continue
        # An inflected form (cities) goes with its word (city), not on its own.
        lemma = dict(e.partition(":")[::2] for e in r["exchange"].split("/") if ":" in e).get("0")
        if lemma and lemma != w and lemma in entries:
            continue
        tags = r["tag"].split()
        # The easiest exam past 高考 that lists it; 中考 and 高考 alone are words everyone knows.
        levels = [ORDER[t] for t in tags if ORDER.get(t, 0) >= 2]
        bnc, frq = int(r["bnc"] or 0), int(r["frq"] or 0)
        ranks = [n for n in (bnc, frq) if n > 0]
        if ranks and min(ranks) <= 2500:
            continue
        if levels:
            level = min(levels)
        elif any(t in ORDER for t in tags):
            continue
        elif 12000 < bnc <= 60000 and (r["collins"] not in ("", "0") or r["oxford"] == "1"):
            level = 6
        else:
            continue
        g = gloss(r["translation"], usual(r["definition"]))
        if not g:
            continue
        g = FIXES.get(w) or adverb(w, g)
        forms = set()
        for ex in r["exchange"].split("/"):
            k, _, v = ex.partition(":")
            if k in ("p", "d", "i", "3", "s", "r", "t") and re.fullmatch(r"[a-z]{3,}", v) and v != w:
                forms.add(v)
        rows.append((w, level, g, ",".join(sorted(forms))))

with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("# From ECDICT (https://github.com/skywind3000/ECDICT), MIT License, Copyright (c) 2025 Linwei.\n")
    out.write("# word\tlevel (2 四级 3 六级 4 考研 5 雅思 6 GRE)\tgloss\tforms\n")
    for row in sorted(rows):
        out.write("\t".join(map(str, row)) + "\n")
print(len(rows))
