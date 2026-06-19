# Plugin: apply_edit dry_run + edit-style op — Implementation Plan (Plan A of 2, #251)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-mutating `dry_run` mode and a new `edit-style` op to the Anglesite plugin's `apply_edit` MCP tool, then tag a release the app can consume.

**Architecture:** `dry_run` reuses the dispatcher's already-computed before (`source`) / after (`next`) strings, skipping the write + history commit and returning a new `edit-preview` body with a windowed diff. `edit-style` is a new resolver that rewrites the owning `.astro` component file: it merges a rule into the component's scoped `<style>` block (creating one if absent) and adds a marker class to the element's opening tag only when it has no id/class. The style resolver returns the *whole rewritten file* as the replacement over `range {0, source.length}`, so the existing single-splice write path is unchanged.

**Tech Stack:** Node ESM (`.mjs`), Zod schemas, Vitest. This is the plugin repo at `/Users/dwk/Developer/github.com/Anglesite/anglesite` — **all work happens there**, NOT in the app repo.

## Global Constraints

- Repo: `/Users/dwk/Developer/github.com/Anglesite/anglesite` (the sibling plugin checkout). `cd` there before any command.
- Language: Node ESM `.mjs`. No TypeScript in `server/`.
- Test runner: `vitest`. Run with `npm test` or `npx vitest run <file>`.
- `dry_run` is **read-only**: it must never write to disk or commit history.
- The op enum is closed-set; new ops require an explicit `editOps` addition + resolver update.
- Response bodies are JSON-stringified into a single MCP `text` content entry.
- `before`/`after` in a preview are the spliced region **plus a bounded context window** (default 200 chars each side), never unbounded whole files.
- Version bump touches BOTH `package.json` and `.claude-plugin/plugin.json` to the same value; the release workflow verifies version == tag.

---

### Task 1: `edit-preview` response builder

**Files:**
- Modify: `server/apply-edit-schema.mjs:85-90` (add builder next to `createEditAppliedContent`)
- Test: `tests/apply-edit-preview.test.ts` (create)

**Interfaces:**
- Produces: `createEditPreviewContent(id, file, range, op, before, after)` → `{ type: "text", text: string }` where the parsed text is `{ type: "anglesite:edit-preview", id, file, range, op, before, after }`.

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-preview.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { createEditPreviewContent } from "../server/apply-edit-schema.mjs";

