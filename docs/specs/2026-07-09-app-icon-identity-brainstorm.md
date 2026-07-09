# App icon & identity brainstorm — the anglesite crystal

*2026-07-09. Concept exploration for replacing the current `</>`-in-a-squircle app
icon and extending the result into an in-app accent identity. Direction set in an
interview with @dwk; concepts below are candidates, not a final pick.*

## Why change it

The current icon (dark `</>` glyph, blue slash, light squircle) is appropriate but
generic — dozens of dev tools use bracket glyphs. Meanwhile the app's name is doing
much more work than the icon lets on: **anglesite** is a real mineral (lead sulfate,
PbSO₄) — colorless-to-pale-champagne orthorhombic crystals with a near-adamantine
luster, first described at Parys Mountain on **Anglesey, Wales**, and classically
found on steel-blue **galena**. The name puns across angle brackets, websites,
geologic *sites*, and a lesser-known gem. The icon should own that.

## Direction (locked in interview)

| Axis | Decision |
|---|---|
| Lead motif | **The crystal/gem** — the mineral leads; brackets become secondary |
| Brackets | **Hidden in the facets** — silhouette/facet lines subtly form `<` `>`; an easter egg, never a typeset glyph |
| Composition | **Single hero crystal** — one bold prism, centered; iconic silhouette, legible at 16 px |
| Treatment | **Glassy/refractive** — lean into the translucent-glass macOS icon language; real refraction and depth |
| Color | **Mineral-true** — champagne/pale-gold crystal on dark steel-blue galena |
| Personality | **Friendly & magical** — the app does heavy lifting invisibly; the gem glows. Not pro-tool severe, not game-y sparkle |
| Reference vibe | **Indie Mac craft** — Panic/Nova, Things, CleanShot lineage: lovingly rendered, personality over corporate flatness. Study Sketch's diamond only to differentiate from it |
| Scope | **Icon + in-app accents** — also rethink accent color and small glyphs (toolbar, empty states) to match |

## Icon concepts

All concepts share the locked direction; they differ in *how the brackets hide* and
*where the light comes from*.

### 1. The Prism (baseline)

An upright orthorhombic prism with a chisel/wedge termination — anglesite's actual
habit — centered on a dark galena field. The crystal's tapering left and right
edges *are* the brackets: the negative space between crystal and squircle corners
reads as `<` and `>` without drawing them. One caustic pool of light where the
crystal meets the ground plane, as if lit from within.

- **Why it wins:** strongest silhouette of the set; the bracket easter egg is pure
  negative space, so it never fights the gem.
- **Risk:** an upright hexagon-ish silhouette is adjacent to Sketch's diamond;
  differentiation rides on the glassy 3D treatment and the dark ground.

### 2. Bracket Facet

The crystal sits rotated a few degrees so its front corner faces the viewer. The
facet junctions on the two visible faces catch specular light as a chevron pair —
a lit `<` on the left face, `>` on the right. The brackets are literally *how the
light breaks on the stone*.

- **Why it wins:** the most magical version of the easter egg — you only see the
  brackets when the light does. Rewards the second look.
- **Risk:** specular chevrons need real rendering care to read as facets, not as
  decals pasted on glass; hardest to keep honest at 32 px.

### 3. Slash of Light

Concept 1's prism, but a single diagonal refraction beam passes through the body —
the old icon's blue `/` reborn as light bending through the crystal. Continuity
easter egg for anyone who knew the previous mark; "angle of incidence" pun for
free (refraction *is* light changing angle).

- **Why it wins:** carries lineage from the current icon; the beam gives the
  composition motion and a natural place for the champagne-gold to go hot.
- **Risk:** a strong diagonal can dominate the silhouette at small sizes and
  read as a "no entry" slash if the contrast is mishandled.

### 4. On Galena

