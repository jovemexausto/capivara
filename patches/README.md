# Patch inventory — vendor/gfxstream & vendor/libkrun

Generated 2026-06-23. Baseline for comparison: `https://github.com/jovemexausto/{gfxstream,libkrun}` `main`,
cloned at `/tmp/capivara-upstreams/{gfxstream,libkrun}` (not committed here — re-clone to reproduce).

Goal: stop treating `vendor/` as the only record of our changes. Every real fix should exist as a
clean, reviewable commit on a fork branch, traceable back to here.

## Status: clean, ready to port

| # | File | Patch | Status |
|---|---|---|---|
| 0 | `libkrun/src/rutabaga_gfx/src/gfxstream.rs` | `libkrun/00-map_ptr-historic-fix.patch` | **Hand-extracted** from squashed `16b557b`; not in any open PR. Applies clean (`git apply --check`) onto fork `main`. **This is the single most important fix** — it's what first made gfxstream/ASG work on macOS/HVF at all (see memory `capivara-gfxstream-mapptr-fix`). |
| 1 | `libkrun/src/devices/src/virtio/gpu/{virtio_gpu.rs,worker.rs}` | `libkrun/01-gpu-complete-boot-shm-mapping.patch` | From commit `35e4129`. Not yet verified to apply against fork `main` (depends on #0's context existing first). |
| 2 | `libkrun/src/devices/src/virtio/gpu/worker.rs`, `rutabaga_gfx/src/{gfxstream,lib}.rs` | `libkrun/02-defer-transferfromhost3d.patch` | From commit `96e1fea`. Same dependency note as #1. |
| 3 | `gfxstream/host/{frame_buffer.cpp,meson.build,native_sub_window_metal.mm}` + `libkrun/.../virtio_gpu.rs` | `gfxstream/01-gles-host-build-fixes.patch` + `libkrun/03-gles-host-build-cmdline-flags.patch` | From commit `107b676`. 7 real bugs in vendored gfxstream that blocked `-Ddecoders=vulkan,gles,composer` from building on macOS. See memory `capivara-gfxstream-gles-host-build`. |
| 4 | `gfxstream/host/gl/texture_draw.cpp` + `libkrun/.../virtio_gpu.rs` | `gfxstream/02-texture_draw-glsl-es-pragmas.patch` + `libkrun/04-revert-use_gles-texture_draw-pragmas.patch` | From commit `8e27d92`. Reverts `use_gles` default (regressed the working Vulkan-only boot), fixes GLSL ES pragmas. The underlying ANGLE-over-Metal shader compile failure is **still unsolved** — don't present this as "GLES now works," only as "two real, narrow bugs fixed along the way."

## Status: already upstream-pushed (verify before reusing)

These two PRs were opened in an earlier (pre-this-session) pass. Confirmed via diff that the vendored
files are **byte-identical** to these PR branches — no drift, safe to treat as already covered:

- **gfxstream** `capivara/macos-shm-fix` → `host/virtio_gpu_gfxstream_renderer.cpp` (propagate `createBlob()`
  errors instead of always returning 0) + `common/base/SharedMemory_posix.cpp` (POSIX SHM naming on macOS).
- **libkrun** `capivara/macos-blob-mapping` → `virtio_gpu.rs` `resource_map_blob` accepts
  `RUTABAGA_MEM_HANDLE_TYPE_SHM` in addition to `APPLE`.

**Important gap found while verifying this**: the libkrun PR branch is much narrower than it looks. It
does **not** contain `create_rutabaga_gfxstream`, `new_gfxstream`, or any of the macOS/gfxstream
Vulkan-only integration scaffolding that predates this session (part of the squashed `16b557b`). The PR's
`resource_map_blob` SHM-acceptance check exists in a vacuum — without the surrounding context, it doesn't
fully make sense as a standalone patch. `wc -l` shows ~150 lines of difference between the PR branch's
`virtio_gpu.rs` (1059 lines) and ours (1207 lines), consistent with that whole integration being absent.

## Not yet inventoried — needs its own pass

This is real, load-bearing code, not yet ported anywhere:

- The **pre-session** gfxstream-macOS integration scaffolding in `virtio_gpu.rs`/`worker.rs`
  (`create_rutabaga_gfxstream`, `new_gfxstream`, `Worker` macOS fields, display backend wiring). This is
  what patches #1 and #2 above *build on* — porting #1/#2 cleanly requires this to land first.
- `vendor/libkrun/src/devices/src/virtio/tpm/` — an entire custom virtio-tpm device, not in upstream `main`
  at all. Unrelated to the gfxstream/boot work; needs its own investigation into origin/purpose before
  deciding if/how to port.
- `vendor/libkrun/Cargo.toml.upstream` and friends (`examples/Cargo.toml.upstream`,
  `krun-sys/Cargo.toml.upstream`, `rutabaga_gfx/ffi/Cargo.toml.upstream`, `tests/Cargo.toml.upstream`,
  `Cargo.lock.upstream`) — backups left behind when local `Cargo.toml`s were substituted for the
  monorepo's build layout. Local glue, not upstream material, but worth understanding before any
  submodule/pin migration.
- `vendor/libkrun/build-sp2a-macos.sh`, `libkrun.pc`, `linux-sysroot/` — local build glue.
- The large list of other diffing files in `libkrun/tests/test_cases/*.rs` and `libkrun/examples/*.c` is
  **mostly upstream API drift** (verified on `examples/boot_efi.c`: upstream renamed/added functions like
  `krun_init_log`, `krun_add_virtio_console_default`, `krun_add_disk` since our vendoring point), not our
  contributions. Don't try to "fix" these — they reflect how far behind `main` our vendored copy is
  (1401 commits on libkrun's `main` since whatever commit we forked from; exact base SHA unknown,
  not worth bisecting for).
- `crates/capy/src/main.rs` (`androidboot.vsock_lights_port=6800`, MMIO transport cmdline, etc.) is
  **Capivara-specific glue**, not gfxstream/libkrun material — does not belong in either fork.

## Recommended next step

Before porting #1/#2 to the libkrun fork, first land the pre-session ASG/gfxstream-macOS scaffolding as
its own clean commit (extracted from `16b557b`, same hand-extraction method used for patch #0). Only then
will #1/#2 apply meaningfully on top. This is bigger, slower work — do it deliberately, not as a quick
follow-up.
