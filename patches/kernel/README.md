# Kernel GKI (virtio-mmio)

Build do kernel GKI usado pelo Capivara, contra uma revisão AOSP **pinada** (não uma branch
flutuante). Tudo que define O QUE muda vive aqui em `patches/kernel/`; o único executável é
`scripts/kernel/build-gki.sh`, parametrizado por versão de Android.

```
patches/kernel/
  capivara_gki.config      # fragmento de Kconfig (compartilhado entre versões)
  android16/
    pinned-manifest.xml    # SHA exato de common-android16-6.12 + sub-projetos
  android15/ android14/    # mesma estrutura quando/se gerados
```

Pipeline (`build-gki.sh <versão>`): `repo sync` da revisão pinada → aplica patches da versão (se
houver) → aplica o fragmento de Kconfig em forma canônica → build via Bazel/Kleaf → coleta
artefatos (`Image`, `*.ko`, `system_dlkm*`).

## `capivara_gki.config`

As flags do recurso, todas `=y`: `CONFIG_VIRTIO_MMIO`, `CONFIG_CRYPTO_USER`,
`CONFIG_DRM_VIRTIO_GPU`, `CONFIG_UDMABUF`, `CONFIG_DMABUF_HEAPS`, `CONFIG_DMABUF_HEAPS_SYSTEM`
(esta última habilita o dmabuf system heap, sem o qual o Codec2/`media.swcodec` quebra — ver
comentário no arquivo).

**Por que não `merge_config.sh -m`:** ele faz merge textual, anexando as flags no fim do
`gki_defconfig`. O Kleaf roda `savedefconfig` ao buildar o target `kernel_aarch64_config` e exige
que o `gki_defconfig` JÁ esteja na forma canônica/minimal — senão falha com *"savedefconfig does
not match"*. E não dá pra corrigir com `_config -- savedefconfig` (o check roda no build do target,
antes do subcomando). Então `build-gki.sh` insere cada símbolo na **posição canônica** que o
`savedefconfig` emite, de forma **idempotente** (símbolos que a base já traz — ex.: `UDMABUF`,
`DMABUF_HEAPS` no android16 — são pulados pra não duplicar). Um guard falha alto se alguma âncora
de inserção sumir numa versão futura do GKI.

## Patches de source

Hoje **não há** patch de source (o suporte a virtio-mmio vem só do Kconfig). O loop em
`build-gki.sh` aplica qualquer `<versão>/*.patch` que exista — é onde entraria um patch de driver
caso uma versão precise. (O antigo `0001-add-tpm-virtio-driver.patch` foi removido: TPM não é
usado.)

## `pinned-manifest.xml`

Manifest revision-locked (`repo manifest -r`) com o SHA exato de cada sub-projeto. Consumido via
`repo init -u file://.../<versão>/pinned-manifest.xml --standalone-manifest`.

- **Ajuste obrigatório:** trocar o `<remote fetch="..">` gerado por
  `fetch="https://android.googlesource.com/"` (URL absoluta). Com `--standalone-manifest` apontando
  pra um `file://` local não há de onde resolver o relativo, e o `repo sync` falha com "does not
  appear to be a git repository".
- **Atualizar o pin:** `repo init -b common-android<N>-<kv> && repo sync` num tmp,
  `repo manifest -r -o pinned-manifest.xml`, reaplicar o ajuste de `fetch`, sobrescrever.

## Adicionar uma versão (android14/15/…)

1. Confirme o branch GKI exato (`common-android<N>-<kv>`) em
   `https://android.googlesource.com/kernel/common/+refs`.
2. Gere o `pinned-manifest.xml` (passos acima) em `patches/kernel/android<N>/`.
3. `capivara_gki.config` é reusado; confira se as âncoras de inserção em `build-gki.sh` ainda
   batem com o `gki_defconfig` dessa versão (o guard avisa se não).
4. Adicione a opção em `.github/workflows/build-gki.yml` (`workflow_dispatch.inputs.android_version`).

## Notas operacionais (CI)

- `repo` do `apt` no `ubuntu-latest` pode ser antigo; se `repo init` reclamar de
  `--standalone-manifest`, instalar o launcher via
  `curl https://storage.googleapis.com/git-repo-downloads/repo`.
- O aviso `unparseable HEAD; trying to recover` é esperado com `--standalone-manifest` — não é erro.
- O `actions/cache` de `/tmp/kernel` pode passar do limite de 10GB (checkout + toolchains); se o
  cache for pulado, o build só re-clona, sem regressão de correção.
