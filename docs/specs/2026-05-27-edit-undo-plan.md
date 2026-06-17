# Per-edit Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface every successful edit in the chat panel with an inline Undo button that rewinds the most-recent edit by writing the prior commit's blobs back to disk on the hidden `refs/heads/anglesite/edits` branch.

**Architecture:** Paired PR. The plugin (`../anglesite`) gains a new `undo_edit` MCP tool that compares the current hidden-branch HEAD's tree to its parent, checks the working tree for drift, and writes the parent's blobs back. The app gains a structured `EditReply` (Phase 9.3 loose-end fix), a `UndoCommand` actor wrapping the MCP tool call, a new `ChatModel.Role.edit` row type with persistence through `ChatHistoryStore`, and a `ChatView` row variant that shows the file + relative time + Undo button.

**Tech Stack:** Node.js ESM (plugin), vitest (plugin tests), Swift 6 (app), XCTest (app tests), SwiftUI on macOS 14+.

**Spec:** [`docs/specs/2026-05-27-edit-undo-design.md`](2026-05-27-edit-undo-design.md) (committed in `12793cb`).

**Tracking:** [Anglesite-app#33](https://github.com/Anglesite/Anglesite-app/issues/33). Plugin-side PR opens against `Anglesite/anglesite` and cross-links.

---

## Working directories

| Repo alias | Absolute path | Branch |
|---|---|---|
| **plugin** | `/Users/dwk/Developer/github.com/Anglesite/anglesite` | New `feat/phase-9-edit-undo` from `origin/main` |
| **app** | `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app` | `main` (direct commits, established workflow) |

Plugin's current `origin/main` head is `bf6b3a9` (Phase 9.3 image-drop merged via #319). The app's main is at `12793cb` (this plan's spec).

## File map

| Path | Repo | Action | Purpose |
|---|---|---|---|
| `server/messages.mjs` | plugin | Modify | Add 4 new reasons to `EDIT_FAILED_REASONS` |
| `server/undo-edit.mjs` | plugin | Create | Tool handler — HEAD-only revert with working-tree-modified check |
| `test/undo-edit.test.js` | plugin | Create | Tests via tmpdir git repos |
| `server/index.mjs` | plugin | Modify | Register `undo_edit` MCP tool |
| `Sources/AnglesiteBridge/EditRouter.swift` | app | Modify | `EditReply` gains `file`/`commit`/`result` structured fields |
| `Sources/AnglesiteBridge/MCPApplyEditRouter.swift` | app | Modify | Parse plugin reply text into structured fields; add `onEdit` observer |
| `Tests/AnglesiteBridgeTests/MCPApplyEditRouterTests.swift` | app | Modify | New cases — structured parse, observer fires, malformed-reply fallthrough |
| `Sources/AnglesiteCore/UndoCommand.swift` | app | Create | Wraps `MCPClient.callTool("undo_edit", …)` into typed `UndoResult` |
| `Tests/AnglesiteCoreTests/UndoCommandTests.swift` | app | Create | Mocked `MCPClient.ToolCallResult` cases |
| `Sources/AnglesiteCore/ChatHistoryStore.swift` | app | Modify | New `Entry.Role.edit` case, optional `editMetadata`, `Undone` record |
| `Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift` | app | Modify | Round-trip for `.edit` rows + `undone` record-flips-undone-flag |
| `Sources/AnglesiteApp/ChatModel.swift` | app | Modify | `Role.edit`, `EditMetadata`, `currentHeadSHA`, `recordEdit`, `undoEdit`, `conflictPrompt` |
| `Sources/AnglesiteApp/ChatView.swift` | app | Modify | `MessageRow` `.edit` variant + `.sheet` for conflict prompt |
| `Sources/AnglesiteApp/SiteWindow.swift` | app | Modify | Wire `router.onEdit` to `chat.recordEdit` in `loadAndStart` |
| `docs/build-plan.md` | app | Modify | Mark Phase 9 step 4 ✅ |

---

## Task 1 (plugin): EDIT_FAILED_REASONS additions

Adds the four reasons `undo_edit` will return. Standalone — no test, but `EDIT_FAILED_REASONS` is consumed by the schema validator so the additions need to land before the new handler.

**Files:**
- Modify: `../anglesite/server/messages.mjs`

- [ ] **Step 1: Set up the plugin branch**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git fetch origin
git checkout -b feat/phase-9-edit-undo origin/main
git status
```

Expected: clean working tree on `feat/phase-9-edit-undo` based at `bf6b3a9` (or whatever the current `origin/main` head is).

- [ ] **Step 2: Modify `server/messages.mjs`**

Find the `EDIT_FAILED_REASONS` array. It currently ends with `"image-optimize-failed"`. Append the four undo-specific reasons:

```javascript
export const EDIT_FAILED_REASONS = Object.freeze([
  "no-match",
  "ambiguous",
  "dynamic-expression",
  "patch-conflict",
  "write-failed",
  "not-implemented",
  "image-optimize-failed",
  "no-edits-to-undo",
  "head-only-mode",
  "initial-commit",
  "working-tree-modified",
]);
```

(If the array's interior order has drifted, preserve whatever order is there; just append the four new strings to the end.)

- [ ] **Step 3: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git add server/messages.mjs
git commit -m "feat(server): add four undo-specific EDIT_FAILED_REASONS

Phase 9 step 4 prep. The new undo_edit MCP tool (next commit) returns
four new refusal reasons:

  - no-edits-to-undo:     the hidden anglesite/edits branch is empty
  - head-only-mode:       caller passed a commit arg that isn't HEAD
                          (v1 enforces head-only; v2 may relax this)
  - initial-commit:       can't undo back past the first edit on the
                          branch (no parent commit to revert to)
  - working-tree-modified: the on-disk file drifted since the edit;
                          surfaces a warn-and-confirm sheet in the UI

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 (plugin): `server/undo-edit.mjs` + tests

The handler. Reads HEAD's tree on `refs/heads/anglesite/edits`, walks each changed file vs. its parent, optionally checks working-tree drift, then writes parent blobs back to disk and advances the branch with a new "undo" commit.

**Files:**
- Create: `../anglesite/server/undo-edit.mjs`
- Create: `../anglesite/test/undo-edit.test.js`

- [ ] **Step 1: Write the failing tests**

Create `../anglesite/test/undo-edit.test.js`:

```javascript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { recordEdit } from "../server/edit-history.mjs";
import { undoEdit } from "../server/undo-edit.mjs";

let repo;

function git(args) {
  return execFileSync("git", args, {
    cwd: repo, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function initRepo() {
  repo = mkdtempSync(join(tmpdir(), "undo-edit-"));
  execFileSync("git", ["init", "--initial-branch=main", repo], { stdio: "ignore" });
  git(["config", "user.email", "test@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(join(repo, "about.md"), "original\n");
  git(["add", "about.md"]);
  git(["commit", "-m", "initial"]);
}

beforeEach(initRepo);
afterEach(() => repo && rmSync(repo, { recursive: true, force: true }));

describe("undoEdit", () => {
  it("rewinds the most-recent edit and advances the branch with a new commit", async () => {
    // Simulate an edit on disk + recordEdit
    writeFileSync(join(repo, "about.md"), "edited\n");
    const editSha = await recordEdit(repo, {
      file: "about.md", range: { start: 0, end: 7 }, message: "edit about.md",
    });
    expect(editSha).toMatch(/^[0-9a-f]{40}$/);
    expect(git(["rev-parse", "refs/heads/anglesite/edits"])).toBe(editSha);

    // Undo
    const result = await undoEdit(repo, {});
    expect(result.status).toBe("undone");
    expect(result.newCommit).toMatch(/^[0-9a-f]{40}$/);
    expect(result.newCommit).not.toBe(editSha);

    // File on disk reverted
    expect(readFileSync(join(repo, "about.md"), "utf-8")).toBe("original\n");

    // Branch advanced — new HEAD has the parent's tree (== HEAD~2 of the branch)
    expect(git(["rev-parse", "refs/heads/anglesite/edits"])).toBe(result.newCommit);
    const newTree = git(["rev-parse", `${result.newCommit}^{tree}`]);
    const editTree = git(["rev-parse", `${editSha}^^{tree}`]);
    expect(newTree).toBe(editTree);

    // Parent linkage: new commit's parent is the edit commit (linearized, not amended)
    const parent = git(["rev-list", "--parents", "-n", "1", result.newCommit]).split(" ")[1];
    expect(parent).toBe(editSha);
  });

  it("refuses with working-tree-modified when the file drifted on disk", async () => {
    writeFileSync(join(repo, "about.md"), "edited\n");
    await recordEdit(repo, {
      file: "about.md", range: { start: 0, end: 7 }, message: "edit",
    });

    // External edit on disk between commit and undo
    writeFileSync(join(repo, "about.md"), "drift!\n");

    const result = await undoEdit(repo, {});
    expect(result.status).toBe("refused");
    expect(result.reason).toBe("working-tree-modified");
    expect(result.files).toEqual(["about.md"]);

    // On-disk file untouched, branch untouched
    expect(readFileSync(join(repo, "about.md"), "utf-8")).toBe("drift!\n");
  });

  it("force: true overwrites a drifted file and completes the undo", async () => {
    writeFileSync(join(repo, "about.md"), "edited\n");
    await recordEdit(repo, {
      file: "about.md", range: { start: 0, end: 7 }, message: "edit",
    });
    writeFileSync(join(repo, "about.md"), "drift!\n");

    const result = await undoEdit(repo, { force: true });
    expect(result.status).toBe("undone");
    expect(readFileSync(join(repo, "about.md"), "utf-8")).toBe("original\n");
  });

  it("refuses with no-edits-to-undo when the hidden branch doesn't exist", async () => {
    const result = await undoEdit(repo, {});
    expect(result.status).toBe("refused");
    expect(result.reason).toBe("no-edits-to-undo");
  });

  it("refuses with head-only-mode when commit arg doesn't match HEAD", async () => {
    writeFileSync(join(repo, "about.md"), "edited\n");
    await recordEdit(repo, {
      file: "about.md", range: { start: 0, end: 7 }, message: "edit",
    });
    const result = await undoEdit(repo, { commit: "0000000000000000000000000000000000000000" });
    expect(result.status).toBe("refused");
    expect(result.reason).toBe("head-only-mode");
  });

  it("clean undo when commit arg equals HEAD", async () => {
    writeFileSync(join(repo, "about.md"), "edited\n");
    const editSha = await recordEdit(repo, {
      file: "about.md", range: { start: 0, end: 7 }, message: "edit",
    });
    const result = await undoEdit(repo, { commit: editSha });
    expect(result.status).toBe("undone");
  });

  it("refuses with no-edits-to-undo when projectRoot is not a git repo", async () => {
    const notARepo = mkdtempSync(join(tmpdir(), "not-a-repo-"));
    try {
      const result = await undoEdit(notARepo, {});
      expect(result.status).toBe("refused");
      expect(result.reason).toBe("no-edits-to-undo");
    } finally {
      rmSync(notARepo, { recursive: true, force: true });
    }
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run test/undo-edit.test.js`

Expected: FAIL with `Cannot find module '../server/undo-edit.mjs'`.

- [ ] **Step 3: Implement `server/undo-edit.mjs`**

Create `../anglesite/server/undo-edit.mjs`:

```javascript
/**
 * Hidden-branch edit undo (#33). Reverts the most-recent commit on
 * refs/heads/anglesite/edits by writing the parent commit's blobs back to disk
 * and advancing the branch with a new linearized commit (`undo: <files>`).
 *
 * Same defensive-execFile pattern as edit-history.mjs — no shell, never
 * mutates the user's HEAD or current branch, every git call passed argv as
 * an array.
 *
 * Refusal reasons match the schema enum in server/messages.mjs:
 *   - no-edits-to-undo:     hidden branch doesn't exist (or projectRoot isn't a repo)
 *   - head-only-mode:       caller passed a commit arg that isn't HEAD
 *   - initial-commit:       HEAD has no parent (only one commit on the branch)
 *   - working-tree-modified: at least one touched file differs on disk vs. HEAD's blob
 */
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const EDITS_REF = "refs/heads/anglesite/edits";

function runGit(projectRoot, args, env = {}) {
  return execFileSync("git", args, {
    cwd: projectRoot,
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...env },
  }).trim();
}

function tryRunGit(projectRoot, args, env = {}) {
  try { return runGit(projectRoot, args, env); } catch { return undefined; }
}

function runGitBuffer(projectRoot, args) {
  return execFileSync("git", args, {
    cwd: projectRoot,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/**
 * @param {string} projectRoot
 * @param {{ commit?: string, force?: boolean }} opts
 */
export async function undoEdit(projectRoot, { commit, force = false } = {}) {
  // 1. Confirm hidden branch exists.
  const head = tryRunGit(projectRoot, ["show-ref", "--verify", "--hash", EDITS_REF]);
  if (!head) return { status: "refused", reason: "no-edits-to-undo" };

  // 2. Head-only mode — caller-supplied commit must match HEAD.
  if (commit && commit !== head) {
    return { status: "refused", reason: "head-only-mode" };
  }

  // 3. Get parent — guard against initial-commit case.
  const parent = tryRunGit(projectRoot, ["rev-parse", `${head}^`]);
  if (!parent) return { status: "refused", reason: "initial-commit" };

  // 4. List files that differ between HEAD and parent.
  const diff = tryRunGit(projectRoot, ["diff", "--name-only", parent, head]);
  if (diff === undefined) return { status: "refused", reason: "no-edits-to-undo" };
  const files = diff.split("\n").filter(Boolean);

  // 5. Working-tree drift check (unless force).
  if (!force) {
    const drifted = [];
    for (const file of files) {
      const onDisk = tryRunGit(projectRoot, ["hash-object", "--", file]);
      const headBlob = tryRunGit(projectRoot, ["rev-parse", `${head}:${file}`]);
      // hash-object on a missing file fails (returns undefined); treat as drift.
      if (!onDisk || onDisk !== headBlob) drifted.push(file);
    }
    if (drifted.length) {
      return { status: "refused", reason: "working-tree-modified", files: drifted };
    }
  }

  // 6. Write parent's blob content for each file back to disk.
  for (const file of files) {
    const content = runGitBuffer(projectRoot, ["show", `${parent}:${file}`]);
    writeFileSync(join(projectRoot, file), content);
  }

  // 7. Advance the hidden branch with a new commit whose tree matches parent's tree.
  const parentTree = runGit(projectRoot, ["rev-parse", `${parent}^{tree}`]);
  const message = `undo: ${files.join(", ")}`;
  const env = {
    GIT_AUTHOR_NAME: "Anglesite",
    GIT_AUTHOR_EMAIL: "edits@anglesite.local",
    GIT_COMMITTER_NAME: "Anglesite",
    GIT_COMMITTER_EMAIL: "edits@anglesite.local",
  };
  const newCommit = runGit(
    projectRoot,
    ["commit-tree", parentTree, "-p", head, "-m", message],
    env,
  );
  // CAS update: only advance if HEAD is still what we read in step 1.
  runGit(projectRoot, ["update-ref", EDITS_REF, newCommit, head]);

  return { status: "undone", newCommit };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run test/undo-edit.test.js`

Expected: all 7 tests pass.

Also run the full plugin suite to confirm nothing broke:

`cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run`

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git add server/undo-edit.mjs test/undo-edit.test.js
git commit -m "feat(server): undo-edit handler — rewind anglesite/edits HEAD (#33)

Phase 9 step 4. Adds server/undo-edit.mjs which:

  1. Walks the file-by-file diff between refs/heads/anglesite/edits HEAD
     and its parent.
  2. Optionally checks each touched file's on-disk hash against the HEAD
     blob (skip with force: true).
  3. Writes the parent commit's blob contents back to disk.
  4. Advances refs/heads/anglesite/edits with a new linearized commit
     ('undo: <files>') whose tree matches the parent's tree and whose
     parent is the edit's commit (so the branch history reads as edit →
     undo, not as a rebase).

Same defensive-execFile pattern as recordEdit. CAS update-ref with
OLDVALUE so concurrent undos can't silently clobber each other.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 (plugin): register `undo_edit` MCP tool

**Files:**
- Modify: `../anglesite/server/index.mjs`

- [ ] **Step 1: Register the tool**

Open `../anglesite/server/index.mjs`. At the top, alongside the existing imports, add:

```javascript
import { undoEdit } from "./undo-edit.mjs";
```

After the existing `server.tool("apply_edit", …)` registration, append:

```javascript
server.tool(
  "undo_edit",
  "Undo the most-recent commit on the hidden anglesite/edits branch by writing the parent commit's blobs back to disk. HEAD-only in v1: an optional `commit` argument must equal current HEAD (or be omitted). `force: true` skips the working-tree-modification check and overwrites any external changes to the touched files.",
  {
    commit: z.string().optional().describe("SHA to undo. Must equal current HEAD of refs/heads/anglesite/edits if provided."),
    force: z.boolean().optional().describe("Skip the working-tree-modification check and overwrite any external changes. Default false."),
  },
  async ({ commit, force }) => {
    const result = await undoEdit(projectRoot, { commit, force });
    return {
      content: [{ type: "text", text: JSON.stringify(result) }],
      isError: result.status === "refused",
    };
  },
);
```

(If `z` isn't already imported at the top of `index.mjs`, add `import { z } from "zod";` — but check first, since `apply_edit` is already using zod schemas and likely imports it.)

- [ ] **Step 2: Sanity-check the server starts**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite && node --check server/index.mjs`

Expected: no output (clean).

Also run the full plugin suite again:

`cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git add server/index.mjs
git commit -m "feat(server): register undo_edit MCP tool

Wires the new undo-edit handler into the MCP server. The tool takes an
optional commit (must equal HEAD in v1) and an optional force flag;
returns the standard MCP { content, isError } shape with the
JSON-encoded { status, newCommit?, reason?, files? } in the content
text.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 (app): structured `EditReply` + `MCPApplyEditRouter` parse + `onEdit` observer

Phase 9.3 loose-end fix. The Swift `EditReply` is currently `{ id, status, message? }`; the plugin's structured reply gets stuffed into `message` as a JSON-string blob. Promote `file`, `commit`, `result` to first-class Swift properties. Also add an `onEdit` observer parameter so `ChatModel.recordEdit` can be wired in Task 9.

**Files:**
- Modify: `Sources/AnglesiteBridge/EditRouter.swift`
- Modify: `Sources/AnglesiteBridge/MCPApplyEditRouter.swift`
- Modify: `Tests/AnglesiteBridgeTests/MCPApplyEditRouterTests.swift`

- [ ] **Step 1: Add the new fields to `EditReply`**

In `Sources/AnglesiteBridge/EditRouter.swift`, replace the `EditReply` struct definition:

```swift
public struct EditReply: Sendable, Equatable, Encodable {
    public let id: String
    public let status: Status
    /// Human-readable detail. Always present for `.failed` / `.ambiguous`; optional for `.applied`.
    public let message: String?
    /// Source file the patch landed on (relative path within the site). Present on `.applied`
    /// when the plugin's structured reply included it; `nil` for `.failed` / `.ambiguous` and
    /// for replies the router couldn't parse as JSON.
    public let file: String?
    /// SHA of the commit on `refs/heads/anglesite/edits` that captures this edit. `nil` when
    /// the site isn't a git repo, or for non-`.applied` replies.
    public let commit: String?
    /// Op-scoped metadata. For `replace-image-src` carries `{ src, srcset? }`. `nil` for ops
    /// that don't surface overlay-side metadata.
    public let result: ImageResult?

    public struct ImageResult: Sendable, Equatable, Encodable {
        public let src: String
        public let srcset: String?

        public init(src: String, srcset: String?) {
            self.src = src
            self.srcset = srcset
        }
    }

    public enum Status: String, Sendable, Equatable, Encodable {
        case applied, failed, ambiguous
    }

    public init(
        id: String,
        status: Status,
        message: String?,
        file: String? = nil,
        commit: String? = nil,
        result: ImageResult? = nil
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.file = file
        self.commit = commit
        self.result = result
    }
}
```

Note the defaulted `nil`s on the new fields — existing call sites that pass three args still compile.

- [ ] **Step 2: Update `MCPApplyEditRouter` to parse structured fields + add `onEdit`**

In `Sources/AnglesiteBridge/MCPApplyEditRouter.swift`, replace the entire file:

```swift
import Foundation
import AnglesiteCore

/// `EditRouter` backed by an `MCPClient` `tools/call` to the plugin's `apply_edit` tool.
///
/// Parses the plugin's structured reply body — `{ type, id, file, range, commit, result? }` —
/// out of the MCP tool's `content[0].text` JSON string into typed Swift properties on
/// `EditReply`. Falls back gracefully to the original "stuff the text in `message`" behavior
/// when the body isn't valid JSON (e.g. older plugins, or `apply_edit` impls that don't emit
/// the structured body).
///
/// `onEdit` fires after every successful `.applied` reply with a non-nil `commit` — wired by
/// `SiteWindow` to `ChatModel.recordEdit(_:)` so the chat panel surfaces each edit as a row.
public struct MCPApplyEditRouter: EditRouter {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult
    public typealias EditObserver = @Sendable (EditReply) -> Void

    private let toolCaller: ToolCaller
    private let onEdit: EditObserver?

    /// Test seam — inject a closure that mimics `MCPClient.callTool` so the router's mapping
    /// logic is verifiable without a live MCP server.
    public init(toolCaller: @escaping ToolCaller, onEdit: EditObserver? = nil) {
        self.toolCaller = toolCaller
        self.onEdit = onEdit
    }

    /// Production hookup: bind to a getter for the currently-active `MCPClient`. Returns
    /// `.failed("MCP not running")` via a thrown `notInitialized` when the getter is `nil`.
    public init(
        mcpClient: @escaping @Sendable () async -> MCPClient?,
        onEdit: EditObserver? = nil
    ) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw MCPClient.MCPError.notInitialized }
            return try await client.callTool(name: name, arguments: args)
        }
        self.onEdit = onEdit
    }

    public func apply(_ message: EditMessage) async -> EditReply {
        let args = message.jsonValue
        do {
            let result = try await toolCaller("apply_edit", args)
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            let trimmed = text.isEmpty ? nil : text
            let parsed = Self.parseStructured(text)
            if result.isError {
                return EditReply(
                    id: message.id,
                    status: .failed,
                    message: trimmed,
                    file: parsed?.file,
                    commit: parsed?.commit,
                    result: parsed?.result
                )
            }
            let reply = EditReply(
                id: message.id,
                status: .applied,
                message: trimmed,
                file: parsed?.file,
                commit: parsed?.commit,
                result: parsed?.result
            )
            if reply.commit != nil { onEdit?(reply) }
            return reply
        } catch {
            return EditReply(id: message.id, status: .failed, message: "\(error)")
        }
    }

    /// Parses the plugin's edit-applied JSON body out of the MCP tool's content text. Returns
    /// `nil` for non-JSON content (the router falls back to the message-string behavior in
    /// that case).
    static func parseStructured(_ text: String) -> Parsed? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let file = json["file"] as? String
        let commit = json["commit"] as? String
        var image: EditReply.ImageResult?
        if let resultDict = json["result"] as? [String: Any],
           let src = resultDict["src"] as? String {
            let srcset = resultDict["srcset"] as? String
            image = EditReply.ImageResult(src: src, srcset: srcset)
        }
        if file == nil && commit == nil && image == nil { return nil }
        return Parsed(file: file, commit: commit, result: image)
    }

    struct Parsed: Equatable {
        let file: String?
        let commit: String?
        let result: EditReply.ImageResult?
    }
}
```

- [ ] **Step 3: Write new tests in `MCPApplyEditRouterTests.swift`**

Open `Tests/AnglesiteBridgeTests/MCPApplyEditRouterTests.swift`. After the last existing test, before the file's closing brace, append:

```swift
    // MARK: structured reply parse

    func testSuccessfulReplyWithStructuredBodyExposesStructuredFields() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .applied)
        XCTAssertEqual(reply.file, "src/pages/about.astro")
        XCTAssertEqual(reply.commit, "abc1234567890abcdef1234567890abcdef12345")
        XCTAssertNil(reply.result)
    }

    func testSuccessfulReplyWithResultExposesImageResult() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","result":{"src":"/images/hero.webp","srcset":"/images/hero-480w.webp 480w"}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.result?.src, "/images/hero.webp")
        XCTAssertEqual(reply.result?.srcset, "/images/hero-480w.webp 480w")
    }

    func testMalformedReplyTextFallsBackToMessageString() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "not valid json {")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .applied)
        XCTAssertEqual(reply.message, "not valid json {")
        XCTAssertNil(reply.file)
        XCTAssertNil(reply.commit)
    }

    func testOnEditFiresForAppliedReplyWithCommit() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(toolCaller: recorder.call, onEdit: { reply in
            Task { await observed.record(reply) }
        })
        _ = await router.apply(sampleMessage)
        // Yield briefly to let the Task fire.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.commit, "abc1234567890abcdef1234567890abcdef12345")
    }

    func testOnEditDoesNotFireWhenReplyHasNoCommit() async {
        // No JSON in the content — parser gives up; reply has nil commit; observer must NOT fire.
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "stub edit response")],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(toolCaller: recorder.call, onEdit: { reply in
            Task { await observed.record(reply) }
        })
        _ = await router.apply(sampleMessage)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        XCTAssertTrue(captured.isEmpty)
    }
}

