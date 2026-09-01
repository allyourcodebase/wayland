const std = @import("std");

const version: std.SemanticVersion = .{ .major = 1, .minor = 24, .patch = 0 };

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("wayland", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pie", "Produce Position Independent Code");

    const dtd_validation = b.option(bool, "dtd-validation", "Validate the protocol DTD") orelse true;
    const icon_directory = b.option([]const u8, "icon-directory", "Location used to look for cursors (defaults to ${datadir}/icons if unset)");

    const link_system_expat = b.systemIntegrationOption("expat", .{});
    const link_system_ffi = b.systemIntegrationOption("ffi", .{});
    const link_system_epoll_shim = b.systemIntegrationOption("epoll-shim", .{});

    const need_epoll_shim = switch (target.result.os.tag) {
        .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
    const epoll_shim = if (need_epoll_shim and !link_system_epoll_shim) createEpollShim(b, target, optimize) else null;

    const cc_flags = getCCFlags(b, target);
    const host_cc_flags = getCCFlags(b, b.graph.host);

    const wayland_version_header = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("src/wayland-version.h.in") },
    }, .{
        .WAYLAND_VERSION_MAJOR = @as(i64, @intCast(version.major)),
        .WAYLAND_VERSION_MINOR = @as(i64, @intCast(version.minor)),
        .WAYLAND_VERSION_MICRO = @as(i64, @intCast(version.patch)),
        .WAYLAND_VERSION = b.fmt("{f}", .{version}),
    });

    const wayland_util = createWaylandUtil(b, target, optimize, upstream, cc_flags);
    const wayland_util_host = createWaylandUtil(b, b.graph.host, optimize, upstream, cc_flags);

    const wayland_scanner_args: CreateWaylandScannerArgs = .{
        .dtd_validation = dtd_validation,
        .wayland = upstream,
        .wayland_version_header = wayland_version_header,
    };

    const wayland_scanner = createWaylandScanner(b, target, optimize, wayland_scanner_args, cc_flags);
    wayland_scanner.root_module.linkLibrary(wayland_util);
    b.installArtifact(wayland_scanner);

    const wayland_scanner_host = createWaylandScanner(b, b.graph.host, optimize, wayland_scanner_args, host_cc_flags);
    wayland_scanner_host.root_module.linkLibrary(wayland_util_host);

    if (link_system_expat) {
        wayland_scanner.root_module.linkSystemLibrary("expat", .{}); // This is going to fail when cross-compiling
        wayland_scanner_host.root_module.linkSystemLibrary("expat", .{});
    } else {
        if (b.lazyDependency("libexpat", .{
            .target = target,
            .optimize = optimize,
        })) |expat| {
            wayland_scanner.root_module.linkLibrary(expat.artifact("expat"));
        }
        if (b.lazyDependency("libexpat", .{
            .target = b.graph.host,
            .optimize = optimize,
        })) |expat_host| {
            wayland_scanner_host.root_module.linkLibrary(expat_host.artifact("expat"));
        }
    }

    const wayland_header = b.addConfigHeader(.{}, .{
        .PACKAGE = "wayland",
        .PACKAGE_VERSION = b.fmt("{f}", .{version}),
        .HAVE_SYS_PRCTL_H = target.result.os.tag == .linux,
        .HAVE_SYS_PROCCTL_H = target.result.os.isAtLeast(.freebsd, .{ .major = 10, .minor = 0, .patch = 0 }) orelse false, // TODO dragonfly
        .HAVE_SYS_UCRED_H = target.result.os.tag.isBSD(),
        .HAVE_ACCEPT4 = true,
        .HAVE_MKOSTEMP = switch (target.result.os.tag) {
            .linux => target.result.isMuslLibC() or (target.result.isGnuLibC() and target.result.os.version_range.linux.glibc.order(.{ .major = 2, .minor = 7, .patch = 0 }) != .lt),
            .freebsd => target.result.os.isAtLeast(.freebsd, .{ .major = 10, .minor = 0, .patch = 0 }) orelse false,
            .dragonfly => target.result.os.isAtLeast(.dragonfly, .{ .major = 4, .minor = 6, .patch = 0 }) orelse false,
            .openbsd => target.result.os.isAtLeast(.openbsd, .{ .major = 5, .minor = 7, .patch = 0 }) orelse false,
            else => false,
        },
        .HAVE_POSIX_FALLOCATE = switch (target.result.os.tag) {
            .netbsd => false, // https://github.com/NetBSD/pkgsrc/blob/trunk/devel/wayland/patches/patch-meson.build
            .openbsd => false,
            else => true,
        },
        .HAVE_PRCTL = target.result.os.tag == .linux,
        // libffi also has `HAVE_MEMFD_CREATE` but doesn't check the glibc version
        .HAVE_MEMFD_CREATE = switch (target.result.os.tag) {
            .linux => target.result.isMuslLibC() or (target.result.isGnuLibC() and target.result.os.version_range.linux.glibc.order(.{ .major = 2, .minor = 7, .patch = 0 }) != .lt),
            .freebsd => target.result.os.isAtLeast(.freebsd, .{ .major = 13, .minor = 0, .patch = 0 }) orelse false,
            .netbsd => false, // https://github.com/NetBSD/pkgsrc/blob/trunk/devel/wayland/patches/patch-meson.build
            else => false,
        },
        .HAVE_MREMAP = target.result.os.tag == .linux or target.result.os.tag == .freebsd,
        .HAVE_STRNDUP = true,
        .HAVE_BROKEN_MSG_CMSG_CLOEXEC = 0, // only applies to FreeBSD version from 2015 to 2021
        .HAVE_XUCRED_CR_PID = 0, // TODO
    });

    for (wayland_header.values.values()) |*entry| {
        if (entry.* == .boolean and !entry.boolean) entry.* = .undef;
    }

    const wayland_private = blk: {
        const write_files = b.addWriteFiles();
        _ = write_files.addCopyFile(wayland_header.getOutputFile(), "config.h");
        const wayland_header2 = write_files.addCopyFile(wayland_header.getOutputFile(), "config/config.h");

        const wayland_private = b.addLibrary(.{
            .linkage = .static,
            .name = "wayland-private",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        wayland_private.root_module.addIncludePath(wayland_header2.dirname());
        wayland_private.root_module.addIncludePath(upstream.path(""));
        wayland_private.root_module.addCSourceFiles(.{
            .files = &.{
                "connection.c",
                "wayland-os.c",
            },
            .root = upstream.path("src"),
            .flags = cc_flags,
        });
        if (need_epoll_shim) {
            if (link_system_epoll_shim) {
                wayland_private.root_module.linkSystemLibrary("epoll-shim", .{});
            } else {
                if (epoll_shim) |compile| wayland_private.root_module.linkLibrary(compile);
            }
        }
        if (link_system_ffi) {
            wayland_private.root_module.linkSystemLibrary("ffi", .{});
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_private.root_module.linkLibrary(libffi.artifact("ffi"));
        }

        break :blk wayland_private;
    };

    var wayland_server_protocol_h: std.Build.LazyPath = undefined;
    var wayland_server_protocol_core_h: std.Build.LazyPath = undefined;
    var wayland_client_protocol_h: std.Build.LazyPath = undefined;
    var wayland_client_protocol_core_h: std.Build.LazyPath = undefined;

    {
        for (
            [_][]const []const u8{
                &.{"server-header"},
                &.{ "server-header", "-c" },
                &.{"client-header"},
                &.{ "client-header", "-c" },
            },
            [_][]const u8{
                "wayland-server-protocol.h",
                "wayland-server-protocol-core.h",
                "wayland-client-protocol.h",
                "wayland-client-protocol-core.h",
            },
            [_]*std.Build.LazyPath{
                &wayland_server_protocol_h,
                &wayland_server_protocol_core_h,
                &wayland_client_protocol_h,
                &wayland_client_protocol_core_h,
            },
        ) |scanner_args, basename, output_file| {
            const run = b.addRunArtifact(wayland_scanner_host);
            run.addArg("-s");
            run.addArgs(scanner_args);
            run.addFileArg(upstream.path("protocol/wayland.xml"));
            output_file.* = run.addOutputFileArg(basename);
        }
    }

    const wayland_protocol_c = blk: {
        const run = b.addRunArtifact(wayland_scanner_host);
        run.addArgs(&.{ "-s", "public-code" });
        run.addFileArg(upstream.path("protocol/wayland.xml"));
        break :blk run.addOutputFileArg("wayland-protocol.c");
    };

    {
        const wayland_server = b.addLibrary(.{
            .linkage = linkage,
            .name = "wayland-server",
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-server.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
                .pic = pic,
            }),
        });
        b.installArtifact(wayland_server);
        wayland_server.root_module.linkLibrary(wayland_private);
        wayland_server.root_module.linkLibrary(wayland_util);
        wayland_server.root_module.addConfigHeader(wayland_version_header);
        wayland_server.root_module.addConfigHeader(wayland_header);
        wayland_server.root_module.addIncludePath(upstream.path("src"));
        wayland_server.root_module.addIncludePath(wayland_server_protocol_core_h.dirname());
        wayland_server.root_module.addIncludePath(wayland_server_protocol_h.dirname());
        wayland_server.installHeader(wayland_server_protocol_core_h, "wayland-server-protocol-core.h");
        wayland_server.installHeader(wayland_server_protocol_h, "wayland-server-protocol.h");
        wayland_server.installHeader(upstream.path("src/wayland-server.h"), "wayland-server.h");
        wayland_server.installHeader(upstream.path("src/wayland-server-core.h"), "wayland-server-core.h");
        wayland_server.installLibraryHeaders(wayland_util); // required by wayland-server-core.h
        wayland_server.installConfigHeader(wayland_version_header); // required by wayland-server-core.h
        wayland_server.root_module.addCSourceFile(.{
            .file = wayland_protocol_c,
            .flags = cc_flags,
        });
        wayland_server.root_module.addCSourceFiles(.{
            .files = &.{
                "wayland-server.c",
                "wayland-shm.c",
                "event-loop.c",
            },
            .root = upstream.path("src"),
            .flags = cc_flags,
        });
        if (need_epoll_shim) {
            if (link_system_epoll_shim) {
                wayland_server.root_module.linkSystemLibrary("epoll-shim", .{});
            } else {
                if (epoll_shim) |compile| wayland_server.root_module.linkLibrary(compile);
            }
        }
        if (link_system_ffi) {
            wayland_server.root_module.linkSystemLibrary("ffi", .{});
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_server.root_module.linkLibrary(libffi.artifact("ffi"));
        }
    }

    const wayland_client = blk: {
        const wayland_client = b.addLibrary(.{
            .linkage = linkage,
            .name = "wayland-client",
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-client.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
                .pic = pic,
            }),
        });
        b.installArtifact(wayland_client);
        wayland_client.root_module.linkLibrary(wayland_private);
        wayland_client.root_module.linkLibrary(wayland_util);
        wayland_client.root_module.addConfigHeader(wayland_version_header);
        wayland_client.root_module.addConfigHeader(wayland_header);
        wayland_client.root_module.addIncludePath(upstream.path("src"));
        wayland_client.root_module.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_client.root_module.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_client.installHeader(wayland_client_protocol_core_h, "wayland-client-protocol-core.h");
        wayland_client.installHeader(wayland_client_protocol_h, "wayland-client-protocol.h");
        wayland_client.installHeader(upstream.path("src/wayland-client.h"), "wayland-client.h");
        wayland_client.installHeader(upstream.path("src/wayland-client-core.h"), "wayland-client-core.h");
        wayland_client.installLibraryHeaders(wayland_util); // required by wayland-client-core.h
        wayland_client.installConfigHeader(wayland_version_header); // required by wayland-client-core.h
        wayland_client.root_module.addCSourceFile(.{
            .file = wayland_protocol_c,
            .flags = cc_flags,
        });
        wayland_client.root_module.addCSourceFile(.{
            .file = upstream.path("src/wayland-client.c"),
            .flags = cc_flags,
        });

        if (need_epoll_shim) {
            if (link_system_epoll_shim) {
                wayland_client.root_module.linkSystemLibrary("epoll-shim", .{});
            } else {
                if (epoll_shim) |compile| wayland_client.root_module.linkLibrary(compile);
            }
        }
        if (link_system_ffi) {
            wayland_client.root_module.linkSystemLibrary("ffi", .{});
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_client.root_module.linkLibrary(libffi.artifact("ffi"));
        }

        break :blk wayland_client;
    };

    {
        const wayland_egl = b.addLibrary(.{
            .linkage = linkage,
            .name = "wayland-egl",
            .version = version,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
                .pic = pic,
            }),
        });
        b.installArtifact(wayland_egl);
        wayland_egl.root_module.linkLibrary(wayland_client);
        wayland_egl.root_module.addConfigHeader(wayland_version_header);
        wayland_egl.root_module.addConfigHeader(wayland_header);
        wayland_egl.root_module.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_egl.root_module.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_egl.installHeader(upstream.path("egl/wayland-egl.h"), "wayland-egl.h");
        wayland_egl.installHeader(upstream.path("egl/wayland-egl-core.h"), "wayland-egl-core.h");
        wayland_egl.installHeader(upstream.path("egl/wayland-egl-backend.h"), "wayland-egl-backend.h");
        wayland_egl.root_module.addCSourceFile(.{
            .file = upstream.path("egl/wayland-egl.c"),
            .flags = cc_flags,
        });
    }

    {
        const wayland_cursor = b.addLibrary(.{
            .linkage = linkage,
            .name = "wayland-cursor",
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-cursor.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
                .pic = pic,
            }),
        });
        b.installArtifact(wayland_cursor);
        wayland_cursor.root_module.linkLibrary(wayland_client);
        wayland_cursor.root_module.addConfigHeader(wayland_version_header);
        wayland_cursor.root_module.addConfigHeader(wayland_header);
        wayland_cursor.root_module.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_cursor.root_module.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_cursor.installHeader(upstream.path("cursor/wayland-cursor.h"), "wayland-cursor.h");
        if (icon_directory) |dir| wayland_cursor.root_module.addCMacro("ICONDIR", dir);
        wayland_cursor.root_module.addCSourceFiles(.{
            .files = &.{
                "wayland-cursor.c",
                "os-compatibility.c",
                "xcursor.c",
            },
            .root = upstream.path("cursor"),
            .flags = cc_flags,
        });
    }

    b.addNamedLazyPath("wayland-xml", upstream.path("protocol/wayland.xml"));
    b.addNamedLazyPath("wayland.dtd", upstream.path("protocol/wayland.dtd"));
}

