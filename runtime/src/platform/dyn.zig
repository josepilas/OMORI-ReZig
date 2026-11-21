//! Thin dlopen/dlsym wrappers (glibc exposes these in libc since 2.34;
//! PortMaster targets are covered by both the libc and libdl paths).

const std = @import("std");

pub const RTLD_NOW: c_int = 0x2;
pub const RTLD_GLOBAL: c_int = 0x100;

extern fn dlopen(path: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
extern fn dlerror() ?[*:0]u8;

/// Load a shared library by soname.
pub fn open(path: [:0]const u8, flags: c_int) ?*anyopaque {
    _ = dlerror(); // clear stale error state
    const h = dlopen(path.ptr, flags);
    if (h == null) {
        last_error = dlerror();
    } else {
        last_error = null;
    }
    return h;
}

/// The dlerror() string of the most recent failed open (best-effort,
/// static storage — read it right after a failed open()).
pub var last_error: ?[*:0]u8 = null;

/// Null-terminated error slice, or a placeholder.
pub fn errorString() []const u8 {
    if (last_error) |e| return std.mem.span(e);
    return "(no dlerror)";
}

/// Resolve a symbol; null when missing.
pub fn sym(handle: *anyopaque, symbol: [:0]const u8) ?*anyopaque {
    return dlsym(handle, symbol.ptr);
}

pub fn close(handle: *anyopaque) c_int {
    return dlclose(handle);
}

test "dlopen finds libc itself" {
    const h = open("libc.so.6", RTLD_NOW);
    try std.testing.expect(h != null);
    // A symbol that must exist.
    try std.testing.expect(sym(h.?, "malloc") != null);
    // A symbol that must not.
    try std.testing.expect(sym(h.?, "omori_native_never_exists") == null);
}