/// Thread-safe collector for the `onEdit` callback fired from the router's async context.
private actor ObservedReplies {
    private(set) var replies: [EditReply] = []
    func record(_ reply: EditReply) { replies.append(reply) }
}
```

(If the test file's closing brace is followed by other helper types, splice the new tests in BEFORE that closing brace — the `ObservedReplies` actor should be outside the class but in the same file.)

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path . --filter MCPApplyEditRouterTests`

Expected: all router tests pass — existing ones still green, new five pass.

Also run the full bridge suite:

`swift test --package-path . --filter AnglesiteBridgeTests`

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteBridge/EditRouter.swift \
        Sources/AnglesiteBridge/MCPApplyEditRouter.swift \
        Tests/AnglesiteBridgeTests/MCPApplyEditRouterTests.swift
git commit -m "feat(bridge): structured EditReply + onEdit observer

Phase 9.3 loose-end fix + Phase 9.4 prep. EditReply gains optional
file/commit/result fields; MCPApplyEditRouter parses the plugin's
JSON-encoded reply body out of the MCP content[0].text into those
typed Swift properties.

The router gains an optional onEdit observer — invoked after every
successful .applied reply with a non-nil commit. SiteWindow will wire
this to ChatModel.recordEdit() in a later commit so each edit shows
up as a chat row.

