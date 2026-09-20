const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.init);

pub fn init(io: Io, gpa: Allocator, args: []const []const u8, environ_map: *const std.process.Environ.Map) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--from-astro")) {
        for (args) |option| if (std.mem.eql(u8, option, "--minimal") or std.mem.eql(u8, option, "--app")) {
            fatal.usageError("error: `init --minimal` or `--app` cannot be combined with `--from-astro`\n", .{});
        };
        return @import("init_from_astro.zig").run(io, gpa, args);
    };

    const cmd: Command = .parse(args);
    if (cmd.app and (cmd.minimal or cmd.multilingual)) fatal.usageError("error: `init --app` cannot be combined with `--minimal` or `--multilingual`\n", .{});
    if (cmd.runtime_path != null and !cmd.app) fatal.usageError("error: --runtime-path requires --app (or --from-astro)\n", .{});
    if (cmd.minimal and cmd.multilingual) fatal.usageError(
        "error: `init --minimal` cannot be combined with `--multilingual`\n",
        .{},
    );
    if (cmd.multilingual) fatal.usageError(
        "error: `init --multilingual` is not implemented yet\n",
        .{},
    );

    const app_package: ?[]const u8 = if (cmd.app) appPackage(io, gpa, cmd.runtime_path, environ_map.get("ZIGAPAGOS_RUNTIME_DIR")) else null;
    defer if (app_package) |data| gpa.free(data);

    const File = struct { path: []const u8, src: []const u8 };
    const files = [_]File{
        .{
            .path = "AGENTS.md",
            .src = if (cmd.app) @embedFile("init/app/AGENTS.md") else @embedFile("init/AGENTS.md"),
        },
        .{
            .path = "CLAUDE.md",
            .src = @embedFile("init/CLAUDE.md"),
        },
        .{
            .path = "zigapagos.ziggy",
            .src = if (cmd.minimal or cmd.app) @embedFile("init/minimal/zigapagos.ziggy") else @embedFile("init/zigapagos.ziggy"),
        },
        .{
            // Plain `init` previously wrote no `.gitignore` at all, so
            // `.zigapagos-cache/` (the image-optimization derive cache, #132)
            // was untracked-but-unignored on a fresh scaffold. Reuse
            // `init_from_astro`'s template and add this command's default
            // output directory and local development server state.
            .path = ".gitignore",
            .src = "public/\n.zigbase/\n" ++ comptime @import("init_from_astro.zig").emitGitignore(),
        },
    };
    const minimal_files = [_]File{
        .{ .path = "content/index.smd", .src = @embedFile("init/minimal/index.smd") },
        .{ .path = "layouts/page.shtml", .src = @embedFile("init/minimal/page.shtml") },
        .{ .path = "assets/style.css", .src = @embedFile("init/minimal/style.css") },
    };
    const app_files = [_]File{
        .{ .path = "content/index.smd", .src = @embedFile("init/app/index.smd") },
        .{ .path = "layouts/page.shtml", .src = @embedFile("init/app/page.shtml") },
        .{ .path = "assets/style.css", .src = @embedFile("init/app/style.css") },
        .{ .path = "app/app.spa.tsx", .src = @embedFile("init/app/app.spa.tsx") },
        .{ .path = "app/store.ts", .src = @embedFile("init/app/store.ts") },
        .{ .path = "app/storage.ts", .src = @embedFile("init/app/storage.ts") },
        .{ .path = "scripts/cli.ts", .src = @embedFile("init/app/cli.ts") },
        .{ .path = "tsconfig.json", .src = @embedFile("init/app/tsconfig.json") },
        .{ .path = "README.md", .src = @embedFile("init/app/README.md") },
        .{ .path = "package.json", .src = app_package orelse "" },
    };
    const sample_files = [_]File{
        .{
            .path = "content/index.smd",
            .src = @embedFile("init/content/index.smd"),
        },
        .{
            .path = "content/about.smd",
            .src = @embedFile("init/content/about.smd"),
        },
        .{
            .path = "content/blog/index.smd",
            .src = @embedFile("init/content/blog/index.smd"),
        },
        .{
            .path = "content/blog/first-post/index.smd",
            .src = @embedFile("init/content/blog/first-post/index.smd"),
        },
        .{
            .path = "content/blog/first-post/retro-cover.jpg",
            .src = @embedFile("init/content/blog/first-post/retro-cover.jpg"),
        },
        .{
            .path = "content/blog/second-post.smd",
            .src = @embedFile("init/content/blog/second-post.smd"),
        },
        .{
            .path = "content/blog/code-blocks.smd",
            .src = @embedFile("init/content/blog/code-blocks.smd"),
        },
        .{
            .path = "content/devlog/index.smd",
            .src = @embedFile("init/content/devlog/index.smd"),
        },
        .{
            .path = "content/devlog/1990.smd",
            .src = @embedFile("init/content/devlog/1990.smd"),
        },
        .{
            .path = "content/devlog/1989.smd",
            .src = @embedFile("init/content/devlog/1989.smd"),
        },
        .{
            .path = "layouts/index.shtml",
            .src = @embedFile("init/layouts/index.shtml"),
        },
        .{
            .path = "layouts/page.shtml",
            .src = @embedFile("init/layouts/page.shtml"),
        },
        .{
            .path = "layouts/post.shtml",
            .src = @embedFile("init/layouts/post.shtml"),
        },
        .{
            .path = "layouts/blog.shtml",
            .src = @embedFile("init/layouts/blog.shtml"),
        },
        .{
            .path = "layouts/blog.xml",
            .src = @embedFile("init/layouts/blog.xml"),
        },
        .{
            .path = "layouts/devlog.shtml",
            .src = @embedFile("init/layouts/devlog.shtml"),
        },
        .{
            .path = "layouts/devlog.xml",
            .src = @embedFile("init/layouts/devlog.xml"),
        },
        .{
            .path = "layouts/devlog-archive.shtml",
            .src = @embedFile("init/layouts/devlog-archive.shtml"),
        },
        .{
            .path = "layouts/templates/base.shtml",
            .src = @embedFile("init/layouts/templates/base.shtml"),
        },
        .{
            .path = "assets/style.css",
            .src = @embedFile("init/assets/style.css"),
        },
        .{
            .path = "assets/highlight.css",
            .src = @embedFile("init/assets/highlight.css"),
        },
        .{
            .path = "assets/under-construction.gif",
            .src = @embedFile("init/assets/under-construction.gif"),
        },

        .{
            .path = "assets/render-mathtex.js",
            .src = @embedFile("init/assets/render-mathtex.js"),
        },
        .{
            .path = "assets/Temml-Local.css",
            .src = @embedFile("init/assets/Temml-Local.css"),
        },
        .{
            .path = "assets/Temml.woff2",
            .src = @embedFile("init/assets/Temml.woff2"),
        },
        .{
            .path = "assets/temml.min.js",
            .src = @embedFile("init/assets/temml.min.js"),
        },
    };

    for ([_][]const File{ &files, if (cmd.app) &app_files else if (cmd.minimal) &minimal_files else &sample_files }) |group| {
        for (group) |file| {
            const dirname = std.fs.path.dirnamePosix(file.path);
            const basename = std.fs.path.basenamePosix(file.path);

            const base_dir = if (dirname) |dn|
                Io.Dir.cwd().createDirPathOpen(io, dn, .{}) catch |err| fatal.dir(dn, err)
            else
                Io.Dir.cwd();

            defer if (dirname != null) base_dir.close(io);

            const f = base_dir.createFile(io, basename, .{
                .exclusive = true,
            }) catch |err| switch (err) {
                else => fatal.file(basename, err),
                error.PathAlreadyExists => {
                    std.debug.print(
                        "WARNING: '{s}' already exists, skipping.\n",
                        .{file.path},
                    );
                    continue;
                },
            };
            defer f.close(io);
            std.debug.print("Created: {s}\n", .{file.path});
            var file_writer = f.writer(io, &.{});
            file_writer.interface.writeAll(file.src) catch |err| fatal.file(file.path, err);
        }
    }

    if (cmd.app) {
        std.debug.print("\nRun `bun install`, `bun run check`, then `bun run build`.\nSee README.md for runtime linkage, browser-local storage, and deployment.\n", .{});
        return false;
    }

    std.debug.print(
        \\
        \\Run `zigapagos dev` to build your site and serve it locally,
        \\rebuilding as you edit.
        \\Run `zigapagos release` to build your website in 'public/'.
        \\Run `zigapagos help` for more commands and options.
        \\
        \\Read https://github.com/valthon/zigapagos/tree/main/docs to learn more about Zigapagos.
        \\
    , .{});

    return false;
}

