const std = @import("std");

/// Thread-safe general purpose allocator used across the invoker.
pub const gpa = std.heap.c_allocator;
