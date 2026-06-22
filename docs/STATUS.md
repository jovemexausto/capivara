# Status

Baseline atual:

```bash
capy --allow-transport-mismatch \
  --kernel snapshots/boot-debug-2026-06-19-v5-initramfs/gki-virtio-mmio-tpm-Image \
  --initramfs snapshots/boot-debug-2026-06-19-v5-initramfs/gki-android-hybrid-v5-skiavk.cpio.gz \
  --disk super=snapshots/boot-debug-2026-06-19-v5-initramfs/super-rebuild.img \
  --userdata snapshots/boot-debug-2026-06-19-v5-initramfs/userdata.img
```

`userdata.img` pode ser regenerado com `./scripts/make-userdata.sh`.

O que funciona hoje:
- boot entra em `zygote` e `surfaceflinger`
- `gpu-gfxstream` fica ativo
- `ExternalBlob` está habilitado

Bloqueio atual:
- falha antes de `resource_map_blob`
- erro observado: `Failed to allocate ring blob shared memory`
- causa isolada no host macOS: SHM POSIX sem `/`
- patch aplicado em `vendor/gfxstream/common/base/SharedMemory_posix.cpp`

Próximo passo:
- rerodar o boot com esse baseline e confirmar se o erro de ring blob some
