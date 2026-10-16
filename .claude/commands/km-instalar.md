---
description: Instala o Kompac novo em /Applications — confere que o checkout está no main e limpo, roda os testes, compila com ./build.sh --install e confere o carimbo e o ícone do que foi instalado.
argument-hint: (ignorado) o Kommand passa o ref; instala-se sempre o main do checkout principal
allowed-tools: Bash
---

# /km-instalar — trocar o Kompac de /Applications pelo build do main

Use depois do merge, quando o que está no `main` precisa virar o app que o
Finder abre. É o que o botão de deploy do Kommand dispara.

Você **confere, compila e instala**. Não escreve no git: não faz merge, não
commita, não faz push. **Se um portão falhar, pare e diga qual** — não conserte
por conta própria.

O repositório é `~/Kogumelo/Ferramentas/Kompac`. Os blocos abaixo chamam esse
caminho de `$R`, e todo comando roda com `-C "$R"` ou dentro de `$R` — também
quando você foi chamado de dentro de uma worktree:

```
R=~/Kogumelo/Ferramentas/Kompac
```

`$ARGUMENTS` (o ref que o Kommand manda) não escolhe o que se instala: aqui o
merge já foi feito pelo botão de merge, e o que vai para /Applications é sempre
o `main` do checkout principal. Se `$ARGUMENTS` não for `main` nem vazio, avise
e siga com o `main`.

## 1. Ramo e limpeza

```
git -C "$R" branch --show-current                                                    # tem que ser main
git -C "$R" diff --quiet HEAD && echo LIMPO                                          # tem que sair LIMPO
git -C "$R" status --porcelain -- Sources Resources vendor Info.plist Package.swift icon FinderExtension   # tem que sair VAZIO
```

- **Fora do `main`:** pare. O Sobre o Kompac mostra o commit de onde o build
  saiu; um build de branch põe lá um hash que o `main` não tem.
- **Arquivo versionado alterado:** pare e liste. O build sairia com `-dirty` no
  carimbo, e o app instalado não corresponderia a commit nenhum.
- **Arquivo não versionado em `Sources/`, `Resources/` ou `vendor/`:** pare
  também. O Swift compila tudo o que está em `Sources/` e o `build.sh` copia o
  `vendor/7zz` e as pastas `Resources/*.lproj` inteiras (`en` e `pt-BR`), versionados ou não — e
  o `git diff` não vê esse caso, por isso o terceiro comando. Não versionado
  fora dessas pastas (anexos, `.DS_Store`) não entra no app e não barra nada.

## 2. Testes do núcleo

```
swift test --package-path "$R"
```

Qualquer falha = pare. Os autotestes do app (`KOMPAC_SELFTEST`,
`KOMPAC_SELFTEST_COMPRESS`) abrem janelas na tela do operador: **não** rode
aqui. A extração de 3 GB (`KOMPAC_BIG_EXTRACT`) também não.

## 3. Guardar o que está instalado e instalar

```
plutil -extract KompacCommit raw /Applications/Kompac.app/Contents/Info.plist 2>/dev/null || echo "(sem carimbo: primeira instalação ou build anterior ao git)"   # guarde: ANTERIOR
"$R/build.sh" --install
```

O `--install` troca `/Applications/Kompac.app` e o registra de novo no Launch
Services, que é o que faz o "Abrir com" do Finder pegar o ícone e os tipos de
arquivo novos.

## 4. Conferir o que foi instalado

```
plutil -extract KompacCommit raw /Applications/Kompac.app/Contents/Info.plist   # = hash curto do HEAD, sem -dirty
git -C "$R" rev-parse --short HEAD
ls /Applications/Kompac.app/Contents/Resources/Kompac.icns                      # tem que existir
ls /Applications/Kompac.app/Contents/Resources/en.lproj/Localizable.strings     # tem que existir
/Applications/Kompac.app/Contents/Resources/7zz i | head -3                     # o motor tem que rodar (7-Zip 26.04)
codesign --verify /Applications/Kompac.app && echo ASSINATURA-OK
pluginkit -m -v -i br.com.kogut.kompac.finder                                    # uma linha só, com "+" e o caminho em /Applications
```

- carimbo diferente do HEAD, ou com `-dirty`: algo escapou do passo 1 — diga o quê;
- sem `Kompac.icns`: o "Abrir com" mostra o quadrado branco (o defeito que o
  Konfig teve em 12/10/2026);
- sem `en.lproj/Localizable.strings`: a interface sai só com as chaves, sem a
  tradução — o `build.sh` não copiou `Resources/*.lproj`;
- o `7zz` não roda: o app abre mas não lista nem extrai nada — pare e relate;
- a extensão do Finder sem `+`, com caminho fora de `/Applications` ou em mais
  de uma linha: o botão direito do Finder fica sem "Compactar em …zip" e
  "Compactar com o Kompac…", ou aponta para uma cópia de teste — diga qual caso.

## Saída (em português)

Um bloco curto: ✅/⚠️ por portão, o commit instalado e o ANTERIOR, e o que
entrou entre os dois (`git -C "$R" log --oneline <ANTERIOR>..HEAD`, quando havia
carimbo). Se o `build.sh` avisou que o Kompac está aberto, repita o aviso: a
versão velha segue rodando até o operador fechar (⌘Q) e abrir de novo. Se o
Finder ainda mostrar o ícone antigo, a saída é `killall Finder`.
