# Brainrot Incremental But With Guns (Roblox)

Jogo completo para o **Roblox Studio**, escrito em **Luau**, inspirado em *Farming Incremental But With Guns*.
Em vez de plantas, você atira em **brainrots gigantes** que nascem no campo, coleta as moedas que eles soltam
e compra upgrades nas barracas até concluir os três atos (Prado, Inverno e Deserto) e alimentar o Brainrot Supremo.

Antes da partida existe um **lobby**: você cria uma festa, escolhe o mapa, o limite de jogadores (1 a 8)
e a privacidade (pública, só amigos ou só convidados). Quando todos estão prontos, o grupo é teleportado
para um servidor reservado da partida.

Tudo (mapas, interface, efeitos) é construído **por código**. Não é preciso montar nada à mão no Studio.

---

## 1. Abrir no Roblox Studio (jeito mais fácil)

1. Baixe o arquivo **`BrainrotIncremental.rbxlx`** (está nesta pasta).
2. Abra o Roblox Studio, clique em **Arquivo > Abrir do arquivo...** e escolha o `.rbxlx`.
3. Aperte **Jogar (F5)**. Por padrão o Studio abre direto na partida do mapa **Prado**.

Os scripts ficam onde o Roblox espera:

| No Explorer do Studio | O que tem |
|---|---|
| `ReplicatedStorage > Shared > Config` | Todas as tabelas de balanceamento (mapas, armas, upgrades, brainrots, receitas...) |
| `ReplicatedStorage > Shared > Util` | Utilitários (rede, formatação de números, fórmulas, sinais) |
| `ServerScriptService > Main` | Script que liga o servidor |
| `ServerScriptService > Services` | Serviços do servidor (partida, combate, moedas, salvamento, lobby...) |
| `ServerScriptService > World` | Construtores dos mapas, dos brainrots e das torretas |
| `ServerStorage > BrainrotModels` | Pasta vazia para os seus modelos 3D de brainrot (opcional) |
| `StarterPlayer > StarterPlayerScripts > Main` | LocalScript que liga o cliente |
| `StarterPlayerScripts > Controllers` / `UI` | Câmera, arma, HUD, janelas e telas do lobby |

### Alternativa: sincronizar com o Rojo

Se você preferir editar os arquivos `.lua` num editor (VS Code) e ver as mudanças no Studio:

