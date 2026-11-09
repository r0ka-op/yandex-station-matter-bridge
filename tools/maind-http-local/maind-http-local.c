#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define SERVER_PORT 8765
#define HEADER_LIMIT (64U * 1024U)
#define REQUEST_LIMIT (1024U * 1024U)
#define DEFAULT_RESPONSE_LIMIT (1024U * 1024U)
#define DEFAULT_TIMEOUT_MS 30000

enum exit_code {
    EXIT_USAGE_ERROR = 64,
    EXIT_INPUT_ERROR = 65,
    EXIT_CONNECT_ERROR = 66,
    EXIT_SEND_ERROR = 67,
    EXIT_RECEIVE_ERROR = 68,
    EXIT_PROTOCOL_ERROR = 69,
    EXIT_LIMIT_ERROR = 70,
    EXIT_TIMEOUT_ERROR = 71,
    EXIT_OUTPUT_ERROR = 72
};

struct buffer {
    unsigned char *data;
    size_t length;
    size_t capacity;
};

static void fail(int code, const char *message) {
    (void)fprintf(stderr, "maind-http-local: %s\n", message);
    exit(code);
}

static int64_t monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        fail(EXIT_TIMEOUT_ERROR, "monotonic clock unavailable");
    }
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int remaining_ms(int64_t deadline) {
    int64_t remaining = deadline - monotonic_ms();
    if (remaining <= 0) {
        return 0;
    }
    return remaining > INT_MAX ? INT_MAX : (int)remaining;
}

static int wait_fd(int fd, short events, int64_t deadline) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;
    for (;;) {
        int timeout = remaining_ms(deadline);
        int result;
        if (timeout == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        result = poll(&pfd, 1, timeout);
        if (result > 0) {
            if ((pfd.revents & events) != 0) {
                return 0;
            }
            if ((events & POLLIN) != 0 && (pfd.revents & POLLHUP) != 0) {
                return 0;
            }
            errno = (pfd.revents & POLLNVAL) ? EBADF : ECONNRESET;
            return -1;
        }
        if (result == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static void append_buffer(struct buffer *buffer, const void *source, size_t count,
                          size_t limit) {
    size_t required;
    size_t capacity;
    unsigned char *replacement;
    if (count == 0) {
        return;
    }
    if (count > limit || buffer->length > limit - count) {
        fail(EXIT_LIMIT_ERROR, "configured byte limit exceeded");
    }
    required = buffer->length + count;
    if (required <= buffer->capacity) {
        memcpy(buffer->data + buffer->length, source, count);
        buffer->length = required;
        return;
    }
    capacity = buffer->capacity == 0 ? 4096U : buffer->capacity;
    while (capacity < required) {
        if (capacity > limit / 2U) {
            capacity = limit;
            break;
        }
        capacity *= 2U;
    }
    replacement = realloc(buffer->data, capacity);
    if (replacement == NULL) {
        fail(EXIT_LIMIT_ERROR, "memory allocation failed");
    }
    buffer->data = replacement;
    buffer->capacity = capacity;
    memcpy(buffer->data + buffer->length, source, count);
    buffer->length = required;
}

static void read_stdin(struct buffer *body) {
    unsigned char chunk[8192];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, chunk, sizeof(chunk));
        if (count > 0) {
            append_buffer(body, chunk, (size_t)count, REQUEST_LIMIT);
            continue;
        }
        if (count == 0) {
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        fail(EXIT_INPUT_ERROR, "could not read request body");
    }
}

static int path_allowed(const char *path) {
    static const char *const allowed[] = {
        "/devices",
        "/interaction/readAttribute",
        "/commissioning/window"
    };
    size_t i;
    if (path == NULL || path[0] != '/' || strchr(path, '\r') != NULL ||
        strchr(path, '\n') != NULL || strchr(path, ' ') != NULL) {
        return 0;
    }
    for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); ++i) {
        if (strcmp(path, allowed[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int connect_loopback(int64_t deadline) {
    int fd;
    int flags;
    int error = 0;
    socklen_t error_length = sizeof(error);
    struct sockaddr_in address;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fail(EXIT_CONNECT_ERROR, "socket creation failed");
    }
    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        fail(EXIT_CONNECT_ERROR, "could not configure socket");
    }
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(SERVER_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errno != EINPROGRESS || wait_fd(fd, POLLOUT, deadline) != 0 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) != 0 ||
            error != 0) {
            close(fd);
            if (errno == ETIMEDOUT) {
                fail(EXIT_TIMEOUT_ERROR, "connect timeout");
            }
            fail(EXIT_CONNECT_ERROR, "loopback connection failed");
        }
    }
    return fd;
}

static void send_all(int fd, const unsigned char *data, size_t length,
                     int64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count;
        if (wait_fd(fd, POLLOUT, deadline) != 0) {
            fail(errno == ETIMEDOUT ? EXIT_TIMEOUT_ERROR : EXIT_SEND_ERROR,
                 errno == ETIMEDOUT ? "send timeout" : "send readiness failed");
        }
        count = send(fd, data + offset, length - offset, MSG_NOSIGNAL);
        if (count > 0) {
            offset += (size_t)count;
            continue;
        }
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        fail(EXIT_SEND_ERROR, "request send failed");
    }
}

