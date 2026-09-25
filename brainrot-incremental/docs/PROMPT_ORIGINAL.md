# PROMPT: "Brainrot Incremental But With Guns" (Roblox / Luau)

> Copie tudo abaixo da linha e cole na IA que vai programar o jogo.
> Os números de balanceamento são sugestões minhas: o jogo original não publica os valores exatos. Ajuste à vontade no arquivo de configuração.

---

## 0. Seu papel e como entregar

Você é um desenvolvedor sênior de Roblox, especialista em **Luau**, Roblox Studio, arquitetura cliente-servidor, DataStores e TeleportService. Sua tarefa é programar um jogo completo e pronto para publicar chamado **"Brainrot Incremental But With Guns"** (nome provisório, deixe configurável).

Regras de entrega:

1. Escreva **código completo e funcional**, sem "TODO", sem "coloque sua lógica aqui", sem pseudocódigo. Cada script deve estar inteiro.
2. Para cada script diga **o nome exato, o tipo** (Script, LocalScript ou ModuleScript) e **onde ele fica no Explorer** do Roblox Studio (ex.: `ServerScriptService/Services/CoinService`).
3. Diga quais **objetos do Workspace** (Parts, Models, pastas, atributos) precisam existir e com qual nome. Se possível, gere esses objetos por código na primeira execução, para eu não precisar montar o mapa na mão.
4. Todo número de balanceamento (custos, danos, chances, tempos) fica em **ModuleScripts de configuração**, nunca espalhado no código.
5. Use `--!strict` quando fizer sentido, nomes em inglês no código e **comentários em português** explicando o que cada parte faz (eu estou aprendendo Lua).
6. Entregue em **fases** (ver seção 14). Ao fim de cada fase, diga como testar no Studio.
7. Se algo aqui estiver ambíguo, escolha a opção mais razoável, diga qual escolheu e continue.

---

## 1. O jogo original (referência que deve ser copiada)

O jogo de referência é **"Farming Incremental But With Guns"** (Steam, pamintandrei, agosto de 2026). É um **incremental em primeira pessoa**: plantações gigantes nascem no campo, você **atira nelas** com sua arma, elas explodem em **moedas físicas** que caem no chão, você **coleta** as moedas e gasta em **barracas de upgrade**. O objetivo final é fazer uma planta crescer tanto que **tampa o sol**.

O que se sabe do original e deve ser reproduzido:

- **Controles:** WASD anda, clique esquerdo atira, Espaço pula, **E interage** com estações. Tem opção de correr (com modo "alternar corrida"), inverter Y, FOV e remapear teclas.
- **Loop:** atirar nas plantas do campo → moedas aparecem **perto do caixote** (crate) → pegar moedas → comprar upgrades → quando o campo esvazia, **interagir com o quadro (board)** para fazer nascer uma nova leva.
- **Tiers de planta por valor:** baixo (Cogumelo Porcini, Trigo, Cana-de-açúcar), médio (Cenoura, Nabo, Morango) e alto (Abóbora, Cogumelo Trombeta-negra, Cogumelo Enoki). As plantas **crescem** com o tempo e com upgrades; maior = mais vida e mais moedas.
- **Barraca de Arma:** 6 upgrades (dano, cadência de tiro, mais projéteis e outros).
- **Barraca de Plantas:** começa com 4 upgrades (mais plantas por respawn, chance de a planta **explodir** ao morrer, chance de nascer planta **maior**, e mais um).
- **Upgrade da própria barraca:** quando você maxa **todos** os upgrades de **todas** as barracas, libera melhorar a barraca, que ganha **novas prateleiras** com upgrades novos: **ímã de moedas**, **coleta automática** (caro), **formas de mover plantas valiosas** até você e **níveis extras** para upgrades já maxados.
- **Barraca de Missões:** dá uma missão aleatória em troca de uma boa quantia de moedas; tem upgrades próprios que aumentam a recompensa e diminuem o tempo de espera.
- **Encantamentos de planta:** plantas podem nascer encantadas (ex.: **Gelo**), o que aumenta tamanho e recompensa. É a identidade do meio do jogo.
- **Tiers de moeda:** moedas de valores diferentes (bronze, prata, ouro...) para não lotar o mapa de peças.
- **3 Atos / biomas:**
  - **Ato 1, Prado:** ensina o loop; você anda pelo campo todo.
  - **Ato 2, Inverno (gelo):** libera quando você maxa tudo no Ato 1. **Todos os upgrades resetam**, você ganha uma **arma nova**, plantas novas e upgrades novos e mais caros, incluindo **torretas que você posiciona em qualquer lugar do campo**, e uma **estação de respawn** que chama as torretas de volta. É uma fase "peixe no barril" (você se move pouco). Pouca visibilidade por causa da neve. O encantamento de Gelo é muito mais forte aqui.
  - **Ato 3, Deserto:** mais uma arma nova, **receitas** e upgrades absurdamente fortes. É o ato favorito dos jogadores. Termina quando a planta gigante tampa o sol (há uma conquista secreta por completar o Ato 3).
