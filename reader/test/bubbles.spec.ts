// 气泡模式 (yy.setBubbles): quotes become bubbles with who says them; every sentence keeps its
// text and number, so the ink line, marks and taps keep working; null puts it all back.
// test/fixtures/hlm/script-2.json is `yuyue lines-json` for this section.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, expect, open, SCREENS, checkPaginated } from './util';

const here = path.dirname(fileURLToPath(import.meta.url));
const script = JSON.parse(fs.readFileSync(path.join(here, 'fixtures/hlm/script-2.json'), 'utf8')) as any[];
const palette = ['#3E6FA8', '#B5523E', '#A87A1F', '#3E8F62', '#7A5AA6', '#A4506F', '#5E7F86'];
const lines = script.map((l) => {
  const who: string | null = l.who;
  const k = who ? [...who].reduce((a, c) => a + c.codePointAt(0)!, 0) % palette.length : 0;
  return { ...l, avatar: who ? [...who].slice(-1)[0] : '?', color: palette[k], right: false };
});

function texts(): string[] {
  const y = (window as any).yy;
  const n = y.geometry().sentencePages.length;
  const out: string[] = [];
  for (let s = 0; s < n; s++) {
    out.push(Array.from(document.querySelectorAll('#yy-content .s[data-s="' + s + '"]')).map((e) => e.textContent).join(''));
  }
  return out;
}

test('setBubbles keeps every sentence and puts them back', async ({ page }) => {
  await open(page, 'hlm/s/2.html');
  const before = await page.evaluate(texts);
  await page.evaluate((ls) => (window as any).yy.setBubbles(ls), lines);
  const bubbles = await page.locator('.yy-bq').count();
  expect(bubbles).toBeGreaterThan(10);
  expect(await page.evaluate(texts)).toEqual(before);
  expect((await checkPaginated(page)).problems).toEqual([]);
  await page.screenshot({ path: `${SCREENS}/bubbles.png` });
  await page.evaluate(() => (window as any).yy.scrollToSentence(40, false));
  await page.screenshot({ path: `${SCREENS}/bubbles-40.png` });
  await page.evaluate(() => (window as any).yy.setBubbles(null));
  expect(await page.locator('.yy-bq').count()).toBe(0);
  expect(await page.evaluate(texts)).toEqual(before);
});
