# Accepted physical implementation evidence

These reports describe the corrected 166.667 MHz XC7Z010 implementation.
Workstation path labels are normalized in the sharing copy; timing/resource
values are retained. `timing-summary.json` contains the parsed audit without
references to generated containers outside this package.

Setup/hold/pulse slack: +0.172/+0.028/+1.750 ns. Zero missing-clock/delay and
unconstrained-endpoint checks. CDC/DRC include reviewed warnings; this is not a
warning-free report set. Core 166.667 MHz, control/memory interface 100 MHz.

The separate share-validation record describes tests rerun against this copied,
relocated source layout. A fresh RTL edit needs new numerical and timing checks.
