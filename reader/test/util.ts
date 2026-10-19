// Shared test helpers. Every page gets a stub of the native bridge before any script runs:
// WebKit tests stub Apple's webkit.messageHandlers.yy, Chromium tests Android's yyNative (which
// receives JSON strings), so both bridge paths are covered. Messages land in window.__yy with
// their arrival times in window.__yyT.
import { test as base, expect, Page } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export { expect };

export const SCREENS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'test-results', 'screens');

export type Msg = { type: string; [k: string]: any };

function bridgeStub(kind: 'apple' | 'android'): void {
  const w = window as any;
  w.__yy = [];
  w.__yyT = [];
  const push = (m: unknown): void => {
    w.__yy.push(m);
    w.__yyT.push(performance.now());
  };
  if (kind === 'apple') {
    // Structured clone, as WKScriptMessageHandler would see it.
    w.webkit = { messageHandlers: { yy: { postMessage: (m: unknown) => push(JSON.parse(JSON.stringify(m))) } } };
  } else {
    w.yyNative = { postMessage: (s: string) => push(JSON.parse(s)) };
  }
}

export const test = base.extend<{ pageErrors: string[] }>({
  pageErrors: [
    async ({ page }, use) => {
      const errors: string[] = [];
      page.on('pageerror', (e) => errors.push(e.message));
      await use(errors);
      expect(errors, 'uncaught errors in the page').toEqual([]);
    },
    { auto: true },
  ],
  page: async ({ page, browserName }, use) => {
    await page.addInitScript(bridgeStub, browserName === 'webkit' ? 'apple' : 'android');
    await use(page);
  },
});

