# Apple Help (Anglesite Help Book) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a searchable macOS Help Book ("Anglesite Help") covering every shipped feature, wired into the Help menu of both the DevID and Mac App Store targets.

**Architecture:** A classic indexed Apple Help Book bundle (`Resources/Anglesite.help/`) of hand-authored HTML with one Apple-native stylesheet. A pre-build script runs `/usr/bin/hiutil` to generate the `.helpindex` that powers the Help-menu search field. `CFBundleHelpBookFolder` / `CFBundleHelpBookName` keys in both Info.plists register the book so AppKit's default **Help → Anglesite Help** opens it. A link-check shell script guards against dead intra-book links.

**Tech Stack:** HTML5 + CSS (system fonts, `prefers-color-scheme`), `hiutil` (macOS Help indexer), XcodeGen (`project.yml` → `Anglesite.xcodeproj`), bash build scripts.

**Spec:** [`docs/specs/2026-05-28-apple-help-design.md`](2026-05-28-apple-help-design.md)

---

## File structure

**Create:**
- `Resources/Anglesite.help/Contents/Info.plist` — help-book manifest.
- `Resources/Anglesite.help/Contents/Resources/en.lproj/index.html` — landing/TOC (access page).
- `Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/help.css` — stylesheet.
- `Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/img/.gitkeep` — placeholder image dir.
- `Resources/Anglesite.help/Contents/Resources/en.lproj/pages/*.html` — 14 topic pages.
- `scripts/build-help-index.sh` — runs `hiutil`, called as a pre-build script.
- `scripts/check-help-links.sh` — link-integrity check (the "test").

**Modify:**
- `project.yml` — add the help resource folder + the index pre-build script to both targets.
- `Resources/Info.plist` — add `CFBundleHelpBookFolder` / `CFBundleHelpBookName`.
- `Resources/AnglesiteMAS-Info.plist` — same two keys.
- `.gitignore` — ignore the generated `*.helpindex`.

**Conventions to follow (from the existing repo):**
- Build scripts use `set -euo pipefail`, derive `REPO_ROOT` from `BASH_SOURCE`, and are **best-effort**: warn + `exit 0` if a tool is missing, so the Xcode build never breaks (see `scripts/build-overlay.sh`).
- `Anglesite.xcodeproj` is gitignored and regenerated from `project.yml` via `xcodegen generate`. After any `project.yml` edit, regenerate.
- The help bundle is **authored content and IS committed** (unlike the vendored `node-runtime` / `edit-overlay` folders). Only the generated `.helpindex` is ignored.

---

## Task 1: Link-check script (the test harness)

Build the test tool first so every later task can verify against it.

**Files:**
- Create: `scripts/check-help-links.sh`

- [ ] **Step 1: Write the link-check script**

```bash
#!/usr/bin/env bash
#
# Phase 10 — verify every intra-book link/asset reference in the Anglesite Help Book
# resolves to a file that exists. Cheap guard against dead links as pages grow.
#
# Scans each .html under en.lproj for href="..." and src="..." values, ignores external
# (http/https/mailto) and pure "#anchor" refs, strips any "#fragment" suffix, resolves the
# remainder relative to the HTML file's directory, and asserts the target exists.
#
# Exit 0 = all links resolve. Exit 1 = at least one dead link (prints each).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LPROJ="$REPO_ROOT/Resources/Anglesite.help/Contents/Resources/en.lproj"

if [[ ! -d "$LPROJ" ]]; then
    echo "error: help book lproj not found at $LPROJ" >&2
    exit 1
fi

fail=0
while IFS= read -r html; do
    dir=$(dirname "$html")
    # Pull href/src targets; one per line.
    grep -oE '(href|src)="[^"]+"' "$html" | sed -E 's/^(href|src)="//; s/"$//' | while IFS= read -r ref; do
        case "$ref" in
            http://*|https://*|mailto:*|"#"*) continue ;;
        esac
        target="${ref%%#*}"          # strip #fragment
        [[ -z "$target" ]] && continue
        if [[ ! -e "$dir/$target" ]]; then
            echo "DEAD LINK: ${html#"$REPO_ROOT"/} -> $ref" >&2
            echo "x" >> "$REPO_ROOT/.help-link-failures"
        fi
    done
done < <(find "$LPROJ" -name '*.html')

if [[ -f "$REPO_ROOT/.help-link-failures" ]]; then
    fail=$(wc -l < "$REPO_ROOT/.help-link-failures" | tr -d '[:space:]')
    rm -f "$REPO_ROOT/.help-link-failures"
fi

if [[ "$fail" -gt 0 ]]; then
    echo "FAIL: $fail dead link(s)." >&2
    exit 1
fi
echo "OK: all help links resolve."
```

