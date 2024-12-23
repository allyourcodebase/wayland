const std = @import("std");

const version: std.SemanticVersion = .{ .major = 1, .minor = 23, .patch = 1 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("wayland", .{});

    const dtd_validation = b.option(bool, "dtd-validation", "Validate the protocol DTD") orelse true;
    const icon_directory = b.option([]const u8, "icon-directory", "Location used to look for cursors (defaults to ${datadir}/icons if unset)");

    const need_epoll_shim = switch (target.result.os.tag) {
        .freebsd, .openbsd => true,
        else => false,
    };

    const link_system_expat = b.systemIntegrationOption("expat", .{});
    const link_system_ffi = b.systemIntegrationOption("ffi", .{});

    const cc_flags = blk: {
        var cc_flags_list: std.ArrayListUnmanaged([]const u8) = .{};
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
        break :blk cc_flags_list.items;
    };

    const wayland_version_header = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("src/wayland-version.h.in") },
    }, .{
        .WAYLAND_VERSION_MAJOR = @as(i64, @intCast(version.major)),
        .WAYLAND_VERSION_MINOR = @as(i64, @intCast(version.minor)),
        .WAYLAND_VERSION_MICRO = @as(i64, @intCast(version.patch)),
        .WAYLAND_VERSION = b.fmt("{}", .{version}),
    });

    const wayland_util = createWaylandUtil(b, target, optimize, upstream, cc_flags);
    const wayland_util_host = createWaylandUtil(b, b.host, optimize, upstream, cc_flags);

    const wayland_scanner_args: CreateWaylandScannerArgs = .{
        .dtd_validation = dtd_validation,
        .cc_flags = cc_flags,
        .wayland = upstream,
        .wayland_version_header = wayland_version_header,
    };

    const wayland_scanner = createWaylandScanner(b, target, optimize, wayland_scanner_args);
    wayland_scanner.linkLibrary(wayland_util);
    b.installArtifact(wayland_scanner);

    const wayland_scanner_host = createWaylandScanner(b, b.host, optimize, wayland_scanner_args);
    wayland_scanner_host.linkLibrary(wayland_util_host);

    if (link_system_expat) {
        wayland_scanner.linkSystemLibrary("expat"); // This is going to fail when cross-compiling
        wayland_scanner_host.linkSystemLibrary("expat");
    } else {
        if (b.lazyDependency("libexpat", .{
            .target = target,
            .optimize = optimize,
        })) |expat| {
            wayland_scanner.linkLibrary(expat.artifact("expat"));
        }
        if (b.lazyDependency("libexpat", .{
            .target = b.host,
            .optimize = optimize,
        })) |expat_host| {
            wayland_scanner_host.linkLibrary(expat_host.artifact("expat"));
        }
    }

    const wayland_header = b.addConfigHeader(.{}, .{
        .PACKAGE = "wayland",
        .PACKAGE_VERSION = b.fmt("{}", .{version}),
        .HAVE_SYS_PRCTL_H = true, // sys/prctl.h
        .HAVE_SYS_PROCCTL_H = null, // sys/procctl.h
        .HAVE_SYS_UCRED_H = if (target.result.os.tag == .macos) true else null, // sys/ucred.h
        .HAVE_ACCEPT4 = true,
        .HAVE_MKOSTEMP = true,
        .HAVE_POSIX_FALLOCATE = true,
        .HAVE_PRCTL = true,
        .HAVE_MEMFD_CREATE = true,
        .HAVE_MREMAP = true,
        .HAVE_STRNDUP = true,
        .HAVE_BROKEN_MSG_CMSG_CLOEXEC = false, // // TODO check freebsd version
        .HAVE_XUCRED_CR_PID = false, // TODO
    });

    const wayland_private = blk: {
        const write_files = b.addWriteFiles();
        _ = write_files.addCopyFile(wayland_header.getOutput(), "config.h");
        const wayland_header2 = write_files.addCopyFile(wayland_header.getOutput(), "config/config.h");

        const wayland_private = b.addStaticLibrary(.{
            .name = "wayland-private",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wayland_private.addIncludePath(wayland_header2.dirname());
        wayland_private.addIncludePath(upstream.path(""));
        wayland_private.addCSourceFiles(.{
            .files = &.{
                "connection.c",
                "wayland-os.c",
            },
            .root = upstream.path("src"),
            .flags = cc_flags,
        });
        if (need_epoll_shim) wayland_private.linkSystemLibrary("epoll-shim");
        wayland_private.linkSystemLibrary("rt");
        if (link_system_ffi) {
            wayland_private.linkSystemLibrary("ffi");
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_private.linkLibrary(libffi.artifact("ffi"));
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
        const wayland_server = b.addStaticLibrary(.{
            .name = "wayland-server",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-server.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        });
        b.installArtifact(wayland_server);
        wayland_server.linkLibrary(wayland_private);
        wayland_server.linkLibrary(wayland_util);
        wayland_server.addConfigHeader(wayland_version_header);
        wayland_server.addConfigHeader(wayland_header);
        wayland_server.addIncludePath(upstream.path("src"));
        wayland_server.addIncludePath(wayland_server_protocol_core_h.dirname());
        wayland_server.addIncludePath(wayland_server_protocol_h.dirname());
        wayland_server.installHeader(wayland_server_protocol_core_h, "wayland-server-protocol-core.h");
        wayland_server.installHeader(wayland_server_protocol_h, "wayland-server-protocol.h");
        wayland_server.installHeader(upstream.path("src/wayland-server.h"), "wayland-server.h");
        wayland_server.installHeader(upstream.path("src/wayland-server-core.h"), "wayland-server-core.h");
        wayland_server.installLibraryHeaders(wayland_util); // required by wayland-server-core.h
        wayland_server.installConfigHeader(wayland_version_header); // required by wayland-server-core.h
        wayland_server.addCSourceFile(.{
            .file = wayland_protocol_c,
            .flags = cc_flags,
        });
        wayland_server.addCSourceFiles(.{
            .files = &.{
                "wayland-shm.c",
                "event-loop.c",
            },
            .root = upstream.path("src"),
            .flags = cc_flags,
        });
        if (need_epoll_shim) wayland_server.linkSystemLibrary("epoll-shim");
        wayland_server.linkSystemLibrary("rt");
        if (link_system_ffi) {
            wayland_server.linkSystemLibrary("ffi");
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_server.linkLibrary(libffi.artifact("ffi"));
        }
    }

    const wayland_client = blk: {
        const wayland_client = b.addStaticLibrary(.{
            .name = "wayland-client",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-client.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        });
        b.installArtifact(wayland_client);
        wayland_client.linkLibrary(wayland_private);
        wayland_client.linkLibrary(wayland_util);
        wayland_client.addConfigHeader(wayland_version_header);
        wayland_client.addConfigHeader(wayland_header);
        wayland_client.addIncludePath(upstream.path("src"));
        wayland_client.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_client.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_client.installHeader(wayland_client_protocol_core_h, "wayland-client-protocol-core.h");
        wayland_client.installHeader(wayland_client_protocol_h, "wayland-client-protocol.h");
        wayland_client.installHeader(upstream.path("src/wayland-client.h"), "wayland-client.h");
        wayland_client.installHeader(upstream.path("src/wayland-client-core.h"), "wayland-client-core.h");
        wayland_client.installLibraryHeaders(wayland_util); // required by wayland-client-core.h
        wayland_client.installConfigHeader(wayland_version_header); // required by wayland-client-core.h
        wayland_client.addCSourceFile(.{
            .file = wayland_protocol_c,
            .flags = cc_flags,
        });
        wayland_client.addCSourceFile(.{
            .file = upstream.path("src/wayland-client.c"),
            .flags = cc_flags,
        });

        if (need_epoll_shim) wayland_client.linkSystemLibrary("epoll-shim");
        wayland_client.linkSystemLibrary("rt");
        if (link_system_ffi) {
            wayland_client.linkSystemLibrary("ffi");
        } else if (b.lazyDependency("libffi", .{
            .target = target,
            .optimize = optimize,
        })) |libffi| {
            wayland_client.linkLibrary(libffi.artifact("ffi"));
        }

        break :blk wayland_client;
    };

    {
        const wayland_egl = b.addStaticLibrary(.{
            .name = "wayland-egl",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .version = version,
        });
        b.installArtifact(wayland_egl);
        wayland_egl.linkLibrary(wayland_client);
        wayland_egl.addConfigHeader(wayland_version_header);
        wayland_egl.addConfigHeader(wayland_header);
        wayland_egl.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_egl.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_egl.installHeader(upstream.path("egl/wayland-egl.h"), "wayland-egl.h");
        wayland_egl.installHeader(upstream.path("egl/wayland-egl-core.h"), "wayland-egl-core.h");
        wayland_egl.installHeader(upstream.path("egl/wayland-egl-backend.h"), "wayland-egl-backend.h");
        wayland_egl.addCSourceFile(.{
            .file = upstream.path("egl/wayland-egl.c"),
            .flags = cc_flags,
        });
    }

    {
        const wayland_cursor = b.addStaticLibrary(.{
            .name = "wayland-cursor",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // To avoid an unnecessary SONAME bump, wayland 1.x.y produces
            // libwayland-cursor.so.0.x.y.
            .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        });
        b.installArtifact(wayland_cursor);
        wayland_cursor.linkLibrary(wayland_client);
        wayland_cursor.addConfigHeader(wayland_version_header);
        wayland_cursor.addConfigHeader(wayland_header);
        wayland_cursor.addIncludePath(wayland_client_protocol_core_h.dirname());
        wayland_cursor.addIncludePath(wayland_client_protocol_h.dirname());
        wayland_cursor.installHeader(upstream.path("cursor/wayland-cursor.h"), "wayland-cursor.h");
        if (icon_directory) |dir| wayland_cursor.root_module.addCMacro("ICONDIR", dir);
        wayland_cursor.addCSourceFiles(.{
            .files = &.{
                "wayland-cursor.c",
                "os-compatibility.c",
                "xcursor.c",
            },
            .root = upstream.path("cursor"),
            .flags = cc_flags,
        });
    }

    const added_named_lazy_path_version = comptime std.SemanticVersion.parse("0.14.0-dev.1576+5d7fa5513") catch unreachable;

    if (comptime @import("builtin").zig_version.order(added_named_lazy_path_version) != .lt) {
        b.addNamedLazyPath("wayland-xml", upstream.path("protocol/wayland.xml"));
        b.addNamedLazyPath("wayland.dtd", upstream.path("protocol/wayland.dtd"));
    }

    const protocol = b.addNamedWriteFiles("protocol");
    _ = protocol.addCopyFile(upstream.path("protocol/wayland.xml"), "wayland.xml");
    _ = protocol.addCopyFile(upstream.path("protocol/wayland.dtd"), "wayland.dtd");
}

fn createWaylandUtil(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wayland: *std.Build.Dependency,
    cc_flags: []const []const u8,
) *std.Build.Step.Compile {
    const wayland_util = b.addStaticLibrary(.{
        .name = "wayland-util",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wayland_util.installHeader(wayland.path("src/wayland-util.h"), "wayland-util.h");
    wayland_util.addCSourceFile(.{
        .file = wayland.path("src/wayland-util.c"),
        .flags = cc_flags,
    });
    return wayland_util;
}

const CreateWaylandScannerArgs = struct {
    dtd_validation: bool,
    cc_flags: []const []const u8,
    wayland: *std.Build.Dependency,
    wayland_version_header: *std.Build.Step.ConfigHeader,
};

fn createWaylandScanner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: CreateWaylandScannerArgs,
) *std.Build.Step.Compile {
    const wayland_scanner = b.addExecutable(.{
        .name = "wayland-scanner",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wayland_scanner.addConfigHeader(args.wayland_version_header);
    wayland_scanner.addCSourceFile(.{
        .file = args.wayland.path("src/scanner.c"),
        .flags = args.cc_flags,
    });
    wayland_scanner.addIncludePath(args.wayland.path(""));
    wayland_scanner.addIncludePath(args.wayland.path("protocol"));

    if (args.dtd_validation) {
        const embed_exe = b.addExecutable(.{
            .name = "embed",
            .root_source_file = b.path("embed.zig"),
            .target = b.host,
        });
        const run_embed = b.addRunArtifact(embed_exe);
        run_embed.addFileArg(args.wayland.path("protocol/wayland.dtd"));
        run_embed.addArg("wayland_dtd");

        const write_files = b.addWriteFiles();
        const wayland_dtd = write_files.addCopyFile(run_embed.captureStdOut(), "wayland.dtd.h");
        wayland_scanner.addIncludePath(wayland_dtd.dirname());

        const link_system_libxml = b.systemIntegrationOption("libxml2", .{});
        if (link_system_libxml) {
            wayland_scanner.linkSystemLibrary("libxml-2.0");
        } else if (b.lazyDependency("libxml2", .{
            .target = target,
            .optimize = optimize,
            .minimum = true,
            .valid = true,
        })) |libxml2| {
            wayland_scanner.linkLibrary(libxml2.artifact("xml"));
        }

        wayland_scanner.root_module.addCMacro("HAVE_LIBXML", "1");
    }

    return wayland_scanner;
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
