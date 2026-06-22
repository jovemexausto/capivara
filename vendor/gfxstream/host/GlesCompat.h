// Case-insensitive alias: native_sub_window.h includes "GlesCompat.h"
// but the file is named gles_compat.h. On case-sensitive filesystems
// (APFS default on macOS) this causes a fatal error.
#include "gles_compat.h"