> Note: the subshell from the `while | read` pipe can't mutate a parent variable, so failures are tallied via a temp file `.help-link-failures` that is read and removed after the loop.

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/check-help-links.sh`

- [ ] **Step 3: Run it to verify it fails (no book yet)**

Run: `scripts/check-help-links.sh; echo "exit=$?"`
Expected: prints `error: help book lproj not found ...` and `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add scripts/check-help-links.sh
git commit -m "test(help): add intra-book link-integrity check"
```

---

## Task 2: Help-book skeleton — manifest, stylesheet, landing page

Produce the minimal openable book: manifest + CSS + `index.html`. After this task the link-check passes.

**Files:**
- Create: `Resources/Anglesite.help/Contents/Info.plist`
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/help.css`
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/img/.gitkeep`
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/index.html`

- [ ] **Step 1: Write the help-book manifest**

`Resources/Anglesite.help/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>dev.anglesite.app.help</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Anglesite Help</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>HPDBookTitle</key>
	<string>Anglesite Help</string>
	<key>HPDBookType</key>
	<string>3</string>
	<key>HPDBookAccessPath</key>
	<string>index.html</string>
	<key>HPDBookIndexPath</key>
	<string>Anglesite.helpindex</string>
	<key>HPDBookIconPath</key>
	<string>shrd/img/AnglesiteHelp.png</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the stylesheet**

`Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/help.css`:

```css
/* Anglesite Help — Apple-native styling. System fonts, readable column, light/dark. */
:root {
	color-scheme: light dark;
	--fg: #1d1d1f;
	--fg-dim: #515154;
	--bg: #ffffff;
	--accent: #0066cc;
	--rule: #d2d2d7;
	--card: #f5f5f7;
}
@media (prefers-color-scheme: dark) {
	:root {
		--fg: #f5f5f7;
		--fg-dim: #a1a1a6;
		--bg: #1e1e1e;
		--accent: #2997ff;
		--rule: #3a3a3c;
		--card: #2a2a2c;
	}
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
	font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
	font-size: 15px;
	line-height: 1.55;
	color: var(--fg);
	background: var(--bg);
	margin: 0;
	padding: 28px 32px 64px;
	max-width: 640px;
}
h1 { font-size: 26px; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 0.4em; }
h2 { font-size: 19px; font-weight: 600; margin: 1.8em 0 0.5em; }
h3 { font-size: 16px; font-weight: 600; margin: 1.4em 0 0.4em; }
p, li { color: var(--fg); }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code, kbd {
	font-family: ui-monospace, "SF Mono", Menlo, monospace;
	font-size: 0.92em;
	background: var(--card);
	padding: 0.1em 0.35em;
	border-radius: 4px;
}
kbd { border: 1px solid var(--rule); }
ol, ul { padding-left: 1.4em; }
li { margin: 0.3em 0; }
hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
.lead { font-size: 16px; color: var(--fg-dim); }
nav.toc ul { list-style: none; padding-left: 0; }
nav.toc li { margin: 0.5em 0; }
.related {
	margin-top: 2.5em; padding-top: 1.2em; border-top: 1px solid var(--rule);
	font-size: 14px; color: var(--fg-dim);
}
.related a { margin-right: 1em; }
figure { margin: 1.4em 0; }
figcaption { font-size: 13px; color: var(--fg-dim); margin-top: 0.5em; }
.screenshot-placeholder {
	display: flex; align-items: center; justify-content: center;
	min-height: 160px; padding: 1.5em; text-align: center;
	border: 2px dashed var(--rule); border-radius: 10px;
	background: var(--card); color: var(--fg-dim); font-size: 13px;
}
```

- [ ] **Step 3: Create the image placeholder dir**

Run: `mkdir -p Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/img && touch Resources/Anglesite.help/Contents/Resources/en.lproj/shrd/img/.gitkeep`

> The book icon `AnglesiteHelp.png` referenced by the manifest is a deferred follow-up; Help Viewer falls back to the app icon when it's absent, so a missing icon does not break the book. The `.gitkeep` keeps the dir under version control.

- [ ] **Step 4: Write the landing/TOC page**

`Resources/Anglesite.help/Contents/Resources/en.lproj/index.html`. Use this exact skeleton; the `<nav class="toc">` lists all 14 topic pages created in Tasks 5–7 (every `href` target is created by the end of Task 7, so the final link-check passes then — see the note in Step 5).

```html
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<meta name="robots" content="anchor">
	<meta name="description" content="Anglesite Help — build, preview, and deploy your website.">
	<title>Anglesite Help</title>
	<link rel="stylesheet" href="shrd/help.css">
