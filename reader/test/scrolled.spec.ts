// Scrolled mode (上下滚动): the band between the top and bottom insets, the page step, and the
// reading position that survives a re-layout or a save-and-restore.
import type { Page } from '@playwright/test';
import { test, expect, open, messages, clearMessages, waitMessages } from './util';

/** The strip text is read in: the viewport between the top and bottom insets (native floats its
 *  bars over the rest), or the whole viewport when the insets would leave less than 0.3 of it. */
function band(page: Page): Promise<{ top: number; bottom: number; h: number; line: number }> {
  return page.evaluate(() => {
    const css = getComputedStyle(document.documentElement);
    const H = innerHeight;
    let top = parseFloat(css.getPropertyValue('--yy-top')) || 0;
    let bottom = H - (parseFloat(css.getPropertyValue('--yy-bottom')) || 0);
    if (bottom - top < H * 0.3) {
      top = 0;
      bottom = H;
    }
    const p = document.querySelector('#yy-content p') as Element;
    return { top, bottom, h: bottom - top, line: parseFloat(getComputedStyle(p).lineHeight) };
  });
}

/** First character on screen, remembered as window.__c: paginated, the first on the current page;
 *  scrolled, the first whose box is at least half below the top of the band (the reader's rule). */
function firstOnScreen(page: Page): Promise<{ s: number; offset: number; top: number; text: string; y: number }> {
  return page.evaluate(() => {
    const scrolled = document.documentElement.getAttribute('data-yy-mode') === 'scrolled';
    const top = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--yy-top')) || 0;
    const on = (b: DOMRect): boolean =>
      scrolled ? b.top + b.height / 2 >= top : b.left + b.width / 2 >= 0 && b.left + b.width / 2 < innerWidth;
    for (const el of Array.from(document.querySelectorAll('#yy-content .s'))) {
      const s = parseInt(el.getAttribute('data-s') as string, 10);
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let t = w.nextNode() as Text | null; t; t = w.nextNode() as Text | null) {
        if (t.parentElement!.closest('rt, rp, .yy-noteref')) continue;
        for (let i = 0; i < t.data.length; i++) {
          if (/\s/.test(t.data[i])) continue;
          const r = document.createRange();
          r.setStart(t, i);
          r.setEnd(t, i + 1);
          const b = r.getClientRects()[0];
          if (b && on(b)) {
            (window as any).__c = { t, i };
            return { s, offset: i, top: b.top, text: t.data.slice(i, i + 12), y: scrollY };
          }
        }
      }
    }
    throw new Error('no text on screen');
  });
}

/** Viewport box of the character remembered by firstOnScreen. */
function marked(page: Page): Promise<{ left: number; top: number; bottom: number } | null> {
  return page.evaluate(() => {
    const { t, i } = (window as any).__c;
    const r = document.createRange();
    r.setStart(t, i);
    r.setEnd(t, i + 1);
    const b = r.getClientRects()[0];
    return b ? { left: b.left, top: b.top, bottom: b.bottom } : null;
  });
}

/** The sentence the latest `scroll` message names: what native saves as the reading position. */
async function savedSentence(page: Page): Promise<number> {
  await page.waitForTimeout(400); // the message for a scroll is posted when it settles
  const all = await messages(page, 'scroll');
  expect(all.length, 'a `scroll` message').toBeGreaterThan(0);
  return all[all.length - 1].sentence;
}

const restoreTop = async (page: Page, s: number): Promise<number> => {
  await page.evaluate((s) => (window as any).yy.scrollToSentence(s, false, { align: 'top' }), s);
  return page.evaluate(() => scrollY);
};