- **Conquistas:** 7 no total, incluindo destruir 1.000 plantas de valor baixo e completar o Ato 3 (secreta).
- **Detalhes de qualidade:** plantas não nascem grudadas no jogador (área de exclusão ao redor dele); balas um pouco maiores que o visual para não errar por pouco; torretas não podem cair do mapa.

**Críticas dos jogadores que a sua versão deve corrigir:** as torretas do Ato 2 falhavam muito (deixe-as confiáveis) e o Ato 2 era limitado demais (deixe um pouco de movimento e variedade).

---

## 2. A nossa versão: brainrot no lugar das plantas

O jogo é **igual ao original**, mas em vez de plantas, o que nasce no campo e cresce são **brainrots** (personagens estilo "Italian Brainrot", muito populares no Roblox). Eles "brotam" do chão como plantas, crescem, balançam/dançam parados, e quando você atira neles explodem em moedas.

Regras do tema:

- Cada brainrot é um **Model** com `PrimaryPart`, escalado com `Model:ScaleTo()` conforme cresce.
- Crie **modelos provisórios** feitos com Parts simples (cores e formas que lembrem cada personagem) e deixe um campo `ModelName` na configuração para eu trocar pelo modelo final depois (colocado em `ServerStorage/BrainrotModels`). **Não copie modelos de outros jogos.**
- Ao nascer: animação de brotar do chão com partículas de terra. Ao morrer: explosão, som engraçado e chuva de moedas.
- Cada brainrot tem um **som/bordão** curto opcional (campo `SoundId` na configuração, pode ficar vazio).
- Mostre um `BillboardGui` acima de cada brainrot com nome, barra de vida e ícone de encantamento, visível só a uma certa distância.

### Tabela de brainrots (substitui a tabela de plantas)

| Ato | Tier | Brainrot | Equivalente no original |
|---|---|---|---|
| 1 Prado | Baixo | Tung Tung Tung Sahur | Cogumelo Porcini |
| 1 Prado | Baixo | Brr Brr Patapim | Trigo |
| 1 Prado | Baixo | Trippi Troppi | Cana-de-açúcar |
| 1 Prado | Médio | Chimpanzini Bananini | Cenoura |
| 1 Prado | Médio | Boneca Ambalabu | Nabo |
| 1 Prado | Médio | Ballerina Cappuccina | Morango |
| 1 Prado | Alto | Tralalero Tralala | Abóbora |
| 1 Prado | Alto | Cappuccino Assassino | Cogumelo Trombeta-negra |
| 1 Prado | Alto | Bombardiro Crocodilo | Cogumelo Enoki |
| 2 Inverno | Baixo/Médio/Alto | Frigo Camelo, Pinguino Congelino, Glorbo Gelatino, Orsetto Ghiacciolo, Tric Trac Baraboom, Bombombini Gusini, Tigrrullini Watermellini, Ta Ta Ta Sahur, La Vaca Saturno Saturnita | plantas do gelo |
| 3 Deserto | Baixo/Médio/Alto | Lirilì Larilà, Cactusino Bandito, Garamararam, Sahur del Deserto, Camello Tostato, Bananita Dolfinita, Burbaloni Luliloli, Graipussi Medussi, Tralalero Supremo | plantas do deserto |

Distribua os 9 brainrots de cada ato em 3 baixos, 3 médios e 3 altos. Nomes inventados acima podem ser trocados; mantenha tudo na configuração `Brainrots.lua`.

Cada entrada da configuração deve ter: `Id`, `DisplayName`, `Act`, `Tier` ("Low"/"Medium"/"High"), `BaseHealth`, `BaseCoinValue`, `BaseScale`, `MaxScale`, `GrowthPerSecond`, `SpawnWeight`, `ModelName`, `SoundId`, `Color`.

---

## 3. Arquitetura geral no Roblox

A experiência tem **2 places**:

1. **Lobby (place inicial):** onde os jogadores chegam, montam o grupo e escolhem a partida.
2. **Partida (place de jogo):** onde fica o mapa escolhido e o jogo acontece. Cada partida roda num **servidor reservado** (`TeleportService:ReserveServer`) só para aquele grupo.

Os dois places compartilham os mesmos módulos de configuração e o mesmo DataStore. Explique como publicar o segundo place dentro da mesma experiência (Asset Manager > Places) e onde colocar o `PlaceId` dele na configuração.