/** Loads a fixture section (path under test/fixtures, e.g. 'hlm/s/2.html') and waits for `ready`. */
export async function open(page: Page, doc: string, q: Record<string, string | number> = {}): Promise<void> {
  const qs = new URLSearchParams(Object.entries(q).map(([k, v]) => [k, String(v)])).toString();
  // Not the default waitUntil 'load': that would also wait for the late pictures.
  await page.goto('/book/' + doc + (qs ? '?' + qs : ''), { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => (window as any).__yy.some((m: Msg) => m.type === 'ready'));
}

export function messages(page: Page, type?: string): Promise<Msg[]> {
  return page.evaluate((t) => (window as any).__yy.filter((m: Msg) => !t || m.type === t), type);
}

export function clearMessages(page: Page): Promise<void> {
  return page.evaluate(() => {
    (window as any).__yy.length = 0;
    (window as any).__yyT.length = 0;
  });
}

/** Waits until at least `n` messages of `type` have arrived (counting from the last clear). */
export async function waitMessages(page: Page, type: string, n = 1, timeout = 5000): Promise<Msg[]> {
  await page.waitForFunction(
    ([t, k]) => (window as any).__yy.filter((m: Msg) => m.type === t).length >= (k as number),
    [type, n] as const,
    { timeout },
  );
  return messages(page, type);
}

/** Reader log messages at warn or error level. */
export async function problems(page: Page): Promise<string[]> {
  return (await messages(page, 'log')).filter((m) => m.level === 'warn' || m.level === 'error').map((m) => m.message);
}

/** Viewport point at the middle of the first line box of sentence `s` (optionally of a fragment
 *  whose text matches). */
export function pointOfSentence(page: Page, s: number): Promise<{ x: number; y: number }> {
  return page.evaluate((s) => {
    for (const el of Array.from(document.querySelectorAll('.s[data-s="' + s + '"]'))) {
      for (const r of Array.from(el.getClientRects())) {
        if (r.width > 8 && r.left >= 0 && r.right <= innerWidth) return { x: r.left + Math.min(r.width / 2, 40), y: r.top + r.height / 2 - 1 };
      }
    }
    throw new Error('sentence ' + s + ' has no box on screen');
  }, s);
}

/** Invariants of the paginated layout (contract §5, §6), checked against the live DOM. Runs in
 *  the page; returns a list of problems (empty when all hold). */
export function checkPaginated(page: Page): Promise<{ problems: string[]; pageCount: number; W: number; sentences: number }> {
  return page.evaluate(() => {
    const y = (window as any).yy;
    const g = y.geometry();
    const W: number = g.pageWidth;
    const H: number = g.pageHeight;
    const out: string[] = [];
    const se = document.scrollingElement as Element;
    const css = getComputedStyle(document.documentElement);
    const px = (n: string): number => parseFloat(css.getPropertyValue(n));
    const margin = px('--yy-margin');
    const cols = parseInt(css.getPropertyValue('--yy-cols'), 10) || 1;
    const colH = H - px('--yy-top') - px('--yy-bottom');
    if (W !== Math.floor(innerWidth)) out.push(`pageWidth ${W} != innerWidth ${innerWidth}`);
    if (H !== Math.floor(innerHeight)) out.push(`pageHeight ${H} != innerHeight ${innerHeight}`);
    if (se.scrollWidth !== g.pageCount * W) out.push(`scrollWidth ${se.scrollWidth} != ${g.pageCount} * ${W}`);
    if (se.scrollHeight > H) out.push(`scrolls vertically: scrollHeight ${se.scrollHeight} > ${H}`);
    if (g.pageFirstSentence.length !== g.pageCount) out.push('pageFirstSentence has ' + g.pageFirstSentence.length + ' entries');

    const sx = scrollX;
    const pageOf = (r: DOMRect): number => Math.floor((r.left + sx + r.width / 2) / W);
    // Nothing straddles two pages: every box lies inside one page between the side margins.
    const inPage = (r: DOMRect, what: string): void => {
      const p = pageOf(r);
      const l = r.left + sx - p * W;
      const rr = r.right + sx - p * W;
      if (l < margin - 2 || rr > W - margin + 2) out.push(`${what} box ${Math.round(l)}..${Math.round(rr)} crosses the edge of page ${p}`);
    };

    const frags = Array.from(document.querySelectorAll('#yy-content .s[data-s]'));
    let n = 0;
    for (const el of frags) n = Math.max(n, parseInt(el.getAttribute('data-s') as string, 10) + 1);
    if (g.sentencePages.length !== n) out.push(`sentencePages has ${g.sentencePages.length} entries for ${n} sentences`);
    const first: number[] = [];
    const pf: number[] = [];
    for (let p = 0; p < g.pageCount; p++) pf.push(-1);
    for (const el of frags) {
      const s = parseInt(el.getAttribute('data-s') as string, 10);
      for (const r of Array.from(el.getClientRects())) {
        if (!r.width && !r.height) continue;
        const p = pageOf(r);
        if (first[s] === undefined) first[s] = p;
        if (p >= 0 && p < pf.length && (pf[p] < 0 || s < pf[p])) pf[p] = s;
        inPage(r, 'sentence ' + s);
      }
    }
    for (let s = 1; s < n; s++) if (g.sentencePages[s] < g.sentencePages[s - 1]) out.push(`sentencePages decreases at ${s}`);
    for (let s = 0; s < n; s++) {
      if (first[s] !== undefined && first[s] !== g.sentencePages[s]) out.push(`sentence ${s} starts on page ${first[s]}, reported ${g.sentencePages[s]}`);
    }
    for (let p = 0; p < g.pageCount; p++) {
      if (pf[p] !== g.pageFirstSentence[p]) out.push(`page ${p}: first sentence ${pf[p]}, reported ${g.pageFirstSentence[p]}`);
    }
    // Pictures fit one column and the page height.
    for (const el of Array.from(document.querySelectorAll('#yy-content img, #yy-content svg'))) {
      if (el.closest('svg') !== el && el.nodeName.toLowerCase() === 'svg') continue;
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) continue;
      if (r.width > W / cols - 2 * margin + 1) out.push(`picture ${Math.round(r.width)}px wider than a column`);
      if (r.height > colH + 1) out.push(`picture ${Math.round(r.height)}px taller than the page (${colH})`);
      inPage(r, 'picture');
    }
    return { problems: out.slice(0, 12).concat(out.length > 12 ? ['… ' + (out.length - 12) + ' more'] : []), pageCount: g.pageCount, W, sentences: n };
  });
}