// A size change in paginated mode can leave the sticky anchor anywhere on the page; carried into
// scrolled mode, it went to the top of the band and the page's own top text scrolled out of view.
test('paginated -> scrolled starts the band with the top of the page', async ({ page }) => {
  await open(page, 'pride/s/4.html');
  await page.evaluate(() => (window as any).yy.scrollToPage(3));
  await page.evaluate(() => (window as any).yy.applySettings({ fontSize: 19 }));
  const b = await band(page);
  const pageTop = await firstOnScreen(page);
  expect(pageTop.top, 'the first character of the page is at its top').toBeLessThan(b.top + b.line / 2);

  await page.evaluate(() => (window as any).yy.applySettings({ mode: 'scrolled' }));
  expect(await page.evaluate(() => scrollX)).toBe(0);
  const box = await marked(page);
  expect(box && box.top - b.top, `“${pageTop.text}” on the first line of the band`).toBeGreaterThanOrEqual(-1);
  expect(box && box.top - b.top, `“${pageTop.text}” on the first line of the band`).toBeLessThan(b.line / 2);
  const now = await firstOnScreen(page);
  expect([now.s, now.offset]).toEqual([pageTop.s, pageTop.offset]);
  expect(now.y, 'not the top of the section').toBeGreaterThan(0);

  // And back: the page that holds it.
  await page.evaluate(() => (window as any).yy.applySettings({ mode: 'paginated' }));
  const back = await marked(page);
  expect(back && back.left >= 0 && back.left < 393, 'the character is on the page shown').toBe(true);
});

test('scrolled nextPage/prevPage: a band minus a line, landing on a line, false at the ends', async ({ page }) => {
  test.setTimeout(120_000);
  await open(page, 'hlm/s/2.html', { mode: 'scrolled' });
  const b = await band(page);
  const lines = await page.evaluate(() => {
    const out: { top: number; bottom: number }[] = [];
    for (const el of Array.from(document.querySelectorAll('#yy-content .s'))) {
      for (const r of Array.from(el.getClientRects())) {
        if (r.width || r.height) out.push({ top: r.top + scrollY, bottom: r.bottom + scrollY });
      }
    }
    out.sort((a, c) => a.top - c.top || a.bottom - c.bottom);
    // A paragraph is split at sentence ends, so two boxes can share a line.
    const merged: { top: number; bottom: number }[] = [];
    for (const l of out) {
      const last = merged[merged.length - 1];
      if (last && l.top < last.bottom - 0.5) last.bottom = Math.max(last.bottom, l.bottom);
      else merged.push({ ...l });
    }
    return merged;
  });
  expect(lines.length).toBeGreaterThan(20);

  const ys: number[] = [];
  for (let i = 0; i < 300; i++) {
    ys.push(await page.evaluate(() => scrollY));
    if (!(await page.evaluate(() => (window as any).yy.nextPage(false)))) break;
  }
  expect(ys.length, 'more than one band').toBeGreaterThan(3);
  const end = await page.evaluate(() => scrollY);
  expect(end, 'the last step reaches the bottom').toBe(await page.evaluate(() => (document.scrollingElement as Element).scrollHeight - innerHeight));
  expect(await page.evaluate(() => (window as any).yy.nextPage(false)), 'at the bottom nextPage is false').toBe(false);
  expect(await page.evaluate(() => scrollY), 'and the page does not move').toBe(end);

  const bands = ys.map((y) => ({ top: y + b.top, bottom: y + b.bottom }));
  const inside = (l: { top: number; bottom: number }, w: { top: number; bottom: number }): boolean =>
    l.top >= w.top - 1 && l.bottom <= w.bottom + 1;
  for (let i = 0; i + 1 < bands.length; i++) {
    // No line is cut in half on both screens: the one the band's bottom edge cuts is whole on the
    // next screen, and the one the next band's top edge cuts was whole on this one.
    for (const l of lines) {
      if (l.top < bands[i].bottom - 1 && l.bottom > bands[i].bottom + 1) {
        expect(inside(l, bands[i + 1]), `band ${i + 1} shows the line band ${i} cut at ${Math.round(l.top)}`).toBe(true);
      }
      if (l.top < bands[i + 1].top - 1 && l.bottom > bands[i + 1].top + 1) {
        expect(inside(l, bands[i]), `band ${i} shows the line band ${i + 1} cut at ${Math.round(l.top)}`).toBe(true);
      }
    }
    const step = ys[i + 1] - ys[i];
    expect(step, `step ${i} keeps an overlap`).toBeLessThan(b.h - 1);
    // The last step stops at the bottom of the section, so it can be short.
    if (i + 2 < bands.length) expect(step, `step ${i} overlaps by a few lines at most`).toBeGreaterThan(b.h - 3 * b.line);
  }

  // Stepping back retraces the offsets exactly (Space then Shift-Space shows the screen before).
  for (let i = ys.length - 2; i >= 0; i--) {
    expect(await page.evaluate(() => (window as any).yy.prevPage(false)), `prevPage to band ${i}`).toBe(true);
    expect(Math.abs((await page.evaluate(() => scrollY)) - ys[i]), `back at band ${i}`).toBeLessThan(1);
  }
  expect(await page.evaluate(() => (window as any).yy.prevPage(false)), 'at the top prevPage is false').toBe(false);
  expect(await page.evaluate(() => scrollY)).toBe(0);

  // From a position no step led to, a step back is computed the same way: the old first line is
  // whole at the bottom of the new band.
  await page.evaluate(() => window.scrollTo(0, 5000));
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => (window as any).yy.prevPage(false))).toBe(true);
  const y = await page.evaluate(() => scrollY);
  expect(5000 - y).toBeLessThan(b.h - 1);
  expect(5000 - y).toBeGreaterThan(b.h - 3 * b.line);
  const firstLine = lines.find((l) => l.top >= 5000 + b.top - 1) as { top: number; bottom: number };
  expect(inside(firstLine, { top: y + b.top, bottom: y + b.bottom }), 'the old first line is on the new screen').toBe(true);
});

