# Guia Técnico

Use este arquivo como guia técnico para trabalhar neste repositório.

## Estrutura

- `crates/`: código Rust nosso.
- `scripts/`: qualquer passo manual precisa virar script aqui.
- `vendor/`: código de terceiros vendorizado.
- `kernel/`: entrada de patch do workflow do GKI.
- `inputs/`: downloads pinados com hash.
- `build/`: somente saídas geradas localmente.
- `snapshots/`: artefatos derivados curados e manifests.
- `docs/`: estado atual e notas de reprodução.

## Regras

- Se é manual, vai para `scripts/`.
- Se é baixado, vai para `inputs/` com hash.
- Se é derivado, vai para `build/` ou `snapshots/`.
- Se é fonte de terceiro, vai para `vendor/`.

## Estado Atual

- O boot chega em `zygote` e `surfaceflinger`.
- O bloqueio vivo está na alocação de shared memory do `gfxstream` no host.
- O baseline canônico é `snapshots/boot-debug-2026-06-19-v5-initramfs/`.

## Entradas Canônicas

- `docs/STATUS.md`
- `docs/REPRO.md`
- `snapshots/boot-debug-2026-06-19-v5-initramfs/MANIFEST.md`
