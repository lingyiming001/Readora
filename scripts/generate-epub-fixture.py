#!/usr/bin/env python3
"""Generate a deterministic, original EPUB for tests. All text/art is project-authored; CC0."""
from pathlib import Path
import zipfile, zlib, struct
root = Path(__file__).resolve().parent.parent

def png():
    width, height = 160, 220
    raw = b''.join(b'\x00' + b''.join(bytes((100 + y // 3, 65 + x // 2, 175)) for x in range(width)) for y in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

entries = {
    'mimetype': b'application/epub+zip',
    'META-INF/container.xml': b'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    'OPS/package.opf': '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">readora-original-fixture</dc:identifier><dc:title>Readora · 阅读之旅</dc:title><dc:creator>Readora 测试团队</dc:creator><dc:language>zh-CN</dc:language></metadata><manifest><item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="cover" href="Images/cover.png" media-type="image/png" properties="cover-image"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>'''.encode(),
    'OPS/nav.xhtml': '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="Text/one.xhtml#opening">第一章 · 开始阅读</a></li><li><a href="Text/two.xhtml#continue">第二章 · 继续旅程</a></li></ol></nav></body></html>'''.encode(),
    'OPS/Text/one.xhtml': ('''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>开始阅读</title><style>p {color: red}</style></head><body><h1 id="opening">第一章 · 开始阅读</h1><p>欢迎使用 Readora。这是一本为验证 EPUB 阅读功能而创作的示例书。</p><p>文字与声音，让阅读自然延续。Hello, EPUB! 😀</p><img src="../Images/cover.png" alt="阅读之旅封面"/>''' + ''.join(f'<p>第 {i} 段：放慢脚步，翻开下一页。在安静的阅读时光里，文字带来新的发现。</p>' for i in range(1, 41)) + '''<script>DoNotExecuteOrRead()</script><p hidden="hidden">隐藏内容</p></body></html>''').encode(),
    'OPS/Text/two.xhtml': ('''<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="continue">第二章 · 继续旅程</h1><p>关闭书籍再打开，应该回到刚才读到的位置。</p>''' + ''.join(f'<p>旅程 {i}：目录跳转、字号调整和朗读，都从同一份正文开始。</p>' for i in range(1, 41)) + '</body></html>').encode(),
    'OPS/Images/cover.png': png(),
}
path = root / 'Tests/ReadoraCoreTests/Fixtures/ReadingJourney.epub'
with zipfile.ZipFile(path, 'w') as archive:
    for name, data in entries.items():
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
print(path)
