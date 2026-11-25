const std = @import("std");

pub const max_bytes = 8192;

pub const Job = struct {
    schema_version: u32,
    job_id: []const u8,
    run_id: []const u8,
    judging_attempt_id: []const u8,
    submission_id: []const u8,
    task_id: []const u8,
    task_revision_id: []const u8,
    contest_id: []const u8,
    contest_problem_id: []const u8,
    execution_format: enum { standard, scripted_lua },
    execution_format_version: u32,
    created_at: []const u8,
};

/// The returned Parsed owns its strings independently of the delivery buffer.
pub fn parse(allocator: std.mem.Allocator, payload: []const u8) error{ InvalidAdvertisement, OutOfMemory }!std.json.Parsed(Job) {
    if (payload.len > max_bytes or !std.unicode.utf8ValidateSlice(payload)) return error.InvalidAdvertisement;
    const parsed = std.json.parseFromSlice(Job, allocator, payload, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAdvertisement,
    };
    errdefer parsed.deinit();
    const job = parsed.value;
    if (job.schema_version != 1 or job.execution_format_version != 1) return error.InvalidAdvertisement;
    const ids = [_][]const u8{ job.job_id, job.run_id, job.judging_attempt_id, job.submission_id, job.task_id, job.task_revision_id, job.contest_id, job.contest_problem_id };
    for (ids) |id| {
        if (!validId(id)) return error.InvalidAdvertisement;
    }
    if (!validTimestamp(job.created_at)) return error.InvalidAdvertisement;
    return parsed;
}

pub fn validId(id: []const u8) bool {
    if (id.len != 36) return false;
    var nonzero = false;
    for (id, 0..) |byte, index| {
        switch (index) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => {
                // Require canonical lowercase IDs so local lookups have a single key.
                if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
                nonzero = nonzero or byte != '0';
            },
        }
    }
    return nonzero;
}

fn digits(s: []const u8) ?u32 {
    var value: u32 = 0;
    for (s) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + byte - '0';
    }
    return value;
}

// RFC 3339 form emitted by Go, with optional fractional seconds and UTC offset.
fn validTimestamp(s: []const u8) bool {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return false;
    const year = digits(s[0..4]) orelse return false;
    const month = digits(s[5..7]) orelse return false;
    const day = digits(s[8..10]) orelse return false;
    const hour = digits(s[11..13]) orelse return false;
    const minute = digits(s[14..16]) orelse return false;
    const second = digits(s[17..19]) orelse return false;
    if (month < 1 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 59) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > days[month - 1]) return false;
    var zone: usize = 19;
    if (s[zone] == '.') {
        zone += 1;
        while (zone < s.len and std.ascii.isDigit(s[zone])) zone += 1;
        if (zone == 20 or zone > 29) return false;
    }
    const suffix = s[zone..];
    if (std.mem.eql(u8, suffix, "Z")) return true;
    if (suffix.len != 6 or (suffix[0] != '+' and suffix[0] != '-') or suffix[3] != ':') return false;
    return (digits(suffix[1..3]) orelse return false) < 24 and (digits(suffix[4..6]) orelse return false) < 60;
}

pub const test_payload =
    \\{"schema_version":1,"execution_format_version":1,"execution_format":"standard",
    \\"job_id":"e331802b-6ed9-42e1-abc8-de75c283e22b","run_id":"3161aba5-dc25-4152-bc15-cd4306518803",
    \\"judging_attempt_id":"c3d405b6-5b28-4a65-bf22-af86a3306852","submission_id":"ad4f2847-37da-441a-acc0-ebde86c47f66",
    \\"task_id":"b946043a-ae61-464d-a46c-ea05eadd5889","task_revision_id":"98953b32-25ee-47f0-9bce-e6468e316b05",
    \\"contest_id":"ad4f2847-37da-441a-acc0-ebde86c47f66","contest_problem_id":"a369b354-9c66-40a3-8171-1ab90377468d",
    \\"created_at":"2026-11-24T12:00:00Z"}
;

test "advertisement parsing rejects unsupported versions, formats and invalid IDs" {
    const a = std.testing.allocator;
    const parsed = try parse(a, test_payload);
    defer parsed.deinit();
    try std.testing.expectEqual(.standard, parsed.value.execution_format);
    const cases = [_][2][]const u8{
        .{ "\"schema_version\":1", "\"schema_version\":2" },
        .{ "\"schema_version\":1", "\"schema_version\":1,\"schema_version\":1" },
        .{ "\"execution_format_version\":1", "\"execution_format_version\":2" },
        .{ "standard", "unknown" },
        .{ "3161aba5-dc25-4152-bc15-cd4306518803", "../../run" },
        .{ "2026-11-24", "2026-02-29" },
    };
    for (cases) |pair| {
        const payload = try std.mem.replaceOwned(u8, a, test_payload, pair[0], pair[1]);
        defer a.free(payload);
        try std.testing.expectError(error.InvalidAdvertisement, parse(a, payload));
    }
    try std.testing.expect(validTimestamp("2024-02-29T00:00:00.123456789+02:00"));
}
