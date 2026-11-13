# Lua runner API

Every run executes one Lua script (the *runner*) inside an embedded Lua 5.5
interpreter.  The runner receives a sandboxed global environment and a small
API for files, Podman resources, coroutines and reporting.  Events emitted
through `report` are forwarded to the backend as-is; the invoker does not
validate or reinterpret them.

The runner is executed as the main coroutine of the scheduler.  Every API call
that performs blocking I/O (`container:*`, `image:*`, `network:*`, `fs:*`,
`sleep`) yields the coroutine instead of blocking the process, so several
operations can make progress concurrently from spawned tasks.

## Sandbox

The following globals are **removed** and are always `nil`:

```
os  io  package  require  debug  dofile  loadfile  load  loadstring
```

The following standard libraries remain available (also as globals):

- base (`assert`, `error`, `ipairs`, `pairs`, `pcall`, `select`, `tonumber`,
  `tostring`, `type`, `next`, `rawget`, `rawset`, `setmetatable`, ...)
- `string`, `table`, `math`, `utf8`, `coroutine`

There is no module loader, no direct filesystem access outside the run
directory, and no way to start host processes except through Podman.

`print(...)` and `log(...)` write a line to the invoker log prefixed with the
run id.  They do not produce an event.

## Run metadata

`run` is a table describing the current run:

| Field | Type | Meaning |
| --- | --- | --- |
| `run.id` | string | Run id chosen by the backend. |
| `run.dir` | string | Absolute path of the run directory on the host. |
| `run.solution_dir` | string | Absolute path of `<run.dir>/solution`. |
| `run.timeout_ms` | integer | Effective global run timeout. |
| `run.elapsed()` | function | Seconds elapsed since the run started. |
| `run.cancel(reason)` | function | Request cancellation of the whole run. |

The global timeout is enforced by the invoker.  When it expires the runner is
stopped and a `run_timeout` event is emitted; the gRPC stream then ends with a
`run_finished{ok=false,status="timeout"}` event.

## Coroutines

### `spawn(fn, ...) -> handle`

Starts `fn(...)` as a coroutine and returns a handle immediately.

Handle methods:

| Method | Meaning |
| --- | --- |
| `handle:join()` | Wait for the task and return its results. If the task failed, returns `nil, message`. |
| `handle:cancel()` | Mark the task cancelled. Waiting calls (`sleep`, `wait`, `read`) wake up and return early. |
| `handle:done()` | `true` once the task finished or failed. |
| `handle:cancelled()` | `true` if cancellation was requested. |
| `handle:status()` | `"ready"`, `"suspended"`, `"finished"` or `"failed"`. |

A Lua error in any task aborts the whole run: a `runner_error` event is emitted
and the run finishes with status `runner_error`.

### `sleep(seconds)`

Yields the current coroutine for the given number of seconds.  A cancelled task
wakes up immediately.

### `now()` / `monotonic()`

Monotonic clock in seconds (float).

### Timers

```lua
local h = timer.after(250, fn, arg1, ...)   -- one shot, milliseconds
local h = timer.every(1000, fn, ...)        -- repeating, milliseconds
timer.cancel(h)
timer.sleep(seconds)                        -- same as sleep()
timer.now()                                 -- same as now()
```

`timer.every` stops when `fn` returns exactly `false` or when the handle is
cancelled.

## Filesystem (`fs`)

All paths are relative to the run directory.  Absolute paths and any `..`
component are rejected; symlinks that resolve outside the run directory are
rejected as well.  On error the functions return `nil, error_string` (except
the predicates, which return a boolean).

| Function | Description |
| --- | --- |
| `fs.read(path[, max_bytes])` | Read a file (default limit 512 MiB). |
| `fs.read_file(path[, max_bytes])` | Alias of `fs.read`. |
| `fs.write(path, data)` | Create or truncate a file. Parent directories are created. |
| `fs.write_file(path, data)` | Alias of `fs.write`. |
| `fs.append(path, data)` | Append to a file. |
| `fs.mkdir(path)` | Create a directory and its parents. |
| `fs.remove(path)` | Remove a file or a directory tree. Missing paths are ignored. |
| `fs.exists(path)` | Boolean. |
| `fs.stat(path)` | `{ size = n, is_dir = bool, mode = n }`. |
| `fs.list(path)` / `fs.readdir(path)` | Array of `{ name = string, type = "file"|"dir"|"symlink"|"other" }`. |
| `fs.copy(src, dst)` | Copy a file inside the run directory. |

