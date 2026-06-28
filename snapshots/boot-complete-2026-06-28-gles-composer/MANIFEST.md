# Manifesto — boot-complete-2026-06-28-gles-composer

**Marco:** boot completo com GLES + composer3 (`sys.boot_completed=1`, 35s de uptime,
0 watchdog kills). Supera o snapshot `boot-complete-2026-06-22-gfxstream-asg` (que chegava
em `boot_completed` via Vulkan-only/ASG, mas sem composer3 funcional e com o `SIGSEGV` latente
do display backend).

## Artefatos e hashes

| Arquivo | SHA256 | Origem |
|---|---|---|
| `gki-virtio-mmio-tpm-Image` | `26db4c456d1b01e8ea2119c4368e76a1dfc795c09ebf77fd4896b491b367abfb` | hardlink de `boot-complete-2026-06-22-gfxstream-asg/` (inalterado) |
| `gki-android-hybrid-v5-skiavk.cpio.gz` | `c590e68c2808ba5e73054c100157b73b1ce7285fde45e9b201c7a9890d8fd95f` | hardlink de `boot-complete-2026-06-22-gfxstream-asg/` (inalterado) |
| `super.img` | `93a55ed917d934fa0049351a3b6fd7b18f9a58a19e8a0a42c2d7ce59d9bf820d` | `/tmp/super-asg.img` (derivado de `inputs/aosp_cf_arm64_only_phone-img-15581820.zip`, via `scripts/build-android-gpt.sh`) |
| `userdata.img` | `9aa342fc9374b0c068a5ee8d5ea885f4848de81cf602e95caa6f65655c15a67f` | `/tmp/userdata-asg.img` pós-boot (inclui estado ADB da sessão validada) |
| `frp.img` | `5bdacd0eb510c431cd32d1a4529904e2f1be16e1c67da8777b42d7e05dd3acb3` | imagem vazia de 4 MB criada manualmente (`dd if=/dev/zero bs=1m count=4`) |

**Nota `userdata.img`:** captura o estado pós-boot com oemlock stub e workaround frp aplicados
via `adb shell`. Contém dados escritos pelo Android durante a sessão validada — não é um disco
limpo de fábrica.

## Código exato

Monorepo: branch `master`, commit `6d0334c` (após rewrite de autor — commit original da
consolidação: `c2ef50a`).

Submodules:
- `vendor/libkrun` → `dcec194` (`capivara/macos-gfxstream-vulkan`, 11 commits sobre `main`)
- `vendor/gfxstream` → `e394898` (`capivara/macos-gfxstream-build`, 13 commits sobre `main`)

## Comando exato de boot

```bash
SNAP=snapshots/boot-complete-2026-06-28-gles-composer

./scripts/run-capy.sh \
  --kernel  "$SNAP/gki-virtio-mmio-tpm-Image" \
  --initramfs "$SNAP/gki-android-hybrid-v5-skiavk.cpio.gz" \
  --disk "super=$SNAP/super.img" \
  --disk "userdata=$SNAP/userdata.img" \
  --disk "frp=$SNAP/frp.img" \
  --vcpus 4 \
  --ram-mib 4096
```

**Variáveis de ambiente** (já setadas por `scripts/run-capy.sh`):
- `DYLD_LIBRARY_PATH=target/debug:vendor/gfxstream/build-macos/host:build/libkrunfw:/opt/homebrew/lib`
- `VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json`
- `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`

**Workarounds manuais necessários** (pós-boot, via ADB, enquanto não integrados ao boot):

```bash
# 1. oemlock stub
adb shell /data/local/tmp/oemlock_stub &

# 2. frp — o device node sobe como vold "removível", sem symlink by-name nem perms corretos
adb shell "ln -sf /dev/block/vdc /dev/block/by-name/frp"
adb shell "chown root:system /dev/block/by-name/frp"
adb shell "chmod 0660 /dev/block/by-name/frp"
```

