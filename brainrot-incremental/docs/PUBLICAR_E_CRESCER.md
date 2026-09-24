# Como publicar o jogo no Roblox e tentar fazer ele crescer

Guia escrito em 24/09/2026 com base na documentação oficial do Roblox (create.roblox.com/docs) dessa data.
As regras do Roblox mudam bastante (mudaram muito em 2026), então, se algum menu estiver diferente,
procure o nome da opção no Creator Hub.

O passo a passo técnico de abrir o arquivo e testar no Studio está no `README.md`. Este guia cobre o
que vem depois: conta, publicação, página do jogo, game passes, lançamento e divulgação.

---

## Resumo em 12 passos

1. Troque o nome do jogo e os nomes dos brainrots por nomes seus (seção 1).
2. Teste tudo no Studio com os comandos de teste e depois desligue o `DebugMode`.
3. Confira os administradores em `Config/Admins` (você e seu amigo já estão lá, seção 7).
4. Na sua conta: verifique a idade, ative a verificação em 2 etapas (2FA) e confirme o e-mail (seção 2).
5. Publique o Lobby e a Partida, cole os dois IDs no `Config/Game` e publique de novo (seção 3).
6. Responda o questionário de maturidade (sem ele o jogo não roda).
7. Envie o ícone, as thumbnails, o título e a descrição (seção 4).
8. Crie os 5 game passes, coloque à venda e cole os IDs (seção 5).
9. Crie até 5 badges grátis por dia (seção 6).
10. Faça um teste fechado só com amigos (seção 8).
11. Abra para todos (Public) e pague a taxa de 1.000 Robux reembolsável para chegar às crianças (seção 2).
12. Atualize toda semana, faça eventos de admin e divulgue (seção 9).

---

## 1. Antes de publicar

- **Nome original.** O nome atual, "Brainrot Incremental But With Guns", é quase igual ao jogo
  "Farming Incremental But With Guns". O Roblox mostra menos os jogos que parecem cópia de outros
  (título, visual ou jogo parecidos), e o anúncio de um jogo "não único" pode nem rodar. Escolha um nome
  seu, curto e fácil de buscar. Exemplos só para dar ideia: "Brainrot Blaster", "Atire nos Brainrots",
  "Brainrot Farm Defense".
- **Personagens originais.** Os brainrots do jogo usam nomes famosos (Tung Tung Tung Sahur, Tralalero
  Tralala e outros). Os direitos desses personagens estão sendo disputados na justiça dos EUA: uma empresa
  diz que é dona do Tung Tung Tung Sahur, e ele chegou a ser retirado do Steal a Brainrot em 2025.
  O julgamento só acontece em novembro de 2027. O mais seguro é inventar brainrots seus no mesmo estilo
  (nome italiano engraçado + objeto + bicho). Para trocar, mude o `DisplayName` de cada um em
  `ReplicatedStorage > Shared > Config > Brainrots` (e o `ModelName` se trocar o modelo 3D).
- **Sons e modelos.** Use só sons e modelos que você fez, comprou ou pegou grátis na Creator Store.
  Música de artista famoso é removida e pode dar punição na conta.
- **Modo de teste desligado.** Em `Config/Game`, confira `DebugMode = false` antes de publicar.
  Os comandos de teste (/coins, /maxall...) só funcionam no Studio ou com ele ligado.
- **Teste completo.** Jogue os 3 atos no Studio, com os comandos de teste para pular partes. Mande
  para mim cada erro vermelho do Output com o nome do script e a linha.

---

## 2. O que a sua conta precisa ter

**Para publicar e deixar o jogo aberto para 16+ (grátis):**
- conta com pelo menos 2 dias e sem punições;
- **verificação de idade**: por estimativa facial (selfie) ou por documento com foto
  (Configurações > Informações da conta > verificação);
- **questionário de maturidade** respondido (seção 4).

**Para o jogo chegar às crianças e adolescentes (menores de 16), que são quase todo o público de brainrot:**
- tudo o que está acima;
- **verificação em 2 etapas (2FA)** ligada (ela pede e-mail confirmado);
- uma destas opções:
  - **taxa de 1.000 Robux**, que volta para você depois (em Audience > Reach), ou
  - ter **Roblox Plus ou Premium** ativo há 2 meses seguidos;
