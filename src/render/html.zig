const std = @import("std");
const Writer = std.Io.Writer;
const supermd = @import("supermd");
const c = supermd.c;
const Ast = supermd.Ast;
const Iter = Ast.Iter;
const tracy = @import("tracy");
const root = @import("../root.zig");
const hl = @import("../highlight.zig");
const highlightCode = hl.highlightCode;
const context = @import("../context.zig");
const StringTable = @import("../StringTable.zig");
const PathTable = @import("../PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;
const fingerprint = @import("../fingerprint.zig");
const image_plan = @import("../image/plan.zig");
const HtmlSafe = @import("superhtml").HtmlSafe;

const log = std.log.scoped(.render);

pub fn html(
    gpa: std.mem.Allocator,
    ctx: *const context.Root,
    page: *const context.Page,
    start: supermd.Node,
    w: *Writer,
) !void {
    const zone = tracy.traceNamed(@src(), "html");
    defer zone.end();

    const ast = page._parse.ast;

    // Footnotes are disconnected from the main ast tree so we cannot
    // start an iterator from the document's root node when rendering
    // one (which happens on-demand by pointing `start` at a footnote node).
    const root_node = if (start.nodeType() == .FOOTNOTE_DEFINITION) start else ast.md.root;
    var it = Iter.init(root_node);

    const full_page = start.n == ast.md.root.n;
    var event: ?Iter.Event = if (!full_page) blk: {
        it.reset(start, .enter);
        break :blk .{ .node = start, .dir = .enter };
    } else it.next();

    var open_div = false;
    var table_in_header = false;
    var table_alignments: []const u8 = &.{};
    var table_cell_id: usize = 0;
    while (event) |ev| : (event = it.next()) {
        // const loop_zone = tracy.traceNamed(@src(), "html-event");
        // defer loop_zone.end();

        const node = ev.node;
        const node_is_section = if (node.getDirective()) |d|
            d.kind == .section and node.nodeType() != .LINK
        else
            false;

        // var buf: [1024]u8 = undefined;
        // tracy.messageCopy(std.fmt.bufPrint(&buf, "{} {s}", .{
        //     node.nodeType(),
        //     @tagName(ev.dir),
        // }) catch unreachable);

        log.debug("node ({}, {s}, {?s}) = {} {s} \n({*} == {*} {})", .{
            node_is_section,
            if (node.getDirective()) |d| @tagName(d.kind) else "<>",
            if (node.getDirective()) |d| d.id else null,
            node.nodeType(),
            @tagName(ev.dir),
            node.n,
            start.n,
            node.n != start.n,
        });

        if (!full_page and node_is_section and node.n != start.n) {
            log.debug("done, breaking", .{});
            break;
        }

        switch (node.nodeType()) {
            .DOCUMENT => {},
            .BLOCK_QUOTE => switch (ev.dir) {
                .enter => {
                    const d = node.getDirective() orelse {
                        try w.print("<blockquote>", .{});
                        continue;
                    };

                    if (d.kind.block.collapsible) |collap| {
                        try w.writeAll("<details");
                        if (collap) try w.writeAll(" open");
                    } else {
                        try w.writeAll("<div");
                    }

                    if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    try w.print(" class=\"block", .{});
                    if (d.attrs) |attrs| {
                        for (attrs) |attr| try w.print(" {f}", .{HtmlSafe{ .bytes = attr }});
                    }
                    try w.print("\">", .{});
                },
                .exit => {
                    if (node.getDirective()) |d| {
                        if (d.kind.block.collapsible != null) {
                            try w.print("</details>", .{});
                        } else {
                            try w.print("</div>", .{});
                        }
                    } else {
                        try w.print("</blockquote>", .{});
                        continue;
                    }
                },
            },
            .LIST => switch (ev.dir) {
                .enter => try w.print("<{s}>", .{
                    @tagName(node.listType()),
                }),
                .exit => try w.print("</{s}>", .{
                    @tagName(node.listType()),
                }),
            },
            .ITEM => switch (ev.dir) {
                .enter => try w.print("<li>", .{}),
                .exit => try w.print("</li>", .{}),
            },
            .HTML_BLOCK => switch (ev.dir) {
                .enter => try w.print(
                    "{s}",
                    .{node.literal() orelse ""},
                ),
                .exit => {},
            },
            .CUSTOM_BLOCK => switch (ev.dir) {
                .enter => {},
                .exit => {},
            },
            .PARAGRAPH => {
                if (node.parent()) |p|
                    if (p.parent()) |gp|
                        if (gp.listIsTight()) continue;

                switch (ev.dir) {
                    .enter => {
                        if (node.getDirective()) |d| {
                            if (open_div) {
                                try w.print("</div>", .{});
                            }
                            open_div = true;
                            try w.print("<div", .{});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                                try w.print("\"", .{});
                            }

                            try w.print(">", .{});
                            _ = it.next();
                            _ = it.next();
                            if (node.firstChild().?.nextSibling() == null) {
                                continue;
                            }
                        }

                        try w.print("<p>", .{});
                    },
                    .exit => {
                        if (node.getDirective() != null) {
                            if (node.firstChild().?.nextSibling() == null) {
                                continue;
                            }
                        }
                        try w.print("</p>", .{});
                    },
                }
            },
            .HEADING => switch (ev.dir) {
                .enter => {
                    if (node.parent()) |p| if (p.getDirective()) |pd| switch (pd.kind) {
                        else => {},
                        .block => |b| {
                            if (b.collapsible != null and node.prevSibling() == null) {
                                try w.writeAll("<summary>");
                                continue;
                            }
                        },
                    };
                    if (node.getDirective()) |d| switch (d.kind) {
                        else => {},
                        .heading => {
                            try w.print("<h{}", .{node.headingLevel()});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                                try w.print("\"", .{});
                            }

                            try w.print(">", .{});
                            continue;
                        },
                        .section => {
                            if (open_div) {
                                try w.print("</div>", .{});
                            }
                            open_div = true;
                            try w.print("<div", .{});
                            if (d.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                            if (d.attrs) |attrs| {
                                try w.print(" class=\"", .{});
                                for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                                try w.print("\"", .{});
                            }

                            try w.print(">", .{});
                        },
                    };

                    try w.print("<h{}>", .{node.headingLevel()});
                },
                .exit => {
                    if (node.parent()) |p| if (p.getDirective()) |pd| switch (pd.kind) {
                        else => {},
                        .block => |b| {
                            if (b.collapsible != null and node.prevSibling() == null) {
                                try w.writeAll("</summary>");
                                continue;
                            }
                        },
                    };
                    try w.print("</h{}>", .{node.headingLevel()});
                },
            },
            .THEMATIC_BREAK => switch (ev.dir) {
                .enter => try w.print("<hr>", .{}),
                .exit => {},
            },
            .FOOTNOTE_REFERENCE => switch (ev.dir) {
                .enter => {
                    const literal = node.literal().?;
                    const def_idx = ast.footnotes.getIndex(literal).?;
                    const footnote = ast.footnotes.values()[def_idx];
                    try w.print("<sup class=\"footnote-ref\"><a href=\"#{s}\" id=\"{s}\">{d}</a></sup>", .{
                        footnote.def_id,
                        footnote.ref_ids[@intCast(node.footnoteRefIx() - 1)],
                        def_idx + 1,
                    });
                },
                .exit => {},
            },
            .FOOTNOTE_DEFINITION => switch (ev.dir) {
                .enter => {},
                .exit => {},
            },
            .HTML_INLINE => switch (ev.dir) {
                .enter => try w.print(
                    "{s}",
                    .{node.literal() orelse ""},
                ),
                .exit => @panic("custom inline"),
            },
            .CUSTOM_INLINE => switch (ev.dir) {
                .enter => @panic("custom inline"),
                .exit => {},
            },
            .TEXT => switch (ev.dir) {
                .enter => try w.print("{s}", .{
                    node.literal() orelse "",
                }),
                .exit => {},
            },
            .SOFTBREAK => switch (ev.dir) {
                .enter => try w.print(" ", .{}),
                .exit => {},
            },
            .LINEBREAK => switch (ev.dir) {
                .enter => try w.print("<br>", .{}),
                .exit => {},
            },
            .CODE => switch (ev.dir) {
                .enter => try w.print("<code>{f}</code>", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .EMPH => switch (ev.dir) {
                .enter => try w.print("<em>", .{}),
                .exit => try w.print("</em>", .{}),
            },
            .STRONG => switch (ev.dir) {
                .enter => try w.print("<strong>", .{}),
                .exit => try w.print("</strong>", .{}),
            },
            .LINK, .IMAGE => try renderDirective(gpa, ctx, page, ast, ev, w),
            .CODE_BLOCK => switch (ev.dir) {
                .exit => {},
                .enter => {
                    if (node.literal()) |code| {
                        const fence_info = node.fenceInfo() orelse "";
                        if (std.mem.trim(u8, fence_info, " \n").len == 0) {
                            try w.print("<pre><code>{f}</code></pre>", .{
                                HtmlSafe{ .bytes = code },
                            });
                        } else {
                            var fence_it = std.mem.tokenizeScalar(u8, fence_info, ' ');
                            const lang_name = fence_it.next().?;

                            if (std.mem.eql(u8, lang_name, "=html")) {
                                try w.writeAll(code);
                                continue;
                            } else if (std.mem.eql(u8, lang_name, "=mathtex")) {
                                try w.writeAll("<script type=\"math/tex\">");
                                try w.writeAll(code);
                                try w.writeAll("</script>");
                                continue;
                            }

                            try w.print("<pre><code class=\"{f}\">", .{HtmlSafe{ .bytes = lang_name }});

                            highlightCode(
                                ctx._meta.io,
                                gpa,
                                lang_name,
                                code,
                                w,
                            ) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.WriteFailed => return error.WriteFailed,
                                // An unknown language is a WARNING, not a build
                                // failure, as of issue #31 -- analyzeContent
                                // (src/worker.zig) no longer aborts the page over
                                // it, so this invariant ("the language was already
                                // validated") is gone and this branch is reachable.
                                // It is still sound to fall back rather than
                                // propagate: highlightCode (src/highlight.zig)
                                // resolves the language and creates the query
                                // cursor with `try`s that all run BEFORE its first
                                // `printSpan` write, so any error it returns here
                                // means nothing has been written to `w` yet for
                                // this call -- falling back to the escaped-code
                                // path below is exactly the output
                                // `enable_treesitter=false` already produces for
                                // every language, known or not.
                                else => try w.print("{f}", .{HtmlSafe{ .bytes = code }}),
                            };
                            try w.writeAll("</code></pre>\n");
                        }
                    }
                },
            },

            else => |nt| if (@intFromEnum(nt) == c.CMARK_NODE_STRIKETHROUGH) switch (ev.dir) {
                .enter => try w.writeAll("<del>"),
                .exit => try w.writeAll("</del>"),
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE) switch (ev.dir) {
                .enter => {
                    table_alignments = node.getTableAlignments();
                    try w.writeAll("<table>");
                },
                .exit => {
                    table_alignments = &.{};
                    try w.writeAll("</table>");
                },
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE_ROW) switch (ev.dir) {
                .enter => {
                    table_in_header = node.isTableHeader();
                    try w.writeAll("<tr>");
                },
                .exit => {
                    table_in_header = !node.isTableHeader();
                    table_cell_id = 0;
                    try w.writeAll("</tr>");
                },
            } else if (@intFromEnum(nt) == c.CMARK_NODE_TABLE_CELL) switch (ev.dir) {
                .enter => {
                    if (table_in_header) {
                        try w.writeAll("<th");
                    } else {
                        try w.writeAll("<td");
                    }

                    if (table_cell_id < table_alignments.len) {
                        const char = table_alignments[table_cell_id];
                        if (char != 0) try w.print(" align='{s}'", .{
                            switch (char) {
                                else => unreachable,
                                'l' => "left",
                                'c' => "center",
                                'r' => "right",
                            },
                        });
                    }
                    table_cell_id += 1;

                    try w.writeAll(">");
                },
                .exit => {
                    if (table_in_header) {
                        try w.writeAll("</th>");
                    } else {
                        try w.writeAll("</td>");
                    }
                },
            } else std.debug.panic(
                "TODO: implement support for {x}",
                .{node.nodeType()},
            ),
        }
    }
    if (open_div) {
        try w.writeAll("</div>");
    }
}

fn renderDirective(
    gpa: std.mem.Allocator,
    ctx: *const context.Root,
    page: *const context.Page,
    ast: Ast,
    ev: Iter.Event,
    w: *Writer,
) !void {
    const zone = tracy.trace(@src());
    defer zone.end();
    _ = ast;
    const node = ev.node;
    const directive = node.getDirective() orelse return renderLink(ev, ctx, w);
    switch (directive.kind) {
        .section, .block, .heading => {},
        .mathtex => |katek| switch (ev.dir) {
            .enter => {
                try w.writeAll("<script type=\"math/tex\"");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.writeAll(">");
                try w.writeAll(katek.formula);
            },
            .exit => {
                try w.writeAll("</script>");
            },
        },
        .text => switch (ev.dir) {
            .enter => {
                try w.print("<span", .{});
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.print(" class=\"", .{});
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.print("\"", .{});
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.print(">", .{});
            },
            .exit => {
                try w.print("</span>", .{});
            },
        },
        .image => |img| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                if (img.linked) |l| if (l) {
                    try w.writeAll("<a href=\"");
                    try printUrl(ctx, page, img.src.?, w);
                    try w.writeAll("\">");
                };

                const planned = imageVariantsFor(ctx, page, img.src.?);
                if (planned) |p| {
                    try w.writeAll("<picture>");
                    // Full responsive srcset (#132): one `w`-descriptor
                    // entry per surviving width, filtered by codec so each
                    // <source> carries only its own codec's variants. Codec
                    // order is fixed best-first per spec §2 — AVIF (Task 12,
                    // emitted only when the hatch produced variants) before
                    // WebP. The HTML spec requires `sizes` alongside `w`
                    // descriptors, so it always follows srcset.
                    const sizes = ctx._meta.build.cfg.getImageOptimize().?.sizes;
                    try writeImageSourceLine(ctx, page, img.src.?, p, .avif, "image/avif", sizes, w);
                    try writeImageSourceLine(ctx, page, img.src.?, p, .webp, "image/webp", sizes, w);
                }

                try w.writeAll("<img");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.writeAll(" src=\"");
                try printUrl(ctx, page, img.src.?, w);
                try w.writeAll("\"");

                if (img.alt) |alt| try w.print(" alt=\"{f}\"", .{HtmlSafe{ .bytes = alt }});
                if (img.size) |size| {
                    if (size.w > 0) try w.print(" width=\"{d}\"", .{size.w});
                    if (size.h > 0) try w.print(" height=\"{d}\"", .{size.h});
                }
                try w.writeAll(">");
                if (planned != null) try w.writeAll("</picture>");
                if (img.linked) |l| if (l) try w.writeAll("</a>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
        .video => |vid| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                try w.writeAll("<video");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }
                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                if (vid.loop) |val| if (val) try w.writeAll(" loop");
                if (vid.autoplay) |val| if (val) try w.writeAll(" autoplay");
                if (vid.muted) |val| if (val) try w.writeAll(" muted");
                if (vid.controls) |val| if (val) try w.writeAll(" controls");
                if (vid.pip) |val| if (!val) {
                    try w.writeAll(" disablepictureinpicture");
                };
                try w.writeAll(">\n<source src=\"");
                try printUrl(ctx, page, vid.src.?, w);
                try w.writeAll("\">\n</video>");
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
        .link => |lnk| switch (ev.dir) {
            .enter => {
                try w.writeAll("<a");
                if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                if (directive.attrs) |attrs| {
                    try w.writeAll(" class=\"");
                    for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    try w.writeAll("\"");
                }

                if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                try w.writeAll(" href=\"");
                try printUrl(ctx, page, lnk.src.?, w);
                // Escaped for the same reason as `id` (#148): `$link.ref(…)`
                // resolves to a heading/section id, which is author-written and
                // is escaped where it is *emitted*. Escaping both sides keeps
                // the fragment and the id it points at spelled the same way.
                if (lnk.ref) |r| try w.print("#{f}", .{HtmlSafe{ .bytes = r }});
                try w.writeAll("\"");

                if (lnk.new) |n| if (n) try w.writeAll(" target=\"_blank\"");
                try w.writeAll(">");
            },
            .exit => try w.writeAll("</a>"),
        },
        .code => |code| switch (ev.dir) {
            .enter => {
                const caption = node.firstChild();
                if (caption != null) try w.writeAll("<figure>");
                if (std.mem.eql(u8, code.language orelse "", "=html")) {
                    try w.writeAll(code.src.?.url);
                } else if (std.mem.eql(u8, code.language orelse "", "=mathtex")) {
                    try w.writeAll("<script type=\"math/tex\"");
                    if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    }

                    if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                    try w.writeAll(">");
                    try w.writeAll(code.src.?.url);
                    try w.writeAll("</script>");
                } else {
                    try w.writeAll("<pre");
                    if (directive.id) |id| try w.print(" id=\"{f}\"", .{HtmlSafe{ .bytes = id }});
                    if (directive.attrs) |attrs| {
                        if (code.language == null) try w.writeAll(" class=\"");
                        for (attrs) |attr| try w.print("{f} ", .{HtmlSafe{ .bytes = attr }});
                    }

                    if (directive.title) |t| try w.print(" title=\"{f}\"", .{HtmlSafe{ .bytes = t }});
                    // `class="null"` for a language-less fence is what `{?s}`
                    // already produced, and #148 is an escaping fix -- so the
                    // null arm is reproduced verbatim rather than quietly
                    // corrected here.
                    if (code.language) |lang| {
                        try w.print("><code class=\"{f}\">", .{HtmlSafe{ .bytes = lang }});
                    } else {
                        try w.writeAll("><code class=\"null\">");
                    }

                    if (code.language) |lang| {
                        highlightCode(
                            ctx._meta.io,
                            gpa,
                            lang,
                            code.src.?.url,
                            w,
                        ) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.WriteFailed => return error.WriteFailed,
                            // See the matching CODE_BLOCK site above: an unknown
                            // language is a WARNING as of issue #31, not a build
                            // failure, so this invariant ("validated during page
                            // analysis") no longer holds and the branch is
                            // reachable. Sound for the same reason: highlightCode's
                            // fallible calls all precede its first write, so
                            // falling back to escaped output here matches
                            // `enable_treesitter=false`'s behavior exactly.
                            else => try w.print("{f}", .{HtmlSafe{ .bytes = code.src.?.url }}),
                        };
                    } else {
                        try w.print("{f}", .{HtmlSafe{ .bytes = code.src.?.url }});
                    }

                    try w.writeAll("</code></pre>");
                }
                if (caption != null) try w.writeAll("\n<figcaption>");
            },
            .exit => {
                const caption = node.firstChild();
                if (caption != null) {
                    try w.writeAll("</figcaption></figure>");
                }
            },
        },
    }
}

