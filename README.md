[![CI](https://github.com/allyourcodebase/wayland/actions/workflows/ci.yaml/badge.svg)](https://github.com/allyourcodebase/wayland/actions)

# Wayland

This is [Wayland](https://gitlab.freedesktop.org/wayland/wayland), packaged for [Zig](https://ziglang.org/).

## Installation

First, update your `build.zig.zon`:

```
# Initialize a `zig build` project if you haven't already
zig init
zig fetch --save git+https://github.com/allyourcodebase/wayland.git#1.23.1-4
```

You can then import `wayland` in your `build.zig` with:

```zig
const wayland = b.dependency("wayland", .{
    .target = target,
    .optimize = optimize,
});
const wayland_server = wayland.artifact("wayland-server");
const wayland_client = wayland.artifact("wayland-client");
const wayland_egl = wayland.artifact("wayland-egl");
const wayland_cursor = wayland.artifact("wayland-cursor");

// Makes sure we get `wayland-scanner` for the host platform even when cross-compiling
const wayland_host = b.dependency("wayland", .{
    .target = b.host,
    .optimize = std.builtin.OptimizeMode.Debug,
});
const wayland_scanner = wayland_host.artifact("wayland-scanner");
```