</head>
<body>
	<h1>Anglesite Help</h1>
	<p class="lead">Anglesite is a native macOS app for building, previewing, and deploying your website — with Claude as your editor and your files always yours on disk.</p>

	<nav class="toc">
		<h2>Get started</h2>
		<ul>
			<li><a href="pages/what-is-anglesite.html">What is Anglesite?</a></li>
			<li><a href="pages/sites.html">Open and create sites</a></li>
			<li><a href="pages/live-preview.html">Live preview</a></li>
		</ul>
		<h2>Editing</h2>
		<ul>
			<li><a href="pages/editing-with-claude.html">Editing with Claude</a></li>
			<li><a href="pages/images.html">Adding and optimizing images</a></li>
			<li><a href="pages/undo.html">Undoing edits</a></li>
		</ul>
		<h2>Publishing</h2>
		<ul>
			<li><a href="pages/health-and-readiness.html">Health and deploy readiness</a></li>
			<li><a href="pages/deploying.html">Deploying your site</a></li>
			<li><a href="pages/accounts.html">Accounts and setup</a></li>
		</ul>
		<h2>Reference</h2>
		<ul>
			<li><a href="pages/settings.html">Settings</a></li>
			<li><a href="pages/updates.html">Updating Anglesite</a></li>
			<li><a href="pages/debug-pane.html">Debug pane and logs</a></li>
			<li><a href="pages/keyboard-shortcuts.html">Keyboard shortcuts</a></li>
			<li><a href="pages/troubleshooting.html">Troubleshooting</a></li>
		</ul>
	</nav>