/// The image_variants entry for an image directive's source, or null when
/// the feature is off / the source was ineligible / it's a kind we don't
/// optimize (URLs, external, build assets — spec's out-of-scope list).
/// Contract 3: allocates nothing.
fn imageVariantsFor(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
) ?*const image_plan.Planned {
    const map = &ctx._meta.build.image_variants;
    if (map.count() == 0) return null;
    const ref: image_plan.SourceRef = switch (src) {
        .page_asset => |pa| .{
            .kind = .page,
            .variant_id = page._scan.variant_id,
            .path = pa.resolved.path,
            .name = pa.resolved.name,
        },
        .site_asset => |sa| .{
            .kind = .site,
            .variant_id = 0,
            .path = sa.resolved.path,
            .name = sa.resolved.name,
        },
        else => return null,
    };
    return map.getPtr(ref);
}

/// Write one `<source type="...">` line for the variants of a single codec,
/// or nothing at all when `planned` has none for that codec — e.g. no
/// `<source type="image/avif">` when `avif_encoder` is unset and the planner
/// therefore never minted `.avif` variants (spec §2's "iff avif_encoder
/// set"). Filtering here, rather than trusting caller order, is what keeps
/// the two calls in the `.image` arm above independent: each call owns
/// deciding whether ITS codec has anything to say.
fn writeImageSourceLine(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
    planned: *const image_plan.Planned,
    codec: image_plan.Codec,
    mime: []const u8,
    sizes: []const u8,
    w: *Writer,
) !void {
    var first = true;
    for (planned.variants) |variant| {
        if (variant.codec != codec) continue;
        if (first) {
            try w.print("<source type=\"{s}\" srcset=\"", .{mime});
        } else {
            try w.writeAll(", ");
        }
        first = false;
        try printVariantUrl(ctx, page, src, variant.basename, w);
        try w.print(" {d}w", .{variant.width});
    }
    if (!first) {
        try w.writeAll("\" sizes=\"");
        try w.print("{f}", .{HtmlSafe{ .bytes = sizes }});
        try w.writeAll("\">");
    }
}

