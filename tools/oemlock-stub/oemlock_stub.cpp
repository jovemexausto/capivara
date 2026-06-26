// oemlock_stub — minimal fake IOemLock/default registrar.
//
// OemLockService.<init>() blocks the system_server main thread in
// ServiceManager.waitForDeclaredService("oemlock") until something is
// registered under "android.hardware.oemlock.IOemLock/default" in
// servicemanager. Cuttlefish's real oemlock-service.remote needs a working
// /dev/hvc10 (host companion) to ever reach AServiceManager_addService(),
// which we don't have. No AIDL method on this interface is invoked before
// boot_completed, so any registered binder — even one that never answers a
// real transaction — satisfies the wait.
//
// AServiceManager_addService / ABinderProcess_* are platform-only NDK
// symbols not exposed in the public NDK stub .so, so they're dlsym'd from
// the on-device libbinder_ndk.so at runtime instead of link-time.

#include <android/binder_ibinder.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdio>

typedef void (*ABinderProcess_setThreadPoolMaxThreadCount_t)(uint32_t);
typedef void (*ABinderProcess_startThreadPool_t)(void);
typedef void (*ABinderProcess_joinThreadPool_t)(void);
typedef binder_status_t (*AServiceManager_addService_t)(AIBinder*, const char*);

static void* onCreate(void* args) { return args; }
static void onDestroy(void*) {}
static binder_status_t onTransact(AIBinder*, transaction_code_t, const AParcel*, AParcel*) {
    return STATUS_UNKNOWN_TRANSACTION;
}

int main() {
    void* lib = dlopen("libbinder_ndk.so", RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "oemlock_stub: dlopen libbinder_ndk.so failed: %s\n", dlerror());
        return 1;
    }

    auto setMax = reinterpret_cast<ABinderProcess_setThreadPoolMaxThreadCount_t>(
        dlsym(lib, "ABinderProcess_setThreadPoolMaxThreadCount"));
    auto startPool = reinterpret_cast<ABinderProcess_startThreadPool_t>(
        dlsym(lib, "ABinderProcess_startThreadPool"));
    auto joinPool = reinterpret_cast<ABinderProcess_joinThreadPool_t>(
        dlsym(lib, "ABinderProcess_joinThreadPool"));
    auto addService = reinterpret_cast<AServiceManager_addService_t>(
        dlsym(lib, "AServiceManager_addService"));

    if (!setMax || !startPool || !joinPool || !addService) {
        fprintf(stderr, "oemlock_stub: missing symbol in libbinder_ndk.so\n");
        return 1;
    }

    setMax(0);

    AIBinder_Class* clazz = AIBinder_Class_define(
        "android.hardware.oemlock.IOemLock", onCreate, onDestroy, onTransact);
    if (!clazz) {
        fprintf(stderr, "oemlock_stub: AIBinder_Class_define failed\n");
        return 1;
    }

    AIBinder* binder = AIBinder_new(clazz, nullptr);
    if (!binder) {
        fprintf(stderr, "oemlock_stub: AIBinder_new failed\n");
        return 1;
    }

    binder_status_t status = addService(binder, "android.hardware.oemlock.IOemLock/default");
    if (status != STATUS_OK) {
        fprintf(stderr, "oemlock_stub: addService failed: %d\n", status);
        return 1;
    }

    fprintf(stderr, "oemlock_stub: registered android.hardware.oemlock.IOemLock/default\n");
    startPool();
    joinPool();
    return 1; // unreachable
}
