#include <curl/curl.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

typedef size_t (*artifact_write)(const unsigned char *, size_t, void *);
typedef int (*artifact_cancelled)(void *);
typedef size_t (*artifact_read)(unsigned char *, size_t, void *);

struct transfer {
    CURL *curl;
    artifact_write write;
    artifact_cancelled cancelled;
    void *context;
    artifact_read read;
};

static size_t write_body(char *data, size_t size, size_t count, void *opaque) {
    struct transfer *t = opaque;
    long status = 0;
    if (curl_easy_getinfo(t->curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK || status != 200) return 0;
    if (size && count > SIZE_MAX / size) return 0;
    return t->write((const unsigned char *)data, size * count, t->context);
}

static int progress(void *opaque, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    struct transfer *t = opaque;
    return t->cancelled(t->context);
}

static int same_origin(CURLU *url, CURLU *origin) {
    char *scheme = NULL, *origin_scheme = NULL, *host = NULL, *origin_host = NULL;
    char *port = NULL, *origin_port = NULL;
    int ok = !curl_url_get(url, CURLUPART_SCHEME, &scheme, 0) && !strcmp(scheme, "https") &&
        !curl_url_get(origin, CURLUPART_SCHEME, &origin_scheme, 0) && !strcmp(origin_scheme, "https") &&
        !curl_url_get(url, CURLUPART_HOST, &host, 0) &&
        !curl_url_get(origin, CURLUPART_HOST, &origin_host, 0) && !strcasecmp(host, origin_host) &&
        !curl_url_get(url, CURLUPART_PORT, &port, CURLU_DEFAULT_PORT) &&
        !curl_url_get(origin, CURLUPART_PORT, &origin_port, CURLU_DEFAULT_PORT) && !strcmp(port, origin_port);
    curl_free(scheme); curl_free(origin_scheme); curl_free(host); curl_free(origin_host);
    curl_free(port); curl_free(origin_port);
    return ok;
}

enum result { OK, SETUP, URL_REJECTED, TLS, TIMEOUT, TRANSIENT, REJECTED, INTERRUPTED, BODY_ERROR };

/* Caller owns curl global initialization and cleanup. */
int podtest_artifact_get(const char *url_text, const char *origin_text, const char *ca_file,
        long timeout_ms, artifact_write write, artifact_cancelled cancelled, void *context) {
    int result = SETUP;
    long status = 0;
    CURLU *url = curl_url(), *origin = curl_url();
    CURL *curl = NULL;
    struct transfer transfer = {.write = write, .cancelled = cancelled, .context = context};
    if (!url || !origin) goto done;
    if (curl_url_set(url, CURLUPART_URL, url_text, CURLU_DISALLOW_USER | CURLU_PATH_AS_IS) ||
        curl_url_set(origin, CURLUPART_URL, origin_text, CURLU_DISALLOW_USER) || !same_origin(url, origin)) {
        result = URL_REJECTED;
        goto done;
    }
    curl = curl_easy_init();
    if (!curl) goto done;
    transfer.curl = curl;
#define SET(k, v) if (curl_easy_setopt(curl, k, v) != CURLE_OK) goto done
    SET(CURLOPT_CURLU, url);
    SET(CURLOPT_PROTOCOLS_STR, "https");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_NETRC, CURL_NETRC_IGNORED);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    if (ca_file) { SET(CURLOPT_CAINFO, ca_file); }
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS, timeout_ms < 3000 ? timeout_ms : 3000L);
    SET(CURLOPT_TIMEOUT_MS, timeout_ms);
    SET(CURLOPT_FAILONERROR, 1L);
    SET(CURLOPT_HTTP_CONTENT_DECODING, 0L);
    SET(CURLOPT_WRITEFUNCTION, write_body);
    SET(CURLOPT_WRITEDATA, &transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    SET(CURLOPT_XFERINFODATA, &transfer);
#undef SET
    CURLcode code = curl_easy_perform(curl);
    if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) goto done;
    if (code == CURLE_OPERATION_TIMEDOUT) result = TIMEOUT;
    else if (code == CURLE_PEER_FAILED_VERIFICATION || code == CURLE_SSL_CONNECT_ERROR || code == CURLE_SSL_CACERT_BADFILE) result = TLS;
    else if (code == CURLE_ABORTED_BY_CALLBACK) result = INTERRUPTED;
    else if (status >= 300) result = (status == 408 || status == 429 || (status >= 500 && status <= 599)) ? TRANSIENT : REJECTED;
    else if (code == CURLE_WRITE_ERROR) result = status && status != 200 ? REJECTED : BODY_ERROR;
    else if (code == CURLE_COULDNT_CONNECT || code == CURLE_COULDNT_RESOLVE_HOST ||
        code == CURLE_PARTIAL_FILE || code == CURLE_RECV_ERROR || code == CURLE_SEND_ERROR || code == CURLE_GOT_NOTHING) result = TRANSIENT;
    else if (code == CURLE_OK) result = status == 200 ? OK : REJECTED;