/// Print a derived variant's URL: the same prefix + directory the fallback
/// original gets from printUrl, with the variant basename substituted.
/// The basename is already content-addressed, so fingerprint.fmtUrl is
/// deliberately NOT consulted (double-hashing would desync install/link).
///
/// Path components and the basename are written through `writeSrcsetSegment`,
/// NOT a plain `w.writeAll`: this URL lands in a `srcset` attribute, and the
/// HTML "parse a srcset attribute" algorithm terminates a candidate URL at
/// the first ASCII whitespace character (unquoted, unlike `src`) — a source
/// basename or directory containing a space would otherwise silently split
/// into an invalid candidate, and the browser falls back to plain `<img>`
/// with optimization off and nothing observable (#132 final review, Fix 2).
/// The file on disk keeps its literal name; only this URL is encoded, and
/// `printUrl`'s plain-`<img src>` path is untouched on purpose — a quoted
/// `src` attribute tolerates the raw space.
fn printVariantUrl(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
    basename: []const u8,
    w: *Writer,
) !void {
    switch (src) {
        .page_asset => |pa| {
            try ctx.printLinkPrefix(w, page._scan.variant_id, page != ctx.page);
            const path: Path = @enumFromInt(pa.resolved.path);
            const v = ctx._meta.build.variants[page._scan.variant_id];
            for (path.slice(&v.path_table)) |comp| {
                try writeSrcsetSegment(w, comp.slice(&v.string_table));
                try w.writeAll("/");
            }
            try writeSrcsetSegment(w, basename);
        },
        .site_asset => |sa| {
            try printAssetUrlPrefix(ctx, page, w, false);
            const path: Path = @enumFromInt(sa.resolved.path);
            for (path.slice(&ctx._meta.build.pt)) |comp| {
                try writeSrcsetSegment(w, comp.slice(&ctx._meta.build.st));
                try w.writeAll("/");
            }
            try writeSrcsetSegment(w, basename);
        },
        else => unreachable, // imageVariantsFor filtered these
    }
}

