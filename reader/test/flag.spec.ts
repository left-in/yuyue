// 有声书 (yy.setFlag): an amber line beside the paragraphs of a stretch the recording doesn't
// line up with, without moving the text.
import { test, expect, open, SCREENS } from './util';

test('setFlag marks the paragraphs holding the sentences, and moves nothing', async ({ page }) => {
  await open(page, 'beiying/s/0.html');
  const before = await page.evaluate(() => {
    const el = document.querySelector('#yy-content .s[data-s="3"]') as HTMLElement;
    return el.getClientRects()[0].left;
  });
  const flagged = await page.evaluate(() => {
    (window as any).yy.setFlag(3, 4);
    return [...document.querySelectorAll('.yy-flag')].map((el) => getComputedStyle(el).backgroundImage);
  });
  expect(flagged.length).toBeGreaterThan(0);
  for (const b of flagged) expect(b).toContain('gradient');
  const after = await page.evaluate(() => (document.querySelector('#yy-content .s[data-s="3"]') as HTMLElement).getClientRects()[0].left);
  expect(after).toBe(before);
  await page.screenshot({ path: `${SCREENS}/flag.png` });
  await page.evaluate(() => (window as any).yy.setFlag(null));
  expect(await page.locator('.yy-flag').count()).toBe(0);
  // The chapter heading too.
  const heading = await page.evaluate(() => {
    (window as any).yy.setFlag(0, 0);
    const el = document.querySelector('.yy-flag');
    return el ? el.tagName + ' ' + getComputedStyle(el).backgroundImage : null;
  });
  expect(heading).toContain('gradient');
  await page.screenshot({ path: `${SCREENS}/flag-heading.png` });
});
