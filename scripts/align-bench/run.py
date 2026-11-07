"""给对齐打分：考卷是 build.py 拼的，答案精确到采样点。

用法：<装了 librosa、onnxruntime 的 python> scripts/align-bench/run.py [yuyue 程序] [只跑名字里带这个的]

每份：先用 ONNX 模型（和 Android 同一个 8 位模型）算 emissions（存下来，下次不重算），再跑
`yuyue fa`，和 truth.json 比：

- 起点错：一句的起点没落在“上一段话说完 → 这句开口”这段停顿里（前后各宽 0.1 秒），离它超过 0.3 秒。
  听的人的感受就是高亮早了或晚了一截。停顿里哪一点都算对：怎么分停顿是口味，不是错。
- 终点错：同理，“这句说完 → 下一段话开口”。
- 漏了：录音里念了，算法说没有（这句听不到、不亮）。
- 多了：录音里没念，算法却给了时间（会放一段别的话）。
- 多出来的话放出来几秒：不在原文里的话落在某句起止里的秒数（听这句时会听到它）。
达标线：起点错 ≤ 3%。
"""
import json
import os
import subprocess
import sys
import time

import numpy as np

# 数据（下载的语料、拼好的考卷、模型）放在实验盘上，不进仓库。
HERE = os.environ.get("YUYUE_BENCH", "bench")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
CASES = os.path.join(HERE, "cases")
MODEL = os.path.join(LAB, "align", "model", "mms_fa.int8.onnx")
YUYUE = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else os.path.expanduser("~/Developer/yuyue/core/target/release/yuyue")
ONLY = sys.argv[2] if len(sys.argv) > 2 else ""
SLACK = 0.1
LIMIT = 0.3


def emissions(d):
    em = os.path.join(d, "em.f32")
    if not os.path.exists(em):
        subprocess.run([sys.executable, os.path.join(SCRIPTS, "em_onnx.py"), MODEL, os.path.join(d, "audio.wav"), em], check=True, capture_output=True)
    return em


def score(d, lang):
    truth = json.load(open(os.path.join(d, "truth.json")))
    em = emissions(d)
    t0 = time.time()
    out = subprocess.run([YUYUE, "fa", os.path.join(d, "text.tsv"), lang, em, str(truth["seconds"])], capture_output=True, text=True, check=True).stdout
    took = time.time() - t0
    got = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) >= 3:
            got[p[0]] = (float(p[1]), float(p[2]))
    # Everything said, in order: the sentences read and the extra speech.
    said = sorted([tuple(v) for v in truth["sentences"].values() if v] + [tuple(x) for x in truth["extra"]])
    r = dict(n=0, start=0, end=0, missed=0, invented=0, extra_played=0.0, extra=sum(b - a for a, b in truth["extra"]), took=took, bad=[])
    for k, v in truth["sentences"].items():
        s, e = got.get(k, (-1, -1))
        if v is None:
            if s >= 0:
                r["invented"] += 1
                r["bad"].append(f"#{k} 没念，算法给了 {s:.2f}–{e:.2f}")
            continue
        r["n"] += 1
        if s < 0:
            r["missed"] += 1
            r["bad"].append(f"#{k} 念了（{v[0]:.2f}–{v[1]:.2f}），算法说没有")
            continue
        i = said.index(tuple(v))
        lo = said[i - 1][1] if i > 0 else 0.0
        hi = said[i + 1][0] if i + 1 < len(said) else truth["seconds"]
        ds = max(lo - SLACK - s, s - (v[0] + SLACK), 0)
        de = max(v[1] - SLACK - e, e - (hi + SLACK), 0)
        if ds > LIMIT:
            r["start"] += 1
            r["bad"].append(f"#{k} 起点差 {ds:.2f} 秒（算法 {s:.2f}，开口 {v[0]:.2f}，停顿从 {lo:.2f}）")
        if de > LIMIT:
            r["end"] += 1
    spans = [v for v in got.values() if v[0] >= 0]
    for a, b in truth["extra"]:
        for s, e in spans:
            r["extra_played"] += max(0.0, min(b, e) - max(a, s))
    return r


def main():
    books = json.load(open(os.path.join(CASES, "books.json")))
    rows = []
    for name in sorted(os.listdir(CASES)):
        d = os.path.join(CASES, name)
        if not os.path.isdir(d) or ONLY not in name:
            continue
        lang = next(l for b, l in books.items() if name.startswith(b + "-"))
        r = score(d, lang)
        rows.append((name, r))
        wrong = r["start"] + r["missed"] + r["invented"]
        print(f"{name:34s} {r['n']:4d} 句  起点错 {r['start']:3d}  终点错 {r['end']:3d}  漏 {r['missed']:2d}  多 {r['invented']:2d}  "
              f"错率 {wrong / max(1, r['n']):5.1%}  多出来的话放出 {r['extra_played']:4.1f}/{r['extra']:4.1f} 秒  {r['took']:.1f} 秒", flush=True)
        for b in r["bad"][:6]:
            print("    " + b)
    n = sum(r["n"] for _, r in rows)
    wrong = sum(r["start"] + r["missed"] + r["invented"] for _, r in rows)
    played = sum(r["extra_played"] for _, r in rows)
    extra = sum(r["extra"] for _, r in rows)
    print(f"\n合计 {n} 句，错 {wrong}（{wrong / max(1, n):.1%}，达标线 3%）；多出来的话放出 {played:.0f} / {extra:.0f} 秒")
    json.dump({k: {kk: vv for kk, vv in r.items()} for k, r in rows}, open(os.path.join(HERE, "last.json"), "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