Estrutura de pastas (nos dois places, com o que for relevante a cada um):

```
ReplicatedStorage/
  Shared/
    Config/        -> Brainrots, Upgrades, Weapons, Maps, Quests, Enchants, Achievements, Lobby, Game
    Util/          -> NumberFormat, Signal, Maid/Trove, Types, Net (RemoteEvents/Functions)
  Remotes/         -> criado por código
ServerScriptService/
  Services/        -> DataService, LobbyService, PartyService, MatchService, BrainrotService,
                      CombatService, CoinService, UpgradeService, QuestService, TurretService,
                      RecipeService, EnchantService, AchievementService, ProgressionService
  Main.server.lua  -> inicializa os serviços na ordem certa
StarterPlayer/StarterPlayerScripts/
  Controllers/     -> WeaponController, CameraController, InputController, HUDController,
                      StallUIController, LobbyUIController, SettingsController, MobileController
  Main.client.lua
ServerStorage/
  BrainrotModels/, WeaponModels/, TurretModels/, Maps/
```

Regras técnicas obrigatórias:

- **Servidor é a autoridade** sobre moedas, vida dos brainrots, compras e progresso. O cliente só pede.
- Todo `RemoteEvent` valida os argumentos (tipo, faixa, distância) e tem **limite de frequência** por jogador.
- **Tiro:** o cliente faz o raycast e mostra o efeito na hora (bala visual, tracer, hitmarker); envia ao servidor a origem, a direção e o alvo. O servidor confere cadência máxima, distância, linha de visão aproximada e só então aplica dano. A "hitbox" da bala deve ser um pouco maior que o visual (use `Workspace:Spherecast` com raio configurável).
- **Desempenho:** limite de brainrots vivos e de moedas no chão (configurável). Quando passar do limite, **funda moedas próximas numa moeda de tier maior** (Bronze → Prata → Ouro → Diamante → Brainrot Dourado...). Use *object pooling* para balas e moedas. Ative `StreamingEnabled` com cuidado para os brainrots gigantes continuarem visíveis de longe (`ModelStreamingMode = Persistent` nos grandes).
- **Números grandes:** formate com sufixos (K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc...) num módulo `NumberFormat`. Custos seguem `custo = base * multiplicador ^ nível`.
- **DataStore:** use **ProfileStore** (ou implemente trava de sessão, tentativas com espera, salvamento em `BindToClose` e autosave a cada 60 s). Nunca perca dados entre o lobby e a partida: salve e libere o perfil **antes** do teleporte.
- Funciona em **PC, celular e console**: botão de tiro e mira na tela no celular, `ProximityPrompt` para interagir (tecla E / toque / botão X), `ContextActionService` para os comandos.

---

## 4. O LOBBY

O lobby é um mapa bonito e pequeno (tema fazenda brainrot) onde os jogadores esperam antes da partida.

### 4.1 Elementos físicos do lobby
- **Spawn** central com placa do jogo e placar de líderes (maior dinheiro total, mais brainrots destruídos, atos concluídos).
- **Mesa/terminal "Criar Partida"** (ProximityPrompt) que abre a interface de criação.
- **Quadro de Partidas Abertas** (ProximityPrompt e também botão no HUD) com a lista de grupos esperando.
- **Plataformas de grupo** (opcional, estilo elevador): ao criar um grupo, uma plataforma com o nome do dono fica marcada; quem entra nela entra no grupo (respeitando as regras de privacidade).
- **Área de conquistas e estatísticas** do jogador.
- **Loja de cosméticos** (skins de arma, rastro de bala) paga com uma moeda permanente de lobby (opcional, ver seção 12).

### 4.2 Criar partida (quem cria vira o "dono" do grupo)
A interface de criação tem:
1. **Escolha do mapa:** Prado (Ato 1), Inverno (Ato 2), Deserto (Ato 3). Mapas que o dono ainda não liberou aparecem com cadeado e o requisito ("Complete o Prado"). Cada mapa mostra imagem, descrição e o recorde do dono.
2. **Número máximo de jogadores:** de 1 a 8 (limites em `Config/Lobby`).
3. **Privacidade:**
   - **Público:** qualquer um pode entrar.
   - **Só amigos:** só amigos do dono podem entrar. Confira **no servidor** com `Player:IsFriendsWith(donoUserId)` (com cache e `pcall`).
   - **Privado/Convite:** só quem o dono convidar pelo botão "Convidar" (lista de jogadores do servidor) ou pelo convite do Roblox (`SocialService:PromptGameInvite`).