- passar na **avaliação**: o jogo começa aparecendo só para 16+ verificados. Ele libera para
  Roblox Kids (5 a 8 anos) e Roblox Select (9 a 15 anos) depois de **250 jogadores "muito engajados"**
  diferentes jogarem em até 60 dias (contas antigas, que jogam bastante e compraram algo no Roblox
  nos últimos 60 dias). O progresso aparece no painel **Audience Reach** do Creator Hub.

**Atenção à classificação:** no nosso jogo os brainrots somem quando morrem, sem sangue. Isso conta como
violência leve ("Mild"), que continua liberada para Kids e Select. Não adicione sangue ou mortes realistas,
senão o jogo sobe para "Moderate" e deixa de aparecer para as crianças de 5 a 8 anos.

---

## 3. Publicar os dois places (Lobby e Partida)

O jogo tem **dois places** que usam **o mesmo arquivo**: o Lobby (onde o jogador entra) e a Partida
(o servidor reservado de cada grupo). O jogo descobre sozinho qual é qual pelos IDs no `Config/Game`.

1. Abra o `BrainrotIncremental.rbxlx` no Studio.
2. **Arquivo > Publicar no Roblox** (File > Publish to Roblox). Crie um jogo novo com o nome que
   você escolheu. Esse primeiro place vira o **place inicial**: ele é o Lobby. Todo jogo novo nasce
   **Privado**, então ninguém entra ainda.
3. Ainda com o mesmo arquivo aberto: **Arquivo > Publicar no Roblox como...** (Publish to Roblox As),
   clique no quadrado do seu jogo e escolha **"Adicionar como novo place"** (Add as a new place).
   Dê o nome "Partida".
4. Pegue os dois números: **Exibir > Gerenciador de ativos** (Asset Manager) > **Places**, clique com o
   botão direito em cada place > **Copiar ID do recurso** (Copy Asset ID).
5. No Studio, abra `ReplicatedStorage > Shared > Config > Game` e cole:
   ```lua
   LobbyPlaceId = 1234567890, -- número do place inicial (Lobby)
   MatchPlaceId = 9876543210, -- número do place "Partida"
   ```
6. Publique de novo **nos dois**: **Publicar no Roblox como...** > seu jogo > escolha o place >
   **Substituir** (Overwrite). Faça uma vez para o Lobby e outra para a Partida.
7. No Creator Hub, abra o jogo > **Audience > Access Settings > Access Control for Places** e deixe a
   Partida como **"Secure within universe only"** (só entra por teleporte do próprio jogo). Assim ninguém
   cai direto na Partida pelo link.
8. **Toda vez que mudar o código**, publique nos dois places e depois use **Restart Servers**
   (marque "only servers with outdated versions") para os servidores antigos pegarem a versão nova.

Teleporte, convite de amigos e "Continuar partida salva" **não funcionam no Studio**. Teste isso no jogo
publicado, pelo aplicativo do Roblox.

**DataStore no Studio:** para testar o salvamento no Studio, ligue **Configurações do jogo > Segurança >
Habilitar acesso do Studio aos serviços de API**. O Studio usa os mesmos dados do jogo de verdade, então
depois do lançamento é melhor testar numa cópia do jogo.

---

## 4. A página do jogo

Tudo isso fica no **Creator Hub** (create.roblox.com) > **Criações** > seu jogo.

- **Questionário de maturidade (obrigatório):** **Configure > Questionnaire** > Start > responda >
  Submit. Jogo sem classificação não pode ser jogado. Responda de novo sempre que um update mudar
  alguma resposta. Pergunta importante: o jogo **não vende itens aleatórios** (responda "não").
- **Ícone:** quadrado **512×512**. Ele aparece pequeno (150×150), então use um brainrot grande e uma arma,
  com cores fortes e pouco ou nenhum texto.
