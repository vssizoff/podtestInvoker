-- Example runner for the podtest-invoker.
--
-- The task archive contains this script and a `solution/` directory.  The
-- runner starts a container from a stock Alpine image, mounts `solution/`
-- read-only at `/solution`, feeds stdin, and reports the result.
--
-- The image must be reachable by Podman.  It is pulled on first use; the
-- archive itself is self-contained and does not contain a prebuilt image.

local IMAGE = "docker.io/library/alpine:3.20"

report.build_log("example task: preparing image " .. IMAGE)

local pulled, pull_err = image.pull(IMAGE)
if not pulled then
  report.runner_error("cannot pull " .. IMAGE .. ": " .. tostring(pull_err))
  report.problem_score(0.0)
  return
end

local c = container.create{
  image = IMAGE,
  command = {
    "sh", "-c",
    "cat /solution/input.txt; " ..
    "echo this-goes-to-stderr >&2; " ..
    "read line; " ..
    "echo got:$line; " ..
    "exit 0",
  },
  stdin = true,
  stdout = true,
  stderr = true,
  network = "none",
  memory = "128m",
  mounts = {
    { source = "solution", target = "/solution", read_only = true },
  },
}

c:start()
c:write("hello from stdin\n")
c:close_stdin()

local code, info = c:wait()
local out = c:stdout()
local errout = c:stderr()

report.test_started(1)
report.test_stdio(1, "hello from stdin\n", out, errout)

local ok = code == 0
  and out:find("solution-content", 1, true) ~= nil
  and out:find("got:hello from stdin", 1, true) ~= nil
  and errout:find("this-goes-to-stderr", 1, true) ~= nil

report.test_verdict(1, ok and "OK" or "WA", ok and 1.0 or 0.0, tostring(code))
report.problem_score(ok and 1.0 or 0.0)
report.build_log(string.format(
  "example task: exit=%d oom=%s cpu=%.3fs peak=%d",
  code, tostring(info.oom), c:cpu_time(), c:memory_peak()))
