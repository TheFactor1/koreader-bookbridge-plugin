#!/usr/bin/env python3
"""Writes a minimal, valid EPUB 3 with the given title and author.

    python3 make-epub.py OUT.epub "Title" "Author Name"

Just enough for Calibre-Web-Automated's importer to extract title/author:
the stored (uncompressed) mimetype entry first, a container.xml, a package
document with dc:title/dc:creator/dc:identifier, and one XHTML chapter. Used
by run.sh so the live sync test never depends on a real library.
"""
import sys, uuid, zipfile
from xml.sax.saxutils import escape

out, title, author = sys.argv[1], sys.argv[2], sys.argv[3]
bid = str(uuid.uuid4())
opf = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bid">urn:uuid:{bid}</dc:identifier>
    <dc:title>{escape(title)}</dc:title>
    <dc:creator>{escape(author)}</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>'''
xhtml = lambda body: f'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>{escape(title)}</title></head><body>{body}</body></html>'''
with zipfile.ZipFile(out, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/nav.xhtml", xhtml('<nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol></nav>'), compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/ch1.xhtml", xhtml(f"<h1>{escape(title)}</h1><p>Test text for the live sync suite.</p>"), compress_type=zipfile.ZIP_DEFLATED)
