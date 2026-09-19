const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.init);

pub fn init(io: Io, gpa: Allocator, args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--from-astro")) {
        for (args) |option| if (std.mem.eql(u8, option, "--minimal")) {
            fatal.usageError("error: `init --minimal` cannot be combined with `--from-astro`\n", .{});
        };
        return @import("init_from_astro.zig").run(io, gpa, args);
    };

    const cmd: Command = .parse(args);
    if (cmd.minimal and cmd.multilingual) fatal.usageError(
        "error: `init --minimal` cannot be combined with `--multilingual`\n",
        .{},
    );
    if (cmd.multilingual) fatal.usageError(
        "error: `init --multilingual` is not implemented yet\n",
        .{},
    );

    const File = struct { path: []const u8, src: []const u8 };
    const files = [_]File{
        .{
            .path = "AGENTS.md",
            .src = @embedFile("init/AGENTS.md"),
        },
        .{
            .path = "CLAUDE.md",
            .src = @embedFile("init/CLAUDE.md"),
        },
        .{
            .path = "zigapagos.ziggy",
            .src = if (cmd.minimal) @embedFile("init/minimal/zigapagos.ziggy") else @embedFile("init/zigapagos.ziggy"),
        },
        .{
            // Plain `init` previously wrote no `.gitignore` at all, so
            // `.zigapagos-cache/` (the image-optimization derive cache, #132)
            // was untracked-but-unignored on a fresh scaffold. Reuse
            // `init_from_astro`'s template and add this command's default
            // output directory, `public/`.
            .path = ".gitignore",
            .src = "public/\n" ++ comptime @import("init_from_astro.zig").emitGitignore(),
        },
    };
    const minimal_files = [_]File{
        .{ .path = "content/index.smd", .src = @embedFile("init/minimal/index.smd") },
        .{ .path = "layouts/page.shtml", .src = @embedFile("init/minimal/page.shtml") },
        .{ .path = "assets/style.css", .src = @embedFile("init/minimal/style.css") },
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

    for ([_][]const File{ &files, if (cmd.minimal) &minimal_files else &sample_files }) |group| {
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
    fn parse(args: []const []const u8) Command {
        var multilingual = false;
        var minimal = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--multilingual")) {
                multilingual = true;
            } else if (std.mem.eql(u8, a, "--minimal")) {
                minimal = true;
            } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
                fatal.usage(
                    \\Usage: zigapagos init [OPTIONS]
                    \\
                    \\Command specific options:
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

        return .{ .multilingual = multilingual, .minimal = minimal };
    }
};
