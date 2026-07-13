import test from "node:test";
import assert from "node:assert/strict";
import { resolveEsiFragments, esiPreviewIsUnprocessed, type EsiFragmentElement, type EsiFragmentDocument } from "./esi-dev-shim";

function makeElement(attrs: Record<string, string>): EsiFragmentElement & { innerHTML: string } {
  const attributes = { ...attrs };
  return {
    getAttribute: (name) => attributes[name] ?? null,
    setAttribute: (name, value) => { attributes[name] = value; },
    hasAttribute: (name) => name in attributes,
    innerHTML: "",
  };
}

test("resolveEsiFragments: fetches src and fills innerHTML on success", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async () => new Response("42", { status: 200 }));
  assert.equal(el.innerHTML, "42");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: falls back to alt once when src fails and no onerror is set", async () => {
  const el = makeElement({ src: "/fragments/count", alt: "/fragments/fallback" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async (url) =>
    url === "/fragments/count" ? new Response("", { status: 500 }) : new Response("fallback-text", { status: 200 })
  );
  assert.equal(el.innerHTML, "fallback-text");
});

test("resolveEsiFragments: onerror=continue drops silently, never tries alt", async () => {
  const el = makeElement({ src: "/fragments/count", alt: "/fragments/fallback", onerror: "continue" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let altCalled = false;
  await resolveEsiFragments(doc, async (url) => {
    if (url === "/fragments/fallback") altCalled = true;
    return new Response("", { status: 500 });
  });
  assert.equal(el.innerHTML, "");
  assert.equal(altCalled, false);
});

test("resolveEsiFragments: no alt and src fails leaves the element empty", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async () => new Response("", { status: 500 }));
  assert.equal(el.innerHTML, "");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: skips elements already marked resolved", async () => {
  const el = makeElement({ src: "/fragments/count", "data-esi-dev-resolved": "true" });
  el.innerHTML = "cached";
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let called = false;
  await resolveEsiFragments(doc, async () => {
    called = true;
    return new Response("42");
  });
  assert.equal(called, false);
  assert.equal(el.innerHTML, "cached");
});

test("resolveEsiFragments: no src attribute marks resolved without fetching", async () => {
  const el = makeElement({});
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let called = false;
  await assert.doesNotReject(
    resolveEsiFragments(doc, async () => {
      called = true;
      return new Response("42");
    })
  );
  assert.equal(called, false);
  assert.equal(el.innerHTML, "");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: fetchImpl throwing leaves the element empty and resolved", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async () => {
    throw new Error("network down");
  });
  assert.equal(el.innerHTML, "");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: passes an AbortSignal to fetchImpl, so a hanging fetch can be timed out", async () => {
  const el = makeElement({ src: "/fragments/count", alt: "/fragments/fallback" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let receivedSignal: AbortSignal | undefined;
  await resolveEsiFragments(doc, async (url, signal) => {
    if (url === "/fragments/count") {
      receivedSignal = signal;
      // Simulates AbortSignal.timeout() firing: fetch rejects once its signal aborts.
      throw new Error("simulated timeout abort");
    }
    return new Response("fallback-text", { status: 200 });
  });
  assert.ok(receivedSignal instanceof AbortSignal, "fetchImpl must receive a real AbortSignal");
  // A timed-out src falls through to alt exactly like any other failure.
  assert.equal(el.innerHTML, "fallback-text");
});

test("resolveEsiFragments: two concurrent invocations on the same element only fetch once", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let fetchCount = 0;
  const fetchImpl = async () => {
    fetchCount++;
    return new Response("42", { status: 200 });
  };
  // Two script instances resolving the same page in the same tick (e.g. two EsiInclude
  // components, if Astro doesn't dedupe the client script) must not both fire a fetch for the
  // same element — RESOLVED_ATTR is claimed synchronously before either awaits.
  const first = resolveEsiFragments(doc, fetchImpl);
  const second = resolveEsiFragments(doc, fetchImpl);
  await Promise.all([first, second]);
  assert.equal(fetchCount, 1);
  assert.equal(el.innerHTML, "42");
});

test("esiPreviewIsUnprocessed: true only for ?esiPreview=unprocessed", () => {
  assert.equal(esiPreviewIsUnprocessed("?esiPreview=unprocessed"), true);
  assert.equal(esiPreviewIsUnprocessed(""), false);
  assert.equal(esiPreviewIsUnprocessed("?esiPreview=live"), false);
  assert.equal(esiPreviewIsUnprocessed("?other=1&esiPreview=unprocessed"), true);
});
