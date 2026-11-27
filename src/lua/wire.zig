pub const version = 1;
pub const run_id_len = 16;
pub const max_payload = 16 * 1024;
pub const Token = [32]u8;
pub const Bootstrap = extern struct {
    deadline_ms: u64,
    script_len: u32,
    run_id: [run_id_len]u8,
    token: Token,
    version: u32 = version,
};
pub const Request = extern struct {
    id: u64,
    deadline_ms: u64,
    run_id: [run_id_len]u8,
    token: Token,
    version: u32,
    method: u32,
    payload: [max_payload]u8,
};

extern "c" fn podtest_lua_validate(boot: *const Bootstrap, request: *const Request, size: usize, last_id: u64, now: u64) c_int;

test "live RPC validator authenticates requests before dispatch" {
    const t = @import("std").testing;
    const boot: Bootstrap = .{ .deadline_ms = 200, .script_len = 0, .run_id = @splat(1), .token = @splat(2) };
    const req: Request = .{ .id = 1, .deadline_ms = 120, .run_id = boot.run_id, .token = boot.token, .version = version, .method = 1, .payload = @splat(0) };
    try t.expectEqual(@as(c_int, 0), podtest_lua_validate(&boot, &req, 3, 0, 100));
    try t.expect(podtest_lua_validate(&boot, &req, 3, 1, 100) != 0);
    try t.expect(podtest_lua_validate(&boot, &req, 3, 0, 120) != 0);
    try t.expect(podtest_lua_validate(&boot, &req, max_payload + 1, 0, 100) != 0);
    var invalid = req;
    invalid.token[31] ^= 1;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    invalid = req;
    invalid.run_id[0] ^= 1;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    invalid = req;
    invalid.deadline_ms = 201;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    invalid = req;
    invalid.version = 2;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    invalid = req;
    invalid.method = 3;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    try t.expect(podtest_lua_validate(&boot, &invalid, 261, 0, 100) != 0);
    try t.expectEqual(@as(c_int, 0), podtest_lua_validate(&boot, &invalid, 5, 0, 100));
    invalid.method = 2;
    try t.expect(podtest_lua_validate(&boot, &invalid, 3, 0, 100) != 0);
    try t.expectEqual(@as(c_int, 0), podtest_lua_validate(&boot, &invalid, 1, 0, 100));
}
