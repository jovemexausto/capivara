![Capivara banner](branding/banner.png)

# Capivara

Android nativo no macOS Apple Silicon. A ideia: instalar um APK e ele virar um
`.app` de primeira classe — Dock, Spotlight, `Cmd+Tab`, a experiência nativa.

Por baixo: Android (Cuttlefish arm64) numa VM via **HVF + [libkrun](https://github.com/containers/libkrun) + [gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream/)**, com a GPU acelerada por Metal/MoltenVK.

> ⚠️ **Early stage / pesquisa.** Hoje o Android boota até o fim e a tela
> renderiza de verdade. Espelhamento (scrcpy) e empacotamento `.app` ainda não.

## Estado

- ✅ Boot completo — `sys.boot_completed=1`, reproduzível por um comando
- ✅ Display renderiza via GPU (gfxstream→Metal) — provado por dump de scanout (o logo "android")
- 🚧 scrcpy (espelhar a tela): travado num rebuild de kernel — falta `CONFIG_DMABUF_HEAPS_SYSTEM` pro codec de vídeo
- ⬜ Empacotar um APK como `.app`

## Rodar

Precisa de macOS Apple Silicon + Rust, e `brew install meson ninja molten-vk vulkan-loader`.

```sh
./scripts/build-all.sh                              # gfxstream + libkrun + capy
./scripts/prepare-userdata.sh /tmp/capy-userdata.img
./scripts/boot-android.sh --kernel <Image> --initramfs <cpio.gz> \
  --disk super=<super.img> --disk userdata=/tmp/capy-userdata.img \
  --disk frp=<frp.img> --vcpus 4 --ram-mib 4096
```

Receita completa, artefatos e os três blockers de boot (userdata F2FS fresca,
`oemlock` stub, symlink `frp`): **[BOOT-RECIPE.md](BOOT-RECIPE.md)**.

Pra ver a tela sem scrcpy, rode o capy com `CAPY_DUMP_DIR=/tmp/frames` — ele grava
o scanout cru (RGBA) que dá pra converter em PNG.

## Como funciona

| Peça | Papel |
|------|-------|
| `crates/capy` | orquestra a VM: GPU headless, discos, bridge ADB, cmdline do boot |
| `vendor/libkrun` | VMM sobre HVF (fork — Vulkan/gfxstream no macOS) |
| `vendor/gfxstream` | GPU virtual; traduz os comandos do guest pra Metal/MoltenVK (fork) |

As mudanças nos forks vivem como série `git format-patch` em
**[patches/](patches/)**; o kernel GKI (virtio-mmio + TPM) é buildado por
`scripts/kernel/build-gki.sh` (CI: `.github/workflows/build-gki.yml`).
