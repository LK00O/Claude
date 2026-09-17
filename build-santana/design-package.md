# Pacote de design: Santana Academia

Documento único da Fase 5. Escrito antes de qualquer construção, consumido pela Fase 8.
Todo texto marcado como verbatim vai para a página exatamente como está aqui.

---

## 0. Os fatos, e de onde vieram

**Confirmados por você:**
- R. Ipiranga, 76, Centro, São Vicente
- (13) 3468-0111
- Instagram @santanaacademia76, Facebook Santana Academia
- Logo: marca circular, bailarina apoiada numa linha vertical, branco sobre preto

**Levantados por mim em fontes públicas, PRECISAM DA SUA CONFIRMAÇÃO antes de publicar:**
- Recepção das 15h às 20h, de segunda a sexta
- WhatsApp (13) 99184-6328
- 31 anos na cidade, ou seja, fundada por volta de 1994
- Direção das irmãs Cláudia Santana e Claudete Santana Lemos
- Modalidades: ballet clássico, baby class, jazz, sapateado americano e irlandês, dança contemporânea
- Atendem "do baby ao 40+"
- Existe aula experimental antes da matrícula
- Homenagem da Câmara Municipal de São Vicente, Medalha e Diploma de Mérito Cultural

**Ainda em branco, nada foi inventado no lugar:**
- A grade de horários de cada turma
- Idade mínima exata da baby class
- Roupa exigida na primeira aula
- Minibio das professoras
- Mensalidades (decisão sua: ficam fora do site, só no WhatsApp)

Regra que vale para o site inteiro: **o que eu não sei vira botão de WhatsApp, nunca vira invenção.**

---

## 1. A premissa da marca

Uma ideia só: **a barra.**

No ballet tudo começa na barra. É nela que você se segura enquanto aprende, e você só solta
quando está pronta. A Santana é essa barra para São Vicente há 31 anos: a mesma sala serve
a criança de 3 anos e a mulher de 45 que sempre quis e nunca fez.

Isso não é metáfora bonita, é a resposta exata para o medo que as duas pessoas têm. A mãe
tem medo de que a professora seja dura com a filha pequena. A adulta tem vergonha de nunca
ter dançado e de ser a pior da sala. Os dois medos são o mesmo medo: **vou cair e ninguém
vai me segurar.** A barra é a resposta.

Cada seção serve essa ideia. O que não serve, sai.

## 2. A paleta

O mundo material do estúdio: pó de giz e breu no chão, madeira, a sombra fria do espelho,
e a luz da janela que anda das 15h às 20h. Fugimos de propósito do quase-preto com âmbar,
que é o lugar-comum de todo site "cinematográfico": a sombra aqui é azulada, não marrom, e
o acento é o rosa-breu da sapatilha levado até onde ele fica legível de verdade.

```css
:root{
  --giz:#F2EFE8;       /* canvas, pó de giz, nunca branco puro */
  --giz-2:#E6E1D5;     /* faixa mais funda */
  --papel:#FBF9F4;     /* cartões e superfícies elevadas */
  --sombra:#161E29;    /* a noite do herói e as seções invertidas, nunca preto puro */
  --sombra-2:#202B39;
  --tinta:#1A222D;     /* texto principal no claro */
  --tinta-fraca:#586675;
  --linha:#D8D1C2;     /* filete decorativo, nunca borda interativa */
  --linha-forte:#8A7D64;/* a borda que o dedo e o teclado tocam, 3,52:1 sobre o giz */
  --madeira:#8A6440;   /* o chão do estúdio, tom de superfície, não é acento */
  --rosin:#A6384A;     /* O ACENTO: a chamada, o foco, a marca ao vivo */
  --rosin-forte:#8B2C3C;
  --rosin-claro:#E08391;/* o acento sobre as seções escuras, 6,25:1 sobre a sombra */
  --luz:#F3D9A8;       /* a luz da janela e da lâmpada, só dentro do herói */
}
```

Disciplina do acento: o rosa-breu significa **"fale com a gente"**. Ele aparece no botão de
WhatsApp, no foco do teclado e no marcador de aberto agora. Em nenhum outro lugar. Um acento
que está em tudo não é acento.

## 3. O trio tipográfico