</body>
</html>
```

- [ ] **Step 5: Run the link-check**

Run: `scripts/check-help-links.sh; echo "exit=$?"`
Expected: **FAIL** — `index.html` links to 14 `pages/*.html` files that don't exist yet. This is expected at this point; the check goes green at the end of Task 7. (The book is still openable now — the access page renders; only the TOC targets are missing.)

- [ ] **Step 6: Commit**

```bash
git add Resources/Anglesite.help
git commit -m "feat(help): help-book skeleton — manifest, stylesheet, landing page"
```

---

## Task 3: Index build script + project + plist wiring

Wire the bundle into both targets and generate the search index.

**Files:**
- Create: `scripts/build-help-index.sh`
- Modify: `project.yml` (both `Anglesite` and `AnglesiteMAS` targets)
- Modify: `Resources/Info.plist`
- Modify: `Resources/AnglesiteMAS-Info.plist`
- Modify: `.gitignore`

- [ ] **Step 1: Write the index build script**

`scripts/build-help-index.sh`:

```bash
#!/usr/bin/env bash
#
# Phase 10 — build the Anglesite Help search index with hiutil.
#
# hiutil (shipped with macOS) indexes the help HTML into Anglesite.helpindex, which powers
# the Help-menu search field and Help Viewer search. Best-effort like the other vendor
# scripts: if hiutil is missing or indexing fails, warn and exit 0 so the Xcode build keeps
# going — the book still opens, just without search.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LPROJ="$REPO_ROOT/Resources/Anglesite.help/Contents/Resources/en.lproj"

if [[ ! -d "$LPROJ" ]]; then
    echo "warning: help lproj missing at $LPROJ — skipping help index." >&2
    exit 0
fi

if ! command -v hiutil >/dev/null 2>&1; then
    echo "warning: hiutil not found — skipping help index (book still opens, no search)." >&2
    exit 0
fi

echo "==> Indexing Anglesite Help → en.lproj/Anglesite.helpindex"
if ! hiutil -Caf "$LPROJ/Anglesite.helpindex" "$LPROJ" 2>&1; then
    echo "warning: hiutil failed — skipping help index." >&2
    exit 0
fi
echo "Help index built: $LPROJ/Anglesite.helpindex"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/build-help-index.sh`

- [ ] **Step 3: Run it to verify it builds an index**

Run: `scripts/build-help-index.sh && ls -la Resources/Anglesite.help/Contents/Resources/en.lproj/Anglesite.helpindex`
Expected: prints `Help index built: ...` and `ls` shows the `.helpindex` file exists.

- [ ] **Step 4: Add the help resource folder to both targets in `project.yml`**

In `project.yml`, the `Anglesite` target has a `sources:` list ending with the `edit-overlay` entry. Add a help entry to **both** the `Anglesite` and `AnglesiteMAS` `sources:` lists, immediately after their existing `Resources/edit-overlay` block. The new entry (match the existing indentation — 6 spaces for `- path:`):

```yaml
      - path: Resources/Anglesite.help
        type: folder
        buildPhase: resources
        optional: true
```

- [ ] **Step 5: Add the index pre-build script to both targets in `project.yml`**

Each target has a `preBuildScripts:` list ending with the "Build edit overlay" entry. Add to **both** the `Anglesite` and `AnglesiteMAS` `preBuildScripts:` lists, after that entry (match indentation — 6 spaces for `- name:`):

```yaml
      - name: Build Help index
        script: "${PROJECT_DIR}/scripts/build-help-index.sh"
        basedOnDependencyAnalysis: false
```

- [ ] **Step 6: Add the Help Book keys to `Resources/Info.plist`**

Add these two keys inside the top-level `<dict>` (e.g. right after the `CFBundleExecutable` block):

```xml
	<key>CFBundleHelpBookFolder</key>
	<string>Anglesite.help</string>
	<key>CFBundleHelpBookName</key>
	<string>dev.anglesite.app.help</string>
```

- [ ] **Step 7: Add the same two keys to `Resources/AnglesiteMAS-Info.plist`**

Add the identical `CFBundleHelpBookFolder` / `CFBundleHelpBookName` block inside its top-level `<dict>`.

- [ ] **Step 8: Ignore the generated index in `.gitignore`**

Under the "Embedded runtimes" or "Build artifacts" section of `.gitignore`, add:

```
# Generated Apple Help search index (rebuilt by scripts/build-help-index.sh)
Resources/Anglesite.help/**/*.helpindex
```

- [ ] **Step 9: Regenerate the Xcode project and verify both plists parse**

Run:
```bash
xcodegen generate
plutil -lint Resources/Info.plist Resources/AnglesiteMAS-Info.plist Resources/Anglesite.help/Contents/Info.plist
```
Expected: `xcodegen` reports success (`Created project at .../Anglesite.xcodeproj`) and `plutil` prints `OK` for all three plists.

- [ ] **Step 10: Confirm the index is gitignored**

Run: `git status --porcelain Resources/Anglesite.help/Contents/Resources/en.lproj/Anglesite.helpindex`
Expected: **empty output** (the file is ignored, so git does not list it).

- [ ] **Step 11: Commit**

```bash
git add scripts/build-help-index.sh project.yml Resources/Info.plist Resources/AnglesiteMAS-Info.plist .gitignore
git commit -m "feat(help): build help index and register book on both targets"
```

---

## Task 4: Reusable page template

Lock the page skeleton once so Tasks 5–7 only fill in content. This template is the canonical structure every topic page copies.

**Files:** none created (reference template used by later tasks).

- [ ] **Step 1: Record the page template**

Every topic page under `pages/` uses this exact structure. Placeholders in ALL-CAPS are filled per page; note the **relative paths from `pages/` use `../`** for shared assets and the landing page:

```html
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<meta name="robots" content="anchor">
	<meta name="description" content="PAGE_DESCRIPTION">
	<title>PAGE_TITLE — Anglesite Help</title>
	<link rel="stylesheet" href="../shrd/help.css">
