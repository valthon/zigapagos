//! `api-gen` / `api-check` — cross-tier typed-client codegen.
//!
//! The codegen `mode` is read from contract/codegen.config.json at configure
//! time (absent/openapi => the OpenAPI path, byte-identical; zigbase => the
//! ZigBase-native path that vendors the backend's own gen-client output).
//!
//! `api-gen` and `api-check` are registered in BOTH arms of the switch below.
//! The arms are mutually exclusive, so the two names are only ever registered
//! once per configure — that is not a duplicate-step bug.

const std = @import("std");

pub fn setup(b: *std.Build) void {
    switch (codegenMode(b)) {
        .openapi => {
            // `apigen`/`api-gen` — regenerate contract/generated from contract/zigbase.openapi.json
            {
                const run_apigen = addApigenRun(b);
                const apigen = b.step("apigen", "Regenerate the typed API client from contract/zigbase.openapi.json");
                apigen.dependOn(&run_apigen.step);
                // `api-gen` alias — the mode-agnostic name shared with zigbase mode.
                b.step("api-gen", "Regenerate the typed API client (mode from contract/codegen.config.json)").dependOn(&run_apigen.step);
            }

            // `api-check` — drift gate: regen then git add + git diff --cached --exit-code
            // Mirrors setupSnapshotTesting's git add / git diff --cached --exit-code pattern.
            // Its own apigen Run step (not the one above): the gate must
            // regenerate on every `api-check`, independently of `apigen`.
            {
                const run_apigen = addApigenRun(b);

                const git_add = b.addSystemCommand(&.{ "git", "add" });
                git_add.addDirectoryArg(b.path("contract/generated"));
                git_add.setName("git add contract/generated");
                git_add.step.dependOn(&run_apigen.step);

                const diff = b.addSystemCommand(&.{
                    "git",
                    "diff",
                    "--cached",
                    "--exit-code",
                });
                diff.addDirectoryArg(b.path("contract/generated"));
                diff.setName("git diff contract/generated");
                diff.step.dependOn(&git_add.step);

                const api_check = b.step("api-check", "Fail if contract/generated is stale vs a fresh apigen");
                api_check.dependOn(&diff.step);
            }
        },
        .zigbase => {
            // ZigBase-native mode: the typed client is the BACKEND's own
            // gen-client output, vendored into the app tree. apiclient.ts drives
            // the backend gen-client + the drift/presence gate (see the script).
            {
                const run_gen = b.addSystemCommand(&.{ "bun", "runtime/scripts/apiclient.ts", "gen" });
                run_gen.has_side_effects = true;
                run_gen.setName("bun apiclient gen");
                b.step("api-gen", "Refresh the vendored ZigBase gen-client output (mode=zigbase)").dependOn(&run_gen.step);
            }
            {
                const run_check = b.addSystemCommand(&.{ "bun", "runtime/scripts/apiclient.ts", "check" });
                run_check.has_side_effects = true;
                run_check.setName("bun apiclient check");
                b.step("api-check", "Fail if the vendored ZigBase client drifts from the backend (mode=zigbase)").dependOn(&run_check.step);
            }
        },
    }
}

fn addApigenRun(b: *std.Build) *std.Build.Step.Run {
    const run_apigen = b.addSystemCommand(&.{
        "bun",
        "runtime/scripts/apigen.ts",
        "--schema",
        "contract/zigbase.openapi.json",
        "--out",
        "contract/generated",
    });
    run_apigen.has_side_effects = true;
    run_apigen.setName("bun apigen");
    return run_apigen;
}

const CodegenMode = enum { openapi, zigbase };

/// Reads the codegen `mode` from contract/codegen.config.json at configure time.
/// Absent / unreadable / unparseable => .openapi (the default; full back-compat,
/// so a repo with no config keeps the exact OpenAPI api-gen/api-check wiring).
fn codegenMode(b: *std.Build) CodegenMode {
    const bytes = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "contract/codegen.config.json",
        b.allocator,
        .limited(64 * 1024),
    ) catch return .openapi;
    const Shape = struct { mode: []const u8 = "openapi" };
    const parsed = std.json.parseFromSliceLeaky(
        Shape,
        b.allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return .openapi;
    if (std.mem.eql(u8, parsed.mode, "zigbase")) return .zigbase;
    return .openapi;
}