Backward-compatible: malformed/non-JSON content falls back to the
existing message-string behavior, and the new EditReply fields all
default to nil so existing call sites compile unchanged.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5 (app): `UndoCommand` in AnglesiteCore + tests

Wraps the new `undo_edit` MCP tool into a typed Swift API. Pure logic over `MCPClient.callTool`; tests use a fake client. Lives in `AnglesiteCore` so `ChatModel` can depend on it without pulling in `AnglesiteBridge`.

**Files:**
- Create: `Sources/AnglesiteCore/UndoCommand.swift`
- Create: `Tests/AnglesiteCoreTests/UndoCommandTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/UndoCommandTests.swift`:

```swift
import XCTest
@testable import AnglesiteCore

final class UndoCommandTests: XCTestCase {
    func testUndoSuccessParsesNewCommit() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.call)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .success(let newCommit) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(newCommit, "abcd1234")
        XCTAssertEqual(fake.lastArgs, .object([
            "commit": .string("current-head"),
            "force": .bool(false),
        ]))
    }

    func testUndoWorkingTreeModifiedReturnsTypedFiles() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"working-tree-modified","files":["src/pages/about.astro"]}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.call)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .workingTreeModified(let files) = result else {
            return XCTFail("expected .workingTreeModified, got \(result)")
        }
        XCTAssertEqual(files, ["src/pages/about.astro"])
    }

    func testUndoForwardsForceFlag() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.call)
        _ = await cmd.undo(commit: "current-head", force: true)
        guard case .object(let dict) = fake.lastArgs,
              case .bool(let force)? = dict["force"]
        else { return XCTFail("unexpected args shape: \(fake.lastArgs)") }
        XCTAssertTrue(force)
    }

    func testUndoFailedMapsToFailedReason() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"initial-commit"}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.call)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(let reason, _) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertEqual(reason, "initial-commit")
    }

    func testUndoThrownErrorMapsToFailed() async {
        struct OopsError: Error {}
        let fake = FakeMCPCaller(result: .failure(OopsError()))
        let cmd = UndoCommand(caller: fake.call)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(_, let detail) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(detail.contains("OopsError"))
    }
}

private final class FakeMCPCaller: @unchecked Sendable {
    private let result: Result<MCPClient.ToolCallResult, Error>
    private(set) var lastArgs: JSONValue = .null
    private let lock = NSLock()

    init(result: Result<MCPClient.ToolCallResult, Error>) {
        self.result = result
    }

    func call(name: String, arguments: JSONValue) async throws -> MCPClient.ToolCallResult {
        lock.lock(); lastArgs = arguments; lock.unlock()
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && swift test --package-path . --filter UndoCommandTests`

