// yy.applySettings: maps the camelCase keys of contract §4 onto the <html> attributes and
// custom properties of §2. A missing key keeps its value; null (or 'auto') falls back to the
// paper default, or to the template default for keys that have no paper default.

export interface Settings {
  paper?: string | null;
  /** 我的纸: its colours over the preset's, as `--yy-p-bg:#…;…;color-scheme:…` (null: none). */
  paperStyle?: string | null;
  /** 纹理 on 我的纸: 'grain' | 'xuan' | 'linen' (null: none). */
  texture?: string | null;
  mode?: string | null;
  paging?: string | null;
  justify?: string | number | boolean | null;
  indent?: string | number | boolean | null;
  compress?: string | number | boolean | null;
  motion?: string | null;
  tint?: string | null;
  fontSize?: number | string | null;
  lineHeight?: number | string | null;
  paragraphSpacing?: number | string | null;
  font?: string | null;
  margin?: number | string | null;
  top?: number | string | null;
  bottom?: number | string | null;
  cols?: number | string | null;
}

type Kind = 'tri' | 'bool' | 'enum';

const ATTRS: { [k: string]: { attr: string; kind: Kind; values?: string[]; def: string | null } } = {
  paper: { attr: 'data-yy-paper', kind: 'enum', values: ['plain', 'dark', 'kami', 'kaminight', 'eink'], def: 'plain' },
  mode: { attr: 'data-yy-mode', kind: 'enum', values: ['paginated', 'scrolled'], def: 'paginated' },
  paging: { attr: 'data-yy-paging', kind: 'enum', values: ['native', 'snap'], def: 'native' },
  justify: { attr: 'data-yy-justify', kind: 'tri', def: 'auto' },
  indent: { attr: 'data-yy-indent', kind: 'tri', def: 'auto' },
  compress: { attr: 'data-yy-compress', kind: 'bool', def: '1' },
  texture: { attr: 'data-yy-texture', kind: 'enum', values: ['grain', 'xuan', 'linen'], def: null },
  motion: { attr: 'data-yy-motion', kind: 'enum', values: ['full', 'reduced'], def: 'full' },
  tint: { attr: 'data-yy-tint', kind: 'enum', values: ['blue', 'ink'], def: null },
};

// [custom property, unit, template default (null: remove so the paper default applies)]
const VARS: { [k: string]: [string, string, string | null] } = {
  fontSize: ['--yy-fs', 'px', '18px'],
  lineHeight: ['--yy-lh', '', null],
  paragraphSpacing: ['--yy-ps', 'em', null],
  margin: ['--yy-margin', 'px', '24px'],
  top: ['--yy-top', 'px', '56px'],
  bottom: ['--yy-bottom', 'px', '88px'],
  cols: ['--yy-cols', '', '1'],
};

// What 我的纸 may set over its preset: the colours, and light or dark.
const PAPER_PROPS = ['--yy-p-bg', '--yy-p-ink', '--yy-p-ink-2', '--yy-p-line', '--yy-p-accent', '--yy-p-hl', '--yy-p-wave',
  '--yy-p-glass', '--yy-p-main', '--yy-p-on-main', '--yy-p-pa', 'color-scheme'];

// Font keywords. Latin text (:lang(en)) gets a matching Latin face; CJK faces have poor Latin.
const FONTS: { [k: string]: [string, string] } = {
  sans: ['var(--yy-sans)', 'var(--yy-sans)'],
  serif: ['var(--yy-serif)', 'var(--yy-latin-serif)'],
  // 楷体 is the system's own; 霞鹜文楷 is downloaded, and core adds its @font-face once it is.
  kai: ['var(--yy-kaiti)', 'var(--yy-latin-serif)'],
  wenkai: ['var(--yy-wenkai)', 'var(--yy-latin-serif)'],
  mono: ['var(--yy-mono)', 'var(--yy-mono)'],
};

const isAuto = (v: unknown): boolean => v == null || v === 'auto' || v === '';

