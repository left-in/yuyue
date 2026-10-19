#!/usr/bin/env python3
"""Builds the small hand-made EPUBs in fixtures/books.

beiying.epub     朱自清《背影》, from fixtures/books/beiying.txt: a clean, real Chinese text.
edge-cases.epub  synthetic chapters that exercise the normalizer: punctuation pairs, ruby,
                 footnotes, sentences crossing inline markup, unsafe markup, links, an image,
                 HTML entities, and a TOC entry that points into the middle of a file.

Run from the repo root: python3 scripts/make_fixture_epubs.py
"""
import base64
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOKS = os.path.join(ROOT, "fixtures", "books")

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

# 1x1 PNG
DOT_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)

STYLE = """body { margin: 0; }
h1, h2 { text-align: center; }
p { text-indent: 2em; margin: 0; }
.author { text-align: center; text-indent: 0; }
"""


def xhtml(title, lang, body, doctype=False):
    head = '<?xml version="1.0" encoding="utf-8"?>\n'
    if doctype:
        head += ('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
                 '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n')
    return (head +
            f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" '
            f'xml:lang="{lang}" lang="{lang}">\n<head>\n<title>{title}</title>\n'
            '<link rel="stylesheet" type="text/css" href="../style.css"/>\n</head>\n'
            f'<body>\n{body}\n</body>\n</html>\n')


def opf(ident, title, creator, lang, items, spine):
    manifest = "\n".join(
        f'    <item id="{i}" href="{h}" media-type="{m}"{(" properties=%r" % p).replace(chr(39), chr(34)) if p else ""}/>'
        for i, h, m, p in items)
    spine_xml = "\n".join(f'    <itemref idref="{i}"/>' for i in spine)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="{lang}">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">{ident}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>{creator}</dc:creator>
    <dc:language>{lang}</dc:language>
    <meta property="dcterms:modified">2026-10-14T00:00:00Z</meta>
  </metadata>
  <manifest>
{manifest}
  </manifest>
  <spine toc="ncx">
{spine_xml}
  </spine>
</package>
"""


def nav(lang, entries):
    lis = "\n".join(f'      <li><a href="{h}">{t}</a></li>' for t, h in entries)
    return xhtml("目录", lang, f'<nav epub:type="toc" id="toc">\n  <h1>目录</h1>\n  <ol>\n{lis}\n  </ol>\n</nav>').replace(
        '<link rel="stylesheet" type="text/css" href="../style.css"/>\n', "")


def ncx(ident, title, entries):
    points = "\n".join(
        f'    <navPoint id="p{n}" playOrder="{n}"><navLabel><text>{t}</text></navLabel>'
        f'<content src="{h}"/></navPoint>'
        for n, (t, h) in enumerate(entries, 1))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="{ident}"/></head>
  <docTitle><text>{title}</text></docTitle>
  <navMap>
{points}
  </navMap>
</ncx>
"""


def write_epub(path, files):
    if os.path.exists(path):
        os.remove(path)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for name, data in files:
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    print("wrote", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes")


def beiying():
    text = open(os.path.join(BOOKS, "beiying.txt"), encoding="utf-8").read()
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    title, author, paras = lines[0], lines[1], lines[2:]
    body = f'<h1>{title}</h1>\n<p class="author">{author}</p>\n' + "\n".join(f"<p>{p}</p>" for p in paras)
    toc = [(title, "text/beiying.xhtml")]
    ident = "urn:yuyue:fixture:beiying"
    items = [
        ("nav", "nav.xhtml", "application/xhtml+xml", "nav"),
        ("ncx", "toc.ncx", "application/x-dtbncx+xml", None),
        ("css", "style.css", "text/css", None),
        ("c1", "text/beiying.xhtml", "application/xhtml+xml", None),
    ]
    write_epub(os.path.join(BOOKS, "beiying.epub"), [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf(ident, title, author, "zh-CN", items, ["c1"])),
        ("OEBPS/nav.xhtml", nav("zh-CN", toc)),
        ("OEBPS/toc.ncx", ncx(ident, title, toc)),
        ("OEBPS/style.css", STYLE),
        ("OEBPS/text/beiying.xhtml", xhtml(title, "zh-CN", body)),
    ])


def edge_cases():
    long_sentence = ("他一面走，一面想，想到家里的光景，想到父亲的差使，想到祖母的丧事，"
                     "想到自己将要远行，想到这一路上的种种，想到许多说不出的心事，"
                     "心里便觉得沉甸甸的，脚下也越走越慢了。")
    ch1 = f"""<h2 id="ch1">第一章　标点和注音</h2>
<p>他说：“我买几个橘子去。你就在此地，不要走动。”我看那边月台的栅栏外有几个卖东西的等着顾客。</p>
<p>这本书叫《“红楼”梦》（又名《石头记》）。真的吗？！是的……</p>
<p><ruby>背<rp>(</rp><rt>bèi</rt><rp>)</rp></ruby>影是一篇散文。</p>
<p>这是一个注释<a epub:type="noteref" href="#fn1">1</a>。注释后面还有一句。</p>
<p>前半句<em>强调的部分。后面</em>接着说完。</p>
<p>我们过了江，
进了车站。我买票，​他忙着照看行李。﻿</p>
<p onclick="alert(1)" style="color: red">点我。</p>
<script type="text/javascript">alert(1)</script>
<p><a href="ch2.xhtml#part2">跳到第二部分</a>，或者看<a href="https://example.com/">外部链接</a>。</p>
<p class="pic"><img src="../images/dot.png" alt="点"/></p>
<p>{long_sentence}</p>
<aside epub:type="footnote" id="fn1"><p>注释的内容。</p></aside>
"""
    ch2 = """<h2 id="part1">Chapter Two</h2>
<p>Mr.&nbsp;Bennet met Dr. Jones at 3.30 p.m. on St. James Street. &ldquo;Is he married?&rdquo; she asked. &ldquo;Oh! single, my dear, to be sure!&rdquo;</p>
<p>It was a fine day&mdash;the best of the year. The U.S.A. is big.</p>
<h2 id="part2">Part Two</h2>
<p>E.g. this is an example, i.e. a test. Here the second part begins.</p>
<p>It ends here.</p>
"""
    toc = [("第一章　标点和注音", "text/ch1.xhtml"), ("Chapter Two", "text/ch2.xhtml"),
           ("Part Two", "text/ch2.xhtml#part2")]
    ident = "urn:yuyue:fixture:edge-cases"
    items = [
        ("nav", "nav.xhtml", "application/xhtml+xml", "nav"),
        ("ncx", "toc.ncx", "application/x-dtbncx+xml", None),
        ("css", "style.css", "text/css", None),
        ("img", "images/dot.png", "image/png", None),
        ("c1", "text/ch1.xhtml", "application/xhtml+xml", None),
        ("c2", "text/ch2.xhtml", "application/xhtml+xml", None),
    ]
    write_epub(os.path.join(BOOKS, "edge-cases.epub"), [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf(ident, "边界情况", "语阅", "zh-CN", items, ["c1", "c2"])),
        ("OEBPS/nav.xhtml", nav("zh-CN", toc)),
        ("OEBPS/toc.ncx", ncx(ident, "边界情况", toc)),
        ("OEBPS/style.css", STYLE),
        ("OEBPS/images/dot.png", DOT_PNG),
        ("OEBPS/text/ch1.xhtml", xhtml("第一章", "zh-CN", ch1)),
        ("OEBPS/text/ch2.xhtml", xhtml("Chapter Two", "en", ch2, doctype=True)),
    ])


if __name__ == "__main__":
    beiying()
    edge_cases()
    sys.exit(0)
