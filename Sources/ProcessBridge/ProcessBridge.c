#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <arpa/inet.h>
#include <netinet/in.h>

int ds_list_pids(int32_t *buffer, int capacity) {
    if (!buffer || capacity <= 0) return proc_listallpids(NULL, 0);
    return proc_listallpids(buffer, capacity * (int)sizeof(int32_t));
}

int ds_list_child_pids(int32_t pid, int32_t *buffer, int capacity) {
    if (pid <= 0 || !buffer || capacity <= 0) return -1;
    return proc_listchildpids(pid, buffer, capacity * (int)sizeof(int32_t));
}

int ds_read_process(int32_t pid, DSProcessInfo *info) {
    if (pid <= 0 || !info) return 0;
    struct proc_bsdinfo bsd = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return 0;
    memset(info, 0, sizeof(*info));
    info->pid = pid;
    info->parent_pid = bsd.pbi_ppid;
    info->uid = bsd.pbi_uid;
    info->status = bsd.pbi_status;
    info->start_seconds = bsd.pbi_start_tvsec;
    info->start_microseconds = bsd.pbi_start_tvusec;
    info->has_executed = (bsd.pbi_flags & PROC_FLAG_EXEC) != 0;
    strlcpy(info->name, bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm, sizeof(info->name));
    proc_pidpath(pid, info->executable, sizeof(info->executable));
    struct proc_taskinfo task = {0};
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        info->has_metrics = 1;
        info->resident_bytes = task.pti_resident_size;
        info->cpu_nanoseconds = task.pti_total_user + task.pti_total_system;
    }
    struct proc_vnodepathinfo paths = {0};
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths)) == sizeof(paths)) {
        strlcpy(info->working_directory, paths.pvi_cdir.vip_path, sizeof(info->working_directory));
    }
    return 1;
}

int ds_read_identity(int32_t pid, uint64_t *start_seconds, uint64_t *start_microseconds, int32_t *status) {
    if (pid <= 0 || !start_seconds || !start_microseconds || !status) return 0;
    struct proc_bsdinfo bsd = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return 0;
    *start_seconds = bsd.pbi_start_tvsec;
    *start_microseconds = bsd.pbi_start_tvusec;
    *status = (int32_t)bsd.pbi_status;
    return 1;
}

static int ds_copy_arguments(const char *raw, size_t length, char *buffer, size_t capacity) {
    int argc = 0;
    memcpy(&argc, raw, sizeof(argc));
    const char *cursor = raw + sizeof(argc), *end = raw + length;
    // Skip the executable path and the kernel's alignment padding.
    while (cursor < end && *cursor) cursor++;
    while (cursor < end && !*cursor) cursor++;
    size_t written = 0;
    for (int index = 0; index < argc && cursor < end; index++) {
        size_t size = strnlen(cursor, (size_t)(end - cursor));
        if (cursor + size >= end) return -1;
        if (written + size + 1 > capacity) return -2;
        memcpy(buffer + written, cursor, size + 1);
        written += size + 1;
        cursor += size + 1;
    }
    return (int)written;
}

// The area holds argc, the executable path, argv, the environment and Apple strings. It averages about 1.5 KB;
// kern.argmax is 1 MB. sysctl truncates silently, so the size is queried first.
int ds_read_arguments(int32_t pid, char *buffer, size_t capacity) {
    if (pid <= 0 || !buffer || capacity == 0) return -1;
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t needed = 0;
    if (sysctl(mib, 3, NULL, &needed, NULL, 0) != 0 || needed < sizeof(int)) return -1;
    char stack[16 * 1024];
    // Spare room tells a complete read from one that an exec in between has cut. The kernel rejects buffers
    // larger than ARG_MAX.
    size_t size = needed + 1024 <= sizeof(stack) ? sizeof(stack) : needed + 1024;
    if (size > ARG_MAX) size = ARG_MAX;
    char *raw = size == sizeof(stack) ? stack : malloc(size);
    if (!raw) return -1;
    size_t length = size;
    int result = -1;
    if (sysctl(mib, 3, raw, &length, NULL, 0) == 0 && length >= sizeof(int) && length < size) {
        result = ds_copy_arguments(raw, length, buffer, capacity);
    }
    if (raw != stack) free(raw);
    return result;
}

static void ds_format_address(const struct in_sockinfo *inet, int family, char *address, size_t size) {
    const struct in6_addr *ipv6 = &inet->insi_laddr.ina_6;
    const struct in_addr *ipv4 = &inet->insi_laddr.ina_46.i46a_addr4;
    // An IPv6 socket bound to a v4-mapped address is stored as IPv4 with only INI_IPV4 set.
    int is_ipv4 = family == AF_INET || IN6_IS_ADDR_V4MAPPED(ipv6)
        || ((inet->insi_vflag & INI_IPV4) && !(inet->insi_vflag & INI_IPV6));
    const char *text;
    if (is_ipv4) {
        text = ipv4->s_addr == INADDR_ANY ? "*" : inet_ntop(AF_INET, ipv4, address, (socklen_t)size);
    } else if (IN6_IS_ADDR_UNSPECIFIED(ipv6)) {
        // A dual-stack wildcard also accepts IPv4, which lsof reports as "*".
        text = (inet->insi_vflag & INI_IPV4) ? "*" : "::";
    } else {
        text = inet_ntop(AF_INET6, ipv6, address, (socklen_t)size);
    }
    if (text != address) strlcpy(address, text ? text : "", size);
}

// lsof reads the same data; a subprocess per scan cost about 160 ms.
int ds_read_tcp_listeners(int32_t pid, DSListener *buffer, int capacity) {
    if (pid <= 0) return -1;
    struct proc_fdinfo stack[256];
    struct proc_fdinfo *descriptors = stack;
    errno = 0;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, stack, sizeof(stack));
    if (bytes <= 0 && errno) return -1;
    if (bytes >= (int)sizeof(stack)) {
        // A full buffer may have cut the table; the size query includes room for open slots.
        int needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (needed <= 0) return -1;
        needed += 64 * (int)sizeof(struct proc_fdinfo);
        descriptors = malloc((size_t)needed);
        if (!descriptors) return -1;
        errno = 0;
        bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, descriptors, needed);
        if (bytes <= 0 && errno) {
            free(descriptors);
            return -1;
        }
    }
    int count = 0;
    for (int index = 0; index < bytes / (int)sizeof(struct proc_fdinfo); index++) {
        if (descriptors[index].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo info;
        if (proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info))
            != (int)sizeof(info)) continue;
        int family = info.psi.soi_family;
        if (info.psi.soi_kind != SOCKINFO_TCP || (family != AF_INET && family != AF_INET6)
            || info.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
        const struct in_sockinfo *inet = &info.psi.soi_proto.pri_tcp.tcpsi_ini;
        if (buffer && count < capacity) {
            buffer[count].port = ntohs((uint16_t)inet->insi_lport);
            ds_format_address(inet, family, buffer[count].address, sizeof(buffer[count].address));
        }
        count++;
    }
    if (descriptors != stack) free(descriptors);
    return count;
}
