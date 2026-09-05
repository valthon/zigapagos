import { expect, test } from "bun:test";
// This cross-package import brings the embedded template into runtime's tsc
// graph; moving/removing this test must preserve that type-check coverage.
// runtime/test supplies the happy-dom preload used by these DOM fixtures.
import { bindActions, targetsOf } from "../../src/cli/rails/stimulus.ts";

function fixture(html: string) {
  const root = document.createElement("div");
  root.innerHTML = html;
  document.body.append(root);
  return root;
}

test("Rails actions work without Object.hasOwn and reject inherited handlers", () => {
  // Consumer browsers may lack Object.hasOwn; the generated helper must not
  // depend on that global or on a consumer adding a polyfill for it.
  const root = fixture('<div data-controller="modal"><button data-action="click->modal#click click->modal#inherited"></button></div>');
  let clicks = 0, inherited = 0;
  const handlers = Object.assign(Object.create({ inherited: () => inherited++ }), { click: () => clicks++ });
  const original = Object.getOwnPropertyDescriptor(Object, "hasOwn")!;
  let dispose: (() => void) | undefined;
  try {
    Object.defineProperty(Object, "hasOwn", { ...original, value: undefined });
    dispose = bindActions(root, "modal", handlers);
    root.querySelector("button")!.dispatchEvent(new MouseEvent("click"));
    expect(clicks).toBe(1);
    expect(inherited).toBe(0);
  } finally {
    Object.defineProperty(Object, "hasOwn", original);
    dispose?.();
    root.remove();
  }
});

test("Rails action filters/global targets fire selectively and clean up", () => {
  const root = fixture('<div data-controller="modal" data-action="keydown.ctrl+a@document->modal#select resize@window->modal#resize"></div>');
  let selected = 0, resized = 0;
  const dispose = bindActions(root, "modal", { select: () => selected++, resize: () => resized++ });
  try {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "a" }));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true }));
    expect(selected).toBe(0);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "A", ctrlKey: true }));
    window.dispatchEvent(new Event("resize"));
    expect(selected).toBe(1);
    expect(resized).toBe(1);
    dispose();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "a", ctrlKey: true }));
    window.dispatchEvent(new Event("resize"));
    expect(selected).toBe(1);
    expect(resized).toBe(1);
  } finally { dispose(); root.remove(); }
});

test("Rails action native options, self filter and default events are preserved", () => {
  const root = fixture('<div data-controller="modal"><button data-action="click->modal#click:self:prevent:capture"><span>child</span></button><input type="submit" data-action="modal#submit:once"><details data-action="modal#toggle"></details></div>');
  let clicks = 0, submits = 0, toggles = 0;
  const dispose = bindActions(root, "modal", { click: () => clicks++, submit: () => submits++, toggle: () => toggles++ });
  try {
    root.querySelector("span")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(clicks).toBe(0);
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    root.querySelector("button")!.dispatchEvent(click);
    expect(clicks).toBe(1);
    expect(click.defaultPrevented).toBe(true);
    root.querySelector("input")!.dispatchEvent(new MouseEvent("click"));
    root.querySelector("input")!.dispatchEvent(new MouseEvent("click"));
    expect(submits).toBe(1);
    root.querySelector("details")!.dispatchEvent(new Event("toggle"));
    expect(toggles).toBe(1);
    dispose();
    root.querySelector("button")!.dispatchEvent(new MouseEvent("click"));
    expect(clicks).toBe(1); // capture listener was removed with matching options
  } finally { dispose(); root.remove(); }
});

test("Rails outer controllers do not bind a nested controller's actions or targets", () => {
  const root = fixture('<div data-controller="modal"><button data-action="modal#click" data-modal-target="button"></button><div data-controller="modal"><button data-action="modal#click" data-modal-target="button"></button></div></div>');
  let clicks = 0;
  const dispose = bindActions(root, "modal", { click: () => clicks++ });
  try {
    expect(targetsOf(root, "modal", ["button"]).button.length).toBe(1);
    for (const el of root.querySelectorAll("button")) el.dispatchEvent(new MouseEvent("click"));
    expect(clicks).toBe(1);
  } finally { dispose(); root.remove(); }
});