static size_t find_header_end(const unsigned char *data, size_t length) {
    size_t i;
    for (i = 3; i < length; ++i) {
        if (data[i - 3] == '\r' && data[i - 2] == '\n' &&
            data[i - 1] == '\r' && data[i] == '\n') {
            return i + 1;
        }
    }
    return 0;
}

static int ascii_equal_nocase(const unsigned char *data, size_t length,
                              const char *text) {
    size_t i;
    if (strlen(text) != length) {
        return 0;
    }
    for (i = 0; i < length; ++i) {
        if (tolower(data[i]) != tolower((unsigned char)text[i])) {
            return 0;
        }
    }
    return 1;
}

static size_t parse_decimal(const unsigned char *data, size_t length) {
    size_t value = 0;
    size_t i;
    if (length == 0) {
        fail(EXIT_PROTOCOL_ERROR, "empty Content-Length");
    }
    for (i = 0; i < length; ++i) {
        unsigned int digit;
        if (!isdigit(data[i])) {
            fail(EXIT_PROTOCOL_ERROR, "invalid Content-Length");
        }
        digit = (unsigned int)(data[i] - '0');
        if (value > (SIZE_MAX - digit) / 10U) {
            fail(EXIT_PROTOCOL_ERROR, "Content-Length overflow");
        }
        value = value * 10U + digit;
    }
    return value;
}

static size_t parse_response_headers(const unsigned char *data, size_t header_end,
                                     size_t response_limit) {
    size_t line_end = 0;
    size_t cursor;
    size_t content_length = 0;
    int content_length_seen = 0;

    while (line_end + 1 < header_end &&
           !(data[line_end] == '\r' && data[line_end + 1] == '\n')) {
        ++line_end;
    }
    if (line_end < 12 || line_end + 1 >= header_end ||
        !((memcmp(data, "HTTP/1.1 ", 9) == 0) || (memcmp(data, "HTTP/1.0 ", 9) == 0)) ||
        data[9] < '1' || data[9] > '5' || !isdigit(data[10]) || !isdigit(data[11]) ||
        (line_end > 12 && data[12] != ' ')) {
        fail(EXIT_PROTOCOL_ERROR, "invalid HTTP status line");
    }
    cursor = line_end + 2;
    while (cursor + 1 < header_end) {
        size_t end = cursor;
        size_t colon;
        size_t value_start;
        size_t value_end;
        if (data[cursor] == '\r' && data[cursor + 1] == '\n') {
            break;
        }
        while (end + 1 < header_end && !(data[end] == '\r' && data[end + 1] == '\n')) {
            ++end;
        }
        if (end + 1 >= header_end) {
            fail(EXIT_PROTOCOL_ERROR, "malformed HTTP header line");
        }
        colon = cursor;
        while (colon < end && data[colon] != ':') {
            ++colon;
        }
        if (colon == cursor || colon == end) {
            fail(EXIT_PROTOCOL_ERROR, "malformed HTTP header field");
        }
        value_start = colon + 1;
        while (value_start < end && (data[value_start] == ' ' || data[value_start] == '\t')) {
            ++value_start;
        }
        value_end = end;
        while (value_end > value_start &&
               (data[value_end - 1] == ' ' || data[value_end - 1] == '\t')) {
            --value_end;
        }
        if (ascii_equal_nocase(data + cursor, colon - cursor, "Content-Length")) {
            size_t parsed = parse_decimal(data + value_start, value_end - value_start);
            if (content_length_seen && parsed != content_length) {
                fail(EXIT_PROTOCOL_ERROR, "conflicting Content-Length headers");
            }
            content_length = parsed;
            content_length_seen = 1;
        } else if (ascii_equal_nocase(data + cursor, colon - cursor,
                                      "Transfer-Encoding")) {
            fail(EXIT_PROTOCOL_ERROR, "Transfer-Encoding is unsupported");
        }
        cursor = end + 2;
    }
    if (!content_length_seen) {
        fail(EXIT_PROTOCOL_ERROR, "Content-Length response header required");
    }
    if (content_length > response_limit || header_end > response_limit - content_length) {
        fail(EXIT_LIMIT_ERROR, "response exceeds configured limit");
    }
    return content_length;
}

