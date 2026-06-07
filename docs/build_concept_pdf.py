#!/usr/bin/env python3
"""Build the SaveVision concept document (HTML) from the workflow result JSON.

Usage: python3 build_concept_pdf.py <workflow_output.json> <out.html>
The JSON is the Workflow task output; we read result.doc and render a styled,
print-ready HTML. A separate step converts the HTML to PDF with headless Chrome.
"""
import json
import sys
import html as _html

CSS = """
@page { size: A4; margin: 20mm 18mm 22mm; }
* { box-sizing: border-box; }
body {
  font-family: Georgia, "Times New Roman", serif;
  color: #1a1a1a; line-height: 1.5; font-size: 11.2pt; margin: 0;
}
h1, h2, h3, .brand, .tag, .toc-h, .cover-meta { font-family: "Helvetica Neue", Arial, sans-serif; }

/* ---------- cover ---------- */
.cover { height: 247mm; display: flex; flex-direction: column; page-break-after: always; }
.cover .brand { font-size: 13pt; font-weight: 700; letter-spacing: 3px; color: #0a7d5a; text-transform: uppercase; }
.cover .rule { height: 3px; background: #0a7d5a; width: 64px; margin: 10mm 0 8mm; }
.cover h1 { font-size: 30pt; line-height: 1.15; margin: 0 0 6mm; font-weight: 800; }
.cover .subtitle { font-size: 13.5pt; color: #444; font-style: italic; max-width: 150mm; }
.cover .spacer { flex: 1; }
.cover-meta { font-size: 9.5pt; color: #666; letter-spacing: 1px; text-transform: uppercase; margin-bottom: 6mm; }
.classbox {
  border: 1px solid #c9c9c9; border-left: 4px solid #b00020; background: #fbf7f7;
  padding: 6mm 7mm; font-family: "Helvetica Neue", Arial, sans-serif; font-size: 8.6pt;
  line-height: 1.45; color: #333;
}
.classbox b { color: #b00020; }

/* ---------- table of contents ---------- */
.toc { page-break-after: always; }
.toc-h { font-size: 16pt; font-weight: 700; margin: 0 0 6mm; color: #0a7d5a; }
.toc ol { list-style: none; padding: 0; margin: 0; counter-reset: t; }
.toc li { counter-increment: t; font-family: "Helvetica Neue", Arial, sans-serif;
          font-size: 11pt; padding: 2.4mm 0; border-bottom: 1px dotted #ccc; }
.toc li::before { content: counter(t) ".  "; color: #0a7d5a; font-weight: 700; }

/* ---------- summary ---------- */
.summary { background: #f3f8f6; border-radius: 4px; padding: 6mm 7mm; margin: 0 0 8mm; }
.summary .toc-h { margin-bottom: 4mm; }

/* ---------- sections ---------- */
.section { page-break-before: always; }
h2 { font-size: 17pt; color: #0a7d5a; margin: 0 0 4mm; padding-bottom: 2mm; border-bottom: 2px solid #e2e2e2; font-weight: 800; }
h3 { font-size: 12.5pt; margin: 6mm 0 2mm; color: #222; }
p { margin: 0 0 3.2mm; }
ul, ol { margin: 0 0 3.6mm 6mm; padding: 0; }
li { margin: 0 0 1.6mm; }
strong { color: #111; }
blockquote { margin: 4mm 0; padding: 2mm 6mm; border-left: 3px solid #0a7d5a; background: #f6f9f8; font-style: italic; color: #333; }
table { width: 100%; border-collapse: collapse; margin: 4mm 0; font-size: 9.6pt; font-family: "Helvetica Neue", Arial, sans-serif; page-break-inside: avoid; }
th, td { border: 1px solid #d5d5d5; padding: 2.2mm 3mm; text-align: left; vertical-align: top; }
th { background: #eef4f2; font-weight: 700; }

/* ---------- back matter ---------- */
.disclaimers, .glossary { page-break-before: always; }
.disclaimers ul { list-style: none; margin-left: 0; }
.disclaimers li { padding: 2.5mm 0 2.5mm 8mm; position: relative; border-bottom: 1px solid #eee; }
.disclaimers li::before { content: "!"; position: absolute; left: 0; top: 2.5mm;
  width: 5mm; height: 5mm; background: #b00020; color: #fff; border-radius: 50%;
  text-align: center; font-weight: 700; font-family: Arial; font-size: 9pt; line-height: 5mm; }
dl { margin: 0; }
dt { font-weight: 700; font-family: "Helvetica Neue", Arial, sans-serif; margin-top: 3mm; color: #0a7d5a; }
dd { margin: 0 0 2mm; }
.footer-note { margin-top: 8mm; font-size: 8.5pt; color: #888; font-family: Arial; }
"""

def main():
    src, out = sys.argv[1], sys.argv[2]
    doc = json.load(open(src))["result"]["doc"]

    title = _html.escape(doc["title"])
    subtitle = _html.escape(doc["subtitle"])
    classnote = _html.escape(doc.get("classification_note", ""))
    summary = doc.get("executive_summary", "")  # already HTML
    sections = doc.get("sections", [])
    disclaimers = doc.get("key_disclaimers", [])
    glossary = doc.get("glossary", [])

    toc = "".join(f"<li>{_html.escape(s['heading'])}</li>" for s in sections)
    body = "".join(f'<div class="section">{s["html"]}</div>' for s in sections)
    disc = "".join(f"<li>{_html.escape(d)}</li>" for d in disclaimers)
    gloss = "".join(
        f"<dt>{_html.escape(g['term'])}</dt><dd>{_html.escape(g['definition'])}</dd>"
        for g in glossary
    )

    out_html = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>{title}</title><style>{CSS}</style></head><body>
<div class="cover">
  <div class="brand">SaveVision</div>
  <div class="rule"></div>
  <h1>{title}</h1>
  <div class="subtitle">{subtitle}</div>
  <div class="spacer"></div>
  <div class="cover-meta">Concept &amp; Design Document · June 2026</div>
  <div class="classbox"><b>Notice.</b> {classnote}</div>
</div>

<div class="toc">
  <div class="toc-h">Contents</div>
  <ol>{toc}</ol>
</div>

<div class="summary">
  <div class="toc-h">Executive summary</div>
  {summary}
</div>

{body}

<div class="disclaimers">
  <h2>Key disclaimers</h2>
  <ul>{disc}</ul>
  <p class="footer-note">SaveVision is a concept for remote, expert-guided assistance on smart glasses. Medical guidance is the first feature; the same pipeline extends to other domains. This document does not constitute medical or legal advice.</p>
</div>

<div class="glossary">
  <h2>Glossary</h2>
  <dl>{gloss}</dl>
</div>

</body></html>"""

    open(out, "w").write(out_html)
    print(f"wrote {out} ({len(out_html)} bytes, {len(sections)} sections)")

if __name__ == "__main__":
    main()
