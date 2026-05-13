// CSS-selector computation for the JS → native edit bridge.
//
// First-cut strategy: walk the parent chain producing `tag` segments, disambiguating siblings
// of the same tag with `:nth-of-type(N)`. Stable enough for a first cut; #18 will pick the
// final strategy (CSS selector vs. server-resolved data attribute) once Phase 5 lands the
// source patcher and we know which side has the better view of stability.

export function cssSelectorFor(element: Element): string {
  // Detached or root: the tag alone is the best we can do.
  if (element === element.ownerDocument?.documentElement) return "html";
  const parent = element.parentElement;
  if (!parent) return element.tagName.toLowerCase();

  const tag = element.tagName.toLowerCase();
  const sameTagSiblings = Array.from(parent.children).filter((c) => c.tagName === element.tagName);
  const segment = sameTagSiblings.length > 1
    ? `${tag}:nth-of-type(${sameTagSiblings.indexOf(element) + 1})`
    : tag;

  return `${cssSelectorFor(parent)} > ${segment}`;
}
