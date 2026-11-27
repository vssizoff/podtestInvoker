#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "wire.h"

int podtest_lua_validate(const struct rpc_boot *boot, const struct rpc_request *request,
    size_t payload_len, uint64_t last_id, uint64_t now_ms) {
    uint8_t diff = 0;
    for (size_t i = 0; i < RPC_RUN_ID; ++i) diff |= request->run_id[i] ^ boot->run_id[i];
    for (size_t i = 0; i < RPC_TOKEN; ++i) diff |= request->token[i] ^ boot->token[i];
    int valid_method = request->method == RPC_ECHO ||
        (request->method == RPC_STDOUT_READ && payload_len == 1) ||
        (request->method == RPC_WORKSPACE_READ && payload_len > sizeof(uint32_t) && payload_len <= sizeof(uint32_t) + 256) ||
        (request->method == RPC_CONTAINER_OPEN && payload_len > 0 && payload_len <= 256) ||
        ((request->method == RPC_CONTAINER_CLOSE || request->method == RPC_CONTAINER_STATUS) && payload_len == 1) ||
        (request->method == RPC_TEST_VERDICT && payload_len >= 10 && payload_len <= 138) ||
        (request->method == RPC_SUBGROUP_SCORE && payload_len >= 9 && payload_len <= 72) ||
        (request->method == RPC_PROBLEM_SCORE && payload_len == 8);
    if (request->version != RPC_VERSION ||
        !valid_method || request->id <= last_id ||
        request->deadline_ms <= now_ms || request->deadline_ms > boot->deadline_ms ||
        payload_len > RPC_PAYLOAD || diff) return -1;
    return 0;
}
