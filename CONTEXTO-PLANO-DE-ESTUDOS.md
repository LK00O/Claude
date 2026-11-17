# Contexto do projeto — Plano de Estudos de História (Cap. 11 a 14)

Este arquivo resume tudo o que foi decidido no chat anterior, para que um chat novo continue o trabalho sem perder nada.

## O que é

Uma página interativa de estudo (HTML único) para o 2º ano do Ensino Médio (material Geekie One), colada no Google Sites pelo bloco **Inserir → Incorporar → Incorporar código**.

## Arquivos

| Arquivo | Para que serve |
| --- | --- |
| `plano-estudos-historia-cap11-14.html` | Código-fonte da página (versão atual) |
| `codigo-google-sites.txt` | Cópia idêntica em .txt, para abrir no Bloco de Notas, copiar tudo e colar no Google Sites |

Os dois arquivos precisam ficar sempre iguais: depois de editar o `.html`, copie-o para o `.txt`.

Branch: `claude/wonderful-curie-kui7y5` · PR: LK00O/Claude#2

## Regras técnicas obrigatórias

- **Um único arquivo** com `<style>` e `<script>` embutidos. Sem bibliotecas externas, só Google Fonts: **Plus Jakarta Sans** na interface e **Newsreader** nos títulos, citações e legendas.
- **JavaScript vanilla**, sem React nem Framer Motion, porque a página roda num iframe do Google Sites.
- **localStorage** protegido por `try/catch`. A chave atual é `planoHistoria_2s_cap11a14_resumo_v3`, e ela guarda **só** os tópicos lidos, as anotações por capítulo e a aba atual. A versão anterior (`..._leitura_v2`) tinha outros tópicos, por isso só as anotações dela são migradas.
- 100% responsivo, sem rolagem horizontal. Foi testado em 360 px.

## Conteúdo atual: 6 tópicos por capítulo, 24 no total

- Cada tópico tem 1 ou 2 parágrafos de resumo (82 a 110 palavras), com termos-chave em **negrito**, e **1 imagem** da Wikimedia Commons.
- Alguns tópicos têm um quadro curto: tabela comparativa, linha do tempo ou citação.
- Cap. 11: Era Napoleônica e Período Joanino
- Cap. 12: Independências dos EUA e do Haiti
- Cap. 13: **Independência do México (apresentação do grupo)**
- Cap. 14: Primeiro Reinado e Constituições do Brasil

### ⚠️ Regra estrita do Capítulo 13

O Cap. 13 trata **somente** da Independência do México e usa **exclusivamente** os dados da apresentação do grupo. Não acrescente outros países nem fatos externos. Os dados permitidos são:

- **Contexto:** Vice-Reino da Nova Espanha, a colônia mais rica da Espanha por quase 300 anos, desde a queda do Império Asteca diante de Hernán Cortés (1521). Economia de mineração (prata como principal minério, além de ouro, cobre e chumbo) e latifúndios (tabaco, cacau, algodão, milho e feijão).
- **Torre social:** peninsulares (gachupines, chamados chapetones no resto da América) no topo, com os cargos políticos; criollos no meio, ricos mas sem poder político; indígenas e mestiços na base, em pobreza, pagando tributos e explorados.
- **Causas:** Reformas Bourbônicas (mais impostos e perda de autonomia das elites); ideias iluministas (soberania popular, igualdade natural, rejeição ao absolutismo); exemplos da Independência dos EUA e da Revolução Francesa; identidade criolla (passado indígena e Virgem de Guadalupe). **Gatilho:** invasão napoleônica da Espanha em 1808 e deposição de Fernando VII.
- **Processo:**
  - Grito de Dolores (16/09/1810), do Padre Miguel Hidalgo: camponeses, indígenas e mestiços; fim da escravidão e dos tributos indígenas; Hidalgo foi excomungado e fuzilado em 1811.
  - Padre José María Morelos: *Sentimentos da Nação* (igualdade social, soberania popular, reforma agrária com divisão dos latifúndios); declarou a independência em 1813; executado em 1815.
  - Guerrilhas de Vicente Guerrero.
  - 1821: medo da Constituição liberal de Cádiz leva a elite criolla, o clero e Agustín de Iturbide a se unirem a Guerrero no Plano de Iguala (Três Garantias: independência, catolicismo como religião única e igualdade entre cidadãos), formando o Exército Trigarante.
  - Tratado de Córdoba (24/08/1821), com o vice-rei Juan O'Donojú.
  - Iturbide vira imperador Agostinho I (1822); perde apoio, enfrenta crise financeira e a oposição republicana de Guadalupe Victoria (veterano das lutas de Hidalgo e Morelos); abdica em 1823.
  - Constituição de 1824 cria a República Federal, com Guadalupe Victoria como primeiro presidente.
- **Consequências:** devastação econômica (minas e campos destruídos, fuga de capitais dos peninsulares, dívida com bancos britânicos); instabilidade e caudilhismo (líderes político-militares autoritários apoiados por tropas e latifundiários); ditadura de Porfirio Díaz a partir de 1876 (modernização com capital estrangeiro, concentração de terras, miséria camponesa); estopim da Revolução Mexicana de 1910, com Francisco I. Madero.

## Paleta (muda suavemente ao trocar de capítulo)

- Base: papel `#FAF9F6`, cards `#FFFFFF`, linhas `#E5E2DC`/`#E6E4DD`, texto `#18181B` e `#52525B`.
- Cap. 11: `#1B365D` + `#C68B2C` (fundo suave `#F0F4F8`)
- Cap. 12: `#14532D` + `#C2410C` (fundo suave `#F0FDF4`)
- Cap. 13: `#6B1D2F` + `#B8860B` (fundo suave `#FDF2F4`)
- Cap. 14: `#273043` + `#3F6212` (fundo suave `#F4F6F8`)

