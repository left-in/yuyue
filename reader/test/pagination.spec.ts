// Page geometry (contract §5, §6) across device sizes, font sizes and documents.
import { test, expect, open, checkPaginated, problems, clearMessages, waitMessages, messages } from './util';

const VIEWPORTS = [
  { name: 'iPhone 393', width: 393, height: 852, cols: 1 },
  { name: 'iPhone Pro Max 430', width: 430, height: 932, cols: 1 },
  { name: 'iPad portrait 820', width: 820, height: 1180, cols: 1 },
  { name: 'iPad landscape 1180 x2', width: 1180, height: 820, cols: 2 },
  { name: 'Mac 1280', width: 1280, height: 800, cols: 2 },
];

const DOCS = [
  'beiying/s/0.html', // 背影, TXT import, zh-CN
  'hlm/s/2.html', // 紅樓夢 ch. 1, zh-Hant, long
  'pride/s/4.html', // Pride and Prejudice ch. I, publisher CSS
  'gatsby/s/4.html', // English, long
  'image/s/0.html', // pictures: wide, taller than a page, late
  'edge/s/0.html', // ruby, footnote, links, punctuation runs
];

const FONT_SIZES = [15, 18, 24];

for (const vp of VIEWPORTS) {
  test.describe(vp.name, () => {
    test.use({ viewport: { width: vp.width, height: vp.height } });
    for (const doc of DOCS) {
      test(doc, async ({ page }) => {
        await open(page, doc, { cols: vp.cols });
        if (doc.startsWith('image/')) await waitMessages(page, 'layout', 1); // the late picture
        for (const fs of FONT_SIZES) {
          await page.evaluate((fs) => (window as any).yy.applySettings({ fontSize: fs }), fs);
          const r = await checkPaginated(page);
          expect(r.problems, `fontSize ${fs}`).toEqual([]);
          expect(r.W).toBe(vp.width);

          // Page step: nextPage moves exactly one page width until it reports the end.
          const walk = await page.evaluate(() => {
            const y = (window as any).yy;
            y.scrollToPage(0);
            const xs: number[] = [];
            const pages: number[] = [];
            for (let i = 0; i < 500 && y.nextPage(false); i++) {
              xs.push(scrollX);
              pages.push(y.currentPage());
            }
            const endX = scrollX;
            const atEnd = y.nextPage(false);
            const back: number[] = [];
            for (let i = 0; i < 500 && y.prevPage(false); i++) back.push(scrollX);
            return { xs, pages, endX, atEnd, afterEnd: scrollX, back, atStart: y.prevPage(false), startX: scrollX };
          });
          const n = r.pageCount;
          expect(walk.xs).toEqual(Array.from({ length: n - 1 }, (_, i) => (i + 1) * vp.width));
          expect(walk.pages).toEqual(Array.from({ length: n - 1 }, (_, i) => i + 1));
          expect(walk.atEnd).toBe(false);
          expect(walk.back).toEqual(Array.from({ length: n - 1 }, (_, i) => (n - 2 - i) * vp.width));
          expect(walk.atStart).toBe(false);
          expect(walk.startX).toBe(0);
        }
        expect(await problems(page)).toEqual([]);
      });
    }
  });
}

test('scrollToPage, scrollToSentence and scrollToAnchor return the page they show', async ({ page }) => {
  await open(page, 'hlm/s/2.html');
  const r = await page.evaluate(() => {
    const y = (window as any).yy;
    const g = y.geometry();
    const last = g.pageCount - 1;
    const s = g.pageFirstSentence[3];
    return {
      last,
      clampHigh: [y.scrollToPage(last + 5), scrollX, y.currentPage()],
      clampLow: [y.scrollToPage(-2), scrollX],
      sentence: [y.scrollToSentence(s), g.sentencePages[s], y.currentPage()],
      missing: y.scrollToAnchor('no-such-id'),
    };
  });
  expect(r.clampHigh).toEqual([r.last, r.last * 393, r.last]);
  expect(r.clampLow).toEqual([0, 0]);
  expect(r.sentence[0]).toBe(r.sentence[1]);
  expect(r.sentence[2]).toBe(r.sentence[1]);
  expect(r.missing).toBe(-1);

  await open(page, 'edge/s/1.html');
  const anchor = await page.evaluate(() => {
    const y = (window as any).yy;
    const el = document.getElementById('part2') as HTMLElement;
    const p = y.scrollToAnchor('part2');
    const box = el.getBoundingClientRect();
    return { p, cur: y.currentPage(), onScreen: box.left >= 0 && box.left < innerWidth };
  });
  expect(anchor.p).toBe(anchor.cur);
  expect(anchor.onScreen).toBe(true);
});

