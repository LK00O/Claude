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

Fora do Studio os comandos ficam desligados. Só ligue `DebugMode = true` no `Config/Game` para testar
num servidor de verdade e desligue antes de abrir o jogo ao público.

---

## 3. Publicar no Roblox

A experiência tem **dois places**: o **Lobby** (place inicial) e a **Partida**. Os dois recebem **o mesmo arquivo**.

1. Com o `.rbxlx` aberto, vá em **Arquivo > Publicar no Roblox**, crie uma experiência nova e dê um nome.
   Esse primeiro place vira o **place inicial**, que será o lobby.
2. Abra **Exibir > Gerenciador de ativos > Places**, clique com o botão direito e escolha
   **Adicionar novo place**. Renomeie para "Partida".
3. Ainda em **Places**, clique com o botão direito em cada place e use **Copiar ID** para pegar os dois números.
4. No script `ReplicatedStorage > Shared > Config > Game`, preencha:
   ```lua
   LobbyPlaceId = 1234567890, -- id do place inicial
   MatchPlaceId = 9876543210, -- id do place "Partida"
   ```
5. Publique de novo **nos dois places**: **Arquivo > Publicar no Roblox como...**, escolha a sua
   experiência e depois o place (faça uma vez para o Lobby e outra para a Partida).
6. Em **Configurações do jogo**:
   - **Segurança:** ligue **Habilitar acesso do Studio aos serviços de API** (só para testar no Studio;
     nos servidores de verdade o DataStore já funciona).
   - **Permissões:** deixe a experiência **Pública** quando quiser abrir para todos.
7. Toda vez que mudar o código, publique **nos dois places** para os dois ficarem iguais.

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

## 5. Como o código é organizado

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

## 6. Limites conhecidos

- O código foi verificado com checagem de sintaxe Luau, lint (selene) e várias rodadas de revisão,
  mas **não foi rodado dentro do Roblox** antes de chegar até você. Se aparecer um erro no Output do
  Studio, copie a mensagem (com o nome do script e a linha) e peça a correção.
- Teleporte, convites e servidores reservados só funcionam no jogo publicado.
- O balanceamento é um ponto de partida e ainda não foi testado jogando.