4. **Continuar partida salva ou começar do zero** (ver 5.5), quando o dono tiver um progresso salvo naquele mapa.
5. Botão **Criar**.

### 4.3 Dentro do grupo
- Janela do grupo com: mapa, privacidade, vagas (ex.: 3/6), lista de membros com foto (`Players:GetUserThumbnailAsync`) e status **Pronto/Não pronto**.
- O dono pode: trocar mapa, trocar limite, trocar privacidade, **expulsar**, **passar a liderança**, **iniciar**.
- Membros podem: marcar pronto, sair.
- **Iniciar** só funciona quando todos estão prontos (ou o dono força com confirmação). Contagem regressiva de 5 s visível para todos, que é cancelada se alguém sair.
- Se o dono sair, a liderança passa para o membro mais antigo; se o grupo ficar vazio, ele é desfeito.
- Chat de grupo não é necessário (o chat do Roblox basta).

### 4.4 Lista de partidas abertas
- Mostra grupos **Públicos** e, para cada jogador, os grupos **Só amigos** de donos que são amigos dele. Grupos privados não aparecem.
- Cada linha: nome do dono, mapa, vagas, botão Entrar (desativado se cheio ou sem permissão, com o motivo).
- Atualiza em tempo real (servidor envia mudanças).
- Os grupos existem **só no servidor de lobby atual**. (Opcional avançado: usar `MessagingService`/`MemoryStoreService` para listar grupos de outros servidores de lobby. Faça só se sobrar tempo, e deixe desligado por padrão.)

### 4.5 Teleporte para a partida
- Quando a contagem acaba: o servidor salva e libera o perfil de todos, chama `TeleportService:ReserveServer(PARTIDA_PLACE_ID)` e `TeleportService:TeleportAsync` com `TeleportOptions.ReservedServerAccessCode` e `TeleportOptions:SetTeleportData` contendo: `mapId`, `maxPlayers`, `privacy`, `hostUserId`, `memberUserIds`, `resumeSave` (bool).
- Mostre uma **tela de carregamento personalizada** (`TeleportService:SetTeleportGui`) com o mapa escolhido.
- Trate falhas com `TeleportInitFailed`: tente de novo até 3 vezes e, se falhar, devolva todos ao grupo com aviso.
- **No servidor de partida:** como o TeleportData do cliente pode ser falsificado, guarde os dados do grupo no **MemoryStoreService** (chave = access code do servidor reservado, expira em 10 min) antes do teleporte, e o servidor de partida lê de lá. Quem chegar e não estiver na lista de membros é mandado de volta ao lobby.
- Um membro que cair pode **voltar para a mesma partida** pelo lobby (botão "Reconectar" enquanto o servidor reservado existir; guarde o access code no perfil).

---

## 5. A PARTIDA (regras gerais, valem para os 3 atos)

### 5.1 Multijogador
- **Moedas são individuais:** a moeda vai para quem a pegou. Com o ímã/coleta automática, a moeda vai para o jogador mais perto dela.
- **Upgrades de arma são individuais** (cada um compra os seus com as suas moedas).
- **Upgrades de brainrot/campo, de barraca, torretas e receitas são do time:** qualquer um compra com as próprias moedas e o efeito vale para todos. A interface mostra quem comprou.
- **Missões** são individuais.
- Os requisitos para liberar o próximo ato (maxar tudo) consideram os upgrades do time mais os upgrades de arma de **pelo menos um** jogador. Deixe essa regra configurável.
- Dificuldade escala com o número de jogadores: vida dos brainrots × (1 + 0,35 × (jogadores − 1)), configurável.
- Deixe uma opção em `Config/Game` para trocar para **carteira compartilhada** (todas as moedas vão para um cofre do time), caso eu prefira depois.

### 5.2 O campo e o quadro
- Cada mapa tem uma **área de campo** (definida por uma Part invisível `FieldArea`) onde os brainrots brotam em posições aleatórias, respeitando: distância mínima entre eles, **área de exclusão em volta dos jogadores** (não nascer em cima ou empurrar ninguém) e ficar dentro do campo.
- **Quadro de respawn (Board):** ProximityPrompt "Plantar brainrots". Faz nascer uma nova leva com `N` brainrots (N vem do upgrade). Tem tempo de recarga curto (configurável, 3 s). Com upgrade de "respawn automático" (prateleira 2), o quadro se ativa sozinho quando o campo fica abaixo de X% da leva.
- Ao brotar, o brainrot começa pequeno (`BaseScale`) e **cresce** até o tamanho alvo daquela leva. Vida e valor em moedas acompanham o tamanho: `vida = BaseHealth * escala^2`, `moedas = BaseCoinValue * escala^2 * multiplicadores`.
- A escolha de qual brainrot nasce usa pesos por tier (`SpawnWeight`), modificados pelos upgrades de chance.

