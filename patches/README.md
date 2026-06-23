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

## Update (same day, continued): scaffolding extracted, branch built, blocked on a real dependency-version gap

Did the recommended next step above. Local-only branch `capivara/gfxstream-macos-base` in the
`/tmp/capivara-upstreams/libkrun` clone (**not pushed** — re-clone + re-apply needed to reproduce, nothing
is preserved outside that `/tmp` clone right now) now has, in order, on top of fork `main`:

1. `rutabaga_gfx/gfxstream: fix macOS+gfxstream build (pre-existing, unrelated to our work)` —
   `cargo check -p krun-rutabaga-gfx --features gfxstream` does **not** currently compile on fork `main`,
   with zero patches of ours applied. Two real, pre-existing bugs, unrelated to anything we did: (a) the
   `stream_renderer_*` extern block isn't marked `unsafe extern "C"`, required by this crate's own
   `edition = "2024"`; (b) `RutabagaResource`'s macOS-only `map_ptr` field is missing from 2 of 3 struct
   literals in `gfxstream.rs`. No CI job in `.github/workflows` appears to exercise gfxstream+macOS, which
   is presumably why nobody caught this. Fixed with `map_ptr: None` at both sites + the `unsafe extern`
   keyword + two `as *const ()` lint fixes the compiler itself suggested. Verified: clean compile after.
2. `virtio/gpu: add gfxstream Vulkan-only integration scaffolding for macOS` — the pre-session scaffolding
   patch from the previous update, applied clean on top of the fix above.
3. `devices: declare gpu-gfxstream feature` — `#[cfg(... feature = "gpu-gfxstream")]` needs this feature to
   exist in `Cargo.toml`; it didn't. Added `gpu-gfxstream = ["gpu", "rutabaga_gfx/gfxstream"]`.
4. `rutabaga_gfx/gfxstream: compute map_ptr for HOST3D blobs on macOS` — patch #0 above, applies clean here.
5. `virtio/gpu: wire the real map_sender into new_gfxstream on macOS` — the real part of patch #1 above
   (the rest of #1's diff was eprintln-debug cleanup already done while hand-extracting the scaffolding;
   confirmed via `git apply --reject`, the rejected hunks were exactly that cleanup, nothing functional lost).
6. Patch #2 (deferred `TransferFromHost3d`) applies clean modulo one single-line `#[cfg(...)]` attribute
   that needed re-adding by hand (trivial context drift from the hunks before it).

**Where it's genuinely blocked**: `krun-rutabaga-gfx` (just the gfxstream.rs/lib.rs changes) compiles clean
standalone -- validated directly inside the fork clone, after every commit in the branch. The
`krun-devices` crate (virtio_gpu.rs/worker.rs) does not, but **not because of anything in our patches**:
fork `main`'s `src/devices/Cargo.toml` pins `vm-memory = "0.17"`, while our monorepo's
`vendor/libkrun/src/devices/Cargo.toml` pins `vm-memory = "0.18.0"`. Our scaffolding patch uses
`GuestMemoryBackend`, which only exists in 0.18+. Bumping the fork's `Cargo.toml` to `0.18.0` to test this
surfaced **14 more compile errors**, all unrelated to gpu/gfxstream (`vsock/packet.rs`'s `get_slice` calls,
etc.) -- 0.18 restructured `GuestMemory`'s slice API (`get_slice` → `get_slices` with a new `Permissions`
parameter) in a way that touches many call sites across the whole crate. This is a real, separate,
substantial vm-memory 0.17→0.18 migration that our integration already depends on (done at some point
before this session, scope unknown), not something to fold into the gfxstream patch series. Reverted the
experimental bump; did not commit it.

Also found, in passing, a second pre-existing fork bug unrelated to all of the above: `cargo check
-p krun-devices` (zero features, zero patches) fails on `OwnedFd::write_volatile` not found in
`console/port_io/unix.rs:139`. Not investigated further -- flagging only.

**All 6 commits are saved as `.patch` files** in
`patches/libkrun/fork-branch-capivara-gfxstream-macos-base/000{1..6}-*.patch` (via `git format-patch
main..capivara/gfxstream-macos-base`), re-appliable with `git am` against the fork's `main` even if the
`/tmp` clone is gone. In order: (1) the macOS+gfxstream baseline compile fix, (2) the integration
scaffolding, (3) the `gpu-gfxstream` feature declaration, (4) the `map_ptr` historic fix, (5) the
`map_sender` wiring fix, (6) the `TransferFromHost3d` deferred-dispatch fix. Each one was individually
`cargo check`-validated (for `krun-rutabaga-gfx`) before moving to the next.

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

Decision point for the user: the vm-memory 0.17→0.18 migration is the real remaining blocker for getting
`krun-devices` (and therefore the full gfxstream-macOS path) to compile standalone in the fork. Options,
not yet chosen:

1. Do the 0.17→0.18 migration as its own clean, separate PR/branch first (real, valuable, but unrelated to
   gfxstream -- touches `vsock/packet.rs` and likely other files; scope not yet measured beyond "14 errors
   surfaced on one `cargo check` invocation, probably more once those are fixed and compilation proceeds
   further").
2. Rebase our scaffolding patch to avoid `GuestMemoryBackend` and stay on vm-memory 0.17's older API, if
   that's possible without losing functionality -- avoids the migration but diverges our fork branch from
   what's actually running/validated in the monorepo.
3. Stage the branch as-is (compiles standalone for `krun-rutabaga-gfx`; `krun-devices` blocked on the
   version gap) and open the PR anyway with that caveat stated, letting upstream maintainers decide.

The branch itself (`capivara/gfxstream-macos-base`) is local-only in `/tmp/capivara-upstreams/libkrun`,
**not pushed**. But all 6 commits are now saved as `.patch` files in this directory (see above) -- safe to
reconstruct with `git checkout -b capivara/gfxstream-macos-base origin/main && git am
patches/libkrun/fork-branch-capivara-gfxstream-macos-base/*.patch` even if `/tmp` is wiped. Pushing the
branch itself is the next action, once the vm-memory decision above is made.
