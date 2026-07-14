import test from "node:test";
import assert from "node:assert/strict";
import { escapeAttribute, buildEsiIncludeTag, buildEsiCommentTag } from "./esi-markup";

test("escapeAttribute escapes & and \"", () => {
  assert.equal(escapeAttribute(`a & b "c"`), `a &amp; b &quot;c&quot;`);
});

test("escapeAttribute leaves plain text untouched", () => {
  assert.equal(escapeAttribute("/fragments/count"), "/fragments/count");
});

test("buildEsiIncludeTag: src only", () => {
  assert.equal(
    buildEsiIncludeTag({ src: "/fragments/count" }),
    `<esi:include src="/fragments/count"></esi:include>`
  );
});

test("buildEsiIncludeTag: src + alt + onerror", () => {
  assert.equal(
    buildEsiIncludeTag({ src: "/a", alt: "/b", onerror: "continue" }),
    `<esi:include src="/a" alt="/b" onerror="continue"></esi:include>`
  );
});

test("buildEsiIncludeTag: escapes quotes and ampersands in attribute values", () => {
  assert.equal(
    buildEsiIncludeTag({ src: '/a?x="y"&z=1' }),
    `<esi:include src="/a?x=&quot;y&quot;&amp;z=1"></esi:include>`
  );
});

test("buildEsiCommentTag", () => {
  assert.equal(
    buildEsiCommentTag(`hello & "world"`),
    `<esi:comment text="hello &amp; &quot;world&quot;"/>`
  );
});