As cores são registradas com `@property`, por isso a transição entre capítulos fica suave.

## Design editorial (aprovado — não voltar ao "visual de dashboard")

- Cabeçalho tipográfico direto sobre o papel, sem banner colorido. A cor do capítulo aparece só na linha de 4 px no topo, no selo da disciplina e na barra de progresso fina (2 px).
- Tópicos em **lista editorial contínua** (índice), separados por linhas de 1 px, numerados `01`, `02`…, com um círculo discreto à direita para marcar como lido.
- Citações com filete lateral; tabelas e linhas do tempo com filetes finos, sem caixas pesadas.
- Botões "Expandir todos", "Recolher todos" e a gaveta "Anotações" em cada capítulo.
- O botão "Reiniciar leitura" fica no cabeçalho e abre uma confirmação, com a opção de apagar também as anotações.

## Animações (filosofia Emil Kowalski / skills `/animate` e `/emil-design-eng`)

- **Curvas:** `cubic-bezier(0.23, 1, 0.32, 1)` para entrar e sair; `cubic-bezier(0.77, 0, 0.175, 1)` para deslocamentos. **Nunca** usar `transition: all`, `ease-in` ou `scale(0)`.
- **Abas:** o destaque (fundo + sublinhado) desliza entre as abas, posicionado via `offsetLeft`/`offsetWidth`. Pelo teclado (setas, Home/End) a troca é instantânea, de propósito.
- **Troca de capítulo:** entrada em cascata com 35 ms entre os itens, combinando opacidade, `translateY(12px)` e `blur(4px)`.
- **Accordion:** `grid-template-rows: 0fr → 1fr`. A seta gira, a imagem assenta de `scale(1.03)` para `scale(1)` e o texto sobe depois. Ao fechar, tudo some rápido, sem atraso.
- **Marcar como lido:** o check é desenhado com `stroke-dashoffset`, os números sobem contando e a barra do capítulo dá um pulso.
- **Lightbox:** fundo com `backdrop-filter: blur(8px)` e entrada de `scale(0.94) translateY(8px)` para `scale(1)`.
- **Toque:** `:active` com `scale(0.98)`. Todo `:hover` fica dentro de `@media (hover: hover) and (pointer: fine)`.
- **Acessibilidade:** `prefers-reduced-motion` mantém só os fades.

## Imagens

- Toda `<img>` leva `referrerpolicy="no-referrer"` e `loading="lazy"`, e a página tem `<meta name="referrer" content="no-referrer">`.
- **Se a URL falhar:** 1ª tentativa de novo pelo nome do arquivo em `commons.wikimedia.org/wiki/Special:FilePath/<arquivo>?width=1200`. Na 2ª falha aparece uma **placa museológica** (fundo `#F3F1EC`, borda `#E2DFD7`, título em itálico e o link "Ver acervo original ↗").
- Imagens SVG da Commons usam a miniatura PNG (`/thumb/.../800px-....svg.png`).

## Vídeos ("Aulas em vídeo para aprofundar", no fim de cada capítulo)

- **Player leve:** primeiro aparece só a capa (`i.ytimg.com/vi/ID/hqdefault.jpg`). O `iframe` `youtube-nocookie.com/embed/ID?autoplay=1` só é criado no clique.
- O iframe usa `referrerpolicy="strict-origin-when-cross-origin"`, porque o YouTube exige o referenciador. Com `no-referrer`, o player dá erro.
- **Não usar** `embed?listType=search`, que o YouTube descontinuou em 2020 e só mostra erro.
- Os IDs reais vieram de busca na web e **não foram assistidos**, porque o ambiente bloqueava o YouTube:
  - Cap. 11: `0yzpJUObXmI` (Débora Aladim, Era Napoleônica e Congresso de Viena) e `RhMJRrj2JsM` (Débora Aladim, A vinda da Corte em 1808)
  - Cap. 12: `VCXJJ7vBO9w` (Débora Aladim, Independência dos EUA) e `XQXnixDXvjQ` (Brasil Escola, Independência do Haiti)
  - Cap. 13: `1AV88Wa9ooM` (aula em espanhol, La Independencia de México en 10 minutos), porque não foi encontrada aula em português
  - Cap. 14: `TzwFrYCd-6M` (Débora Aladim, Primeiro Reinado) e `DZNxnDldG6k` ("Aula de História: Tudo sobre as Constituições Brasileiras")
- Se um card ficar sem `id`, ele abre a busca no YouTube. Se a capa não existir, aparece o aviso e o link "Buscar esta aula ↗".

## Como a página é organizada no código

O `<script>` tem três partes:
1. **`CHAPTERS`:** os dados de cada capítulo (`id`, `num`, `short`, `title`, `sub`, `theme`, `objectives` e `topics`). Cada tópico tem `title`, `img`, `caption`, `text` (lista de parágrafos) e, opcionalmente, `boxes` com `quote`, `concept`, `compare` ou `timeline`.
2. **`VIDEOS`:** as videoaulas por capítulo (`channel`, `title`, `query`, `id`).
3. **Funções de renderização e eventos:** `renderTabs`, `renderChapter`, `renderTopic`, `renderVideos`, `toggleRead`, `imgFallback` e `playVideo`.

## Pendências e pontos de atenção

- Conferir no Google Sites se os 7 vídeos tocam e se as 24 imagens carregam. As que falharem devem ser trocadas pelos links corretos da Wikimedia Commons ou do YouTube.
- Se aparecer uma aula em português sobre a Independência do México, trocar o vídeo em espanhol.
- A Constituição de 1967 aparece como "Outorgada pelo regime militar". Alguns materiais usam "semioutorgada".