/// Write `s`, percent-encoding the five characters the HTML "ASCII
/// whitespace" definition names (space, tab, LF, FF, CR) — the exact set
/// the srcset candidate-URL parser splits on. Everything else is written
/// byte-identical, so no existing URL changes.
fn writeSrcsetSegment(w: *Writer, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const enc: ?[]const u8 = switch (ch) {
            ' ' => "%20",
            '\t' => "%09",
            '\n' => "%0A",
            '\x0C' => "%0C",
            '\r' => "%0D",
            else => null,
        };
        if (enc) |e| {
            try w.writeAll(s[start..i]);
            try w.writeAll(e);
            start = i + 1;
        }
    }
    try w.writeAll(s[start..]);
}

fn printUrl(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
    w: *Writer,
) !void {
    switch (src) {
        .url => |url| try w.writeAll(url),
        .self_page => |alt| if (alt) |a| {
            try ctx.printLinkPrefix(
                w,
                page._scan.variant_id,
                // We are not checking the variant id so two different pages
                // might have the same id in different variant arrays, but we
                // don't care because, when the variant is different, the full
                // host url will be printed anyway.
                // NOTE: `p.resolved.page_id` is not the same as `page._scan.page_id`
                page != ctx.page,
            );

            if (a[0] != '/') {
                const v = ctx._meta.build.variants[page._scan.variant_id];
                try w.print("{f}", .{page._scan.url.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )});
            }

            try w.writeAll(std.mem.trimStart(u8, a, "/"));
        },
        .page => |p| {
            try ctx.printLinkPrefix(
                w,
                p.resolved.variant_id,
                // We are not checking the variant id so two different pages
                // might have the same id in different variant arrays, but we
                // don't care because, when the variant is different, the full
                // host url will be printed anyway.
                // NOTE: `p.resolved.page_id` is not the same as `page._scan.page_id`
                page != ctx.page,
            );

            const path: Path = @enumFromInt(p.resolved.path);
            const v = ctx._meta.build.variants[p.resolved.variant_id];
            if (p.resolved.alt) |a| {
                if (a[0] != '/') {
                    try w.print("{f}", .{path.fmt(
                        &v.string_table,
                        &v.path_table,
                        null,
                        true,
                    )});
                }
                try w.writeAll(std.mem.trimStart(u8, a, "/"));
            } else {
                try w.print("{f}", .{path.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    true,
                )});
            }
        },
        .page_asset => |pa| {
            try ctx.printLinkPrefix(
                w,
                page._scan.variant_id,
                page != ctx.page,
            );

            const pn: PathName = .{
                .path = @enumFromInt(pa.resolved.path),
                .name = @enumFromInt(pa.resolved.name),
            };

            const v = ctx._meta.build.variants[page._scan.variant_id];
            try w.print("{f}", .{pn.fmt(
                &v.string_table,
                &v.path_table,
                null,
                "/",
            )});
        },
        .site_asset => |sa| {
            try printAssetUrlPrefix(ctx, page, w, false);

            const pn: PathName = .{
                .path = @enumFromInt(sa.resolved.path),
                .name = @enumFromInt(sa.resolved.name),
            };

            // The SuperMD-directive twin of `context/Asset.zig`'s `.site` arm:
            // a `![](…)` reference to a site asset must resolve to the same
            // (possibly content-hashed) name the install pass writes, so it
            // goes through the same formatter. See issue #53.
            try w.print("{f}", .{fingerprint.fmtUrl(
                pn,
                &ctx._meta.build.st,
                &ctx._meta.build.pt,
                &ctx._meta.build.asset_fingerprints,
            )});
        },
        .build_asset => |ba| {
            try printAssetUrlPrefix(ctx, page, w, false);
            try w.print("{s}", .{ba.ref});
        },
    }
}

