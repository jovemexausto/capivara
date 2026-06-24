![Capivara banner](branding/banner.png)

Capivara faz apps Android se comportarem como apps nativos do macOS. Um APK instalado vira um `.app` de primeira classe, com Dock, Spotlight, `Cmd+Tab` e a experiência nativa do sistema.

Android rodando nativamente em Apple Silicon macOS via HVF, `libkrun` e `gfxstream`.

## Roadmap

- ✅ fechar o bloqueio atual do `gfxstream` no host
- garantir boot completo com scrcpy funcional
- consolidar o fluxo de imagem, kernel e rootfs em scripts únicos
- tornar o APK instalável e executável como `.app`
- manter o caminho de reprodução curto, pinado e sem passos manuais

## Estado atual: 
O build padrão deste repo está são e funcional. O caminho GLES pro composer3 está bloqueado, mas agora por uma causa muito mais precisa: o backend que o macOS entrega para GLES é o ANGLE-over-Metal interno da própria Apple, não NSOpenGL nativo. O shader interno do gfxstream falha nele com info log vazio, independente da sintaxe da diretiva #version — ainda sem causa raiz definitiva (hipótese livre: requisito de drawable real do Metal não satisfeito em contexto headless).

Por que o ANGLE-Metal da Apple rejeita silenciosamente um shader trivial num contexto offscreen ?