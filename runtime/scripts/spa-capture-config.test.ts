import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, symlinkSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { captureConfigFiles } from "./spa-capture-config.ts";
import { makeSourceCapture, readSourceCapture } from "./spa-source-capture.ts";

test("capture tracks complete local extends chain and rejects changed deepest config", () => {
  const dir = mkdtempSync(join(tmpdir(), "capture-config-"));
  try {
    const entry = join(dir,"app.ts"), config = join(dir,"tsconfig.json"), middle = join(dir,"middle.json"), base = join(dir,"base.json"), capture = join(dir,"capture.json");
    writeFileSync(entry,"export const value=1;");
    writeFileSync(config,JSON.stringify({extends:"./middle"}));
    writeFileSync(middle,JSON.stringify({extends:"./base.json"}));
    writeFileSync(base,"{}");
    const files = captureConfigFiles(entry,null)!;
    expect(files).toEqual([base,middle,config].map((path) => realpathSync(path)).sort());
    writeFileSync(capture,JSON.stringify(makeSourceCapture(entry,[entry],null,files,true)));
    expect(readSourceCapture(capture,entry,null,files,true)).toEqual([realpathSync(entry)]);
    writeFileSync(base,JSON.stringify({compilerOptions:{jsxImportSource:"other"}}));
    expect(readSourceCapture(capture,entry,null,captureConfigFiles(entry,null)!,true)).toBeNull();
    mkdirSync(join(dir,"elsewhere"));
    writeFileSync(join(dir,"elsewhere","config.json"),"{}");
    symlinkSync(join(dir,"elsewhere","config.json"),join(dir,"linked.json"));
    writeFileSync(config,JSON.stringify({extends:"./linked.json"}));
    expect(captureConfigFiles(entry,null)).toBeNull();
    for (const content of ['{ /* comment */ "extends":"./middle" }', '{"extends":["./middle"]}', '{"extends":"@fixture/config"}', '{"extends":"./absent"}', '{"extends":"./tsconfig.json"}']) {
      writeFileSync(config,content);
      expect(captureConfigFiles(entry,null)).toBeNull();
    }
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