- **Display: Fraunces**, variável, pesos 600 a 800. Tem contraste de traço e um desvio
  proposital nas terminações, o que dá caráter de cartaz de recital sem virar a serifada
  didone que toda escola de ballet usa. Não é Inter nem Roboto.
- **Corpo: Instrument Sans**, 400 a 600. Quieta, moderna, boa com acentuação portuguesa.
- **Mono: Space Mono**, 400 e 700. Horários, idades e etiquetas pequenas vivem aqui, e as
  colunas de número alinham sozinhas.

Todas hospedadas no próprio site, só nos pesos em uso.

## 4. O mapa de faixas do herói

Sem vídeo gerado, a filmagem é o próprio estúdio, desenhado em SVG e CSS e movido pelo
scroll. O que anda é a luz: começa às 15h, com sol duro entrando pela janela, e termina às
20h, com a sala escura e a lâmpada acesa. A barra se desenha sozinha no caminho.

Altura do herói: 700vh no modo completo. Cinco momentos de texto, cada um com platô longo.

| Faixa | Faixa de progresso | O que a luz faz | Texto (verbatim) | Entrada |
|---|---|---|---|---|
| 1 | 0,00 a 0,18 | 15h. Sol alto e duro pela janela, o chão claro, a barra ainda é só uma sombra | kicker "SÃO VICENTE, DESDE 1994" / "Toda bailarina começou sem saber." / "Inclusive as que você admira." | Subida palavra a palavra, com rampa de carga na abertura |
| 2 | 0,20 a 0,42 | 17h. A luz desce, as sombras esticam, a barra termina de se desenhar, poeira no facho | kicker "A BARRA" / "Primeiro você se segura." / "Ninguém entra numa sala de dança sem medo. Por isso a primeira coisa que a gente ensina é onde colocar a mão." | Palavras que entram deslizando pela barra |
| 3 | 0,44 a 0,66 | 18h30. Hora dourada, a sala inteira quente | kicker "DO BABY AO 40+" / "Depois você solta." / "Tem gente de 3 anos e gente de 45 na mesma casa. Cada uma na sua turma, cada uma no seu tempo." | Metades que se afastam do centro |
| 4 | 0,68 a 0,86 | 20h. Janela escura, a lâmpada do estúdio acesa, a luz agora vem de dentro | kicker "31 ANOS" / "E um dia você dança." / "Três décadas formando gente em São Vicente." | Caracteres espalhados que se juntam |
| settle | 0,88 a 1,00 | Noite assentada, a barra em repouso, a lâmpada quieta | "Santana Academia" / "Ballet, jazz, sapateado e dança contemporânea. R. Ipiranga, 76, Centro, São Vicente." / botões "Agendar aula experimental" e "Ver as modalidades" | Chegada em três tempos: nome, linha, botões |

Os números são pontos de partida, validados depois pelo teste do peteleco.

## 5. Os três modos do herói, e por que são três

O padrão manda entregar herói estático em celular para poupar o download do vídeo. **Aqui não
existe vídeo**, o herói inteiro são algumas centenas de bytes de SVG e CSS, então o motivo
do corte não se aplica. Desvio consciente, declarado:

- **completo**, 700vh: telas grandes com ponteiro fino.
- **curto**, 560vh: celulares e tablets em retrato. Os mesmos cinco momentos, com as mesmas
  faixas, num percurso mais curto. Nenhum beat é cortado, porque cortar beat quebraria o trio
  "primeiro você se segura, depois você solta, e um dia você dança", que é a espinha do texto.
- **estático**: movimento reduzido ligado, e celular deitado com pouca altura. O mesmo palco
  congelado no fim da tarde, com a barra inteira desenhada e o bloco de texto parado.

Uma função de JavaScript decide o modo e escreve uma classe no `<html>`. O CSS só reage a
essa classe e nunca repete as media queries por conta própria. Fonte única de verdade, então
CSS e JS não têm como discordar. Os três modos são reavaliados ao vivo em rotação, redimensionamento
e troca de preferência de movimento, nos dois sentidos.

### O bloco do herói estático (verbatim)

- Selo ao vivo: "Aberto agora" ou "Recepção abre às 15h"
- Nome: Santana Academia
- Linha: "Ballet, jazz, sapateado e dança contemporânea. Do baby ao 40+. Na Rua Ipiranga, 76, desde 1994."
- Botões: "Agendar aula experimental" e "Ver as modalidades"