done:
    if (curl) curl_easy_cleanup(curl);
    if (url) curl_url_cleanup(url);
    if (origin) curl_url_cleanup(origin);
    return result;
}

static size_t read_body(char *data, size_t size, size_t count, void *opaque) {
    struct transfer *t = opaque;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    const size_t capacity = size * count;
    if (t->cancelled(t->context)) return CURL_READFUNC_ABORT;
    const size_t bytes = t->read((unsigned char *)data, capacity, t->context);
    return bytes <= capacity ? bytes : CURL_READFUNC_ABORT;
}

/* Uploads to a single HTTPS signed target; redirects and proxy env are disabled. */
static size_t discard_body(char *data, size_t size, size_t count, void *opaque) {
    (void)data; (void)opaque;
    return size && count > SIZE_MAX / size ? 0 : size * count;
}

int podtest_artifact_put(const char *url_text, const char *origin_text, const char *ca_file,
        long timeout_ms, curl_off_t expected_size, artifact_read read, artifact_cancelled cancelled,
        void *context, const char *checksum_header) {
    CURLU *url = curl_url(), *origin = curl_url();
    CURL *curl = NULL;
    int result = SETUP;
    struct curl_slist *headers = curl_slist_append(NULL, checksum_header);
    long status = 0;
    struct transfer transfer = {.read = read, .cancelled = cancelled, .context = context};
    if (!url || !origin || !headers) goto done;
    if (curl_url_set(url, CURLUPART_URL, url_text, CURLU_DISALLOW_USER | CURLU_PATH_AS_IS) ||
        curl_url_set(origin, CURLUPART_URL, origin_text, CURLU_DISALLOW_USER) || !same_origin(url, origin)) {
        result = URL_REJECTED; goto done;
    }
    curl = curl_easy_init();
    if (!curl) goto done;
    transfer.curl = curl;
#define PUT(k, v) if (curl_easy_setopt(curl, k, v) != CURLE_OK) goto done
    PUT(CURLOPT_CURLU, url); PUT(CURLOPT_PROTOCOLS_STR, "https"); PUT(CURLOPT_FOLLOWLOCATION, 0L);
    PUT(CURLOPT_PROXY, ""); PUT(CURLOPT_NETRC, CURL_NETRC_IGNORED); PUT(CURLOPT_SSL_VERIFYPEER, 1L);
    PUT(CURLOPT_SSL_VERIFYHOST, 2L); if (ca_file) PUT(CURLOPT_CAINFO, ca_file);
    PUT(CURLOPT_NOSIGNAL, 1L); PUT(CURLOPT_CONNECTTIMEOUT_MS, timeout_ms < 3000 ? timeout_ms : 3000L);
    PUT(CURLOPT_TIMEOUT_MS, timeout_ms); PUT(CURLOPT_UPLOAD, 1L); PUT(CURLOPT_INFILESIZE_LARGE, expected_size);
    PUT(CURLOPT_READFUNCTION, read_body); PUT(CURLOPT_READDATA, &transfer);
    PUT(CURLOPT_HTTPHEADER, headers); PUT(CURLOPT_WRITEFUNCTION, discard_body);
    PUT(CURLOPT_NOPROGRESS, 0L); PUT(CURLOPT_XFERINFOFUNCTION, progress); PUT(CURLOPT_XFERINFODATA, &transfer);
#undef PUT
    CURLcode code = curl_easy_perform(curl);
    if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) goto done;
    if (code == CURLE_OPERATION_TIMEDOUT) result = TIMEOUT;
    else if (code == CURLE_PEER_FAILED_VERIFICATION || code == CURLE_SSL_CONNECT_ERROR || code == CURLE_SSL_CACERT_BADFILE) result = TLS;
    else if (code == CURLE_ABORTED_BY_CALLBACK) result = INTERRUPTED;
    else if (status >= 300) result = (status == 408 || status == 429 || (status >= 500 && status <= 599)) ? TRANSIENT : REJECTED;
    else if (code == CURLE_OK) result = status == 200 ? OK : REJECTED;
    else if (code == CURLE_COULDNT_CONNECT || code == CURLE_COULDNT_RESOLVE_HOST || code == CURLE_RECV_ERROR || code == CURLE_SEND_ERROR || code == CURLE_GOT_NOTHING) result = TRANSIENT;
done:
    if (curl) curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    if (url) curl_url_cleanup(url);
    if (origin) curl_url_cleanup(origin);
    return result;
}
