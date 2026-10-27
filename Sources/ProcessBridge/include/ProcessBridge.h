#ifndef PORTS_PROCESS_BRIDGE_H
#define PORTS_PROCESS_BRIDGE_H

#include <stdbool.h>
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
    bool has_executed; // PROC_FLAG_EXEC: a forked child keeps its parent's argv until it calls exec.
    char name[64];
    char executable[4096];
    char working_directory[4096];
} DSProcessInfo;

typedef struct {
    uint16_t port; // Host byte order.
    char address[48]; // "*" for a wildcard bind that accepts IPv4, "::" for an IPv6-only one.
} DSListener;

// The caller owns all buffers. No global state, retained pointers, or environment reads.
int ds_list_pids(int32_t *buffer, int capacity);
// Lists the children of pid, zombies included. Returns the number written, at most capacity (a full buffer may have
// cut the list), or -1 on failure. A missing pid has no children.
int ds_list_child_pids(int32_t pid, int32_t *buffer, int capacity);
int ds_read_process(int32_t pid, DSProcessInfo *info);
// Copies only argv, excluding environment variables. Returns bytes, -2 when capacity is too small, or -1 on failure.
int ds_read_arguments(int32_t pid, char *buffer, size_t capacity);
// Reads only the start time and run state, no path or argv. Returns 1, or 0 when the process is gone or unreadable.
int ds_read_identity(int32_t pid, uint64_t *start_seconds, uint64_t *start_microseconds, int32_t *status);
// Returns the number of listening TCP sockets, which may exceed capacity; only capacity entries are written.
// Returns -1 when the process is gone (ESRCH) or belongs to another user (EPERM).
int ds_read_tcp_listeners(int32_t pid, DSListener *buffer, int capacity);

#endif