</head>
<body>
	<h1>PAGE_TITLE</h1>
	<p class="lead">PAGE_LEAD</p>

	<!-- BODY: h2/h3 sections, ordered steps, and figure placeholders as specified per page -->

	<p class="related">
		<strong>See also:</strong>
		<a href="RELATED_1.html">RELATED_1_TITLE</a>
		<a href="RELATED_2.html">RELATED_2_TITLE</a>
		<a href="../index.html">Help home</a>
	</p>
</body>
</html>
```

- [ ] **Step 2: Record the screenshot-placeholder snippet**

Where a page specifies a figure, use this block (the `alt` text for the eventual capture lives in the HTML comment so it's a drop-in later):

```html
<figure>
	<!-- alt: ALT_TEXT_FOR_FUTURE_SCREENSHOT -->
	<div class="screenshot-placeholder">Screenshot: CAPTION_DESCRIPTION</div>
	<figcaption>CAPTION_DESCRIPTION</figcaption>
</figure>
```

No commit (reference only).

---

## Task 5: Get-started pages

Author the three "Get started" pages. Content facts below are drawn from `docs/build-plan.md` and the app sources — use them verbatim where they describe behavior; do **not** invent features.

**Files:**
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/pages/what-is-anglesite.html`
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/pages/sites.html`
- Create: `Resources/Anglesite.help/Contents/Resources/en.lproj/pages/live-preview.html`

- [ ] **Step 1: Write `what-is-anglesite.html`**

Title "What is Anglesite?". Lead: a one-line description. Sections + required facts:
- **A native home for your website** — Anglesite hosts the Anglesite site toolkit; each site is a folder of files (an Astro static site).
- **Your files stay yours** — the filesystem is the source of truth. The site can always be opened and edited in Finder, VS Code, or the Claude Code CLI; Anglesite never becomes the only way to edit it. (From CLAUDE.md "filesystem is the source of truth".)
- **What you do here** — preview live, edit with Claude, check readiness, deploy.
- Figure placeholder: caption "The Anglesite site window — preview on the left, chat on the right."
- `See also`: `sites.html` (Open and create sites), `live-preview.html` (Live preview).

- [ ] **Step 2: Write `sites.html`**

Title "Open and create sites". Sections + facts:
- **The Sites window** — the launcher (Window titled "Sites") lists your sites; it's the default window at launch.
- **Opening a site** — opening a site gives it its own window; Anglesite auto-opens your most-recently-used site when you launch the app.
- **Switching between sites** — each site has its own window; use the Window menu or <kbd>⌘`</kbd> to switch. (Cross-link keyboard-shortcuts.)
- **Creating a new site** — today new sites are created with the `/anglesite:start` command in Claude Code; describe that path plainly (the in-app "New Site…" button is not yet available). Do not claim an in-app create flow exists.
- Figure placeholder: caption "The Sites launcher window."
- `See also`: `live-preview.html`, `editing-with-claude.html`.

- [ ] **Step 3: Write `live-preview.html`**

Title "Live preview". Sections + facts:
- **A live view of your site** — each site window shows a live preview of the running Astro dev server.
- **It starts and stops with the window** — opening a site starts its dev server; closing the window stops it. Each window is independent.
- **Reloading** — edits and saved file changes refresh the preview.
- Figure placeholder: caption "Live preview of a site in the Anglesite window."
- `See also`: `editing-with-claude.html`, `health-and-readiness.html`.

- [ ] **Step 4: Run the link-check (expect remaining-pages failures only)**

Run: `scripts/check-help-links.sh; echo "exit=$?"`
Expected: still FAIL, but the only dead links reported are the not-yet-created pages from Tasks 6–7 (e.g. `editing-with-claude.html`, `health-and-readiness.html`). No dead link should point to a page created in this task. Eyeball the list to confirm.