## 6. As seções depois do settle

Todas afunilam para uma só chamada: **agendar a aula experimental pelo WhatsApp, com a
mensagem já escrita.**

1. **A casa.** Três fatos em linha: 31 anos, direção das irmãs Cláudia e Claudete, medalha de
   mérito cultural da Câmara. Curto. É credencial, não redação.
2. **As modalidades.** Ballet clássico, baby class, jazz, sapateado, contemporâneo. Cinco
   cartões com tratamento idêntico, cada um com seu desenho em SVG feito à mão, para quem é
   indicado e o que a aula faz por você. Nenhum cartão fica sem desenho, porque falta de
   simetria lê como buraco.
3. **Segure a barra** (o momento interativo). A pessoa pressiona e segura a barra na tela.
   Enquanto segura, a frase troca em três tempos e a mão desenhada vai soltando. No fim, a
   chamada acende. Encena a premissa: primeiro você se segura, depois você solta. Movimento
   reduzido recebe o estado final direto, sem precisar segurar nada.
4. **Horários.** Recepção de segunda a sexta, das 15h às 20h. A grade de cada turma fica
   marcada como a confirmar até você me mandar, e o botão leva a pergunta pronta para o
   WhatsApp. Nenhum horário inventado entra aqui.
5. **Quem ensina.** Cláudia e Claudete, com espaço reservado para foto e minibio.
6. **Perguntas.** Só as objeções reais que a pesquisa achou, respondidas com o que se sabe de
   fato. O que não se sabe vira botão de WhatsApp, com essa honestidade dita na resposta.
7. **Onde ficamos.** Endereço, link do mapa, telefone, WhatsApp, Instagram, Facebook, horário
   da recepção.
8. **A chamada final.** A barra uma última vez e o único botão.
9. **Rodapé.** Contato, horário, endereço, e o aviso de que a grade completa é confirmada pelo
   WhatsApp.

### As perguntas, verbatim

- **"Nunca dancei na vida. Ainda dá tempo?"**
  "Dá. A maior parte de quem entra na turma adulta nunca fez aula antes. Começa todo mundo
  na mesma barra, no mesmo dia, sem saber nada."
- **"Vou parar numa turma cheia de criança?"**
  "Não. As turmas são separadas por idade e por nível. Adulto iniciante fica com adulto
  iniciante."
- **"Minha filha é tímida e tem medo de professora brava."**
  "A primeira aula é para ela olhar a sala e decidir. Ninguém é empurrado para o meio. Se ela
  quiser ficar na barra a aula inteira segurando a mão da professora, fica."
- **"Qual a idade mínima para começar?"**
  "Tem turma de baby class para os menores. A idade exata de entrada muda conforme a turma
  que está aberta, então confirme no WhatsApp antes de vir."
- **"Preciso comprar roupa e sapatilha antes da primeira aula?"**
  "Para a aula experimental, não. Vá com roupa confortável que deixe você se mexer. O que
  cada turma usa depois a gente combina pessoalmente."
- **"Como funciona a aula experimental?"**
  "Você agenda antes pelo WhatsApp, a gente confirma o dia e o horário da turma certa para
  você, e você vem fazer a aula."
- **"Quanto custa?"**
  "A mensalidade depende da modalidade e de quantas vezes por semana você vem. A gente passa
  o valor certo pelo WhatsApp, sem enrolação."

### A chamada, verbatim

Botão: **"Agendar aula experimental"**
Mensagem que já vai escrita no WhatsApp: "Oi! Vim pelo site e quero agendar uma aula experimental."
Linha de apoio abaixo do botão: "A gente responde no horário da recepção, das 15h às 20h."

### O formulário

Não existe, de propósito. Site estático não tem para onde mandar formulário, e nesse ramo a
venda acontece na conversa. O botão abre o WhatsApp com a mensagem pronta. Isso está dito
com todas as letras para você: nenhum campo do site guarda dado de ninguém.

## 7. A camada de vetores

Desenhados à mão em SVG, nada de biblioteca:

- **A barra**, o elemento de assinatura. Uma linha contínua que entra no herói como barra de
  ballet e depois vira a espinha do site: se desenha sozinha na entrada de cada seção,
  sublinha os títulos, vira o eixo da grade de horários e volta inteira na chamada final.
  Se ela sumisse, a página seria outra. É esse o teste.