Expected: build failure — `UndoCommand` doesn't exist yet.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/UndoCommand.swift`**

```swift
import Foundation

/// Typed wrapper around the plugin's `undo_edit` MCP tool.
///
/// `undo(commit:force:)` returns an `UndoResult` enum that surfaces the three meaningful
/// outcomes — success with the new branch SHA, conflict with the drifted file list, and
/// generic failure with a reason+detail pair. The chat panel presents a warn-and-confirm
/// sheet on `.workingTreeModified` and retries with `force: true` if the owner confirms.
public struct UndoCommand: Sendable {
    public typealias Caller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    public enum UndoResult: Sendable, Equatable {
        case success(newCommit: String)
        case workingTreeModified(files: [String])
        case failed(reason: String, detail: String)
    }

    private let caller: Caller

    public init(caller: @escaping Caller) {
        self.caller = caller
    }

    /// Production hookup — bind to a getter for the currently-active `MCPClient`. The chat
    /// view's Undo button calls this with the commit SHA of the head edit row.
    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.caller = { name, args in
            guard let client = await mcpClient() else { throw MCPClient.MCPError.notInitialized }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    public func undo(commit: String, force: Bool) async -> UndoResult {
        let args: JSONValue = .object([
            "commit": .string(commit),
            "force": .bool(force),
        ])
        let result: MCPClient.ToolCallResult
        do {
            result = try await caller("undo_edit", args)
        } catch {
            return .failed(reason: "mcp-error", detail: String(describing: error))
        }
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failed(reason: "malformed-reply", detail: text.isEmpty ? "no content" : text)
        }
        let status = json["status"] as? String ?? "unknown"
        if status == "undone", let newCommit = json["newCommit"] as? String {
            return .success(newCommit: newCommit)
        }
        let reason = json["reason"] as? String ?? "unknown"
        if reason == "working-tree-modified" {
            let files = (json["files"] as? [String]) ?? []
            return .workingTreeModified(files: files)
        }
        let detail = (json["detail"] as? String) ?? text
        return .failed(reason: reason, detail: detail)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && swift test --package-path . --filter UndoCommandTests`

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteCore/UndoCommand.swift Tests/AnglesiteCoreTests/UndoCommandTests.swift
git commit -m "feat(core): UndoCommand — typed wrapper for undo_edit MCP tool