### 5.3 Moedas
- Ao morrer, o brainrot solta moedas **físicas** que saltam e caem **perto do caixote (Crate)** do mapa (como no original), com um pouco de espalhamento. Deixe também a opção de soltar no local da morte (`CoinDropMode = "Crate" | "OnDeath"`).
- Tiers de moeda: Bronze (1), Prata (10), Ouro (100), Esmeralda (1K), Diamante (10K), Brainrot Dourado (100K), e acima disso o valor da moeda escala sozinho. O servidor divide o valor total na menor quantidade de moedas (máx. configurável por morte).
- Coleta ao encostar (Touched no servidor com checagem de distância) e som satisfatório + número flutuante "+1,2K".
- Moedas somem depois de 120 s se ninguém pegar (configurável), exceto se a coleta automática estiver ativa.

### 5.4 Fim do ato
- Quando todos os upgrades do ato estão no máximo, aparece um **portal** para o próximo ato com anúncio para todos. Entrar no portal (voto da maioria ou decisão do dono, configurável) **teleporta o grupo para um novo servidor reservado com o próximo mapa**, e o próximo mapa fica **liberado permanentemente** no perfil de todos os membros presentes.
- No Ato 3, o final é o brainrot gigante tampando o sol (seção 8.4).

### 5.5 Salvar a partida
- O progresso **dentro** da partida (moedas de cada jogador, upgrades, torretas posicionadas, receitas, missões) é salvo a cada 60 s e ao fechar o servidor, numa chave `Run_<hostUserId>_<mapId>`.
- Cada jogador salva também a sua parte (moedas e upgrades de arma) para não perder se sair.
- No lobby, ao criar partida com um mapa que tem save, o dono escolhe **Continuar** ou **Começar do zero**.

### 5.6 Arma, mira e câmera
- Câmera **primeira pessoa travada** (`CameraMode = LockFirstPerson`) na partida; terceira pessoa livre no lobby.
- Arma segurada como **Tool** com modelo simples, recuo visual, flash de cano, tracer, som, hitmarker e número de dano flutuante. Crítico com número maior e cor diferente.
- **Tiro automático** segurando o botão (cadência vem do upgrade).
- Configurações: sensibilidade, inverter Y, FOV (60 a 110), alternar corrida, volume de música/efeitos, mostrar números de dano, **remapear teclas** (incluindo WASD, que o original teve de adicionar num patch). Salvas no perfil.

### 5.7 Barracas (stalls)
- Cada barraca é um Model com balcão e **prateleiras**; cada upgrade é um item físico na prateleira com um ProximityPrompt e também aparece numa interface ao interagir com o balcão.
- A interface mostra: nome, ícone, descrição, nível atual/máximo, efeito atual → próximo, custo (verde se dá para comprar), botão comprar, e **comprar ×10 / comprar máximo**.
- **Upgrade da barraca:** botão que só libera quando todos os upgrades de **todas** as barracas daquele ato estão no máximo. Cada nível da barraca adiciona uma prateleira física nova com upgrades novos (a barraca cresce visualmente).

---

## 6. ATO 1: PRADO (mapa "Prado Brainrot")

**Layout:** campo retangular grande e aberto no centro, cercado por cerca de madeira. De um lado, a "praça" com: **Quadro** de respawn, **Caixote** das moedas, **Barraca de Arma**, **Barraca de Brainrots**, **Barraca de Missões** e o local onde o **portal** do próximo ato aparece. Colinas baixas e árvores em volta, céu com sol grande visível. Jogador anda livremente por todo o campo.

**Arma inicial:** "Pistola de Espaguete" (nome livre). Um tiro por vez, cadência média.

### 6.1 Barraca de Arma (6 upgrades)

| Upgrade | Efeito por nível | Máx | Custo base | Mult. |
|---|---|---|---|---|
| Dano | +25% dano (multiplicativo) | 25 | 10 | 1,55 |
| Cadência | +8% tiros/s | 20 | 15 | 1,6 |
| Projéteis | +1 projétil por tiro (em leque) | 8 | 250 | 3,2 |
| Perfuração | bala atravessa +1 brainrot | 6 | 500 | 3,5 |
| Chance de Crítico | +3% chance (crítico = 2× dano, aumentável depois) | 15 | 100 | 1,9 |
| Calibre | bala +10% maior e +10% mais rápida | 10 | 60 | 1,8 |

### 6.2 Barraca de Brainrots (4 upgrades iniciais)

