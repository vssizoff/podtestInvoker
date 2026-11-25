#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <poll.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "wire.h"

#if LUA_VERSION_NUM != 505
#error Lua 5.5 is required
#endif

enum { SCRIPT_CAP = 256 * 1024, HEAP_CAP = 8 * 1024 * 1024, LOG_CAP = 64 * 1024 };
enum { RUNNER_ERROR = 2, MEMORY_LIMIT = 3, INSTRUCTION_LIMIT = 4, SETUP_ERROR = 5, OUTPUT_LIMIT = 6 };
enum { TASK_CAP = 32 };
struct task {
    lua_State *thread;
    int join, done;
    uint64_t wake, rpc_id;
    size_t reply_len;
    struct rpc_reply reply;
};
struct budget {
    size_t heap, log_left, instructions_left;
    struct task tasks[TASK_CAP];
    int count, current, rpc;
    uint64_t next_request;
    struct rpc_boot boot;
};

static int write_all(int fd, const char *data, size_t len) {
    while (len) {
        ssize_t n = write(fd, data, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        data += n;
        len -= (size_t)n;
    }
    return 0;
}

static void fail(int code, const char *message) {
    (void)write_all(STDERR_FILENO, message, strlen(message));
    _exit(code);
}

static void *allocate(void *context, void *ptr, size_t old_size, size_t size) {
    struct budget *b = context;
    if (!ptr) old_size = 0; /* Lua supplies a type tag on new allocations. */
    if (!size) {
        free(ptr);
        b->heap -= old_size;
        return NULL;
    }
    if (size > HEAP_CAP - (b->heap - old_size)) return NULL;
    void *next = realloc(ptr, size);
    if (next) b->heap = b->heap - old_size + size;
    return next;
}

static struct budget *get_budget(lua_State *L) {
    void *context;
    lua_getallocf(L, &context);
    return context;
}

static void count_instruction(lua_State *L, lua_Debug *debug) {
    (void)debug;
    if (--get_budget(L)->instructions_left == 0)
        fail(INSTRUCTION_LIMIT, "runner: instruction limit\n");
}

static void log_bytes(struct budget *b, const char *bytes, size_t len) {
    if (len > b->log_left) {
        (void)write_all(STDOUT_FILENO, bytes, b->log_left);
        fail(OUTPUT_LIMIT, "runner: output limit\n");
    }
    b->log_left -= len;
    if (write_all(STDOUT_FILENO, bytes, len)) fail(RUNNER_ERROR, "runner: log write failed\n");
}

static int runner_print(lua_State *L) {
    struct budget *b = get_budget(L);
    int count = lua_gettop(L);
    for (int i = 1; i <= count; ++i) {
        size_t len;
        const char *bytes = luaL_tolstring(L, i, &len);
        if (i > 1) log_bytes(b, "\t", 1);
        log_bytes(b, bytes, len);
        lua_pop(L, 1);
    }
    log_bytes(b, "\n", 1);
    return 0;
}

static int require_builtin(lua_State *L) {
    size_t len;
    const char *name = luaL_checklstring(L, 1, &len);
    if (len != sizeof("judge.runtime") - 1 || memcmp(name, "judge.runtime", len))
        return luaL_error(L, "module is not allowlisted");
    lua_pushvalue(L, lua_upvalueindex(1));
    return 1;
}

static int traceback(lua_State *L) {
    const char *message = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "non-string Lua error";
    luaL_traceback(L, L, message, 1);
    return 1;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) fail(SETUP_ERROR, "runner: monotonic clock unavailable\n");
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static int spawn(lua_State *L) {
    struct budget *b = get_budget(L);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (b->count == TASK_CAP) return luaL_error(L, "task limit");
    lua_State *child = lua_newthread(L);
    luaL_ref(L, LUA_REGISTRYINDEX); /* Keep completed handles stable until the run ends. */
    lua_pushvalue(L, 1);
    lua_xmove(L, child, 1);
    lua_sethook(child, count_instruction, LUA_MASKCOUNT, 1);
    int id = b->count++;
    b->tasks[id] = (struct task){ .thread = child, .join = -1 };
    lua_pushinteger(L, id);
    return 1;
}

static struct task *current_task(lua_State *L, struct budget *b) {
    if (!lua_isyieldable(L) || L != b->tasks[b->current].thread)
        luaL_error(L, "operation requires a scheduled coroutine");
    return &b->tasks[b->current];
}

static int resumed(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)status; (void)ctx;
    return 0;
}

