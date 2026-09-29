#ifndef SWITCHBOARD_PROCESS_ENVIRONMENT_H
#define SWITCHBOARD_PROCESS_ENVIRONMENT_H
#include <stddef.h>
#include <sys/types.h>
/* 1: found, 0: absent, -1: unavailable or malformed. Spaces remain intact. */
int sb_environment_value(pid_t pid, const char *key, char *destination, size_t capacity);
#endif