- [ ] **Step 5: Commit**

```bash
git add Resources/Anglesite.help/Contents/Resources/en.lproj/pages
git commit -m "docs(help): get-started pages (what-is, sites, live-preview)"
```

---

## Task 6: Editing pages

**Files:**
- Create: `pages/editing-with-claude.html`
- Create: `pages/images.html`
- Create: `pages/undo.html`

(All under `Resources/Anglesite.help/Contents/Resources/en.lproj/`.)

- [ ] **Step 1: Write `editing-with-claude.html`**

Title "Editing with Claude". Facts:
- **The chat panel** — ask Claude to make changes to your site in plain language.
- **Edits appear in your site** — Claude's edits are applied to your files and reflected in the live preview; an in-preview edit overlay shows what changed.
- **Every edit is tracked** — each successful edit shows in the chat as a row with the file changed and a relative time, with an Undo button (see Undoing edits).
- Figure placeholder: caption "Asking Claude to edit a page from the chat panel."
- `See also`: `images.html`, `undo.html`.

- [ ] **Step 2: Write `images.html`**

Title "Adding and optimizing images". Facts (from image-drop design, Phase 10 item 3):
- **Drag an image onto the page** — drop an image onto a picture in the preview to replace it.
- **Anglesite optimizes it automatically** — the image is converted/optimized (WebP, EXIF stripped) and responsive variants are generated (480/768/1024/1920) into the site's `public/images/`; the original is preserved under `public/images/originals/`. The preview swaps to the optimized image when done.
- **If something goes wrong** — on failure the original image is restored and a message explains why.
- Figure placeholder: caption "Dropping a new image onto the preview."
- `See also`: `editing-with-claude.html`, `undo.html`.

- [ ] **Step 3: Write `undo.html`**

Title "Undoing edits". Facts (from edit-undo design, Phase 10 item 4):
- **Undo the most recent edit** — each edit row in chat has an Undo button; the button is enabled on the most recent not-yet-undone edit.
- **When a file changed outside Anglesite** — if the file was modified in Finder, VS Code, or the CLI since the edit, Undo pauses and asks you to confirm before overwriting ("Undo anyway").
- **History is preserved** — undo is recorded, not destructive to history.
- Figure placeholder: caption "An edit row in chat with the Undo button."
- `See also`: `editing-with-claude.html`, `images.html`.

- [ ] **Step 4: Run the link-check**

Run: `scripts/check-help-links.sh; echo "exit=$?"`
Expected: FAIL only for the still-missing Task 7 pages; no dead link to any page created in Tasks 5–6.

- [ ] **Step 5: Commit**

```bash
git add Resources/Anglesite.help/Contents/Resources/en.lproj/pages
git commit -m "docs(help): editing pages (claude, images, undo)"
```

---

## Task 7: Publishing + reference pages (book goes green)

Author the remaining eight pages. After this task the link-check passes fully.

**Files (all under `…/en.lproj/pages/`):**
- Create: `health-and-readiness.html`, `deploying.html`, `accounts.html`, `settings.html`, `updates.html`, `debug-pane.html`, `keyboard-shortcuts.html`, `troubleshooting.html`

- [ ] **Step 1: Write `health-and-readiness.html`**

Title "Health and deploy readiness". Facts (health-badge design, Phase 10 item 2):
- **The readiness dot** — a colored dot in the site window's toolbar shows whether the site is ready to deploy (green / yellow / red), using the same pre-deploy checks the Deploy button enforces.
- **What it checks** — runs the build plus the standard pre-deploy checks; the popover lists any failures and warnings.
- **Rechecking** — it refreshes when you click Recheck or after a deploy.
- **Ask Claude for a deeper audit** — the popover's "Ask Claude" opens the chat and runs the deeper `/anglesite:check` audit.
- Figure placeholder: caption "The readiness popover listing checks."
- `See also`: `deploying.html`, `editing-with-claude.html`.

- [ ] **Step 2: Write `deploying.html`**

