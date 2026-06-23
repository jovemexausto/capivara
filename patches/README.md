# Patch inventory — vendor/gfxstream & vendor/libkrun

Last refined 2026-06-23. Baseline for comparison: `https://github.com/jovemexausto/{gfxstream,libkrun}`
`main`, cloned at `/tmp/capivara-upstreams/{gfxstream,libkrun}` (ephemeral, not committed here —
re-clone to reproduce/re-extend any of this).

Goal: stop treating `vendor/` as the only record of our changes. Every real fix exists as a clean,
reviewable commit on a fork branch, and every fork branch is mirrored here as a flat, sequentially
numbered `git format-patch` series — so nothing depends on the `/tmp` clone surviving.

## libkrun — `capivara/macos-gfxstream-vulkan` (ready, fully validated)

One linear branch, built from fork `main`, 7 commits, exported as
`patches/libkrun/0001..0007-*.patch`. Apply with `git am patches/libkrun/*.patch` against fork `main`.

| # | Commit | What | Why it's there |
|---|---|---|---|
| 0001 | `deps: migrate vm-memory 0.17 -> 0.18.0` | Bumps `vm-memory` to 0.18.0 across all 6 workspace `Cargo.toml`s; adds `GuestMemoryBackend` import to 7 files where default trait methods moved; enables vm-memory's `rawfd` feature (needed for `OwnedFd`'s `WriteVolatile`/`ReadVolatile`, lost because every `Cargo.toml` sets `default-features = false`). | Real, independently-useful dependency upgrade. Our scaffolding (0003) needs `GuestMemoryBackend`, which doesn't exist in 0.17 — this is the actual prerequisite, put first so everything after it builds on a 0.18 base. |
| 0002 | `rutabaga_gfx/gfxstream: fix macOS+gfxstream build (pre-existing, unrelated to our work)` | `extern "C"` → `unsafe extern "C"` (edition 2024); adds missing `map_ptr: None` to 2 of 3 `RutabagaResource` struct literals; 2 lint-suggested cast fixes. | Fork `main`, zero patches, does not compile with `--features gfxstream` on macOS. No CI job exercises this combination. Unrelated to anything we built — just a prerequisite bug. |
| 0003 | `virtio/gpu: add gfxstream Vulkan-only integration scaffolding for macOS` | `create_rutabaga_gfxstream`, `new_gfxstream`, macOS `Worker` fields, display backend wiring, `resource_map_blob` accepting `RUTABAGA_MEM_HANDLE_TYPE_SHM` in addition to `APPLE`. ~150 lines. | The actual macOS/HVF gfxstream integration. Pre-dates this session (was already baked into the monorepo's squashed initial commit) — hand-extracted by diffing against fork `main`. **Supersedes** the old `capivara/macos-blob-mapping` PR branch: that branch's 2 commits only ever touched the `RUTABAGA_MEM_HANDLE_TYPE_SHM` check in isolation, which is a strict subset of this commit's diff. Don't reuse `macos-blob-mapping` — close/replace it with this branch. |
| 0004 | `devices: declare gpu-gfxstream feature` | Adds `gpu-gfxstream = ["gpu", "rutabaga_gfx/gfxstream"]` to `src/devices/Cargo.toml`. | The feature didn't exist upstream; needed by `#[cfg(... feature = "gpu-gfxstream")]` gates introduced in 0003. |
| 0005 | `rutabaga_gfx/gfxstream: compute map_ptr for HOST3D blobs on macOS` | The `map_ptr` fix in `create_blob` — `mmap`s the SHM fd so ASG/ranchu Vulkan actually gets a usable pointer. | **The single most important fix in this whole series** — first thing that made gfxstream/ASG work on macOS/HVF at all. See memory `capivara-gfxstream-mapptr-fix`. |
| 0006 | `virtio/gpu: wire the real map_sender into new_gfxstream on macOS` | Connects the real `map_sender` channel into `new_gfxstream` instead of the scaffolding's placeholder. | |
| 0007 | `virtio/gpu: defer gfxstream TransferFromHost3d to break dispatcher deadlock` | One-shot helper thread defers blocking `TransferFromHost3d` reads off the single in-order dispatcher thread. | Fixes the dispatcher deadlock that blocked full Android boot. See `capivara-egl-gpu-blocker` / boot-completed work. |

**Validated**: `cargo check` clean (zero errors) for `libkrun`, `krun-vmm`, `krun-arch`, `krun-kernel`,
`krun-smbios`, `krun-devices --features gpu-gfxstream`, and `krun-rutabaga-gfx --features gfxstream`, all
run directly inside the fork clone after every commit. The only failure anywhere in this tree is
`krun-init-blob`'s build script (`ld: unknown options --as-needed -Bstatic ...`, a macOS-host-linking-musl
toolchain issue) — confirmed pre-existing on fork `main` with zero patches applied, unrelated to this work.

