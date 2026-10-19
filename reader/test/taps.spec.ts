// `tap` messages (contract §5): only real taps, with the sentence or link under the finger.
import type { Page } from '@playwright/test';
import { test, expect, open, clearMessages, messages, waitMessages, pointOfSentence } from './util';

/** Viewport centre of the first box of `selector`, after bringing it on screen (paginated). */
async function pointOf(page: Page, selector: string): Promise<{ x: number; y: number }> {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel) as HTMLElement;
    if (el.id) (window as any).yy.scrollToAnchor(el.id);
    else {
      // The page its first box is on (a sentence can go on to the next page; a noteref is in none).
      const b = el.getClientRects()[0];
      (window as any).yy.scrollToPage(Math.floor((b.left + scrollX + b.width / 2) / innerWidth));
    }
    const r = el.getClientRects()[0];
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }, selector);
}

/** Taps posted within `ms` (mouse taps wait out the double-click delay before posting). */
async function tapsAfter(page: Page, ms = 500): Promise<any[]> {
  await page.waitForTimeout(ms);
  return messages(page, 'tap');
}

test('a tap on a sentence reports its index, the point and the viewport size', async ({ page }) => {
  await open(page, 'beiying/s/0.html');
  await clearMessages(page);
  const p = await pointOfSentence(page, 2);
  const t0 = await page.evaluate(() => performance.now());
  await page.mouse.click(p.x, p.y);
  const [tap] = await waitMessages(page, 'tap');
  expect(tap).toMatchObject({ type: 'tap', width: 393, height: 852, sentence: 2, link: null });
  expect(Math.abs(tap.x - p.x)).toBeLessThanOrEqual(1);
  expect(Math.abs(tap.y - p.y)).toBeLessThanOrEqual(1);
  // A mouse tap waits out the double-click interval, so a double click is not also a tap.
  const t = await page.evaluate(() => (window as any).__yyT[0]);
  expect(t - t0).toBeGreaterThanOrEqual(250);
});

test('between the lines a tap finds the sentence of that line; in the margin, none', async ({ page }) => {
  await open(page, 'beiying/s/0.html');
  const p = await page.evaluate(() => {
    const r = document.querySelector('.s[data-s="1"]')!.getClientRects()[0];
    return { x: r.left + 20, y: r.bottom + 5 };
  });
  const hit = await page.evaluate(({ x, y }) => (document.elementFromPoint(x, y) as Element).closest('.s') === null, p);
  expect(hit, 'the point should be in the gap between two lines').toBe(true);
  await clearMessages(page);
  await page.mouse.click(p.x, p.y);
  expect((await waitMessages(page, 'tap'))[0].sentence).toBe(1);

  await clearMessages(page);
  await page.mouse.click(6, 420);
  expect((await waitMessages(page, 'tap'))[0]).toMatchObject({ sentence: null, link: null, x: 6, y: 420 });
});

test('links: internal and external targets, reported at once, never followed', async ({ page }) => {
  await open(page, 'edge/s/0.html');
  const url = page.url();
  const cases = [
    { sel: 'a[data-yy-target="1#part2"]', link: { target: '1#part2' }, sentence: 15 },
    { sel: 'a[data-yy-external]', link: { external: 'https://example.com/' }, sentence: 15 },
    { sel: 'a.yy-noteref', link: { target: '0#fn1' }, sentence: null },
  ];
  for (const c of cases) {
    const p = await pointOf(page, c.sel);
    await clearMessages(page);
    const t0 = await page.evaluate(() => performance.now());
    await page.mouse.click(p.x, p.y);
    const [tap] = await waitMessages(page, 'tap');
    expect(tap, c.sel).toMatchObject({ link: c.link, sentence: c.sentence });
    const t = await page.evaluate(() => (window as any).__yyT[0]);
    expect(t - t0, c.sel + ': link taps do not wait for a double click').toBeLessThan(200);
    expect(page.url()).toBe(url);
  }
});

test('no tap after a drag, a long press or a double click, or while text is selected', async ({ page }) => {
  await open(page, 'beiying/s/0.html');
  const p = await pointOfSentence(page, 2);

  await clearMessages(page);
  await page.mouse.move(p.x, p.y);
  await page.mouse.down();
  await page.mouse.move(p.x + 40, p.y + 2, { steps: 5 });
  await page.mouse.up();
  expect(await tapsAfter(page), 'drag').toEqual([]);
  await page.evaluate(() => getSelection()!.removeAllRanges());

  // A small wobble inside the slop is still a tap.
  await clearMessages(page);
  await page.mouse.move(p.x, p.y);
  await page.mouse.down();
  await page.mouse.move(p.x + 3, p.y + 2);
  await page.mouse.up();
  expect((await tapsAfter(page)).length, 'wobble').toBe(1);

  await clearMessages(page);
  await page.mouse.move(p.x, p.y);
  await page.mouse.down();
  await page.waitForTimeout(650);
  await page.mouse.up();
  expect(await tapsAfter(page), 'long press').toEqual([]);

  await clearMessages(page);
  await page.mouse.dblclick(p.x, p.y);
  expect(await tapsAfter(page), 'double click').toEqual([]);

  // With a selection on screen, the next tap only dismisses it.
  await page.evaluate(() => {
    const t = document.querySelector('.s[data-s="1"]')!.firstChild as Text;
    getSelection()!.setBaseAndExtent(t, 0, t, 4);
  });
  await clearMessages(page);
  await page.mouse.click(p.x, p.y);
  expect(await tapsAfter(page), 'selection').toEqual([]);
});

test('a swipe that moved the page is not a tap', async ({ page }) => {
  await open(page, 'beiying/s/0.html', { paging: 'snap' });
  const p = await pointOfSentence(page, 2);
  await clearMessages(page);
  await page.mouse.move(p.x, p.y);
  await page.mouse.down();
  // The scroll view takes the gesture over and pages; the finger lifts where it went down.
  await page.evaluate(() => window.scrollTo(innerWidth, 0));
  await page.mouse.up();
  expect(await tapsAfter(page)).toEqual([]);
});