Title "Deploying your site". Facts:
- **Deploy from the site window** — the Deploy drawer publishes your site.
- **Checks run first** — every deploy runs the pre-deploy checks; the app cannot bypass them. If a check fails the deploy is blocked and a sheet explains what to fix (it surfaces failures rather than allowing override). (From CLAUDE.md: app cannot bypass plugin security hooks.)
- **Accounts** — deploying needs your GitHub and/or Cloudflare setup (cross-link accounts).
- Figure placeholder: caption "The Deploy drawer."
- `See also`: `accounts.html`, `health-and-readiness.html`.

- [ ] **Step 3: Write `accounts.html`**

Title "Accounts and setup". Facts:
- **GitHub** — sign in to GitHub for backup/publishing; describe the in-app sign-in.
- **Cloudflare** — provide a Cloudflare API token when prompted.
- **Stored securely** — credentials are stored in the macOS Keychain.
- Figure placeholder: caption "Signing in to GitHub."
- `See also`: `deploying.html`, `settings.html`.

- [ ] **Step 4: Write `settings.html`**

Title "Settings". Open Settings with <kbd>⌘,</kbd>. Describe the settings surface at a high level (general preferences; account/connection status). Keep claims general — do not enumerate options that may change. Figure placeholder: caption "Anglesite Settings."
- `See also`: `accounts.html`, `updates.html`.

- [ ] **Step 5: Write `updates.html`**

Title "Updating Anglesite". Facts:
- Updates come through the App Store.
- Anglesite uses App Store updates rather than an in-app updater.
- `See also`: `settings.html`, `troubleshooting.html`.

- [ ] **Step 6: Write `debug-pane.html`**

Title "Debug pane and logs". Facts:
- **Opening it** — View menu ▸ Show Debug Pane, or <kbd>⌥⌘D</kbd>.
- **What it shows** — streamed stdout/stderr from the background processes Anglesite runs (the dev server, the site toolkit). Useful when reporting a problem.
- Figure placeholder: caption "The debug pane streaming logs."
- `See also`: `troubleshooting.html`, `keyboard-shortcuts.html`.

- [ ] **Step 7: Write `keyboard-shortcuts.html`**

Title "Keyboard shortcuts". A definition-style list using `<kbd>`:
- <kbd>⌘`</kbd> — cycle between open site windows.
- <kbd>⌥⌘D</kbd> — show the Debug pane.
- <kbd>⌘,</kbd> — open Settings.
- <kbd>⌘?</kbd> — open this Help.
- `See also`: `debug-pane.html`, `what-is-anglesite.html`.

> Only list shortcuts confirmed in `AnglesiteApp.swift` (`⌥⌘D` is wired explicitly; `⌘,`/`⌘?`/`⌘`` are macOS standards). If a shortcut can't be confirmed in the sources, omit it rather than guess.

- [ ] **Step 8: Write `troubleshooting.html`**

Title "Troubleshooting". Q&A sections:
- **The preview won't load** — give it a moment to start; check the Debug pane for errors; close and reopen the site window to restart its dev server.
- **My deploy is blocked** — open the readiness popover / blocked-deploy sheet to see which checks failed, fix them, and deploy again.
- **An edit didn't apply** — check the chat for the failure message; the original is restored on failure.
- **Where are my files?** — your site is a folder on disk you can open in Finder at any time.
- `See also`: `debug-pane.html`, `health-and-readiness.html`.

- [ ] **Step 9: Run the link-check — expect PASS**

Run: `scripts/check-help-links.sh; echo "exit=$?"`
Expected: `OK: all help links resolve.` and `exit=0`. If any dead link remains, fix the offending `href` before committing.

- [ ] **Step 10: Rebuild the index over the full content**

Run: `scripts/build-help-index.sh`
Expected: `Help index built: ...` (re-indexes now that all pages exist).

- [ ] **Step 11: Commit**

```bash
git add Resources/Anglesite.help/Contents/Resources/en.lproj/pages
git commit -m "docs(help): publishing and reference pages — book complete"
```

---

## Task 8: Build + Help-menu verification

Confirm the book ships in the app bundle and the Help menu opens it.

**Files:** none (verification + optional Swift fallback).

