# PWA icon setup

The web app manifest (`/manifest.webmanifest`) references two icon sizes that
this integration doesn't generate for you:

- `public/icons/icon-192.png` — 192×192
- `public/icons/icon-512.png` — 512×512
- `public/icons/icon-maskable-192.png` and `icon-maskable-512.png` — same
  sizes, with the artwork inset ~10% from the edge (maskable icons get
  cropped to a circle or squircle by the OS, so content near the edge gets
  clipped)

Generate all four from a single square source image (SVG or PNG, 512×512 or
larger) with any image tool — a maskable icon is just the same artwork
scaled to ~80% and centered on an opaque background. Place the four files
under `public/icons/` in your site's `Source/` directory.

Until those files exist, the manifest will reference broken icon paths —
browsers still allow installing the PWA, but without a proper home-screen
icon.
