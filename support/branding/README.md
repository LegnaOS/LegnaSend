# LegnaSend product mark

The mark follows the live download portal's `brand-mark` in `support/download-portal/index.php` and `assets/portal.css`: green `#54B865`, dark `#102C16`, three rounded corners and one tighter corner, rotated −12°. The letter is a font-independent geometric L. The website remains unchanged; this is a deterministic native rendering of its visual identity, not a claim of identical font rasterization.

`legnasend-mark.svg` is the inspectable vector. Run:

```sh
python3 support/scripts/generate_brand_icons.py
python3 support/scripts/generate_brand_icons.py --check
```

The generator uses Pillow, keeps existing file names and platform metadata, and produces 140 binary assets plus the vector and two Android XML files. `generated-icons.json` records paths, sizes, color modes and content hashes. Keep script, vector, generated files and manifest together. iOS icons have an opaque background; Android adaptive foregrounds are inset for masking; tray and notification glyphs use a transparent L cutout. Windows application and installer ICO files include 16–256 px representations. Existing Linux packaging consumes the shared PNGs. Existing success/error badges remain distinct.

No upstream license or legal credit is removed. The internal `LocalSendLogo` class name remains source-compatible while displaying the LegnaSend mark. Browser/PWA assets are outside this native batch and are not rewritten.

The shared rotation widget uses Flutter tickers instead of an endless timer. It stops for reduced motion, disabled animation, hidden routes/TickerMode and background lifecycle, retaining its angle for resumption. Receive-page online/active-tab gating remains in place; About and Settings show the static mark.

Checks and visual evidence: `docs/evidence/portal-brand-icons/` and the Flutter golden `app/test/widget/goldens/legnasend_portal_mark.png`. Compiling asset catalogs or widget tests does not replace installed-platform visual acceptance.