static int join(lua_State *L) {
    struct budget *b = get_budget(L);
    struct task *task = current_task(L, b);
    lua_Integer id = luaL_checkinteger(L, 1);
    if (id <= 0 || id >= b->count || id == b->current) return luaL_error(L, "invalid task handle");
    if (b->tasks[id].done) return 0;
    task->join = (int)id;
    return lua_yieldk(L, 0, 0, resumed);
}

static int sleep_ms(lua_State *L) {
    struct task *task = current_task(L, get_budget(L));
    lua_Integer ms = luaL_checkinteger(L, 1);
    if (ms < 0 || ms > 1000) return luaL_error(L, "sleep must be 0..1000 ms");
    task->wake = now_ms() + (uint64_t)ms;
    return lua_yieldk(L, 0, 0, resumed);
}

static int rpc_resumed(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    struct task *t = &get_budget(L)->tasks[ctx];
    if (t->reply.status == RPC_EOF) { lua_pushnil(L); return 1; }
    if (t->reply.status) return luaL_error(L, "RPC request rejected");
    lua_pushlstring(L, t->reply.payload, t->reply_len);
    return 1;
}

static int rpc_call(lua_State *L, unsigned method, const char *bytes, size_t len) {
    struct budget *b = get_budget(L);
    struct task *t = current_task(L, b);
    if (!b->rpc) return luaL_error(L, "RPC unavailable");
    luaL_argcheck(L, len <= RPC_PAYLOAD, 1, "RPC payload too large");
    struct rpc_request request = {
        .id = ++b->next_request, .deadline_ms = b->boot.deadline_ms,
        .version = RPC_VERSION, .method = method,
    };
    memcpy(request.run_id, b->boot.run_id, sizeof(request.run_id));
    memcpy(request.token, b->boot.token, sizeof(request.token));
    memcpy(request.payload, bytes, len);
    size_t size = offsetof(struct rpc_request, payload) + len;
    ssize_t n;
    do { n = send(STDIN_FILENO, &request, size, MSG_DONTWAIT | MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
    if (n != (ssize_t)size) return luaL_error(L, "RPC send failed");
    t->rpc_id = request.id;
    return lua_yieldk(L, 0, b->current, rpc_resumed);
}

static int rpc_echo(lua_State *L) {
    size_t len;
    const char *bytes = luaL_checklstring(L, 1, &len);
    return rpc_call(L, RPC_ECHO, bytes, len);
}

static int rpc_stdout_read(lua_State *L) {
    lua_Integer handle = luaL_checkinteger(L, 1);
    luaL_argcheck(L, handle >= 1 && handle <= 8, 1, "invalid container handle");
    char byte = (char)handle;
    return rpc_call(L, RPC_STDOUT_READ, &byte, 1);
}

static void rpc_receive(struct budget *b) {
    struct rpc_reply reply;
    ssize_t n = recv(STDIN_FILENO, &reply, sizeof(reply), MSG_DONTWAIT | MSG_TRUNC);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
    if (n < (ssize_t)offsetof(struct rpc_reply, payload) || n > (ssize_t)sizeof(reply) ||
        reply.version != RPC_VERSION || memcmp(reply.run_id, b->boot.run_id, sizeof(reply.run_id)))
        fail(RUNNER_ERROR, "runner: invalid RPC reply\n");
    for (int i = 0; i < b->count; ++i) {
        struct task *t = &b->tasks[i];
        if (!t->rpc_id || t->rpc_id != reply.id) continue;
        t->rpc_id = 0;
        t->reply_len = (size_t)n - offsetof(struct rpc_reply, payload);
        memcpy(&t->reply, &reply, (size_t)n);
        return;
    }
    fail(RUNNER_ERROR, "runner: unexpected RPC response ID\n");
}

static int schedule(lua_State *L) {
    struct budget *b = get_budget(L);
    for (;;) {
        int active = 0, progressed = 0, pending_rpc = 0;
        uint64_t wake = UINT64_MAX;
        if (b->rpc) rpc_receive(b);
        for (int i = 0; i < b->count; ++i) {
            struct task *t = &b->tasks[i];
            if (t->done) continue;
            active = 1;
            if (t->rpc_id) { pending_rpc = 1; continue; }
            if (t->join >= 0 && !b->tasks[t->join].done) continue;
            if (t->wake > now_ms()) {
                if (t->wake < wake) wake = t->wake;
                continue;
            }
            t->join = -1;
            t->wake = 0;
            b->current = i;
            progressed = 1;
            int results;
            int status = lua_resume(t->thread, L, 0, &results);
            if (status == LUA_ERRMEM) fail(MEMORY_LIMIT, "runner: memory limit\n");
            if (status != LUA_OK && status != LUA_YIELD) {
                const char *message = lua_type(t->thread, -1) == LUA_TSTRING ? lua_tostring(t->thread, -1) : "non-string Lua error";
                luaL_traceback(L, t->thread, message, 0);
                return lua_error(L);
            }
            if (results) lua_pop(t->thread, results);
            t->done = status == LUA_OK;
        }
        if (!active) return 0;
        if (progressed) continue;
        if (pending_rpc) {
            uint64_t now = now_ms();
            if (now >= b->boot.deadline_ms) fail(RUNNER_ERROR, "runner: RPC deadline\n");
            if (wake > b->boot.deadline_ms) wake = b->boot.deadline_ms;
            struct pollfd fd = { .fd = STDIN_FILENO, .events = POLLIN };
            int rc = poll(&fd, 1, (int)(wake > now ? wake - now : 0));
            if (rc < 0 && errno != EINTR) fail(RUNNER_ERROR, "runner: RPC poll failed\n");
            continue;
        }
        if (wake == UINT64_MAX) return luaL_error(L, "task join deadlock");
        struct timespec until = { .tv_sec = (time_t)(wake / 1000), .tv_nsec = (long)(wake % 1000) * 1000000 };
        int rc;
        do { rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL); } while (rc == EINTR);
        if (rc) fail(SETUP_ERROR, "runner: sleep failed\n");
    }
}

static int run(lua_State *L) {
    const struct { const char *name; lua_CFunction open; } libraries[] = {
        { LUA_GNAME, luaopen_base }, { LUA_STRLIBNAME, luaopen_string },
        { LUA_TABLIBNAME, luaopen_table }, { LUA_MATHLIBNAME, luaopen_math },
        { LUA_UTF8LIBNAME, luaopen_utf8 }, { LUA_COLIBNAME, luaopen_coroutine },
    };
    for (size_t i = 0; i < sizeof(libraries) / sizeof(*libraries); ++i) {
        luaL_requiref(L, libraries[i].name, libraries[i].open, 1);
        lua_pop(L, 1);
    }
    const char *denied[] = { "dofile", "loadfile", "load", "warn" };
    for (size_t i = 0; i < sizeof(denied) / sizeof(*denied); ++i) {
        lua_pushnil(L);
        lua_setglobal(L, denied[i]);
    }
    lua_getglobal(L, "string");
    lua_pushnil(L);
    lua_setfield(L, -2, "dump");
    lua_pop(L, 1);
    lua_pushcfunction(L, runner_print);
    lua_setglobal(L, "print");
    lua_newtable(L);
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "api_version");
    lua_pushcfunction(L, spawn);
    lua_setfield(L, -2, "spawn");
    lua_pushcfunction(L, join);
    lua_setfield(L, -2, "join");
    lua_pushcfunction(L, sleep_ms);
    lua_setfield(L, -2, "sleep");
    lua_pushcfunction(L, rpc_echo);
    lua_setfield(L, -2, "fixture_echo");
    lua_pushcfunction(L, rpc_stdout_read);
    lua_setfield(L, -2, "stdout_read");
    lua_pushcclosure(L, require_builtin, 1);
    lua_setglobal(L, "require");

    size_t length;
    const char *source = lua_tolstring(L, 1, &length);
    int status = luaL_loadbufferx(L, source, length, "@runner.lua", "t");
    if (status == LUA_ERRMEM) fail(MEMORY_LIMIT, "runner: memory limit\n");
    if (status != LUA_OK) return lua_error(L);
    lua_State *main_task = lua_newthread(L);
    lua_pushvalue(L, -2);
    lua_xmove(L, main_task, 1);
    /* Count each instruction so fresh Lua threads cannot reset a quantum. */
    lua_sethook(main_task, count_instruction, LUA_MASKCOUNT, 1);
    struct budget *b = get_budget(L);
    b->tasks[0] = (struct task){ .thread = main_task, .join = -1 };
    b->count = 1;
    return schedule(L);
}

