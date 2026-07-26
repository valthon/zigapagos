import { describe, test, expect, afterEach } from "bun:test";
import {
  __setServerForTest, setSsrPathname,
  currentPathname, currentSearch, currentHash,
} from "./ssr-env.ts";

afterEach(() => {
  __setServerForTest(undefined);
  setSsrPathname("/");
});

describe("ssr-env location surface (server side)", () => {
  test("currentSearch parses the query out of a query-carrying SSR pathname", () => {
    __setServerForTest(true);
    setSsrPathname("/app/club/1?tab=events");
    expect(currentSearch()).toBe("?tab=events");
  });

  test("currentSearch is empty when the SSR pathname has no query", () => {
    __setServerForTest(true);
    setSsrPathname("/app/club/1");
    expect(currentSearch()).toBe("");
  });

  test("currentHash is always empty on the server (fragments never reach a server)", () => {
    __setServerForTest(true);
    setSsrPathname("/app#section");
    expect(currentHash()).toBe("");
  });

  test("currentPathname strips a query from the SSR pathname (parity with window.location.pathname)", () => {
    __setServerForTest(true);
    setSsrPathname("/app/club/1?tab=events");
    expect(currentPathname()).toBe("/app/club/1");
  });
});

describe("host exposes search/hash", () => {
  test("host.search and host.hash are the ssr-env functions", async () => {
    const { host } = await import("./host.ts");
    __setServerForTest(true);
    setSsrPathname("/p?q=1");
    expect(host.search()).toBe("?q=1");
    expect(host.hash()).toBe("");
  });
});