Phase 9 step 4. UndoCommand.undo(commit:force:) returns an UndoResult
enum surfacing the three meaningful outcomes: success with new branch
SHA, workingTreeModified with the drifted file list, and failed with
a reason+detail pair.

Test seam via Caller closure; production hookup via mcpClient getter
that throws MCPClient.MCPError.notInitialized when the per-site
PreviewSession's client isn't running.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6 (app): `ChatHistoryStore` — `.edit` Entry + `Undone` record

Extends the JSONL persistence layer to support the new `.edit` row and the `undone` synthetic record. Backward-compatible: existing `user`/`assistant`/`tool` entries decode unchanged.

**Files:**
- Modify: `Sources/AnglesiteCore/ChatHistoryStore.swift`
- Modify: `Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Open `Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift`. Find the file's closing brace and append these new tests just before it:

```swift
    // MARK: edit rows + undone records

    func testEditEntryRoundTripsWithMetadata() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123"]
        )
        try await store.append(edit)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].role, .edit)
        XCTAssertEqual(loaded[0].metadata?["file"], "src/pages/about.astro")
        XCTAssertEqual(loaded[0].metadata?["commit"], "abc123")
    }

    func testUndoneRecordFlipsTheReferencedEditsUndoneFlag() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        let editID = UUID()
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        )
        try await store.append(edit)
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1, "undone records collapse onto the referenced edit, not as separate rows")
        XCTAssertEqual(loaded[0].metadata?["undone"], "true")
        XCTAssertEqual(loaded[0].metadata?["undoneNewCommit"], "def456")
    }

    func testUndoneRecordWithoutMatchingEditIsIgnored() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        try await store.appendUndone(messageID: UUID(), newCommit: "orphan")
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testMixedHistoryPreservesOrderAndAppliesUndone() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        let editID = UUID()
        try await store.append(.init(role: .user, content: "Hi"))
        try await store.append(.init(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        ))
        try await store.append(.init(role: .assistant, content: "OK."))
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.role), [.user, .edit, .assistant])
        XCTAssertEqual(loaded[1].metadata?["undone"], "true")
    }
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && swift test --package-path . --filter ChatHistoryStoreTests`

Expected: build failure — `Role.edit` doesn't exist, `appendUndone` doesn't exist.

- [ ] **Step 3: Implement the extensions in `Sources/AnglesiteCore/ChatHistoryStore.swift`**

In `Sources/AnglesiteCore/ChatHistoryStore.swift`, find the `Role` enum and add the new case:

```swift
public enum Role: String, Sendable, Codable, Equatable {
    case user
    case assistant
    case tool
    /// An edit landed on the source — surfaced in chat with an inline Undo button.
    /// Metadata carries `file`, `commit`, `messageID`, and optional `undone`/`undoneNewCommit`
    /// once an undone record has been processed.
    case edit
}
```

Find the `Entry` struct and ensure it stays the same shape (no change needed — metadata is already a free-form dictionary).

At the end of the actor body (just before the file's final closing brace), add:

```swift
    /// One synthetic record marker. `load()` collapses these onto the referenced edit by
    /// setting its `metadata["undone"] = "true"` and `metadata["undoneNewCommit"] = "<sha>"`.
    /// Wire format on disk:
    ///   { "kind": "undone", "messageID": "<UUID>", "newCommit": "<sha>", "timestamp": "…" }
    public func appendUndone(messageID: UUID, newCommit: String) throws {
        struct UndoneRecord: Encodable {
            let kind = "undone"
            let messageID: String
            let newCommit: String
            let timestamp: Date
        }
        let record = UndoneRecord(
            messageID: messageID.uuidString,
            newCommit: newCommit,
            timestamp: Date()
        )
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        var data = try encoder.encode(record)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
```

Replace the `load()` method with one that knows about the new record kind:

```swift
    /// Load every entry from the history file, in write order. Returns an empty array if the
    /// file doesn't exist yet (a brand-new site has no history). Synthetic "undone" records are
    /// collapsed onto the referenced edit entries by flipping their `metadata["undone"]` flag.
    public func load() throws -> [Entry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        struct UndoneSidecar: Decodable {
            let kind: String
            let messageID: String
            let newCommit: String
        }
        var entries: [Entry] = []
        var undoneSidecars: [String: String] = [:]  // messageID → newCommit
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            if let sidecar = try? decoder.decode(UndoneSidecar.self, from: lineData),
               sidecar.kind == "undone" {
                undoneSidecars[sidecar.messageID] = sidecar.newCommit
                continue
            }
            if let entry = try? decoder.decode(Entry.self, from: lineData) {
                entries.append(entry)
            }
        }
        // Apply undone sidecars by matching the entry's metadata["messageID"].
        if !undoneSidecars.isEmpty {
            entries = entries.map { entry in
                guard entry.role == .edit,
                      let mid = entry.metadata?["messageID"],
                      let newCommit = undoneSidecars[mid]
                else { return entry }
                var meta = entry.metadata ?? [:]
                meta["undone"] = "true"
                meta["undoneNewCommit"] = newCommit
                return Entry(
                    timestamp: entry.timestamp,
                    role: entry.role,
                    content: entry.content,
                    metadata: meta
                )
            }
        }
        return entries
    }
```

- [ ] **Step 4: Run tests — expect pass**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && swift test --package-path . --filter ChatHistoryStoreTests`

Expected: all tests pass — existing ones still green, four new ones pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteCore/ChatHistoryStore.swift Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift
git commit -m "feat(core): ChatHistoryStore supports .edit rows + undone records

Phase 9 step 4. The JSONL persistence layer grows:

  1. Role.edit — a new entry kind. Metadata carries file, commit, and
     messageID so undone sidecars can find their target.
  2. appendUndone(messageID:newCommit:) — writes a synthetic
     { kind: 'undone', messageID, newCommit, timestamp } record on a
     new line, no rewrite of existing rows.
  3. load() collapses undone sidecars onto their referenced edits by
     flipping metadata['undone'] = 'true'. Orphan sidecars (no matching
     edit row in the file) are silently dropped.

Backward-compatible: existing user/assistant/tool entries decode and
serialize identically. JSONL stays strictly append-only on disk.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7 (app): `ChatModel` — `Role.edit`, `EditMetadata`, `recordEdit`, `undoEdit`

The ChatModel layer. New `.edit` role on the in-memory message, an `EditMetadata` struct carrying file + commit + undone, `recordEdit(_:)` to append from an `EditReply`, `undoEdit(messageID:)` to call `UndoCommand` and handle the response, a `currentHeadSHA` computed property, and a `conflictPrompt` binding for the warn-and-confirm sheet.

**Files:**
- Modify: `Sources/AnglesiteApp/ChatModel.swift`

(No unit tests added in this task — `ChatModel` is in `AnglesiteApp` which has no test target today; existing `ChatModel` methods like `send(_:)` and `loadAnnotations()` are also untested. The Core-layer pieces this orchestrates — `UndoCommand`, `ChatHistoryStore` — are fully tested in Tasks 5 and 6. The smoke fixture in Task 10 covers `ChatModel` end-to-end.)

- [ ] **Step 1: Extend `Role` and `Message`**

In `Sources/AnglesiteApp/ChatModel.swift`, find the `Role` enum (around line 31):