const Command = struct {
    multilingual: bool,
    minimal: bool,
    app: bool,
    runtime_path: ?[]const u8,
    fn parse(args: []const []const u8) Command {
        var multilingual = false;
        var minimal = false;
        var app = false;
        var runtime_path: ?[]const u8 = null;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--multilingual")) {
                multilingual = true;
            } else if (std.mem.eql(u8, a, "--minimal")) {
                minimal = true;
            } else if (std.mem.eql(u8, a, "--app")) {
                app = true;
            } else if (std.mem.startsWith(u8, a, "--runtime-path=")) {
                runtime_path = a[15..];
                if (runtime_path.?.len == 0) fatal.usageError("error: --runtime-path needs a directory\n", .{});
            } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
                fatal.usage(
                    \\Usage: zigapagos init [OPTIONS]
                    \\
                    \\Command specific options:
                    \\  --app            Start a browser-local SPA with forms and async states
                    \\  --runtime-path=DIR  Runtime sources for --app (npm launcher supplies default)
                    \\  --minimal        Start with one page, an HTML layout, and plain CSS
                    \\  --multilingual   Setup a sample multilingual website
                    \\                   (not implemented yet)
                    \\
                    \\General Options:
                    \\  --help, -h       Print command specific usage
                    \\
                    \\
                , .{});
            } else {
                fatal.usageError("error: unknown init option: {s}\n", .{a});
            }
        }

        return .{ .multilingual = multilingual, .minimal = minimal, .app = app, .runtime_path = runtime_path };
    }
};