- [ ] **Step 1: Build the DevID scheme**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm the book + index are in the built app**

Run (resolve the built product path from DerivedData or the local `build/` dir; adjust if needed):
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'Anglesite.app' -path '*Debug*' 2>/dev/null | head -1)
ls "$APP/Contents/Resources/Anglesite.help/Contents/Resources/en.lproj/index.html"
ls "$APP/Contents/Resources/Anglesite.help/Contents/Resources/en.lproj/Anglesite.helpindex"
```
Expected: both paths exist.

- [ ] **Step 3: Confirm the Help Book keys are in the built Info.plist**

Run:
```bash
plutil -extract CFBundleHelpBookName raw "$APP/Contents/Info.plist"
plutil -extract CFBundleHelpBookFolder raw "$APP/Contents/Info.plist"
```
Expected: prints `dev.anglesite.app.help` and `Anglesite.help`.

- [ ] **Step 4: Launch and verify the Help menu (manual)**

Run: `open "$APP"`
Then manually: open the **Help** menu → click **Anglesite Help**. Expected: Help Viewer opens to the Anglesite Help landing page; clicking TOC links navigates; typing in the Help-menu search field returns indexed results.

- [ ] **Step 5: Swift fallback — only if Step 4's "Anglesite Help" item is missing or does nothing**

If and only if the default Help item fails to open the book, add a Help command group in `Sources/AnglesiteApp/AnglesiteApp.swift` inside the existing `.commands { … }` block:

```swift
CommandGroup(replacing: .help) {
    Button("Anglesite Help") {
        NSApplication.shared.showHelp(nil)
    }
    .keyboardShortcut("?", modifiers: .command)
}
```

Then `xcodebuild … build` again and repeat Step 4. If Step 4 already worked, skip this step — no Swift change is needed.

- [ ] **Step 6: Build the MAS scheme**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` (confirms the help wiring works on the sandboxed target too).

- [ ] **Step 7: Commit (only if Step 5 changed Swift)**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(help): add explicit Help menu command opening the help book"
```

> If Step 5 was skipped, there is nothing to commit here — the book and wiring were committed in Tasks 1–7.

---

## Task 9: Update the build plan

Record completion in the roadmap.

**Files:**
- Modify: `docs/build-plan.md`

- [ ] **Step 1: Note Apple Help under Phase 10**

In `docs/build-plan.md`, under the **Phase 10 — v2 polish** section, add a line recording that the Apple Help Book shipped, linking the design and plan docs, and noting the deferred follow-ups (screenshot capture; book icon artwork). Match the prose style of the existing Phase 10 entries.

- [ ] **Step 2: Commit**

```bash
git add docs/build-plan.md
git commit -m "docs(plan): record Apple Help Book under Phase 10"
```

---

## Self-review notes

- **Spec coverage:** bundle structure (Task 2) · book Info.plist keys (Task 2) · all 15 pages incl. index (Tasks 2,5,6,7) · Apple-native CSS w/ dark mode (Task 2) · screenshot placeholders (Task 4 snippet, used in 5–7) · `project.yml` resource + pre-build wiring on both targets (Task 3) · `build-help-index.sh` w/ hiutil + best-effort guard (Task 3) · `.gitignore` for `.helpindex` (Task 3) · both Info.plist keys (Task 3) · Help-menu integration + Swift fallback (Task 8) · `check-help-links.sh` (Task 1) · build verification both schemes (Task 8). YAGNI guards (en-only, no Markdown, no committed screenshots, no remote help) honored.
- **Type/path consistency:** book id `dev.anglesite.app.help` used identically in the book manifest, both app Info.plists, and `CFBundleHelpBookName`. `HPDBookAccessPath = index.html` and `HPDBookIndexPath = Anglesite.helpindex` match the files created. Page filenames in `index.html`'s TOC exactly match the files authored in Tasks 5–7. Pre-build script name "Build Help index" and path `scripts/build-help-index.sh` consistent.
- **Link-check timing:** the check intentionally fails in Tasks 2/5/6 (forward links to not-yet-written pages) and goes green in Task 7 Step 9 — each interim step says so explicitly, so a worker won't mistake it for a real failure.
