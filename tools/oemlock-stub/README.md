# oemlock-stub

Workaround Capivara-specific para um bloqueador real de boot. **Não é
upstreamável** (não é bug do gfxstream, libkrun ou AOSP/Cuttlefish) e **não
está, ainda, automaticamente integrado ao boot** — ver "Status" abaixo.

## O problema

`OemLockService.<init>()` (`frameworks/base`,
`com.android.server.oemlock.OemLockService.java:79`) chama
`ServiceManager.waitForDeclaredService("oemlock")` **de forma síncrona, na
main thread do `system_server`**, dentro de `SystemServiceManager.startService()`.
Se nada estiver registrado em `android.hardware.oemlock.IOemLock/default` no
`servicemanager`, isso bloqueia por 65s e o `Watchdog` mata o `system_server`
(`WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on main thread (main)
for 65s`), reiniciando o ciclo indefinidamente — `boot_completed` nunca chega
a `1`.

O HAL real do Cuttlefish (`android.hardware.oemlock-service.remote`) só
registra o serviço *depois* de abrir `/dev/hvc10` como terminal raw — um
canal serial para um companion host (`cvd`) que o Capivara não roda. Sem
`/dev/hvc10`, o HAL aborta (`SIGABRT`) antes de chegar ao registro. Isso é
estrutural ao design do Cuttlefish, não um bug em qualquer um dos nossos
forks.

## A correção

`oemlock_stub.cpp` registra um `AIBinder` vazio sob o nome exato
`android.hardware.oemlock.IOemLock/default`. Nenhum método AIDL real
(`isOemUnlockAllowedBy*`, etc.) é chamado no caminho crítico de boot — só a
*presença* no `servicemanager` é checada — então um binder vazio que
responde `STATUS_UNKNOWN_TRANSACTION` a qualquer transação é suficiente.

`AServiceManager_addService`/`ABinderProcess_*` são símbolos *platform-only*,
não expostos no `.so` de link do NDK público — por isso são resolvidos via
`dlopen("libbinder_ndk.so")` + `dlsym` em runtime (a lib real está sempre
presente no dispositivo).

Validado ao vivo (`adb push` + execução manual numa VM já em boot-loop): o
construtor do `OemLockService` passou de 65s+Watchdog-kill para 3ms, sem
nenhum `WATCHDOG KILLING` relacionado a oemlock depois disso.

## Build

```
./tools/oemlock-stub/build.sh [out_path]
```

Requer o Android NDK (`brew install --cask android-ndk`, ou
`ANDROID_NDK_ROOT` apontando para uma instalação existente).

## Status

**Não integrado ao boot automaticamente.** Hoje só existe como binário
buildável + prova de conceito via `adb push`/`adb shell`. Tentamos embuti-lo
no initramfs (`gki-android-hybrid-v5-skiavk.cpio.gz`) e descobrimos que esse
ramdisk é o de **recovery** (seu `init.rc` importa
`/init.recovery.${ro.hardware}.rc`), não o que governa o boot normal — então
essa via não funciona. O caminho certo de integração permanente ainda não
foi decidido entre:

- Editar a partição `vendor_boot_a`/`vendor` dentro do disco
  (`super-rebuild.img`) — onde o resto dos HALs do Cuttlefish já vive.
  Caminho mais correto, mas exige ferramentas de EROFS/ext4 que macOS não
  tem nativamente.
- Um boot ramdisk próprio do Capivara (diferente do de recovery usado hoje).
- Curto prazo: `capy` já tem um bridge ADB embutido — poderia fazer
  `push`+`exec` automaticamente assim que detectasse conectividade ADB, sem
  esperar decisão sobre os pontos acima.

Próximo bloqueador conhecido, depois deste: `PersistentDataBlockService`
falha fatal na boot phase 500 (`Service PersistentDataBlockService init
timeout`) por falta da partição `frp` no `partition_map` — ver
`README.md` "Estado atual".
