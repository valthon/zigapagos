import { expect, test, describe } from "bun:test";
import { decodeVlq, SourceMapConsumer, type RawSourceMap } from "./source-map.ts";

// Base64-VLQ encode a single signed integer (test helper; mirrors the spec).
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function encodeVlq(value: number): string {
  let vlq = value < 0 ? (-value << 1) | 1 : value << 1;
  let out = "";
  do {
    let digit = vlq & 31;
    vlq >>>= 5;
    if (vlq > 0) digit |= 32;
    out += B64[digit];
  } while (vlq > 0);
  return out;
}
const encodeSeg = (fields: number[]): string => fields.map(encodeVlq).join("");

describe("decodeVlq", () => {
  test("round-trips signed integers", () => {
    for (const n of [0, 1, -1, 15, 16, -16, 100, -100, 12345, -98765]) {
      expect(decodeVlq(encodeVlq(n))).toEqual([n]);
    }
  });

  test("decodes a multi-field segment", () => {
    expect(decodeVlq(encodeSeg([0, 0, 5, 3]))).toEqual([0, 0, 5, 3]);
    expect(decodeVlq(encodeSeg([2, 1, -1, 4, 0]))).toEqual([2, 1, -1, 4, 0]);
  });

  test("throws on an invalid base64 char", () => {
    expect(() => decodeVlq("A!B")).toThrow(/invalid base64 char/);
  });

  test("throws on a truncated segment (dangling continuation bit)", () => {
    // A multi-char VLQ minus its terminating char leaves the continuation bit
    // set at the end — silently dropping the field would feed NaN into lookups.
    const truncated = encodeVlq(12345).slice(0, -1);
    expect(truncated.length).toBeGreaterThan(0);
    expect(() => decodeVlq(truncated)).toThrow(/truncated VLQ segment/);
  });
});

describe("SourceMapConsumer.originalPositionFor", () => {
  // Generated line 1 with two segments:
  //   genCol 0 -> src0 line1(idx0) col1(idx0) name0
  //   genCol 8 -> src0 line3(idx2) col5(idx4) name1
  // Generated line 2 with one segment:
  //   genCol 0 -> src1 line10 col0
  const map: RawSourceMap = {
    version: 3,
    sources: ["a.ts", "b.ts"],
    names: ["foo", "bar"],
    mappings: [
      [encodeSeg([0, 0, 0, 0, 0]), encodeSeg([8, 0, 2, 4, 1])].join(","),
      encodeSeg([0, 1, 9, 0]), // srcIdx delta +1 (=>1), origLine delta +9 (0-based idx0 was 2, +9=... see below)
    ].join(";"),
  };

  test("maps a column to the nearest preceding segment", () => {
    const c = new SourceMapConsumer(map);
    // line 1, generated col 0 -> a.ts:1:1 name foo
    expect(c.originalPositionFor(1, 0)).toEqual({ source: "a.ts", line: 1, column: 1, name: "foo" });
    // col 5 still falls in the first segment (< 8)
    expect(c.originalPositionFor(1, 5)).toEqual({ source: "a.ts", line: 1, column: 1, name: "foo" });
    // col 8 hits the second segment: origLine delta 0->2 (idx2 => line 3), col idx 0->4 => col 5, name bar
    expect(c.originalPositionFor(1, 8)).toEqual({ source: "a.ts", line: 3, column: 5, name: "bar" });
    expect(c.originalPositionFor(1, 100)).toEqual({ source: "a.ts", line: 3, column: 5, name: "bar" });
  });

  test("cross-line deltas accumulate (source/line/col persist across lines)", () => {
    const c = new SourceMapConsumer(map);
    // line 2 seg: srcIdx +1 => index 1 (b.ts); origLine +9 from idx2 => idx11 => line 12; col idx4 +0 => 4 => col 5
    expect(c.originalPositionFor(2, 0)).toEqual({ source: "b.ts", line: 12, column: 5, name: null });
  });

  test("returns null for an out-of-range line or an unmapped column", () => {
    const c = new SourceMapConsumer(map);
    expect(c.originalPositionFor(99, 0)).toBeNull();
    // A generated-only segment (1 field) yields no source.
    const gen: RawSourceMap = { version: 3, sources: ["x.ts"], mappings: encodeSeg([4]) };
    expect(new SourceMapConsumer(gen).originalPositionFor(1, 4)).toBeNull();
    // A column before the first segment.
    expect(new SourceMapConsumer(gen).originalPositionFor(1, 0)).toBeNull();
  });

  test("applies sourceRoot to relative sources but leaves absolute/URL ones", () => {
    const m: RawSourceMap = {
      version: 3,
      sourceRoot: "https://cdn/src",
      sources: ["a.ts", "https://other/b.ts"],
      mappings: [encodeSeg([0, 0, 0, 0]), encodeSeg([0, 1, 0, 0])].join(";"),
    };
    const c = new SourceMapConsumer(m);
    expect(c.originalPositionFor(1, 0)?.source).toBe("https://cdn/src/a.ts");
    expect(c.originalPositionFor(2, 0)?.source).toBe("https://other/b.ts");
  });
});
