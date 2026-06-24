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
validado). O caminho GLES pro composer3 está bloqueado — causa raiz agora confirmada com dados
reais, não é mais hipótese: `USE_ANGLE_SHADER_PARSER` nunca foi portado do `CMakeLists.txt` pro
`meson.build` que de fato usamos, então toda tradução de shader GLES falha incondicionalmente
(`ShaderParser::convertESSLToGLSL()` cai sempre no branch `#else m_valid = false`, sem log algum).
E mesmo se a flag fosse ligada, a fonte da ANGLE não está vendorizada em `vendor/gfxstream/
third_party/angle/` (só tem arquivos de build do Bazel, não o código). Não tem nada a ver com
Metal/ANGLE-over-Metal/XPC — descartei essa hipótese com testes diretos (compilação Metal isolada
funciona limpo; compilação via desktop OpenGL.framework do shader traduzido manualmente também
funciona limpo). Ver memória `capivara-gles-shader-translator-missing` para o diagnóstico completo.

Resolver isso de verdade é vendorizar a ANGLE real + portar o wiring de build pro Meson — um
projeto de infraestrutura separado, não um patch de shader pontual.