static int set_limit(int resource, rlim_t max) {
    const struct rlimit limit = {max, max};
    return setrlimit(resource, &limit);
}

static int restrict_process(int rpc) {
    if (geteuid() == 0 || getegid() == 0 || clearenv() ||
        syscall(SYS_close_range, 3u, ~0u, 0u) || (!rpc && close(STDIN_FILENO)) ||
        set_limit(RLIMIT_AS, 64 * 1024 * 1024) || set_limit(RLIMIT_NOFILE, 3) ||
        set_limit(RLIMIT_CORE, 0) || set_limit(RLIMIT_CPU, 2) ||
        prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;

    /* No filesystem, socket, exec or clone calls after loading the dynamic runtime. */
#define ALLOW(name) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_##name, 0, 1), BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
#define ALLOW_RPC(name) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_##name, 0, 4), \
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])), \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, STDIN_FILENO, 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, rpc ? SECCOMP_RET_ALLOW : SECCOMP_RET_KILL_PROCESS), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS)
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        ALLOW(write), ALLOW(brk), ALLOW(mmap), ALLOW(munmap), ALLOW(mremap), ALLOW(madvise),
        ALLOW(clock_gettime), ALLOW(clock_nanosleep), ALLOW(getrandom), ALLOW(exit_group), ALLOW(exit), ALLOW(rt_sigreturn),
        ALLOW(poll), ALLOW_RPC(sendto), ALLOW_RPC(recvfrom),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    };
