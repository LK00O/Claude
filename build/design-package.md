# Pacote de design: Nova Balneária

## 1. A premissa da marca

Uma ideia só: **estar aberto**. A Nova Balneária abre às 6 e fecha às 22, todos os dias,
sem exceção. Esse é o fato real que sustenta o site inteiro. A página é uma travessia do
dia: o primeiro pão da manhã, o balcão cheio do meio-dia, o café do fim da tarde, a luz
ainda acesa às 22h. Cada seção serve essa ideia. O que não serve, sai.

Consequência de design: o site sabe que horas são para o visitante e responde a isso ao
vivo. Essa é a assinatura, e ela é útil, não decorativa.

## 2. A paleta

Padaria à beira-mar. O azul profundo é a Balneária, o dourado é a crosta do pão.
Fugimos de propósito do lugar-comum creme com serifada e terracota: a tinta principal
é azul-mar, não marrom, e a face de display é uma grotesca com personalidade, não uma
serifada elegante.

```css
:root{
  --canvas:#FAF6EE;        /* papel morno, nunca branco puro */
  --canvas-2:#F2E9DA;      /* faixa mais funda */
  --deep:#0E2C3A;          /* mar profundo, seções invertidas e o herói */
  --deep-2:#16414F;
  --panel:#FFFDF8;         /* cartões */
  --ink:#102E3C;
  --ink-soft:#57707D;
  --line:#E2D6C2;
  --zap:#1EA65A;           /* a chamada, família WhatsApp, escurecida para contraste */
  --zap-hover:#178A4A;
  --warm:#E4671B;          /* marcador de aberto agora, doses raras */
  --warm-soft:#F6C79B;
}
```

Disciplina do acento: verde significa "fale com a gente" e aparece só em botão de
WhatsApp. Laranja significa "estamos abertos agora" e aparece só no marcador ao vivo.
Nenhum dos dois é decoração.

## 3. O trio tipográfico

- **Display:** Bricolage Grotesque, pesos 600 e 800. Tem quirk, lembra letreiro de
  padaria, não é Inter nem Roboto.
- **Corpo:** Karla, 400 e 600. Quieta, boa com acentuação portuguesa.
- **Mono:** DM Mono, 400 e 500. Os preços vivem aqui, e alinham em coluna.

## 4. O mapa de faixas do herói (a travessia do dia)

Sem vídeo, a "filmagem" é o próprio dia, desenhado em gradiente e movido pelo scroll.
Nada disso depende de foto, então nada fica borrado. O arco do sol cruza o céu conforme
a pessoa rola.

| Faixa | Faixa de progresso (ponto de partida) | O que o fundo faz | Texto (verbatim) | Entrada |
|---|---|---|---|---|
| 1 | 0,00 a 0,20 | Azul noite cedendo ao primeiro dourado no horizonte | kicker "6H" / "O primeiro pão do dia." / "A gente abre cedo porque tem gente que começa mais cedo ainda." | Subida palavra a palavra, com rampa de carga na abertura |
| 2 | 0,22 a 0,46 | Céu alto de meio-dia, luz dura | kicker "MEIO-DIA" / "O balcão enche." / "Misto quente, churrasco no pão francês, suco batido na hora." | Soco por palavra, com passagem do ponto |
| 3 | 0,48 a 0,72 | Hora dourada, sombras longas | kicker "FIM DA TARDE" / "Café e uma fatia de torta." / "A de frango sai inteira ou na fatia. Você escolhe." | Desfoque que entra em foco |
| 4 | 0,74 a 0,90 | Noite, com a luz da padaria acesa | kicker "22H" / "Ainda aberto." / "Todo dia. Sem exceção." | Caracteres espalhados que se juntam |
| settle | 0,92 a 1,00 | Noite assentada, texto em repouso | "Nova Balneária" / "Padaria e restaurante. Vila Antártica, Praia Grande." / dois botões | Chegada em três tempos: nome, linha, botões |

Os números são pontos de partida, validados depois pelo teste do peteleco.

## 5. O bloco do herói estático

Para celulares e para quem pede menos movimento. O gradiente do céu reflete a hora real
do visitante, então a assinatura continua funcionando ali.

- Selo ao vivo: "Aberto agora" ou "Abrimos às 6h"
- Nome: Nova Balneária
- Linha: "Padaria e restaurante na Vila Antártica. Todo dia, das 6h às 22h."
- Botões: "Pedir no WhatsApp" e "Ver o cardápio"

## 6. As seções depois do settle

Todas afunilam para uma só chamada: falar no WhatsApp com a mensagem já escrita.

1. **Agora na Balneária.** Lê o relógio do visitante e mostra o que é bom naquela hora.
   O pagamento da assinatura.
2. **Os destaques.** X-balnearia (o lanche da casa), torta de frango, pão francês,
   coxinha, pizza, pudim. Cartões com as fotos pequenas, no tamanho em que são nítidas.
3. **Monte seu pedido** (o momento interativo). A pessoa toca nos itens, eles caem numa
   bandeja, e um botão só manda tudo pro WhatsApp já escrito, item por item. Encena a
   ideia da marca: o balcão. Movimento reduzido recebe o estado final direto.
4. **O cardápio inteiro.** 82 itens, com busca e filtro por seção, foto pequena onde
   existe, preço em mono. Aviso de preço no topo da seção.
5. **Como pedir.** Três passos, cada um com sua ilustração em SVG desenhada à mão.
6. **Onde ficamos.** Endereço, horário, telefone, link do mapa.
7. **Perguntas.** Só o que eu sei de fato. O que eu não sei vira botão de WhatsApp.
8. **Rodapé.** Contato, horário, endereço e o aviso de preço.

### Microtexto do aviso de preço (verbatim)

"Os preços são os do delivery. No balcão costuma sair mais barato. Confirme no WhatsApp
antes de vir."

### O formulário

Não existe. A chamada é o WhatsApp, que é onde a venda acontece de verdade nesse ramo.
Site estático não tem para onde mandar formulário, e um botão que abre a conversa com a
mensagem pronta converte muito mais que um campo de email.

## 7. A camada de vetores

Desenhados à mão em SVG, nada de biblioteca:

- O arco do sol e da lua que cruza o herói conforme o scroll.
- A barra do dia: uma régua de 6h a 22h com o marcador da hora atual, ao vivo.
- Três ilustrações de linha para o "Como pedir": o dedo que toca, a bandeja, a conversa.
- Um friso de onda que se desenha sozinho na entrada das seções, ligando o mar ao nome.
- Partículas de farinha em nível sussurro sobre o herói.

Tudo honra movimento reduzido: estados finais mostrados, motores parados.

## 8. A lista de engenharia

Loop rAF normalizado por dt que descansa quando converge, escritas no DOM só quando
mudam, faixas com smoothstep e plateau longo, os cinco portões do herói estático vivos
nos dois sentidos, movimento reduzido honrado ao vivo nos dois sentidos, overflow-x clip
em html e body, entradas coreografadas com IntersectionObserver e atrasos aposentados
depois, um elemento vivo por seção em nível sussurro, animações pausadas em aba oculta,
marcos semânticos e link de pular, foco visível, alvos de toque de 44px, favicon SVG
embutido, e as tags og com o comentário DEPLOY STEP para preencher na publicação.

## 9. O portão da escrita

Todo texto acima vai para a página exatamente como está. A página construída precisa
passar no portão da Fase 9 antes de qualquer pessoa ver: zero travessões, zero palavras
de catálogo corporativo, e a varredura dos vícios de texto de IA.
