![Capivara banner](branding/banner.png)

Capivara faz apps Android se comportarem como apps nativos do macOS. Um APK instalado vira um `.app` de primeira classe, com Dock, Spotlight, `Cmd+Tab` e a experiência nativa do sistema.

Android rodando nativamente em Apple Silicon macOS via HVF, `libkrun` e `gfxstream`.

## Roadmap

- ✅ fechar o bloqueio atual do `gfxstream` no host
- ✅ resolver o bloqueio de compile de shader do decoder GLES (validado por boot real)
- ✅ SurfaceFlinger/composer3 estáveis ponta a ponta (`use_gles(true)` + `gralloc=minigbm`)
- ✅ resolver o hang do blit GLES no macOS (Core profile; o bloqueador "composer/GLES" multi-sessão)
- ✅ resolver o `postOnlyOnMainThread` sem UI thread (descartava toda composição em silêncio)
- ✅ `sys.boot_completed=1` alcançado (use-after-free do display backend + remoção do drain global
  do deferred guard); `oemlock`/`frp` ainda contornados via workaround manual
- integrar `oemlock` stub + partição `frp` ao boot (hoje aplicados via `adb` a cada boot)
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

**Bloqueadores remanescentes até `sys.boot_completed=1`** (depois do composer estável), na ordem em
que aparecem durante o boot — cada um só fica visível depois que o anterior é contornado:

1. `OemLockService.<init>()` bloqueia 65s na main thread do `system_server` esperando
   `android.hardware.oemlock.IOemLock/default` no `servicemanager` — o HAL real do Cuttlefish
   precisa de um companion host via `/dev/hvc10` que não existe no Capivara. **Workaround
   validado, não integrado ao boot ainda**: ver `tools/oemlock-stub/README.md`.
2. `PersistentDataBlockService` falha fatal na boot phase 500 (`Service PersistentDataBlockService
   init timeout`) por falta da partição `frp` (`androidboot.partition_map`/`androidboot.boot_devices`
   não tinham suporte a esse papel — adicionado em `crates/capy/src/soc.rs`, `DiskRole::Frp`, via
   `--disk frp=<img>`). Mesmo com a partição existindo, o device node `/dev/block/vdN` correspondente
   sobe como disco "removível" pro `vold` (`delaying scan due to secure keyguard`) em vez de seguir o
   caminho de first-stage init dos demais slots fixos — symlink `by-name/frp` e permissão
   `root:system 0660` **não são criados automaticamente ainda**; workaround validado via `adb shell`
   (`ln -s`/`chown`/`chmod`), não integrado ao boot.
3. Com (1) e (2) contornados: bug real no host-side fence handling do gfxstream
   (`asyncWaitForGpuWithCb`, patches/README.md gfxstream 0010) — mesma família da race do ASG
   (0009), mas no caminho de `compose()` via pipe/render-control em vez do ring ASG/Vulkan. Um
   `EmulatedEglFenceSync` com `destroyWhenSignaled=true` pode se autodestruir e sumir do registry
   antes do comando virtio-gpu `GFXSTREAM_CREATE_EXPORT_SYNC` (canal separado, sem garantia de
   ordem) tentar localizá-lo — o código antigo logava o erro e **dropava o callback de conclusão em
   silêncio**, travando pra sempre o `dma_fence_default_wait` do `RanchuHwc` (e por consequência o
   `presentDisplay`/`SurfaceFlinger`/`DisplayManagerService`). **Corrigido e commitado**: tratar
   "não encontrado" como "já sinalizado" em vez de dropar o callback.
4. Com (1)-(3) corrigidos, o `DisplayManagerService.<init>()` travava 65s em
   `getCompositionColorSpaces` → `presentDisplay` → `RanchuHwc`. **Causa raiz encontrada e
   corrigida** (patches/README.md gfxstream 0011): o blit de window-surface do GLES no macOS
   (`eglBlitFromCurrentReadBufferANDROID`) travava o Metal porque o contexto GL do host era legacy
   2.1 (Apple não tem profile de compatibilidade 3.x), e os shaders internos do translator usavam
   `#version 300 es`, que o 2.1 rejeita → programa quebrado → draw trava segurando o lock global do
   FrameBuffer. Forçar **Core profile** no macOS resolve: shaders compilam (`#version 330 core`), o
   blit completa, e o boot avança até `rcComposeWithoutPost`/scanout. Esse era o bloqueador
   "composer/GLES" de várias sessões.
5. Com (1)-(4) corrigidos, `rcComposeWithoutPost` entrava mas **nunca retornava**:
   `postOnlyOnMainThread()` (patches/README.md gfxstream 0012) herdava do AEMU a suposição de uma UI
   thread Cocoa/Qt real pra rodar `PostCmd::Compose` — o Capivara não tem essa UI thread, então
   `run_on_ui_thread` sempre caía no stub padrão que **descarta a tarefa em silêncio**. `compose()`
   ficava travado pra sempre em `completeFuture.wait()`. **Corrigido**: roda sempre na própria thread
   do `PostWorker`. Validado: `rcComposeWithoutPost` passou a entrar E retornar.
6. **RESOLVIDO — era a causa raiz final**: `SIGSEGV` em `VirtioGpuResource::TransferWithIov`/`memmove`,
   host crashava entre ~7s e ~580s. O achado decisivo: os bytes corrompidos eram **idênticos** entre
   crashes de sessões diferentes (decodificavam pra `"/tmp/capy-adb-5555.sock"`, string nossa) — o que
   descarta race (lixo variável) e aponta bug de lógica determinístico. Causa raiz: o `disp_ptr`
   passado ao libkrun via FFI apontava pra um `Box<HeadlessDisplay>` **local** de `setup()` em
   `crates/capy/src/main.rs`; quando `setup` retornava, o `Box` era dropado e o `frame_buf` de 33 MB
   liberado, e a região era reusada pela `CString` do socket ADB — o gfxstream guardava o ponteiro e o
   dereferenciava no flush de scanout do compose (só exercitado depois que 0011/0012 fizeram o compose
   chegar ao flush, por isso só apareceu agora). Fix: `Box::leak` (ownership transferido pro libkrun
   pelo tempo de vida do processo), monorepo `fe63c4a`. Os patches gfxstream 0013 e libkrun 0010
   (`wait_idle`) continuam válidos como hardening estrutural, mas não eram a causa deste crash; o
   `wait_idle_all()` global de 0010 foi **removido** (libkrun 0011) por causar deadlock no ring ASG.
   **Resultado: `sys.boot_completed=1`, 35s de uptime, 0 watchdog kills.**