// The paginated reading position: one definition on both sides of the bridge. Native saves, for
// page p, the first sentence s with sentencePages[s] == p (pageFirstSentence[p] when none starts
// there); the reader keeps the start of that same sentence on screen through relayouts. After a
// resize the page shown is the one sentencePages names for it, so the screen and the saved position
// cannot end up on different pages.
import type { Page } from '@playwright/test';
import { test, expect, open, clearMessages, waitMessages } from './util';

type Saved = { p: number; s: number; starts: boolean };

/** What native saves for the page shown; `starts` is false on a page no sentence starts on. */
function saved(page: Page): Promise<Saved> {
  return page.evaluate(() => {
    const y = (window as any).yy;
    const g = y.geometry();
    const p = y.currentPage();
    for (let s = g.pageFirstSentence[p]; s >= 0 && s < g.sentencePages.length; s++) {
      if (g.sentencePages[s] > p) break;
      if (g.sentencePages[s] === p) return { p, s, starts: true };
    }
    return { p, s: g.pageFirstSentence[p], starts: false };
  });
}

/** The reader's position (debug API) with the page shown and the page its sentence starts on. */
function where(page: Page): Promise<{ s: number; offset: number; page: number; sPage: number }> {
  return page.evaluate(() => {
    const y = (window as any).yy;
    const a = y.anchor();
    return { s: a.s, offset: a.offset, page: y.currentPage(), sPage: y.geometry().sentencePages[a.s] };
  });
}

/** Resizes and waits for the relayout (a new page size always changes the geometry). */
async function resize(page: Page, width: number, height: number): Promise<void> {
  // A moment first: an earlier resize can still have a relayout on its way, and clearing that one
  // would leave this call waiting for a message that has already gone.
  await page.waitForTimeout(50);
  await clearMessages(page);
  await page.setViewportSize({ width, height });
  await waitMessages(page, 'layout');
}

test.describe('760x480', () => {
  test.use({ viewport: { width: 760, height: 480 } });

  test('every page: the reader keeps the sentence native saves, and a resize shows the page it starts on', async ({ page }) => {
    await open(page, 'beiying/s/0.html', { font: 'serif' });
    const n = await page.evaluate(() => (window as any).yy.geometry().pageCount);
    expect(n).toBeGreaterThan(3);
    for (let p = 0; p < n; p++) {
      await page.evaluate((p) => (window as any).yy.scrollToPage(p), p);
      const save = await saved(page);
      expect(save.starts, `a sentence starts on page ${p}`).toBe(true);
      expect((await where(page)).s, `page ${p}: the reader's position is the saved sentence`).toBe(save.s);

      await resize(page, 760, 875);
      const tall = await where(page);
      expect(tall.s, `page ${p} at 875: same sentence`).toBe(save.s);
      expect(tall.page, `page ${p} at 875: the page s${save.s} starts on`).toBe(tall.sPage);

      await resize(page, 760, 480);
      expect(await where(page), `page ${p} at 480 again`).toMatchObject({ s: save.s, page: p });
    }
  });

  // Native's live window resize goes through every size in between; a relayout at each must not
  // move the position (it is kept, not taken again from the page each relayout lands on).
  test('a resize in steps, there and back, stays with the sentence', async ({ page }) => {
    await open(page, 'beiying/s/0.html', { font: 'serif' });
    await page.evaluate(() => (window as any).yy.scrollToPage(3));
    const save = await saved(page);
    for (const h of [520, 600, 680, 760, 875, 800, 700, 560, 480]) {
      await resize(page, 760, h);
      const w = await where(page);
      expect(w.s, `at ${h}`).toBe(save.s);
      expect(w.page, `at ${h}: the page s${save.s} starts on`).toBe(w.sPage);
    }
    expect((await where(page)).page).toBe(3);
  });

  test('after scrollToSentence the sentence is the position, until the page turns', async ({ page }) => {
    await open(page, 'beiying/s/0.html', { font: 'serif' });
    // A sentence that starts on its page after another one does (not the one a page turn names).
    const s = await page.evaluate(() => {
      const g = (window as any).yy.geometry();
      for (let s = 1; s < g.sentencePages.length; s++) {
        if (g.sentencePages[s] > 0 && g.sentencePages[s] === g.sentencePages[s - 1] && g.pageFirstSentence[g.sentencePages[s]] < s - 1) return s;
      }
      return -1;
    });
    expect(s).toBeGreaterThan(0);
    const p = await page.evaluate((s) => (window as any).yy.scrollToSentence(s), s);
    expect(p).toBe(await page.evaluate((s) => (window as any).yy.geometry().sentencePages[s], s));
    expect((await where(page)).s).toBe(s);
    for (const h of [875, 600, 480]) {
      await resize(page, 760, h);
      const w = await where(page);
      expect(w.s, `at ${h}`).toBe(s);
      expect(w.page, `at ${h}: the page s${s} starts on`).toBe(w.sPage);
    }
    expect((await where(page)).page).toBe(p);
    // A page turn makes the page's own sentence the position again.
    await page.evaluate(() => (window as any).yy.nextPage());
    await page.evaluate(() => (window as any).yy.prevPage());
    expect((await where(page)).s).toBe((await saved(page)).s);
  });

  test('switching into paginated mode takes the sentence native saves for the page it lands on', async ({ page }) => {
    await open(page, 'beiying/s/0.html', { font: 'serif', mode: 'scrolled' });
    await page.evaluate(() => window.scrollTo(0, 1500));
    await page.waitForTimeout(400);
    await page.evaluate(() => (window as any).yy.applySettings({ mode: 'paginated' }));
    const save = await saved(page);
    expect(save.p).toBeGreaterThan(0);
    expect((await where(page)).s).toBe(save.s);
    await resize(page, 760, 875);
    const w = await where(page);
    expect(w.s).toBe(save.s);
    expect(w.page).toBe(w.sPage);
  });
});

// A long sentence can fill a page so that none starts on it. The sentence index alone cannot name
// that page (native's saved sentence restores the page where it starts, the one before); the reader
// keeps the page's own first character, so a relayout there and back returns to the same page.
test.describe('393x500', () => {
  test.use({ viewport: { width: 393, height: 500 } });

  test('a page no sentence starts on keeps its first character', async ({ page }) => {
    await open(page, 'hlm/s/2.html', { font: 'serif', fs: 30 });
    const p = await page.evaluate(() => {
      const g = (window as any).yy.geometry();
      for (let p = 1; p < g.pageCount; p++) if (g.pageFirstSentence[p] >= 0 && !g.sentencePages.includes(p)) return p;
      return -1;
    });
    expect(p, 'a page that no sentence starts on').toBeGreaterThan(0);
    await page.evaluate((p) => (window as any).yy.scrollToPage(p), p);
    const save = await saved(page);
    expect(save.starts).toBe(false);
    const w = await where(page);
    expect(w.s).toBe(save.s);
    expect(w.offset, 'mid-sentence: the first character on the page').toBeGreaterThan(0);
    await resize(page, 393, 620);
    await resize(page, 393, 500);
    expect((await where(page)).page).toBe(p);
  });
});