function flag(v: unknown): string {
  return v === true || v === 1 || v === '1' || v === 'true' || v === 'on' ? '1' : '0';
}

function withUnit(v: number | string, unit: string): string | null {
  if (typeof v === 'number') return isFinite(v) ? v + unit : null;
  const t = String(v).trim();
  if (/^-?\d*\.?\d+$/.test(t)) return t + unit;
  return t || null;
}

/** Applies the settings to <html>. Returns true when anything changed. */
export function applyToRoot(s: Settings): boolean {
  const root = document.documentElement;
  let changed = false;
  const setAttr = (name: string, value: string | null): void => {
    if (root.getAttribute(name) === value) return;
    if (value == null) root.removeAttribute(name);
    else root.setAttribute(name, value);
    changed = true;
  };
  const setVar = (name: string, value: string | null): void => {
    if ((root.style.getPropertyValue(name).trim() || null) === value) return;
    if (value == null) root.style.removeProperty(name);
    else root.style.setProperty(name, value);
    changed = true;
  };
  const src = s as { [k: string]: unknown };

  for (const key in ATTRS) {
    if (!(key in src)) continue;
    const a = ATTRS[key];
    const v = src[key];
    let value: string | null;
    if (a.kind === 'tri') value = isAuto(v) ? 'auto' : flag(v);
    else if (a.kind === 'bool') value = v == null ? a.def : flag(v);
    else value = v != null && a.values!.indexOf(String(v)) >= 0 ? String(v) : a.def;
    setAttr(a.attr, value);
  }

  for (const key in VARS) {
    if (!(key in src)) continue;
    const [name, unit, def] = VARS[key];
    const v = src[key] as number | string | null;
    let value = isAuto(v) ? def : withUnit(v as number | string, unit);
    if (key === 'cols' && value != null) value = String(Math.max(1, Math.min(2, parseInt(value, 10) || 1)));
    setVar(name, value);
  }

  if ('paperStyle' in src) {
    const own: { [name: string]: string } = {};
    for (const part of String(src.paperStyle || '').split(';')) {
      const i = part.indexOf(':');
      const name = part.slice(0, i).trim();
      if (i > 0 && PAPER_PROPS.indexOf(name) >= 0) own[name] = part.slice(i + 1).trim();
    }
    for (const name of PAPER_PROPS) setVar(name, own[name] || null);
  }

  if ('font' in src) {
    const f = src.font as string | null;
    if (isAuto(f)) {
      setVar('--yy-font', null);
      setVar('--yy-font-en', null);
    } else {
      const k = FONTS[String(f)] ? String(f) : keywordOf(String(f));
      setVar('--yy-font', k ? FONTS[k][0] : String(f));
      setVar('--yy-font-en', k ? FONTS[k][1] : String(f));
    }
  }
  return changed;
}

function keywordOf(stack: string): string | null {
  const t = stack.replace(/\s+/g, '');
  for (const k in FONTS) if (FONTS[k][0] === t) return k;
  return null;
}

/** Core writes only --yy-font into the document; derive the Latin face the same way
 *  applySettings does. */
export function normalizeRoot(): void {
  const root = document.documentElement;
  const f = root.style.getPropertyValue('--yy-font').trim();
  if (!f || root.style.getPropertyValue('--yy-font-en').trim()) return;
  const k = keywordOf(f);
  root.style.setProperty('--yy-font-en', k ? FONTS[k][1] : f);
}

/** The effective settings, for debugging and the demo. */
export function currentSettings(): { [k: string]: string | null } {
  const root = document.documentElement;
  const out: { [k: string]: string | null } = {};
  for (const key in ATTRS) out[key] = root.getAttribute(ATTRS[key].attr);
  for (const key in VARS) out[key] = root.style.getPropertyValue(VARS[key][0]).trim() || null;
  const f = root.style.getPropertyValue('--yy-font').trim();
  out.font = f ? keywordOf(f) || f : null;
  return out;
}