pub fn printAssetUrlPrefix(
    ctx: *const context.Root,
    page: *const context.Page,
    w: *Writer,
    /// When set to true the full host url will always be printed,
    /// regardless of whether `page` is the page currently being
    /// rendered. Used by `Asset.absLink()` (issue #25): an asset
    /// referenced from its own page still needs an absolute URL for
    /// contexts consumed outside the page itself (og:image, canonical
    /// links, feeds).
    force_host_url: bool,
) !void {
    switch (ctx.site._meta.kind) {
        .simple => |url_prefix_path| {
            if (force_host_url or ctx.page != page) {
                try w.print("{f}/", .{
                    root.fmtJoin('/', &.{
                        ctx.site.host_url,
                        url_prefix_path,
                    }),
                });
            } else if (url_prefix_path.len > 0) {
                try w.print("/{s}/", .{url_prefix_path});
            } else {
                try w.writeAll("/");
            }
        },
        .multi => |locale| {
            const assets_prefix_path = ctx._meta.build.cfg.Multilingual.assets_prefix_path;
            if (force_host_url or ctx.page != page or locale.host_url_override != null) {
                // Trailing separator, matching the `.simple` arm above and
                // this arm's own `else` branch. `fmtJoin` never appends one
                // and skips empty components, so without it the caller's
                // asset name is concatenated straight onto the prefix:
                // `https://example.com/static` + `site.css` came out as
                // `https://example.com/staticsite.css`, and with an empty
                // `assets_prefix_path` as `https://example.comsite.css`.
                //
                // NOT latent: the `locale.host_url_override != null` disjunct
                // has always been reachable through plain `link()`, so any
                // multilingual site with an override has been emitting this
                // malformed site-asset URL. `absLink()` merely adds a third
                // way in. Fixing it here repairs `link()` on those sites too.
                try w.print("{f}/", .{
                    root.fmtJoin('/', &.{
                        ctx.site.host_url,
                        assets_prefix_path,
                    }),
                });
            } else {
                try w.writeAll("/");
                if (assets_prefix_path.len > 0) {
                    try w.print("{s}/", .{assets_prefix_path});
                }
            }
        },
    }
}
fn renderLink(
    ev: Iter.Event,
    ctx: *const context.Root,
    w: *Writer,
) !void {
    _ = ctx;
    const node = ev.node;
    switch (ev.dir) {
        .enter => {
            try w.print("<a href=\"{s}\">", .{
                node.link() orelse "",
            });
        },
        .exit => try w.print("</a>", .{}),
    }
}

