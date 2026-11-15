// Root-only exhaustion signal -> unprivileged Stats Widget admission latch.
// No IPC commands, user paths, process control, shell execution or credentials.
// Apple documents LOW_SWAP in xnu/doc/vm/memorystatus_notify.md. Its kqueue
// filter/flag are private ABI, isolated here and checked with EV_RECEIPT so a
// future macOS change fails visibly instead of silently claiming protection.
#include <errno.h>
#include <notify.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define RELAY_NAME "com.ethansk.stats-widget.memory-exhaustion"
#define MEMORYSTATUS_FILTER (-14)
#define PRESSURE_NORMAL 0x1
#define PRESSURE_WARN 0x2
#define PRESSURE_CRITICAL 0x4
#define LOW_SWAP 0x8
#define HEALTHY_SECONDS 120.0

struct recovery_policy {
    bool paused;
    double healthy_since;
    double last_sample;
};

// Only LOW_SWAP enters the emergency state. Unknown pressure and gaps in
// observation break the healthy interval; warning/critical never pause a
// normally running app. The relay is the single owner of this recovery policy.
static bool update_policy(struct recovery_policy *policy, bool exhaustion,
                          int pressure, double now) {
    bool previous = policy->paused;
    if (exhaustion) {
        policy->paused = true;
        policy->healthy_since = 0;
    }
    if (policy->paused) {
        if (pressure != PRESSURE_NORMAL || exhaustion ||
            (policy->last_sample > 0 && now - policy->last_sample > 30)) {
            policy->healthy_since = 0;
        } else if (policy->healthy_since == 0) {
            policy->healthy_since = now;
        } else if (now - policy->healthy_since >= HEALTHY_SECONDS) {
            policy->paused = false;
            policy->healthy_since = 0;
        }
    }
    policy->last_sample = now;
    return previous != policy->paused;
}

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int current_pressure(void) {
    int pressure = 0;
    size_t size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) != 0)
        return 0; // Unknown is never evidence of recovery.
    return pressure;
}

static int register_exhaustion_filter(void) {
    int fd = kqueue();
    if (fd < 0) return -1;
    struct kevent change, receipt;
    EV_SET(&change, 0, MEMORYSTATUS_FILTER, EV_ADD | EV_CLEAR | EV_RECEIPT,
           PRESSURE_NORMAL | PRESSURE_WARN | PRESSURE_CRITICAL | LOW_SWAP, 0, NULL);
    int count = kevent(fd, &change, 1, &receipt, 1, NULL);
    if (count != 1 || !(receipt.flags & EV_ERROR) || receipt.data != 0) {
        int error = count == 1 ? (int)receipt.data : errno;
        close(fd);
        errno = error ? error : EIO;
        return -1;
    }
    return fd;
}

static int publish_state(int token, bool paused) {
    if (notify_set_state(token, paused ? 1 : 0) != NOTIFY_STATUS_OK ||
        notify_post(RELAY_NAME) != NOTIFY_STATUS_OK) return -1;
    fprintf(stderr, "memory-relief: %s\n", paused ? "exhaustion: paused" : "recovered: allowed");
    return 0;
}

#ifndef MEMORY_RELAY_TEST
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("Stats Widget memory-pressure relay 1");
        return 0;
    }
    bool probe = argc == 2 && strcmp(argv[1], "--probe") == 0;
    bool clear = argc == 2 && strcmp(argv[1], "--clear") == 0;
    if (!(argc == 1 || probe || clear)) return 64;
    if (geteuid() != 0) {
        fputs("memory-relief: LOW_SWAP requires root\n", stderr);
        return 77;
    }
    int token = 0;
    if (notify_register_check(RELAY_NAME, &token) != NOTIFY_STATUS_OK) return 1;
    if (clear) return publish_state(token, false) == 0 ? 0 : 1;
    int fd = register_exhaustion_filter();
    if (fd < 0) { perror("memory-relief: register LOW_SWAP"); return 1; }
    if (probe) { puts("LOW_SWAP registered successfully"); close(fd); return 0; }
    uint64_t previous_state = 0;
    if (notify_get_state(token, &previous_state) != NOTIFY_STATUS_OK) return 1;
    struct recovery_policy policy = {.paused = previous_state != 0};
    fputs("memory-relief: LOW_SWAP listener ready\n", stderr);
    for (;;) {
        struct kevent event;
        struct timespec timeout = {.tv_sec = 10};
        int count = kevent(fd, NULL, 0, &event, 1, policy.paused ? &timeout : NULL);
        if (count < 0) { if (errno == EINTR) continue; perror("kevent"); return 1; }
        if (count == 1 && (event.flags & EV_ERROR)) return 1;
        bool exhaustion = count == 1 && (event.fflags & LOW_SWAP) != 0;
        int pressure = current_pressure();
        // Preserve a short warn/critical event even when the sampled pressure
        // has already returned to normal by the time this process is scheduled.
        if (count == 1 && (event.fflags & (PRESSURE_WARN | PRESSURE_CRITICAL))) pressure = 0;
        if (update_policy(&policy, exhaustion, pressure, monotonic_seconds())) {
            if (publish_state(token, policy.paused) != 0) return 1;
        }
    }
}
#endif
