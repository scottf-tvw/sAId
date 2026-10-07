// macOS atomic no-clobber rename. Never emulate with a check followed by rename/mv.
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: rename-exclusive SOURCE DESTINATION\n");
        return 64;
    }
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
        fprintf(stderr, "sAId: exclusive rename %s -> %s failed: %s\n",
                argv[1], argv[2], strerror(errno));
        return 1;
    }
    return 0;
}