Example:

```lua
fs.write("tmp/input.txt", "42\n")
local text = assert(fs.read("tmp/input.txt"))
```

The task archive is extracted at the run directory root, so a `solution/`
directory in the archive is available as `solution/...` (and as
`run.solution_dir` on the host).

## Images (`image`)

Image references must be fully qualified (`docker.io/library/node:26-alpine3.23`).
Short names are not resolved by the Podman HTTP API.

| Function | Description |
| --- | --- |
| `image.pull(ref)` | Pull an image. Returns `true` or `nil, error`. |
| `image.exists(ref)` | Boolean. |
| `image.remove(ref)` | Remove an image. |
| `image.build(opts)` | Build an image and return its tag. |

`image.build(opts)` options:

| Option | Meaning |
| --- | --- |
| `tag` | Image tag. Generated when omitted. |
| `dockerfile` | Dockerfile name inside the context (default `Dockerfile`). |
| `context` | Directory inside the run directory, or a table `{ ["name"] = "contents" }` used as an in-memory context. |
| `files` | Alias for a table context. |

All images built by the runner are labelled with the invoker instance and are
removed at run end and on the next startup.

## Networks (`network`)

| Function | Description |
| --- | --- |
| `network.create([name])` | Create a network, return its name. |
| `network.exists(name)` | Boolean. |
| `network.remove(name)` | Remove a network. |

## Containers (`container`)

### `container.create(opts) -> container`

Creates (but does not start) a container.  Returns a container object.  On
failure returns `nil, error`.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `image` | string | **required** | Fully qualified image reference. |
| `command` | string or array | image default | Command / arguments. A string is passed as a single argument. |
| `name` | string | generated | Container name. |
| `stdin` | bool | `true` | Attach stdin (only when `stdio ~= "none"`). |
| `stdout` | bool | `true` | Capture/attach stdout. |
| `stderr` | bool | `true` | Capture/attach stderr. |
| `stdio` | string | `"capture"` | `"capture"`, `"stream"`, `"pipe"`, `"none"`. |
| `mounts` | array | none | `{ source = "<run-relative>", target = "/abs/path", read_only = bool }`. `destination`/`ro` are accepted aliases. |
| `network` | string or array | none | `"none"` (default), `"host"`, a network name, or an array of names. |
| `env` | array or map | none | `{"A=1"}` or `{ A = "1" }`. |
| `memory` | number or string | unlimited | Limit, e.g. `512*1024*1024` or `"512m"`. |
| `memory_mb` | number | unlimited | Limit in MiB (ignored when `memory` is set). |
| `workdir` | string | image default | Working directory. |
| `hostname` | string | generated | Hostname. |
| `user` | string | image default | `uid[:gid]`. |
| `test` | number | current test | Test number used by `report.test_stdio` helpers. |
| `pipe_to` | container | none | Connect this container's stdout to another container's stdin. |

Mount sources are resolved **inside the run directory** and must already exist.
A typical solution mount is:

```lua
mounts = { { source = "solution", target = "/solution", read_only = true } }
```

### `container.run(opts) -> container`

`container.create(opts)` followed by `:start()`.

### Container methods

| Method | Description |
| --- | --- |
| `c:start()` | Start the container. |
| `c:stop([grace_ms])` | Stop gracefully (SIGTERM, then SIGKILL after `grace_ms`). |
| `c:kill()` | Kill immediately. |
| `c:remove()` | Remove the container. |
| `c:wait()` | Yield until exit; returns `exit_code, info` where `info = { oom = bool, error = string, killed = bool }`. |
| `c:write(data)` | Write to stdin, returns the number of bytes written. |
| `c:close_stdin()` | Close stdin (EOF). |
| `c:read([opts])` | Read available output; returns a string or `nil` at EOF/timeout/cancellation. |
| `c:stdout()` / `c:output()` | Whole retained stdout history. |
| `c:stderr()` | Whole retained stderr history. |
| `c:history()` | `{ stdout = string, stderr = string, truncated = bool }`. |
| `c:pipe_to(dst)` / `c:pipe_from(dst)` | Connect stdout to another container's stdin. |
| `c:cpu_time()` | CPU time in seconds, normalised by the calibration factor. |
| `c:raw_cpu_time()` | Raw cgroup CPU time in seconds. |
| `c:memory_peak()` | Peak memory in bytes (cgroup `memory.peak`). |
| `c:exit_code()` | Exit code, or `nil` while running. |
| `c:status()` | `"created"`, `"running"`, `"exited"`, `"removed"`, `"failed"`. |
| `c:oom_killed()` | Boolean. |
| `c:id()` / `c:name()` | Identifiers. |
| `c:inspect()` | Table with `id`, `name`, `image`, `exit_code`, `oom`, `error`, `cpu_time`, `memory_peak`, `done`. |
| `c:set_test(n)` | Set the test number attached to later stdio reports. |
| `c:is_done()` | Boolean. |

