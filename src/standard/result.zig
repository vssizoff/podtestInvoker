const std = @import("std");
const resource = @import("resource");

pub const Verdict = enum { accepted, wrong_answer, presentation_error, partial, compilation_error, testing_error, wall_timeout, output_limit, memory_limit, runtime_error };
pub const TestResult = struct { id: []const u8, verdict: Verdict, score_milli: u32, exit_code: i32, metrics: ?resource.Metrics };
pub const GroupResult = struct { id: []const u8, score_milli: u64 };

pub const Result = struct {
    version: u32,
    tests: []const TestResult,
    groups: []const GroupResult,
    problem_score_milli: u64,
    infrastructure_error: bool = false,
    compilation_error: bool = false,

    pub fn verdict(self: Result) Verdict {
        if (self.compilation_error) return .compilation_error;
        for (self.tests) |item| if (item.verdict != .accepted) return item.verdict;
        return .accepted;
    }
};
