#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "wire.h"

static uint64_t monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static int await(int fd, short events, uint64_t deadline) {
    struct pollfd p = { .fd = fd, .events = events };
    for (;;) {
        uint64_t now = monotonic_ms();
        if (now >= deadline) return 0;
        int rc = poll(&p, 1, (int)(deadline - now));
        if (rc < 0 && errno == EINTR) continue;
        return rc;
    }
}

static int packet(int fd, const void *data, size_t len, uint64_t deadline,
    rpc_cancel_fn cancelled, void *context) {
    for (;;) {
        if (cancelled && cancelled(context)) return -3;
        uint64_t now = monotonic_ms();
        if (now >= deadline) return -2;
        uint64_t wake = cancelled && deadline - now > 20 ? now + 20 : deadline;
        int ready = await(fd, POLLOUT, wake);
        if (ready < 0) return -1;
        if (!ready) continue;
        ssize_t n = send(fd, data, len, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        return n == (ssize_t)len ? 0 : -1;
    }
}

static ssize_t receive(int fd, struct rpc_request *request, struct ucred *peer) {
    union { struct cmsghdr align; char data[CMSG_SPACE(sizeof(struct ucred)) + CMSG_SPACE(sizeof(int))]; } control;
    struct iovec iov = { .iov_base = request, .iov_len = sizeof(*request) };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.data,
        .msg_controllen = sizeof(control.data) };
    ssize_t n = recvmsg(fd, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (n < 0) return n;
    if (n == 0 && msg.msg_controllen == 0 && !(msg.msg_flags & MSG_CTRUNC)) return 0;
    int credentials = 0, invalid = msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC);
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS && c->cmsg_len == CMSG_LEN(sizeof(*peer))) {
            memcpy(peer, CMSG_DATA(c), sizeof(*peer));
            ++credentials;
        } else {
            invalid = 1;
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
                size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
                for (size_t i = 0; i < count; ++i) {
                    int received;
                    memcpy(&received, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
                    close(received);
                }
            }
        }
    }
    if (invalid || credentials != 1 || n == 0) {
        errno = EPROTO;
        return -1;
    }
    return n;
}

extern int podtest_lua_validate(const struct rpc_boot *, const struct rpc_request *, size_t, uint64_t, uint64_t);

