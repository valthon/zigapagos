import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { makeSourceCapture, readSourceCapture } from "./spa-source-capture.ts";

test("source capture accepts current graph and rejects changed inputs or identity", () => {
  const dir = mkdtempSync(join(tmpdir(), "spa-capture-"));
  try {
    const entry = join(dir,"app.ts"), dependency = join(dir,"dependency.ts"), config = join(dir,"config.json"), tsconfig = join(dir,"tsconfig.json"), file = join(dir,"capture.json");
    writeFileSync(entry,"import './dependency';"); writeFileSync(dependency,"export const value=1;");
    writeFileSync(config,"{}"); writeFileSync(tsconfig,"{}");
    const capture = makeSourceCapture(entry,[entry,dependency],config,[config,tsconfig],true);
    writeFileSync(file,JSON.stringify(capture));
    expect(readSourceCapture(file,entry,config,[config,tsconfig],true)).toEqual([entry,dependency].map((path) => realpathSync(path)));
    expect(readSourceCapture(file,entry,config,[config,tsconfig],false)).toBeNull();
    expect(readSourceCapture(file,dependency,config,[config,tsconfig],true)).toBeNull();
    expect(readSourceCapture(file,entry,undefined,[tsconfig],true)).toBeNull();
    for (const input of [entry,dependency,config,tsconfig]) {
      // Keep the fixture bytes explicit; every identity-bearing input must be checked.
      const old = readFileSync(input);
      writeFileSync(input,"changed");
      expect(readSourceCapture(file,entry,config,[config,tsconfig],true)).toBeNull();
      writeFileSync(input,old);
    }
    expect(readSourceCapture(file,entry,config,[config,tsconfig,"new-tsconfig.json"],true)).toBeNull();
    writeFileSync(file,JSON.stringify({...capture,inputs:[]}));
    expect(readSourceCapture(file,entry,config,[config,tsconfig],true)).toBeNull();
    writeFileSync(file,"invalid JSON");
    expect(readSourceCapture(file,entry,config,[config,tsconfig],true)).toBeNull();
    rmSync(dependency);
    expect(makeSourceCapture(entry,[entry,dependency],config,[config,tsconfig],true)).toBeNull();
    rmSync(file);
    expect(readSourceCapture(file,entry,config,[config,tsconfig],true)).toBeNull();
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