```swift
enum Role: Equatable { case user, assistant, system, error }
```

Replace with:

```swift
enum Role: Equatable { case user, assistant, system, error, edit }
```

Just below the `Message` struct's existing fields, add a new optional `editMetadata`:

```swift
struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    var toolCalls: [ToolCall]
    let timestamp: Date
    /// Only set on `role: .edit` rows. Carries file + commit + undone flag.
    var editMetadata: EditMetadata?

    enum Role: Equatable { case user, assistant, system, error, edit }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCalls: [ToolCall] = [],
        timestamp: Date = Date(),
        editMetadata: EditMetadata? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.timestamp = timestamp
        self.editMetadata = editMetadata
    }
}

struct EditMetadata: Equatable {
    let file: String
    let commit: String
    var undone: Bool
}
```

(If the existing `Message.init` already has a different parameter order or defaults, preserve those and only add `editMetadata: EditMetadata? = nil` as a new optional trailing parameter.)

- [ ] **Step 2: Add an `UndoCommand` dependency**

Just below the existing `private let annotationFeed: AnnotationFeed?` line:

```swift
    /// Optional. Wired to the per-site `MCPClient` for production; nil in tests where the
    /// chat has no MCP backing yet.
    private let undoCommand: UndoCommand?
```

Update both `init(...)` methods to accept `undoCommand: UndoCommand? = nil`:

```swift
    init(siteID: String, siteDirectory: URL) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.agent = ClaudeAgent(siteDirectory: siteDirectory)
        self.history = ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = nil
        self.undoCommand = nil
    }

    init(
        siteDirectory: URL,
        agent: ClaudeAgent,
        history: ChatHistoryStore? = nil,
        annotationFeed: AnnotationFeed? = nil,
        undoCommand: UndoCommand? = nil
    ) {
        self.siteID = ""
        self.siteDirectory = siteDirectory
        self.agent = agent
        self.history = history ?? ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.undoCommand = undoCommand
    }
```

(Adjust to whatever the existing `siteID` field shape is — look at the existing initializer and keep its structure, just add the new parameter.)

- [ ] **Step 3: Add `currentHeadSHA` + `conflictPrompt`**

After the `lastUsage` declaration, add:

```swift
    /// SHA of the most-recent `.edit` row whose `editMetadata.undone == false`. Drives the
    /// Undo button's enabled state — only the head row has an enabled button. Nil when no
    /// un-undone edit rows exist.
    var currentHeadSHA: String? {
        messages.reversed().first { msg in
            msg.role == .edit && (msg.editMetadata?.undone == false)
        }?.editMetadata?.commit
    }

    /// Binding for the warn-and-confirm sheet shown when the working tree drifted between
    /// the edit and the undo click. `nil` when no conflict is pending.
    var conflictPrompt: ConflictPrompt?

    struct ConflictPrompt: Identifiable, Equatable {
        let id = UUID()
        let messageID: UUID
        let commit: String
        let files: [String]
    }
```

- [ ] **Step 4: Add `recordEdit(_:)` and `undoEdit(messageID:)`**