describe("createEditPreviewContent", () => {
  it("builds an edit-preview body with before/after", () => {
    const entry = createEditPreviewContent(
      "abc", "src/pages/about.astro", { start: 10, end: 17 },
      "replace-text", "Welcome", "Hello",
    );
    expect(entry.type).toBe("text");
    const body = JSON.parse(entry.text);
    expect(body).toEqual({
      type: "anglesite:edit-preview",
      id: "abc",
      file: "src/pages/about.astro",
      range: { start: 10, end: 17 },
      op: "replace-text",
      before: "Welcome",
      after: "Hello",
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run tests/apply-edit-preview.test.ts`
Expected: FAIL — `createEditPreviewContent is not a function`.

- [ ] **Step 3: Add the builder**

Append to `server/apply-edit-schema.mjs` (after `createEditAppliedContent`):

```js
/** Build the MCP `content` entry for an edit-preview (dry-run) response. `before`/`after` are the
 *  windowed source fragments around the change — see dispatcher `windowAround`. */
export function createEditPreviewContent(id, file, range, op, before, after) {
  const body = { type: "anglesite:edit-preview", id, file, range, op, before, after };
  return { type: "text", text: JSON.stringify(body) };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/apply-edit-preview.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git add server/apply-edit-schema.mjs tests/apply-edit-preview.test.ts
git commit -m "feat(apply-edit): add edit-preview response builder"
```

---

### Task 2: `dry_run` schema flag + windowed dispatcher path

**Files:**
- Modify: `server/apply-edit-schema.mjs:44-70` (add `dry_run` to `applyEditInputShape`)
- Modify: `server/apply-edit-dispatcher.mjs` (import builder; add `windowAround`; short-circuit before write)
- Test: `tests/apply-edit-dry-run.test.ts` (create)

**Interfaces:**
- Consumes: `createEditPreviewContent` (Task 1).
- Produces: `applyEdit(projectRoot, edit, opts)` returns an `edit-preview` (no `isError`) when `edit.dry_run === true`; otherwise behaves exactly as before. New local helper `windowAround(source, start, end, pad = 200)` → `{ before, after }`.

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-dry-run.test.ts`. (Uses a temp Astro project; mirror the fixture style in existing patcher tests — write a minimal `src/pages/about.astro`.)

```ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyEdit } from "../server/apply-edit-dispatcher.mjs";

let root: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ang-dry-"));
  mkdirSync(join(root, "src/pages"), { recursive: true });
  writeFileSync(join(root, "src/pages/about.astro"), "---\n---\n<h1>Welcome</h1>\n");
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const baseEdit = {
  id: "1",
  path: "/about/",
  selector: { tag: "h1", classes: [], nthChild: 1, textContent: "Welcome" },
  op: "replace-text",
  value: "Hello",
};

describe("apply_edit dry_run", () => {
  it("returns edit-preview without mutating the file", () => {
    const before = readFileSync(join(root, "src/pages/about.astro"), "utf-8");
    const res = applyEditSync({ ...baseEdit, dry_run: true });
    expect(res.isError).toBeFalsy();
    const body = JSON.parse(res.content[0].text);
    expect(body.type).toBe("anglesite:edit-preview");
    expect(body.before).toContain("Welcome");
    expect(body.after).toContain("Hello");
    // critical: file is byte-identical
    expect(readFileSync(join(root, "src/pages/about.astro"), "utf-8")).toBe(before);
  });

  it("still refuses (no-match) under dry_run", async () => {
    const res = await applyEdit(root, {
      ...baseEdit, dry_run: true,
      selector: { tag: "h1", classes: [], nthChild: 1, textContent: "Nonexistent" },
    });
    expect(res.isError).toBe(true);
    expect(JSON.parse(res.content[0].text).reason).toBe("no-match");
  });

  // helper to await applyEdit synchronously in the first test
  function applyEditSync(edit) {
    let out;
    // applyEdit is async; resolve before assertions
    return (out = applyEditPromise(edit));
  }
  function applyEditPromise(edit) {
    // vitest supports returning a promise; but we need sync read after.
    // Use the async form instead:
    throw new Error("use async");
  }
});
```

Replace the awkward helper: write the first test as `async` and `await applyEdit(root, {...baseEdit, dry_run: true})` directly (the helper stubs above exist only to make the intent explicit — delete them and use `await`).

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/apply-edit-dry-run.test.ts`
Expected: FAIL — `dry_run` is dropped by the schema / no `edit-preview` returned (current code writes and returns `edit-applied`).

- [ ] **Step 3: Add the schema flag**

In `server/apply-edit-schema.mjs`, add to `applyEditInputShape` (after `value`):

```js
  dry_run: z
    .boolean()
    .optional()
    .describe(
      "When true, compute the would-be change and return an edit-preview {before, after} WITHOUT writing to disk or recording history",
    ),
```

- [ ] **Step 4: Add the dispatcher short-circuit + window helper**

In `server/apply-edit-dispatcher.mjs`:

Add to the import from `./apply-edit-schema.mjs`:

```js
import {
  createEditAppliedContent,
  createEditFailedContent,
  createEditPreviewContent,
} from "./apply-edit-schema.mjs";
```

Add a helper near `spliceSource`:

```js
/** Bounded before/after fragments around a [start,end) splice — keeps preview payloads small. */
function windowAround(source, start, end, replacement, pad = 200) {
  const from = Math.max(0, start - pad);
  const to = Math.min(source.length, end + pad);
  const before = source.slice(from, to);
  const after = source.slice(from, start) + replacement + source.slice(end, to);
  return { before, after };
}

function preview(id, file, range, op, before, after) {
  return { content: [createEditPreviewContent(id, file, range, op, before, after)] };
}
```

In `applyEdit`, replace the block from `const next = spliceSource(...)` through the `atomicWrite` try/catch with:

```js
  const next = spliceSource(source, range, replacement);

  if (edit.dry_run) {
    const { before, after } = windowAround(source, range.start, range.end, replacement);
    return preview(edit.id, file, range, edit.op, before, after);
  }

  try {
    atomicWrite(absPath, next);
  } catch (err) {
    return failed(edit.id, "write-failed", `${file}: ${err.message}`);
  }
```

(The `onApplied` history block and final `applied(...)` return stay exactly as they are — only reached when `dry_run` is falsy.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run tests/apply-edit-dry-run.test.ts`
Expected: PASS (both: preview returned + file unchanged; refusal under dry_run).

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `npm test`
Expected: PASS — existing `apply_edit` tests unaffected (they don't set `dry_run`).

- [ ] **Step 7: Commit**

```bash
git add server/apply-edit-schema.mjs server/apply-edit-dispatcher.mjs tests/apply-edit-dry-run.test.ts
git commit -m "feat(apply-edit): add read-only dry_run preview path"
```

---

### Task 3: `edit-style` op — scoped `<style>` rewrite with marker class

**Files:**
- Modify: `server/apply-edit-schema.mjs:41` (`editOps`) and `:60-69` (op/value `.describe`)
- Create: `server/style-edit.mjs` (pure rewrite logic, unit-testable in isolation)
- Modify: `server/patcher.mjs` (route `op === "edit-style"` to the new resolver, returning whole-file replacement)
- Test: `tests/style-edit.test.ts` (create), `tests/patcher-edit-style.test.ts` (create)

**Interfaces:**
- Consumes: `pathToAstroCandidates`, `findAstroTemplateStart` patterns from `patcher.mjs` (style resolver reuses `.astro` candidate resolution).
- Produces:
  - `rewriteAstroStyle(source, { tag, id, classes, nthChild, textContent }, property, value)` (in `style-edit.mjs`) → `{ next: string, selectorUsed: string, addedMarkerClass?: string }` or `{ refused: true, reason, detail }`.
  - `patcher.resolve(...)` returns for `edit-style`: `{ file, range: { start: 0, end: source.length }, replacement: next }`.

- [ ] **Step 1: Write the failing unit test for the pure rewriter**

Create `tests/style-edit.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { rewriteAstroStyle } from "../server/style-edit.mjs";

const FM = "---\n---\n";

describe("rewriteAstroStyle", () => {
  it("targets an existing id and creates a scoped <style> block", () => {
    const src = `${FM}<h1 id="title">Welcome</h1>\n`;
    const r = rewriteAstroStyle(src, { tag: "h1", id: "title", classes: [], nthChild: 1, textContent: "Welcome" }, "color", "teal");
    expect(r.refused).toBeFalsy();
    expect(r.selectorUsed).toBe("#title");
    expect(r.next).toContain("<style>");
    expect(r.next).toMatch(/#title\s*\{[^}]*color:\s*teal/);
    expect(r.addedMarkerClass).toBeUndefined();
  });

  it("adds a marker class when the element has no id or class", () => {
    const src = `${FM}<h1>Welcome</h1>\n`;
    const r = rewriteAstroStyle(src, { tag: "h1", classes: [], nthChild: 1, textContent: "Welcome" }, "color", "teal");
    expect(r.refused).toBeFalsy();
    expect(r.addedMarkerClass).toMatch(/^ang-[0-9a-f]{6}$/);
    expect(r.next).toContain(`class="${r.addedMarkerClass}"`);
    expect(r.next).toMatch(new RegExp(`\\.${r.addedMarkerClass}\\s*\\{[^}]*color:\\s*teal`));
  });

  it("merges into an existing scoped <style> rule for the same selector", () => {
    const src = `${FM}<h1 id="t">Hi</h1>\n<style>\n  #t { font-size: 2rem; }\n</style>\n`;
    const r = rewriteAstroStyle(src, { tag: "h1", id: "t", classes: [], nthChild: 1, textContent: "Hi" }, "color", "teal");
    expect(r.next).toMatch(/#t\s*\{[^}]*font-size:\s*2rem/);
    expect(r.next).toMatch(/#t\s*\{[^}]*color:\s*teal/);
    expect((r.next.match(/<style>/g) || []).length).toBe(1); // no duplicate block
  });

  it("refuses when the element cannot be located", () => {
    const src = `${FM}<h1 id="t">Hi</h1>\n`;
    const r = rewriteAstroStyle(src, { tag: "h2", classes: [], nthChild: 1, textContent: "Missing" }, "color", "teal");
    expect(r.refused).toBe(true);
    expect(r.reason).toBe("no-match");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run tests/style-edit.test.ts`
Expected: FAIL — module `style-edit.mjs` not found.

- [ ] **Step 3: Implement `style-edit.mjs`**

Create `server/style-edit.mjs`:

```js
/**
 * Pure scoped-<style> rewriter for the `edit-style` op.
 *
 * Component-encapsulation model: a style change lands in the owning .astro file's scoped
 * <style> block (created if absent), targeting the element via its existing #id or .class.
 * When the element has neither, a deterministic marker class (ang-<6 hex>) is added to its
 * opening tag and used as the selector.
 *
 * Returns { next, selectorUsed, addedMarkerClass? } or { refused, reason, detail }.
 */
import { createHash } from "node:crypto";

function refuse(reason, detail) {
  return { refused: true, reason, detail };
}

/** Locate the element's opening tag in `source`. Returns {start, end, tagText} or null. */
function findOpeningTag(source, selector) {
  const tag = selector.tag?.toLowerCase();
  if (!tag) return null;
  // Prefer locating by the element's static text content (same heuristic the text resolver uses).
  const re = new RegExp(`<${tag}\\b[^>]*>`, "gi");
  let m;
  const tags = [];
  while ((m = re.exec(source)) !== null) {
    tags.push({ start: m.index, end: m.index + m[0].length, tagText: m[0] });
  }
  if (tags.length === 0) return null;
  if (selector.textContent) {
    // pick the tag immediately preceding the textContent occurrence
    const idx = source.indexOf(selector.textContent);
    if (idx !== -1) {
      const owning = tags.filter((t) => t.end <= idx).sort((a, b) => b.end - a.end)[0];
      if (owning) return owning;
    }
  }
  return tags.length === 1 ? tags[0] : null; // ambiguous without text anchor
}

/** Derive the CSS selector for the element, mutating the tag to add a marker class if needed. */
function deriveSelector(tagText, selector) {
  if (selector.id) return { selectorUsed: `#${selector.id}`, newTagText: tagText };
  if (selector.classes && selector.classes.length > 0) {
    return { selectorUsed: `.${selector.classes[0]}`, newTagText: tagText };
  }
  // No id/class: synthesize a deterministic marker class from tag + textContent.
  const seed = `${selector.tag}|${selector.textContent ?? ""}|${selector.nthChild ?? 0}`;
  const marker = "ang-" + createHash("sha1").update(seed).digest("hex").slice(0, 6);
  // inject class="..." before the closing > (handle self-closing and existing attrs)
  const newTagText = tagText.replace(/(\s*\/?>)$/, ` class="${marker}"$1`);
  return { selectorUsed: `.${marker}`, addedMarkerClass: marker, newTagText };
}

/** Insert/merge `property: value` for `selectorUsed` in the file's scoped <style> block. */
function upsertStyleRule(source, selectorUsed, property, value) {
  const decl = `${property}: ${value};`;
  const styleRe = /<style>([\s\S]*?)<\/style>/i;
  const sm = source.match(styleRe);
  if (!sm) {
    // No <style> block — append one at end of file.
    const block = `\n<style>\n  ${selectorUsed} { ${decl} }\n</style>\n`;
    return source.replace(/\s*$/, "") + block + "\n";
  }
  const css = sm[1];
  // Existing rule for this selector?
  const ruleRe = new RegExp(`(${escapeRegex(selectorUsed)}\\s*\\{)([^}]*)(\\})`);
  const rm = css.match(ruleRe);
  let newCss;
  if (rm) {
    const body = rm[2].trim();
    const merged = body.length ? `${body} ${decl}` : decl;
    newCss = css.replace(ruleRe, `$1 ${merged} $3`);
  } else {
    newCss = `${css.replace(/\s*$/, "")}\n  ${selectorUsed} { ${decl} }\n`;
  }
  return source.replace(styleRe, `<style>${newCss}</style>`);
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function rewriteAstroStyle(source, selector, property, value) {
  const tag = findOpeningTag(source, selector);
  if (!tag) return refuse("no-match", `could not locate <${selector.tag}> for style edit`);
  const { selectorUsed, addedMarkerClass, newTagText } = deriveSelector(tag.tagText, selector);
  let next = source;
  if (newTagText !== tag.tagText) {
    next = source.slice(0, tag.start) + newTagText + source.slice(tag.end);
  }
  next = upsertStyleRule(next, selectorUsed, property, value);
  const result = { next, selectorUsed };
  if (addedMarkerClass) result.addedMarkerClass = addedMarkerClass;
  return result;
}
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `npx vitest run tests/style-edit.test.ts`
Expected: PASS (all four cases).

- [ ] **Step 5: Write the failing patcher-integration test**

Create `tests/patcher-edit-style.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolve } from "../server/patcher.mjs";

let root: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ang-style-"));
  mkdirSync(join(root, "src/pages"), { recursive: true });
  writeFileSync(join(root, "src/pages/about.astro"), "---\n---\n<h1 id=\"t\">Welcome</h1>\n");
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

describe("patcher resolve() for edit-style", () => {
  it("returns whole-file replacement with the merged style", () => {
    const r = resolve(root, {
      path: "/about/",
      selector: { tag: "h1", id: "t", classes: [], nthChild: 1, textContent: "Welcome" },
      op: "edit-style",
      value: { property: "color", value: "teal" },
    });
    expect(r.refused).toBeFalsy();
    expect(r.range).toEqual({ start: 0, end: expect.any(Number) });
    expect(r.replacement).toMatch(/#t\s*\{[^}]*color:\s*teal/);
  });
});
```

- [ ] **Step 6: Run to verify it fails**

Run: `npx vitest run tests/patcher-edit-style.test.ts`
Expected: FAIL — `resolve` has no `edit-style` branch (falls through to no-match).

- [ ] **Step 7: Route `edit-style` in `patcher.mjs`**

At the top of `server/patcher.mjs`, import the rewriter:

```js
import { rewriteAstroStyle } from "./style-edit.mjs";
```

In `resolve(projectRoot, edit)`, add a dedicated branch BEFORE the resolver loop (style only applies to `.astro`, and returns whole-file replacement):

```js
export function resolve(projectRoot, edit) {
  if (edit.op === "edit-style") {
    return resolveStyle(projectRoot, edit);
  }
  const resolvers = [resolveMdoc, resolveKeystatic, resolveAstro];
  // …unchanged…
}
```

Add the resolver near `resolveAstro`:

```js
/** Resolve an edit-style op to a whole-file rewrite of the owning .astro component. */
function resolveStyle(projectRoot, edit) {
  const { path: pagePath, selector, value } = edit;
  if (!value || typeof value !== "object" || !value.property) {
    return refuse("no-match", "edit-style value must be { property, value }");
  }
  const candidates = pathToAstroCandidates(projectRoot, pagePath);
  if (candidates.length === 0) {
    return refuse("no-match", `no .astro file found for path ${pagePath}`);
  }
  const hits = [];
  for (const file of candidates) {
    let source;
    try {
      source = readFileSync(file, "utf-8");
    } catch {
      continue;
    }
    const r = rewriteAstroStyle(source, selector, value.property, value.value);
    if (!r.refused) hits.push({ file: relative(projectRoot, file), source, r });
  }
  if (hits.length === 0) {
    return refuse("no-match", `could not locate <${selector.tag}> for style edit`);
  }
  if (hits.length > 1) {
    return refuse("ambiguous", `element matched in ${hits.length} .astro files`);
  }
  const { file, source, r } = hits[0];
  return { file, range: { start: 0, end: source.length }, replacement: r.next };
}
```

- [ ] **Step 8: Add `edit-style` to the schema enum + descriptions**

In `server/apply-edit-schema.mjs`:

```js
export const editOps = ["replace-text", "replace-attr", "replace-image-src", "edit-style"];
```

Update the `op` `.describe` and `value` `.describe` to mention: `edit-style (value is {property, value}; merges a rule into the owning component's scoped <style>)`.

- [ ] **Step 9: Run the patcher + full suite**

Run: `npx vitest run tests/patcher-edit-style.test.ts && npm test`
Expected: PASS — new edit-style resolution works; existing tests unaffected.

- [ ] **Step 10: Commit**

```bash
git add server/style-edit.mjs server/patcher.mjs server/apply-edit-schema.mjs tests/style-edit.test.ts tests/patcher-edit-style.test.ts
git commit -m "feat(apply-edit): add edit-style op (scoped <style> + marker class)"
```

---

### Task 4: dry_run × edit-style end-to-end + style dry_run window

**Files:**
- Test: `tests/apply-edit-dry-run.test.ts` (extend)

**Interfaces:**
- Consumes: `applyEdit` dry_run (Task 2), `edit-style` (Task 3).

- [ ] **Step 1: Write the failing test**

Add to `tests/apply-edit-dry-run.test.ts`:

```ts
it("dry_run edit-style returns a preview and leaves the file unchanged", async () => {
  const file = join(root, "src/pages/about.astro");
  writeFileSync(file, "---\n---\n<h1 id=\"t\">Welcome</h1>\n");
  const before = readFileSync(file, "utf-8");
  const res = await applyEdit(root, {
    id: "9", path: "/about/",
    selector: { tag: "h1", id: "t", classes: [], nthChild: 1, textContent: "Welcome" },
    op: "edit-style", value: { property: "color", value: "teal" }, dry_run: true,
  });
  expect(res.isError).toBeFalsy();
  const body = JSON.parse(res.content[0].text);
  expect(body.type).toBe("anglesite:edit-preview");
  expect(body.op).toBe("edit-style");
  expect(body.after).toMatch(/color:\s*teal/);
  expect(readFileSync(file, "utf-8")).toBe(before); // unchanged
});
```

Note: because edit-style returns `range {0, source.length}`, `windowAround` with `pad=200` will include the whole small file — acceptable. The `after` contains the merged rule.

- [ ] **Step 2: Run to verify it passes (no new code expected)**

Run: `npx vitest run tests/apply-edit-dry-run.test.ts`
Expected: PASS — Task 2's dry_run path is op-agnostic, so edit-style previews for free. If it FAILS, the dispatcher short-circuit was placed after an op-specific branch; move it as specified in Task 2 Step 4.

- [ ] **Step 3: Commit**

```bash
git add tests/apply-edit-dry-run.test.ts
git commit -m "test(apply-edit): dry_run preview for edit-style"
```

---

### Task 5: MCP-server integration test (tools/list + call)

**Files:**
- Modify: `tests/mcp-server.test.ts` (add `edit-style` + `dry_run` over the JSON-RPC stdio boundary)

**Interfaces:**
- Consumes: the running server (spawned as in existing tests).

- [ ] **Step 1: Write the failing test**

Add a case mirroring the existing `apply_edit` JSON-RPC tests: spawn the server against a temp project with `src/pages/about.astro` containing `<h1 id="t">Welcome</h1>`, send `tools/call` for `apply_edit` with `op: "edit-style"`, `value: { property: "color", value: "teal" }`, `dry_run: true`, and assert the response text parses to `type: "anglesite:edit-preview"` with `after` containing `color: teal`, and that the file on disk is unchanged.

(Follow the exact spawn/JSON-RPC helper already in `tests/mcp-server.test.ts:130-153`; reuse its request/response plumbing rather than re-implementing it.)

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `npx vitest run tests/mcp-server.test.ts`
Expected: PASS once Tasks 2–3 are in (this test asserts the wiring, which already exists). If the schema rejects `dry_run`/`edit-style`, revisit Task 2 Step 3 / Task 3 Step 8.

- [ ] **Step 3: Commit**

```bash
git add tests/mcp-server.test.ts
git commit -m "test(mcp): apply_edit dry_run + edit-style over stdio"
```

---

### Task 6: Version bump + release

**Files:**
- Modify: `package.json:3` (version)
- Modify: `.claude-plugin/plugin.json:3` (version)

**Interfaces:** none (release artifact).

- [ ] **Step 1: Bump both version fields**

Read the current version in `package.json` and `.claude-plugin/plugin.json` (they match). Increment the **minor** version (new backward-compatible features): e.g. `0.16.4` → `0.17.0` for the server, matching the convention already in the repo. Set BOTH files to the same new value.

- [ ] **Step 2: Run the full suite**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npm test`
Expected: PASS (all suites).

- [ ] **Step 3: Commit**

```bash
git add package.json .claude-plugin/plugin.json
git commit -m "chore(release): vX.Y.Z — apply_edit dry_run + edit-style"
```

- [ ] **Step 4: Open the PR (do not tag yet)**

```bash
git push -u origin <branch>
gh pr create --title "feat(apply-edit): dry_run preview + edit-style op (paired with app #251)" \
  --body "Adds a read-only dry_run mode to apply_edit and a new edit-style op (scoped <style> + marker class). Paired with Anglesite-app #251. Tag a release after merge so the app can bump its bundled-plugin pointer."
```

Tagging the release (`git tag vX.Y.Z && git push origin vX.Y.Z`) happens **after** this PR merges — that triggers the release workflow and produces the artifact the app's Plan B consumes.

---

## Self-Review

**Spec coverage:**
- dry_run flag + read-only preview → Task 2 ✓ (byte-identical assertion)
- edit-preview response shape `{before, after, file, range, op}` → Task 1 ✓
- windowed before/after → Task 2 `windowAround` ✓
- edit-style op → Task 3 ✓
- scoped `<style>` resolution by component → Task 3 `resolveStyle` + `rewriteAstroStyle` ✓
- marker class when no id/class → Task 3 `deriveSelector` ✓
- refusals preserved under dry_run → Task 2 test #2 ✓
- MCP wiring → Task 5 ✓
- paired release → Task 6 ✓

**Placeholder scan:** Task 1 test helper `applyEditSync`/`applyEditPromise` are deliberately-flagged stubs with an explicit "delete them and use await" instruction — not a silent placeholder. All other steps carry full code.

**Type consistency:** `createEditPreviewContent(id, file, range, op, before, after)` is defined in Task 1 and called with the same arg order in Task 2 (`preview(...)` wrapper). `rewriteAstroStyle(source, selector, property, value)` defined in Task 3 Step 3, called the same way in `resolveStyle`. `edit-style` op string consistent across schema, patcher, tests.

**Note for the implementer:** the edit-style whole-file replacement means `range.end` equals the *pre-edit* file length; that's intentional and the dispatcher splices over the whole file. Don't "optimize" it to a sub-range — the marker-class tag edit and the `<style>` edit are disjoint regions a single sub-range can't cover.
