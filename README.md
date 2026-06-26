![Capivara banner](branding/banner.png)

Capivara faz apps Android se comportarem como apps nativos do macOS. Um APK instalado vira um `.app` de primeira classe, com Dock, Spotlight, `Cmd+Tab` e a experiência nativa do sistema.

Android rodando nativamente em Apple Silicon macOS via HVF, `libkrun` e `gfxstream`.

## Roadmap

- ✅ fechar o bloqueio atual do `gfxstream` no host
- ✅ resolver o bloqueio de compile de shader do decoder GLES (validado por boot real)
- ✅ SurfaceFlinger/composer3 estáveis ponta a ponta (`use_gles(true)` + `gralloc=minigbm`)
- resolver os bloqueadores remanescentes de `system_server` (`oemlock` parcialmente, `frp`/
  `PersistentDataBlockService` em aberto) até `sys.boot_completed=1`
- garantir boot completo com scrcpy funcional
- consolidar o fluxo de imagem, kernel e rootfs em scripts únicos
- tornar o APK instalável e executável como `.app`
- manter o caminho de reprodução curto, pinado e sem passos manuais

## Estado atual

O build padrão deste repo está são e funcional (Vulkan-only via gfxstream/ASG, boot completo
validado). O bloqueio de compile de shader que travava o decoder GLES pro composer3 está
**resolvido e validado por boot real**: a causa raiz definitiva era `third_party/angle/
BUILD.angle.bazel` (glue Bazel nosso) nunca definir `ANGLE_ENABLE_GLSL` — sem isso,
`sh::ConstructCompiler()` da ANGLE retorna `null` incondicionalmente pra qualquer output GLSL
desktop, que é o único tipo de output que o path macOS do gfxstream usa. Não tem nada a ver com
Metal/ANGLE-over-Metal/XPC (hipótese descartada numa sessão anterior) nem com `#version` pragma
(hipótese de uma sessão ainda mais antiga). Ver memória `capivara-gles-shader-translator-missing` e
`patches/README.md` (gfxstream 0006-0008, libkrun 0008) para o diagnóstico completo.

**Validado por boot real, ponta a ponta**: `use_gles(true)` (`vendor/libkrun/.../virtio_gpu.rs`,
patches/README.md libkrun 0009) é agora o default — sem ele, `render_control.cpp`/
`renderControl_dec` nem entram no build (`meson.build` os gateia atrás de `if use_gles`/
`if use_composer`), e a consulta legada de extensões do RanchuHwc (`pipe:opengles`) nunca é
respondida, travando o composer até o `Watchdog` matar o `system_server`. Combinado com
`androidboot.hardware.gralloc=minigbm` (`crates/capy/src/main.rs` — `gralloc=default` resolve pra
`GRALLOC_TYPE_RANCHU`, um `SIGSEGV` de null-pointer em `GoldfishGralloc::getFormat()` quando
SurfaceFlinger importa um `AHardwareBuffer`), `SurfaceFlinger` ficou estável por 800s+ de boot
contínuo, zero crashes.

**Bloqueadores remanescentes até `sys.boot_completed=1`** (depois do composer estável):

1. `OemLockService.<init>()` bloqueia 65s na main thread do `system_server` esperando
   `android.hardware.oemlock.IOemLock/default` no `servicemanager` — o HAL real do Cuttlefish
   precisa de um companion host via `/dev/hvc10` que não existe no Capivara. **Workaround
   validado, não integrado ao boot ainda**: ver `tools/oemlock-stub/README.md`.
2. Com (1) contornado, o próximo bloqueador exposto: `PersistentDataBlockService` falha fatal na
   boot phase 500 (`Service PersistentDataBlockService init timeout`) por falta da partição `frp`
   no `androidboot.partition_map`. Ainda não investigado a fundo.