#undef ALLOW
#undef ALLOW_RPC
    const struct sock_fprog program = { .len = sizeof(filter) / sizeof(*filter), .filter = filter };
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
}

int main(int argc, char **argv) {
    static char source[SCRIPT_CAP + 1];
    static struct budget budget = { .log_left = LOG_CAP, .instructions_left = 1000000 };
    size_t length = 0;
    if (argc == 2 && !strcmp(argv[1], "--rpc")) {
        budget.rpc = 1;
        ssize_t n = recv(STDIN_FILENO, &budget.boot, sizeof(budget.boot), MSG_TRUNC);
        uint64_t now = now_ms();
        if (n != sizeof(budget.boot) || budget.boot.version != RPC_VERSION ||
            budget.boot.script_len > SCRIPT_CAP || budget.boot.deadline_ms <= now ||
            budget.boot.deadline_ms - now > 300000)
            fail(SETUP_ERROR, "runner: invalid RPC bootstrap\n");
        while (length < budget.boot.script_len) {
            size_t left = budget.boot.script_len - length;
            size_t chunk = left < RPC_PAYLOAD ? left : RPC_PAYLOAD;
            n = recv(STDIN_FILENO, source + length, chunk, MSG_TRUNC);
            if (n != (ssize_t)chunk) fail(SETUP_ERROR, "runner: invalid RPC script packet\n");
            length += chunk;
        }
    } else if (argc != 1) fail(SETUP_ERROR, "runner: invalid arguments\n");
    while (!budget.rpc && length < sizeof(source)) {
        ssize_t n = read(STDIN_FILENO, source + length, sizeof(source) - length);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) fail(SETUP_ERROR, "runner: could not read script\n");
        if (!n) break;
        length += (size_t)n;
    }
    if (length > SCRIPT_CAP) fail(SETUP_ERROR, "runner: script too large\n");
    const unsigned seed = luaL_makeseed(NULL);
    if (restrict_process(budget.rpc)) fail(SETUP_ERROR, "runner: process restrictions unavailable\n");
    lua_State *L = lua_newstate(allocate, &budget, seed);
    if (!L) fail(MEMORY_LIMIT, "runner: memory limit\n");
    lua_pushcfunction(L, traceback);
    lua_pushcfunction(L, run);
    lua_pushlstring(L, source, length);
    int status = lua_pcall(L, 1, 0, 1);
    if (status == LUA_ERRMEM) fail(MEMORY_LIMIT, "runner: memory limit\n");
    if (status != LUA_OK) {
        size_t len;
        const char *message = lua_tolstring(L, -1, &len);
        if (message) (void)write_all(STDERR_FILENO, message, len < 4096 ? len : 4096);
        fail(RUNNER_ERROR, "\n");
    }
    lua_close(L);
    return 0;
}
