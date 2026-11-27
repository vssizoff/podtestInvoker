#ifndef PODTEST_LUA_WIRE_H
#define PODTEST_LUA_WIRE_H

#include <stdint.h>
#include <stddef.h>

/* Private ABI between Linux x86-64 binaries built from the same tree. */
enum { RPC_VERSION = 1, RPC_PAYLOAD = 16 * 1024, RPC_RUN_ID = 16, RPC_TOKEN = 32 };
struct rpc_boot {
    uint64_t deadline_ms;
    uint32_t script_len;
    uint8_t run_id[RPC_RUN_ID], token[RPC_TOKEN];
    uint32_t version;
};
struct rpc_request {
    uint64_t id, deadline_ms;
    uint8_t run_id[RPC_RUN_ID], token[RPC_TOKEN];
    uint32_t version, method;
    char payload[RPC_PAYLOAD];
};
struct rpc_reply {
    uint64_t id;
    uint8_t run_id[RPC_RUN_ID];
    uint32_t version, status;
    char payload[RPC_PAYLOAD];
};

_Static_assert(sizeof(struct rpc_boot) == 64, "RPC bootstrap ABI changed");
_Static_assert(offsetof(struct rpc_request, payload) == 72, "RPC request ABI changed");
_Static_assert(offsetof(struct rpc_reply, payload) == 32, "RPC reply ABI changed");

enum { RPC_ECHO = 1, RPC_STDOUT_READ = 2, RPC_WORKSPACE_READ = 3,
    RPC_CONTAINER_OPEN = 4, RPC_CONTAINER_CLOSE = 5, RPC_CONTAINER_STATUS = 6,
    RPC_TEST_VERDICT = 7, RPC_SUBGROUP_SCORE = 8, RPC_PROBLEM_SCORE = 9,
    RPC_EOF = 1, RPC_IO_ERROR = 2 };
typedef int (*rpc_read_fn)(void *, unsigned, char *, size_t *);
typedef int (*rpc_workspace_read_fn)(void *, const char *, size_t, uint32_t, char *, size_t *);
typedef int (*rpc_cancel_fn)(void *);
typedef int (*rpc_dispatch_fn)(void *, unsigned, const char *, size_t, char *, size_t *);
int podtest_lua_supervise(char *const argv[], const char *script, size_t len, unsigned timeout_ms,
    rpc_read_fn read_stdout, rpc_cancel_fn cancelled, void *context);
int podtest_lua_supervise_workspace(char *const argv[], const char *script, size_t len, unsigned timeout_ms,
    rpc_read_fn read_stdout, rpc_workspace_read_fn read_workspace, rpc_cancel_fn cancelled, void *context);
int podtest_lua_supervise_run(char *const argv[], const char *script, size_t len, unsigned timeout_ms,
    rpc_read_fn read_stdout, rpc_workspace_read_fn read_workspace, rpc_dispatch_fn dispatch,
    rpc_cancel_fn cancelled, void *context, int log_fd);

#endif
