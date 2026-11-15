// Tests the optional relay policy with synthetic pressure events only.
// Compile and run without root; it never posts the live exhaustion signal.
#define MEMORY_RELAY_TEST 1
#include "memory-pressure-relay.c"
#include <assert.h>

int main(void) {
    struct recovery_policy p = {0};
    update_policy(&p, false, PRESSURE_WARN, 10);
    update_policy(&p, false, PRESSURE_CRITICAL, 20);
    assert(!p.paused); // Swapping/pressure is explicitly allowed.
    assert(update_policy(&p, true, PRESSURE_NORMAL, 30) && p.paused);
    for (int t = 40; t < 160; t += 10) update_policy(&p, false, PRESSURE_NORMAL, t);
    assert(p.paused);
    assert(update_policy(&p, false, PRESSURE_NORMAL, 160) && !p.paused);

    update_policy(&p, true, PRESSURE_NORMAL, 200);
    for (int t = 210; t <= 300; t += 10) update_policy(&p, false, PRESSURE_NORMAL, t);
    update_policy(&p, false, PRESSURE_WARN, 310);
    update_policy(&p, false, PRESSURE_NORMAL, 320);
    assert(p.healthy_since == 320 && p.paused);
    update_policy(&p, true, PRESSURE_NORMAL, 330);
    assert(p.healthy_since == 0 && p.paused);
    update_policy(&p, false, 0, 340); // Failed sysctl cannot resume.
    update_policy(&p, false, PRESSURE_NORMAL, 350);
    update_policy(&p, false, PRESSURE_NORMAL, 500); // Sleep/unknown gap resets.
    assert(p.healthy_since == 0 && p.paused);
    for (int t = 510; t <= 630; t += 10) update_policy(&p, false, PRESSURE_NORMAL, t);
    assert(!p.paused);
    puts("memory relay policy: passed");
}