**Not yet done**: pushing `capivara/macos-gfxstream-vulkan` to the fork, opening/updating the PR, deciding
whether to ask upstream maintainers to close `capivara/macos-blob-mapping` in favor of it.

## gfxstream — blocked on fork drift, not yet portable as a clean branch

`patches/gfxstream/unported-blocked-on-fork-drift/0001-0002-*.patch` are the 2 real fixes found this
session (7 meson/build bugs blocking `-Ddecoders=vulkan,gles,composer` on macOS, plus GLSL ES version
pragma fixes in `texture_draw.cpp`). They are **not** organized into a fork branch yet, unlike libkrun,
because attempting to apply them onto `capivara/macos-shm-fix` (the existing, already-pushed, byte-
identical-to-vendored PR branch) failed structurally, not just with offset conflicts:

- `host/native_sub_window_metal.mm` — the file our patch touches — **does not exist** in the fork at all.
  The fork only has `native_sub_window_cocoa.mm` for macOS. This means the monorepo's vendored
  `vendor/gfxstream` tree has diverged from the personal fork's `main` lineage by more than "a few patches
  behind" — there's a structural difference in how macOS native windowing is implemented, not just drift.
- `host/frame_buffer.cpp` and `host/meson.build` both have real hunks that *do* apply (offset-shifted) and
  real hunks that don't match any nearby context at all — consistent with the same root cause.

This needs its own investigation pass before these 2 patches can be ported: find out whether the
fork's `main` and the monorepo's vendored copy are from genuinely different upstream points (different
gfxstream lineages, e.g. AOSP's vs. Android Emulator's vs. some other downstream), or whether the Metal
native-window file was renamed/restructured upstream after our vendoring point. Don't force-apply with
`--reject` and hand-patch the result — that risks silently reintroducing the macOS Metal/GLES regression
already diagnosed as unsolved (see below).

Also, separately: even once ported, fix #2 (`texture_draw.cpp` GLSL ES pragmas) does **not** make the
GLES decoder path actually work — it only narrows the remaining failure to a real, unsolved bug: Apple's
internal ANGLE-over-Metal GLES shim rejects gfxstream's blit shader with an empty info log regardless of
`#version` pragma tried. Don't present porting these 2 patches as "GLES decoder works on macOS" — only as
"two narrow, real build/shader-pragma bugs fixed along the way; the underlying blocker is still open."

The 2 already-pushed PRs remain unaffected and don't need re-verification beyond what was already done:

- **gfxstream** `capivara/macos-shm-fix` — `createBlob()` propagates errors instead of always returning 0;
  POSIX SHM naming on macOS (`common/base/SharedMemory_posix.cpp`). Confirmed byte-identical to vendored.
- **libkrun** `capivara/macos-blob-mapping` — now superseded by `capivara/macos-gfxstream-vulkan` commit
  0003 above (see note in that row). Recommend closing this PR in favor of the new branch once it's pushed.

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
  Don't try to "fix" these as if they were ours — they reflect how far behind `main` the vendored copy is.
- `crates/capy/src/main.rs` (`androidboot.vsock_lights_port=6800`, MMIO transport cmdline, etc.) is
  Capivara-specific glue, doesn't belong in either fork.

## Recommended next steps

1. Push `capivara/macos-gfxstream-vulkan` to `jovemexausto/libkrun`, open a PR, reference/supersede
   `capivara/macos-blob-mapping` in the description. **Not done — needs explicit go-ahead, this is a push
   to a remote.**
2. Investigate the gfxstream fork-vs-vendored structural drift (`native_sub_window_metal.mm` missing)
   before attempting to port the 2 GLES-build-fix patches into a branch.
3. Decide whether the ANGLE-over-Metal GLES shader-compile blocker is worth continuing to chase, or
   whether the Vulkan-only path (already working, already in the 7-commit branch) is the stable target
   for now.
