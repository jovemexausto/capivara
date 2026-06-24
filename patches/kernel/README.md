# Patch inventory — kernel GKI (virtio-tpm)

Espelha a convenção já estabelecida em `patches/{libkrun,gfxstream}/README.md`: o que antes era
um conjunto de edições imperativas (`sed -i`/`grep`/`echo`) direto numa árvore AOSP clonada fresca
em toda execução, hoje é um patch real + um fragmento de Kconfig, aplicados contra uma revisão
explicitamente pinada — não uma branch flutuante.

Tudo que define O QUE muda no kernel vive aqui, em `patches/kernel/`: o manifest pinado, o patch e
o fragmento de config. O único executável é `scripts/kernel/build-gki-android16-virtio-mmio-tpm.sh`
— um script só, que orquestra repo sync → aplica patch → merge config → build Bazel → coleta
artefatos. Antes disso existiam **3 diretórios** (`kernel/`, `scripts/kernel/`, `patches/kernel/`)
e **3 scripts separados** pra uma única pipeline linear, mais o código-fonte do driver duplicado
(solto em `kernel/drivers/char/tpm/tpm_virtio.c` *e* embutido no patch) — consolidado nesta pasta
porque nenhuma das peças era reusada independentemente. O patch (`0001-*.patch`) agora é a única
fonte de verdade do driver; não existe mais um `.c` solto no monorepo.

## O que motivou essa migração

Confirmado durante a implementação (não especulativo):

1. **A branch `common-android16-6.12` realmente se move.** O script antigo tinha um `sed -i
   's/^SUBLEVEL = .*/SUBLEVEL = 89/'` defensivo que, ao testar contra o HEAD atual, já é um no-op —
   o upstream já está em `SUBLEVEL = 89`. E tinha deleções defensivas de linhas como
   `# CONFIG_DRM_VIRTIO_GPU is not set` e `# CONFIG_UDMABUF is not set` que **não existem mais** no
   `gki_defconfig` atual (o upstream parou de emitir essas linhas de comentário para símbolos não
   selecionados nessa flavor de defconfig). Os `sed -i '/padrão/d'` correspondentes já eram no-ops
   silenciosos — exatamente o modo de falha (não falha, só para de fazer o que deveria) que motivou
   a migração.
2. **`CONFIG_UDMABUF=y` já vem `y` por padrão upstream hoje** — outro sinal de que o conjunto de
   sed's tinha acumulado lógica morta/defensiva ao longo do tempo, sem ninguém notando porque nada
   ali falha alto.

## Estrutura

- **`pinned-manifest.xml`** — manifest "revision-locked" (`repo manifest -r`), com o SHA exato de
  cada sub-projeto do AOSP usado neste build (`kernel/common`, toolchains, etc.), em vez de
  `-b common-android16-6.12` solto. Consumido via
  `repo init -u file://.../patches/kernel/pinned-manifest.xml --standalone-manifest`.
  - **Ajuste necessário**: o manifest gerado pelo `repo manifest -r` vem com
    `<remote fetch="..">`, resolvido relativo à URL do *manifest git repo* original
    (`https://android.googlesource.com/kernel/manifest`). Isso quebra com `--standalone-manifest`
    apontando para um arquivo local (`file://`), porque não há mais uma URL de remote da qual
    resolver o relativo. Corrigido manualmente para
    `fetch="https://android.googlesource.com/"` (URL absoluta) — sem isso, `repo sync` tenta buscar
    `kernel/common` relativo ao caminho do próprio arquivo de manifest e falha com "does not appear
    to be a git repository". Validado com um `repo init`+`repo sync common` limpo a partir do
    arquivo final.
  - **Como atualizar o pin deliberadamente**: clonar `common-android16-6.12` normalmente
    (`repo init -u https://android.googlesource.com/kernel/manifest -b common-android16-6.12 &&
    repo sync`), gerar um novo `repo manifest -r -o pinned-manifest.xml`, aplicar o mesmo ajuste de
    `fetch=".."` → URL absoluta, e então regenerar `0001-add-tpm-virtio-driver.patch` (abaixo) caso
    o patch não aplique mais limpo contra a nova revisão.
- **`0001-add-tpm-virtio-driver.patch`** — patch unificado (`git apply -p1`, com `-p1` porque o
  diff foi gerado de dentro de `common/`) cobrindo:
  - `drivers/char/tpm/tpm_virtio.c` (arquivo novo — este patch é a única fonte de verdade do
    driver no monorepo; pra ler/editar o código, aplique o patch numa árvore ou abra o `.patch`
    direto, já que é um diff de "arquivo novo" — todo o conteúdo aparece prefixado com `+`,
    perfeitamente legível em qualquer visualizador de diff).
  - `drivers/char/tpm/Kconfig` — stanza `config TCG_VIRTIO`.
  - `drivers/char/tpm/Makefile` — regra `obj-$(CONFIG_TCG_VIRTIO) += tpm_virtio.o`.
  - `include/uapi/linux/virtio_ids.h` — `#define VIRTIO_ID_TPM 29`.
  - `arch/arm64/configs/gki_defconfig` — remove `bootconfig` de dentro do `CONFIG_CMDLINE="..."`
    (única ocorrência relevante para arm64; as variantes x86/microdroid do upstream não são tocadas
    porque não fazem parte do nosso build).
  - Validado com `git apply --check -p1` numa árvore limpa na revisão pinada, e confirmado que
    `tpm_virtio.c` resultante é byte-idêntico ao que existia no monorepo antes desta consolidação
    (`kernel/drivers/char/tpm/tpm_virtio.c`, removido — ver acima).