O oemlock_stub binário foi compilado de `tools/oemlock-stub/` via NDK e empurrado pro guest com
`adb push`. Ver `tools/oemlock-stub/README.md`.

## Cadeia de fixes (da sessão anterior até este marco)

Os fixes do snapshot anterior (ASG/Vulkan) continuam válidos. Fixes adicionais neste marco:

| # | Patch | Causa raiz | Fix |
|---|---|---|---|
| gfxstream 0009 | `host: close the ASG host/guest lost-wakeup race in RingStream::readRaw` | Guest só pinga host quando observa `host_state == NEED_NOTIFY`; sem barreira StoreLoad, o host adormecia com dados já no ring | Barreira + re-check dos rings antes de `onUnavailableRead()` |
| gfxstream 0010 | `host: invoke the completion callback when an export-sync fence isn't found` | `asyncWaitForGpuWithCb` dropava o callback quando a fence já se autodestruíra (`destroyWhenSignaled=true`) — "não encontrado" = "já sinalizado", mas o código logava e descartava | Trata miss como "já completo", invoca callback imediatamente |
| gfxstream 0011 | `host/gl: force Core profile on macOS` | macOS não tem GL compatibility profile 3.x; contextos eram legacy 2.1; shaders internos do ANGLE emitem `#version 300 es` em non-core, 2.1 rejeita → draw trava Metal com lock global do FrameBuffer | `shouldEnableCoreProfile()` retorna `dispatchMaj > 2` no `__APPLE__` |
| gfxstream 0012 | `host: never route PostWorker tasks through the (nonexistent) UI thread` | `postOnlyOnMainThread()` retornava `true` no `__APPLE__`; Capivara não tem UI thread Cocoa/Qt; `run_on_ui_thread` era o stub no-op, descartava toda composição em silêncio | `postOnlyOnMainThread()` sempre `false` |
| gfxstream 0013 | `host: mResources como shared_ptr + mutex` | `mResources` acessado por dispatch thread, deferred-read thread e SyncThread sem lock | `map<id, shared_ptr<>>` com mutex só nas operações de mapa |
| libkrun 0010 | `virtio/gpu: deferred_guard` | `TransferFromHost3d` deferido sem serialização vs. ciclo de vida do resource | `wait_idle(resource_id)` per-resource + `wait_idle_all()` global (substituído por 0011) |
| libkrun 0011 | `virtio/gpu: scope deferred-read guard per-resource` | `wait_idle_all()` deadlockava o ring ASG bloqueando CmdSubmit3d/ASG pings | Remove `wait_idle_all()`; mantém só `wait_idle(resource_id)` nos lifecycle commands |
| capy `fe63c4a` | `capy: fix use-after-free of the headless display backend` | **Causa raiz do `SIGSEGV` em `TransferWithIov`**: `Box<HeadlessDisplay>` local em `setup()` era dropado ao retornar; `frame_buf` de 33 MB era liberado e reusado pela `CString` do socket ADB; gfxstream dereferenciava o ponteiro pendente no flush de scanout | `Box::leak` — ownership transferido ao libkrun pelo tempo de vida do processo |

## Como reproduzir a partir do zero

1. `git clone --recurse-submodules https://github.com/jovemexausto/capivara && cd capivara`
2. `git checkout 6d0334c` (ou master)
3. `./scripts/build-all.sh` (compila libkrun + gfxstream + capy)
4. Extraia `super.img` e `userdata.img` de `inputs/aosp_cf_arm64_only_phone-img-15581820.zip` via `scripts/build-android-gpt.sh`, ou copie direto deste snapshot
5. Crie `frp.img`: `dd if=/dev/zero of=frp.img bs=1m count=4`
6. Rode o comando acima
7. Aguarde boot (~35s); aplique os workarounds oemlock/frp via ADB
8. Verifique: `adb shell getprop sys.boot_completed` → `1`

Para o smoke-test automatizado: `./scripts/smoke-test.sh --snapshot snapshots/boot-complete-2026-06-28-gles-composer`