- **Thumbnails:** imagens **1920×1080** (16:9), até 10. Mostre o jogo de verdade: a arma atirando, o chão
  cheio de brainrots, moedas voando, o gigante. Não coloque texto importante na parte de baixo (o número
  de jogadores cobre essa área). Ative de **2 a 5 thumbnails** na personalização: o Roblox mostra a melhor
  para cada tipo de jogador (em média +8,5% de cliques). Não apague as antigas cedo; teste novas a cada
  update grande.
- **Vídeo (opcional):** até 3 por mês, só gameplay real, sem narração e sem música com letra.
- **Título e descrição:** curtos e honestos. Nada de "Robux grátis", nada de repetir palavras-chave e
  poucos emojis. Na descrição conte em 2 linhas o que se faz ("Atire nos brainrots, colete moedas, compre
  armas e sobreviva a 3 mapas com até 8 amigos") e diga quando sai update.
- **Idiomas:** ligue a tradução automática. Os textos do jogo são capturados e traduzidos sozinhos.
- **Tornar público:** **Configure > Settings > Audience** > **Public** > Save. Só faça isso depois do
  teste com amigos (seção 8).

---

## 5. Game passes

O jogo já tem **5 game passes** prontos. Eles ficam escondidos até você criar os passes no Roblox e colar
os números. O que cada um faz está no `README.md` (seção "Game passes").

| Pass | O que faz | Preço sugerido |
|---|---|---|
| Moedas em Dobro | toda moeda do dono vale o dobro | 199 Robux |
| VIP | +25% de moedas, etiqueta dourada e [VIP] no chat | 249 Robux |
| Dano em Dobro | a arma do dono causa o dobro de dano (torretas não) | 179 Robux |
| Coleta Automática | ímã de moedas desde o começo | 149 Robux |
| Torreta Extra | +1 torreta no limite | 129 Robux |

Os preços são só sugestão, com base em jogos parecidos (VIP de 100 a 400 e dinheiro em dobro de 119 a 299
em simuladores). O Roblox já ativa o **preço regional**: no Brasil o jogador paga menos, sozinho. Você recebe
**70%** de cada venda (um pass de 199 Robux rende uns 139 Robux). Preços entre 50 e 800 Robux podem
aparecer na página de comprar Robux.

**Como criar:**
1. Com o jogo já publicado: Creator Hub > seu jogo > **Monetização > Passes > Criar um passe**.
2. Envie um ícone (até 512×512, o Roblox recorta em círculo), o nome e a descrição.
3. Abra o pass > **Vendas** (Sales) > ligue **Item à venda** > escolha o preço > Salvar.
4. Copie o número do pass (três pontinhos > **Copiar ID do recurso**).
5. No Studio, em `Config/Game`, cole cada número no lugar do `0` e mude `Enabled` para `true`:
   ```lua
   Gamepasses = { Enabled = true, DoubleCoins = 111, AutoCollect = 222, ExtraTurret = 333, VIP = 444, DoubleDamage = 555 },
   ```
6. Publique nos dois places.

O jogo busca o preço direto do Roblox, então o preço mostrado na loja é sempre o certo, mesmo com preço
regional. Pass que não está à venda não aparece.

**Duas regras que o jogo segue de propósito:**
- **Nunca venda moedas do jogo por Robux.** As moedas compram upgrades de sorte (mais brainrots raros).
  Se moeda pudesse ser comprada com Robux, isso viraria "item aleatório pago", que exige mostrar as
  chances em % e, **no Brasil, é proibido para menores de 18 desde março de 2026** (ECA Digital).
- **Nada de pass de sorte.** Pelo mesmo motivo, trocamos o pass "Sorte do Servidor" pelo "Dano em Dobro".

---

## 6. Badges (conquistas)

- Cada jogo pode criar **5 badges grátis por dia**; a partir da 6ª no mesmo dia, custa 100 Robux cada.
  Crie aos poucos.
- Creator Hub > seu jogo > **Engajamento > Badges** > criar (ícone 512×512, recortado em círculo).
- Copie o número (**Copiar ID do recurso**) e cole no `BadgeId` da conquista em
  `ReplicatedStorage > Shared > Config > Achievements`. Publique nos dois places.

---

## 7. Administradores (você e seu amigo)

Já vem configurado em `ReplicatedStorage > Shared > Config > Admins`:
```lua
OwnerUserIds = { 335101108 }, -- você (cargo "Dono")
UserIds = { 1179661787 },     -- seu amigo (cargo "Admin")
```
- Você também vira admin sozinho por ser o dono do jogo. O seu número fica na lista para garantir, caso
  você passe o jogo para uma Comunidade depois.
- **Para pôr ou tirar alguém:** abra o perfil da pessoa no site do Roblox. O endereço é
  `roblox.com/users/NÚMERO/profile`. Coloque ou apague o NÚMERO em `UserIds` e publique nos dois places.
- A lista de comandos (voar, velocidade, dar moedas, eventos globais, avisos, expulsar, banir...) e como
  usar o painel **ADMIN** estão no `README.md`, seção "Administradores".
- **Nunca dê admin para quem você não conhece.** Um admin consegue banir jogadores e mexer na economia
  de todos os servidores.

---

## 8. Lançamento em teste

1. Com o jogo ainda privado, mude o Audience para **Limited > Friends** (seus amigos do Roblox) ou
   **Playtesters**.
2. Jogue uma partida inteira com 2 a 4 amigos: lobby, criar grupo, convidar, escolher o mapa, os 3 atos,
   sair e "Continuar partida salva".
3. Peça para eles jogarem no **celular** também (a maioria dos jogadores do Roblox joga no celular).
4. Abra **Exibir > Console do desenvolvedor** (F9) no jogo publicado e anote os erros vermelhos do servidor.
   Me mande cada um com o nome do script e a linha.
5. Só depois disso mude para **Public**.

---

## 9. Como fazer o jogo crescer

### Como o Roblox decide quem vê o seu jogo
A maior parte dos jogadores vem da Home ("Recomendado para você"). O algoritmo testa o jogo com poucos
jogadores e, se eles gostam, mostra para mais gente parecida. O que ele mede, em média por jogador:
- quantos clicam para jogar depois de ver o ícone (ícone e thumbnail bons);
- **quantos saem no primeiro minuto** (isso pesa muito contra);
- quantos voltam no dia seguinte, na mesma semana e no mesmo mês;
- quanto tempo jogam por dia (conta até 60 min);
- quantos jogam **com amigos** (o nosso jogo é co-op, isso ajuda muito).

**Importante:** só conta quem chegou pela Home. Quem veio por anúncio, busca ou link ajuda o jogo a
"entrar no teste", mas não melhora a posição dele. Por isso o jogo precisa **segurar** o jogador.

### Os primeiros 60 segundos
O jogador precisa atirar num brainrot e ver moedas voando **em menos de 30 segundos**. Nada de tutorial
longo nem de lobby confuso: o botão de jogar sozinho tem que ser o mais chamativo. Use o gráfico
**New User First Session Retention** (Analytics > Engajamento) para ver em que minuto os novos desistem.

### Anúncios (Ads Manager)
- Com 13+ anos dá para pagar anúncio convertendo Robux em créditos (não dá para desfazer). Com cartão,
  só 18+ (pode ser a conta de um responsável).
- Objetivo **Engagement**: mira justamente os jogadores "muito engajados" que contam para a avaliação de
  Kids/Select (seção 2). É o melhor uso do primeiro dinheiro de anúncio.
- Objetivo **Plays**: traz a primeira leva de jogadores para o algoritmo aprender.
- Sugestão não oficial: US$ 10 a 20 por dia durante 3 a 5 dias, e só então olhar o custo por play.
  O primeiro dia é de "aprendizado" e sai caro. Teste várias thumbnails na mesma campanha.

### Updates toda semana
- Atualize **uma vez por semana, sempre no mesmo dia**. Sábado é o dia de mais jogadores no Roblox.
  Steal a Brainrot e Grow a Garden atualizam aos sábados.
- Update pequeno reaproveita o que existe: um brainrot novo, uma arma nova, uma missão nova, uma skin.
  Os números ficam nas tabelas de `Config`, então muita coisa não precisa de código novo.
- Depois de cada update o Roblox testa o jogo com mais gente nova. Capriche na thumbnail nessa semana.
- Anuncie o update como **Experience Event** no Creator Hub (Engajamento > Eventos): quem se inscreve
  recebe notificação.
- Seja realista: é melhor um update pequeno toda semana do que prometer um gigante e sumir.

### Eventos de admin ("admin abuse")
Os maiores jogos de brainrot fazem um evento semanal, junto com o update, em que o dono entra no jogo e
dá coisas para todo mundo. O nosso jogo já tem isso: pelo painel ADMIN você liga um **evento global**
(moedas em dobro, sorte, gigantes ou "abuse" com tudo junto) em todos os servidores ao mesmo tempo,
manda um aviso para todo mundo e faz chover moedas. Marque dia e hora fixos (por exemplo, sábado às 16h,
logo depois do update) e avise na descrição e no Experience Event. Esses eventos são grátis para os
jogadores, então não entram nas regras de item aleatório pago.

### Comunidade e redes sociais
- Crie uma **Comunidade** no Roblox (antigo Grupo) para o jogo. Dá para publicar o jogo nela depois.
- Links externos (Discord, YouTube, TikTok) só entram pelos **Social Links** da página do jogo, e para
  adicionar é preciso ter **16+ com idade verificada**. Dentro do jogo não pode mostrar links.
- Grave vídeos curtos (TikTok, YouTube Shorts, Roblox Moments) do que é engraçado ou impressionante:
  o gigante chegando, chuva de moedas, o chão lotado, reação de amigo. Os dois maiores jogos de brainrot
  viralizaram assim.
- Youtubers pequenos de Roblox (em português) aceitam jogar jogos novos. Mande o link e ofereça um
  evento de admin ao vivo com eles.

### Convites
O jogo já tem grupo com amigos e convite do próprio Roblox. Jogar com amigos é um dos sinais que o
algoritmo mede. Uma ideia para depois: um bônus para quem entra por convite e para quem convidou
(o Roblox tem um sistema oficial de indicação para isso).

### Números para olhar toda semana (Creator Hub > Analytics)
- **Retenção D1 e D7** (quantos voltam no dia seguinte e depois de uma semana);
- **tempo médio de sessão**;
- **Home Recommendations**: impressões, cliques e a comparação com jogos parecidos;
- **conversão** (quantos % compram algum pass).

Quando as impressões caem, quase sempre é porque um desses números piorou antes.

---

## 10. Regras que dão punição (não faça)

- Thumbnail, título ou descrição que mentem sobre o jogo, ou que prometem Robux.
- **Dar recompensa para quem der like ou favoritar** (metas gerais como "update com 1.000 likes" são
  toleradas).
- Usar bots ou comprar visitas, likes ou favoritos.
- Copiar outro jogo (nome, visual ou jogo igual).
- Vender itens aleatórios (caixas, ovos, roletas, sorte) sem mostrar as chances. No Brasil, nem mostrando
  dá para vender para menores.
- Pedir para o jogador fazer algo fora do Roblox (postar em rede social) para ganhar algo que ele pagou.

---

## 11. Expectativa realista

Grow a Garden e Steal a Brainrot chegaram a mais de 20 milhões de jogadores ao mesmo tempo, mas os dois
tinham um estúdio experiente por trás. A maioria dos jogos novos começa com poucos jogadores. O que
funciona é repetir o ciclo: publicar, olhar os números, melhorar o começo do jogo, atualizar toda semana
e fazer eventos. Cada semana boa faz o Roblox mostrar o jogo para mais gente.

---

## 12. Dinheiro de verdade (DevEx)

- Os Robux que o jogo ganha podem virar dinheiro pelo **DevEx** (Creator Hub > Finanças > Sacar).
- Precisa ter **13+ anos**, **30.000 Robux ganhos** (não conta Robux comprado nem recebido de presente),
  e-mail confirmado e o cadastro no portal do DevEx (quem não mora nos EUA preenche o formulário W-8).
  Se você for menor de idade, faça com um responsável.
- A taxa é **US$ 0,0038 por Robux**: 30.000 Robux viram uns US$ 114.
- O Roblox também paga um bônus automático (**Creator Rewards**) quando jogadores que gastam no Roblox
  passam 10 minutos ou mais no seu jogo.
