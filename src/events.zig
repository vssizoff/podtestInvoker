const std = @import("std");
const gpa = @import("util/mem.zig").gpa;

/// An event produced by a run and forwarded to the backend over the gRPC
/// stream.  Strings are owned by the event; the sink takes ownership and is
/// responsible for calling `deinit`.
pub const Event = union(enum) {
    test_started: struct { n: u32 },
    test_verdict: struct {
        n: u32,
        verdict: []u8,
        score: ?f64,
        grader_data: ?[]u8,
    },
    subgroup_score: struct {
        id: []u8,
        score: f64,
        grader_data: ?[]u8,
    },
    problem_score: struct {
        score: f64,
        grader_data: ?[]u8,
    },
    build_log: struct { text: []u8 },
    test_stdio: struct {
        n: u32,
        stdin: []u8,
        stdout: []u8,
        stderr: []u8,
    },
    runner_error: struct {
        message: []u8,
        traceback: []u8,
    },
    run_finished: struct {
        ok: bool,
        status: []u8,
    },
    run_timeout: struct {},

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .test_started => {},
            .test_verdict => |*v| {
                gpa.free(v.verdict);
                if (v.grader_data) |d| gpa.free(d);
            },
            .subgroup_score => |*v| {
                gpa.free(v.id);
                if (v.grader_data) |d| gpa.free(d);
            },
            .problem_score => |*v| {
                if (v.grader_data) |d| gpa.free(d);
            },
            .build_log => |*v| gpa.free(v.text),
            .test_stdio => |*v| {
                gpa.free(v.stdin);
                gpa.free(v.stdout);
                gpa.free(v.stderr);
            },
            .runner_error => |*v| {
                gpa.free(v.message);
                gpa.free(v.traceback);
            },
            .run_finished => |*v| gpa.free(v.status),
            .run_timeout => {},
        }
        self.* = undefined;
    }
};

pub const Sink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, ev: Event) void,

    pub fn emit(self: Sink, ev: Event) void {
        self.emit_fn(self.ctx, ev);
    }
};

pub fn dup(s: []const u8) ![]u8 {
    return gpa.dupe(u8, s);
}

/// Simple in-memory sink useful for tests and for runs without a live stream.
pub const Collector = struct {
    mutex: @import("util/mutex.zig").Mutex = .{},
    events: std.ArrayList(Event) = .empty,

    pub fn sink(self: *Collector) Sink {
        return .{ .ctx = self, .emit_fn = emitFn };
    }

    fn emitFn(ctx: *anyopaque, ev: Event) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(gpa, ev) catch {
            var e = ev;
            e.deinit();
        };
    }

    pub fn deinit(self: *Collector) void {
        for (self.events.items) |*e| e.deinit();
        self.events.deinit(gpa);
    }
};
