#ifndef PORTS_PROCESS_BRIDGE_H
#define PORTS_PROCESS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t pid;
    int32_t parent_pid;
    uint32_t uid;
    uint32_t status;
    uint64_t start_seconds;
    uint64_t start_microseconds;
    uint64_t resident_bytes;
    uint64_t cpu_nanoseconds;
    int has_metrics;
    char name[64];
    char executable[4096];
    char working_directory[4096];
} DSProcessInfo;

// The caller owns all buffers. No global state, retained pointers, or environment reads.
int ds_list_pids(int32_t *buffer, int capacity);
int ds_read_process(int32_t pid, DSProcessInfo *info);
// Copies only argv, excluding environment variables. Returns bytes or -1 on failure.
int ds_read_arguments(int32_t pid, char *buffer, size_t capacity);

#endif