Just before the existing `// MARK: Helpers` (or wherever's a sensible spot near `send`), add:

```swift
    /// Append a `.edit` row from a successful `EditReply`. The reply must have a non-nil
    /// `commit` field — `MCPApplyEditRouter.onEdit` only fires for those. Persists the row
    /// via `ChatHistoryStore` with the `messageID` in metadata so future `undone` sidecars
    /// can find it on reload.
    func recordEdit(_ reply: EditReply) {
        guard let file = reply.file, let commit = reply.commit else { return }
        let metadata = EditMetadata(file: file, commit: commit, undone: false)
        let message = Message(
            role: .edit,
            content: "Edited \(file)",
            editMetadata: metadata
        )
        messages.append(message)
        let entry = ChatHistoryStore.Entry(
            timestamp: message.timestamp,
            role: .edit,
            content: message.content,
            metadata: [
                "file": file,
                "commit": commit,
                "messageID": message.id.uuidString,
            ]
        )
        Task { [history] in try? await history.append(entry) }
    }

    /// Call `undo_edit` for the message identified by `messageID`. On success, flip the
    /// row's `undone` flag and persist a sidecar. On working-tree drift, set `conflictPrompt`
    /// so the view shows a sheet. On failure, append an `.error` system message.
    func undoEdit(messageID: UUID, force: Bool = false) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == .edit,
              let metadata = messages[idx].editMetadata,
              !metadata.undone
        else { return }
        guard let undoCommand else {
            lastError = "Undo unavailable: MCP not running."
            return
        }
        let result = await undoCommand.undo(commit: metadata.commit, force: force)
        switch result {
        case .success(let newCommit):
            var updated = metadata
            updated.undone = true
            messages[idx].editMetadata = updated
            Task { [history] in
                try? await history.appendUndone(messageID: messageID, newCommit: newCommit)
            }
        case .workingTreeModified(let files):
            conflictPrompt = ConflictPrompt(messageID: messageID, commit: metadata.commit, files: files)
        case .failed(let reason, let detail):
            let message = "Couldn't undo: \(detail) (\(reason))"
            messages.append(Message(role: .error, content: message))
            lastError = message
        }
    }

    /// Called when the user clicks "Undo anyway" on the conflict sheet. Retries the undo
    /// with `force: true` and dismisses the sheet.
    func confirmConflictUndo() async {
        guard let prompt = conflictPrompt else { return }
        conflictPrompt = nil
        await undoEdit(messageID: prompt.messageID, force: true)
    }

    /// Called when the user clicks "Cancel" on the conflict sheet.
    func dismissConflictPrompt() {
        conflictPrompt = nil
    }
```

- [ ] **Step 4b: Fix `recordEdit` import**

`EditReply` lives in `AnglesiteBridge`. Add the import near the top of `Sources/AnglesiteApp/ChatModel.swift` if it isn't already there:

```swift
import AnglesiteBridge
```

(Search for `import AnglesiteBridge` first — if it's already imported for another reason, no edit needed.)

- [ ] **Step 5: Update `Message(persisted:)` to handle `.edit` entries**

At the bottom of `Sources/AnglesiteApp/ChatModel.swift`, find the private extension:

```swift
private extension ChatModel.Message {
    init(persisted entry: ChatHistoryStore.Entry) {
        let role: ChatModel.Message.Role = {
            switch entry.role {
            case .user: return .user
            case .assistant: return .assistant
            case .tool: return .assistant
            }
        }()
        self.init(role: role, content: entry.content, timestamp: entry.timestamp)
    }
}
```

Replace with:

```swift
private extension ChatModel.Message {
    init(persisted entry: ChatHistoryStore.Entry) {
        let role: ChatModel.Message.Role = {
            switch entry.role {
            case .user: return .user
            case .assistant: return .assistant
            case .tool: return .assistant
            case .edit: return .edit
            }
        }()
        var editMetadata: ChatModel.EditMetadata?
        if entry.role == .edit,
           let file = entry.metadata?["file"],
           let commit = entry.metadata?["commit"] {
            let undone = entry.metadata?["undone"] == "true"
            editMetadata = ChatModel.EditMetadata(file: file, commit: commit, undone: undone)
        }
        self.init(
            role: role,
            content: entry.content,
            timestamp: entry.timestamp,
            editMetadata: editMetadata
        )
    }
}
```

- [ ] **Step 6: Update the `persist(_:)` helper**

Find `private func persist(_ message: Message)`. The current switch handles `user/assistant/system/error`. Add the `.edit` case:

```swift
private func persist(_ message: Message) {
    let role: ChatHistoryStore.Role = {
        switch message.role {
        case .user: return .user
        case .assistant: return .assistant
        case .system, .error: return .assistant
        case .edit: return .edit
        }
    }()
    var metadata: [String: String] = [:]
    if !message.toolCalls.isEmpty {
        metadata["tool_calls"] = message.toolCalls.count.description
    }
    if let edit = message.editMetadata {
        metadata["file"] = edit.file
        metadata["commit"] = edit.commit
        metadata["messageID"] = message.id.uuidString
    }
    let entry = ChatHistoryStore.Entry(
        timestamp: message.timestamp,
        role: role,
        content: message.content,
        metadata: metadata.isEmpty ? nil : metadata
    )
    Task { [history] in try? await history.append(entry) }
}
```

(Note: `recordEdit` does its own persist with explicit metadata — `persist(_:)` is updated for general callers that might pass a `.edit` message through, but in practice this path won't be hit by Phase 9.4 code.)

- [ ] **Step 7: Build to confirm everything compiles**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`. If any test target compiles `ChatModel` directly, also:

`swift test --package-path . --filter ChatModelTests 2>&1 | tail -10`

Expected: pass (or no such test target — that's fine).

- [ ] **Step 8: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteApp/ChatModel.swift
git commit -m "feat(chat): Role.edit + recordEdit/undoEdit on ChatModel

Phase 9 step 4. ChatModel grows:

  - Message.Role.edit + Message.editMetadata { file, commit, undone }
  - recordEdit(EditReply) — appends a .edit row from MCPApplyEditRouter's
    onEdit observer (wired in a later commit), persists with messageID
    in metadata.
  - undoEdit(messageID:force:) — calls UndoCommand.undo, flips the row's
    undone flag on success, sets conflictPrompt on working-tree drift,
    appends an .error system message on hard failure.
  - confirmConflictUndo() / dismissConflictPrompt() — sheet callbacks.
  - currentHeadSHA — computed; the latest unundone .edit row's commit.
    Drives the view's per-row Undo enabled state.

Persisted .edit rows round-trip through ChatHistoryStore via Task 6's
extensions. Existing user/assistant/system/error paths unchanged.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8 (app): `ChatView` — `.edit` row variant + conflict sheet

**Files:**
- Modify: `Sources/AnglesiteApp/ChatView.swift`

- [ ] **Step 1: Add the `.edit` row branch in `MessageRow`**

In `Sources/AnglesiteApp/ChatView.swift`, find `MessageRow`'s `body` (currently around line 222):

```swift
var body: some View {
    HStack {
        if message.role == .user { Spacer(minLength: 32) }
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            bubble
            ForEach(message.toolCalls) { call in
                ToolCallCard(call: call)
            }
        }
        if message.role != .user { Spacer(minLength: 32) }
    }
}
```

Replace with:

```swift
var body: some View {
    if message.role == .edit {
        editRow
    } else {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                bubble
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
            }
            if message.role != .user { Spacer(minLength: 32) }
        }
    }
}
```

Then add the `editRow` view. The owner needs `model` to bind the Undo button — the `MessageRow` struct already has `let message: ChatModel.Message` but doesn't have `model`. Promote: add `let model: ChatModel` to the struct. Update the call site in `messagesList`:

```swift
ForEach(model.messages) { message in
    MessageRow(message: message, model: model)
        .id(message.id)
}
```

And add the new view inside `MessageRow`:

```swift
@ViewBuilder
private var editRow: some View {
    HStack(spacing: 8) {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 3)
        VStack(alignment: .leading, spacing: 2) {
            Text(message.content)
                .font(.callout)
                .foregroundStyle(.primary)
            Text(relativeTime)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
        if let metadata = message.editMetadata {
            if metadata.undone {
                Text("Undone")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button("Undo") {
                    Task { await model.undoEdit(messageID: message.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(metadata.commit != model.currentHeadSHA)
            }
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
}

private var relativeTime: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: message.timestamp, relativeTo: Date())
}
```

Also extend `bubbleBackground` to include `.edit` (it's branched out before the switch, but the compiler will still require it — pick a sensible color):

```swift
private var bubbleBackground: Color {
    switch message.role {
    case .user: return Color.accentColor.opacity(0.18)
    case .assistant: return Color(NSColor.controlBackgroundColor)
    case .system: return Color.secondary.opacity(0.12)
    case .error: return Color.red.opacity(0.15)
    case .edit: return Color.secondary.opacity(0.06)  // never actually rendered; editRow handles .edit
    }
}
```

- [ ] **Step 2: Add the conflict sheet on `ChatView`**

In `ChatView`'s `body`, find where existing sheets are attached (search for `.sheet`). If none exist, append `.sheet(...)` to the root view. The pattern:

```swift
.sheet(item: $model.conflictPrompt) { prompt in
    VStack(alignment: .leading, spacing: 12) {
        Text("File modified outside Anglesite")
            .font(.headline)
        Text("`\(prompt.files.joined(separator: "`, `"))` has been changed since this edit. Undoing will overwrite those changes.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Cancel") { model.dismissConflictPrompt() }
            Button("Undo anyway", role: .destructive) {
                Task { await model.confirmConflictUndo() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    .padding(20)
    .frame(width: 380)
}
```

The `$model.conflictPrompt` binding requires `@Bindable model` — the existing ChatView already uses `@Bindable var model: ChatModel` based on the surrounding code patterns. If it doesn't, change the property declaration accordingly.

- [ ] **Step 3: Build**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteApp/ChatView.swift
git commit -m "feat(chat): MessageRow .edit variant + conflict sheet

Phase 9 step 4. ChatView's MessageRow handles the new .edit role with
its own compact layout: a left-edge color stripe, file + relative time,
and a right-aligned Undo button. Undo is enabled only on the row whose
commit matches ChatModel.currentHeadSHA (the most-recent unundone
edit). Undone rows show 'Undone' instead of the button.

A new .sheet(item: \$model.conflictPrompt) presents the warn-and-
confirm dialog when undo_edit returns working-tree-modified — Cancel
leaves state unchanged, Undo anyway re-invokes with force: true.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9 (app): wire `MCPApplyEditRouter.onEdit` to `ChatModel.recordEdit`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

- [ ] **Step 1: Wire the observer in `loadAndStart`**

Open `Sources/AnglesiteApp/SiteWindow.swift`. Find the `loadAndStart()` method. After the existing line that constructs the `ChatModel` (something like `chat = ChatModel(...)`), and after `preview.start(...)` or whatever's already wiring the preview, locate where `PreviewModel`'s `editRouter` is set up.

The cleanest wiring: pass `onEdit` directly into the `MCPApplyEditRouter` construction. Hunt down the construction site — it's in `Sources/AnglesiteApp/PreviewModel.swift`, currently:

```swift
self.editRouter = MCPApplyEditRouter(mcpClient: { [weak session] in
    guard let session else { return nil }
    return await session.mcpClient()
})
```

Modify `PreviewModel.init` to accept an optional `onEdit` parameter:

```swift
@MainActor
final class PreviewModel {
    // ... existing properties ...

    init(onEdit: MCPApplyEditRouter.EditObserver? = nil) {
        // ... existing setup ...
        self.editRouter = MCPApplyEditRouter(
            mcpClient: { [weak session] in
                guard let session else { return nil }
                return await session.mcpClient()
            },
            onEdit: onEdit
        )
        // ... rest of existing setup ...
    }
}
```

Then in `SiteWindow.swift`'s `loadAndStart`, change the `@State private var preview = PreviewModel()` to a delayed initializer that gets the chat ref:

Actually that won't work — `preview` is a `@State` so its init must be eager. Cleaner approach: expose a setter on `PreviewModel.editRouter`'s observer that `SiteWindow` calls after creating the chat.

Easiest path: don't change `PreviewModel.init`. Instead, expose `MCPApplyEditRouter` initialization at the `SiteWindow` layer:

Look at how `SiteWindow.swift`'s `loadAndStart` currently wires things up. If `preview.editRouter` is created inside `PreviewModel.init` (eagerly), then we need a way to inject the observer after construction. Add a method on `PreviewModel`:

```swift
@MainActor
final class PreviewModel {
    // ... existing properties ...

    /// Set the edit observer after init. Called by SiteWindow once the ChatModel exists.
    /// Subsequent calls replace the prior observer.
    func setEditObserver(_ onEdit: @escaping MCPApplyEditRouter.EditObserver) {
        self.editRouter = MCPApplyEditRouter(
            mcpClient: { [weak session] in
                guard let session else { return nil }
                return await session.mcpClient()
            },
            onEdit: onEdit
        )
    }
}
```

(`editRouter` may need to become `var` instead of `let`; if it's already var, no change needed.)

Then in `SiteWindow.swift`'s `loadAndStart`, after the existing `chat = ChatModel(...)` line, add:

```swift
preview.setEditObserver { [weak chat] reply in
    Task { @MainActor in
        chat?.recordEdit(reply)
    }
}
```

The `[weak chat]` capture prevents a retain cycle; `Task @MainActor` hops onto the main actor so the `@Observable` mutation is on the right isolation.

Also wire `UndoCommand`: when constructing `ChatModel` in `loadAndStart`, pass `undoCommand: UndoCommand(mcpClient: { ... })` using the same `session.mcpClient()` getter:

```swift
let undoCommand = UndoCommand(mcpClient: { [weak session] in
    guard let session else { return nil }
    return await session.mcpClient()
})
chat = ChatModel(
    siteDirectory: resolved.path,
    agent: ClaudeAgent(siteDirectory: resolved.path),
    annotationFeed: feed,
    undoCommand: undoCommand
)
```

(Adapt to whatever the existing `ChatModel` construction looks like — keep its existing arguments, just add the new `undoCommand:` trailing parameter.)

- [ ] **Step 2: Build**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app && xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/PreviewModel.swift
git commit -m "feat(chat): wire MCPApplyEditRouter.onEdit to ChatModel.recordEdit

Phase 9 step 4. SiteWindow.loadAndStart now:

  1. Constructs an UndoCommand bound to the same per-site MCPClient
     getter the editRouter uses, passes it into ChatModel.
  2. After the chat is created, sets the edit observer on PreviewModel
     so every successful applied edit (with a non-nil commit) fires
     ChatModel.recordEdit on the main actor.

PreviewModel grows a setEditObserver(_:) seam that rebuilds the
MCPApplyEditRouter with the new observer attached — avoiding an init-
time dependency between the chat and preview models.

Tracks Anglesite-app#33.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: docs + paired PR

**Files:**
- Modify: `docs/build-plan.md`

- [ ] **Step 1: Mark Phase 9 step 4 ✅ in `docs/build-plan.md`**

Find the line:

```text
4. Undo affordance per edit in the chat panel, backed by the hidden git branch.
```

Replace with:

```text
4. ✅ Per-edit undo (#33). Every successful `apply_edit` surfaces in the chat panel as a `Role.edit` row with file + relative time + an inline Undo button. The button is enabled only on the most-recent unundone row (HEAD-only mode in v1); clicking it invokes the plugin's new `undo_edit` MCP tool, which writes the parent commit's blobs back to disk and advances `refs/heads/anglesite/edits` with a linearized `undo: <files>` commit. When the on-disk file has drifted since the edit (Finder/CLI changes), the undo refuses with `working-tree-modified` and the UI presents a warn-and-confirm sheet whose "Undo anyway" retries with `force: true`. Persistence is append-only — the chat history's JSONL gains a synthetic `{ kind: "undone", messageID, newCommit }` record that `ChatHistoryStore.load()` collapses onto the referenced edit. Phase 9.3 loose-end fix: `EditReply` gains structured `file`/`commit`/`result` fields parsed out of the plugin's content body. Design: [`docs/specs/2026-05-27-edit-undo-design.md`](2026-05-27-edit-undo-design.md).
```

Commit on `main`:

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git add docs/build-plan.md
git commit -m "docs: mark phase-9 step 4 (per-edit undo) complete

Per-edit Undo ships — paired PR pending against Anglesite/anglesite
for the plugin's new undo_edit MCP tool.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 2: Push the plugin branch**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git push -u origin feat/phase-9-edit-undo
```

- [ ] **Step 3: Open the paired PR**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
gh pr create --title "feat(server): undo_edit MCP tool for per-edit chat undo" --body "Paired PR with [Anglesite/Anglesite-app#33](https://github.com/Anglesite/Anglesite-app/issues/33). Delivers Phase 9 step 4 — every successful edit shows up in the chat panel with an inline Undo button.

## What's new

- **server/undo-edit.mjs** — handler that rewinds the most-recent commit on refs/heads/anglesite/edits by writing the parent commit's blobs back to disk and advancing the branch with a new linearized commit ('undo: <files>'). HEAD-only in v1; an optional commit arg must equal current HEAD. force: true skips the working-tree-drift check.
- **server/index.mjs** — registers the undo_edit MCP tool.
- **server/messages.mjs** — four new entries in EDIT_FAILED_REASONS: no-edits-to-undo, head-only-mode, initial-commit, working-tree-modified.

Same defensive-execFile pattern as recordEdit. CAS update-ref so concurrent undos can't silently clobber. Test coverage: 7 cases (happy path, working-tree drift, force override, empty branch, head-only mismatch, commit-matches-head, non-git-repo).

Design doc lives in the app repo: [docs/specs/2026-05-27-edit-undo-design.md](https://github.com/Anglesite/Anglesite-app/blob/main/docs/specs/2026-05-27-edit-undo-design.md).

## Test plan

- [x] npx vitest run — all tests pass (existing + 7 new undo-edit)
- [ ] Manual: launch the app's debug build against a site with at least one edit committed to anglesite/edits, click Undo in the chat panel, verify file reverts on disk + new commit appears on refs/heads/anglesite/edits + Undo button moves to the prior row.

🤖 Generated with [Claude Code](https://claude.com/claude-code)" 2>&1
```

Capture the PR URL from the output.

- [ ] **Step 4: Cross-link from Anglesite-app#33**

```bash
gh issue comment 33 --repo Anglesite/Anglesite-app --body "Paired PR open: <PASTE_URL_FROM_STEP_3>"
```

- [ ] **Step 5: Push the app's commits**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
git push 2>&1 | tail -3
```

---

## Final verification

After all 10 tasks land:

```bash
# Plugin: full test suite
cd /Users/dwk/Developer/github.com/Anglesite/anglesite && npx vitest run

# App: relevant test bundles
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
swift test --package-path . --filter AnglesiteCoreTests
swift test --package-path . --filter AnglesiteBridgeTests

# App: clean build of the macOS app
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
```

Expected: green across all three test suites; clean app build.

Manual smoke (against the refreshed smoke fixture from Phase 9.3's plan, or any git-initialized Anglesite site):

1. Build the plugin branch into the app's bundled plugin: re-run the Xcode build (the pre-build `copy-plugin.sh` script pulls in the new server files).
2. Launch the freshly-built Debug app against the site.
3. Make any edit through the preview (click-to-edit a paragraph, drop an image on an `<img>`). A new chat row appears: *"Edited src/pages/<file>.astro · just now [Undo]"*.
4. Click Undo. The row's button is replaced with "Undone"; the edit reverts in the preview within ~1 second (Astro's file watcher); the chat row before it (if any) gets an enabled Undo button.
5. Check `git log refs/heads/anglesite/edits` in the site — there's a new `undo: <file>` commit on top of the original edit's commit.
6. Modify the file via Finder/VS Code while the chat row's Undo button is still enabled. Click Undo. Sheet appears: *"This file has been modified outside Anglesite since the edit."* with **Cancel** / **Undo anyway**. Cancel → no change. Undo anyway → the Finder edits are overwritten by the parent's blob; chat row marks "Undone".

After merge, close #33 (the paired PR's commit message also has `Closes #33` if desired — or use the GitHub UI).
