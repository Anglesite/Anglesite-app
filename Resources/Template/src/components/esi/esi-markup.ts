/** Escapes the two characters that matter inside a double-quoted HTML attribute value. */
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
