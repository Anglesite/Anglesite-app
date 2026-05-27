# Image Drop Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the image-drop pipeline end-to-end: dropping a file on an `<img>` in the WKWebView preview writes the bytes to `public/images/`, runs sharp with EXIF stripping at four widths, patches the `<img>` tag with new `src` + `srcset`, and commits to a hidden git branch — surfaced in the overlay with an optimistic blob-URL preview and revert-on-fail.

**Architecture:** Paired PR. The plugin (`../anglesite`) gains the missing Phase 5 plumbing (apply-edit dispatcher + edit-history git module) plus the Phase 9 image-drop additions (hoisted optimize core + `replace-image-src` resolver + dispatcher preprocessing). The app overlay rewrites its image-drop handler to do the optimistic preview, swap-on-reply, revert-on-fail, and 30-second timeout. Wire schema stays unchanged except an optional `result: { src, srcset? }` field on `edit-applied`.

**Tech Stack:** Node.js ESM (plugin), sharp (image optimize), zod (schema), vitest (both repos' tests). TypeScript + esbuild (overlay), jsdom-backed vitest (overlay tests).

**Spec:** [`docs/specs/2026-05-26-image-drop-design.md`](2026-05-26-image-drop-design.md) (committed in `3468b11`).

**Tracking:** GitHub Anglesite-app#32. Plugin-side PR will be opened against `Anglesite/anglesite` and reference this design doc + the app issue.

---

## Discovery (Phase 5 leftovers)

Investigation during planning revealed that Phase 5 issues `#297` (server/index.mjs dispatcher) and `#298` (server/edit-history.mjs) are marked CLOSED on the plugin repo but the code never merged. The plugin's `apply_edit` MCP tool today returns `edit-failed: not-implemented`. Image drop is therefore blocked on these Phase 5 leftovers landing as well. **Tasks 1–4 below close out Phase 5 in the plugin repo;** tasks 5+ are the actual Phase 9 image-drop work on top.

The `docs/build-plan.md` change in Task 9 acknowledges this — it un-✅s Phase 5 steps 3 and 4 retroactively in the same commit where the paired PR makes them real.

## Working directories

The plan touches two repos in parallel:

| Repo alias | Absolute path |
|---|---|
| **plugin** | `/Users/dwk/Developer/github.com/Anglesite/anglesite` |
| **app** | `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app` |

Every task header below names the repo. `cd` into the right one before running commands.

## File map

| Path | Repo | Action | Purpose |
|---|---|---|---|
| `server/edit-history.mjs` | plugin | Create | git plumbing — commit a file's new content to `refs/heads/anglesite/edits` without touching the working tree or index |
| `test/edit-history.test.js` | plugin | Create | tests against a tmpdir bare repo |
| `server/messages.mjs` | plugin | Modify | add `"image-optimize-failed"` to `EDIT_FAILED_REASONS`; add optional `result` parameter to `createEditAppliedMessage` |
| `server/apply-edit-dispatcher.mjs` | plugin | Create | calls `patcher.resolve` → applies patch on disk → calls `editHistory.commit` → returns the MCP tool content array |
| `test/apply-edit-dispatcher.test.js` | plugin | Create | tests dispatcher's success / refused / write-failed / image preprocessing paths |
| `server/index.mjs` | plugin | Modify | replace the `apply_edit` stub handler with `dispatch(...)` |
| `server/optimize-images.mjs` | plugin | Create | ES-module implementation of the optimize core (hoisted from `template/scripts/optimize-images.ts`) — `optimizeImage(filePath, { widths }) → { primary, variants }` |
| `test/optimize-images.test.js` | plugin | Create | tests against a tiny real JPEG fixture; asserts WebP + variants exist and EXIF is stripped |
| `template/scripts/optimize-images.ts` | plugin | Modify | becomes a thin CLI wrapper that imports `server/optimize-images.mjs` and runs against `public/images/` for the existing `npm run ai-optimize` entry point |
| `server/patcher.mjs` | plugin | Modify | new `replace-image-src` resolver — takes `value: { src, srcset }` and rewrites the entire `<img>` opening tag |
| `test/patcher.test.js` | plugin | Modify | add `replace-image-src` cases |
| `JS/edit-overlay/src/messages.ts` | app | Modify | extend `EditReply` with optional `result: { src: string; srcset?: string }` field |
| `JS/edit-overlay/src/overlay.ts` | app | Modify | rewrite `attachImageDrop` for optimistic preview + swap/revert + 30s timeout |
| `JS/edit-overlay/src/toast.ts` | app | Create | small toast affordance — `showToast(text)` mounts a CSS-styled div bottom-right, auto-dismisses after 4s |
| `JS/edit-overlay/test/overlay.test.ts` | app | Modify | add `attachImageDrop` cases — applied / failed / timeout |
| `JS/edit-overlay/test/toast.test.ts` | app | Create | toast mount + auto-dismiss |
| `Resources/edit-overlay/overlay.js` | app | Regenerate | output of `scripts/build-overlay.sh` after overlay changes |
| `docs/build-plan.md` | app | Modify | un-✅ Phase 5 steps 3 + 4 retroactively in the same commit where they actually land; ✅ Phase 9 step 3 |

---

## Task 1 (plugin): server/edit-history.mjs + tests

Hidden-branch git plumbing. Each successful edit becomes a commit on `refs/heads/anglesite/edits`, leaving the working tree and index untouched. Uses git's `hash-object`, `update-index`, `write-tree`, `commit-tree`, `update-ref` — the plumbing commands that bypass the working tree.

**Files:**
- Create: `../anglesite/server/edit-history.mjs`
- Create: `../anglesite/test/edit-history.test.js`

- [ ] **Step 1: Write the failing tests**

Create `../anglesite/test/edit-history.test.js`:

```javascript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { commitEdit, currentHistoryHead } from "../server/edit-history.mjs";

let repo;

function git(args, opts = {}) {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", ...opts }).trim();
}

beforeEach(() => {
  repo = mkdtempSync(join(tmpdir(), "anglesite-edit-history-"));
  git("init -q -b main");
  git("config user.email test@example.com");
  git("config user.name Test");
  writeFileSync(join(repo, "README.md"), "initial\n");
  git("add README.md");
  git('commit -q -m "initial"');
});

afterEach(() => {
  rmSync(repo, { recursive: true, force: true });
});

describe("commitEdit", () => {
  it("creates anglesite/edits branch on first call and returns the new commit SHA", async () => {
    writeFileSync(join(repo, "page.astro"), "hello world\n");
    const sha = await commitEdit(repo, {
      file: "page.astro",
      content: "hello world\n",
      message: "edit page.astro",
    });
    expect(sha).toMatch(/^[0-9a-f]{40}$/);
    const head = git("rev-parse refs/heads/anglesite/edits");
    expect(head).toBe(sha);
  });

  it("subsequent commits chain as the parent of the new commit", async () => {
    writeFileSync(join(repo, "page.astro"), "v1\n");
    const sha1 = await commitEdit(repo, { file: "page.astro", content: "v1\n", message: "v1" });
    writeFileSync(join(repo, "page.astro"), "v2\n");
    const sha2 = await commitEdit(repo, { file: "page.astro", content: "v2\n", message: "v2" });
    expect(sha2).not.toBe(sha1);
    const parents = git(`rev-list --parents -n 1 ${sha2}`).split(" ");
    expect(parents[1]).toBe(sha1);
  });

  it("does not modify the working tree or index", async () => {
    writeFileSync(join(repo, "page.astro"), "patched\n");
    const statusBefore = git("status --porcelain");
    expect(statusBefore).toBe("?? page.astro");
    await commitEdit(repo, { file: "page.astro", content: "patched\n", message: "edit" });
    const statusAfter = git("status --porcelain");
    expect(statusAfter).toBe("?? page.astro");
  });

  it("commits files in nested directories", async () => {
    mkdirSync(join(repo, "src", "pages"), { recursive: true });
    writeFileSync(join(repo, "src/pages/about.astro"), "about\n");
    const sha = await commitEdit(repo, {
      file: "src/pages/about.astro",
      content: "about\n",
      message: "edit about",
    });
    const tree = git(`ls-tree -r ${sha}`);
    expect(tree).toContain("src/pages/about.astro");
  });

  it("includes multiple files in a single commit when given", async () => {
    writeFileSync(join(repo, "a.txt"), "a\n");
    writeFileSync(join(repo, "b.txt"), "b\n");
    const sha = await commitEdit(repo, {
      files: [
        { path: "a.txt", content: "a\n" },
        { path: "b.txt", content: "b\n" },
      ],
      message: "two files",
    });
    const tree = git(`ls-tree -r ${sha}`);
    expect(tree).toContain("a.txt");
    expect(tree).toContain("b.txt");
  });
});

describe("currentHistoryHead", () => {
  it("returns null when the branch does not exist", async () => {
    const head = await currentHistoryHead(repo);
    expect(head).toBeNull();
  });

  it("returns the SHA after commitEdit creates the branch", async () => {
    writeFileSync(join(repo, "x.txt"), "x\n");
    const sha = await commitEdit(repo, { file: "x.txt", content: "x\n", message: "x" });
    const head = await currentHistoryHead(repo);
    expect(head).toBe(sha);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ../anglesite && npx vitest run test/edit-history.test.js`
Expected: FAIL with "Cannot find module '../server/edit-history.mjs'".

- [ ] **Step 3: Implement `edit-history.mjs`**

Create `../anglesite/server/edit-history.mjs`:

```javascript
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

/**
 * Commit a file (or set of files) to the hidden `anglesite/edits` branch
 * without modifying the working tree or the user-facing index.
 *
 * Plumbing strategy:
 *   git hash-object -w --stdin                 → blob SHA per file
 *   git read-tree --empty                      → clears a private index
 *   git update-index --add --cacheinfo ...     → builds the tree entry
 *   git write-tree                             → tree SHA
 *   git commit-tree <tree> -p <parent>?        → commit SHA
 *   git update-ref refs/heads/anglesite/edits  → branch points at new commit
 *
 * The "private index" is a separate index file (`GIT_INDEX_FILE` env override)
 * so we never touch the user's `.git/index`. We use execFile (not the shell)
 * for all git invocations so user-controlled paths/content can't inject args.
 *
 * @param {string} projectRoot - absolute path to the site's git root
 * @param {{ file?: string, content?: string,
 *           files?: Array<{ path: string, content: string }>,
 *           message: string }} args
 * @returns {Promise<string>} - the new commit SHA
 */
export async function commitEdit(projectRoot, args) {
  const files = args.files ?? [{ path: args.file, content: args.content }];
  if (!files.length || files.some((f) => !f.path || f.content === undefined)) {
    throw new Error("commitEdit: need at least one { path, content } entry");
  }

  // 1. Hash each file's new content into a blob in the object DB.
  const blobs = [];
  for (const { path, content } of files) {
    const { stdout } = await execFileP("git", ["hash-object", "-w", "--stdin"], {
      cwd: projectRoot,
      input: content,
    });
    blobs.push({ path, sha: stdout.trim() });
  }

  // 2. Build a tree on a private index file. Seed from current anglesite/edits
  //    if it exists (so we preserve untouched paths from prior edits); otherwise
  //    start from HEAD's tree (the actual source files baseline).
  const indexFile = `${projectRoot}/.git/anglesite-edits.idx`;
  const env = { ...process.env, GIT_INDEX_FILE: indexFile };

  const parent = await currentHistoryHead(projectRoot);
  let seedTree;
  if (parent) {
    seedTree = `${parent}^{tree}`;
  } else {
    const r = await execFileP("git", ["rev-parse", "HEAD^{tree}"], { cwd: projectRoot });
    seedTree = r.stdout.trim();
  }
  await execFileP("git", ["read-tree", seedTree], { cwd: projectRoot, env });

  // 3. Add each blob to the private index.
  for (const blob of blobs) {
    await execFileP(
      "git",
      ["update-index", "--add", "--cacheinfo", `100644,${blob.sha},${blob.path}`],
      { cwd: projectRoot, env },
    );
  }

  // 4. Write the tree.
  const { stdout: treeOut } = await execFileP("git", ["write-tree"], {
    cwd: projectRoot,
    env,
  });
  const tree = treeOut.trim();

  // 5. Commit-tree (no working-tree touch). Use an explicit author so the
  //    commit is deterministic regardless of repo config.
  const commitArgs = ["commit-tree", tree, "-m", args.message];
  if (parent) commitArgs.push("-p", parent);
  const commitEnv = {
    ...process.env,
    GIT_AUTHOR_NAME: "Anglesite",
    GIT_AUTHOR_EMAIL: "edits@anglesite.local",
    GIT_COMMITTER_NAME: "Anglesite",
    GIT_COMMITTER_EMAIL: "edits@anglesite.local",
  };
  const { stdout: commitOut } = await execFileP("git", commitArgs, {
    cwd: projectRoot,
    env: commitEnv,
  });
  const sha = commitOut.trim();

  // 6. Update the hidden branch ref.
  await execFileP("git", ["update-ref", "refs/heads/anglesite/edits", sha], {
    cwd: projectRoot,
  });

  // 7. Clean up the private index file.
  await execFileP("rm", ["-f", indexFile]);

  return sha;
}

/**
 * Return the current head SHA of the hidden anglesite/edits branch, or null
 * if the branch hasn't been created yet.
 *
 * @param {string} projectRoot
 * @returns {Promise<string | null>}
 */
export async function currentHistoryHead(projectRoot) {
  try {
    const { stdout } = await execFileP(
      "git",
      ["rev-parse", "refs/heads/anglesite/edits"],
      { cwd: projectRoot },
    );
    return stdout.trim();
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ../anglesite && npx vitest run test/edit-history.test.js`
Expected: all 6 edit-history tests pass.

- [ ] **Step 5: Commit**

```bash
cd ../anglesite
git add server/edit-history.mjs test/edit-history.test.js
git commit -m "feat(server): edit-history.mjs — commit edits to hidden anglesite/edits branch (#298)

Phase 5 step 4 — git plumbing that commits a file's new content to
refs/heads/anglesite/edits without touching the working tree or the
user-facing .git/index. Uses hash-object → write-tree on a private
GIT_INDEX_FILE → commit-tree → update-ref via execFile (no shell).

commitEdit({ file, content, message }) returns the new SHA;
currentHistoryHead() returns the branch's current SHA or null.

Closes the long-running gap where Anglesite-app#298 was marked closed
but the code never merged. Apply-edit dispatcher (next commit) calls
this on every successful patch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 (plugin): messages.mjs additions

`createEditAppliedMessage` gains an optional `result` parameter; `EDIT_FAILED_REASONS` gains `"image-optimize-failed"`.

**Files:**
- Modify: `../anglesite/server/messages.mjs`

- [ ] **Step 1: Modify `messages.mjs`**

In `../anglesite/server/messages.mjs`, find:

```javascript
export const EDIT_FAILED_REASONS = Object.freeze([
  "no-match",
  "ambiguous",
  "dynamic-expression",
  "patch-conflict",
  "write-failed",
  "not-implemented",
]);
```

Change to:

```javascript
export const EDIT_FAILED_REASONS = Object.freeze([
  "no-match",
  "ambiguous",
  "dynamic-expression",
  "patch-conflict",
  "write-failed",
  "not-implemented",
  "image-optimize-failed",
]);
```

In the same file, find:

```javascript
export function createEditAppliedMessage(id, file, range, commit) {
  return { type: MESSAGE_TYPES.EDIT_APPLIED, id, file, range, commit };
}
```

Change to:

```javascript
/** Build an edit-applied response (server → client). `range` is `{start, end}` byte offsets in
 *  `file`; `commit` is the SHA on the hidden `anglesite/edits` branch (#298). `result` is
 *  optional, op-scoped metadata: e.g. `replace-image-src` returns `{ src, srcset? }` so the
 *  overlay can apply both attributes without re-deriving them from the patch text. */
export function createEditAppliedMessage(id, file, range, commit, result) {
  const msg = { type: MESSAGE_TYPES.EDIT_APPLIED, id, file, range, commit };
  if (result !== undefined) msg.result = result;
  return msg;
}
```

- [ ] **Step 2: Commit**

```bash
cd ../anglesite
git add server/messages.mjs
git commit -m "feat(server): add image-optimize-failed reason + optional result field

EDIT_FAILED_REASONS gains \"image-optimize-failed\" for sharp / I/O
errors during the image-drop optimize step.

createEditAppliedMessage gains an optional \`result\` parameter — op-scoped
metadata that the overlay can apply directly. For replace-image-src
this carries { src, srcset? } so the overlay swaps both attributes
without re-deriving them from the patched source text.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 (plugin): apply-edit-dispatcher.mjs + tests

The dispatcher is the glue: receives the validated `apply_edit` message → calls `patcher.resolve` → if resolved, writes the patch to disk and calls `editHistory.commitEdit` → returns the MCP tool content. This task wires only the **non-image** ops (`replace-text`, `replace-attr`). Image preprocessing lands in Task 7.

**Files:**
- Create: `../anglesite/server/apply-edit-dispatcher.mjs`
- Create: `../anglesite/test/apply-edit-dispatcher.test.js`

- [ ] **Step 1: Write the failing tests**

Create `../anglesite/test/apply-edit-dispatcher.test.js`:

```javascript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { dispatch } from "../server/apply-edit-dispatcher.mjs";

let repo;

function git(args) {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8" }).trim();
}

function setupAstroFixture() {
  mkdirSync(join(repo, "src/pages"), { recursive: true });
  writeFileSync(
    join(repo, "src/pages/about.astro"),
    `---
const title = "About";
---
<p>Welcome to our site!</p>
`,
  );
  git("add .");
  git('commit -q -m "fixture"');
}

beforeEach(() => {
  repo = mkdtempSync(join(tmpdir(), "anglesite-dispatcher-"));
  git("init -q -b main");
  git("config user.email test@example.com");
  git("config user.name Test");
});

afterEach(() => {
  rmSync(repo, { recursive: true, force: true });
});

describe("dispatch", () => {
  it("applies a replace-text edit and returns edit-applied with the commit SHA", async () => {
    setupAstroFixture();
    const result = await dispatch(repo, {
      id: "e-1",
      path: "/about/",
      selector: { tag: "P", classes: [], nthChild: 1, textContent: "Welcome to our site!" },
      op: "replace-text",
      value: "Welcome to our redesigned site!",
    });

    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(1);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.type).toBe("anglesite:edit-applied");
    expect(reply.id).toBe("e-1");
    expect(reply.file).toBe("src/pages/about.astro");
    expect(reply.commit).toMatch(/^[0-9a-f]{40}$/);

    const src = readFileSync(join(repo, "src/pages/about.astro"), "utf-8");
    expect(src).toContain("Welcome to our redesigned site!");
    expect(src).not.toContain("Welcome to our site!");

    const showOut = execSync(
      `git show ${reply.commit}:src/pages/about.astro`,
      { cwd: repo, encoding: "utf-8" },
    );
    expect(showOut).toContain("Welcome to our redesigned site!");
  });

  it("returns edit-failed when the patcher refuses", async () => {
    setupAstroFixture();
    const result = await dispatch(repo, {
      id: "e-2",
      path: "/about/",
      selector: { tag: "P", classes: [], nthChild: 1, textContent: "This text does not exist" },
      op: "replace-text",
      value: "anything",
    });

    expect(result.isError).toBe(true);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.type).toBe("anglesite:edit-failed");
    expect(reply.id).toBe("e-2");
    expect(reply.reason).toBe("no-match");
  });

  it("returns write-failed when the source file can't be written", async () => {
    setupAstroFixture();
    execSync(`chmod 0444 src/pages/about.astro`, { cwd: repo });
    const result = await dispatch(repo, {
      id: "e-3",
      path: "/about/",
      selector: { tag: "P", classes: [], nthChild: 1, textContent: "Welcome to our site!" },
      op: "replace-text",
      value: "anything",
    });

    expect(result.isError).toBe(true);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.reason).toBe("write-failed");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ../anglesite && npx vitest run test/apply-edit-dispatcher.test.js`
Expected: FAIL with "Cannot find module '../server/apply-edit-dispatcher.mjs'".

- [ ] **Step 3: Implement the dispatcher**

Create `../anglesite/server/apply-edit-dispatcher.mjs`:

```javascript
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolve as resolvePatch } from "./patcher.mjs";
import { commitEdit } from "./edit-history.mjs";
import { createEditAppliedMessage, createEditFailedMessage } from "./messages.mjs";

/**
 * Dispatch a validated apply_edit message: resolve the patch via patcher,
 * apply it on disk, commit to the hidden anglesite/edits branch, and return
 * the MCP tool's `{ content, isError? }` shape.
 *
 * Image preprocessing (replace-image-src) lives in `processImageDrop` —
 * dispatch() routes there before calling `resolvePatch` (added in Task 7).
 *
 * @param {string} projectRoot
 * @param {{ id: string, path: string, selector: object, op: string, value?: unknown }} message
 */
export async function dispatch(projectRoot, message) {
  // Resolve the source-file patch.
  const patch = resolvePatch(projectRoot, {
    path: message.path,
    selector: message.selector,
    op: message.op,
    value: message.value,
  });

  if (patch.refused) {
    return failedReply(message.id, patch.reason, patch.detail);
  }

  // Apply the patch on disk.
  let newContent;
  try {
    const absFile = join(projectRoot, patch.file);
    const original = readFileSync(absFile, "utf-8");
    newContent =
      original.slice(0, patch.range.start) +
      patch.replacement +
      original.slice(patch.range.end);
    writeFileSync(absFile, newContent);
  } catch (err) {
    return failedReply(message.id, "write-failed", String(err.message || err));
  }

  // Commit to anglesite/edits.
  let sha;
  try {
    sha = await commitEdit(projectRoot, {
      file: patch.file,
      content: newContent,
      message: `${message.op} ${patch.file}`,
    });
  } catch (err) {
    return failedReply(message.id, "write-failed", `history commit failed: ${err.message || err}`);
  }

  return appliedReply(message.id, patch.file, patch.range, sha);
}

function appliedReply(id, file, range, commit, result) {
  const msg = createEditAppliedMessage(id, file, range, commit, result);
  return { content: [{ type: "text", text: JSON.stringify(msg) }] };
}

function failedReply(id, reason, detail) {
  const msg = createEditFailedMessage(id, reason, detail);
  return {
    content: [{ type: "text", text: JSON.stringify(msg) }],
    isError: true,
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ../anglesite && npx vitest run test/apply-edit-dispatcher.test.js`
Expected: all 3 dispatcher tests pass.

- [ ] **Step 5: Commit**

```bash
cd ../anglesite
git add server/apply-edit-dispatcher.mjs test/apply-edit-dispatcher.test.js
git commit -m "feat(server): apply-edit dispatcher — patcher + disk write + history commit (#297)

Phase 5 step 3 — wires patcher.resolve, the source-file write, and the
hidden-branch commit (edit-history.mjs) into a single dispatch entry
point. Image preprocessing for replace-image-src lands in a follow-up
commit; this one wires the text/attr path that the WKWebView overlay
already exercises.

Returns the MCP tool's { content, isError? } shape directly. Refusals
land as edit-failed with the patcher's reason; disk write failures and
history commit failures both map to write-failed.

Closes the long-running gap where Anglesite-app#297 was marked closed
but the code never merged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 (plugin): wire dispatcher into server/index.mjs

Replace the apply_edit stub handler with `dispatch(...)`.

**Files:**
- Modify: `../anglesite/server/index.mjs`

- [ ] **Step 1: Locate the stub handler**

Open `../anglesite/server/index.mjs`. Find the block around line 75–91 that registers `apply_edit` with the `not-implemented` stub. It looks like:

```javascript
server.tool(
  "apply_edit",
  "Apply an edit ...",
  applyEditInputShape,
  ({ id }) => {
    return {
      content: [
        createEditFailedContent(id, "not-implemented", "Phase 5 patcher ... hasn't landed yet — schema-only stub."),
      ],
      isError: true,
    };
  },
);
```

- [ ] **Step 2: Replace the stub**

At the top of `server/index.mjs`, alongside other imports, add:

```javascript
import { dispatch as dispatchEdit } from "./apply-edit-dispatcher.mjs";
```

Replace the `server.tool("apply_edit", ...)` block with:

```javascript
server.tool(
  "apply_edit",
  "Apply an edit to the underlying source for a previewed page element. The selector is the structured ElementInfo payload built by the WKWebView overlay; the server resolves it via selector.mjs and patches the matching source file. Successful patches commit to the hidden anglesite/edits branch.",
  applyEditInputShape,
  async (message) => {
    return await dispatchEdit(projectRoot, message);
  },
);
```

(`projectRoot` is already in scope in `server/index.mjs` — confirm by reading the top of the file before edits. If `projectRoot` is named differently in the local scope, use whatever variable holds the site directory.)

Also remove the no-longer-needed import of `createEditFailedContent` if it was only used by the stub — leave it if other handlers still use it.

- [ ] **Step 3: Verify the server still starts**

Run: `cd ../anglesite && node --check server/index.mjs`
Expected: no output (success).

- [ ] **Step 4: Commit**

```bash
cd ../anglesite
git add server/index.mjs
git commit -m "feat(server): wire apply_edit MCP tool to the dispatcher (#297)

The apply_edit handler delegates to apply-edit-dispatcher.dispatch().
Removes the \"Phase 5 patcher ... hasn't landed yet\" stub that has been
shipping in every release since Phase 5 nominally closed.

End-to-end: WKWebView overlay → MCPApplyEditRouter → apply_edit MCP
tool → dispatch() → patcher.resolve → writeFileSync → commitEdit →
edit-applied. Text edits from the overlay now actually patch source
files for the first time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5 (plugin): hoist optimize-images core into server/

`template/scripts/optimize-images.ts` becomes a thin CLI wrapper; the actual sharp/EXIF logic moves to `server/optimize-images.mjs` so the dispatcher can `import` it directly.

**Files:**
- Create: `../anglesite/server/optimize-images.mjs`
- Create: `../anglesite/test/optimize-images.test.js`
- Modify: `../anglesite/template/scripts/optimize-images.ts`

- [ ] **Step 1: Write the failing tests**

Create `../anglesite/test/optimize-images.test.js`:

```javascript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import sharp from "sharp";
import { optimizeImage } from "../server/optimize-images.mjs";

let dir;

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "anglesite-optimize-"));
  await sharp({ create: { width: 2400, height: 1600, channels: 3, background: { r: 255, g: 0, b: 0 } } })
    .withMetadata({ exif: { IFD0: { Make: "Anglesite Test" } } })
    .jpeg()
    .toFile(join(dir, "photo.jpg"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("optimizeImage", () => {
  it("emits a WebP primary at the largest width and width-suffixed variants", async () => {
    const result = await optimizeImage(join(dir, "photo.jpg"), {
      outputDir: dir,
      widths: [480, 768, 1024, 1920],
    });

    expect(result.primary).toBe("photo.webp");
    expect(result.variants).toHaveLength(4);
    expect(result.variants.map((v) => v.width)).toEqual([480, 768, 1024, 1920]);
    expect(result.variants.map((v) => v.file)).toEqual([
      "photo-480w.webp",
      "photo-768w.webp",
      "photo-1024w.webp",
      "photo-1920w.webp",
    ]);

    for (const v of result.variants) {
      expect(existsSync(join(dir, v.file))).toBe(true);
    }
    expect(existsSync(join(dir, result.primary))).toBe(true);
  });

  it("strips EXIF metadata from the output", async () => {
    const result = await optimizeImage(join(dir, "photo.jpg"), {
      outputDir: dir,
      widths: [480],
    });
    const meta = await sharp(join(dir, result.primary)).metadata();
    expect(meta.exif).toBeUndefined();
  });

  it("preserves the original under originals/ before overwriting", async () => {
    const result = await optimizeImage(join(dir, "photo.jpg"), {
      outputDir: dir,
      widths: [480],
      preserveOriginalsDir: join(dir, "originals"),
    });
    expect(existsSync(join(dir, "originals", "photo.jpg"))).toBe(true);
  });

  it("does not upscale: if input is narrower than a requested width, that variant is skipped", async () => {
    await sharp({ create: { width: 600, height: 400, channels: 3, background: { r: 0, g: 255, b: 0 } } })
      .jpeg()
      .toFile(join(dir, "small.jpg"));

    const result = await optimizeImage(join(dir, "small.jpg"), {
      outputDir: dir,
      widths: [480, 768, 1024, 1920],
    });
    expect(result.variants.map((v) => v.width)).toEqual([480]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ../anglesite && npx vitest run test/optimize-images.test.js`
Expected: FAIL with "Cannot find module '../server/optimize-images.mjs'".

- [ ] **Step 3: Implement `server/optimize-images.mjs`**

Create `../anglesite/server/optimize-images.mjs`:

```javascript
import { mkdirSync, copyFileSync, existsSync } from "node:fs";
import { join, basename, extname } from "node:path";
import sharp from "sharp";

/**
 * Optimize a single image: write a primary WebP plus responsive variants,
 * stripping EXIF metadata. Idempotent on re-run.
 *
 * @param {string} inputFile - absolute path to a source image (.jpg/.png/.heic/etc)
 * @param {{
 *   outputDir: string,
 *   widths?: number[],
 *   preserveOriginalsDir?: string,
 * }} options
 * @returns {Promise<{
 *   primary: string,
 *   variants: Array<{ width: number, file: string, bytes: number }>,
 * }>}
 */
export async function optimizeImage(inputFile, options) {
  const widths = options.widths ?? [480, 768, 1024, 1920];
  const outputDir = options.outputDir;
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  const stem = basename(inputFile, extname(inputFile));

  if (options.preserveOriginalsDir) {
    if (!existsSync(options.preserveOriginalsDir)) {
      mkdirSync(options.preserveOriginalsDir, { recursive: true });
    }
    copyFileSync(inputFile, join(options.preserveOriginalsDir, basename(inputFile)));
  }

  const meta = await sharp(inputFile).metadata();
  const inputWidth = meta.width ?? 0;
  const usableWidths = widths.filter((w) => w <= inputWidth).sort((a, b) => a - b);
  if (usableWidths.length === 0) {
    usableWidths.push(Math.min(widths[0] ?? inputWidth, inputWidth));
  }

  const variants = [];
  for (const width of usableWidths) {
    const file = `${stem}-${width}w.webp`;
    const out = join(outputDir, file);
    await sharp(inputFile)
      .rotate()
      .resize({ width, withoutEnlargement: true })
      .webp({ quality: 80 })
      .toFile(out);
    const stats = await sharp(out).metadata();
    variants.push({ width, file, bytes: stats.size ?? 0 });
  }

  const primaryWidth = usableWidths[usableWidths.length - 1];
  const primary = `${stem}.webp`;
  await sharp(inputFile)
    .rotate()
    .resize({ width: primaryWidth, withoutEnlargement: true })
    .webp({ quality: 80 })
    .toFile(join(outputDir, primary));

  return { primary, variants };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ../anglesite && npx vitest run test/optimize-images.test.js`
Expected: all 4 optimize-images tests pass.

- [ ] **Step 5: Thin the template CLI**

Open `../anglesite/template/scripts/optimize-images.ts`. The file currently has the entire optimize implementation (~135 lines of pure functions plus a private `optimizeImage` function). Replace its body with a thin CLI that walks `public/images/` and calls the server-side `optimizeImage` for each:

```typescript
/**
 * CLI wrapper around server/optimize-images.mjs. Walks public/images/,
 * preserves originals in public/images/originals/, and emits responsive
 * WebP variants. Run via `npm run ai-optimize`.
 *
 * The actual sharp pipeline lives in the plugin's server/optimize-images.mjs
 * so the apply-edit dispatcher can reuse it for drop-on-<img> optimization.
 */

import { readdirSync, existsSync } from "node:fs";
import { join, extname, dirname } from "node:path";

const pluginServerOptimize = "@dwk/anglesite/server/optimize-images.mjs";
const { optimizeImage } = await import(pluginServerOptimize);

const IMAGE_EXTENSIONS = new Set([
  ".jpg", ".jpeg", ".png", ".gif", ".tiff", ".tif", ".heif", ".heic",
]);
const SKIP_EXTENSIONS = new Set([".svg", ".webp", ".avif"]);
const SKIP_FILENAMES = new Set([
  "apple-touch-icon.png",
  "og-image.png",
  "favicon.svg",
]);

export function shouldOptimize(filePath: string): boolean {
  const ext = extname(filePath).toLowerCase();
  if (!IMAGE_EXTENSIONS.has(ext)) return false;
  if (SKIP_EXTENSIONS.has(ext)) return false;
  const name = filePath.split("/").pop() ?? "";
  if (SKIP_FILENAMES.has(name)) return false;
  return true;
}

export function getImageFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "originals") continue;
      out.push(...getImageFiles(full));
    } else if (entry.isFile() && shouldOptimize(full)) {
      out.push(full);
    }
  }
  return out;
}

async function main() {
  const cwd = process.cwd();
  const imagesDir = join(cwd, "public/images");
  if (!existsSync(imagesDir)) {
    console.log("No public/images/ — nothing to optimize.");
    return;
  }
  const files = getImageFiles(imagesDir);
  if (files.length === 0) {
    console.log("All images already optimized.");
    return;
  }
  console.log(`Optimizing ${files.length} image(s)…`);
  for (const file of files) {
    const result = await optimizeImage(file, {
      outputDir: dirname(file),
      preserveOriginalsDir: join(imagesDir, "originals"),
    });
    console.log(`  ${file.replace(cwd + "/", "")} → ${result.primary} (+${result.variants.length} variants)`);
  }
  console.log("Done.");
}

const invokedDirectly = process.argv[1]?.endsWith("optimize-images.ts");
if (invokedDirectly) {
  await main();
}
```

- [ ] **Step 6: Commit**

```bash
cd ../anglesite
git add server/optimize-images.mjs test/optimize-images.test.js template/scripts/optimize-images.ts
git commit -m "feat(server): hoist optimize-images core into server/

Phase 9 step 3 prep. The sharp / EXIF / variants pipeline moves from
template/scripts/optimize-images.ts into server/optimize-images.mjs as
an ES-module function: optimizeImage(file, { outputDir, widths,
preserveOriginalsDir }) → { primary, variants }.

The template script keeps the same \`npm run ai-optimize\` entry point
but is now a thin CLI wrapper that walks public/images/ and calls the
server-side function for each file. Single source of truth for the
WebP behavior; the apply-edit dispatcher (next commit) calls the same
function on drop-on-<img>.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6 (plugin): patcher.mjs replace-image-src resolver

The resolver takes `value: { src, srcset }` and rewrites the entire opening `<img>` tag, returning a range that spans from `<` to the matching `>`. Resolver is pure — no side effects, no I/O on images. (The dispatcher does the bytes work in Task 7.)

**Files:**
- Modify: `../anglesite/server/patcher.mjs`
- Modify: `../anglesite/test/patcher.test.js`
- Create: `../anglesite/test/fixtures/patcher/src/pages/photo.astro` (test fixture)

- [ ] **Step 1: Add the fixture file**

Create `../anglesite/test/fixtures/patcher/src/pages/photo.astro`:

```astro
---
const title = "Photo";
---
<p>Before image.</p>
<img src="/images/hero.jpg" srcset="/images/hero-480w.jpg 480w, /images/hero-768w.jpg 768w" alt="Hero" />
<img src="/images/loose.jpg" alt="No srcset" />
<p>After image.</p>
```

- [ ] **Step 2: Write the failing tests**

In `../anglesite/test/patcher.test.js`, find the `describe("astro resolver", …)` block and add inside it:

```javascript
describe("replace-image-src", () => {
  it("rewrites the entire <img> opening tag with new src + srcset", () => {
    const result = resolve(FIXTURE_ROOT, {
      path: "/photo/",
      selector: { tag: "IMG", classes: [], nthChild: 1, textContent: "/images/hero.jpg" },
      op: "replace-image-src",
      value: {
        src: "/images/hero.webp",
        srcset: "/images/hero-480w.webp 480w, /images/hero-768w.webp 768w, /images/hero-1024w.webp 1024w, /images/hero-1920w.webp 1920w",
      },
    });
    expect(result.refused).toBeUndefined();
    expect(result.file).toBe("src/pages/photo.astro");
    expect(result.replacement).toMatch(/^<img/);
    expect(result.replacement).toContain('src="/images/hero.webp"');
    expect(result.replacement).toContain('srcset="/images/hero-480w.webp 480w');
    expect(result.replacement).toContain('alt="Hero"');
    const src = readFileSync(resolvePath(FIXTURE_ROOT, result.file), "utf-8");
    const matched = src.slice(result.range.start, result.range.end);
    expect(matched.startsWith("<img")).toBe(true);
    expect(matched.endsWith("/>") || matched.endsWith(">")).toBe(true);
  });

  it("adds srcset when the original <img> had none", () => {
    const result = resolve(FIXTURE_ROOT, {
      path: "/photo/",
      selector: { tag: "IMG", classes: [], nthChild: 2, textContent: "/images/loose.jpg" },
      op: "replace-image-src",
      value: {
        src: "/images/loose.webp",
        srcset: "/images/loose-480w.webp 480w, /images/loose-768w.webp 768w",
      },
    });
    expect(result.refused).toBeUndefined();
    expect(result.replacement).toContain('src="/images/loose.webp"');
    expect(result.replacement).toContain('srcset="/images/loose-480w.webp 480w');
    expect(result.replacement).toContain('alt="No srcset"');
  });

  it("refuses with no-match when no <img> with the current src is found", () => {
    const result = resolve(FIXTURE_ROOT, {
      path: "/photo/",
      selector: { tag: "IMG", classes: [], nthChild: 1, textContent: "/images/missing.jpg" },
      op: "replace-image-src",
      value: { src: "/images/whatever.webp", srcset: "" },
    });
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ../anglesite && npx vitest run test/patcher.test.js`
Expected: the new `replace-image-src` cases fail.

- [ ] **Step 4: Update `buildReplacement` in `patcher.mjs`**

In `../anglesite/server/patcher.mjs`, find `buildReplacement`:

```javascript
function buildReplacement(op, value, _matchedSource) {
  if (op === "replace-text") {
    return typeof value === "string" ? value : String(value ?? "");
  }
  if (op === "replace-attr" && value && typeof value === "object") {
    return value.value != null ? String(value.value) : "";
  }
  if (op === "replace-image-src" && value && typeof value === "object") {
    return value.filename || "";
  }
  return typeof value === "string" ? value : "";
}
```

Replace it with:

```javascript
function buildReplacement(op, value, matchedSource) {
  if (op === "replace-text") {
    return typeof value === "string" ? value : String(value ?? "");
  }
  if (op === "replace-attr" && value && typeof value === "object") {
    return value.value != null ? String(value.value) : "";
  }
  if (op === "replace-image-src" && value && typeof value === "object") {
    // matchedSource is the entire opening <img …> tag. Rewrite its src and
    // srcset attributes while preserving everything else (alt, width, class,
    // data-*, etc). Existing src/srcset are replaced; missing srcset is added.
    return rewriteImgTag(matchedSource, value.src, value.srcset);
  }
  return typeof value === "string" ? value : "";
}

/**
 * Rewrite the src and srcset attributes inside an <img …> opening tag.
 * Preserves all other attributes. If srcset is absent in the source tag,
 * it's inserted right after src.
 *
 * @param {string} tagSource - e.g. '<img src="/foo.jpg" alt="x" />'
 * @param {string} newSrc
 * @param {string} newSrcset - empty string means "don't emit srcset"
 */
function rewriteImgTag(tagSource, newSrc, newSrcset) {
  let out = tagSource;
  if (/\ssrc=("[^"]*"|'[^']*')/i.test(out)) {
    out = out.replace(/(\ssrc=)("[^"]*"|'[^']*')/i, `$1"${newSrc}"`);
  } else {
    out = out.replace(/(\s*\/?>)$/, ` src="${newSrc}"$1`);
  }
  if (newSrcset) {
    if (/\ssrcset=("[^"]*"|'[^']*')/i.test(out)) {
      out = out.replace(/(\ssrcset=)("[^"]*"|'[^']*')/i, `$1"${newSrcset}"`);
    } else {
      out = out.replace(/(\ssrc="[^"]*")/i, `$1 srcset="${newSrcset}"`);
    }
  }
  return out;
}
```

- [ ] **Step 5: Add the whole-tag finder + special-case in resolveAstro**

In the same file, just above `resolveAstro`, add:

```javascript
/**
 * Given a needle that is a src URL (e.g. "/images/hero.jpg"), find the full
 * <img …> opening tag that contains it. Returns the {start, end} byte range
 * of the entire opening tag plus the matched source — or [] if not found.
 */
function findImgTagBySrc(source, srcNeedle) {
  const tagRe = /<img\b[^>]*\/?>/gi;
  let m;
  const matches = [];
  while ((m = tagRe.exec(source)) !== null) {
    if (m[0].includes(`src="${srcNeedle}"`) || m[0].includes(`src='${srcNeedle}'`)) {
      matches.push({ start: m.index, end: m.index + m[0].length, source: m[0] });
    }
  }
  return matches;
}
```

In `resolveAstro`, immediately after the early-return for `candidates.length === 0` and BEFORE the existing `const textContent = selector.textContent` line, add:

```javascript
  if (op === "replace-image-src") {
    const currentSrc = selector.textContent;
    if (!currentSrc) {
      return refuse("no-match", "no current src to find in .astro files");
    }
    const allTagMatches = [];
    for (const file of candidates) {
      let source;
      try {
        source = readFileSync(file, "utf-8");
      } catch {
        continue;
      }
      const m = findImgTagBySrc(source, currentSrc);
      for (const tag of m) {
        allTagMatches.push({ file: relative(projectRoot, file), tag });
      }
    }
    if (allTagMatches.length === 0) {
      return refuse("no-match", `no <img src="${currentSrc}"> found in .astro files`);
    }
    if (allTagMatches.length > 1) {
      return refuse("ambiguous", `${allTagMatches.length} <img> tags match src="${currentSrc}"`);
    }
    const only = allTagMatches[0];
    return {
      file: only.file,
      range: { start: only.tag.start, end: only.tag.end },
      replacement: buildReplacement(op, value, only.tag.source),
    };
  }
```

(Keep the rest of `resolveAstro` exactly as it is.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ../anglesite && npx vitest run test/patcher.test.js`
Expected: all 3 new tests pass, all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
cd ../anglesite
git add server/patcher.mjs test/patcher.test.js test/fixtures/patcher/src/pages/photo.astro
git commit -m "feat(patcher): replace-image-src resolver — whole-<img>-tag replacement

The resolver for replace-image-src now finds the matching <img> by its
current src attribute and returns a range covering the entire opening
tag. The replacement is the rewritten tag with new src + srcset (or
just src when srcset is empty), preserving alt / width / class / etc.

The resolver stays pure: it consumes value: { src, srcset } as
pre-computed strings. The dispatcher (next commit) decodes the
dataURL, writes the bytes, runs optimize, and feeds the resulting
paths into the resolver.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7 (plugin): dispatcher image-drop preprocessing

The dispatcher gains a `replace-image-src` branch that decodes the dataURL, writes bytes to `public/images/`, runs `optimizeImage`, builds the srcset string, and invokes the resolver with the computed `{ src, srcset }` payload. On success it returns `edit-applied` with `result: { src, srcset }`.

**Files:**
- Modify: `../anglesite/server/apply-edit-dispatcher.mjs`
- Modify: `../anglesite/test/apply-edit-dispatcher.test.js`

- [ ] **Step 1: Write the failing tests**

At the top of `../anglesite/test/apply-edit-dispatcher.test.js`, add the sharp import:

```javascript
import sharp from "sharp";
```

Inside `describe("dispatch", …)`, add a new nested describe at the bottom (before the outer block closes):

```javascript
describe("replace-image-src", () => {
  it("writes bytes, optimizes, patches <img>, and returns result.src+srcset", async () => {
    mkdirSync(join(repo, "src/pages"), { recursive: true });
    mkdirSync(join(repo, "public/images"), { recursive: true });
    writeFileSync(
      join(repo, "src/pages/about.astro"),
      `<img src="/images/hero.jpg" alt="Hero" />`,
    );
    await sharp({ create: { width: 100, height: 100, channels: 3, background: { r: 0, g: 0, b: 255 } } })
      .jpeg()
      .toFile(join(repo, "public/images/hero.jpg"));
    git("add .");
    git('commit -q -m "fixture"');

    const dropped = await sharp({ create: { width: 2000, height: 1500, channels: 3, background: { r: 255, g: 128, b: 0 } } })
      .jpeg()
      .toBuffer();
    const dataURL = `data:image/jpeg;base64,${dropped.toString("base64")}`;

    const result = await dispatch(repo, {
      id: "e-img-1",
      path: "/about/",
      selector: { tag: "IMG", classes: [], nthChild: 1, textContent: "/images/hero.jpg" },
      op: "replace-image-src",
      value: { filename: "vacation.jpg", mimeType: "image/jpeg", dataURL },
    });

    expect(result.isError).toBeUndefined();
    const reply = JSON.parse(result.content[0].text);
    expect(reply.type).toBe("anglesite:edit-applied");
    expect(reply.result.src).toBe("/images/hero.webp");
    expect(reply.result.srcset).toContain("/images/hero-480w.webp 480w");
    expect(reply.result.srcset).toContain("/images/hero-1024w.webp 1024w");

    const astro = readFileSync(join(repo, "src/pages/about.astro"), "utf-8");
    expect(astro).toContain('src="/images/hero.webp"');
    expect(astro).toContain('srcset="/images/hero-480w.webp');

    expect(existsSync(join(repo, "public/images/hero.webp"))).toBe(true);
    expect(existsSync(join(repo, "public/images/hero-480w.webp"))).toBe(true);
    expect(existsSync(join(repo, "public/images/originals/hero.jpg"))).toBe(true);
  });

  it("falls back to dropped filename when target src is external", async () => {
    mkdirSync(join(repo, "src/pages"), { recursive: true });
    mkdirSync(join(repo, "public/images"), { recursive: true });
    writeFileSync(
      join(repo, "src/pages/about.astro"),
      `<img src="https://cdn.example.com/photo.jpg" alt="External" />`,
    );
    git("add .");
    git('commit -q -m "fixture"');

    const dropped = await sharp({ create: { width: 1500, height: 1000, channels: 3, background: { r: 0, g: 200, b: 50 } } })
      .jpeg()
      .toBuffer();
    const dataURL = `data:image/jpeg;base64,${dropped.toString("base64")}`;

    const result = await dispatch(repo, {
      id: "e-img-ext",
      path: "/about/",
      selector: { tag: "IMG", classes: [], nthChild: 1, textContent: "https://cdn.example.com/photo.jpg" },
      op: "replace-image-src",
      value: { filename: "trip-sunset.jpg", mimeType: "image/jpeg", dataURL },
    });

    expect(result.isError).toBeUndefined();
    const reply = JSON.parse(result.content[0].text);
    expect(reply.result.src).toBe("/images/trip-sunset.webp");
  });

  it("returns image-optimize-failed when the dataURL bytes are corrupt", async () => {
    mkdirSync(join(repo, "src/pages"), { recursive: true });
    mkdirSync(join(repo, "public/images"), { recursive: true });
    writeFileSync(join(repo, "src/pages/about.astro"), `<img src="/images/hero.jpg" />`);
    git("add .");
    git('commit -q -m "fixture"');

    const result = await dispatch(repo, {
      id: "e-img-bad",
      path: "/about/",
      selector: { tag: "IMG", classes: [], nthChild: 1, textContent: "/images/hero.jpg" },
      op: "replace-image-src",
      value: {
        filename: "broken.jpg",
        mimeType: "image/jpeg",
        dataURL: "data:image/jpeg;base64,bm90LWFuLWltYWdl",
      },
    });

    expect(result.isError).toBe(true);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.reason).toBe("image-optimize-failed");
  });
});
```

Also ensure the test file imports `existsSync` from node:fs at the top.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ../anglesite && npx vitest run test/apply-edit-dispatcher.test.js`
Expected: 3 new replace-image-src tests fail.

- [ ] **Step 3: Update the dispatcher**

Replace `../anglesite/server/apply-edit-dispatcher.mjs` entirely with:

```javascript
import { readFileSync, writeFileSync, mkdirSync, renameSync, existsSync, readdirSync } from "node:fs";
import { join, basename, extname } from "node:path";
import { Buffer } from "node:buffer";
import { resolve as resolvePatch } from "./patcher.mjs";
import { commitEdit } from "./edit-history.mjs";
import { optimizeImage } from "./optimize-images.mjs";
import { createEditAppliedMessage, createEditFailedMessage } from "./messages.mjs";

export async function dispatch(projectRoot, message) {
  let preprocessed = message;
  let imageResult = null;

  if (message.op === "replace-image-src") {
    try {
      imageResult = await processImageDrop(projectRoot, message);
    } catch (err) {
      return failedReply(message.id, "image-optimize-failed", String(err.message || err));
    }
    preprocessed = {
      ...message,
      value: { src: imageResult.src, srcset: imageResult.srcset },
    };
  }

  const patch = resolvePatch(projectRoot, {
    path: preprocessed.path,
    selector: preprocessed.selector,
    op: preprocessed.op,
    value: preprocessed.value,
  });

  if (patch.refused) {
    return failedReply(message.id, patch.reason, patch.detail);
  }

  let newContent;
  try {
    const absFile = join(projectRoot, patch.file);
    const original = readFileSync(absFile, "utf-8");
    newContent =
      original.slice(0, patch.range.start) +
      patch.replacement +
      original.slice(patch.range.end);
    writeFileSync(absFile, newContent);
  } catch (err) {
    return failedReply(message.id, "write-failed", String(err.message || err));
  }

  let sha;
  try {
    sha = await commitEdit(projectRoot, {
      file: patch.file,
      content: newContent,
      message: `${message.op} ${patch.file}`,
    });
  } catch (err) {
    return failedReply(message.id, "write-failed", `history commit failed: ${err.message || err}`);
  }

  const result = imageResult
    ? { src: imageResult.src, srcset: imageResult.srcset }
    : undefined;
  return appliedReply(message.id, patch.file, patch.range, sha, result);
}

/**
 * Decode the dropped image's data URL, write it to public/images/<basename>.<ext>,
 * move any pre-existing same-stem files to public/images/originals/, then run
 * optimizeImage and build the srcset string from the variants.
 *
 * Basename: stem of the target <img>'s current src (e.g. /images/hero.jpg → "hero").
 * Falls back to the dropped filename's stem when the target src is external
 * (http(s)://…) or otherwise can't be parsed to a /images/ path.
 *
 * @returns {Promise<{ src: string, srcset: string }>}
 */
async function processImageDrop(projectRoot, message) {
  const { selector, value } = message;
  if (!value || typeof value !== "object" || !value.dataURL) {
    throw new Error("image drop missing dataURL");
  }

  const currentSrc = selector.textContent ?? "";
  let stem;
  const localMatch = currentSrc.match(/\/images\/([^/?#]+?)(?:\.[a-z0-9]+)?$/i);
  if (localMatch) {
    stem = localMatch[1];
  } else {
    stem = basename(value.filename, extname(value.filename));
  }

  const imagesDir = join(projectRoot, "public/images");
  const originalsDir = join(imagesDir, "originals");
  mkdirSync(imagesDir, { recursive: true });

  if (existsSync(imagesDir)) {
    mkdirSync(originalsDir, { recursive: true });
    for (const entry of readdirSync(imagesDir)) {
      if (entry === "originals") continue;
      const re = new RegExp(`^${escapeRegex(stem)}(-\\d+w)?\\.[a-z0-9]+$`, "i");
      if (re.test(entry)) {
        try {
          renameSync(join(imagesDir, entry), join(originalsDir, entry));
        } catch {
          // best-effort
        }
      }
    }
  }

  const m = value.dataURL.match(/^data:([^;]+);base64,(.+)$/);
  if (!m) throw new Error("dataURL is not base64-encoded");
  const ext = extname(value.filename) || mimeToExt(m[1]);
  if (!ext) throw new Error(`can't infer extension from mimeType ${m[1]} / filename ${value.filename}`);
  const bytes = Buffer.from(m[2], "base64");
  const droppedPath = join(imagesDir, `${stem}${ext}`);
  writeFileSync(droppedPath, bytes);

  const optimized = await optimizeImage(droppedPath, {
    outputDir: imagesDir,
    widths: [480, 768, 1024, 1920],
    preserveOriginalsDir: originalsDir,
  });

  const src = `/images/${optimized.primary}`;
  const srcset = optimized.variants
    .map((v) => `/images/${v.file} ${v.width}w`)
    .join(", ");
  return { src, srcset };
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function mimeToExt(mime) {
  return {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/heic": ".heic",
    "image/heif": ".heif",
    "image/tiff": ".tiff",
    "image/webp": ".webp",
  }[mime];
}

function appliedReply(id, file, range, commit, result) {
  const msg = createEditAppliedMessage(id, file, range, commit, result);
  return { content: [{ type: "text", text: JSON.stringify(msg) }] };
}

function failedReply(id, reason, detail) {
  const msg = createEditFailedMessage(id, reason, detail);
  return {
    content: [{ type: "text", text: JSON.stringify(msg) }],
    isError: true,
  };
}
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `cd ../anglesite && npx vitest run`
Expected: all tests pass (existing + new dispatcher image-drop tests).

- [ ] **Step 5: Commit**

```bash
cd ../anglesite
git add server/apply-edit-dispatcher.mjs test/apply-edit-dispatcher.test.js
git commit -m "feat(server): dispatcher handles replace-image-src end-to-end

For replace-image-src messages, the dispatcher now:
1. Derives a basename from the target <img>'s current src (stem of the
   /images/<name>.<ext> path), falling back to the dropped filename's
   stem when src is external.
2. Moves pre-existing <stem>.* files (raw + .webp + width variants) to
   public/images/originals/.
3. Decodes the dataURL → bytes → public/images/<stem>.<ext>.
4. Runs optimizeImage from server/optimize-images.mjs (sharp +
   EXIF strip + variants at 480/768/1024/1920).
5. Hands the patcher a { src, srcset } value computed from the optimize
   result.
6. Returns edit-applied with result: { src, srcset } so the overlay
   can apply both attributes without re-deriving them.

Decode failures, sharp errors, and corrupt dataURLs map to the new
image-optimize-failed reason.

Closes Anglesite-app#32.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8 (app): EditReply.result + overlay drop rewrite + toast + timeout

This task spans the overlay's TypeScript surface, the drop handler rewrite, and a small toast UI. Bundled together because the tests reach across all of these files.

**Files:**
- Modify: `JS/edit-overlay/src/messages.ts`
- Modify: `JS/edit-overlay/src/overlay.ts`
- Create: `JS/edit-overlay/src/toast.ts`
- Modify: `JS/edit-overlay/test/overlay.test.ts`
- Create: `JS/edit-overlay/test/toast.test.ts`

- [ ] **Step 1: Extend `EditReply` in `messages.ts`**

In `JS/edit-overlay/src/messages.ts`, find:

```typescript
export interface EditReply {
  id: string;
  status: "applied" | "failed" | "ambiguous";
  message?: string;
}
```

Change to:

```typescript
export interface EditReply {
  id: string;
  status: "applied" | "failed" | "ambiguous";
  message?: string;
  /** Op-scoped metadata. For `replace-image-src`, carries the final src + optional
   *  srcset the overlay should apply on swap. */
  result?: { src: string; srcset?: string };
  /** Failure detail forwarded from the server (e.g. the sharp error message). */
  detail?: string;
  /** Failure reason forwarded from the server's EDIT_FAILED_REASONS enum. */
  reason?: string;
}
```

- [ ] **Step 2: Write the failing toast tests**

Create `JS/edit-overlay/test/toast.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { showToast, TOAST_CLASS } from "../src/toast.js";

describe("showToast", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
  });

  it("mounts a toast element with the given text", () => {
    showToast("Hello toast");
    const el = document.querySelector(`.${TOAST_CLASS}`);
    expect(el).toBeTruthy();
    expect(el?.textContent).toBe("Hello toast");
  });

  it("auto-dismisses after the default 4 seconds", () => {
    showToast("bye");
    expect(document.querySelector(`.${TOAST_CLASS}`)).toBeTruthy();
    vi.advanceTimersByTime(4000);
    expect(document.querySelector(`.${TOAST_CLASS}`)).toBeNull();
  });

  it("stacks: a second showToast appends another element", () => {
    showToast("one");
    showToast("two");
    expect(document.querySelectorAll(`.${TOAST_CLASS}`).length).toBe(2);
  });
});
```

- [ ] **Step 3: Write the failing overlay drop tests**

In `JS/edit-overlay/test/overlay.test.ts`, add at the bottom:

```typescript
describe("image drop", () => {
  function makeImg(src: string, srcset?: string): HTMLImageElement {
    const img = document.createElement("img");
    img.src = src;
    if (srcset) img.setAttribute("srcset", srcset);
    document.body.appendChild(img);
    return img;
  }

  function dropOn(target: Element, file: File): void {
    const dt = new DataTransfer();
    dt.items.add(file);
    const drop = new DragEvent("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: dt });
    target.dispatchEvent(drop);
  }

  function flushFileReader(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0));
  }

  it("sets img.src to a blob URL immediately on drop", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    expect(img.src.startsWith("blob:")).toBe(true);
  });

  it("posts apply-edit { op: replace-image-src, value: { filename, mimeType, dataURL } } after FileReader resolves", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    expect(sent.length).toBe(1);
    const msg = sent[0] as { op: string; value: { filename: string; mimeType: string; dataURL: string } };
    expect(msg.op).toBe("replace-image-src");
    expect(msg.value.filename).toBe("vacation.jpg");
    expect(msg.value.mimeType).toBe("image/jpeg");
    expect(msg.value.dataURL.startsWith("data:image/jpeg;base64,")).toBe(true);
  });

  it("on edit-applied with result, swaps src/srcset and revokes the blob URL", async () => {
    const img = makeImg("/images/hero.jpg", "old-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    const revokeSpy = vi.spyOn(URL, "revokeObjectURL");
    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "applied", result: { src: "/images/hero.webp", srcset: "new-srcset" },
    });

    expect(img.src.endsWith("/images/hero.webp")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("new-srcset");
    expect(revokeSpy).toHaveBeenCalled();
  });

  it("on edit-failed, restores original src/srcset, revokes blob URL, and shows a toast", async () => {
    const img = makeImg("/images/hero.jpg", "original-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "failed", reason: "image-optimize-failed", detail: "sharp error",
    });

    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("original-srcset");
    expect(document.querySelector(".anglesite-toast")?.textContent).toContain("sharp error");
  });

  it("after 30s with no reply, restores original src/srcset and toasts a timeout", async () => {
    vi.useFakeTimers();
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();

    vi.advanceTimersByTime(30000);
    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/timed out/i);
    vi.useRealTimers();
  });
});
```

(jsdom's DataTransfer/File/FileReader are partial. If the existing test harness stubs them, follow that pattern; if not, jsdom 24+ supports File/FileReader natively.)

- [ ] **Step 4: Run tests to verify they fail**

Run: `npm test --prefix JS/edit-overlay`
Expected: toast tests fail (no module), image-drop tests fail (existing handler doesn't do new behavior).

- [ ] **Step 5: Implement `src/toast.ts`**

Create `JS/edit-overlay/src/toast.ts`:

```typescript
export const TOAST_CLASS = "anglesite-toast";

/**
 * Mount a small bottom-right toast with the given text. Auto-dismisses after
 * `durationMs` (default 4000). Stacks: subsequent toasts appear above earlier
 * ones until they self-remove.
 */
export function showToast(text: string, durationMs = 4000): void {
  ensureStyles();
  const el = document.createElement("div");
  el.className = TOAST_CLASS;
  el.textContent = text;
  const existing = document.querySelectorAll(`.${TOAST_CLASS}`).length;
  el.style.bottom = `${16 + existing * 56}px`;
  document.body.appendChild(el);

  setTimeout(() => {
    el.remove();
  }, durationMs);
}

let stylesInstalled = false;
function ensureStyles(): void {
  if (stylesInstalled) return;
  stylesInstalled = true;
  const style = document.createElement("style");
  style.setAttribute("data-anglesite-toast", "");
  style.textContent = `
.${TOAST_CLASS} {
  position: fixed;
  right: 16px;
  bottom: 16px;
  max-width: 360px;
  padding: 10px 14px;
  background: rgba(20, 20, 24, 0.92);
  color: #fff;
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  z-index: 2147483647;
  pointer-events: none;
}
`;
  document.head.appendChild(style);
}
```

- [ ] **Step 6: Rewrite `attachImageDrop` in `overlay.ts`**

In `JS/edit-overlay/src/overlay.ts`, locate the existing `attachImageDrop()` function (around lines 100–128) and replace it entirely. Also add `import { showToast } from "./toast.js";` at the top alongside other imports.

```typescript
function attachImageDrop(awaitReply: (id: string, handler: (r: EditReply) => void) => void): void {
  document.addEventListener("dragover", (ev) => {
    const target = ev.target as Element | null;
    if (target?.tagName !== "IMG") return;
    ev.preventDefault();
  });
  document.addEventListener("drop", (ev) => {
    const target = ev.target as HTMLImageElement | null;
    if (target?.tagName !== "IMG") return;
    const file = ev.dataTransfer?.files[0];
    if (!file || !file.type.startsWith("image/")) return;
    ev.preventDefault();

    const savedSrc = target.src;
    const savedSrcset = target.getAttribute("srcset");
    const blobURL = URL.createObjectURL(file);
    target.src = blobURL;
    target.removeAttribute("srcset");

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      target.src = savedSrc;
      if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
      else target.removeAttribute("srcset");
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        target.src = reply.result.src;
        if (reply.result.srcset !== undefined) {
          target.setAttribute("srcset", reply.result.srcset);
        } else {
          target.removeAttribute("srcset");
        }
        URL.revokeObjectURL(blobURL);
      } else {
        target.src = savedSrc;
        if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
        else target.removeAttribute("srcset");
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image edit timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: elementInfoFor(target),
        op: "replace-image-src",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  });
}
```

In the `install()` function, change `attachImageDrop();` to `attachImageDrop(awaitReply);`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `npm test --prefix JS/edit-overlay`
Expected: all overlay + toast tests pass.

- [ ] **Step 8: Rebuild the overlay bundle**

Run: `bash scripts/build-overlay.sh`
Expected: `Resources/edit-overlay/overlay.js` is regenerated.

- [ ] **Step 9: Commit**

```bash
git add JS/edit-overlay/src/messages.ts JS/edit-overlay/src/overlay.ts JS/edit-overlay/src/toast.ts \
        JS/edit-overlay/test/overlay.test.ts JS/edit-overlay/test/toast.test.ts \
        Resources/edit-overlay/overlay.js
git commit -m "feat(overlay): optimistic-preview image-drop with revert + toast + timeout

Phase 9 step 3 — the JS overlay side of the image-drop pipeline.

EditReply gains optional result: { src, srcset? }, detail, reason
fields to carry server-side metadata (used by replace-image-src; absent
on other ops).

attachImageDrop is rewritten:
- On drop: saves originals, sets img.src = URL.createObjectURL(file) for
  instant preview, registers awaitReply, kicks off a 30s timeout.
- On edit-applied with result: swaps src/srcset to the optimized paths,
  revokes the blob URL.
- On edit-failed / ambiguous / missing-result / timeout: restores the
  originals, revokes the blob URL, shows a small bottom-right toast.

New src/toast.ts is a tiny CSS-styled affordance — showToast(text)
mounts a 4s-auto-dismiss toast that stacks with siblings.

Tracks Anglesite-app#32.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9 (app): update build-plan.md

Mark Phase 5 steps 3 + 4 as ✅ (they actually shipped now in this paired PR), mark Phase 9 step 3 as ✅, and remove the misleading "#315" / "#316" references.

**Files:**
- Modify: `docs/build-plan.md`

- [ ] **Step 1: Update the Phase 5 entries**

In `docs/build-plan.md`, find the lines (in the Phase 5 section) that read:

```text
3. ✅ `server/index.mjs` dispatch — wires the `apply_edit` MCP tool to the dispatcher. Landed in `#297` → merged via #315.
4. ✅ Hidden git branch undo — `server/edit-history.mjs` commits each successful patch to `anglesite/edits` via git plumbing (no working-tree-dirtying). Landed in `#298` → merged via #316.
```

Replace with:

```text
3. ✅ `server/index.mjs` dispatch — wires the `apply_edit` MCP tool to `server/apply-edit-dispatcher.mjs`, which calls `patcher.resolve`, writes the patch to disk, and commits via `edit-history.commitEdit`. Landed in `#297` (paired with Anglesite-app#32's image-drop PR — the earlier "merged via #315" claim was wrong; the work didn't actually land until the Phase 9 step 3 paired PR).
4. ✅ Hidden git branch undo — `server/edit-history.mjs` commits each successful patch to `refs/heads/anglesite/edits` via git plumbing (`hash-object` → `write-tree` on a private `GIT_INDEX_FILE` → `commit-tree` → `update-ref`). No working-tree or `.git/index` modification. Landed in `#298` (same paired PR as step 3 — earlier "merged via #316" claim was wrong).
```

- [ ] **Step 2: Update the Phase 9 step 3 entry**

In the same file, find:

```text
3. Image drop → call `optimize-images` skill via MCP → write to `public/` → patch `src=`.
```

Replace with:

```text
3. ✅ Image drop pipeline (#32). Dropping an image on an `<img>` in the WKWebView preview triggers the overlay's `attachImageDrop` handler (optimistic blob-URL preview + 30s timeout). The bytes flow via `apply-edit` `replace-image-src` through MCP to the plugin's `apply-edit-dispatcher`, which writes them to `public/images/<basename>.<ext>`, moves pre-existing `<basename>.*` to `public/images/originals/`, runs `optimizeImage` from the hoisted `server/optimize-images.mjs` (sharp + EXIF strip + variants at 480/768/1024/1920), and feeds the new `{ src, srcset }` into the patcher's `replace-image-src` resolver — which rewrites the entire opening `<img>` tag while preserving alt / class / data-* etc. On `edit-applied` the overlay swaps `src`/`srcset` to the optimized paths; on `edit-failed` it restores the originals and toasts the failure detail. Design: [`docs/specs/2026-05-26-image-drop-design.md`](specs/2026-05-26-image-drop-design.md).
```

- [ ] **Step 3: Commit**

```bash
git add docs/build-plan.md
git commit -m "docs: mark phase-5.3/5.4 + phase-9.3 actually-shipped

Phase 5 steps 3 (dispatcher) and 4 (edit-history) were marked ✅ in
this file with \"merged via #315\" / \"merged via #316\" but the code
never landed in the plugin's main branch — the apply_edit MCP tool was
still returning edit-failed: not-implemented up until the paired PR
for Phase 9 step 3. Correct the historical claims and document what
actually shipped.

Phase 9 step 3 (image-drop) is the umbrella PR that finally delivers
all three.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Open the paired PR on Anglesite/anglesite

The plugin's commits from Tasks 1–7 live on a feature branch in the plugin repo. Open a PR pairing with this Anglesite-app change.

- [ ] **Step 1: Push the plugin branch**

```bash
cd ../anglesite
git push -u origin HEAD
```

(Replace `HEAD` with an explicit branch name if not already on a feature branch — e.g. `feat/phase-9-image-drop`.)

- [ ] **Step 2: Open the PR**

```bash
cd ../anglesite
gh pr create --title "feat(server): apply-edit dispatcher + edit-history + image-drop pipeline" --body "Paired PR with Anglesite/Anglesite-app#32. Delivers Phase 9 step 3 (image-drop pipeline) and closes out Phase 5 leftovers (#297 dispatcher, #298 edit-history) that were marked ✅ in Anglesite-app's build plan but never actually merged.

### What's new

- server/edit-history.mjs — git plumbing that commits a file's new content to refs/heads/anglesite/edits without touching the working tree or the user-facing .git/index. (#298)
- server/apply-edit-dispatcher.mjs — receives validated apply_edit messages, calls patcher.resolve, applies the patch on disk, commits via edit-history. Wires the previously stubbed apply_edit MCP tool in server/index.mjs for the first time. (#297)
- server/optimize-images.mjs — sharp + EXIF strip + variants at 480/768/1024/1920, hoisted from template/scripts/optimize-images.ts. The template script becomes a thin CLI wrapper around the new module.
- server/patcher.mjs replace-image-src resolver — finds the matching <img> by current src and returns a range covering the entire opening tag; the replacement is the rewritten tag with new src + srcset (preserves alt, class, data-* etc).
- Dispatcher image preprocessing — for replace-image-src, decodes the dataURL → writes bytes → moves prior <basename>.* files to originals/ → runs optimizeImage → builds the srcset string → hands { src, srcset } to the resolver.
- server/messages.mjs — new image-optimize-failed reason; createEditAppliedMessage gains an optional result field for op-scoped metadata.

Paired-PR design doc: docs/specs/2026-05-26-image-drop-design.md in the app repo.

## Test plan

- npx vitest run — all tests pass (existing patcher tests + new edit-history, apply-edit-dispatcher, optimize-images, replace-image-src patcher tests)
- Manual: launch Anglesite-app's debug build against ~/Sites/anglesite-smoke, drag a JPEG onto an <img> in the preview, observe blob-URL preview → swap to /images/<stem>.webp + srcset → new files in public/images/ → original moved to public/images/originals/ → patched <img> in source → commit on refs/heads/anglesite/edits.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

The PR URL is printed by `gh pr create` — paste it into the Anglesite-app#32 issue as a cross-link comment.

- [ ] **Step 3: Cross-link from Anglesite-app#32**

```bash
gh issue comment 32 --repo Anglesite/Anglesite-app --body "Paired PR open: <paste URL from previous step>"
```

---

## Final verification

After all 10 tasks land:

```bash
# Plugin: full test suite
cd ../anglesite && npx vitest run
# App: overlay tests
npm test --prefix JS/edit-overlay
# App: AnglesiteCore tests (sanity check; the new EditReply shape is JS-only)
swift test --package-path . --filter 'AnglesiteCoreTests'
```

Expected: green across all three.

Manual smoke (use `~/Sites/anglesite-smoke` if `scripts/create-smoke-fixture.sh` is already run):

1. Quit the app; if there's a prior install of the plugin in the smoke site's `node_modules/@dwk/anglesite/`, refresh it from the local plugin checkout (`npm install` or `npm link` per the existing dev workflow).
2. Launch the freshly-built Debug app, open the smoke site.
3. Drag a JPEG from Finder onto any `<img>` in the preview. Observe:
   - Image swaps to the dropped file immediately (blob URL).
   - 2–10 seconds later, the URL changes to `/images/<stem>.webp` and srcset populates.
   - `~/Sites/anglesite-smoke/public/images/` contains the new `.webp` + 4 width variants.
   - `~/Sites/anglesite-smoke/public/images/originals/` contains the previous file.
   - The `<img>` tag in the source `.astro` file is patched.
   - `git log refs/heads/anglesite/edits` in the smoke site shows a new commit.
4. Drag a corrupt file (e.g. rename `README.md` to `bad.jpg`) onto an `<img>`. Observe blob preview → revert to original + toast within ~10 seconds.

Push everything:

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && git push
cd ../anglesite && git push
```
