// Resources/Template/src/components/esi/esi-components.build.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, writeFile, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — three `..` up from src/components/esi/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

test("EsiInclude/EsiComment/EsiRemove survive an astro build byte-for-byte", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-esi-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });

    const fixturePage = `---
import EsiInclude from "../components/esi/EsiInclude.astro";
import EsiComment from "../components/esi/EsiComment.astro";
import EsiRemove from "../components/esi/EsiRemove.astro";
---
<EsiInclude src="/fragments/count" alt="/fragments/count-fallback" onerror="continue" />
<EsiComment text="build fixture" />
<EsiRemove><span class="fallback">—</span></EsiRemove>
`;
    await writeFile(join(fixtureDir, "src/pages/esi-build-fixture.astro"), fixturePage, "utf8");

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/esi-build-fixture/index.html"), "utf8");

    assert.match(
      html,
      /<esi:include src="\/fragments\/count" alt="\/fragments\/count-fallback" onerror="continue"><\/esi:include>/
    );
    assert.match(html, /<esi:comment text="build fixture"\/>/);
    assert.match(html, /<esi:remove><span class="fallback">—<\/span><\/esi:remove>/);

    // The dev-only fetch shim must not ship to production at all — not just be inert. `index.html`
    // alone isn't enough: Astro hoists client <script> blocks into separately bundled
    // `dist/_astro/*.js` chunks, so a leaked shim could land there even with no trace in the page
    // HTML. Walk the whole `dist/` tree.
    const distFiles = await readdir(join(fixtureDir, "dist"), { recursive: true, withFileTypes: true });
    for (const entry of distFiles) {
      if (!entry.isFile()) continue;
      const filePath = join(entry.parentPath, entry.name);
      const contents = await readFile(filePath, "utf8").catch(() => "");
      assert.ok(
        !contents.includes("resolveEsiFragments"),
        `dev shim script leaked into production build: ${filePath}`
      );
    }
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
