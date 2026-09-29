#include "ProcessEnvironment.h"
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

int sb_environment_value(pid_t pid, const char *key, char *out, size_t capacity) {
    if (!out || capacity == 0) return -1;
    out[0] = '\0';
    int argmax = 0;
    size_t length = sizeof(argmax);
    int limit[] = {CTL_KERN, KERN_ARGMAX};
    if (sysctl(limit, 2, &argmax, &length, NULL, 0) != 0 || argmax <= 0) return -1;
    char *buffer = calloc((size_t)argmax, 1);
    if (!buffer) return -1;
    int query[] = {CTL_KERN, KERN_PROCARGS2, pid};
    length = (size_t)argmax;
    if (sysctl(query, 3, buffer, &length, NULL, 0) != 0 || length < sizeof(int)) {
        free(buffer); return -1;
    }
    int argc = 0;
    memcpy(&argc, buffer, sizeof(argc));
    char *p = buffer + sizeof(argc), *end = buffer + length;
    while (p < end && *p) p++;
    while (p < end && !*p) p++;
    for (int i = 0; i < argc; i++) {
        while (p < end && *p) p++;
        if (p < end) p++;
    }
    size_t keylen = strlen(key);
    int result = 0;
    while (p < end && *p) {
        size_t size = strnlen(p, (size_t)(end - p));
        if (size == (size_t)(end - p)) { result = -1; break; }
        if (size > keylen && !strncmp(p, key, keylen) && p[keylen] == '=') {
            size_t value_size = size - keylen - 1;
            if (value_size >= capacity) { result = -1; break; }
            memcpy(out, p + keylen + 1, value_size);
            out[value_size] = '\0';
            result = 1;
            break;
        }
        p += size + 1;
    }
    /* The buffer may contain unrelated environment values; do not retain it. */
    memset(buffer, 0, length);
    free(buffer);
    return result;
}
