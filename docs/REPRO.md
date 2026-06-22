# Reprodução

Entradas reproduzíveis:
- `inputs/`: blobs baixados usados como base fixa
- `snapshots/boot-debug-2026-06-19-v5-initramfs/`: baseline curado atual
- `snapshots/boot-debug-2026-06-19-v5-initramfs/MANIFEST.md`: procedência por artefato
- `build/libkrunfw/`: runtime derivado do input pinado de `libkrunfw`

Regra:
- se algo vem de download manual, precisa ir para `inputs/` ou virar script de fetch
- se algo é intermediário, não fica no repositório

Fluxo mínimo:
1. `./scripts/setup-macos.sh`
2. `./scripts/build-all.sh`
3. `cargo build --target aarch64-unknown-linux-musl --package krun-init --release`
4. `./scripts/make-miniroot.sh /tmp/miniroot target/aarch64-unknown-linux-musl/release/krun-init`
5. `./scripts/make-userdata.sh` se precisar regenerar o userdata local
6. `./scripts/kernel/build-gki-android16-virtio-mmio-tpm.sh` para reproduzir o kernel baseline
7. `./scripts/libkrunfw/bootstrap.sh` para preparar o runtime embutido
8. rodar o comando de `docs/STATUS.md`
