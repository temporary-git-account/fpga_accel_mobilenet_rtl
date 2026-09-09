# Editing the illustrated guide

Edit [README.md](../README.md) directly. It is the single complete architecture
guide. GitHub renders its Markdown tables, code blocks and relative image links.

The four diagrams in [images](images/) are self-contained SVG files with titles,
descriptions, explicit colors and white backgrounds. They contain no scripts,
external fonts, linked assets or browser-specific drawing code. Edit the SVG
files to update a diagram; no HTML renderer or build step is required.

Keep the text explanations alongside images accessible and accurate. Numerical
examples and operator tables should remain selectable text. For offline reading,
copy the README together with this image directory into a Markdown viewer.

`MANIFEST.json` records the delivered snapshot. Intentional edits will change
its checksums; preserve the original manifest when comparing your changes.
