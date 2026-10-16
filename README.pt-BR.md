# Kompac

[English](README.md) · **Português**

Visualizador, extrator e compactador de arquivos para macOS, sem telemetria.
Abre ZIP, 7z, RAR (4 e 5, com senha), tar, tar.gz/tgz, tar.bz2, tar.xz/txz, zstd, ISO e DMG.
Cria só quatro: ZIP, 7z, tar.gz e tar.xz.

- **Fase 1 — leitura:** abrir, ver o conteúdo em árvore, prever texto sem extrair e extrair tudo
  ou só o que foi selecionado.
- **Fase 2 — compactar:** Arquivo › Novo (⌘N).

Código, comentários e identificadores estão em inglês; a interface está em inglês e
em português (ver [Idiomas](#idiomas)).

## Usar

```sh
./build.sh             # gera Kompac.app aqui
./build.sh --install   # e copia para /Applications (é a cópia que o "Abrir com" do Finder usa)
```

O `build.sh` carimba o número do build (nº de commits) e o commit (`KompacCommit`, com `-dirty` se
há arquivo versionado alterado) no `Info.plist`; os dois aparecem em Kompac › Sobre o Kompac.

**Deploy pelo Kommand (o comando de instalação do mantenedor):** o projeto declara
`production = "/km-instalar"`. A skill (`.claude/commands/km-instalar.md`) confere que o checkout
está no `main` e limpo, roda o `swift test`, faz o `./build.sh --install` e confere carimbo, ícone,
`7zz` e assinatura do que foi instalado. Não escreve no git.

Para abrir um arquivo, use o Finder (Abrir com › Kompac), arraste o arquivo para o ícone no Dock
ou use Arquivo › Abrir (⌘O). Os tipos estão registrados como alternativos, então o Kompac não vira
o app padrão sozinho. Para isso: Obter Informações › Abrir com › Kompac › Alterar Tudo.

- **Extrair selecionados (⌘E) / Extrair tudo (⇧⌘E):** o destino padrão é a pasta do arquivo.
  Se sai um único item (uma pasta ou um arquivo), ele vai direto para o destino; se saem vários,
  vão para uma subpasta com o nome do arquivo compactado. Nada é sobrescrito: se o nome existir,
  vira "nome 2". O 7zz extrai primeiro numa pasta oculta `.kompac-…` ao lado do destino, e por isso
  cancelar ou dar erro não deixa extração pela metade.
- **Prévia:** clicar num arquivo mostra os primeiros 16 KB se for texto, lidos para a memória
  (`7zz e -so`). Se não for texto, mostra o tipo e o tamanho.
- **Nomes em:** ZIPs do Windows sem a marca de UTF-8 gravam os nomes em CP850/CP437 ou
  Windows-1252, e aparecem como "Relat≤rio". O modo automático detecta a página e corrige,
  inclusive nos nomes gravados no disco ao extrair.
- **Senha:** é pedida num painel dentro da janela, ao abrir (nomes cifrados) ou ao extrair.

### Compactar (Arquivo › Novo, ⌘N)

Abre uma janela vazia: arraste arquivos e pastas para ela (ou use Escolher…). Cada item entra no
topo do arquivo com o próprio nome.

| Formato | Para quê | Senha |
|---|---|---|
| **ZIP** (padrão) | máxima compatibilidade | AES-256; **só ASCII** (limite do 7zz: com acento ou €, ele recusa) |
| **7z** | máxima compressão | AES-256, com opção de **cifrar os nomes** (`-mhe=on`); aceita acentos |
| **tar.gz** | servidores Linux | não tem |
| **tar.xz** | Linux, menor tamanho | não tem |

- Compressão: Rápido (`-mx=1`), Normal (`-mx=5`), Máximo (`-mx=9`).
- Nome e destino: o padrão é o nome do item (vários itens: "Arquivo") e a pasta dos originais.
  Nada é sobrescrito: se o nome existir, vira "Arquivo 2.zip". (Com a interface em inglês, o nome
  padrão é "Archive".)
- Nunca entram `.DS_Store`, `._*` (resource forks) nem `__MACOSX` (`-xr!…` no 7zz).
- 7z pode ser dividido em partes (`nome.7z.001`, `.002`…). O ZIP dividido do 7zz não é o padrão
  `.z01` do Windows, por isso não é oferecido.
- O 7zz grava num arquivo oculto `.kompac-…` no destino, que só no fim recebe o nome escolhido.
  Cancelar ou dar erro apaga o parcial (e as partes).
- tar.gz/tar.xz: dois 7zz ligados por pipe (`a -ttar -so` → `a -tgzip -si`/`-txz -si`), sem .tar
  intermediário no disco.
- O 7zz 26.04 **não cria** zstd (`E_NOTIMPL`), só lê.

### Pelo Finder (botão direito)

Dois itens no menu de qualquer arquivo ou pasta:

- **Compactar em “nome.zip”:** ZIP, nível Normal, ao lado dos originais, sem perguntar nada. A
  janela só mostra o progresso e fecha ao terminar; com erro ou aviso do 7zz, fica aberta com o
  aviso.
- **Compactar com o Kompac…:** abre a janela Novo com os itens selecionados.

É uma extensão do Finder (`Contents/PlugIns/KompacFinder.appex`, tipo FinderSync, o mesmo que
outros compactadores usam para pôr itens ali). O Finder só a carrega dentro da sandbox, e a sandbox
não a deixa rodar o 7zz nos arquivos do usuário: ela só monta um endereço
`kompac://compress?action=zip|window&path=…` (`FinderRequest`) e o abre com o Kompac.app em que
mora. O `build.sh --install` a registra e liga (`pluginkit -e use`), porque extensões do Finder de
terceiros começam desligadas; para desligar: Ajustes do Sistema › Geral › Itens de Início e
Extensões › Finder. Se o menu não aparecer logo depois de instalar: `killall Finder`.

## Estrutura

| Pasta | O quê |
|---|---|
| `Sources/KompacCore` | núcleo sem UI: roda o `7zz`, lê `7zz l -slt`, extrai e compacta (`Compression.swift`) com progresso (`-bsp1`) e cancelamento, faz a prévia e converte nomes |
| `Sources/Kompac` | app AppKit + SwiftUI, um `NSDocument` somente leitura por arquivo aberto; a janela Novo (`CompressView`/`CompressModel`) não é documento |
| `Sources/KompacFinder` + `FinderExtension/` | a extensão do Finder (menu do botão direito): código, o `Info.plist` dela e a permissão de sandbox |
| `Resources/<idioma>.lproj` | textos da interface (`Localizable.strings`) e nomes dos tipos de documento (`InfoPlist.strings`), uma pasta por idioma |
| `Tests/KompacCoreTests` | `swift test`; as fixtures são geradas por `Tests/make-fixtures.sh` |
| `icon/` | `kompac.svg` (desenho), `kompac-16.svg` (desenho de 16 px) e `Kompac.icns` (versionado); `make-icon.sh` regera o .icns quando o desenho muda |
| `.claude/commands/km-instalar.md` | o deploy: do `main` para `/Applications` |
| `vendor/7zz` | 7-Zip 26.04 oficial para macOS (universal), de https://www.7-zip.org |
| `Resources/7zip-LICENSE.txt` | licença do 7-Zip (GNU LGPL + restrição unRAR), copiada para dentro do app |

## Idiomas

A interface segue o idioma do macOS: inglês por padrão, português (pt-BR) disponível. Os textos
ficam em `Resources/<idioma>.lproj/Localizable.strings`, com o texto em inglês como chave
(`NSLocalizedString("Extract", …)` no código); os nomes dos tipos de documento ficam em
`InfoPlist.strings`, na mesma pasta. O `build.sh` se recusa a compilar se alguma chave usada no
código faltar em algum idioma.

Para acrescentar um idioma:

1. Copie `Resources/en.lproj` para `Resources/<idioma>.lproj` (por exemplo `es.lproj`).
2. Traduza os valores (o lado direito do `=`) em `Localizable.strings` e `InfoPlist.strings`;
   deixe as chaves como estão.
3. Acrescente o código do idioma em `CFBundleLocalizations` no `Info.plist`.

## Motor: 7zz

O Kompac usa o binário de terminal oficial do 7-Zip em vez do libarchive do sistema. O 7zz abre
RAR5 com senha e cria 7z com nomes cifrados, e o libarchive não faz nenhuma das duas coisas.

- Versão 26.04 (2026-10-05), `7z2604-mac.tar.xz` do GitHub oficial (ip7z/7zip).
  SHA-256 do pacote: `bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578`;
  SHA-256 do `7zz`: `36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577`.
- Para atualizar, troque `vendor/7zz` e `Resources/7zip-LICENSE.txt` e rode `swift test`.
- Comportamentos conferidos no 26.04, dos quais o código depende:
  - Nome que não é UTF-8 válido vira U+EF00+byte (0xF3 → U+EFF3), na listagem e no disco.
    A opção `-mcp=` não muda isso no Mac, então a conversão é feita no núcleo.
  - O xz não grava o nome de dentro: o 7zz lista o item sem `Path`, e o tar é reconhecido pelo
    nome de fora (`x.tar.xz`).
  - Na criação, `-p` vazio faz o 7zz pedir a senha no teclado: sem senha, o `-p` não é passado.
  - O 7zz só enxerga a camada de fora de um tar.gz. Por isso tar.gz/xz/bz2/zst passam por dois
    7zz ligados por pipe (`x -so` → `l`/`x -si -ttar`).
  - DMG: o 7zz abre a imagem APFS de dentro. `-sns-` evita arquivos `nome:com.apple.provenance`.

Testes: `swift test`. Para testar também um RAR real e grande, aponte `KOMPAC_REAL_RAR` para ele:
`KOMPAC_REAL_RAR=/caminho/grande.rar swift test` roda o teste de listagem. A extração completa só
roda com `KOMPAC_REAL_RAR=/caminho/grande.rar KOMPAC_BIG_EXTRACT=<pasta temporária> swift test --filter realRARExtraction`;
ela confere que cada arquivo listado sai com o tamanho listado e apaga o que extraiu no fim.

Autoteste do app pelo Launch Services (o mesmo caminho do Finder), que lista e sai:
`open -n -W -a Kompac.app --env KOMPAC_SELFTEST=/tmp/saida.txt arquivo.zip`
(com `--env KOMPAC_SELFTEST_PASSWORD=…` para um arquivo com senha).

Autoteste da janela Novo, que compacta e sai:
`open -n -W -a "$PWD/Kompac.app" --env KOMPAC_SELFTEST_COMPRESS=/tmp/saida.txt --env "KOMPAC_SELFTEST_SOURCES=/caminho/pasta|/caminho/arquivo" --env KOMPAC_SELFTEST_FORMAT=7z`
(formatos: `zip`, `7z`, `tar.gz`, `tar.xz`; `KOMPAC_SELFTEST_PASSWORD` opcional).

## Licença

[MIT](LICENSE), © 2026 Kogumelo Informática Ltda. Use, copie e modifique à
vontade, mantendo o aviso de copyright. O código vem sem garantia.

As partes de terceiros mantêm a licença de origem: o motor 7-Zip embutido (`vendor/7zz`) é
© Igor Pavlov, sob GNU LGPL com a restrição unRAR (`Resources/7zip-LICENSE.txt`, copiado
também para dentro do app), e os RAR de teste em `Tests/KompacCoreTests/Fixtures/` vêm do
libarchive, sob licença BSD (`SOURCE.txt` ao lado).