- **`capivara_gki.config`** — fragmento de Kconfig com as 6 flags do recurso
  (`CONFIG_VIRTIO_MMIO`, `CONFIG_CRYPTO_USER`, `CONFIG_TCG_TPM`, `CONFIG_TCG_VIRTIO`,
  `CONFIG_DRM_VIRTIO_GPU`, `CONFIG_UDMABUF`, todas `=y`). Aplicado via
  `scripts/kconfig/merge_config.sh -m` (ferramenta oficial do próprio kernel — já existe em
  qualquer checkout, não é dependência nova). Diferente do `sed` antigo: `merge_config.sh` localiza
  e sobrescreve o símbolo onde quer que ele esteja (ou anexa, se ausente) — não depende de uma
  linha-âncora vizinha continuar existindo no mesmo lugar.
  - **Nota de portabilidade**: `merge_config.sh` usa `cp -T` e construções de `sed` que exigem
    coreutils GNU. Em macOS (BSD cp/sed) ele falha com `cp: illegal option -- T` — irrelevante para
    o CI real (`ubuntu-latest`, GNU coreutils nativo), mas testar localmente num Mac requer
    `brew install coreutils gnu-sed` e prefixar o `PATH` com `gnubin` antes de chamar o script.

## Validado

- `git apply --check -p1 patches/kernel/0001-add-tpm-virtio-driver.patch` limpo contra
  `kernel/common` na revisão pinada (clone fresco, sem cache).
- `tpm_virtio.c` pós-patch é byte-idêntico ao que existia em `kernel/drivers/char/tpm/tpm_virtio.c`
  antes da consolidação (arquivo removido — o patch é a fonte de verdade agora).
- `merge_config.sh -m` produz um `gki_defconfig` com as 6 flags presentes e em efeito (a única
  diferença vs. o `sed` antigo é a *posição* de `CONFIG_UDMABUF=y` no arquivo — já estava `y` por
  padrão upstream, o merge só moveu a linha para o bloco anexado; sem diferença de comportamento).
- `repo init -u file://.../pinned-manifest.xml --standalone-manifest` sozinho: roda e identifica
  corretamente a URL de fetch absoluta (`https://android.googlesource.com/kernel/common`),
  confirmado via `ps aux` durante a execução. **Não confirmado**: o `repo sync` subsequente até o
  fim — na prática, isso dispara um clone real de `kernel/common` (~1.6GB) pela rede, sem
  autenticação, e demorou tempo suficiente (>1h numa tentativa) para não valer a pena esperar
  localmente só para confirmar. Isso não indica um bug — é só um clone anônimo grande e
  potencialmente sujeito a rate-limiting do `android.googlesource.com`; o mesmo aconteceria com a
  branch flutuante antiga. Ver seção abaixo.

## Não validado ainda — checar na primeira execução real do workflow

O patch e o fragmento de config (`0001-add-tpm-virtio-driver.patch`, `capivara_gki.config`) foram
validados de ponta a ponta contra uma árvore `common/` real, na revisão pinada (clone completo,
sem cache, rodado uma vez). O que **não** foi confirmado:

- Um `repo init`+`repo sync` *completo* a partir do `pinned-manifest.xml` final, do zero, sem
  reusar um clone já existente. O mecanismo (manifest, `fetch` absoluto, `--standalone-manifest`)
  foi confirmado correto na fase de `repo init`; a fase de `repo sync` em si é só uma questão de
  tempo de rede, não de lógica — mas não tive paciência de deixar rodando localmente por horas só
  pra confirmar que termina. **Recomendo a primeira execução real ser via `workflow_dispatch` no
  CI**, onde dá pra acompanhar o log e ver quanto tempo o clone de fato leva nesse ambiente.
- `repo` instalado via `apt-get install repo` no runner `ubuntu-latest` pode ser uma versão mais
  antiga do launcher — `--standalone-manifest` é uma flag relativamente recente. Se a primeira
  execução do workflow falhar em `repo init` com "unrecognized arguments: --standalone-manifest",
  a correção é trocar a instalação por `curl
  https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && chmod +x
  /usr/local/bin/repo` (o mesmo launcher usado para validar isso localmente) em vez do pacote apt.
- Um aviso cosmético (`project .repo/manifests: unparseable HEAD; trying to recover... repo has
  been initialized`) aparece com `--standalone-manifest` — esperado nesse modo (não há checkout
  git real do projeto de manifest, então o código que tenta ler o HEAD dele falha e cai num
  caminho de recuperação) e não impede o `repo init` de terminar com sucesso. Não é um erro.
- O `actions/cache` para `/tmp/kernel` pode exceder o limite de 10GB por repositório do GitHub
  Actions (o checkout completo, com toolchains, passou de 10GB localmente) — ver nota no próprio
  workflow YAML.
- O build completo via Bazel (`./tools/bazel run //common:kernel_aarch64_dist`) com a árvore
  pinada + patchada não foi rodado até o fim aqui (validei só a preparação da árvore: patch +
  config + manifest; o build em si já funcionava antes e não foi alterado por esta migração).

## Fora de escopo

`vendor/libkrun/src/devices/src/virtio/tpm/` (o lado host/VMM do mesmo recurso virtio-tpm) não foi
tocado nesta passada — ver nota em `patches/README.md`.
