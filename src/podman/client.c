#define _GNU_SOURCE
#include <curl/curl.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef int (*sink_fn)(void *, const unsigned char *, size_t);
typedef int (*cancel_fn)(void *);
struct cancellation { cancel_fn check; void *context; };
static int progress(void *opaque, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    struct cancellation *cancel = opaque;
    return cancel->check(cancel->context) != 0;
}
struct response { unsigned char *data; size_t capacity; size_t used; int overflow; long code; sink_fn sink; void *context; int aborted; };
static size_t write_body(char *ptr, size_t size, size_t count, void *opaque) {
    struct response *r = opaque;
    size_t n = size * count;
    if (r->code < 200 || r->code >= 300) return n;
    if (r->sink) {
        if (r->sink(r->context, (const unsigned char *)ptr, n)) { r->aborted = 1; return 0; }
        return n;
    }
    if (!r->data) return n;
    if (n > r->capacity - r->used) { r->overflow = 1; return 0; }
    memcpy(r->data + r->used, ptr, n); r->used += n; return n;
}

static size_t read_header(char *ptr, size_t size, size_t count, void *opaque) {
    struct response *r = opaque;
    size_t n = size * count;
    if (n >= 12 && !memcmp(ptr, "HTTP/", 5)) {
        const char *space = memchr(ptr, ' ', n);
        if (space && ptr + n - space >= 4 && space[1] >= '1' && space[1] <= '5' &&
            space[2] >= '0' && space[2] <= '9' && space[3] >= '0' && space[3] <= '9')
            r->code = (space[1] - '0') * 100 + (space[2] - '0') * 10 + space[3] - '0';
    }
    return n;
}

int podtest_podman_request(const char *socket, const char *version, const char *method, const char *path,
        const unsigned char *body, size_t body_len, unsigned char *response, size_t *response_len,
        unsigned int timeout_ms, sink_fn sink, void *context, const char *content_type,
        cancel_fn cancel, void *cancel_context) {
    CURL *curl = curl_easy_init();
    if (!curl) return 5;
    struct response result = {.data = response, .capacity = response ? *response_len : 0, .sink = sink, .context = context};
    long code = 0;
    int status = 5;
    struct curl_slist *headers = NULL;
    struct cancellation cancellation = {cancel, cancel_context};
#define SET(opt, value) if (curl_easy_setopt(curl, opt, value) != CURLE_OK) goto done
    char url[768];
    if (!path || path[0] != '/' || strstr(path, "..") || !version || !*version ||
        version[strspn(version, "0123456789.")] || timeout_ms <= 0 ||
        snprintf(url, sizeof(url), "http://localhost/v%s/libpod%s", version, path) >= (int)sizeof(url)) {
        status = 1;
        goto done;
    }
    SET(CURLOPT_URL, url); SET(CURLOPT_UNIX_SOCKET_PATH, socket); SET(CURLOPT_PROXY, ""); SET(CURLOPT_PROTOCOLS_STR, "http");
    SET(CURLOPT_NOSIGNAL, 1L); SET(CURLOPT_CUSTOMREQUEST, method);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 1000L); SET(CURLOPT_TIMEOUT_MS, (long)timeout_ms);
    SET(CURLOPT_WRITEFUNCTION, write_body); SET(CURLOPT_WRITEDATA, &result);
    SET(CURLOPT_HEADERFUNCTION, read_header); SET(CURLOPT_HEADERDATA, &result);
    if (cancel) {
        if (cancel(cancel_context)) { status = 7; goto done; }
        SET(CURLOPT_NOPROGRESS, 0L);
        SET(CURLOPT_XFERINFOFUNCTION, progress);
        SET(CURLOPT_XFERINFODATA, &cancellation);
    }
    if (body) {
        headers = curl_slist_append(NULL, content_type ? content_type : "Content-Type: application/json");
        if (!headers) goto done;
        SET(CURLOPT_HTTPHEADER, headers);
        SET(CURLOPT_POSTFIELDS, body); SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
    }
    CURLcode rc = curl_easy_perform(curl);
    if (rc == CURLE_OPERATION_TIMEDOUT) status = 2;
    else if (rc == CURLE_ABORTED_BY_CALLBACK) status = 7;
    else if (rc != CURLE_OK) status = result.aborted ? 6 : result.overflow ? 4 : 5;
    else if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code) == CURLE_OK) {
        if (code >= 200 && code < 300) {
            if (response_len) *response_len = result.used;
            status = 0;
        } else if (code >= 400 && code <= 599) status = (int)code;
        else status = 1;
    }
done:
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return status;
#undef SET
}

static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int attach_ready(int fd, short events, long long deadline) {
    struct pollfd p = {.fd = fd, .events = events};
    for (;;) {
        long long now = monotonic_ms();
        if (now < 0 || now >= deadline) return 2;
        int rc = poll(&p, 1, (int)(deadline - now));
        if (rc > 0) return 0;
        if (rc == 0) return 2;
        if (errno != EINTR) return 5;
    }
}

int podtest_attach_open(const char *path, const char *version, const char *endpoint, unsigned timeout, int *out) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    char request[512], header[8192];
    if (!*path || strlen(path) >= sizeof(addr.sun_path) || !*version ||
        version[strspn(version, "0123456789.")] || !timeout || timeout > 30000) return 1;
    strcpy(addr.sun_path, path);
    int n = snprintf(request, sizeof(request), "POST /v%s/libpod%s HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n", version, endpoint);
    if (n < 0 || n >= (int)sizeof(request)) return 1;
    long long now = monotonic_ms();
    if (now < 0) return 5;
    long long deadline = now + timeout;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return 5;
    int rc = 5;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto fail;
    for (int sent = 0; sent < n;) {
        if ((rc = attach_ready(fd, POLLOUT, deadline))) goto fail;
        ssize_t count = send(fd, request + sent, (size_t)(n - sent), MSG_NOSIGNAL);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) { rc = 5; goto fail; }
        sent += (int)count;
    }
    /* Do not consume bytes belonging to the upgraded stream. */
    for (size_t used = 0; used < sizeof(header) - 1;) {
        if ((rc = attach_ready(fd, POLLIN, deadline))) goto fail;
        ssize_t count = recv(fd, header + used, 1, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count != 1) { rc = 5; goto fail; }
        ++used;
        if (used >= 4 && !memcmp(header + used - 4, "\r\n\r\n", 4)) {
            header[used] = 0;
            int code = 0;
            if (sscanf(header, "HTTP/1.1 %d", &code) != 1) { rc = 1; goto fail; }
            if (code != 101) { rc = code >= 400 && code <= 599 ? code : 1; goto fail; }
            *out = fd;
            return 0;
        }
    }
    rc = 4;
fail:
    close(fd);
    return rc;
}

/* -1: would block, -2: closed peer, -3: transport failure. */
long podtest_attach_io(int fd, void *bytes, size_t len, int writing) {
    ssize_t n;
    do { n = writing ? send(fd, bytes, len, MSG_NOSIGNAL) : recv(fd, bytes, len, 0); }
    while (n == -1 && errno == EINTR);
    if (n >= 0) return n;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
    if (errno == EPIPE || errno == ECONNRESET) return -2;
    return -3;
}

int podtest_attach_half_close(int fd) { return shutdown(fd, SHUT_WR); }
void podtest_attach_close(int fd) { close(fd); }
