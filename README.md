![Capivara banner](branding/banner.png)

Capivara faz apps Android se comportarem como apps nativos do macOS. Um APK instalado vira um `.app` de primeira classe, com Dock, Spotlight, `Cmd+Tab` e a experiência nativa do sistema.

Android rodando nativamente em Apple Silicon macOS via HVF, `libkrun` e `gfxstream`.

## Roadmap

- ✅ fechar o bloqueio atual do `gfxstream` no host
- ✅ resolver o bloqueio de compile de shader do decoder GLES (validado por boot real)
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
(hipótese de uma sessão ainda mais antiga). Um boot real com `use_gles(true)` temporário confirmou:
o blit shader interno do gfxstream (`texture_draw.cpp`) compila com sucesso pra vertex e fragment,
sem mais crash. Ver memória `capivara-gles-shader-translator-missing` e `patches/README.md`
(gfxstream 0006-0008, libkrun 0008) para o diagnóstico completo.

**Não validado ainda**: boot de um guest Android real exercitando o decoder GLES/composer3 ponta a
ponta (SurfaceFlinger renderizando) — só testado contra um `/bin/sh` minimal, que não roda
compositor. `use_gles` continua `false` por padrão em `vendor/libkrun/.../virtio_gpu.rs` até essa
validação acontecer.