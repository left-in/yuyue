#!/usr/bin/env python3
"""把 window-catalog 截好的图攒成一个 index.html 图册。

用法: python3 scripts/window-gallery.py [build/window-catalog]
"""
import html
import sys
from pathlib import Path

out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/window-catalog")
manifest = out / "manifest.tsv"
shots = out / "shots"
rows = [line.rstrip("\n").split("\t", 1) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]

cards = []
for name, what in rows:
    d = shots / name
    pngs = sorted(d.glob("*.png"), key=lambda p: int(p.stem)) if d.is_dir() else []
    if not pngs:
        cards.append(f'<section class="missing"><h2>{html.escape(what)}</h2><p class="meta">{name} 没截到,看 {name}.log</p></section>')
        continue
    figs = []
    for i, p in enumerate(pngs):
        cap = "前台窗口" if i == 0 else f"同一趟的第 {i+1} 扇窗"
        figs.append(
            f'<figure><a href="{p.as_posix()}" target="_blank">'
            f'<img src="{p.as_posix()}" loading="lazy" alt="{html.escape(what)}"></a>'
            f"<figcaption>{cap}</figcaption></figure>"
        )
    cards.append(
        f'<section><h2>{html.escape(what)}</h2><p class="meta"><code>{html.escape(name)}</code></p>'
        f'<div class="row">{"".join(figs)}</div></section>'
    )

ok = sum(1 for c in cards if "missing" not in c)
doc = f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>语阅 · 全窗口图册</title>
<style>
  body {{ font: 15px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 0; background: #f5f4f1; color: #2c2b28; }}
  header {{ padding: 28px 32px 10px; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  header p {{ color: #77756e; margin: 0; }}
  section {{ background: #fff; border-radius: 14px; margin: 18px 32px; padding: 18px 20px; box-shadow: 0 1px 3px rgb(0 0 0 / 6%); }}
  section.missing {{ background: #fdf3f3; }}
  h2 {{ font-size: 16px; margin: 0 0 2px; }}
  .meta {{ color: #98968e; font-size: 12px; margin: 0 0 12px; }}
  .row {{ display: flex; flex-wrap: wrap; gap: 14px; }}
  figure {{ margin: 0; }}
  img {{ max-height: 420px; max-width: 100%; border: 1px solid #e4e2dc; border-radius: 8px; display: block; }}
  figcaption {{ color: #98968e; font-size: 12px; margin-top: 4px; }}
</style></head><body>
<header><h1>语阅 · 全窗口图册</h1><p>{ok} / {len(cards)} 张窗口与弹窗 · 点图看原图(2x) · 重跑: scripts/window-catalog.sh</p></header>
{"".join(cards)}
</body></html>
"""
(out / "index.html").write_text(doc, encoding="utf-8")
print(f"index.html 写好了:{ok}/{len(cards)} 张 → {out / 'index.html'}")