pub fn htmlToc(ast: Ast, w: *Writer) !void {
    try w.print("<ul>\n", .{});
    var lvl: i32 = 1;
    var first_item = true;
    var node: ?supermd.Node = ast.md.root.firstChild();
    while (node) |n| : (node = n.nextSibling()) {
        if (n.nodeType() != .HEADING) continue;
        defer first_item = false;

        const new_lvl = n.headingLevel();
        if (new_lvl > lvl) {
            if (first_item) {
                try w.print("<li>\n", .{});
            }
            while (new_lvl > lvl) : (lvl += 1) {
                try w.print("<ul><li>\n", .{});
            }

            try tocRenderHeading(n, w, true);
        } else if (new_lvl < lvl) {
            try w.print("</li>", .{});
            while (new_lvl < lvl) : (lvl -= 1) {
                try w.print("</ul></li>", .{});
            }
            try w.print("<li>", .{});
            try tocRenderHeading(n, w, true);
        } else {
            if (first_item) {
                try w.print("<li>", .{});
                try tocRenderHeading(n, w, true);
            } else {
                try w.print("</li><li>", .{});
                try tocRenderHeading(n, w, true);
            }
        }
    }

    while (lvl > 1) : (lvl -= 1) {
        try w.print("</li></ul>", .{});
    }

    try w.print("</ul>", .{});
}

