const std = @import("std");
const Verdict = @import("result.zig").Verdict;

pub const compiler_command: []const []const u8 = &.{ "/bin/sh", "-ec", "umask 077; cd /tmp; tar -xf -; /usr/local/bin/g++ -std=c++23 -O0 -DPC_BASE_EXIT_CODE=50 -DENABLE_UNEXPECTED_EOF checker.cpp -o checker; cat checker" };

pub const command: []const []const u8 = &.{ "/bin/sh", "-ec", "umask 077; cd /tmp; tar -xf -; exec /podtest-checker --testset \"$1\" --group \"$2\" input output answer /dev/stdout -appes", "testlib" };

pub fn pack(a: std.mem.Allocator, input: []const u8, actual: []const u8, answer: []const u8) ![]const u8 {
    return packFiles(a, &.{ "input", "output", "answer" }, &.{ input, actual, answer });
}

pub fn packFiles(a: std.mem.Allocator, names: []const []const u8, files: []const []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (names, files) |name, data| try tar.writeFileBytes(name, data, .{ .mode = 0o600 });
    try tar.finishPedantically();
    return out.toOwnedSlice();
}

pub const Decision = struct { verdict: Verdict, points: u32 = 0 };

pub fn decide(code: i32, report: []const u8, maximum: u32) Decision {
    const failed: Decision = .{ .verdict = .testing_error };
    const root = "<result outcome = \"";
    const close = "</result>";
    const xml_prefix = "<?xml version=\"1.0\" encoding=\"";
    var xml = std.mem.trim(u8, report, " \r\n\t");
    if (std.mem.startsWith(u8, xml, xml_prefix)) {
        const tail = xml[xml_prefix.len..];
        const end = std.mem.indexOfScalar(u8, tail, '"') orelse return failed;
        if (end == 0 or !std.mem.startsWith(u8, tail[end..], "\"?>")) return failed;
        for (tail[0..end]) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return failed;
        xml = std.mem.trimStart(u8, tail[end + 3 ..], " \r\n\t");
    }
    if (!std.mem.startsWith(u8, xml, root) or !std.mem.endsWith(u8, xml, close)) return failed;
    const element = xml[root.len .. xml.len - close.len];
    const end = std.mem.indexOfScalar(u8, element, '>') orelse return failed;
    if (std.mem.indexOfAny(u8, element[end + 1 ..], "<\x00") != null) return failed;
    const tag = element[0..end];
    const eq = std.mem.eql;
    switch (code) {
        0 => if (eq(u8, tag, "accepted\"")) return .{ .verdict = .accepted, .points = maximum },
        1 => if (eq(u8, tag, "wrong-answer\"")) return .{ .verdict = .wrong_answer },
        2, 4, 8 => if (eq(u8, tag, "presentation-error\"") or eq(u8, tag, "unexpected-eof\"")) return .{ .verdict = .presentation_error },
        7 => if (attribute(tag, "points\" points = \"")) |value| {
            const fraction = std.fmt.parseFloat(f64, value) catch return failed;
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return failed;
            return .{ .verdict = .partial, .points = @intFromFloat(@round(fraction * @as(f64, @floatFromInt(maximum)))) };
        },
        50...150 => if (attribute(tag, "partially-correct\" pctype = \"")) |value| {
            const percent = std.fmt.parseInt(u32, value, 10) catch return failed;
            if (percent != code - 50) return failed;
            return .{ .verdict = .partial, .points = @intCast((@as(u64, maximum) * percent + 50) / 100) };
        },
        else => {},
    }
    return failed;
}

fn attribute(tag: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, tag, prefix) or !std.mem.endsWith(u8, tag, "\"") or tag.len <= prefix.len + 1) return null;
    return tag[prefix.len .. tag.len - 1];
}

test "testlib distinguishes contestant outcomes, partial credit and broken reports" {
    try std.testing.expectEqual(Decision{ .verdict = .partial, .points = 251 }, decide(7, "<result outcome = \"points\" points = \"0.25\">ok</result>", 1002));
    try std.testing.expectEqual(Verdict.accepted, decide(0, "<result outcome = \"accepted\">ok</result>", 1000).verdict);
    try std.testing.expectEqual(Verdict.wrong_answer, decide(1, "<result outcome = \"wrong-answer\">bad</result>", 1000).verdict);
    try std.testing.expectEqual(Verdict.testing_error, decide(3, "<result outcome = \"fail\">bad</result>", 1000).verdict);
    try std.testing.expectEqual(Verdict.testing_error, decide(0, "missing report", 1000).verdict);
    try std.testing.expectEqual(Verdict.testing_error, decide(0, "noise<result outcome = \"accepted\">ok</result>", 1000).verdict);
    try std.testing.expectEqual(Verdict.testing_error, decide(0, "<result outcome = \"accepted\">ok</result></result>", 1000).verdict);
    try std.testing.expectEqual(Verdict.accepted, decide(0, "<?xml version=\"1.0\" encoding=\"windows-1251\"?><result outcome = \"accepted\">a &lt; b</result>\n", 1000).verdict);
}
