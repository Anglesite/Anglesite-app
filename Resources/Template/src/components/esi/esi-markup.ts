/**
 * Escapes the two characters that matter inside a double-quoted HTML attribute value — correct
 * and sufficient for a browser parsing this as HTML.
 *
 * Forward-looking caveat: `@dwk/esi`'s edge-side tokenizer doesn't exist as code yet (the design
 * this hinges on emitting exact literal bytes that tokenizer expects). If it ends up being a
 * lightweight/regex-based parser rather than a full HTML parser, an unescaped `>` in `src`/`alt`
 * (e.g. `src="/a>injected"`) could prematurely terminate the tag from that parser's point of view
 * even though it's valid to a browser. Revisit once that tokenizer lands and its actual parsing
 * behavior can be verified against.
 */
export function escapeAttribute(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

export interface EsiIncludeProps {
  src: string;
  alt?: string;
  onerror?: "continue";
}

/** Builds the literal `<esi:include ...></esi:include>` tag `@dwk/esi`'s tokenizer expects. */
export function buildEsiIncludeTag(props: EsiIncludeProps): string {
  let tag = `<esi:include src="${escapeAttribute(props.src)}"`;
  if (props.alt) tag += ` alt="${escapeAttribute(props.alt)}"`;
  if (props.onerror) tag += ` onerror="${escapeAttribute(props.onerror)}"`;
  tag += "></esi:include>";
  return tag;
}

/** Builds the literal `<esi:comment text="…"/>` tag. */
export function buildEsiCommentTag(text: string): string {
  return `<esi:comment text="${escapeAttribute(text)}"/>`;
}