/* argv is trusted host configuration, not supplied by the Lua script. */
int podtest_lua_supervise(char *const argv[], const char *script, size_t len, unsigned timeout_ms,
    rpc_read_fn read_stdout, rpc_cancel_fn cancelled, void *context) {
    if (!argv || !argv[0] || argv[0][0] != '/' || len > 256 * 1024 || !timeout_ms || timeout_ms > 300000 ||
        !getuid() || !getgid()) return -1;
    struct rpc_boot boot = { .deadline_ms = monotonic_ms() + timeout_ms, .script_len = len, .version = RPC_VERSION };
    if (getrandom(boot.run_id, sizeof(boot.run_id), 0) != sizeof(boot.run_id) ||
        getrandom(boot.token, sizeof(boot.token), 0) != sizeof(boot.token)) return -1;
    int fd[2], on = 1;
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, fd)) return -1;
    if (setsockopt(fd[0], SOL_SOCKET, SO_PASSCRED, &on, sizeof(on))) {
        close(fd[0]); close(fd[1]); return -1;
    }
    pid_t child = fork();
    if (!child) {
        close(fd[0]);
        if (setpgid(0, 0) || dup2(fd[1], STDIN_FILENO) < 0 ||
            fcntl(STDIN_FILENO, F_SETFD, 0) || syscall(SYS_close_range, 3u, ~0u, 0u)) _exit(125);
        char *const env[] = { NULL };
        execve(argv[0], argv, env);
        _exit(125);
    }
    close(fd[1]);
    if (child < 0) { close(fd[0]); return -1; }
    int result = -1, status;
    int pidfd = (int)syscall(SYS_pidfd_open, child, 0);
    if (pidfd < 0) goto done;
    if (cancelled && cancelled(context)) { result = -3; goto done; }
    int sent = packet(fd[0], &boot, sizeof(boot), boot.deadline_ms, cancelled, context);
    if (sent) { result = sent; goto done; }
    for (size_t offset = 0; offset < len;) {
        size_t chunk = len - offset < RPC_PAYLOAD ? len - offset : RPC_PAYLOAD;
        sent = packet(fd[0], script + offset, chunk, boot.deadline_ms, cancelled, context);
        if (sent) { result = sent; goto done; }
        offset += chunk;
    }
    uint64_t last_id = 0;
    pid_t runner = 0;
    struct { uint64_t id, deadline; unsigned handle; } pending[32] = {0};
    for (;;) {
        uint64_t now = monotonic_ms(), wake = boot.deadline_ms;
        if (cancelled && cancelled(context)) { result = -3; goto done; }
        if (now >= wake) { result = -2; goto done; }
        if (cancelled && wake > now + 20) wake = now + 20;
        for (size_t i = 0; i < 32; ++i) {
            if (!pending[i].id) continue;
            if (now >= pending[i].deadline) { result = -2; goto done; }
            struct rpc_reply reply = { .id = pending[i].id, .version = RPC_VERSION };
            size_t size = sizeof(reply.payload);
            int rc = read_stdout(context, pending[i].handle, reply.payload, &size);
            if (!rc) {
                if (wake > now + 2) wake = now + 2;
                if (wake > pending[i].deadline) wake = pending[i].deadline;
                continue;
            }
            if (rc != 1 || size > sizeof(reply.payload)) {
                reply.status = rc == 2 ? RPC_EOF : RPC_IO_ERROR;
                size = 0;
            }
            memcpy(reply.run_id, boot.run_id, sizeof(reply.run_id));
            sent = packet(fd[0], &reply, offsetof(struct rpc_reply, payload) + size, pending[i].deadline, cancelled, context);
            if (sent) { result = sent; goto done; }
            pending[i].id = 0;
        }
        struct rpc_request request;
        struct ucred peer;
        int ready = await(fd[0], POLLIN, wake);
        if (!ready) continue;
        if (ready < 0) goto done;
        ssize_t n = receive(fd[0], &request, &peer);
        if (!n) break;
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (n < (ssize_t)offsetof(struct rpc_request, payload) || peer.pid <= 0 ||
            peer.uid != getuid() || peer.gid != getgid() || getpgid(peer.pid) != child ||
            (runner && runner != peer.pid)) goto done;
        size_t payload_len = (size_t)n - offsetof(struct rpc_request, payload);
        if (podtest_lua_validate(&boot, &request, payload_len, last_id, monotonic_ms())) goto done;
        runner = peer.pid;
        last_id = request.id;
        if (request.method == RPC_STDOUT_READ) {
            if (!read_stdout) goto done;
            unsigned handle = (unsigned char)request.payload[0];
            size_t slot = 0;
            while (slot < 32 && pending[slot].id) ++slot;
            if (slot == 32) goto done;
            pending[slot].id = request.id;
            pending[slot].deadline = request.deadline_ms;
            pending[slot].handle = handle;
            continue;
        }
        struct rpc_reply reply = { .id = request.id, .version = RPC_VERSION };
        memcpy(reply.run_id, boot.run_id, sizeof(reply.run_id));
        memcpy(reply.payload, request.payload, payload_len);
        sent = packet(fd[0], &reply, offsetof(struct rpc_reply, payload) + payload_len, request.deadline_ms, cancelled, context);
        if (sent) { result = sent; goto done; }
    }
    for (;;) {
        uint64_t now = monotonic_ms();
        if (cancelled && cancelled(context)) { result = -3; break; }
        if (now >= boot.deadline_ms) { result = -2; break; }
        uint64_t wake = boot.deadline_ms;
        if (cancelled && wake > now + 20) wake = now + 20;
        int ready = await(pidfd, POLLIN, wake);
        if (ready < 0) break;
        if (ready > 0) { result = 0; break; }
    }
done:
    if (pidfd >= 0) close(pidfd);
    close(fd[0]);
    if (result) { (void)kill(-child, SIGKILL); (void)kill(child, SIGKILL); }
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return -1;
    if (result) return result;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
