# Patch inventory — vendor/gfxstream & vendor/libkrun

Last refined 2026-06-23. Baseline for comparison: `https://github.com/jovemexausto/{gfxstream,libkrun}`
`main`, cloned at `/tmp/capivara-upstreams/{gfxstream,libkrun}` (ephemeral, not committed here —
re-clone to reproduce/re-extend any of this).

Goal: stop treating `vendor/` as the only record of our changes. Every real fix exists as a clean,
reviewable commit on a fork branch, and every fork branch is mirrored here as a flat, sequentially
numbered `git format-patch` series — so nothing depends on the `/tmp` clone surviving. Both series below
apply cleanly with `git am patches/<repo>/*.patch` against the respective fork's `main`, and both have
been fully `cargo check`/`meson`+`ninja`-validated commit by commit inside the fork clones.

## libkrun — `capivara/macos-gfxstream-vulkan` (7 commits)

| # | Commit | What | Why it's there |
|---|---|---|---|
| 0001 | `deps: migrate vm-memory 0.17 -> 0.18.0` | Bumps `vm-memory` to 0.18.0 across all 6 workspace `Cargo.toml`s; adds `GuestMemoryBackend` import to 7 files where default trait methods moved; enables vm-memory's `rawfd` feature (needed for `OwnedFd`'s `WriteVolatile`/`ReadVolatile`, lost because every `Cargo.toml` sets `default-features = false`). | Real, independently-useful dependency upgrade. The scaffolding (0003) needs `GuestMemoryBackend`, which doesn't exist in 0.17 — put first so everything after it builds on a 0.18 base. |
| 0002 | `rutabaga_gfx/gfxstream: fix macOS+gfxstream build (pre-existing, unrelated to our work)` | `extern "C"` → `unsafe extern "C"` (edition 2024); adds missing `map_ptr: None` to 2 of 3 `RutabagaResource` struct literals; 2 lint-suggested cast fixes. | Fork `main`, zero patches, does not compile with `--features gfxstream` on macOS. No CI job exercises this combination. |
| 0003 | `virtio/gpu: add gfxstream Vulkan-only integration scaffolding for macOS` | `create_rutabaga_gfxstream`, `new_gfxstream`, macOS `Worker` fields, display backend wiring, `resource_map_blob` accepting `RUTABAGA_MEM_HANDLE_TYPE_SHM` in addition to `APPLE`. ~150 lines. | The macOS/HVF gfxstream integration. **Supersedes** the old `capivara/macos-blob-mapping` PR branch — that branch's 2 commits only ever touched the SHM check in isolation, a strict subset of this commit. Close/replace that PR with this branch. |
| 0004 | `devices: declare gpu-gfxstream feature` | Adds `gpu-gfxstream = ["gpu", "rutabaga_gfx/gfxstream"]` to `src/devices/Cargo.toml`. | Feature didn't exist upstream; needed by the `#[cfg(...)]` gates in 0003. |
| 0005 | `rutabaga_gfx/gfxstream: compute map_ptr for HOST3D blobs on macOS` | `mmap`s the SHM fd in `create_blob` so ASG/ranchu Vulkan gets a usable pointer. | **The single most important fix in this series** — first thing that made gfxstream/ASG work on macOS/HVF at all. |
| 0006 | `virtio/gpu: wire the real map_sender into new_gfxstream on macOS` | Connects the real `map_sender` channel into `new_gfxstream` instead of the scaffolding's placeholder. | |
| 0007 | `virtio/gpu: defer gfxstream TransferFromHost3d to break dispatcher deadlock` | One-shot helper thread defers blocking `TransferFromHost3d` reads off the single in-order dispatcher thread. | Fixes the dispatcher deadlock that blocked full Android boot. |

**Validated**: `cargo check` clean for `libkrun`, `krun-vmm`, `krun-arch`, `krun-kernel`, `krun-smbios`,
`krun-devices --features gpu-gfxstream`, and `krun-rutabaga-gfx --features gfxstream`. The only failure
anywhere in the tree is `krun-init-blob`'s build script (musl cross-link, macOS host linker) — confirmed
pre-existing on fork `main` with zero patches applied.

## gfxstream — `capivara/macos-gfxstream-build` (5 commits)

Built from fork `main`, starting with the 2 commits that were the old, narrower `capivara/macos-shm-fix`
PR branch (kept — they're real and unrelated to the rest), then 3 new commits hand-extracted this pass:

| # | Commit | What | Why it's there |
|---|---|---|---|
| 0001 | `common: fix macOS shared memory names` | POSIX SHM naming for `shm_open` on macOS (leading `/`, etc.) in `SharedMemory_posix.cpp`. | Pre-existing PR content, unchanged. |
| 0002 | `host: propagate createBlob failures` | `stream_renderer_create_blob` now returns the real error code instead of always `0`. | Pre-existing PR content, unchanged. |
| 0003 | `host: add Metal-backed Vulkan-only build support for macOS` | New `native_sub_window_metal.mm` (CAMetalLayer-based native window, replacing the deprecated NSOpenGL/cocoa path), the darwin framework/link-args block in `meson.build`, `GFXSTREAM_ENABLE_HOST_GLES` guards in `frame_buffer.cpp`/`color_buffer.cpp`/`gles_compat.h`, plus stub backends (`iostream`, `snapshot`) for subsystems not needed on this platform. | **This is what first made gfxstream buildable for macOS/HVF at all** — predates the libkrun session work, was never extracted as its own commit before. Found by diffing the vendored tree (with the 2 patches below reverse-applied) against the old `macos-shm-fix` branch: `host/native_sub_window_metal.mm` plain doesn't exist anywhere in the fork's history before this. |
| 0004 | `host: fix macOS build for decoders=vulkan,gles,composer` | 7 real bugs blocking the GLES/composer decoders on top of 0003's Vulkan-only base: missing brace, 3 duplicate function defs, missing `getConfigs` wrapper, missing `objcpp_args` (so `.mm` files never saw `GFXSTREAM_ENABLE_HOST_GLES`), conditional macOS frameworks for GLES. | Session work. |
| 0005 | `host/gl/texture_draw: use GLSL ES 3.00 pragmas under the GLES decoder` | Adds GLSL ES 3.00 core-profile shader variants for the blit shaders. | Session work. **Does not make the GLES decoder fully work** — Apple's internal ANGLE-over-Metal shim still rejects the blit shader compile with an empty info log, independent of `#version` pragma. Root cause still open. The Vulkan-only path (0001-0003) is unaffected and is the validated, working configuration. |

**Validated**: `meson setup -Ddecoders=vulkan --buildtype=debug && ninja` clean after 0003; `meson setup
-Ddecoders=vulkan,gles,composer --buildtype=debug && ninja` clean after 0004 and 0005, run directly inside
the fork clone after each commit.

All 5 commits carry the same `Signed-off-by: Marcus Figueiredo <figueiredo@protonmail.com>` trailer as the
2 pre-existing ones, at the repo owner's explicit instruction.

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
- `crates/capy/src/main.rs` (`androidboot.vsock_lights_port=6800`, MMIO transport cmdline, etc.) is
  Capivara-specific glue, doesn't belong in either fork.