`c:read(opts)` options:

| Option | Default | Meaning |
| --- | --- | --- |
| `stream` | `"stdout"` | `"stdout"`, `"stderr"`, `"all"`/`"combined"`. |
| `max` | 1 MiB | Maximum bytes to return. |
| `timeout` | none | Seconds to wait before returning `nil`. `0` means non-blocking. |

All captured output is kept in a bounded history (`stdio_history_limit_bytes`,
512 MiB per stream by default).  When the limit is exceeded the oldest bytes
are dropped and `history().truncated` becomes `true`.

CPU and memory accounting is sampled from the container cgroup while it runs
(the kernel removes the cgroup when the process exits).  The reported values are
therefore accurate to the sampling interval (about 5 ms) and remain available
after `wait()`.

### Stdio modes

| Mode | Behaviour |
| --- | --- |
| `capture` | Attach stdin/stdout/stderr and retain output for `read`/`stdout`/`stderr`. |
| `stream` | Attach and retain output as well; intended for long-running readers. |
| `pipe` | Attach and connect to another container when `pipe_to` is used. |
| `none` | Do not attach any stream; `write`/`read` are not available. |

## Reporting (`report`)

Events are serialised and sent to the backend.  The backend is responsible for
interpreting verdicts and scores; the invoker forwards the values unmodified.

| Function | Event |
| --- | --- |
| `report.test_started(n)` | `TestStarted{n}` |
| `report.test_verdict(n, verdict, score?, grader_data?)` | `TestVerdict{n, verdict, score, grader_data}` |
| `report.subgroup_score(id, score, grader_data?)` | `SubgroupScore{id, score, grader_data}` |
| `report.problem_score(score, grader_data?)` | `ProblemScore{score, grader_data}` |
| `report.build_log(text)` | `BuildLog{text}` |
| `report.test_stdio(n, stdin, stdout, stderr)` | `TestStdio{n, stdin, stdout, stderr}` |
| `report.runner_error(message, traceback?)` | `RunnerError{message, traceback}` |

Aliases: `report.verdict`, `report.subgroup`, `report.problem`, `report.stdio`.

`score` is optional for `test_verdict` (omit it to leave the field unset).
`grader_data` is an arbitrary byte string.

## Example

```lua
-- runner.lua
report.build_log("building")

local image = image.build{
  tag = "local/solution:latest",
  context = {
    ["Dockerfile"] = "FROM scratch\nCOPY app /app\nENTRYPOINT [\"/app\"]\n",
    ["app"] = fs.read("solution/app.bin"),
  },
}

local c = container.create{
  image = image,
  command = { "/app", "--test", "1" },
  stdin = true,
  stdout = true,
  stderr = true,
  memory = "256m",
  mounts = { { source = "solution", target = "/solution", read_only = true } },
  network = "none",
}

c:start()
c:write("42\n")
c:close_stdin()

local code, info = c:wait()
local out = c:stdout()
local err = c:stderr()

report.test_started(1)
report.test_stdio(1, "42\n", out, err)
report.test_verdict(1, code == 0 and "OK" or "WA", code == 0 and 1.0 or 0.0)
report.problem_score(code == 0 and 1.0 or 0.0)
report.build_log(string.format("cpu=%.3fs peak=%d exit=%d oom=%s",
  c:cpu_time(), c:memory_peak(), code, tostring(info.oom)))
```

A complete runnable task archive is available in
[`examples/task`](../examples/task).
