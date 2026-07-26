// The single home for the "let Preact flush" wait duplicated across the suite
// as setTimeout(r, 5). Drains microtasks, queued macrotasks, and one rAF tick.
export async function flush(): Promise<void> {
  await Promise.resolve();
  await new Promise<void>((r) => setTimeout(r, 0));
  if (typeof requestAnimationFrame === "function") {
    await new Promise<void>((r) => requestAnimationFrame(() => r()));
  }
  await new Promise<void>((r) => setTimeout(r, 0));
}
