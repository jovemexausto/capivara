# Patch inventory — vendor/gfxstream & vendor/libkrun

Last refined 2026-06-23. Baseline for comparison: `https://github.com/jovemexausto/{gfxstream,libkrun}`
`main`, cloned at `/tmp/capivara-upstreams/{gfxstream,libkrun}` (ephemeral, not committed here —
re-clone to reproduce/re-extend any of this).

Goal: stop treating `vendor/` as the only record of our changes. Every real fix exists as a clean,
reviewable commit on a fork branch, and every fork branch is mirrored here as a flat, sequentially
numbered `git format-patch` series — so nothing depends on the `/tmp` clone surviving. Both series below
apply cleanly with `git am patches/<repo>/*.patch` against the respective fork's `main`, and both have
been fully `cargo check`/`meson`+`ninja`-validated commit by commit inside the fork clones.

## libkrun — `capivara/macos-gfxstream-vulkan` (9 commits)

| # | Commit | What | Why it's there |
|---|---|---|---|
| 0001 | `deps: migrate vm-memory 0.17 -> 0.18.0` | Bumps `vm-memory` to 0.18.0 across all 6 workspace `Cargo.toml`s; adds `GuestMemoryBackend` import to 7 files where default trait methods moved; enables vm-memory's `rawfd` feature (needed for `OwnedFd`'s `WriteVolatile`/`ReadVolatile`, lost because every `Cargo.toml` sets `default-features = false`). | Real, independently-useful dependency upgrade. The scaffolding (0003) needs `GuestMemoryBackend`, which doesn't exist in 0.17 — put first so everything after it builds on a 0.18 base. |
| 0002 | `rutabaga_gfx/gfxstream: fix macOS+gfxstream build (pre-existing, unrelated to our work)` | `extern "C"` → `unsafe extern "C"` (edition 2024); adds missing `map_ptr: None` to 2 of 3 `RutabagaResource` struct literals; 2 lint-suggested cast fixes. | Fork `main`, zero patches, does not compile with `--features gfxstream` on macOS. No CI job exercises this combination. |
| 0003 | `virtio/gpu: add gfxstream Vulkan-only integration scaffolding for macOS` | `create_rutabaga_gfxstream`, `new_gfxstream`, macOS `Worker` fields, display backend wiring, `resource_map_blob` accepting `RUTABAGA_MEM_HANDLE_TYPE_SHM` in addition to `APPLE`. ~150 lines. | The macOS/HVF gfxstream integration. **Supersedes** the old `capivara/macos-blob-mapping` PR branch — that branch's 2 commits only ever touched the SHM check in isolation, a strict subset of this commit. Close/replace that PR with this branch. |
| 0004 | `devices: declare gpu-gfxstream feature` | Adds `gpu-gfxstream = ["gpu", "rutabaga_gfx/gfxstream"]` to `src/devices/Cargo.toml`. | Feature didn't exist upstream; needed by the `#[cfg(...)]` gates in 0003. |
| 0005 | `rutabaga_gfx/gfxstream: compute map_ptr for HOST3D blobs on macOS` | `mmap`s the SHM fd in `create_blob` so ASG/ranchu Vulkan gets a usable pointer. | **The single most important fix in this series** — first thing that made gfxstream/ASG work on macOS/HVF at all. |
| 0006 | `virtio/gpu: wire the real map_sender into new_gfxstream on macOS` | Connects the real `map_sender` channel into `new_gfxstream` instead of the scaffolding's placeholder. | |
| 0007 | `virtio/gpu: defer gfxstream TransferFromHost3d to break dispatcher deadlock` | One-shot helper thread defers blocking `TransferFromHost3d` reads off the single in-order dispatcher thread. | Fixes the dispatcher deadlock that blocked full Android boot. |
| 0008 | `virtio/gpu: document that the GLES shader-compile blocker is now fixed` | Comment-only update in `create_rutabaga_gfxstream`'s `use_gles(false)` rationale, pointing at the real fix (gfxstream 0006-0008) instead of the disproven ANGLE-over-Metal hypothesis. `use_gles` still defaults to `false` pending a real Android-guest boot test (only tested against a minimal `/bin/sh` root so far, via a temporary diagnostic edit, reverted). | Keeps the comment from misleading whoever reads it next. |
| 0009 | `virtio/gpu: flip use_gles(true) to the validated default` | Flips `set_use_gles(false)` to `true`, rewrites the rationale comment. | A real Android guest boot (composer3/RanchuHwc + SurfaceFlinger, plus `crates/capy`'s `gralloc=minigbm`) confirmed `render_control.cpp`/`renderControl_dec` only compile into `libgfxstream_backend` when `use_gles` is on — a Vulkan-only build leaves RanchuHwc's legacy `pipe:opengles` host-extension query unanswered forever, hanging composer until the Watchdog kills `system_server`. SurfaceFlinger ran stable for 800s+ with this on. |

**Validated**: `cargo check` clean for `libkrun`, `krun-vmm`, `krun-arch`, `krun-kernel`, `krun-smbios`,
`krun-devices --features gpu-gfxstream`, and `krun-rutabaga-gfx --features gfxstream`. The only failure
anywhere in the tree is `krun-init-blob`'s build script (musl cross-link, macOS host linker) — confirmed
pre-existing on fork `main` with zero patches applied.

## gfxstream — `capivara/macos-gfxstream-build` (10 commits)

Built from fork `main`, starting with the 2 commits that were the old, narrower `capivara/macos-shm-fix`
PR branch (kept — they're real and unrelated to the rest), then 3 new commits hand-extracted this pass:

| # | Commit | What | Why it's there |
|---|---|---|---|
| 0001 | `common: fix macOS shared memory names` | POSIX SHM naming for `shm_open` on macOS (leading `/`, etc.) in `SharedMemory_posix.cpp`. | Pre-existing PR content, unchanged. |
| 0002 | `host: propagate createBlob failures` | `stream_renderer_create_blob` now returns the real error code instead of always `0`. | Pre-existing PR content, unchanged. |
| 0003 | `host: add Metal-backed Vulkan-only build support for macOS` | New `native_sub_window_metal.mm` (CAMetalLayer-based native window, replacing the deprecated NSOpenGL/cocoa path), the darwin framework/link-args block in `meson.build`, `GFXSTREAM_ENABLE_HOST_GLES` guards in `frame_buffer.cpp`/`color_buffer.cpp`/`gles_compat.h`, plus stub backends (`iostream`, `snapshot`) for subsystems not needed on this platform. | **This is what first made gfxstream buildable for macOS/HVF at all** — predates the libkrun session work, was never extracted as its own commit before. Found by diffing the vendored tree (with the 2 patches below reverse-applied) against the old `macos-shm-fix` branch: `host/native_sub_window_metal.mm` plain doesn't exist anywhere in the fork's history before this. |
| 0004 | `host: fix macOS build for decoders=vulkan,gles,composer` | 7 real bugs blocking the GLES/composer decoders on top of 0003's Vulkan-only base: missing brace, 3 duplicate function defs, missing `getConfigs` wrapper, missing `objcpp_args` (so `.mm` files never saw `GFXSTREAM_ENABLE_HOST_GLES`), conditional macOS frameworks for GLES. | Session work. |
| 0005 | `host/gl/texture_draw: use GLSL ES 3.00 pragmas under the GLES decoder` | Adds GLSL ES 3.00 core-profile shader variants for the blit shaders. | Session work. Superseded as the "why GLES doesn't work" diagnosis by 0006/0007 below — the real blocker was never the `#version` pragma or ANGLE-over-Metal (that hypothesis was investigated and disproved with direct Metal/OpenGL.framework compile tests); it was `USE_ANGLE_SHADER_PARSER` never being wired into the Meson build, and the ANGLE shader translator never being vendored at all. See `capivara-gles-shader-translator-missing` memory for the full diagnosis trail. |
| 0006 | `third_party/angle: fix macOS coverage gaps in Bazel build glue` | `angle_common`/`angle_glslang`'s `select()`s on `@platforms//os` only had linux/windows branches (one had no default, the other silently always picked the linux source unconditionally). Added macOS branches + `//conditions:default` fallbacks. | **Generic Bazel+macOS bug, not Capivara-specific — good upstream candidate.** Verified with a full `bazel clean --expunge` + rebuild of `@angle//:translator` using only this tracked `BUILD.angle.bazel`, no local ANGLE checkout needed (`git_repository()` fetches its own copy at the pinned commit `8b39631d6ab5a2efa21629c6fa94a80381720950`). |
| 0007 | `host/gl: implement the missing angle_shader_translator C ABI` | New `ShaderTranslator.{h,cpp}` — the flat C ABI (`ST_*`) that `angle_shader_parser.cpp` `dlopen()`s as `libshadertranslator.{dylib,so,dll}` at runtime, wrapping ANGLE's real `sh::*` API. This file never existed anywhere (not in gfxstream, not in vanilla ANGLE, not in this fork's history) — `CMakeLists.txt` literally says the caller is responsible for providing it, and no caller ever did. Built as a standalone `cc_shared_library` via Bazel (`//host/gl/glestranslator/gles_v2:shadertranslator`), copied next to `libgfxstream_backend` by a Meson `custom_target` gated on `decoders=gles`. | Session work. Initial version had a real bug (see 0008) found by the boot test that 0008 documents — kept as its own commit since it's the structural piece (the ABI shape, the Bazel/Meson wiring), not the bugfix. |
| 0008 | `third_party/angle, host/gl: fix ANGLE_ENABLE_GLSL gap, null nameHashingMap crash` | Two real bugs found by an actual boot test with `use_gles(true)`: (a) the `translator` Bazel target never defined `ANGLE_ENABLE_GLSL` (ANGLE's `CodeGen.cpp::ConstructCompiler()` gates every output backend behind its own `#ifdef`, and GLSL's was never set — upstream gfxstream's Linux path only ever needs Vulkan/SPIRV output, so this was never exercised before), so `sh::ConstructCompiler()` unconditionally returned null for every `ST_GLSL_*_OUTPUT` gfxstream's macOS host path requests. Added the define plus the ~15 missing `glsl/*.cpp`/`tree_ops/glsl/*.cpp` (incl. `apple/` subdir) source files that backend actually needs. (b) `ShaderTranslator.cpp`'s failure fallback path left `nameHashingMap` null, but the caller dereferences it unconditionally — caused a real `SIGSEGV` during the same boot test, before (a) was fixed. | **This is the actual root-cause fix for the multi-session GLES shader-compile blocker.** Confirmed nothing to do with Apple's ANGLE-over-Metal runtime (disproven in an earlier session) or `#version` pragmas (0005's old hypothesis) — it was always a missing preprocessor define in our own Bazel glue. |
| 0009 | `host: close the ASG host/guest lost-wakeup race in RingStream::readRaw` | After publishing `ASG_HOST_STATE_NEED_NOTIFY`, issues a `StoreLoad` barrier and re-checks both rings before blocking on `onUnavailableRead()`. | Real race: the guest only pings when it observes `host_state == NEED_NOTIFY`; if it wrote a request and sampled `host_state` while still `CAN_CONSUME` (just before this store), it never pings, and the host's blocking receive sleeps forever on data already in the ring. Caused intermittent ~16s stalls on SurfaceFlinger/HWC's first host round-trip, tripping the Watchdog. Also ignores meson `*.stamp` build artifacts. |
| 0010 | `host: invoke the completion callback when an export-sync fence isn't found` | `FrameBuffer::Impl::asyncWaitForGpuWithCb` now calls `cb()` before returning when `EmulatedEglFenceSync::getFromHandle` misses, instead of just logging and dropping it. | Same bug shape as 0009, different channel: `destroyWhenSignaled=true` fences self-remove from the registry as soon as they signal (via the render-control/pipe channel), but `GFXSTREAM_CREATE_EXPORT_SYNC` (a separate virtio-gpu command channel, no ordering guarantee) can arrive after that — "not found" then means "already done", not an error. The dropped callback left RanchuHwc's virtio-gpu timeline task (and the guest's `dma_fence_default_wait` backing a `presentDisplay` call) blocked forever. Confirmed live: a single "fence sync 0x... not found" log line at the exact moment `RanchuHwc`'s binder thread hung in `DrmVirtGpuResource::wait()`. |
**Validated**: `meson setup -Ddecoders=vulkan --buildtype=debug && ninja` clean after 0003; `meson setup
-Ddecoders=vulkan,gles,composer --buildtype=debug && ninja` clean after 0004 and 0005, run directly inside
the fork clone after each commit. 0006/0007: full `decoders=vulkan,gles,composer` meson+ninja build clean
end to end, plus a standalone `dlopen`/`dlsym`/call test of the resulting `libshadertranslator.dylib`
returning success. **0008: validated by a real boot** (`scripts/run-capy.sh` with `use_gles(true)`,
temporarily) — `ConstructCompiler` now returns valid handles for both vertex and fragment stages of
gfxstream's internal blit shader, and the renderer proceeds past shader compilation with no crash
(previously: `SIGABRT` from a `GFXSTREAM_FATAL` "Could not compile shader" log, or `SIGSEGV` before that).
**0009: validated by a real boot** — `SurfaceFlinger` stable for 800s+ continuous boot (combined
with libkrun 0009 and `crates/capy`'s `gralloc=minigbm`), zero crashes, where the unfixed race
previously caused intermittent ~16s stalls.
**0010: validated by a real boot** — with the `oemlock`/`frp` boot blockers also worked around
(see README.md "Estado atual"), the exact "fence sync 0x... not found" hang that previously wedged
`RanchuHwc`'s `presentDisplay` forever stopped recurring, and `system_server` survived roughly 10x
longer (~700s vs. the prior ~65s Watchdog-kill ceiling) before hitting an unrelated, further-along
blocker (`getCompositionColorSpaces`, not yet root-caused).

0001-0005 carry the same `Signed-off-by: Marcus Figueiredo <figueiredo@protonmail.com>` trailer as the
2 pre-existing ones, at the repo owner's explicit instruction. 0006-0008 don't have that trailer yet —
add it before pushing if the same convention should apply.

## kernel — GKI virtio-tpm (no fork branch — different ecosystem)

Unlike libkrun/gfxstream, the Android GKI kernel (`kernel/common`) isn't a single git repo we can
fork — it's a multi-repo `repo`-tool manifest spanning dozens of AOSP projects. There's no
"submodule" or "fork branch" equivalent here. Instead, see `patches/kernel/README.md` for:

- One subdirectory per Android version (`android16/`, with `android14/`/`android15/` to follow —
  see "Como adicionar uma nova versão" in that README), each with:
  - `pinned-manifest.xml` — a revision-locked `repo manifest` snapshot (exact SHA per
    sub-project), replacing a floating `-b common-android<N>-<kv>` branch reference.
  - `0001-add-tpm-virtio-driver.patch` — a real unified diff (`git apply -p1`) for the
    `tpm_virtio` driver wiring, replacing line-anchored `sed -i` edits.
- `capivara_gki.config` — a Kconfig fragment (shared across versions), merged via the kernel's own
  `scripts/kconfig/merge_config.sh`, replacing more `sed -i` deletions/insertions on
  `gki_defconfig`.
- One orchestrating script, `scripts/kernel/build-gki.sh <android-version>` — selects the version
  subdirectory and runs the whole pipeline. Replaced 3 separate scripts across 3 directories that
  existed for one linear, never-independently-reused pipeline.

This was a direct response to discovering the old `sed`-based approach had already silently
stopped doing some of what it was meant to do (see `patches/kernel/README.md` for specifics) —
the floating branch had drifted enough that several of the script's `sed` deletions were already
no-ops against current upstream.

## Recommended next steps

1. Push `capivara/macos-gfxstream-vulkan` (libkrun) and `capivara/macos-gfxstream-build` (gfxstream) to
   their forks. **Not done — needs explicit go-ahead, this is a push to a remote.**
2. Open/update PRs referencing that they supersede `capivara/macos-blob-mapping` (libkrun) and the old,
   narrower `capivara/macos-shm-fix` (gfxstream) respectively.
3. Decide whether the ANGLE-over-Metal GLES shader-compile blocker (gfxstream 0005's note) is worth
   continuing to chase, or whether the Vulkan-only path is the stable target going forward.

## Not yet inventoried — needs its own pass

Real, load-bearing code, not yet ported anywhere, no patch series exists for any of these:

- `vendor/libkrun/src/devices/src/virtio/tpm/` — an entire custom virtio-tpm device, not in upstream
  `main` at all. Unrelated to gfxstream/boot work; needs its own investigation into origin/purpose.
- `vendor/libkrun/Cargo.toml.upstream` and friends (`examples/Cargo.toml.upstream`,
  `krun-sys/Cargo.toml.upstream`, `rutabaga_gfx/ffi/Cargo.toml.upstream`, `tests/Cargo.toml.upstream`,
  `Cargo.lock.upstream`) — backups left behind when local `Cargo.toml`s were substituted for the
  monorepo's build layout. Local glue, not upstream material.
- `vendor/libkrun/build-sp2a-macos.sh`, `libkrun.pc`, `linux-sysroot/` — local build glue.
- `libkrun/tests/test_cases/*.rs` and `libkrun/examples/*.c` diffs are **mostly upstream API drift**
  (confirmed on `examples/boot_efi.c`: upstream renamed/added `krun_init_log`,
  `krun_add_virtio_console_default`, `krun_add_disk` since our vendoring point), not our contributions.
  Don't try to "fix" these as if they were ours.
- `crates/capy/src/main.rs` (`androidboot.vsock_lights_port=6800`, `androidboot.hardware.gralloc=
  minigbm`, MMIO transport cmdline, etc.) is Capivara-specific glue, doesn't belong in either fork.
- `tools/oemlock-stub/` — same category, one level further: not even cmdline glue, but a whole
  binary Capivara has to ship because we don't run a Cuttlefish host companion (`cvd`). Validated
  workaround for the `OemLockService` boot blocker (see its own README), not yet wired into any
  boot path automatically.
- `crates/capy/src/soc.rs`'s `DiskRole::Frp` (and the matching `--disk frp=<img>`/`androidboot.
  partition_map` wiring in `main.rs`) is also Capivara-specific glue, not upstream material — it
  teaches our own boot-contract builder about a partition role Cuttlefish's real disk layout
  already has but our minimal test images didn't. The device-node permission fix it still needs
  (`/dev/block/vdN` for `frp` lands as `root:root 0600` instead of `root:system 0660`, and `vold`
  treats it as a delayed-scan removable disk instead of a fixed first-stage-init partition) is
  validated only via manual `adb shell`, same not-yet-automated status as `tools/oemlock-stub/`.