/// Self-freeing scratch; caller owns and frees the single returned JSON buffer.
/// Explicit relative runtime links stay relative;
/// environment-derived links are made relative to this project and disclosed.
fn appPackage(io: Io, gpa: Allocator, explicit_path: ?[]const u8, env_path: ?[]const u8) []const u8 {
    const runtime = explicit_path orelse env_path orelse fatal.usageError("error: --app needs --runtime-path=DIR or the npm launcher's ZIGAPAGOS_RUNTIME_DIR\n", .{});
    var dir = Io.Dir.cwd().openDir(io, runtime, .{}) catch |err| fatal.dir(runtime, err);
    defer dir.close(io);
    const manifest_stat = dir.statFile(io, "package.json", .{ .follow_symlinks = true }) catch |err| fatal.usageError("error: application runtime needs package.json: {t}\n", .{err});
    if (manifest_stat.kind != .file) fatal.usageError("error: runtime package.json must be a regular file\n", .{});
    const manifest_bytes = dir.readFileAlloc(io, "package.json", gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        else => fatal.usageError("error: cannot read runtime package.json: {t}\n", .{err}),
    };
    defer gpa.free(manifest_bytes);
    const manifest = std.json.parseFromSlice(std.json.Value, gpa, manifest_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        else => fatal.usageError("error: invalid runtime package.json: {t}\n", .{err}),
    };
    defer manifest.deinit();
    if (manifest.value != .object) fatal.usageError("error: runtime package.json must be an object\n", .{});
    const name = manifest.value.object.get("name") orelse fatal.usageError("error: runtime package.json needs a package name\n", .{});
    if (name != .string or name.string.len == 0) fatal.usageError("error: runtime package.json name must be a nonempty string\n", .{});
    if (manifest.value.object.get("type")) |kind| {
        if (kind != .string or (!std.mem.eql(u8, kind.string, "module") and !std.mem.eql(u8, kind.string, "commonjs"))) fatal.usageError("error: runtime package.json type must be module or commonjs\n", .{});
    }
    for ([_][]const u8{ "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" }) |field| {
        if (manifest.value.object.get(field)) |dependencies| {
            if (dependencies != .object) fatal.usageError("error: runtime package.json {s} must be an object\n", .{field});
            for (dependencies.object.values()) |version| {
                if (version != .string or version.string.len == 0) fatal.usageError("error: runtime package.json {s} values must be nonempty strings\n", .{field});
            }
        }
    }
    // These are installed runtime dependencies, not authoring-only tools.
    const dependencies = manifest.value.object.get("dependencies") orelse fatal.usageError("error: runtime package.json needs dependencies for preact and preact-render-to-string\n", .{});
    for ([_][]const u8{ "preact", "preact-render-to-string" }) |dependency_name| {
        if (!dependencies.object.contains(dependency_name)) fatal.usageError("error: runtime package.json dependencies needs {s}\n", .{dependency_name});
    }
    const exports = manifest.value.object.get("exports") orelse fatal.usageError("error: runtime package.json needs root and jsx-runtime exports\n", .{});
    if (exports != .object) fatal.usageError("error: runtime package.json exports must expose . and ./jsx-runtime\n", .{});
    for ([_][]const u8{ ".", "./jsx-runtime" }) |subpath| {
        const target = exports.object.get(subpath) orelse fatal.usageError("error: runtime package.json exports needs {s}\n", .{subpath});
        // The starter imports both subpaths during Bun SSR, browser bundling,
        // and TypeScript checking. Respect condition order in each context.
        for ([_][]const []const u8{ &.{ "bun", "node", "import", "default" }, &.{ "browser", "import", "default" }, &.{ "types", "import", "default" } }) |conditions| {
            const path = appExportTarget(target, conditions, 0) orelse fatal.usageError("error: runtime package.json export {s} needs an importable target\n", .{subpath});
            if (!std.mem.startsWith(u8, path, "./")) fatal.usageError("error: runtime package.json export {s} must target a local ./ file\n", .{subpath});
            const decoded = gpa.dupe(u8, path) catch fatal.oom();
            defer gpa.free(decoded);
            const file_path = appExportPath(decoded) orelse fatal.usageError("error: runtime package.json export {s} has an invalid package target\n", .{subpath});
            appRuntimeFile(io, dir, file_path);
        }
    }
    // Fixed entry points consumed by release/dev. This is a preflight of the
    // app toolchain contract, not a recursive JavaScript dependency audit.
    for ([_][]const u8{
        "src/index.ts",             "src/jsx-runtime.ts",           "src/spa-entry.ts",
        "src/browser-entry.ts",     "src/host.ts",                  "src/ssr-env.ts",
        "sidecar/standalone.ts",    "sidecar/render.ts",            "sidecar/bundle-standalone.ts",
        "sidecar/bundle-island.ts", "scripts/build-spa-runtime.ts", "scripts/emit-host-config.ts",
    }) |path| appRuntimeFile(io, dir, path);
    const cwd = Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch |err| fatal.dir(".", err);
    defer gpa.free(cwd);
    const absolute = Io.Dir.cwd().realPathFileAlloc(io, runtime, gpa) catch |err| fatal.dir(runtime, err);
    defer gpa.free(absolute);
    const relative = std.fs.path.relative(gpa, cwd, null, cwd, absolute) catch fatal.oom();
    defer gpa.free(relative);
    const chosen = explicit_path orelse relative;
    const dependency = std.fmt.allocPrint(gpa, "file:{s}", .{chosen}) catch fatal.oom();
    defer gpa.free(dependency);
    std.debug.print("Application runtime link: {s}\nKeep this workspace location available; update package.json if you move it.\n", .{dependency});
    return std.json.Stringify.valueAlloc(gpa, .{
        .name = "my-application",
        .private = true,
        .type = "module",
        .scripts = .{ .build = "bun scripts/cli.ts release", .dev = "bun scripts/cli.ts dev", .check = "bun node_modules/typescript/bin/tsc --noEmit" },
        .dependencies = .{ .@"@z/runtime" = dependency },
        .devDependencies = .{ .typescript = "6.0.3" },
    }, .{ .whitespace = .indent_2 }) catch fatal.oom();
}