fn createWaylandUtil(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wayland: *std.Build.Dependency,
    cc_flags: []const []const u8,
) *std.Build.Step.Compile {
    const wayland_util = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-util",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    wayland_util.installHeader(wayland.path("src/wayland-util.h"), "wayland-util.h");
    wayland_util.root_module.addCSourceFile(.{
        .file = wayland.path("src/wayland-util.c"),
        .flags = cc_flags,
    });
    return wayland_util;
}

const CreateWaylandScannerArgs = struct {
    dtd_validation: bool,
    wayland: *std.Build.Dependency,
    wayland_version_header: *std.Build.Step.ConfigHeader,
};

fn createWaylandScanner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: CreateWaylandScannerArgs,
    cc_flags: []const []const u8,
) *std.Build.Step.Compile {
    const wayland_scanner = b.addExecutable(.{
        .name = "wayland-scanner",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    wayland_scanner.root_module.addConfigHeader(args.wayland_version_header);
    wayland_scanner.root_module.addCSourceFile(.{
        .file = args.wayland.path("src/scanner.c"),
        .flags = cc_flags,
    });
    wayland_scanner.root_module.addIncludePath(args.wayland.path(""));
    wayland_scanner.root_module.addIncludePath(args.wayland.path("protocol"));

    if (args.dtd_validation) {
        const embed_exe = b.addExecutable(.{
            .name = "embed",
            .root_module = b.createModule(.{
                .root_source_file = b.path("embed.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        const run_embed = b.addRunArtifact(embed_exe);
        run_embed.addFileArg(args.wayland.path("protocol/wayland.dtd"));
        run_embed.addArg("wayland_dtd");

        wayland_scanner.root_module.addIncludePath(run_embed.captureStdOut(.{ .basename = "wayland.dtd.h" }).dirname());

        const link_system_libxml = b.systemIntegrationOption("libxml2", .{});
        if (link_system_libxml) {
            wayland_scanner.root_module.linkSystemLibrary("libxml-2.0", .{});
        } else if (b.lazyDependency("libxml2", .{
            .target = target,
            .optimize = optimize,
            .minimum = true,
            .valid = true,
        })) |libxml2| {
            wayland_scanner.root_module.linkLibrary(libxml2.artifact("xml"));
        }

        wayland_scanner.root_module.addCMacro("HAVE_LIBXML", "1");
    }

    return wayland_scanner;
}

fn getCCFlags(b: *std.Build, target: std.Build.ResolvedTarget) []const []const u8 {
    var cc_flags_list: std.ArrayList([]const u8) = .empty;
    cc_flags_list.appendSlice(b.allocator, &.{
        "-std=c99",
        "-Wno-unused-parameter",
        "-Wstrict-prototypes",
        "-Wmissing-prototypes",
        "-fvisibility=hidden",
    }) catch @panic("OOM");
    switch (target.result.os.tag) {
        .freebsd, .openbsd => {},
        else => cc_flags_list.append(b.allocator, "-D_POSIX_C_SOURCE=200809L") catch @panic("OOM"),
    }
    if (target.result.os.tag == .netbsd) {
        cc_flags_list.append(b.allocator, "-D_NETBSD_SOURCE") catch @panic("OOM");
    }
    return cc_flags_list.items;
}

fn createEpollShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const upstream = b.lazyDependency("epoll-shim", .{}) orelse return null;

    const have_eventfd = switch (target.result.os.tag) {
        .freebsd => target.result.os.isAtLeast(.freebsd, .{ .major = 13, .minor = 0, .patch = 0 }) orelse false,
        .netbsd => target.result.os.isAtLeast(.netbsd, .{ .major = 10, .minor = 0, .patch = 0 }) orelse false,
        .dragonfly, .openbsd => false,
        else => unreachable,
    };
    const have_timerfd = switch (target.result.os.tag) {
        .freebsd => target.result.os.isAtLeast(.freebsd, .{ .major = 12, .minor = 0, .patch = 0 }) orelse false,
        .netbsd => target.result.os.isAtLeast(.netbsd, .{ .major = 10, .minor = 0, .patch = 0 }) orelse false,
        .openbsd => false,
        .dragonfly => @panic("TODO"),
        else => unreachable,
    };
    const have_errno_t = switch (target.result.os.tag) {
        .dragonfly, .netbsd, .openbsd => false,
        .freebsd => true,
        else => unreachable,
    };
    // Whether `signal.h` defines `sigandset`, `sigorset` and `sigisemptyset`
    const have_sig_set_ops = switch (target.result.os.tag) {
        .freebsd => true,
        .dragonfly, .netbsd, .openbsd => false,
        else => unreachable,
    };

    const flags: []const []const u8 = &.{
        "-fvisibility=hidden",
        "-std=gnu11",
    };

    const epoll_shim = b.addLibrary(.{
        .name = "epoll-shim",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    var sources: std.ArrayList([]const u8) = .empty;
    var compat_sources: std.ArrayList([]const u8) = .empty;

    for ([_][]const u8{
        "epoll-shim/detail/common.h",
        "epoll-shim/detail/poll.h",
        "epoll-shim/detail/read.h",
        "epoll-shim/detail/write.h",
        "sys/epoll.h",
        "sys/signalfd.h",
    }) |path| {
        const config_header = b.addConfigHeader(.{
            .include_path = path,
            .style = .{ .cmake = upstream.path("include").path(b, path) },
        }, .{
            .POLLRDHUP_VALUE = @as(i64, if (target.result.isFreeBSDLibC()) 0x4000 else 0x2000),
        });
        epoll_shim.installConfigHeader(config_header);
        epoll_shim.root_module.addConfigHeader(config_header);
    }
    epoll_shim.root_module.linkSystemLibrary("pthread", .{});
    epoll_shim.root_module.addCMacro("EPOLL_SHIM_DISABLE_WRAPPER_MACROS", "");
    epoll_shim.root_module.addIncludePath(b.path(""));
    epoll_shim.root_module.addIncludePath(upstream.path("include"));
    epoll_shim.root_module.addIncludePath(upstream.path("external/queue-macros/include"));
    epoll_shim.root_module.addIncludePath(upstream.path("external/tree-macros/include/sys"));
    sources.append(b.allocator, "epoll_shim_ctx.c") catch @panic("OOM");
    sources.append(b.allocator, "epoll.c") catch @panic("OOM");
    sources.append(b.allocator, "epollfd_ctx.c") catch @panic("OOM");
    sources.append(b.allocator, "kqueue_event.c") catch @panic("OOM");
    sources.append(b.allocator, "signalfd.c") catch @panic("OOM");
    sources.append(b.allocator, "signalfd_ctx.c") catch @panic("OOM");
    sources.append(b.allocator, "timespec_util.c") catch @panic("OOM");
    sources.append(b.allocator, "rwlock.c") catch @panic("OOM");
    sources.append(b.allocator, "wrap.c") catch @panic("OOM");
    if (!have_eventfd) {
        epoll_shim.installHeader(upstream.path("include/sys/eventfd.h"), "sys/eventfd.h");
        sources.append(b.allocator, "eventfd.c") catch @panic("OOM");
        sources.append(b.allocator, "eventfd_ctx.c") catch @panic("OOM");
    }
    if (!have_timerfd) {
        epoll_shim.installHeader(upstream.path("include/sys/timerfd.h"), "sys/timerfd.h");
        sources.append(b.allocator, "timerfd.c") catch @panic("OOM");
        sources.append(b.allocator, "timerfd_ctx.c") catch @panic("OOM");
    } else {
        epoll_shim.root_module.addCMacro("HAVE_TIMERFD", "");
    }
    if (!have_errno_t) epoll_shim.root_module.addCMacro("errno_t", "int");

    if (!have_sig_set_ops) {
        compat_sources.append(b.allocator, "sigops") catch @panic("OOM");
    }

    if (target.result.os.tag.isDarwin()) {
        compat_sources.append(b.allocator, "pipe2") catch @panic("OOM");
        compat_sources.append(b.allocator, "socket") catch @panic("OOM");
        compat_sources.append(b.allocator, "socketpair") catch @panic("OOM");
        compat_sources.append(b.allocator, "itimerspec") catch @panic("OOM");
        compat_sources.append(b.allocator, "sem") catch @panic("OOM");
        compat_sources.append(b.allocator, "ppoll") catch @panic("OOM");
    }

    var compat_includes: std.Io.Writer.Allocating = .init(b.allocator);
    for (compat_sources.items) |name| {
        const upper_name = std.ascii.allocUpperString(b.allocator, name) catch @panic("OOM");
        epoll_shim.root_module.addCMacro(b.fmt("COMPAT_ENABLE_{s}", .{upper_name}), "");
        epoll_shim.root_module.addCSourceFile(.{
            .file = upstream.path(b.fmt("src/compat_{s}.c", .{name})),
            .flags = flags,
        });
        compat_includes.writer.print("#include \"compat_{s}.h\"\n", .{name}) catch @panic("OOM");
    }

    const compat_includes_written = compat_includes.written();
    if (compat_includes_written.len == 0) {
        epoll_shim.root_module.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = sources.items,
            .flags = flags,
        });
    } else {
        const write_files = b.addWriteFiles();
        epoll_shim.root_module.addIncludePath(upstream.path("src"));
        for (sources.items) |src| {
            const wrapped_src = write_files.add(b.fmt("wrapped_{s}", .{src}), b.fmt("{s}#include \"{s}\"", .{ compat_includes_written, src }));
            epoll_shim.root_module.addCSourceFile(.{ .file = wrapped_src, .flags = flags });
        }
    }

    return epoll_shim;
}

comptime {
    if (version.major != 1) {
        // The versioning used for the shared libraries assumes that the major
        // version of Wayland as a whole will increase to 2 if and only if there
        // is an ABI break, at which point we should probably bump the SONAME of
        // all libraries to .so.2. For more details see
        // https://gitlab.freedesktop.org/wayland/wayland/-/merge_requests/177
        @compileError(
            \\We probably need to bump the SONAME of libwayland-server and -client
            \\We probably need to bump the SONAME of libwayland-cursor
        );
    }
}
