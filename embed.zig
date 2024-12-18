//! This is embed.py ported to Zig:
//! https://gitlab.freedesktop.org/wayland/wayland/-/blob/main/src/embed.py
//!
//! Simple C data embedder
//!
//! License: MIT
//!
//! Copyright (c) 2020 Simon Ser
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.

const std = @import("std");

pub fn main() !void {
    var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len != 3) {
        try stderr.print("usage: {s} <filename> <ident>\n", .{args[0]});
        std.process.exit(1);
    }
    const filename = args[1];
    const ident = args[2];

    const buf = try std.fs.cwd().readFileAlloc(gpa, filename, std.math.maxInt(u32));
    defer gpa.free(buf);

    try stdout.print("static const char {s}[] = {{\n\t", .{ident});
    for (buf) |c| {
        try stdout.print("0x{x:0>2}, ", .{c});
    }
    try stdout.print("\n}};\n", .{});
}
