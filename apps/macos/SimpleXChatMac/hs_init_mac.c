//
//  hs_init_mac.c
//  SimpleXChat (macOS)
//

#include "hs_init_mac.h"

extern void hs_init_with_rtsopts(int * argc, char **argv[]);

void haskell_init_mac(void) {
    int argc = 6;
    char *argv[] = {
        "simplex",
        "+RTS", // requires `hs_init_with_rtsopts`
        "-A64m", // chunk size for new allocations
        "-H64m", // initial heap size
        "-xn", // non-moving GC
        // The RTS handler swallows SIGTERM, so the app could not be quit with `kill`
        // or at logout. The app handles SIGTERM itself and shuts the chat down cleanly.
        "--install-signal-handlers=no",
        0
    };
    char **pargv = argv;
    hs_init_with_rtsopts(&argc, &pargv);
}