test('snap paging: animated page turns post `page`; currentPage reports the target at once', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { paging: 'snap' });
  await clearMessages(page);
  const r = await page.evaluate(() => {
    const y = (window as any).yy;
    const ok = y.nextPage(true);
    return { ok, logical: y.currentPage(), x: scrollX };
  });
  expect(r.ok).toBe(true);
  expect(r.logical).toBe(1);
  const [msg] = await waitMessages(page, 'page');
  expect(msg).toEqual({ type: 'page', page: 1 });
  expect(await page.evaluate(() => scrollX)).toBe(393);
  // The CSS snaps to whole pages.
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).scrollSnapType)).toContain('x');
});

test('native paging: no snapping, page turns are always instant, no `page` messages', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { paging: 'native' });
  await clearMessages(page);
  const r = await page.evaluate(() => {
    const y = (window as any).yy;
    const ok = y.nextPage(true);
    const x1 = scrollX;
    y.scrollToPage(4, true);
    return { ok, x1, x4: scrollX, snap: getComputedStyle(document.documentElement).scrollSnapType };
  });
  expect(r).toMatchObject({ ok: true, x1: 393, x4: 4 * 393 });
  expect(r.snap === 'none' || r.snap === '').toBe(true);
  await page.waitForTimeout(400);
  expect(await messages(page, 'page')).toEqual([]);
});

test('late pictures re-lay out and post `layout`', async ({ page }) => {
  await open(page, 'image/s/0.html');
  const before = (await messages(page, 'ready'))[0];
  const late = await page.evaluate(() => (document.querySelector('img[src*="late"]') as HTMLImageElement).complete);
  expect(late, 'the late picture should still be loading at `ready`').toBe(false);
  const [layout] = await waitMessages(page, 'layout');
  expect(layout.pageCount).toBeGreaterThanOrEqual(before.pageCount);
  expect((await checkPaginated(page)).problems).toEqual([]);
});

test('picture-only sections are one centred page', async ({ page }) => {
  for (const doc of ['pride/s/0.html', 'hlm/s/0.html']) {
    await open(page, doc);
    const r = await page.evaluate(() => {
      const pic = document.querySelector('#yy-content img, #yy-content svg') as Element;
      const b = pic.getBoundingClientRect();
      return { pages: (window as any).yy.geometry().pageCount, kind: document.documentElement.getAttribute('data-yy-kind'), mid: b.left + b.width / 2, w: b.width, h: b.height };
    });
    expect(r.kind, doc).toBe('image');
    expect(r.pages, doc).toBe(1);
    expect(Math.abs(r.mid - 393 / 2), doc).toBeLessThan(2);
    expect(r.w, doc).toBeGreaterThan(100);
    expect((await checkPaginated(page)).problems, doc).toEqual([]);
  }
});

test('scrolled mode: pages are viewport-high slices and the document scrolls vertically', async ({ page }) => {
  await open(page, 'hlm/s/2.html', { mode: 'scrolled' });
  const r = await page.evaluate(() => {
    const y = (window as any).yy;
    const g = y.geometry();
    const se = document.scrollingElement as Element;
    // sentencePages: page = floor(top of the sentence / viewport height)
    let bad = 0;
    for (let s = 0; s < g.sentencePages.length; s++) {
      const el = document.querySelector('.s[data-s="' + s + '"]') as Element;
      const box = el.getClientRects()[0];
      if (box && Math.floor((box.top + scrollY + box.height / 2) / innerHeight) !== g.sentencePages[s]) bad++;
    }
    return { pageCount: g.pageCount, sh: se.scrollHeight, sw: se.scrollWidth, H: innerHeight, bad };
  });
  expect(r.sw).toBe(393);
  expect(r.sh).toBeGreaterThan(r.H * 5);
  expect(r.pageCount).toBe(Math.ceil((r.sh - 1) / r.H));
  expect(r.bad).toBe(0);
});

test('`ready` waits for web fonts, but not for pictures', async ({ page }) => {
  // The font file is answered (404) after 900ms; the page must be measured with it settled.
  await open(page, 'font/s/0.html', { font: '"YY Slow", serif' });
  const t = await page.evaluate(() => ({
    ready: (window as any).__yyT[(window as any).__yy.findIndex((m: any) => m.type === 'ready')],
    status: (document as any).fonts.status,
  }));
  expect(t.ready).toBeGreaterThan(850);
  expect(t.status).toBe('loaded');
  // A slow picture does not hold `ready` back (WebKit's fonts.ready waits for the load event).
  await open(page, 'image/s/0.html');
  const r = await page.evaluate(() => ({
    ready: (window as any).__yyT[(window as any).__yy.findIndex((m: any) => m.type === 'ready')],
    late: (document.querySelector('img[src*="late"]') as HTMLImageElement).complete,
  }));
  expect(r.late).toBe(false);
  expect(r.ready).toBeLessThan(1200);
});
