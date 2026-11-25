#define _GNU_SOURCE
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/vfs.h>
#include <unistd.h>

int podtest_has_disk_space(int fd) {
    struct statvfs stat;
    if (fstatvfs(fd, &stat) != 0 || stat.f_frsize == 0 ||
        stat.f_bavail < (2ULL * 1024 * 1024 * 1024 + stat.f_frsize - 1) / stat.f_frsize)
        return 0;
    if (stat.f_favail >= 16384) return 1;

    /* Btrfs allocates inodes dynamically and reports no inode counts. */
    struct statfs fs;
    return stat.f_files == 0 && stat.f_favail == 0 &&
        fstatfs(fd, &fs) == 0 && fs.f_type == BTRFS_SUPER_MAGIC;
}

/* State directory is provisioned by the operator. Lock the directory inode. */
int podtest_lock(const char *path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_uid == geteuid() && !(st.st_mode & 0077)) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
        if (errno == EWOULDBLOCK) {
            close(fd);
            return -2;
        }
    }
    close(fd);
    return -1;
}

struct ping {
    const char *version;
    char body[2];
    size_t used;
    int version_matches;
};

static size_t header(char *data, size_t size, size_t count, void *context) {
    struct ping *ping = context;
    size_t n = size * count;
    const char prefix[] = "Libpod-Api-Version:";
    if (n >= sizeof(prefix) - 1 && !strncasecmp(data, prefix, sizeof(prefix) - 1)) {
        size_t begin = sizeof(prefix) - 1;
        while (begin < n && (data[begin] == ' ' || data[begin] == '\t')) begin++;
        size_t end = n;
        while (end > begin && strchr("\r\n \t", data[end - 1])) end--;
        ping->version_matches = end - begin == strlen(ping->version) &&
            !memcmp(data + begin, ping->version, end - begin);
    }
    return n;
}

static size_t body(char *data, size_t size, size_t count, void *context) {
    struct ping *ping = context;
    size_t n = size * count;
    if (n > sizeof(ping->body) - ping->used) return 0;
    memcpy(ping->body + ping->used, data, n);
    ping->used += n;
    return n;
}

int podtest_ping(const char *socket, const char *version) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return 1;
    CURL *curl = curl_easy_init();
    int result = 1;
    struct ping ping = {.version = version};
    long status = 0;
    if (!curl) goto done;
#define SET(opt, val) if (curl_easy_setopt(curl, opt, val) != CURLE_OK) goto done
    SET(CURLOPT_URL, "http://localhost/libpod/_ping");
    SET(CURLOPT_UNIX_SOCKET_PATH, socket);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_PROTOCOLS_STR, "http");
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 1000L);
    SET(CURLOPT_TIMEOUT_MS, 3000L);
    SET(CURLOPT_HEADERFUNCTION, header);
    SET(CURLOPT_HEADERDATA, &ping);
    SET(CURLOPT_WRITEFUNCTION, body);
    SET(CURLOPT_WRITEDATA, &ping);
#undef SET
    CURLcode code = curl_easy_perform(curl);
    if (code == CURLE_OPERATION_TIMEDOUT) result = 2;
    if (code != CURLE_OK) goto done;
    if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) goto done;
    result = status != 200 || ping.used != 2 || memcmp(ping.body, "OK", 2) ? 3 :
        !ping.version_matches ? 4 : 0;
done:
    if (curl) curl_easy_cleanup(curl);
    curl_global_cleanup();
    return result;
}
