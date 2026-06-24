![Capivara banner](branding/banner.png)

Capivara faz apps Android se comportarem como apps nativos do macOS. Um APK instalado vira um `.app` de primeira classe, com Dock, Spotlight, `Cmd+Tab` e a experiência nativa do sistema.

Android rodando nativamente em Apple Silicon macOS via HVF, `libkrun` e `gfxstream`.

## Roadmap

- ✅ fechar o bloqueio atual do `gfxstream` no host
- garantir boot completo com scrcpy funcional
- consolidar o fluxo de imagem, kernel e rootfs em scripts únicos
- tornar o APK instalável e executável como `.app`
- manter o caminho de reprodução curto, pinado e sem passos manuais

## Estado atual

O build padrão deste repo está são e funcional (Vulkan-only via gfxstream/ASG, boot completo
validado). O caminho GLES pro composer3 tinha dois bloqueios reais — `USE_ANGLE_SHADER_PARSER`
nunca portado do `CMakeLists.txt` pro `meson.build`, e o shim C-ABI que `angle_shader_parser.cpp`
espera via `dlopen` (`libshadertranslator.dylib`) nunca implementado em lugar nenhum (nem no
gfxstream, nem na ANGLE, nem no histórico do fork) — ambos resolvidos: a ANGLE é vendorizada via
Bazel `git_repository()` pinada, e o shim
(`ShaderTranslator.h`/`.cpp`, ver `vendor/gfxstream/host/gl/glestranslator/gles_v2/`) embrulha a API
real da ANGLE (`sh::*`) num ABI plano. O build completo (`decoders=vulkan,gles,composer`) compila
limpo ponta a ponta e o shim carrega/roda via `dlopen` de verdade — mas **ainda não validado por
boot real** exercitando o decoder GLES. Não tem nada a ver com Metal/ANGLE-over-Metal/XPC —
hipótese descartada com testes diretos numa sessão anterior. Ver memória
`capivara-gles-shader-translator-missing` e `patches/README.md` (gfxstream 0006/0007) para o
diagnóstico completo e o que é upstreamável.

Próximo passo: `use_gles(true)` em `vendor/libkrun/.../virtio_gpu.rs` + boot real pra validar o
decoder GLES/composer3 ponta a ponta.