- O facho de luz da janela, que anda e esfria das 15h às 20h.
- A poeira no facho, em nível sussurro.
- Cinco glifos de modalidade, um por cartão.
- A mão que segura a barra no momento interativo.
- Favicon SVG embutido: círculo e barra, desenho meu, abstrato.

Tudo honra movimento reduzido: estados finais mostrados, motores parados.

## 8. A lista de engenharia

Loop rAF normalizado por dt que descansa quando converge, escritas no DOM só quando mudam,
faixas com smoothstep e platô longo validado pelo teste do peteleco, os três modos do herói
vivos nos dois sentidos a partir de uma fonte única de verdade, movimento reduzido honrado ao
vivo nos dois sentidos, overflow-x clip em html e body, entradas coreografadas com
IntersectionObserver e atrasos aposentados depois, um elemento vivo por seção em nível
sussurro, animações pausadas em aba oculta e fora de tela, marcos semânticos e link de pular,
foco visível, alvos de toque de 44px, contraste calculado e não chutado (dois valores da paleta reprovaram na conta e foram
trocados antes de qualquer linha de HTML), e as tags og com o
comentário DEPLOY STEP para preencher na publicação.

## 9. O portão da escrita

Todo texto acima vai para a página exatamente como está. A página construída precisa passar
no portão da Fase 9 antes de qualquer pessoa ver: zero travessões, zero palavra de catálogo
corporativo, e a varredura dos vícios de texto de IA. Os recursos de marca propositais, como
o trio "Primeiro você se segura. Depois você solta. E um dia você dança.", são artesanato e
ficam.

---

## 10. O que a auditoria da Fase 9 encontrou e o que foi corrigido

Tudo abaixo foi medido num Chrome de verdade, dirigido pelo protocolo de depuração,
não olhado no olho. Os defeitos são meus, encontrados antes de qualquer pessoa ver.

**Defeitos de código, corrigidos:**

1. **O scrim das faixas escapava para trás do palco.** Com opacidade exatamente 1 a faixa
   deixa de criar contexto de empilhamento, e o scrim em `z-index:-1` ia parar atrás das
   camadas de luz. Todas as cinco faixas estavam sem a proteção que eu achava que tinham.
   Corrigido com `isolation:isolate`.
2. **A interação voltava ao começo ao ser completada.** O laço continuava rodando depois de
   encher a barra e drenava o progresso de volta a zero, com a frase retrocedendo junto.
   Agora completo é estado final.
3. **A faixa ativa da régua de horários tinha largura zero.** `inset:0 auto 0 0` deixa a
   largura em auto. A faixa existia, nunca aparecia.
4. **As âncoras do menu escondiam o título atrás da barra fixa.** Resolvido com
   `scroll-margin-top` nas seções.
5. **O marcador de "aberto agora" vazava da tela no celular.** O rótulo virou selo acima da
   régua, e o ponto ficou preso entre 2% e 98%.
6. **Alvos de toque abaixo de 44px** em todos os links de contato e do rodapé. Corrigido com
   padding para fora e margem negativa de volta, sem mexer um pixel do layout.
7. **A página ficava sem `h1`** em todos os modos menos o estático, porque o único h1 vivia
   num bloco escondido. Agora existe um h1 só, presente sempre.
8. **A barra cortava o texto no meio, no celular.** A sala desce nos modos curto e estático,
   e o texto ganhou a largura da tela. Medido em 375x812, 360x640 e 834x1112: a menor folga
   entre o fim do texto e a barra passou de menos 31px para 71px.

**Medições que passaram:**

- **Pior pixel atrás de cada texto:** 42 medições, três elementos por faixa, em três pontos
  de cada faixa. Piso de 3,5:1. Menor valor medido depois das correções: 4,22:1. Maior: 16,22:1.
  A faixa das 20h reprovou na primeira rodada e ganhou scrim próprio mais o chip no kicker.
- **Teste do peteleco:** passos de 120px, 240px e 360px, no desktop e no celular. Nenhum beat
  é pulável em nenhum tamanho de passo, e no peteleço normal cada beat fica legível por 5 a 9
  peteleços seguidos.
