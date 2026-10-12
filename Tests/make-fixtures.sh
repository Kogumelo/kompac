#!/bin/zsh
# Generates the fixtures in Tests/KompacCoreTests/Fixtures (run it again only if they need recreating).
# The RARs come from libarchive's test suite (BSD-2 license, see Fixtures/SOURCE.txt):
# 7zz cannot create RAR.
set -e
cd "$(dirname "$0")"
F=$PWD/KompacCoreTests/Fixtures
Z=$PWD/../vendor/7zz
W=$(mktemp -d)
trap 'rm -r "$W"' EXIT
export COPYFILE_DISABLE=1   # no macOS ._ files inside the tars

# ZIP with names in a code page (without the UTF-8 flag), the way Windows writes them.
# Python's zipfile only writes ASCII or UTF-8: write a placeholder name of the same length
# in bytes and swap the bytes afterwards.
cat > $W/mk.py <<'PY'
import sys, zipfile
def mk(path, names, enc):
    ph = [''.join(chr(c) if c < 128 else '#' for c in n.encode(enc)) for n in names]
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for p, n in zip(ph, names):
            z.writestr(p, ("conteudo de " + n + "\n").encode('utf-8') * 3)
    data = open(path, 'rb').read()
    for p, n in zip(ph, names):
        data = data.replace(p.encode('ascii'), n.encode(enc))
    open(path, 'wb').write(data)
out = sys.argv[1]
mk(out + '/w1252.zip', ['Relatório de notas.txt', 'Configuração.ini', 'Atenção/leia.txt'], 'cp1252')
mk(out + '/cp850.zip', ['Relatório.txt', 'Matrícula 2026/Configuração.ini'], 'cp850')
PY
python3 -I $W/mk.py $F

# 6 loose files at the root
mkdir -p $W/six && for i in 1 2 3 4 5 6; do echo "arquivo $i" > $W/six/f$i.txt; done
(cd $W/six && $Z a -bso0 -bsp0 $F/six.zip f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt)

# a single folder at the root
mkdir -p $W/root/Projeto/sub && echo a > $W/root/Projeto/sub/a.txt && echo b > $W/root/Projeto/b.txt
(cd $W/root && $Z a -bso0 -bsp0 $F/single.zip Projeto)

# 7z with encrypted names (-mhe), password "segredo"
mkdir -p $W/enc/pasta && echo oi > $W/enc/a.txt && echo ola > $W/enc/pasta/b.txt
(cd $W/enc && $Z a -bso0 -bsp0 -psegredo -mhe=on $F/enc.7z a.txt pasta)

# tar.gz with "./" at the start of the paths (as the system tar does)
mkdir -p $W/tgz/docs && printf 'Olá, tar!\nlinha 2\n' > $W/tgz/docs/leia.txt && echo x > $W/tgz/x.txt
tar -czf $F/docs.tar.gz -C $W/tgz .

echo "OK: $F"
