#define _GNU_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

static int kmsg_fd = -1;
static __thread int in_log;

static void init_klog(void) {
    if (kmsg_fd >= 0) return;
    kmsg_fd = (int)syscall(SYS_openat, AT_FDCWD, "/dev/kmsg", O_WRONLY | O_CLOEXEC, 0);
    if (kmsg_fd < 0) {
        kmsg_fd = (int)syscall(SYS_openat, AT_FDCWD, "/dev/console", O_WRONLY | O_CLOEXEC, 0);
    }
}

static void klog(const char* op, const char* path) {
    if (in_log) return;
    in_log = 1;
    init_klog();
    if (kmsg_fd >= 0) {
        char buf[512];
        int n = snprintf(buf, sizeof(buf), "<6>CAPY_TRACE %s %s\n", op, path ? path : "(null)");
        if (n > 0) {
            syscall(SYS_write, kmsg_fd, buf, (size_t)n);
        }
    }
    in_log = 0;
}

static void* resolve_sym(const char* name) {
    void* sym = dlsym(RTLD_NEXT, name);
    return sym;
}

int open(const char* path, int flags, ...) {
    static int (*real_open)(const char*, int, ...) = NULL;
    if (!real_open) real_open = (int (*)(const char*, int, ...))resolve_sym("open");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    klog("open", path);
    if (flags & O_CREAT) {
        return real_open(path, flags, mode);
    }
    return real_open(path, flags);
}

int openat(int dirfd, const char* path, int flags, ...) {
    static int (*real_openat)(int, const char*, int, ...) = NULL;
    if (!real_openat) real_openat = (int (*)(int, const char*, int, ...))resolve_sym("openat");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    klog("openat", path);
    if (flags & O_CREAT) {
        return real_openat(dirfd, path, flags, mode);
    }
    return real_openat(dirfd, path, flags);
}

#if defined(__ANDROID__)
int mount(const char* src, const char* target, const char* fstype, unsigned long flags, const void* data) {
    static int (*real_mount)(const char*, const char*, const char*, unsigned long, const void*) = NULL;
    if (!real_mount) real_mount = (int (*)(const char*, const char*, const char*, unsigned long, const void*))resolve_sym("mount");

    (void)src;
    (void)fstype;
    (void)flags;
    (void)data;
    klog("mount", target);
    return real_mount(src, target, fstype, flags, data);
}
#endif