fn tocRenderHeading(heading: supermd.Node, w: *Writer, link: bool) !void {
    var it = Iter.init(heading);
    while (it.next()) |ev| {
        const node = ev.node;
        switch (node.nodeType()) {
            // Any inline node not explicitly handled below (inline HTML,
            // images, etc.) is rendered as its literal text so a heading with
            // such a node produces a plain-text toc entry instead of aborting
            // the whole build. See AUD-006.
            else => switch (ev.dir) {
                .enter => if (node.literal()) |lit| try w.print("{f}", .{
                    HtmlSafe{ .bytes = lit },
                }),
                .exit => {},
            },
            .HEADING => switch (ev.dir) {
                .enter => {
                    const dir = node.getDirective() orelse continue;
                    if (dir.id) |id| {
                        std.debug.assert(id.len > 0);
                        std.debug.assert(std.mem.trim(u8, id, "\t\n\r ").len > 0);
                        if (link) try w.print("<a href=\"#{s}\">", .{id});
                    }
                },
                .exit => {
                    const dir = node.getDirective() orelse continue;
                    if (dir.id != null) {
                        if (link) try w.print("</a>", .{});
                    }
                },
            },
            .TEXT => switch (ev.dir) {
                .enter => try w.print("{s}", .{
                    node.literal() orelse "",
                }),
                .exit => {},
            },
            .SOFTBREAK => switch (ev.dir) {
                .enter => try w.print(" ", .{}),
                .exit => {},
            },
            .LINEBREAK => switch (ev.dir) {
                .enter => try w.print("<br>", .{}),
                .exit => {},
            },
            .CODE => switch (ev.dir) {
                .enter => try w.print("<code>{f}</code>", .{
                    HtmlSafe{ .bytes = node.literal() orelse "" },
                }),
                .exit => {},
            },
            .EMPH => switch (ev.dir) {
                .enter => try w.print("<em>", .{}),
                .exit => try w.print("</em>", .{}),
            },
            .STRONG => switch (ev.dir) {
                .enter => try w.print("<strong>", .{}),
                .exit => try w.print("</strong>", .{}),
            },
            .LINK => {},
        }
    }
}

