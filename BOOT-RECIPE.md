# Capivara — Receita de Boot Reproduzível (sys.boot_completed=1)

> **Validado em 2026-06-28.** Boot completo headless do Android (Cuttlefish arm64)
> em macOS Apple Silicon via libkrun/HVF/gfxstream, com `sys.boot_completed=1`.

## TL;DR — um comando

```bash
# 1) Gera uma userdata F2FS fresca de fábrica (cópia de trabalho em /tmp)
./scripts/prepare-userdata.sh /tmp/capy-userdata.img

# 2) Boota com oemlock+frp automáticos e espera boot_completed
SNAP=snapshots/boot-complete-2026-06-28-gles-composer
./scripts/boot-android.sh \
  --kernel    "$SNAP/gki-virtio-mmio-tpm-Image" \
  --initramfs "$SNAP/gki-android-hybrid-v5-skiavk.cpio.gz" \
  --disk "super=$SNAP/super.img" \
  --disk "userdata=/tmp/capy-userdata.img" \
  --disk "frp=$SNAP/frp.img" \
  --vcpus 4 --ram-mib 4096
```

`boot-android.sh` injeta `--allow-transport-mismatch`, espera o ADB chegar a
`device`, cria o symlink frp (como root), registra o stub oemlock e aguarda
`sys.boot_completed=1`.

## ⚠️ REGRA DE OURO — segurança de disco

**NUNCA aponte o capy para uma imagem original/master.** Bootar GRAVA no disco e
suja o journal F2FS. Sempre boote de uma **cópia em /tmp**. Se você bootar a
master direto, a próxima boot falha o `init_user0` e você terá de regenerar.

- userdata de trabalho: `/tmp/capy-userdata.img` (descartável, regenerável)
- `prepare-userdata.sh` regenera uma fresca a partir do ZIP do AOSP em segundos.

## Os 3 blockers e por que a receita funciona

### 1. `init_user0` exige F2FS limpa de fábrica
`vdc cryptfs init_user0` (T≈10s) só passa numa F2FS de fábrica. Userdata que já
bootou e foi morta com `pkill`/CTRL+C fica com journal sujo → no remount o F2FS
faz rollback → `Rebooting into recovery: init_user0_failed`.
**Fix:** sempre partir da userdata sparse do ZIP do AOSP (`prepare-userdata.sh`).

### 2. oemlock (binder) — senão Watchdog mata o system_server em ~74s
`OemLockService` espera o binder `android.hardware.oemlock.IOemLock/default`. O
HAL real do Cuttlefish (`vendor.oemlock_default`) requer `/dev/hvc10`, que não
existe no Capivara → SIGABRT em loop. Sem o serviço, o Watchdog mata o
system_server ~65s depois.
**Fix:** `tools/oemlock-stub/oemlock_stub` registra um binder stub via ADB. É um
processo independente: sobrevive a reinícios do system_server.

### 3. frp (PersistentDataBlockService) — precisa de root!
`PersistentDataBlockService` (OnBootPhase_500) lê `/dev/block/by-name/frp`. O 3º
disco (frp.img) aparece como `/dev/block/vdc` mas sem symlink by-name. Sem ele, o
system_server **cai em loop** no phase 500.
**Fix:** `ln -sf /dev/block/vdc /dev/block/by-name/frp` + perms `root:system 0660`.
**Tem de ser via `su 0`** — `/dev/block` é root-only; rodando como `shell` o
comando falha silenciosamente (foi exatamente o bug que travou tentativas
anteriores).

## Detalhes do ambiente que importam

- **ADB:** `ro.adb.secure=0` (sem prompt de autorização) e adbd escuta direto em
  `vsock:5555` (`service.adb.listen_addrs` no super.img). capy faz bridge
  `tcp 127.0.0.1:5556 → vsock:5555`. (Porta host 5556 p/ não colidir com
  BlueStacks/Genymotion em 5555.)
- **`--allow-transport-mismatch`:** obrigatório. O backend libkrun expõe virtio
  via MMIO/FDT; o gate só avisa e segue (boot funciona).
- **Primeiro boot é lento** (~3-4 min): dexopt + o system_server pode reiniciar
  1x até achar frp/oemlock. É resiliente — ele reinicia e encontra os fixes.
- **ADB "offline" precoce:** conectar antes do adbd subir o listener vsock cacheia
  uma entrada `offline` que `adb connect` sozinho NÃO refresca. `boot-android.sh`
  faz `adb disconnect` antes de cada reconexão p/ se auto-curar. Sem isso o boot
  trava esperando `device` e a injeção de frp/oemlock chega tarde demais (depois
  do watchdog ~74s) → guest reinicia. Validado: ADB chega a `device` em ~16s.

## ⚠️ Flakiness conhecida — race do gfxstream (NÃO faz parte da receita)

Em ~1 de 2 boots frescos, o capy (processo host) aborta com `Abort trap: 6` por
volta de T≈43s, no caminho Vulkan do SurfaceFlinger:
```
[vk_decoder_global_state] ExternalBlob feature is not supported with external memory metal
gles_v2_imp.cpp:glAttachShader:494 error 0x501
Created VkDevice ... for application:'surfaceflinger'
Abort trap: 6
```
É a **race residual do gfxstream** já sinalizada nos commits (`harden mResources
lifetime, root cause still open` / `mitigate a residual gfxstream race`) — não tem
relação com oemlock/frp/userdata. **Mitigação atual: re-rodar.** Resolver de vez é
trabalho separado de gfxstream, não da receita de boot.

## Artefatos da receita

| artefato | origem |
|----------|--------|
| `gki-virtio-mmio-tpm-Image` (kernel) | snapshot |
| `gki-android-hybrid-v5-skiavk.cpio.gz` (initramfs **original**) | snapshot |
| `super.img` | snapshot |
| `frp.img` (4 MB zeros) | snapshot |
| userdata F2FS fresca | `scripts/prepare-userdata.sh` ← ZIP do AOSP |

> Nota: a `userdata.img` antiga do snapshot ficou inutilizável (F2FS rollback,
> falha `init_user0`). A fonte canônica de userdata agora é `prepare-userdata.sh`.