| Upgrade | Efeito por nível | Máx | Custo base | Mult. |
|---|---|---|---|---|
| Mais Brainrots | +1 brainrot por respawn (começa com 5) | 20 | 20 | 1,65 |
| Brainrot Explosivo | +2% chance de explodir ao morrer, causando dano em área (40% da vida máx. dele) nos vizinhos, o que pode gerar reação em cadeia | 15 | 150 | 1,9 |
| Brainrot Gigante | +2% chance de nascer 3× maior (mais vida, muito mais moedas) | 15 | 200 | 1,95 |
| Adubo Brainrot | +15% tamanho alvo e velocidade de crescimento | 20 | 40 | 1,7 |

### 6.3 Barraca de Missões
- Botão "Pegar missão". Dá uma missão aleatória de uma lista: "Destrua 50 brainrots", "Destrua 5 brainrots de tier Alto", "Colete 10K moedas", "Cause 3 explosões em cadeia", "Destrua um Gigante", "Acerte 20 críticos", "Destrua 3 encantados" etc. Alvos escalam com o progresso.
- Recompensa: moedas (baseadas na renda atual do jogador, ex.: 90 s de renda média).
- Tempo de espera entre missões: 60 s.
- Upgrades da barraca de missões: **Recompensa** (+20% por nível, máx 10) e **Espera** (−8% por nível, máx 8).
- Mostrar missão ativa e progresso no HUD.

### 6.4 Upgrade da Barraca (prateleiras novas)
Liberado quando tudo acima está no máximo. Cada nível de barraca libera novas prateleiras:

- **Prateleira 2 (Arma):** Multiplicador de Crítico (+0,25×), Dano+ (níveis extras de dano), Cadência+.
- **Prateleira 2 (Brainrots):** **Ímã de Moedas** (raio de atração +4 studs por nível), **Coleta Automática** (1 nível, muito caro: toda moeda vai direto para o jogador mais perto), **Atrair Brainrots Valiosos** (brainrots de tier Alto e Gigantes andam devagar até o jogador mais próximo), **Respawn Automático** do quadro, **Chance de Tier Alto** (+peso para tier Médio/Alto), **Chance de Encantamento** (libera encantamentos, seção 9).
- **Prateleira 3:** níveis extras (+10 níveis máx.) para todos os upgrades da barraca de brainrots, **Multiplicador de Moedas** (+10% por nível).
Deixe tudo isso em `Config/Upgrades` com `Act`, `Stall`, `ShelfLevel`, `Id`, `Name`, `Description`, `MaxLevel`, `BaseCost`, `CostMultiplier`, `EffectPerLevel`, `EffectType`, `Scope` ("Player" ou "Team").

---

## 7. ATO 2: INVERNO (mapa "Tundra Congelini")

- Ao entrar, **todos os upgrades do ato anterior zeram** (moedas também). Os upgrades novos são mais caros (custo base × 25).
- **Arma nova:** "Canhão de Gelato" (nome livre): tiro mais lento, projétil que causa dano em área pequena e **desacelera** o brainrot.
- **Layout "peixe no barril":** o time fica numa **plataforma elevada** de madeira no meio de um vale de neve, com as barracas, o quadro e o caixote em cima da plataforma. Os brainrots brotam no vale em volta. Os jogadores podem andar pela plataforma (e ela é grande o bastante para não ficar parado) e descer por uma rampa para pegar moedas se não tiverem coleta automática.
- **Nevasca:** neblina (`Atmosphere`) e partículas de neve que diminuem a visibilidade; um upgrade "Lanterna/Farol" aumenta a visibilidade.
- **Brainrots do inverno** (tabela da seção 2). Alguns nascem **congelados** (camada de gelo que precisa ser quebrada primeiro, com vida extra).
- **Encantamento de Gelo** muito mais forte neste ato (multiplicador de moedas e chance maiores).
- Barracas: Arma (6 upgrades equivalentes aos do Ato 1, adaptados à arma nova, ex.: raio de explosão no lugar de perfuração), Brainrots (4), Missões, e a **Barraca de Torretas**.

### 7.1 Torretas (corrigir o problema do original)
- Comprar uma torreta dá um item; o jogador **posiciona** onde quiser no campo (modo de colocação com prévia verde/vermelha, girar com R, confirmar com clique/toque). Pode recolher e reposicionar.
- Torretas miram sozinhas no brainrot mais valioso ou mais perto (modo alternável na torreta), com raycast de linha de visão, e **nunca** ficam presas: são ancoradas, colocadas com raycast no chão e checagem de área válida.
- **Estação de Respawn de Torretas:** botão que devolve todas as torretas para a base (como no original), mesmo sendo raro precisar.
- Upgrades da barraca de torretas: Quantidade máxima (+1), Dano, Cadência, Alcance, **Mira** (precisão, "treino de mira"), Moedas de torreta (+% das moedas de abates feitos por torretas).
- Moedas de abates de torreta vão para **quem posicionou** a torreta (ou divididas, configurável).
- Limite total de torretas por jogador e por servidor (desempenho).

