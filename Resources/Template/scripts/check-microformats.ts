import { validateDist } from "./microformats.ts";

const distDir = process.argv[2] ?? "dist";
const problems = validateDist(distDir);

if (problems.length > 0) {
  console.error(`✗ microformats validation failed (${problems.length} problem(s)):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("✓ microformats validation passed");