1. Instale o [Rojo](https://rojo.space) (programa e plugin do Studio).
2. Nesta pasta, rode `rojo serve` e clique em **Connect** no plugin do Rojo dentro do Studio.
3. Para gerar o `.rbxlx` de novo: `rojo build default.project.json -o BrainrotIncremental.rbxlx`.

---

## 2. Testar no Studio

O mesmo arquivo serve para o **lobby** e para a **partida**. No Studio, quem decide é o
`ReplicatedStorage > Shared > Config > Game`:

```lua
StudioRole = "Match",   -- "Match" abre uma partida; "Lobby" abre o lobby
StudioMapId = "Meadow", -- mapa da partida: "Meadow" (Prado), "Winter" (Inverno) ou "Desert" (Deserto)
```

- **Um jogador:** aperte **Jogar (F5)**.
- **Vários jogadores:** aba **Testar > Clientes e servidores**, escolha 2 a 4 jogadores e clique em **Iniciar**.
- **Teleporte não funciona no Studio** (limite do Roblox). No lobby você pode criar festas e testar a
  interface, mas ao iniciar aparece um aviso. Para jogar um mapa, use `StudioRole = "Match"` e o `StudioMapId`.
- **Salvamento:** sem acesso às APIs, o Studio usa um armazenamento temporário (o progresso some quando
  você para o teste). Para testar o salvamento de verdade, publique o jogo uma vez e ligue
  **Configurações do jogo > Segurança > Habilitar acesso do Studio aos serviços de API**.

### Testar no Studio com segurança

Com o acesso às APIs ligado, o Studio **não mexe nos dados de verdade dos jogadores**. Ele salva
num "caderno separado": os DataStores do Studio têm `_Studio` no fim do nome
(`BrainrotIncremental_Player_v1_Studio` e `BrainrotIncremental_Runs_v1_Studio`). Então você pode
usar `/coins`, `/nextact`, `/reset` e fechar o teste no meio à vontade: o seu perfil e as partidas
salvas do jogo publicado continuam intactos, e os placares do lobby (moedas, abates e atos) não
recebem nenhuma pontuação de teste. No Output aparece a linha
`[DataService] Studio: usando lojas _Studio (dados reais protegidos)`.

Quem controla isso é o `StudioLiveData` no `Config/Game`:

```lua
StudioLiveData = false, -- false (padrão) = Studio usa as lojas _Studio e não grava placar
```

Só mude para `true` se precisar investigar um problema nos **dados reais** (por exemplo, o perfil de
um jogador que reclamou). Com `true`, o Studio lê e **grava** nos DataStores de verdade: um teste pode
sobrescrever progresso real. Volte para `false` assim que terminar.

### Comandos de teste (modo debug)

No Studio o modo debug já vem ligado. Aparece um botão **DEBUG** no canto da tela, e também dá para
digitar no chat:

| Comando | O que faz |
|---|---|
| `/coins 1000` | Ganha moedas |
| `/maxall` | Maxa todos os upgrades e prateleiras do mapa |
| `/wave` | Planta uma leva de brainrots |
| `/nextact` | Conclui o ato atual |
| `/supreme 0.9` | Define o progresso do Brainrot Supremo (0 a 1) |
| `/ingredients` | Ganha 5 de cada ingrediente |
| `/unlockall` | Libera todos os mapas no seu perfil |
| `/tokens 100` | Ganha Brainrot Tokens (moeda da loja do lobby) |
| `/reset` | Zera o seu progresso nesta partida |
| `/help` | Lista os comandos |

Fora do Studio os comandos de teste ficam desligados. Para testar no jogo publicado, **use os
comandos de administrador** (seção 5: `:coins`, `:maxall`, `:nextact`, `:tokens`...), que só funcionam
para quem está no `Config/Admins`.

- O `DebugMode = true` no `Config/Game` não abre os comandos para todo mundo: fora do Studio, mesmo
  ligado, só os **admins** conseguem usar os comandos com `/`. Mesmo assim, deixe `false` no jogo
  publicado.
- **Não coloque o atributo `DebugMode` no Workspace do place publicado** (instruções antigas pediam
  isso para testar). Hoje esse atributo só vale no Studio e é ignorado nos servidores de verdade; se
  ele estiver lá, pode apagar.
- O mesmo vale para o atributo `ForceRole` do Workspace: ele só serve para testes no Studio e é
  ignorado no jogo publicado.

---

## 3. Publicar no Roblox

A experiência tem **dois places**: o **Lobby** (place inicial) e a **Partida**. Os dois recebem **o mesmo arquivo**.

1. Com o `.rbxlx` aberto, vá em **Arquivo > Publicar no Roblox**, crie uma experiência nova e dê um nome.
   Esse primeiro place vira o **place inicial**, que será o lobby.
2. Com o mesmo arquivo aberto, vá em **Arquivo > Publicar no Roblox como...**, clique na sua
   experiência e escolha **Adicionar como novo place** (Add as a new place). Dê o nome "Partida".
3. Abra **Exibir > Gerenciador de ativos > Places**, clique com o botão direito em cada place e use
   **Copiar ID do recurso** (Copy Asset ID) para pegar os dois números.
4. No script `ReplicatedStorage > Shared > Config > Game`, preencha:
   ```lua
   LobbyPlaceId = 1234567890, -- id do place inicial
   MatchPlaceId = 9876543210, -- id do place "Partida"
   ```
   Os dois números precisam ser **diferentes**. Se ficarem iguais, o jogo avisa no Output
   (`LobbyPlaceId e MatchPlaceId iguais: usando Lobby`) e não teleporta ninguém, para não prender
   os jogadores num vai-e-volta entre lobby e partida.
5. Publique de novo **nos dois places**: **Arquivo > Publicar no Roblox como...**, escolha a sua
   experiência, depois o place e **Substituir** (Overwrite). Faça uma vez para o Lobby e outra para a Partida.
6. Em **Configurações do jogo**:
   - **Segurança:** ligue **Habilitar acesso do Studio aos serviços de API** (só para testar no Studio;
     nos servidores de verdade o DataStore já funciona).
   - **Permissões:** deixe a experiência **Pública** quando quiser abrir para todos.
7. Toda vez que mudar o código, publique **nos dois places** para os dois ficarem iguais e use
   **Restart Servers** no Creator Hub para os servidores abertos pegarem a versão nova.

O guia completo, com o que a conta precisa ter, a página do jogo, os game passes e como divulgar,
está em `docs/PUBLICAR_E_CRESCER.md`.

Os teleportes entre lobby e partida, o convite de amigos e o "Continuar partida salva" só funcionam
depois desses passos, num servidor publicado.

---

## 4. Personalizar

### Modelos 3D dos brainrots
Sem modelos, o jogo monta cada brainrot com peças simples e coloridas. Para usar modelos de verdade,
coloque um **Model** dentro de `ServerStorage > BrainrotModels` com o nome exato abaixo. Pode ser de
qualquer tamanho: o jogo ajusta a escala, ancora e posiciona sozinho.

`TungTungSahur`, `BrrBrrPatapim`, `TrippiTroppi`, `ChimpanziniBananini`, `BonecaAmbalabu`,
`BallerinaCappuccina`, `TralaleroTralala`, `CappuccinoAssassino`, `BombardiroCrocodilo`, `FrigoCamelo`,
`PinguinoCongelino`, `TaTaTaSahur`, `GlorboGelatino`, `OrsettoGhiacciolo`, `BombombiniGusini`,
`TricTracBaraboom`, `TigrrulliniWatermellini`, `LaVacaSaturnoSaturnita`, `LiriliLarila`,
`CactusinoBandito`, `SahurDelDeserto`, `CamelloTostato`, `Garamararam`, `BananitaDolfinita`,
`BurbaloniLuliloli`, `GraipussiMedussi`, `TralaleroFaraone` e o chefão final `TralaleroSupremo`.

Por segurança, o jogo **limpa** cada modelo antes de usar: tira scripts (um modelo grátis da Toolbox
pode ter um script escondido), sons, cadeiras, ferramentas, prompts, `SpawnLocation` e telas
(`BillboardGui`/`SurfaceGui`), e deixa no máximo 2 efeitos de partícula e 2 luzes. Se algo for
tirado, aparece um aviso no Output com o nome do modelo.

### Músicas e sons
Em `Config/Game`, preencha `Music` (uma por mapa, mais a do final) e `Sounds` (tiro, acerto, moeda,
explosão...) com os IDs dos áudios. Com `0` o jogo fica em silêncio, sem erro.

### Balanceamento
Todos os números estão em `ReplicatedStorage > Shared > Config`:

| Arquivo | O que controla |
|---|---|
| `Game` | Regras gerais: velocidade, limite de brainrots, carteira compartilhada, votação do portal |
| `Maps` | Os três mapas, multiplicadores de custo/vida por ato, iluminação |
| `Weapons` / `Stats` | Arma inicial e todos os atributos (dano, cadência, crítico, perfuração...) |
| `Upgrades` | Todos os upgrades de cada barraca (custo, efeito, nível máximo) |
| `Brainrots` / `Enchants` | Vida, valor e tamanho de cada brainrot; encantamentos (Dourado, Gelo, Fogo, Arco-íris...) |
| `Quests` / `Recipes` | Missões e receitas do caldeirão do Deserto |
| `Achievements` / `Cosmetics` | Conquistas e skins da loja do lobby |
| `Keybinds` | Teclas padrão (o jogador pode remapear nas Configurações) |

**Atenção:** os valores de custo, dano e vida foram criados para este projeto (o jogo original não
publica esses números). Eles foram ajustados com uma simulação para cada ato durar cerca de 35 a 50
minutos jogando sozinho. Jogue alguns atos e ajuste as tabelas ao seu gosto.

### Badges e game passes (opcional)
- **Badges:** crie em Creator Hub > sua experiência > Engajamento > Badges e coloque o id em
  `BadgeId` de cada conquista em `Config/Achievements`.

#### Game passes

O jogo já vem com **5 game passes** prontos. Eles ficam desligados até você criar os passes no
Roblox e colar os ids no `Config/Game`:

| Chave no Config | Nome no jogo | O que faz |
|---|---|---|
| `DoubleCoins` | Moedas em Dobro | Toda moeda que o dono ganha (brainrots, torretas e missões) vale o dobro. |
| `AutoCollect` | Coleta Automática | Ímã de moedas desde o começo da partida: as moedas a até 30 studs vêm sozinhas. |
| `ExtraTurret` | Torreta Extra | +1 torreta no limite do dono (Inverno e Deserto). |
| `VIP` | VIP | +25% em todas as moedas do dono (com o Moedas em Dobro junto fica ×2,5), etiqueta dourada "VIP" em cima da cabeça (no lobby e na partida) e `[VIP]` dourado antes do nome no chat. |
| `DoubleDamage` | Dano em Dobro | O dano da arma do dono vale o dobro, em todos os mapas. Só a arma dele: as torretas não mudam. |

Onde o jogador compra: botão **Vantagens** no HUD da partida e aba **Vantagens** na **Loja** do lobby.
A compra vale na hora, sem sair do jogo, e fica para sempre na conta dele. O **preço** que aparece
nas lojas é lido do Roblox (é o que você escolhe no Creator Hub, no passo 4): não existe preço no
código. Se você desligar a venda de um pass no Creator Hub, o botão dele vira **Indisponível**.

> **Regra importante: nunca venda moedas do jogo por Robux** (nem "pacote de moedas", nem produto
> que dê moedas). As moedas compram upgrades de sorte (Sorte de Tier, chance de encantamento), e
> com isso esses upgrades passariam a contar como **itens aleatórios pagos** nas regras do Roblox:
> seria preciso mostrar as chances e, no Brasil, esse tipo de item é bloqueado para menores de
> idade. Pelo mesmo motivo o jogo não tem pass de sorte: todos os passes dão bônus fixos.

**Passo a passo para colocar os passes à venda:**

1. Publique o jogo primeiro (seção 3): os passes pertencem à experiência.
2. Abra o **Creator Hub** (create.roblox.com) > **Criações** > clique na **sua experiência** >
   menu **Monetização** > **Passes**.
3. Clique em **Criar um passe** (Create a Pass), envie uma imagem, escreva o nome e a descrição
   (pode copiar da tabela acima) e confirme em **Criar passe**.
4. Clique no pass criado > **Vendas** (Sales): ligue **Item à venda**, escolha o **preço** em Robux
   e clique em **Salvar**.
5. Copie o **id** do pass: na lista de passes, clique nos três pontinhos (**...**) do pass >
   **Copiar ID do recurso** (Copy Asset ID). O id também é o número que aparece no endereço da página do pass.
6. Repita os passos 3 a 5 para cada pass que você quiser vender (não precisa criar todos).
7. No Studio, abra `ReplicatedStorage > Shared > Config > Game`, cole cada id no lugar do `0`
   e mude `Enabled` para `true`:
   ```lua
   Gamepasses = { Enabled = true, DoubleCoins = 1111111, AutoCollect = 2222222, ExtraTurret = 3333333, VIP = 4444444, DoubleDamage = 5555555 },
   ```
   Pass com id `0` não aparece nas lojas. Com `Enabled = false` (o padrão) as lojas de vantagens
   ficam escondidas.
8. Publique **nos dois places** (Lobby e Partida), como no passo 5 da seção 3.

Para testar no Studio: com os ids preenchidos, clique em **Comprar**. O Studio mostra uma compra de
teste (não gasta Robux) e a vantagem ativa na hora, só durante aquele teste.

Os bônus podem ser ajustados no mesmo `Config/Game`: `GamepassVipCoinMult` (1.25 = +25% do VIP) e
`GamepassAutoCollectRadius` (raio do ímã da Coleta Automática). Os textos das lojas acompanham os
números sozinhos.

---

## 5. Administradores

O jogo tem **comandos de administrador** que funcionam no jogo publicado (não só no Studio):
voar, dar moedas, fazer chover moedas, ligar eventos e mandar avisos para **todos os servidores**,
expulsar e banir. Quem confere se a pessoa é admin é sempre o servidor, em todo comando, e cada
comando usado aparece no Output com o nome de quem usou (linhas começando com `[Admin]`).

### Quem é admin

Tudo fica em `ReplicatedStorage > Shared > Config > Admins`:

- **Dono (cargo "Owner"): automático.** O jogo descobre sozinho quem é o dono da experiência:
  se a experiência é da sua conta, é você; se um dia ela for passada para um grupo (comunidade),
  é o dono do grupo. Além disso, o seu UserId (`335101108`) está em `OwnerUserIds`, então você
  continua "Owner" mesmo se o jogo mudar para um grupo.
- **Admin (cargo "Admin"):** quem está na lista `UserIds`. Ela já vem com o seu amigo (`1179661787`).
- **Grupo (opcional):** se o jogo for de um grupo, `GroupMinRank = 200` (por exemplo) deixa admin
  todo membro com cargo 200 ou mais. Com `0` (o padrão) isso fica desligado.
- **No Studio:** todo jogador de teste é admin (`StudioEveryoneAdmin = true`), para você testar.

### Como adicionar (ou tirar) um admin

1. Abra o perfil da pessoa no site do Roblox. O endereço tem este formato:
   `https://www.roblox.com/users/NUMERO/profile`. Esse **número é o UserId** da pessoa.
   Exemplo: `roblox.com/users/1179661787/profile` → UserId `1179661787`.
2. No Studio, abra `ReplicatedStorage > Shared > Config > Admins` e coloque o número na lista
   `UserIds`, separado por vírgula:
   ```lua
   UserIds = { 1179661787, 123456789 },
   ```
3. Publique **nos dois places** (Lobby e Partida) e use **Restart Servers** no Creator Hub.

Para **tirar** um admin, apague o número da lista e publique de novo. Use sempre o UserId (o
número), nunca o nome: o nome de usuário pode ser trocado, o UserId nunca muda.

> **Atenção: nunca dê admin para quem você não conhece de verdade.** Um admin pode expulsar e
> banir jogadores, dar moedas, mandar avisos para todos os servidores e ligar eventos. Ninguém
> consegue virar admin "pelo jogo": só quem está no `Config/Admins` (ou é o dono).

### Como usar

- **Chat:** digite `:` e o comando, por exemplo `:fly` ou `:coins all 1000`. A resposta aparece
  como aviso na sua tela (e o comando normalmente nem aparece no chat dos outros).
- **Painel:** admins veem um botão **ADMIN** no topo da tela (no PC, a tecla **F3** também abre).
  O painel tem abas com botões para cada comando.
- **Jogador** pode ser: o começo do nome (`hen`), o começo do nome de exibição, o UserId,
  `me` (você), `all` (todos) ou `others` (todos menos você). No `:kick` e no `:ban` vale só o
  nome **completo** (ou o UserId), para um erro de digitação não expulsar a pessoa errada.

| Comando | Exemplo | O que faz | Onde |
|---|---|---|---|
| `:fly` | `:fly` | Liga ou desliga o seu voo | Lobby e partida |
| `:speed <velocidade>` | `:speed 50` | Muda a sua velocidade (1 a 200; normal = 16) | Lobby e partida |
| `:jump <força>` | `:jump 120` | Muda a força do seu pulo (0 a 300; normal = 50) | Lobby e partida |
| `:tp <jogador>` | `:tp ana` | Leva você até um jogador | Lobby e partida |
| `:bring <jogador>` | `:bring all` | Traz um jogador (ou todos) até você | Lobby e partida |
| `:respawn [jogador]` | `:respawn ana` | Faz o personagem renascer (sem jogador = você) | Lobby e partida |
| `:coins <jogador> <quantia>` | `:coins all 10k` | Dá moedas (aceita `10k`, `3m`, `1b`...) | Só na partida |
| `:wave` | `:wave` | Planta uma leva de brainrots | Só na partida |
| `:giant` | `:giant` | Planta na hora uma leva só de gigantes | Só na partida |
| `:coinrain [quantia]` | `:coinrain 5000` | Chuva de moedas em volta de cada jogador (até `1b` por jogador; conta no placar) | Só na partida |
| `:maxall` | `:maxall` | Maxa todos os upgrades e prateleiras | Só na partida |
| `:nextact` | `:nextact` | Conclui o ato atual | Só na partida |
| `:supreme <0 a 1>` | `:supreme 0.9` | Define o progresso do Brainrot Supremo | Só na partida |
| `:ingredients [jogador]` | `:ingredients` | Dá 5 de cada ingrediente | Só na partida |
| `:tokens <jogador> <quantia>` | `:tokens ana 50` | Dá Brainrot Tokens (número negativo tira) | Lobby e partida |
| `:unlockall <jogador>` | `:unlockall me` | Libera todos os mapas no perfil | Lobby e partida |
| `:announce <texto>` | `:announce Evento às 18h!` | Aviso em **todos os servidores** (até 200 letras) | Lobby e partida |
| `:event <evento> <minutos>` | `:event moedas2x 30` | Liga um evento em **todos os servidores** (até 120 min) | Lobby e partida |
| `:endevent` | `:endevent` | Encerra o evento em todos os servidores | Lobby e partida |
| `:kick <jogador> [motivo]` | `:kick fulano spam` | Expulsa do servidor | Lobby e partida |
| `:ban <jogador> <duração> [motivo]` | `:ban fulano 7d xingando` | Bane do jogo todo: `30m`, `2h`, `1d`, `7d` ou `perm` (para sempre) | Lobby e partida |
| `:unban <userId>` | `:unban 123456789` | Tira o banimento | Lobby e partida |
| `:cmds` | `:cmds` | Mostra a lista de comandos | Lobby e partida |

Regras de segurança: ninguém consegue expulsar nem banir um admin ou o dono, e `all`/`others` não
valem para `:kick` e `:ban` (nem para tirar tokens com número negativo). Quem não é admin e digita um comando é ignorado.

Os comandos de teste com `/` (seção 2) continuam existindo, só no Studio. Os comandos com `:`
são os de admin e valem também nos servidores de verdade.

### Eventos globais

`:event <evento> <minutos>` liga um evento em **todos os servidores** (lobby e partidas) ao mesmo
tempo, com uma faixa e o tempo restante na tela de todo mundo. Servidores que abrirem durante o
evento também entram nele. Ele acaba sozinho no fim do tempo (ou com `:endevent`).

| Evento | Nome no jogo | Efeito |
|---|---|---|
| `moedas2x` | Moedas x2 | Todo mundo ganha o dobro de moedas (soma com os game passes) |
| `sorte` | Sorte Brainrot | +1 de Sorte de Tier e o dobro da chance de encantamento |
| `gigantes` | Invasão de Gigantes | +30% de chance de brainrot gigante |
| `abuse` | Admin Abuse | Tudo junto, e o quadro "Plantar brainrots" recarrega na metade do tempo |

Os eventos são **grátis** (você liga para todo mundo; ninguém paga Robux por eles), então não
entram nas regras de itens aleatórios pagos. Os números ficam em `Config/Admins > Events`.

### Banimento

O `:ban` usa o sistema de banimento oficial do Roblox. Ele já vem **ligado** no arquivo do jogo
(**Players > BanningEnabled** marcado). O ban vale para a experiência inteira (lobby e partida) e
também pega as contas alternativas da pessoa. No Studio o ban não vale de verdade (só no jogo
publicado), e como no Studio todo mundo é admin, para testar `:kick` e `:ban` lá mude
`StudioEveryoneAdmin` para `false` por um tempo.

Os avisos e os eventos usam o MessagingService e o MemoryStore do Roblox. Eles funcionam sozinhos
no jogo publicado; no Studio, ligue o acesso às APIs (seção 2) para testar.

## 6. Como o código é organizado

- `docs/ESPECIFICACAO.md`: o contrato entre todos os scripts (nomes de funções, remotes, dados salvos).
  É o melhor lugar para entender como as peças conversam.
- `docs/PROMPT_ORIGINAL.md`: o design completo do jogo (mecânicas, atos, lobby, interface).
- O servidor manda em tudo (dano, moedas, compras). O cliente só pede ações por um único
  `RemoteFunction` chamado `Request`, com limite de pedidos por segundo contra trapaça.
- O estado do jogo (moedas, upgrades, missões...) é enviado ao cliente 10 vezes por segundo pelo
  `StateService` e lido pelo `StateController`.
- O progresso do jogador fica num DataStore com trava de sessão; a partida em andamento é salva
  separadamente para o grupo poder continuar depois ou reconectar.
- Os comentários do código estão em português e explicam cada parte, para quem está aprendendo Lua.

## 7. Limites conhecidos

- O código foi verificado com checagem de sintaxe Luau, lint (selene) e várias rodadas de revisão,
  mas **não foi rodado dentro do Roblox** antes de chegar até você. Se aparecer um erro no Output do
  Studio, copie a mensagem (com o nome do script e a linha) e peça a correção.
- Teleporte, convites e servidores reservados só funcionam no jogo publicado.
- O balanceamento é um ponto de partida e ainda não foi testado jogando.
