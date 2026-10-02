/*
 * ShowcaseRadio.c - 5 GHz hotspot channels for CarPlay sessions
 *
 * Loaded into wifid only (see ShowcaseRadio.plist). On the HSIC-era receivers
 * (iOS 10 and 12) wifid picks the Personal Hotspot channel from a fixed list
 * of 2.4 GHz candidates, {1, 6, 11}, stored as three 32-bit integers in its
 * writable __DATA segment. A crowded 2.4 GHz channel is what makes those
 * receivers stall: on an iPad4,2 about a quarter of received frames arrived
 * corrupted and 8% of its own frames never reached the iPhone.
 *
 * While Showcase signals a CarPlay session, the candidates become the
 * non-DFS 5 GHz channels {36, 40, 44}; afterwards the stock list returns, so
 * ordinary Personal Hotspot use is unchanged. The list is found at runtime as
 * the only {1, 6, 11} triple in wifid's __DATA segment. If it is missing or
 * not unique (newer iOS selects channels elsewhere), nothing is changed.
 */

#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#define SHOWCASE_RADIO_NOTIFICATION "com.rostane.showcase.softap-5ghz"
#define SHOWCASE_RADIO_STATUS       "/tmp/showcase_radio_status"

static uint32_t *g_table = NULL;
static const uint32_t kStockChannels[3] = { 1, 6, 11 };
static const uint32_t kFiveGHzChannels[3] = { 36, 40, 44 };

/* "<pid> <state>": Showcase compares the pid with the running wifid to know
 * that the current wifid instance loaded this library. */
static void write_status(const char *state) {
    FILE *file = fopen(SHOWCASE_RADIO_STATUS, "w");
    if (file) {
        fprintf(file, "%d %s\n", getpid(), state);
        fclose(file);
    }
    syslog(LOG_NOTICE, "ShowcaseRadio: %s", state);
}

static uint32_t *find_channel_list(void) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    unsigned long size = 0;
    uint8_t *data = getsegmentdata(header, "__DATA", &size);
    if (!data || size < sizeof(kStockChannels)) return NULL;
    uint32_t *found = NULL;
    int matches = 0;
    for (unsigned long offset = 0; offset + sizeof(kStockChannels) <= size;
         offset += sizeof(uint32_t)) {
        if (memcmp(data + offset, kStockChannels, sizeof(kStockChannels)) == 0) {
            found = (uint32_t *)(data + offset);
            matches++;
        }
    }
    return matches == 1 ? found : NULL;
}

static void apply_state(uint64_t fiveGHz) {
    if (!g_table) return;
    memcpy(g_table, fiveGHz ? kFiveGHzChannels : kStockChannels,
           sizeof(kStockChannels));
    write_status(fiveGHz ? "5ghz" : "stock");
}

__attribute__((constructor))
static void showcase_radio_init(void) {
    g_table = find_channel_list();
    if (!g_table) {
        write_status("unsupported");
        return;
    }
    int token = 0;
    if (notify_register_dispatch(SHOWCASE_RADIO_NOTIFICATION, &token,
            dispatch_get_main_queue(), ^(int t) {
                uint64_t state = 0;
                notify_get_state(t, &state);
                apply_state(state);
            }) != NOTIFY_STATUS_OK) {
        write_status("unsupported");
        return;
    }
    /* Start from the stock list. Showcase posts its state again once it sees
     * that this wifid instance has loaded the library. */
    apply_state(0);
}
