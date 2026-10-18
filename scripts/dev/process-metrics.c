// Build: clang scripts/dev/process-metrics.c -o /tmp/island-process-metrics
// Usage: /tmp/island-process-metrics <pid> [seconds]
// Reads kernel process counters twice; it never signals or modifies the target.
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fprintf(stderr, "usage: %s pid [seconds]\n", argv[0]); return 2; }
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end || pid <= 0) return 2;
    long seconds = argc == 3 ? strtol(argv[2], &end, 10) : 12;
    if ((argc == 3 && *end) || seconds < 1 || seconds > 60) return 2;
    struct rusage_info_v4 before = {0}, after = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&before)) { perror("proc_pid_rusage"); return 1; }
    struct timespec delay = {seconds, 0};
    while (nanosleep(&delay, &delay) != 0) {}
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&after)) { perror("proc_pid_rusage"); return 1; }
    printf("{\"pid\":%ld,\"seconds\":%ld,\"userTimeDeltaRaw\":%llu,\"systemTimeDeltaRaw\":%llu,\"interruptWakeupsDelta\":%llu,\"packageIdleWakeupsDelta\":%llu,\"residentBytesBefore\":%llu,\"residentBytesAfter\":%llu,\"physicalFootprintBytes\":%llu}\n",
        pid, seconds, (unsigned long long)(after.ri_user_time-before.ri_user_time),
        (unsigned long long)(after.ri_system_time-before.ri_system_time),
        (unsigned long long)(after.ri_interrupt_wkups-before.ri_interrupt_wkups),
        (unsigned long long)(after.ri_pkg_idle_wkups-before.ri_pkg_idle_wkups),
        (unsigned long long)before.ri_resident_size, (unsigned long long)after.ri_resident_size,
        (unsigned long long)after.ri_phys_footprint);
    return 0;
}
