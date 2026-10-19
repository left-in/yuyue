// 中文标点挤压 (contract §3): core marks the full-width punctuation that can give up half an em,
// and the reader undoes the mark (.yy-pz-keep) where the font in use has no blank half to give up.
// Whether a font does is only visible in its ink: WebKit's measureText horizontal bounds are the
// advance box (Songti ，: advance 1.00, box 0.00–1.00, ink 0.18–0.33), so the reader rasterises the
// glyph when the box covers the advance. These tests state the decision each mark must come to, per
// font, in both engines.
import type { Page } from '@playwright/test';
import { test, expect, open } from './util';

type Mark = { kind: 'r' | 'l'; ch: string; next: string; keep: boolean; em: number };

/** Every marked fragment: its class, its glyph, the next non-blank character, keep/trim, and its
 *  width in em (what the mark does to the line). */
function marks(page: Page, compress: boolean): Promise<Mark[]> {
  return page.evaluate((compress) => {
    (window as any).yy.applySettings({ compress });
    const content = document.getElementById('yy-content') as HTMLElement;
    const out: Mark[] = [];
    for (const el of Array.from(content.querySelectorAll('.pz-r, .pz-l'))) {
      const w = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
      w.currentNode = el;
      let next = '';
      for (let t = w.nextNode(); t; t = w.nextNode()) {
        if (el.contains(t)) continue;
        const m = /\S/.exec((t as Text).data);
        if (m) {
          next = m[0];
          break;
        }
      }
      const cs = getComputedStyle(el);
      out.push({
        kind: el.classList.contains('pz-r') ? 'r' : 'l',
        ch: (el.textContent || '').trim(),
        next,
        keep: el.classList.contains('yy-pz-keep'),
        em: el.getBoundingClientRect().width / parseFloat(cs.fontSize),
      });
    }
    return out;
  }, compress);
}

const key = (m: Mark): string => m.kind + m.ch + (m.next || '');
const near = (a: number, b: number, tol = 0.06): boolean => Math.abs(a - b) < tol;

/** Checks the decisions on, and the widths with compress on against compress off. Turning
 *  compression off leaves the classes where they were — nothing untrims (reader.css only reads
 *  them while `data-yy-compress` is `1`), so the width is what tells the two apart. */
function check(on: Mark[], off: Mark[], want: Record<string, boolean>, what: string): void {
  expect(on.length, `${what}: marks`).toBe(off.length);
  const byKey = new Map(off.map((m) => [key(m), m]));
  const seen = new Set<string>();
  for (const m of on) {
    const k = key(m);
    seen.add(k);
    const want_keep = want[k];
    expect(want_keep, `${what}: no expectation for ${JSON.stringify(k)}`).not.toBeUndefined();
    expect(m.keep, `${what}: ${JSON.stringify(k)} should ${want_keep ? 'keep its width' : 'tighten'}`).toBe(want_keep);
    const was = byKey.get(k) as Mark;
    if (want_keep) {
      expect(near(m.em, was.em), `${what}: ${JSON.stringify(k)} keeps its full width (${m.em} vs ${was.em}em)`).toBe(true);
    } else {
      expect(
        near(m.em, was.em - 0.5, 0.15),
        `${what}: ${JSON.stringify(k)} gives up half an em (${m.em} vs ${was.em}em)`,
      ).toBe(true);
    }
  }
  for (const k of Object.keys(want)) expect(seen.has(k), `${what}: ${JSON.stringify(k)} is not in the section`).toBe(true);
}

test('compress on beiying: the font decides, not core markup alone', async ({ page }) => {
  await open(page, 'beiying/s/0.html', { font: 'serif', justify: 0 });
  const off = await marks(page, false);
  const on = await marks(page, true);
  // `“` is drawn narrow (0.39em in Songti, no blank half), so a mark before it stays: tightening
  // one there would close the space around the opening quote instead of around the comma.
  // `！` is centred, so the same. `。` sits in the left half and `”` is not an opening bracket, so
  // that pair tightens.
  check(on, off, { 'r，“': true, 'r！”': true, 'r。”': false }, 'Songti');
  expect(on.filter((m) => key(m) === 'r。”').length, 'the 。” pairs').toBe(4);
});

test('compress with a sans font: the same section, other decisions', async ({ page }) => {
  await open(page, 'beiying/s/0.html', { font: 'sans', justify: 0 });
  const off = await marks(page, false);
  const on = await marks(page, true);
  check(on, off, { 'r，“': true, 'r！”': false, 'r。”': false }, 'PingFang');
});

test('compress around brackets and in runs of punctuation', async ({ page }) => {
  await open(page, 'edge/s/0.html', { font: 'serif', justify: 0 });
  const off = await marks(page, false);
  const on = await marks(page, true);
  // Songti ink, in em of a 1em box: ： 0.19–0.31, “ 0.04–0.35 of 0.39, 》 0.06–0.54, ） 0.13–0.38,
  // ？ 0.12–0.43.
  check(
    on,
    off,
    {
      'r：“': true, // ： has its blank, but the narrow “ after it has none on its left
      'r。”': false,
      'l“红': true, // 《“: the narrow “ has no blank left half to give up
      'r》（': true, // 》 reaches past the middle of its box
      'r》）': true,
      'r）。': false,
      'r？！': false,
    },
    'edge',
  );
});

test('compression off leaves the text alone; no marks is not an error', async ({ page }) => {
  await open(page, 'beiying/s/0.html', { font: 'serif', justify: 0 });
  const off = await marks(page, false);
  const full = off.every((m) => near(m.em, 1, 0.15));
  expect(full, `widths with compression off: ${off.map((m) => m.em).join(', ')}`).toBe(true);

  // A section with no marks at all (hlm is Traditional: only brackets and quotes compress, and this
  // section has none).
  await open(page, 'hlm/s/2.html', { font: 'serif' });
  expect(await marks(page, true)).toEqual([]);
  expect(await page.evaluate(() => (window as any).__yy.filter((m: any) => m.type === 'log').length)).toBe(0);
});
