#!/usr/bin/env python3
"""
Gera a versão de prévia a partir do index.html de produção.

A prévia é publicada numa página que já traz seu próprio esqueleto de documento,
então aqui removemos doctype, html, head e body e entregamos só o conteúdo.
Rodar sempre que o index.html mudar, para os dois nunca divergirem.
"""
import re
import pathlib

RAIZ = pathlib.Path(__file__).resolve().parent.parent
ORIGEM = RAIZ / "nova-balnearia" / "index.html"
DESTINO = RAIZ / "build" / "previa.html"

html = ORIGEM.read_text(encoding="utf-8")

cabeca = re.search(r"<head>(.*?)</head>", html, re.S).group(1)
corpo = re.search(r"<body>(.*?)</body>", html, re.S).group(1)

manter = []

# o título da prévia é o nome da marca; o título longo é para busca no site real
manter.append("<title>Nova Balneária</title>")

# a folha de estilo das fontes locais e o ícone continuam valendo
for padrao in (
    r'<link rel="stylesheet" href="assets/fontes\.css">',
    r'<link rel="icon"[^>]*>',
    r'<link rel="preload"[^>]*>',
):
    manter += re.findall(padrao, cabeca)

# o bloco de estilo inteiro
manter.append(re.search(r"<style>.*?</style>", cabeca, re.S).group(0))

saida = "\n".join(manter) + "\n" + corpo.strip() + "\n"

# na prévia a barra grudenta respeita a área segura do topo em celular
saida = saida.replace(
    ".nav{\n  position:sticky;top:0;z-index:60;",
    ".nav{\n  position:sticky;top:env(safe-area-inset-top,0px);z-index:60;",
)

DESTINO.write_text(saida, encoding="utf-8")

print(f"prévia gerada: {DESTINO}")
print(f"  {len(saida) / 1024:.1f} KB")
import re as _re
for tag in ("!doctype", "html", "head", "body"):
    assert not _re.search(r"<" + tag + r"[\s>]", saida, _re.I), f"sobrou <{tag}> na prévia"
print("  sem tags de documento duplicadas")
assert "<style>" in saida and "</style>" in saida
assert "wa.me" in saida and "MENU" in saida, "faltou o script com o cardápio e os links"
print("  estilo e conteúdo presentes")