/// Borrowed manifest string; no allocation. Bound nesting of untrusted exports.
fn appExportTarget(value: std.json.Value, conditions: []const []const u8, depth: usize) ?[]const u8 {
    if (depth == 32) return null;
    switch (value) {
        .string => |path| return if (path.len > 0) path else null,
        .object => |object| {
            var entries = object.iterator();
            while (entries.next()) |entry| {
                for (conditions) |condition| {
                    if (std.mem.eql(u8, entry.key_ptr.*, condition)) {
                        if (appExportTarget(entry.value_ptr.*, conditions, depth + 1)) |path| return path;
                        // An explicit null target blocks this condition.
                        if (entry.value_ptr.* == .null) return null;
                        break;
                    }
                }
            }
        },
        .array => |array| for (array.items) |item| {
            if (appExportTarget(item, conditions, depth + 1)) |path| return path;
        },
        else => {},
    }
    return null;
}

fn appRuntimeFile(io: Io, dir: Io.Dir, path: []const u8) void {
    const stat = dir.statFile(io, path, .{ .follow_symlinks = true }) catch |err| fatal.usageError("error: application runtime needs file {s}: {t}\n", .{ path, err });
    if (stat.kind != .file) fatal.usageError("error: application runtime {s} must be a regular file\n", .{path});
}

/// Decode a package URL path without allowing resolver-invalid segments.
/// Returns a borrowed prefix of the caller-owned buffer.
fn appExportPath(path: []u8) ?[]const u8 {
    var read: usize = 0;
    var written: usize = 0;
    while (read < path.len) {
        var byte = path[read];
        if (byte == '%') {
            if (read + 2 >= path.len) return null;
            const hi = std.fmt.charToDigit(path[read + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(path[read + 2], 16) catch return null;
            byte = hi * 16 + lo;
            if (byte == '/' or byte == '\\') return null;
            read += 2;
        }
        if (byte == 0 or byte == '\\') return null;
        path[written] = byte;
        written += 1;
        read += 1;
    }
    const decoded = path[0..written];
    if (!std.mem.startsWith(u8, decoded, "./")) return null;
    var segments = std.mem.splitScalar(u8, decoded[2..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, "..") or std.ascii.eqlIgnoreCase(segment, "node_modules")) return null;
    }
    return decoded;
}
