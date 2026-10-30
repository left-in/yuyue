#!/usr/bin/env python3
"""书伴's service logos, from shared/provider-icons/*.svg into both apps.

The SVGs are LobeHub Icons (MIT, github.com/lobehub/lobe-icons), as magpie ships them; magpie's
own is from magpie (MIT, github.com/yetone/magpie). One-colour ones (fill="currentColor") become
template images that take the text colour; the coloured ones keep theirs.

  Apple:   apple/Yuyue/Assets.xcassets/provider-<id>.imageset (the SVG, vector kept)
  Android: android/app/src/main/res/drawable/provider_<id>.xml (a VectorDrawable)

usage: provider-icons.py
"""
import glob, json, os, re
import xml.etree.ElementTree as ET

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG = '{http://www.w3.org/2000/svg}'
ANDROID = 'http://schemas.android.com/apk/res/android'
AAPT = 'http://schemas.android.com/aapt'
NAMED = {'gold': '#FFD700', 'black': '#000000', 'white': '#FFFFFF'}


def colour(value, opacity=1.0):
    """#RGB / #RRGGBB / a name, with an opacity, as Android's #AARRGGBB."""
    v = NAMED.get(value, value).lstrip('#')
    if len(v) == 3:
        v = ''.join(c * 2 for c in v)
    return '#%02X%s' % (round(255 * opacity), v.upper())


def number(value, size):
    """A gradient coordinate: a plain number, or a percentage of the box."""
    value = value.strip()
    return float(value[:-1]) / 100 * size if value.endswith('%') else float(value)


def android(svg, template):
    view = [float(n) for n in svg.get('viewBox').split()]
    gradients = {g.get('id'): g for g in svg.iter(SVG + 'linearGradient')}
    out = [f'<vector xmlns:android="{ANDROID}" xmlns:aapt="{AAPT}" android:width="24dp" android:height="24dp"'
           f' android:viewportWidth="{view[2]:g}" android:viewportHeight="{view[3]:g}">']
    for path in svg.iter(SVG + 'path'):
        opacity = float(path.get('opacity', '1'))
        if opacity == 0:
            continue
        fill = path.get('fill', 'currentColor' if template else '#000')
        attrs = [f'android:pathData="{path.get("d")}"']
        if path.get('fill-rule') == 'evenodd':
            attrs.append('android:fillType="evenOdd"')
        alpha = opacity * float(path.get('fill-opacity', '1'))
        gradient = None
        if fill == 'currentColor':
            # The template's colour comes from the tint; black keeps the alpha.
            attrs.append(f'android:fillColor="{colour("#000", alpha)}"')
        elif fill.startswith('url('):
            gradient = gradients[re.match(r'url\(#(.+)\)', fill).group(1)]
            if alpha < 1:
                attrs.append(f'android:fillAlpha="{alpha:g}"')
        else:
            attrs.append(f'android:fillColor="{colour(fill, alpha)}"')
        if gradient is None:
            out.append('  <path ' + ' '.join(attrs) + '/>')
            continue
        w, h = view[2], view[3]
        x1, y1 = number(gradient.get('x1', '0%'), w), number(gradient.get('y1', '0%'), h)
        x2, y2 = number(gradient.get('x2', '100%'), w), number(gradient.get('y2', '0%'), h)
        out.append('  <path ' + ' '.join(attrs) + '>')
        out.append('    <aapt:attr name="android:fillColor">')
        out.append(f'      <gradient android:type="linear" android:startX="{x1:g}" android:startY="{y1:g}" android:endX="{x2:g}" android:endY="{y2:g}">')
        for stop in gradient.iter(SVG + 'stop'):
            offset = number(stop.get('offset', '0'), 1) if stop.get('offset', '0').endswith('%') else float(stop.get('offset', '0'))
            out.append(f'        <item android:offset="{offset:g}" android:color="{colour(stop.get("stop-color"), float(stop.get("stop-opacity", "1")))}"/>')
        out.append('      </gradient>')
        out.append('    </aapt:attr>')
        out.append('  </path>')
    out.append('</vector>')
    return '\n'.join(out) + '\n'


for source in sorted(glob.glob(os.path.join(root, 'shared/provider-icons/*.svg'))):
    name = os.path.splitext(os.path.basename(source))[0]
    text = open(source, encoding='utf-8').read()
    svg = ET.fromstring(text)
    template = 'currentColor' in text or not re.search(r'fill="(#|url|gold)', text)

    # Apple: currentColor isn't drawn by the asset catalogue; a template is black on clear.
    imageset = os.path.join(root, f'apple/Yuyue/Assets.xcassets/provider-{name}.imageset')
    os.makedirs(imageset, exist_ok=True)
    open(os.path.join(imageset, f'{name}.svg'), 'w', encoding='utf-8').write(text.replace('currentColor', '#000000'))
    json.dump({
        'images': [{'filename': f'{name}.svg', 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'preserves-vector-representation': True,
                       'template-rendering-intent': 'template' if template else 'original'},
    }, open(os.path.join(imageset, 'Contents.json'), 'w'), indent=2)

    drawable = os.path.join(root, f'android/app/src/main/res/drawable/provider_{name}.xml')
    os.makedirs(os.path.dirname(drawable), exist_ok=True)
    open(drawable, 'w', encoding='utf-8').write(android(svg, template))
    print(f'{name}: {"template" if template else "colour"}')
