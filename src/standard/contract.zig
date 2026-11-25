const std = @import("std");
const resource = @import("resource");

pub const max_source = 1 << 20;
pub const max_file = 1 << 20;
pub const max_tests = 64;
pub const max_payload = 16 << 20;
pub const max_history = 2 << 20;
pub const Language = enum { posix_sh, javascript };
pub const Checker = enum { exact_bytes, ascii_tokens };
pub const Group = struct { id: []const u8, scoring: enum { sum, all_or_nothing } };
pub const Case = struct { id: []const u8, group: []const u8, input: []const u8, answer: []const u8, points_milli: u32 };
pub const Task = struct {
    version: u32,
    language: Language,
    build: enum { package_source },
    checker: Checker,
    limits: resource.Request,
    groups: []const Group,
    tests: []const Case,
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Task) {
    if (bytes.len > 64 << 10 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidStandardTask;
    const parsed = try std.json.parseFromSlice(Task, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedStandardVersion;
    const task = parsed.value;
    _ = try resource.Policy.resolve(task.limits, .{});
    if (task.limits.output_bytes > max_history or task.tests.len == 0 or task.tests.len > max_tests or
        task.groups.len == 0 or task.groups.len > task.tests.len) return error.InvalidStandardTask;
    var used: [max_tests]bool = @splat(false);
    for (task.groups, 0..) |g, i| {
        if (!identifier(g.id)) return error.InvalidStandardGroup;
        for (task.groups[0..i]) |prev| if (std.mem.eql(u8, prev.id, g.id)) return error.DuplicateStandardGroup;
    }
    for (task.tests, 0..) |t, i| {
        if (!identifier(t.id) or !testPath(t.input) or !testPath(t.answer)) return error.InvalidStandardTest;
        for (task.tests[0..i]) |prev| if (std.mem.eql(u8, prev.id, t.id)) return error.DuplicateStandardTest;
        used[try groupIndex(task.groups, t.group)] = true;
    }
    for (used[0..task.groups.len]) |has_tests| if (!has_tests) return error.EmptyStandardGroup;
    return parsed;
}

pub fn groupIndex(groups: []const Group, id: []const u8) !usize {
    for (groups, 0..) |g, i| if (std.mem.eql(u8, g.id, id)) return i;
    return error.UnknownStandardGroup;
}

fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

fn testPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "tests/") or path.len > 200) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return count <= 16;
}

pub fn matches(checker: Checker, actual: []const u8, expected: []const u8) bool {
    if (checker == .exact_bytes) return std.mem.eql(u8, actual, expected);
    var left = std.mem.tokenizeAny(u8, actual, " \t\n\r\x0b\x0c");
    var right = std.mem.tokenizeAny(u8, expected, " \t\n\r\x0b\x0c");
    while (left.next()) |value| {
        const expected_token = right.next() orelse return false;
        if (!std.mem.eql(u8, value, expected_token)) return false;
    }
    return right.next() == null;
}

pub const GroupScore = struct {
    maximum: u64 = 0,
    earned: u64 = 0,
    all_passed: bool = true,

    pub fn record(self: *GroupScore, points: u32, passed: bool) void {
        self.maximum += points;
        if (passed) self.earned += points else self.all_passed = false;
    }

    pub fn value(self: GroupScore, mode: Group) u64 {
        return switch (mode.scoring) {
            .sum => self.earned,
            .all_or_nothing => if (self.all_passed) self.maximum else 0,
        };
    }
};

test "checkers distinguish binary output, missing tokens and extra tokens" {
    const t = std.testing;
    try t.expect(matches(.exact_bytes, "a\x00b", "a\x00b"));
    try t.expect(!matches(.exact_bytes, "a\n", "a"));
    try t.expect(matches(.ascii_tokens, "\t42 \r\na", "42 a\n"));
    try t.expect(!matches(.ascii_tokens, "42 a b", "42 a"));
    try t.expect(!matches(.ascii_tokens, "42", "42 a"));
    try t.expect(!matches(.ascii_tokens, "a\x00b", "a b"));
}

test "all-or-nothing fails even when a zero-point test fails" {
    var score: GroupScore = .{};
    score.record(1001, true);
    score.record(0, false);
    try std.testing.expectEqual(@as(u64, 1001), score.value(.{ .id = "g", .scoring = .sum }));
    try std.testing.expectEqual(@as(u64, 0), score.value(.{ .id = "g", .scoring = .all_or_nothing }));
}

test "standard v1 rejects unknown features, unsafe paths and excessive limits" {
    const a = std.testing.allocator;
    const valid = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{\"memory_bytes\":67108864,\"swap_bytes\":0,\"pids\":32,\"cpu_quota_micros\":100000,\"wall_ms\":1000,\"output_bytes\":4096},\"groups\":[{\"id\":\"g\",\"scoring\":\"sum\"}],\"tests\":[{\"id\":\"t\",\"group\":\"g\",\"input\":\"tests/in\",\"answer\":\"tests/out\",\"points_milli\":1000}]}";
    var parsed = try parse(a, valid);
    defer parsed.deinit();
    try std.testing.expectEqual(Language.posix_sh, parsed.value.language);

    const invalid = [_]struct { json: []const u8, failure: anyerror }{
        .{ .json = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"custom\",\"checker\":\"exact_bytes\",\"limits\":{},\"groups\":[],\"tests\":[]}", .failure = error.InvalidEnumTag },
        .{ .json = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{\"memory_bytes\":67108864,\"swap_bytes\":0,\"pids\":32,\"cpu_quota_micros\":100000,\"wall_ms\":1000,\"output_bytes\":4096},\"groups\":[{\"id\":\"g\",\"scoring\":\"sum\"}],\"tests\":[{\"id\":\"t\",\"group\":\"g\",\"input\":\"tests/../secret\",\"answer\":\"tests/out\",\"points_milli\":1000}]}", .failure = error.InvalidStandardTest },
        .{ .json = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{},\"groups\":[],\"tests\":[],\"interactor\":true}", .failure = error.UnknownField },
        .{ .json = "{\"version\":1,\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{},\"groups\":[],\"tests\":[]}", .failure = error.DuplicateField },
        .{ .json = "{\"version\":2,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{},\"groups\":[],\"tests\":[]}", .failure = error.UnsupportedStandardVersion },
        .{ .json = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{\"memory_bytes\":67108864,\"swap_bytes\":0,\"pids\":129,\"cpu_quota_micros\":100000,\"wall_ms\":1000,\"output_bytes\":4096},\"groups\":[{\"id\":\"g\",\"scoring\":\"sum\"}],\"tests\":[{\"id\":\"t\",\"group\":\"g\",\"input\":\"tests/in\",\"answer\":\"tests/out\",\"points_milli\":1000}]}", .failure = error.InvalidResourceRequest },
        .{ .json = "{\"version\":1,\"language\":\"posix_sh\",\"build\":\"package_source\",\"checker\":\"exact_bytes\",\"limits\":{\"memory_bytes\":67108864,\"swap_bytes\":0,\"pids\":32,\"cpu_quota_micros\":100000,\"wall_ms\":1000,\"output_bytes\":4096},\"groups\":[{\"id\":\"g\",\"scoring\":\"sum\"}],\"tests\":[{\"id\":\"t\",\"group\":\"missing\",\"input\":\"tests/in\",\"answer\":\"tests/out\",\"points_milli\":1000}]}", .failure = error.UnknownStandardGroup },
    };
    for (invalid) |item| {
        try std.testing.expectError(item.failure, parse(a, item.json));
    }
}