// A second step must build on the first while the smooth scroll is still running, rather than
// compute from an offset that is still stale and land on the same screen twice.
test('scrolled steps add up while a smooth scroll is on its way', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { mode: 'scrolled', paging: 'snap' });
  const smooth = await page.evaluate(async () => {
    const y = (window as any).yy;
    y.nextPage(true);
    const second = y.nextPage(true); // the first is still on its way: it has not even started
    await new Promise((r) => setTimeout(r, 2000));
    return { second, y: scrollY };
  });
  expect(smooth.second).toBe(true);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
  const instant = await page.evaluate(() => {
    const y = (window as any).yy;
    const one = (y.nextPage(false), scrollY);
    return { one, two: (y.nextPage(false), scrollY) };
  });
  expect(instant.two - instant.one, 'two different steps').toBeGreaterThan(400);
  expect(smooth.y, 'two smooth steps land where two instant ones do').toBe(instant.two);
});

// `scroll` names a sentence and native restores it. The old restore put it a third of the way down,
// so every open/close moved the view up by about a third of a screen.
test('restoring the saved sentence with align top holds the position', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { mode: 'scrolled' });
  const b = await band(page);
  for (const steps of [3, 8, 17]) {
    await page.evaluate((n) => {
      window.scrollTo(0, 0);
      for (let i = 0; i < n; i++) (window as any).yy.nextPage(false);
    }, steps);
    const y0 = await page.evaluate(() => scrollY);
    const s0 = await savedSentence(page);
    // The first restore can move up once, to the start of a sentence the band's top edge cut...
    const y1 = await restoreTop(page, s0);
    expect(y1, `${steps} steps: no move down`).toBeLessThanOrEqual(y0 + 1);
    expect(y0 - y1, `${steps} steps: a move up of part of a sentence at most`).toBeLessThan(b.h / 2);
    // ...after that, save and restore is a fixed point.
    const s1 = await savedSentence(page);
    const y2 = await restoreTop(page, s1);
    const s2 = await savedSentence(page);
    const y3 = await restoreTop(page, s2);
    expect([y2, y3], `${steps} steps: s${s0} -> s${s1} -> s${s2}`).toEqual([y1, y1]);
    expect(s2).toBe(s1);
    // The sentence it names starts on the first line of the band.
    const top = await page.evaluate((s) => (document.querySelector('.s[data-s="' + s + '"]') as Element).getClientRects()[0].top, s1);
    expect(top - b.top, `s${s1} starts the band`).toBeGreaterThanOrEqual(-0.5);
    expect(top - b.top, `s${s1} starts the band`).toBeLessThan(b.line / 2);
  }
});