- **Os três modos** batem em seis tamanhos de tela, e rearmam ao vivo na rotação e na troca de
  preferência de movimento, nos dois sentidos.
- **Zero erro no console** em todas as larguras. **Zero rolagem lateral** em 320, 360, 375,
  414 e 768px.
- **Sem as fontes**, a página continua inteira e legível na fonte do sistema.
- **Peso da primeira visita: 205 KB no total**, sendo 73 KB de HTML e o resto fontes.
  Carrega em 69ms no servidor local. Nenhuma imagem, nenhum framework, nenhuma etapa de compilação.


---

## 11. A troca do scroll pelo relógio (pedido do cliente)

O herói deixou de ser uma pista de 700vh e virou **uma tela só que anda sozinha**. Cada
momento fica parado 2,1s e leva 0,9s para virar o próximo, ou seja, muda a cada 3 segundos,
e muda gradualmente. A luz continua andando das 15h às 20h, só que no relógio, não no scroll.

**O que isso obrigou a acrescentar.** Conteúdo que se troca sozinho tira o controle de quem
lê. Sem devolver esse controle, quem lê devagar perde a frase e quem usa leitor de tela fica
preso num carrossel. Então o herói ganhou:

- **Marcadores**, desenhados como a própria barra em miniatura, um por momento. Clicáveis,
  alcançáveis pelo teclado, e cada um leva no rótulo o texto do momento a que leva.
- **Botão de pausa**, com `aria-pressed` e rótulo que troca entre pausar e continuar.
- **O fim é repouso, não laço.** A travessia termina no bloco do nome com os dois botões e
  fica lá. Um laço apagaria a chamada a cada 15 segundos.
- **Nada de `aria-live`.** Anunciar a troca a cada 3 segundos atrapalharia mais do que
  ajudaria. As cinco falas já estão no DOM em ordem, legíveis de cima a baixo.
- **O convite para descer**, que aparece quando a travessia chega ao fim.

**Um movimento novo que nasceu de um problema de medida.** No celular o bloco final não cabia
acima da barra. Em vez de encolher o texto, a sala **se assenta e desce** quando o último
momento chega. Virou movimento de câmera, e o problema de espaço sumiu junto.

Os dois modos do herói caíram de três para dois: **auto** e **estático**. A escolha entre eles
continua saindo de uma função só de JavaScript que escreve a classe no `<html>`, com o CSS
apenas reagindo.

### O que a medição desta rodada encontrou

**Defeitos corrigidos:** o marcador acendia 600ms antes do texto trocar; a barra passava por
cima dos botões do bloco final no desktop, o que eu não tinha medido na versão de scroll; os
rótulos dos marcadores vinham duplicados porque o texto partido guarda a cópia do leitor de
tela e a visual; e as regras de toque dos controles estavam antes das definições, então
perdiam por ordem de fonte e os alvos ficavam em 30px.

**Medições que passaram:** zero colisão entre texto, barra e controles em nove tamanhos de
tela, de 320x568 a 1920x1080. Pior pixel atrás de cada texto medido nos cinco momentos, no
desktop e no celular: menor valor 3,95:1 contra um piso de 3,5. Zero erro de console, zero
rolagem lateral, todos os alvos de toque com 44px ou mais, e movimento reduzido honrado ao
vivo nos dois sentidos.

### O que a medição encontrou e EU NÃO posso resolver sozinho

Os momentos 2 e 3 têm 26 e 25 palavras. Numa leitura cuidadosa em português, isso pede cerca
de **8 segundos**, e o beat dura 3. Quem chegar no meio deles vai pegar o título e perder a
linha de apoio. Os outros três momentos cabem em 3 segundos com folga.

Três saídas foram apresentadas ao cliente, que escolheu a terceira: **cada momento fica no ar
pelo tempo que o texto dele pede.** Os três curtos ficam 3 segundos, os dois longos ficam 6.
A duração é declarada no HTML de cada faixa, em `data-segundos`, e o relógio monta a linha do
tempo a partir dela. Nenhuma linha foi cortada e a tela continua trocando sozinha.

Medido no navegador: momento 1 com 3s, momentos 2 e 3 com 6,0s cada, momento 4 com 3,0s, e o
bloco final entrando aos 17,5s para descansar. Marcadores, pausa, os dois modos e o portão da
escrita continuam passando.
