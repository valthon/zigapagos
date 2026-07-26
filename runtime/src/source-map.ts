// ---------------------------------------------------------------------------
// Source Map v3 consumer — a tiny, self-contained base64-VLQ decoder + mappings
// lookup, used by the observability layer to symbolicate minified stack frames
// against the maps a release build emits alongside each bundle.
//
// Deliberately dependency-free (no `source-map` npm package): the runtime ships
// to the browser, so this is ~120 lines that parse a v3 map and answer
// `originalPositionFor(line, column)`. It is NOT a full spec implementation
// (no index maps / sections) — just the single-map lookup a symbolicator needs.
// See observability.ts for the frame rewriting that consumes it.
// ---------------------------------------------------------------------------

export interface RawSourceMap {
  version: number;
  /** Original source paths; a null entry is allowed by the spec. */
  sources: (string | null)[];
  /** Symbol names referenced by mapping segments' optional 5th field. */
  names?: string[];
  /** The base64-VLQ encoded mappings string. */
  mappings: string;
  /** Optional prefix prepended to every relative `sources` entry. */
  sourceRoot?: string;
  file?: string;
}

export interface OriginalPosition {
  /** Original source path (with `sourceRoot` applied), or null. */
  source: string | null;
  /** 1-based original line. */
  line: number;
  /** 1-based original column. */
  column: number;
  /** Original symbol name, or null when the segment carried none. */
  name: string | null;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64MAP: Record<string, number> = {};
for (let i = 0; i < B64.length; i++) B64MAP[B64[i]] = i;

// Decode a comma-delimited mapping segment (a run of base64 chars) into its
// signed VLQ fields. A single field spans however many chars it needs; the low
// bit of the assembled value is the sign, the rest the magnitude.
export function decodeVlq(segment: string): number[] {
  const out: number[] = [];
  let shift = 0;
  let value = 0;
  for (let i = 0; i < segment.length; i++) {
    const c = B64MAP[segment[i]];
    if (c === undefined) throw new Error(`decodeVlq: invalid base64 char ${JSON.stringify(segment[i])}`);
    const cont = c & 32; // continuation bit
    value += (c & 31) << shift;
    if (cont) {
      shift += 5;
    } else {
      const negate = value & 1;
      value >>>= 1;
      out.push(negate ? -value : value);
      value = 0;
      shift = 0;
    }
  }
  // A dangling shift means the last field's continuation bit was set but no
  // terminating char followed — a truncated/malformed segment that would
  // otherwise silently drop its final field (feeding NaN into lookups).
  if (shift > 0) throw new Error("decodeVlq: truncated VLQ segment (continuation bit set at end)");
  return out;
}

// One decoded segment holds the absolute (de-delta'd) fields for a generated
// position: [genCol] (no source) or [genCol, srcIdx, origLine, origCol]
// (+ optional nameIdx). Kept as a plain number[] to stay allocation-light.
type Segment = number[];

export class SourceMapConsumer {
  readonly sources: (string | null)[];
  readonly names: string[];
  private readonly lines: Segment[][];

  constructor(map: RawSourceMap) {
    const root = map.sourceRoot ?? "";
    this.sources = (map.sources ?? []).map((s) =>
      s == null ? null : root && !/^(?:[a-z]+:)?\/\//i.test(s) ? root.replace(/\/?$/, "/") + s : s,
    );
    this.names = map.names ?? [];
    this.lines = [];

    // Fields carry deltas relative to the previous occurrence: source index,
    // original line, original column and name index persist ACROSS lines; the
    // generated column resets to 0 at the start of every generated line.
    let srcIdx = 0;
    let origLine = 0;
    let origCol = 0;
    let nameIdx = 0;

    for (const group of map.mappings.split(";")) {
      const segs: Segment[] = [];
      let genCol = 0;
      if (group.length > 0) {
        for (const segStr of group.split(",")) {
          if (!segStr) continue;
          const f = decodeVlq(segStr);
          genCol += f[0];
          const seg: Segment = [genCol];
          if (f.length >= 4) {
            srcIdx += f[1];
            origLine += f[2];
            origCol += f[3];
            seg.push(srcIdx, origLine, origCol);
            if (f.length >= 5) {
              nameIdx += f[4];
              seg.push(nameIdx);
            }
          }
          segs.push(seg);
        }
      }
      this.lines.push(segs);
    }
  }

  /**
   * Map a generated position to its original position.
   * @param line   1-based generated line (as browsers report in stacks).
   * @param column 0-based generated column.
   * Returns null when the line has no mappings or the column precedes the first
   * segment / the matched segment carries no source (a generated-only marker).
   */
  originalPositionFor(line: number, column: number): OriginalPosition | null {
    const segs = this.lines[line - 1];
    if (!segs || segs.length === 0) return null;
    // Rightmost segment whose generated column is <= the queried column.
    let lo = 0;
    let hi = segs.length - 1;
    let found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (segs[mid][0] <= column) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found === -1) return null;
    const seg = segs[found];
    if (seg.length < 4) return null; // generated-only marker, no source
    return {
      source: this.sources[seg[1]] ?? null,
      line: seg[2] + 1,
      column: seg[3] + 1,
      name: seg.length >= 5 ? (this.names[seg[4]] ?? null) : null,
    };
  }
}
