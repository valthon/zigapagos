import { test, expect } from "bun:test";
import {
  setSsrPathname, getSsrPathname, currentPathname, currentSearch, currentHash,
  isServer, __setServerForTest,
} from "@z/runtime/ssr-env";
import { host } from "@z/runtime/host";

test("ssr pathname defaults to / and is settable", () => {
  expect(getSsrPathname()).toBe("/");
  setSsrPathname("/booking/");
  expect(getSsrPathname()).toBe("/booking/");
  setSsrPathname("/"); // reset
});

test("currentPathname uses window.location on the client", () => {
  // happy-dom provides window; default location pathname is "/".
  expect(isServer()).toBe(false);
  expect(currentPathname()).toBe(window.location.pathname);
});

test("currentSearch uses window.location.search on the client", () => {
  window.history.replaceState(null, "", "/booking/?q=1&n=2");
  expect(isServer()).toBe(false);
  expect(currentSearch()).toBe(window.location.search);
  expect(currentSearch()).toBe("?q=1&n=2");
  window.history.replaceState(null, "", "/"); // reset
});

test("currentHash uses window.location.hash on the client", () => {
  window.history.replaceState(null, "", "/booking#section");
  expect(isServer()).toBe(false);
  expect(currentHash()).toBe(window.location.hash);
  expect(currentHash()).toBe("#section");
  window.history.replaceState(null, "", "/"); // reset
});

test("__setServerForTest(true) flips the server branch on the real host", () => {
  expect(isServer()).toBe(false); // happy-dom registered → client by default
  __setServerForTest(true);
  try {
    expect(isServer()).toBe(true);
    expect(host.now()).toBe(0);                 // server clock baseline
    expect(host.cookies.get("anything")).toBe(""); // server cookies no-op
    expect(host.recaptchaToken()).toBe("");
  } finally {
    __setServerForTest(undefined);
  }
  expect(isServer()).toBe(false); // restored
});