test('scrolled: default align is a third of the way down; scrollToPage is viewport slices', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { mode: 'scrolled' });
  const third = await page.evaluate(() => {
    const y = (window as any).yy;
    const p = y.scrollToSentence(40, false);
    const top = (document.querySelector('.s[data-s="40"]') as Element).getClientRects()[0].top;
    const p2 = y.scrollToSentence(60, false, {}); // an options object without align: the default
    const top2 = (document.querySelector('.s[data-s="60"]') as Element).getClientRects()[0].top;
    const g = y.geometry();
    return { p, top, p2, top2, pages: [g.sentencePages[40], g.sentencePages[60]] };
  });
  expect(Math.abs(third.top - 852 / 3)).toBeLessThan(1.5);
  expect(Math.abs(third.top2 - 852 / 3)).toBeLessThan(1.5);
  // The return value is the page the sentence starts on (contract §4), counted like sentencePages.
  expect([third.p, third.p2]).toEqual(third.pages);

  const slices = await page.evaluate(() => {
    const y = (window as any).yy;
    const at = (p: number): number[] => [y.scrollToPage(p), scrollY];
    return { first: at(0), third: at(2), past: at(9999), pages: y.geometry().pageCount, max: (document.scrollingElement as Element).scrollHeight - innerHeight };
  });
  expect(slices.first).toEqual([0, 0]);
  expect(slices.third).toEqual([2, 2 * 852]);
  expect(slices.past).toEqual([slices.pages - 1, Math.min((slices.pages - 1) * 852, slices.max)]);
});

test('`scroll` names the sentence at the top of the band; a re-layout keeps the text and re-posts', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { mode: 'scrolled' });
  const b = await band(page);
  await clearMessages(page);
  await page.evaluate(() => window.scrollTo(0, 4000));
  const all = await waitMessages(page, 'scroll');
  await page.waitForTimeout(400);
  const last = (await messages(page, 'scroll')).pop() || all[0];
  expect(last.progress).toBeGreaterThan(0);
  expect(last.progress).toBeLessThan(1);
  const at = await firstOnScreen(page);
  // The sentence of the first character in the band; when that sentence began above the band and
  // the next one starts on the same line, the next one (restoring it shows the same line).
  const expected = await page.evaluate(
    ({ s, top }) => {
      const r = (n: number): DOMRect | undefined => (document.querySelector('.s[data-s="' + n + '"]') as Element | null)?.getClientRects()[0];
      const own = r(s);
      const next = r(s + 1);
      const c = (window as any).__c;
      const range = document.createRange();
      range.setStart(c.t, c.i);
      range.setEnd(c.t, c.i + 1);
      const cb = range.getClientRects()[0];
      return own && own.top + own.height / 2 < top && next && next.top < cb.bottom && next.bottom > cb.top ? s + 1 : s;
    },
    { s: at.s, top: b.top },
  );
  expect(last.sentence).toBe(expected);
  expect(await messages(page, 'page'), 'scrolled mode posts no `page`').toEqual([]);

  // A re-layout moves the text, so the reader re-posts where it is; the character at the top of
  // the band stays where it was.
  await clearMessages(page);
  await page.evaluate(() => (window as any).yy.applySettings({ fontSize: 21 }));
  expect((await messages(page, 'scroll')).length, 'a re-layout posts `scroll`').toBe(1);
  const box = await marked(page);
  expect(Math.abs((box as { top: number }).top - at.top)).toBeLessThan(1.5);

  await page.evaluate(() => window.scrollTo(0, (document.scrollingElement as Element).scrollHeight));
  await page.waitForTimeout(500);
  const tail = await messages(page, 'scroll');
  expect(tail[tail.length - 1].progress).toBe(1);
});
