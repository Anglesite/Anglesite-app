/**
 * Whether Keystatic's admin UI (`react()`/`keystatic()` integrations) should be registered for
 * this Astro CLI invocation. Only true for the `astro dev` subcommand — checking `argv[2]`
 * specifically (not scanning the whole array) matters: `astro build --mode dev` is a legitimate
 * command that puts `"dev"` in argv as the `--mode` value, not the subcommand, and a whole-array
 * scan would false-positive on it, shipping Keystatic into a production build.
 */
export function isKeystaticDev(argv: readonly string[]): boolean {
  return argv[2] === "dev";
}
