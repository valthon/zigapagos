import { test, expect } from "bun:test";
import { serializeDom, diffDom, checkPropSerialization } from "@z/runtime/testing/parity";

function frag(html: string): HTMLElement {
  const d = document.createElement("div");
  d.innerHTML = html;
  return d;
}

test("identical DOM → no diff (attr order + data-z-* ignored)", () => {
  const a = serializeDom(frag('<button class="x" id="b">hi</button>'));
  const b = serializeDom(frag('<button id="b" class="x" data-z-hydrated>hi</button>'));
  expect(diffDom(a, b, "double-render")).toEqual([]);
});

test("text mismatch is reported", () => {
  const a = serializeDom(frag("<time>—</time>"));
  const b = serializeDom(frag("<time>2m ago</time>"));
  const ms = diffDom(a, b, "double-render");
  expect(ms).toHaveLength(1);
  expect(ms[0]).toMatchObject({ kind: "text", ssr: "—", client: "2m ago", source: "double-render" });
});

test("attribute value mismatch is reported", () => {
  const a = serializeDom(frag('<a href="/x">go</a>'));
  const b = serializeDom(frag('<a href="/y">go</a>'));
  expect(diffDom(a, b, "double-render")[0]).toMatchObject({ kind: "attribute" });
});

test("extra/missing node reported as structure", () => {
  const a = serializeDom(frag("<ul><li>1</li></ul>"));
  const b = serializeDom(frag("<ul><li>1</li><li>2</li></ul>"));
  const ms = diffDom(a, b, "hydrate-snapshot");
  expect(ms.some((m) => m.kind === "extra" || m.kind === "structure")).toBe(true);
});

test("ignoreSelectors drops a subtree from both sides", () => {
  const a = serializeDom(frag("<div><time>—</time></div>"), { ignoreSelectors: ["time"] });
  const b = serializeDom(frag("<div><time>2m ago</time></div>"), { ignoreSelectors: ["time"] });
  expect(diffDom(a, b, "double-render")).toEqual([]);
});

test("normalizeWhitespace collapses runs", () => {
  const a = serializeDom(frag("<p>a   b</p>"), { normalizeWhitespace: true });
  const b = serializeDom(frag("<p>a b</p>"), { normalizeWhitespace: true });
  expect(diffDom(a, b, "double-render")).toEqual([]);
});

test("prop-serialization: a Date prop is flagged (lost in JSON round-trip)", () => {
  const ms = checkPropSerialization({ when: new Date(0), ok: "s" });
  expect(ms.some((m) => m.kind === "prop-serialization")).toBe(true);
});

test("prop-serialization: clean JSON props → no finding", () => {
  expect(checkPropSerialization({ a: 1, b: "s", c: [1, 2], d: { e: true } })).toEqual([]);
});
