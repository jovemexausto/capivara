# Kernel Input

This directory holds the source patch used by `.github/workflows/build-gki-android16-virtio-mmio-tpm.yml`.

Current content:
- `drivers/char/tpm/tpm_virtio.c`

It is not the full kernel tree. The workflow copies this file into a fresh Android GKI checkout before building the artifact.
