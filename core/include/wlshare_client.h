/*
 * The wlshare client core, as the app sees it.
 *
 * Written from the C side, not generated: `tests/header_matches.rs` reads this
 * file and `src/ffi.rs` and fails if any function or struct differs between
 * them, so neither half is checked against itself.
 *
 * Three rules hold everywhere:
 *   - A null client is a no-op, not a crash.
 *   - A pointer handed to a callback is borrowed for that call and no longer.
 *   - A callback runs with a lock held: it must not block and must not call
 *     back into this API.
 */
#ifndef WLSHARE_CLIENT_H
#define WLSHARE_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One connection and the thread running it. */
typedef struct WlshareClient WlshareClient;

#define WLSHARE_STATE_CONNECTING 0
#define WLSHARE_STATE_READY 1
#define WLSHARE_STATE_CLOSED 2

/* The three real buttons of the RFB button mask; the wheel's four come out of
 * wlshare_client_wheel. */
#define WLSHARE_BUTTON_LEFT 1
#define WLSHARE_BUTTON_MIDDLE 2
#define WLSHARE_BUTTON_RIGHT 4

/* Where a session has got to, and what the desktop looks like. */
typedef struct {
    int32_t state;
    uint32_t width;
    uint32_t height;
    double scale;
} WlshareStatus;

/* The framebuffer, as it is for the length of one callback. `pixels` is
 * width * height * 4 bytes of B, G, R, X — MTLPixelFormat.bgra8Unorm exactly —
 * and null before the desktop's size is known. A `generation` the window has
 * not seen is a framebuffer of a new size. */
typedef struct {
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint64_t generation;
    bool damaged;
    uint32_t damage_x;
    uint32_t damage_y;
    uint32_t damage_width;
    uint32_t damage_height;
} WlshareFrame;

/* The pointer's shape, as it is for the length of one callback. `rgba` is
 * premultiplied. `present` false is a pointer that is hidden or has not
 * arrived; `generation` tells the two apart, being zero until the first shape. */
typedef struct {
    const uint8_t *rgba;
    uint64_t generation;
    uint16_t width;
    uint16_t height;
    uint16_t hotspot_x;
    uint16_t hotspot_y;
    bool present;
} WlshareCursor;

typedef void (*WlshareWakeFn)(void *ctx);
typedef void (*WlshareFrameFn)(void *ctx, const WlshareFrame *frame);
typedef void (*WlshareCursorFn)(void *ctx, const WlshareCursor *cursor);

/* Start a session. Never null: a connection that fails does so in the status.
 * An empty password asks for the None security type, any other for RSA-AES. */
WlshareClient *wlshare_client_connect(const char *host, uint16_t port, const char *username, const char *password,
                                      uint16_t surface_width, uint16_t surface_height, double scale);

/* End the session and wait for its thread. The frame callback is cleared
 * first, so nothing calls back into the app after this returns. */
void wlshare_client_close(WlshareClient *client);

void wlshare_client_status(const WlshareClient *client, WlshareStatus *out);

/* Why the session ended, and the desktop's name, NUL-terminated into `out` and
 * truncated to fit. Both return the full length, so a caller given back more
 * than cap - 1 can ask again with room. */
size_t wlshare_client_error(const WlshareClient *client, char *out, size_t cap);
size_t wlshare_client_name(const WlshareClient *client, char *out, size_t cap);

/* Call `wake` from the session's thread whenever there is something new to
 * draw. Null takes the callback off. */
void wlshare_client_on_frame(const WlshareClient *client, WlshareWakeFn wake, void *ctx);

/* Show `visit` the framebuffer and take its damage. */
void wlshare_client_with_frame(const WlshareClient *client, WlshareFrameFn visit, void *ctx);

/* Say the whole framebuffer must be uploaded again. */
void wlshare_client_damage_all(const WlshareClient *client);

/* Show `visit` the pointer's shape. */
void wlshare_client_with_cursor(const WlshareClient *client, WlshareCursorFn visit, void *ctx);

/* The pointer: the RFB button mask, and a position in the window's device
 * pixels. */
void wlshare_client_pointer(const WlshareClient *client, uint8_t buttons, uint16_t x, uint16_t y);

void wlshare_client_key(const WlshareClient *client, bool down, uint32_t keysym);

/* The window's backing store: its size in device pixels and the scale it draws
 * at. The desktop is asked to match once the change settles. */
void wlshare_client_surface(const WlshareClient *client, uint16_t width, uint16_t height, double scale);

/* The wheel notches a scroll comes to, into `out` as button-mask bits, and how
 * many there were. A scroll too small for a notch is kept for the next one. */
size_t wlshare_client_wheel(const WlshareClient *client, double dx, double dy, bool precise, uint8_t *out, size_t cap);

/* The X11 keysym for a key: its macOS virtual key code, and the character it
 * typed as a Unicode scalar — charactersIgnoringModifiers cased by Shift and
 * Caps Lock — or 0 for a key that typed nothing. 0 back is a key not to send. */
uint32_t wlshare_keysym(uint16_t key_code, uint32_t character);

#ifdef __cplusplus
}
#endif

#endif /* WLSHARE_CLIENT_H */