pub fn htmlTocDetails(ast: Ast, w: *Writer) !void {
    var lvl: i32 = 1;
    var first_item = true;
    var node: ?supermd.Node = ast.md.root.firstChild();
    while (node) |n| : (node = n.nextSibling()) {
        if (n.nodeType() != .HEADING) continue;
        defer first_item = false;

        const new_lvl = n.headingLevel();
        if (new_lvl > lvl) {
            // if (lvl == 1) {
            //     try w.print("<details>\n", .{});
            //     lvl += 1;
            // }
            while (new_lvl > lvl) : (lvl += 1) {
                try w.print("<ul><li>\n", .{});
            }

            // if (lvl == 1) try w.print("<summary>\n", .{});
            try tocRenderHeading(n, w, true);
            // if (lvl == 1) try w.print("</summary>\n", .{});
        } else if (new_lvl < lvl) {
            try w.print("</li>", .{});
            while (new_lvl < lvl) : (lvl -= 1) {
                try w.print("</ul></li>", .{});
            }
            if (lvl == 1) {
                try w.print("</details><details><summary>", .{});
                try tocRenderHeading(n, w, false);
                try w.print("</summary>", .{});
            } else {
                try w.print("<li>", .{});
                try tocRenderHeading(n, w, true);
            }
        } else {
            if (first_item) {
                if (lvl == 1) {
                    try w.print("<details><summary>", .{});
                    try tocRenderHeading(n, w, false);
                    try w.print("</summary>", .{});
                } else {
                    try w.print("<li>", .{});
                    try tocRenderHeading(n, w, true);
                }
            } else {
                if (lvl == 1) {
                    try w.print("</details><details><summary>", .{});
                    try tocRenderHeading(n, w, false);
                    try w.print("</summary>", .{});
                } else {
                    try w.print("</li><li>", .{});
                    try tocRenderHeading(n, w, true);
                }
            }
        }
    }

    while (lvl > 1) : (lvl -= 1) {
        try w.print("</li></ul>", .{});
    }
}