The bottom quarter of the squircle is a bed of dark, subtly *cubic* galena
(galena crystallizes in cubes — a nice geometric floor that stays quiet), with the
hero crystal rising out of it. Tells the "site where you unearth something
precious" story — your website, brought to light — while staying a single-hero
composition.

- **Why it wins:** most narratively complete; mineral-true down to the matrix; the
  cubic bed gives the icon a horizon line, which macOS icons rarely have.
- **Risk:** the busiest of the four; the galena bed must simplify to a plain dark
  band below ~64 px or it turns to noise.

**Recommended path:** develop **1 and 3 together** (they share geometry — 3 is 1
plus a light beam), keep **2** as the stretch goal if the renders support it, and
fold 4's galena *material* into whichever wins as the background treatment rather
than a literal rock bed.

## Palette (working values)

| Role | Hex | Notes |
|---|---|---|
| Galena deep | `#1B222C` | Icon background field; near-black steel blue |
| Galena steel | `#2E3A47` | Facet shadows, matrix highlights |
| Champagne core | `#E8D5A3` | Crystal body mid-tone |
| Gold hot | `#C9A24B` | Refraction concentrations, caustics |
| Ice highlight | `#F8F2E0` | Specular hits, top facet |

The pairing is inherently high-contrast (bright wedge on dark field), which is
what makes the 16 px read work — the silhouette carries everything.

## Production notes (macOS 27)

- Author as a **layered Icon Composer document**, not flat PNGs: galena background
  layer, crystal body layer with glass material, specular/caustic layer on top.
  The system's dynamic glass lighting then works *with* the refraction story
  instead of fighting a baked render. Keep the current `AppIcon.appiconset` PNGs
  as the fallback export from the same source.
- Provide explicit **dark and tinted variants**: dark mode inverts nothing here
  (the field is already dark), but the tinted/clear variants should reduce to the
  crystal silhouette alone.
- Test gates: 16 px dock/Finder read (silhouette-only), 32 px (facet lines must
  survive or be dropped per-size), 512 px marketing (full refraction).

## In-app accents (identity beyond the icon)

- **Chrome stays cool, magic goes gold.** UI chrome and selection tint shift from
  system blue toward galena-steel; **champagne-gold is reserved for the "magical"
  moments** — Apple Intelligence actions, deploy success, the edit overlay's
  active state. Gold as a scarce accent reads precious; gold everywhere reads
  like a warning state, so budget it.
- **Small glyphs:** toolbar icons remain SF Symbols (Mac-assed Mac app), but empty
  states and onboarding get one drawn asset each from the icon's crystal geometry
  — the same prism, simplified to a two-tone line illustration.
- **Sparkle alignment:** where the system uses its Intelligence sparkle language,
  ours glows through the crystal rather than adding a second sparkle vocabulary.
- **Website/template branding and the wordmark are out of scope** for this pass
  (icon + in-app accents only, per interview).

## Open questions / next steps

1. ~~Produce rough facet-geometry studies (SVG or Icon Composer) for concepts 1–3
   and evaluate the bracket easter egg at 32 px.~~ **Done 2026-07-09** — see
   [`assets/icon-studies/`](assets/icon-studies/) (`study-1-prism.svg`,
   `study-2-bracket-facet.svg`, `study-3-slash-of-light.svg`). These are
   geometry/light studies, not final art. When production starts, verify the
   "Production notes" above against Apple's current Icon Composer documentation —
   they were written from memory of the macOS 26/27 icon pipeline and are
   speculative until checked.
2. ~~Decide whether the beam in concept 3 stays champagne or deliberately echoes
   the old icon's blue for one release of continuity.~~ **Resolved 2026-07-09:
   the beam stays champagne** — mineral-true throughout, no blue continuity nod.
3. Pick the winner, then commission/produce the final layered render and export
   the `.icon` document + appiconset.
4. Follow-up pass for accent-color adoption in `AnglesiteApp` (tint, edit-overlay
   active state, empty-state art).