- **Upgrade da Barraca** no Ato 2 libera: Ímã, Coleta Automática, Torreta Congelante (desacelera), Aura de Gelo, níveis extras.
- Fim: maxar tudo → portal para o Deserto.

---

## 8. ATO 3: DESERTO (mapa "Deserto Sahur")

- Upgrades zeram de novo; custos base × 25 em relação ao Ato 2.
- **Arma nova:** "Metralhadora de Tralalero" (nome livre): cadência altíssima, com **superaquecimento** (barra de calor; upgrades reduzem o calor e aumentam o limite).
- **Layout:** arena de areia em volta de um **oásis** central com as barracas. Dunas nas bordas, miragens (efeito visual), e uma **Grande Cova** no centro onde nasce o brainrot final.
- **Calor do deserto:** ficar muito tempo longe da sombra do oásis dá leve lentidão (efeito visual de calor); upgrade "Chapéu de Palha" anula. Leve, não pode ser chato.
- **Brainrots do deserto** (tabela da seção 2) e as mesmas barracas (Arma, Brainrots, Missões, Torretas herdadas com upgrades novos).

### 8.1 Receitas (Laboratório Brainrot)
Como no original, o Ato 3 tem **receitas** com efeitos muito fortes:
- Brainrots do deserto às vezes soltam **ingredientes** (ex.: "Areia Mística", "Espresso Assassino", "Banana Cósmica", "Tamborim de Sahur", "Gelo Eterno") além das moedas.
- No **Caldeirão** do oásis, o jogador combina ingredientes + moedas para fazer uma receita. Cada receita dá um bônus permanente **para o time** naquela partida, ex.: "Dano ×2", "Moedas ×3", "Todo brainrot nasce encantado por 60 s", "Gigantes garantidos na próxima leva", "Torretas atiram 2× mais rápido", "Crescimento ×5".
- Receitas são descobertas: a primeira vez mostra "???" com dicas; ao acertar, fica registrada num **Livro de Receitas** (salvo no perfil).
- Deixe tudo em `Config/Recipes`.

### 8.2 Barraca de Crescimento Supremo
Upgrades que fazem o **Brainrot Supremo** (na Grande Cova) crescer: Fertilizante (tamanho), Irrigação (velocidade), Raiz Profunda (vida), cada um bem caro.

### 8.3 O Brainrot Supremo
- Um brainrot único ("Tralalero Supremo" ou outro) que cresce continuamente na Grande Cova conforme os upgrades e conforme os jogadores **alimentam** ele com moedas (botão "Alimentar": converte moedas em crescimento).
- Barra no HUD: "Tamanho do Supremo: X% do céu".
- Sombra dele vai cobrindo o mapa e a iluminação (`Lighting`) escurece aos poucos.

### 8.4 Final
- Quando chega a 100%: ele **tampa o sol**. Cena final: câmera sobe mostrando o brainrot gigante na frente do sol, tudo escurece, música épica, créditos rolando (com os nomes dos jogadores do grupo), conquista secreta "Eclipse Brainrot" para todos.
- Depois do final, o grupo volta ao lobby e o perfil marca "Jogo concluído" (libera cosméticos e o modo **Infinito** opcional no Deserto, onde tudo continua escalando).

---

## 9. Encantamentos (valem nos 3 atos, liberados pelo upgrade "Chance de Encantamento")

Brainrots podem nascer encantados. Encantamento aparece com cor, partículas e ícone no BillboardGui.

| Encantamento | Visual | Efeito |
|---|---|---|
| Dourado | brilho dourado | ×3 moedas |
| Gelo | cristais azuis | ×2 tamanho, ×4 moedas (×10 no Ato 2) |
| Fogo | chamas | ao morrer, incendeia vizinhos (dano por segundo) |
| Arco-íris | cores alternando | ×10 moedas, raro |
| Radioativo | verde brilhante | cresce 3× mais rápido |
| Galáctico | estrelas | ×50 moedas, ultra raro, anúncio para o servidor |

Chances, multiplicadores e em quais atos cada um aparece ficam em `Config/Enchants`. Upgrades aumentam a chance e o multiplicador de cada encantamento.

---

## 10. Interface (HUD e menus)

