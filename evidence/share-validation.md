# Sharing snapshot validation

Validation date: 2026-09-09.

## Checks run against this package

- Verilator 5.020 quick suite: PASS. The copied RTL and relocated testbenches
  were compiled, then exercised against AXI memory/cache tests, control-register
  checks, ten synthetic layer shapes and the included real classifier head.
  Cancellation, injected failures and recovery jobs passed. See
  `share-quick-rtl.log` for exact markers and cycle counts.
- Offline calculator: all 40,815 exported requantization cases matched under
  Node.js, including rejection of five invalid cases. JavaScript syntax passed.
- HTML structure: 95 unique IDs, 50 resolved links, no external assets.
  Navigation anchors and local documentation paths were checked.
- Sharing scope: file names, raw contents, UTF-16 encodings, and all 58 members
  of the compressed constant archive passed the requested naming scan.
  No symlinks, Git directory, OS sources or application transport code are bundled.

Browser preview was unavailable in this session. HTML structure and arithmetic
logic were checked programmatically; interactive layout was not visually tested.

## Boundaries of these results

The physical implementation reports are retained evidence from the accepted
166.667 MHz design. This documentation packaging step did not rerun synthesis,
routing, full graph RTL simulation, or the Windows XSim/netlist regressions.
The complete commands for repeating those gates are in GUIDE.md.

`MANIFEST.json` records SHA-256 checksums and sizes for the delivered files,
excluding the manifest itself. Run `python3 verify_package.py` after copying.
Checksums detect accidental changes; they are not a digital signature.