static void receive_response(int fd, struct buffer *response, size_t response_limit,
                             int64_t deadline) {
    unsigned char chunk[8192];
    size_t header_end = 0;
    size_t expected_total = 0;
    for (;;) {
        ssize_t count;
        if (expected_total != 0 && response->length == expected_total) {
            return;
        }
        if (wait_fd(fd, POLLIN, deadline) != 0) {
            fail(errno == ETIMEDOUT ? EXIT_TIMEOUT_ERROR : EXIT_RECEIVE_ERROR,
                 errno == ETIMEDOUT ? "receive timeout" : "receive readiness failed");
        }
        count = recv(fd, chunk, sizeof(chunk), 0);
        if (count > 0) {
            append_buffer(response, chunk, (size_t)count, response_limit);
            if (header_end == 0) {
                header_end = find_header_end(response->data, response->length);
                if (header_end == 0 && response->length > HEADER_LIMIT) {
                    fail(EXIT_PROTOCOL_ERROR, "HTTP header block too large");
                }
                if (header_end != 0) {
                    size_t content_length = parse_response_headers(
                        response->data, header_end, response_limit);
                    expected_total = header_end + content_length;
                    if (response->length > expected_total) {
                        fail(EXIT_PROTOCOL_ERROR, "response contains bytes beyond Content-Length");
                    }
                }
            } else if (response->length > expected_total) {
                fail(EXIT_PROTOCOL_ERROR, "response contains bytes beyond Content-Length");
            }
            continue;
        }
        if (count == 0) {
            if (header_end == 0) {
                fail(EXIT_PROTOCOL_ERROR, "EOF before complete HTTP headers");
            }
            if (response->length != expected_total) {
                fail(EXIT_PROTOCOL_ERROR, "EOF before complete HTTP body");
            }
            return;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            continue;
        }
        fail(EXIT_RECEIVE_ERROR, "response receive failed");
    }
}

static void write_stdout(const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(STDOUT_FILENO, data + offset, length - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            fail(EXIT_OUTPUT_ERROR, "stdout write failed");
        }
    }
}

static long parse_long(const char *text, long minimum, long maximum,
                       const char *error_message) {
    char *end = NULL;
    long value;
    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < minimum || value > maximum) {
        fail(EXIT_USAGE_ERROR, error_message);
    }
    return value;
}

int main(int argc, char **argv) {
    const char *method = NULL;
    const char *path = NULL;
    long timeout_ms = DEFAULT_TIMEOUT_MS;
    long response_limit = DEFAULT_RESPONSE_LIMIT;
    struct buffer body = {0};
    struct buffer request = {0};
    struct buffer response = {0};
    char headers[512];
    int header_length;
    int fd;
    int64_t deadline;
    int i;

    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        (void)puts("maind-http-local 1");
        return 0;
    }
    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--method") == 0 && i + 1 < argc) {
            method = argv[++i];
        } else if (strcmp(argv[i], "--path") == 0 && i + 1 < argc) {
            path = argv[++i];
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc) {
            timeout_ms = parse_long(argv[++i], 100, 300000, "invalid timeout");
        } else if (strcmp(argv[i], "--max-response") == 0 && i + 1 < argc) {
            response_limit = parse_long(argv[++i], 1024, 2097152,
                                        "invalid response limit");
        } else {
            fail(EXIT_USAGE_ERROR, "invalid arguments");
        }
    }
    if (method == NULL || path == NULL ||
        (strcmp(method, "GET") != 0 && strcmp(method, "POST") != 0) ||
        !path_allowed(path)) {
        fail(EXIT_USAGE_ERROR, "method or allowlisted path required");
    }
    (void)signal(SIGPIPE, SIG_IGN);
    if (strcmp(method, "POST") == 0) {
        read_stdin(&body);
        if (body.length == 0) {
            fail(EXIT_INPUT_ERROR, "POST body is empty");
        }
    }
    header_length = snprintf(
        headers, sizeof(headers),
        "%s %s HTTP/1.1\r\n"
        "Host: 127.0.0.1:8765\r\n"
        "Accept: application/json\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n",
        method, path, body.length);
    if (header_length <= 0 || (size_t)header_length >= sizeof(headers)) {
        fail(EXIT_USAGE_ERROR, "request headers exceed internal limit");
    }
    append_buffer(&request, headers, (size_t)header_length,
                  REQUEST_LIMIT + sizeof(headers));
    append_buffer(&request, body.data, body.length, REQUEST_LIMIT + sizeof(headers));
    deadline = monotonic_ms() + timeout_ms;
    fd = connect_loopback(deadline);
    send_all(fd, request.data, request.length, deadline);
    if (shutdown(fd, SHUT_WR) != 0 && errno != ENOTCONN) {
        close(fd);
        fail(EXIT_SEND_ERROR, "request shutdown failed");
    }
    receive_response(fd, &response, (size_t)response_limit, deadline);
    close(fd);
    write_stdout(response.data, response.length);
    free(body.data);
    free(request.data);
    free(response.data);
    return 0;
}
