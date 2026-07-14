# Art Brief: Feed-Bearing Folder Symbol (`folder.badge.rss`)

**Date:** 2026-07-13
**Origin:** Website Design Window cleanup (#714) — the site navigator needs a
directory icon that distinguishes collections with an RSS feed from plain
directories. No stock SF Symbol exists for this; per the #714 convention, SF
Symbols are used where available and a custom symbol is briefed where not.

## What to draw

A custom SF Symbol composing:

- **Base:** the standard SF Symbols `folder` silhouette, unmodified — the icon
  must read as a sibling of the plain `folder` rows beside it.
- **Badge:** the conventional RSS glyph — a dot with two concentric quarter-arc
  waves radiating up-right (the same construction as SF's
  `dot.radiowaves.up.forward`) — placed **bottom-trailing**, matching the badge
  position and scale of Apple's `folder.badge.*` family (`folder.badge.plus`,
  `folder.badge.gearshape`).

## Production requirements

- Author on the **SF Symbols app custom-symbol template** (export a template
  from `folder.badge.plus` so badge geometry, margins, and alignment match the
  system family exactly).
- Provide the standard **Small / Medium / Large scales** and interpolate across
  weights **Ultralight, Regular, Black** (the template derives the rest).
- **Renditions:** monochrome (primary) and hierarchical — badge takes the
  secondary hierarchical level, mirroring `folder.badge.plus`. Multicolor is not
  needed.
- Name the symbol **`custom.folder.badge.rss`** in the exported
  `Symbols.xcassets` entry.
- RTL: keep the badge bottom-trailing (it flips with the folder tab
  automatically on the template); the RSS waves keep radiating away from the
  dot — do not mirror the glyph itself.

## Where it lands

- Asset catalog: `Sources/AnglesiteApp/` symbol asset, loaded via
  `Image("custom.folder.badge.rss")`.
- Replaces the interim SwiftUI composite in `SiteNavigatorView` (a `folder`
  symbol with a `dot.radiowaves.up.forward` overlay badge), which ships until
  this symbol exists.

## Reference

- Apple HIG — SF Symbols: custom symbols
  (https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- Sibling symbols to match: `folder`, `folder.badge.plus`,
  `folder.badge.gearshape`, `dot.radiowaves.up.forward`.
