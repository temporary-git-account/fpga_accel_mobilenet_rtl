# Editing the offline guide

Read `ARCHITECTURE-offline.html` directly in a browser. Reading it requires no
server, installed tools, or network connection.

To edit the guide, change `DESIGN.md`, the inline diagram templates in
`docs/render_guide.py`, or the CSS and JavaScript in this directory. Regenerate
from the package root with Python 3 and the `markdown-it-py` package installed:

```sh
python3 docs/render_guide.py
```

The renderer embeds all styles, scripts and SVG diagrams into one HTML file.
Markdown comments mark where those interactive illustrations are inserted.
The Markdown version retains the equations and explanations as plain text.

`MANIFEST.json` records the delivered snapshot. Intentional edits will change
its checksums; preserve the original manifest when comparing your changes.