- **HUD da partida:** moedas (com animação ao ganhar), renda por segundo estimada, mira no centro, missão ativa, barra de calor (Ato 3), barra do Supremo (Ato 3), contador de brainrots vivos, botão de configurações, botão "Voltar ao lobby" (com confirmação).
- **Lista de jogadores do time** no canto com moedas de cada um.
- **Notificações** no topo: "Fulano comprou Brainrot Gigante nv. 5", "Um brainrot Galáctico nasceu!", "Portal para o Inverno aberto!".
- **Menu de barraca**, **menu de missões**, **Livro de Receitas**, **modo de colocação de torreta**.
- **HUD do lobby:** botão Criar Partida, botão Partidas Abertas, janela do grupo, conquistas, estatísticas, configurações.
- Visual: estilo cartunesco e colorido, fontes grandes (`Enum.Font.FredokaOne` ou `GothamBold`), cantos arredondados (`UICorner`), `UIStroke`, animações com `TweenService`. Tudo com `UIScale`/`AutomaticSize` para funcionar em celular.

---

## 11. Conquistas e estatísticas (salvas no perfil)

Recrie 7 conquistas como no original, mais algumas extras:
1. **Primeiro Brainrot**: destrua 1 brainrot.
2. **Colheita de Sahur**: destrua 1.000 brainrots de tier Baixo.
3. **Coleção Média**: destrua 500 brainrots de tier Médio.
4. **Caçador de Lendas**: destrua 100 brainrots de tier Alto.
5. **Complete o Prado**.
6. **Complete o Inverno**.
7. **Eclipse Brainrot** (secreta): complete o Deserto.
Extras: primeiro Galáctico, 100 explosões em cadeia, 1 bilhão de moedas coletadas, jogar com 4 amigos.

Estatísticas: brainrots destruídos por tier, moedas totais, tiros, críticos, tempo jogado, atos concluídos, receitas descobertas. Integrar com `BadgeService` (IDs de badge configuráveis, podem ficar vazios).

---

## 12. Extras opcionais (deixe desligados por padrão em `Config/Game`)
- **Game passes** (IDs configuráveis): 2× Moedas, Coleta Automática desde o início, Torreta extra. Use `MarketplaceService` com `ProcessReceipt` correto.
- **Moeda de lobby** ("Brainrot Tokens") ganha ao completar atos, para comprar skins de arma e rastros de bala.
- **Música** por mapa (IDs configuráveis).

---

## 13. Segurança e qualidade
- Nunca confie no cliente para moedas, dano, compras ou posição de torreta.
- `pcall` em toda chamada de DataStore, MemoryStore, Teleport, BadgeService e amizade.
- Limpe conexões (`Maid`/`Trove`) quando jogadores saem e quando brainrots morrem.
- Evite loops `while true do wait()`; use `RunService.Heartbeat` com agendamento ou `task.wait` com intervalo sensato.
- Crescimento dos brainrots: atualize escala em lotes (ex.: 10 vezes por segundo no servidor, interpolado no cliente), não em todo frame.
- Log de erros claro no Output com prefixo do serviço (ex.: `[CoinService]`).
- Escreva um **modo de teste**: comando no Studio (atributo `DebugMode` no Workspace) que dá moedas infinitas, maxa upgrades e pula ato, para eu testar rápido.

---

## 14. Ordem de entrega (fases)

1. **Base:** estrutura de pastas, módulos de configuração completos, Net/Remotes, NumberFormat, DataService com ProfileStore.
2. **Ato 1 jogável sozinho:** arma e tiro, brainrots brotando e crescendo, quadro, caixote e moedas com tiers, Barraca de Arma e de Brainrots, HUD.
3. **Ato 1 completo:** missões, upgrade da barraca e prateleiras, ímã, coleta automática, atrair valiosos, encantamentos, portal.
4. **Lobby:** criação de grupo, mapa, limite de jogadores, privacidade (público/só amigos/convite), lista de partidas, prontos, contagem, teleporte com servidor reservado e MemoryStore, reconexão.
5. **Multijogador na partida:** regras da seção 5.1, escala de dificuldade, salvar/continuar partida.
6. **Ato 2:** mapa de inverno, arma nova, reset de upgrades, torretas e estação de respawn, nevasca, encantamento de gelo.
7. **Ato 3:** mapa do deserto, metralhadora com calor, receitas e caldeirão, Brainrot Supremo e cena final.
8. **Polimento:** conquistas, badges, configurações e remapeamento de teclas, suporte a celular/console, efeitos, sons, otimização.

Em cada fase: liste os arquivos criados/alterados, o código completo de cada um e um roteiro curto de teste no Studio (incluindo como testar com 2+ jogadores em **Test > Clients and Servers**, e lembrando que teleporte e servidor reservado só funcionam no jogo publicado, então simule isso no Studio com um modo local que carrega o mapa direto).
