# Especificação técnica: Brainrot Incremental But With Guns

Este documento é o **contrato** entre todos os scripts do jogo. Qualquer nome de módulo, função, remote, chave de estado, atributo ou campo de configuração citado aqui deve ser usado **exatamente** assim. Se um script precisar de algo que não está aqui, ele cria isso de forma privada (local), sem mudar o contrato.

A referência de design (o que o jogo faz) é o arquivo `docs/PROMPT_ORIGINAL.md`. Em caso de dúvida de *comportamento*, siga o prompt; em caso de dúvida de *interface*, siga esta especificação.

---

## 1. Convenções gerais

- Linguagem: **Luau** (Roblox). Pode usar `+=`, `continue`, `table.clone`, `task.*`, anotações de tipo opcionais. **Não** use `--!strict` (os módulos se cruzam demais); use `--!nonstrict` ou nada.
- Código em inglês (nomes), **comentários em português** explicando o que cada parte faz (o dono está aprendendo Lua). Todo texto visível ao jogador em **português do Brasil**.
- Tempo compartilhado: sempre `workspace:GetServerTimeNow()` (servidor e cliente). Nunca `tick()`.
- Nada de `wait()`, `spawn()`, `delay()`: use `task.wait`, `task.spawn`, `task.delay`.
- Toda chamada que pode falhar (DataStore, MemoryStore, Teleport, BadgeService, MarketplaceService, `IsFriendsWith`, `GetNameFromUserIdAsync`, `GetUserThumbnailAsync`) vai dentro de `pcall`.
- Formato dos arquivos (padrão Rojo): `Nome.server.lua` = **Script**, `Nome.client.lua` = **LocalScript**, `Nome.lua` = **ModuleScript**. Pastas = `Folder`.
- Todos os números de balanceamento ficam em `Shared/Config`. Nenhum número mágico de balanceamento no código dos serviços (constantes técnicas como "10 Hz" podem ficar no código, com comentário).
- Moedas podem ficar enormes (até ~1e15 ou mais): sempre `number` (double), formatado com `NumberFormat`.

### 1.1 Estrutura de pastas (= Explorer do Roblox Studio)

```
src/
  ReplicatedStorage/
    Shared/                      (Folder)
      Config/                    (Folder)  Game, Lobby, Maps, Stats, Weapons, Upgrades, Brainrots,
                                           Enchants, Coins, Quests, Recipes, Achievements, Cosmetics, Keybinds, Admins,
                                           Audio
      Util/                      (Folder)  Signal, Trove, Net, NumberFormat, Formulas, PlaceRole, Tables, Gamepasses
  ServerScriptService/
    Main.server.lua              (Script: inicializa tudo)
    Services/                    (Folder)  DataService, StateService, SettingsService, TravelService,
                                           AchievementService, DebugService, AdminService,
                                           LobbyService, PartyService, ShopService,
                                           MatchService, StatService, MonetizationService, CoinService,
                                           BrainrotService, CombatService, UpgradeService, ProgressionService,
                                           QuestService, TurretService, RecipeService, SupremeService
    World/                       (Folder)  MapBuilder, BrainrotFactory, TurretFactory
      Builders/                  (Folder)  Common, Lobby, Meadow, Winter, Desert
  StarterPlayer/
    StarterPlayerScripts/
      Main.client.lua            (LocalScript: inicializa o cliente)
      Controllers/               (Folder)  StateController, NotifyController, PromptController,
                                           CameraController, MovementController, MobileController,
                                           MusicController, WeaponController, EffectsController,
                                           HUDController, PlacementController, EndingController,
                                           ChatTagController, FlyController, AnnouncementController,
                                           AmbientController
      UI/                        (Folder)  UIKit, StallWindow, CauldronWindow, SupremeWindow,
                                           SettingsWindow, DebugPanel, AdminPanel, LobbyUI
                                           (+ LobbyCreate, LobbyList, LobbyParty, LobbyShop, LobbyAchievements)
```

Caminhos de `require`:
- Compartilhado: `local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")`, depois `require(Shared.Config.Game)`, `require(Shared.Util.Net)` etc.
- Servidor: `local ServerScriptService = game:GetService("ServerScriptService")`, `ServerScriptService.Services.X`, `ServerScriptService.World.MapBuilder`, `ServerScriptService.World.Builders.Common`.
- Cliente: os módulos ficam em `Players.LocalPlayer.PlayerScripts`. Use caminhos relativos: dentro de `Controllers/X.lua`, `script.Parent.StateController` e `script.Parent.Parent.UI.UIKit`; dentro de `UI/X.lua`, `script.Parent.UIKit` e `script.Parent.Parent.Controllers.StateController`.

### 1.2 Regra anti-require-circular (IMPORTANTE)

`require` circular trava no Roblox. Então:
- **No topo** de um serviço do servidor só pode dar `require` em: módulos de `Shared`, módulos de `World`, e nos serviços-folha **`DataService` e `StateService`**.
- Qualquer outro serviço é acessado **dentro de funções** com um helper local:
  ```lua
  local Services = script.Parent
  local function Svc(name) return require(Services:WaitForChild(name)) end
  -- uso: Svc("MatchService").AddCoins(player, 10, "Kill")
  ```
- `DataService` e `StateService` não dão `require` em nenhum outro serviço no topo.
- No cliente: no topo só `Shared`, `UIKit`, `StateController` e `NotifyController`. Outros controllers/janelas são acessados dentro de funções (mesmo helper, apontando para a pasta certa).
- `World/*` não dá `require` em nenhum serviço.

### 1.3 Ciclo de vida

Todo serviço (servidor) e todo controller/janela (cliente) é uma tabela com `Init()` e `Start()` (podem ser vazias). `Init` prepara (conecta remotes, cria pastas) e não deve esperar outros serviços; `Start` roda depois que todos fizeram `Init`. Quem chama é o `Main`.

### 1.4 Papel do servidor (Lobby ou Partida)

O mesmo arquivo `.rbxl` é publicado **nos dois places** da experiência. O papel é decidido por `Util/PlaceRole`:
- `PlaceRole.Get()` → `"Lobby"` ou `"Match"`.
  0. **Só no Studio:** se o papel da sessão foi trocado com `PlaceRole.SetRuntimeRole(role)` (troca lobby → partida no mesmo servidor, abaixo), devolve esse papel antes de tudo.
  1. **Só no Studio** (`RunService:IsStudio()`): se `workspace:GetAttribute("ForceRole")` for `"Lobby"`/`"Match"`, usa isso. Num jogo publicado o atributo é ignorado (se ficasse salvo no place, um servidor poderia virar partida e mandar todos de volta ao lobby sem fim).
  2. Trava contra configuração errada: se `Config.Game.LobbyPlaceId ~= 0` e `LobbyPlaceId == MatchPlaceId`, avisa **uma vez** no Output (`"[PlaceRole] LobbyPlaceId e MatchPlaceId iguais: usando Lobby"`) e usa `"Lobby"` (o lobby nunca teleporta sozinho).
  3. Se `game.PlaceId ~= 0` e `game.PlaceId == Config.Game.MatchPlaceId` → `"Match"`.
  4. Se `game.PlaceId ~= 0` e `game.PlaceId == Config.Game.LobbyPlaceId` → `"Lobby"`.
  5. Se `RunService:IsStudio()` → `Config.Game.StudioRole` (padrão da 2.0: `"Lobby"`).
  6. Senão → `"Lobby"`.
- `PlaceRole.SetRuntimeRole(role) -> boolean` — **só no Studio**: guarda um papel "da sessão" (`"Lobby"` ou `"Match"`; `nil` apaga) que o `Get()` devolve primeiro (passo 0). Outro texto é recusado com `warn` (devolve `false`). Fora do Studio a chamada é ignorada com `warn` e devolve `false`: num jogo publicado o papel vem só dos PlaceIds. Muda só o que o `Get()` responde; quem muda o atributo `Role` é o `Main`.
- Outras travas contra loop de teleporte: `TravelService.SendToLobby` devolve `false` (sem teleportar) fora do Studio quando `LobbyPlaceId == game.PlaceId` (ou `LobbyPlaceId == 0`), e `TravelService.SendToNewMatch` recusa quando `LobbyPlaceId == MatchPlaceId` (seção 8.16).
- O servidor, no `Main`, grava `workspace:SetAttribute("Role", role)`. **O cliente lê o papel desse atributo** (espera até existir), nunca calcula sozinho, e continua ouvindo o atributo depois (seção 10.1).
- `PlaceRole.IsStudio()` → `RunService:IsStudio()`.

**Teste no Studio: lobby → partida no mesmo servidor** (o teleporte não funciona no Studio; fluxo completo na seção 8.16):
- Com `Config.Game.StudioRole = "Lobby"` (padrão) e `Config.Game.StudioInPlaceMatch = true` (padrão), o Play abre o **lobby**. Quando um grupo inicia, o **mesmo servidor** desliga o lobby, monta o mapa escolhido e vira a partida.
- Durante a troca o servidor grava no `workspace` os atributos `StudioSwitching: boolean` (`true` enquanto troca) e `StudioSwitchMap: string` (o `MapId` escolhido; é gravado antes do `StudioSwitching`). No fim os dois são apagados (`nil`): quem lê trata `nil`/`false` como "não está trocando".
- O atributo `Role` muda de `"Lobby"` para `"Match"` **no máximo uma vez por sessão do Studio** (junto com `PlaceRole.SetRuntimeRole("Match")`). Nunca volta de `"Match"` para `"Lobby"`: o fim do teste é um `Kick` com mensagem.
- **Ato → ato no mesmo servidor não existe:** os serviços da partida ligam uma vez só por servidor. Na partida do Studio, concluir o ato (portal ou `/nextact`) dá as recompensas normalmente, mas o `TravelService.SendToNewMatch` responde `false, MSG_STUDIO_NEXT_ACT` (mostrado como aviso; seção 8.16). Para testar Inverno ou Deserto, use `/unlockall` no lobby e escolha o mapa ao criar o grupo.
- Com `StudioRole = "Match"` o Studio abre direto a partida em `Config.Game.StudioMapId` (o jeito antigo continua funcionando). Num jogo publicado nada disso existe: o grupo sempre é teleportado.

---

## 2. Rede (`Shared/Util/Net.lua`)

O servidor cria `ReplicatedStorage.Remotes` (Folder) com os remotes abaixo. O cliente espera por eles (`WaitForChild`).

### 2.1 RemoteEvents
| Nome | Direção | Argumentos |
|---|---|---|
| `State` | S→C | `(key: string, value: any)` |
| `Notify` | S→C | `(payload: {Text: string, Kind: "info"\|"success"\|"warning"\|"error"\|"rare", Duration: number?, Achievement: string?})` — `Achievement` (opcional, até 64 letras) = id da conquista (`Config.Achievements`), só nos avisos de conquista desbloqueada; o cliente ignora campos que não conhece |
| `Fire` | C→S | `(origin: Vector3, directions: {Vector3}, shotId: number)` |
| `HitConfirm` | S→C | `(hits: {{Position: Vector3, Damage: number, Crit: boolean, Killed: boolean, Id: string?}})` — `Id` (opcional) = o `BrainrotId` do alvo (atributo do modelo, ex.: `"B12"`); o cliente junta os números de dano do mesmo alvo. Um `HitConfirm` por tiro |
| `RemoteShot` | S→C | `(userId: number, origin: Vector3, endpoints: {Vector3}, tracerColor: Color3)` — só para quem está a até 400 studs da origem e no máximo 1 por atirador a cada 0,1 s para cada jogador (seção 8.6) |
| `Effect` | S→C | `(kind: string, data: table)` — kinds na seção 2.4 |
| `CoinPopup` | S→C | `(amount: number, position: Vector3)` |
| `TurretShots` | S→C | `(shots: {{From: Vector3, To: Vector3, Hit: boolean}})` |
| `OpenUI` | S→C | `(action: string, arg: string?)` — mesmo formato de `ClientAction` (seção 7) |
| `Ending` | S→C | `(data: {Names: {string}, Duration: number, SupremeName: string})` |
| `PartyState` | S→C | `(state: PartyStatePayload)` — seção 9 |
| `Announcement` | S→C | `(payload: {Text: string (já filtrado pelo Roblox), From: string (nome de exibição do admin), Duration: number (s)})` — aviso de admin (`:announce`), mostrado em todos os servidores (seção 8.18) |

### 2.2 RemoteFunction
`Request` (C→S): `(action: string, ...) -> (ok: boolean, result: any)`. Em erro, `result` é uma mensagem em português.

### 2.3 API do módulo Net
Servidor:
- `Net.Init()` — cria a pasta e todos os remotes (só servidor; idempotente).
- `Net.OnEvent(name, fn(player, ...))` — conecta `OnServerEvent`.
- `Net.Handle(action, fn(player, ...) -> (ok, result), opts?)` — registra um handler de `Request`. `opts = {Rate = número por segundo (padrão 8), Burst = (padrão 16)}`. Rate limit por jogador **por action** (token bucket). Se exceder → `false, "Calma! Muitas ações seguidas."`. Handler que dá erro → `false, "Erro interno"` + `warn` com o nome da action. Action sem handler → `false, "Ação desconhecida"`.
- `Net.FireClient(player, name, ...)`, `Net.FireAll(name, ...)`, `Net.FireAllExcept(player, name, ...)`.
Cliente:
- `Net.On(name, fn(...))` — conecta `OnClientEvent`; retorna a conexão.
- `Net.Fire(name, ...)` — `FireServer`.
- `Net.Request(action, ...) -> ok, result` — `InvokeServer` dentro de `pcall`; em falha retorna `false, "Erro de conexão"`.

### 2.4 Tipos de `Effect`
- `"Death"`: `{Position: Vector3, Size: number (altura em studs), Color: Color3, Enchant: string?, Giant: boolean}`
- `"Explosion"`: `{Position: Vector3, Radius: number}`
- `"Spawn"`: `{Position: Vector3, Size: number (altura em studs)}`
- `"IceBreak"`: `{Position: Vector3, Size: number (maior lado do bloco de gelo, em studs)}`
- `"Ingredient"`: `{Position: Vector3, Color: Color3}`
- `"Purchase"`: `{Position: Vector3}` (confete na barraca)
- `"Portal"`: `{Position: Vector3}`

### 2.5 Tabela completa de actions de `Request`
| Action | Args | Retorno ok | Dono |
|---|---|---|---|
| `GetFullState` | — | `table` (chave→valor) | StateService |
| `SaveSettings` | `settings: table` | `true` | SettingsService |
| `Debug` | `command: string, arg: any` | `string` | DebugService |
| `BuyUpgrade` | `upgradeId: string, amount: number \| "max"` | `{Level, Spent}` | UpgradeService |
| `BuyShelf` | — | `{ShelfLevel}` | UpgradeService |
| `VotePortal` | — | `true` | ProgressionService |
| `ReturnToLobby` | — | `true` | MatchService |
| `TakeQuest` | — | `quest` | QuestService |
| `AbandonQuest` | — | `true` | QuestService |
| `PlaceTurret` | `position: Vector3, rotY: number` | `turretId` | TurretService |
| `PickupTurret` | `turretId: string` | `true` | TurretService |
| `RecallTurrets` | — | `true` | TurretService |
| `SetTurretMode` | `turretId: string, mode: "Valuable"\|"Nearest"` | `true` | TurretService |
| `Craft` | `ingredientIds: {string}` | `{RecipeId, Name, NewDiscovery: boolean}` | RecipeService |
| `FeedSupreme` | `fraction: number (0.1, 0.5 ou 1)` | `{Spent, Progress}` | SupremeService |
| `BuyGamepass` | `key: "DoubleCoins"\|"AutoCollect"\|"ExtraTurret"\|"VIP"\|"DoubleDamage"` | `true` | MonetizationService (lobby e partida) |
| `PartyCreate` | `opts: {MapId, MaxPlayers, Privacy, Resume}` | `partyId` | PartyService |
| `PartyJoin` | `partyId: string` | `true` | PartyService |
| `PartyLeave` | — | `true` | PartyService |
| `PartyReady` | `ready: boolean` | `true` | PartyService |
| `PartyStart` | `force: boolean` | `true` | PartyService |
| `PartyCancelCountdown` | — | `true` | PartyService |
| `PartyKick` | `userId: number` | `true` | PartyService |
| `PartyTransfer` | `userId: number` | `true` | PartyService |
| `PartySetMap` | `mapId: string` | `true` | PartyService |
| `PartySetMaxPlayers` | `n: number` | `true` | PartyService |
| `PartySetPrivacy` | `privacy: "Public"\|"Friends"\|"Invite"` | `true` | PartyService |
| `PartySetResume` | `resume: boolean` | `true` | PartyService |
| `PartyInvite` | `userId: number` | `true` | PartyService |
| `Reconnect` | — | `true` | LobbyService |
| `BuyCosmetic` | `id: string` | `true` | ShopService |
| `EquipCosmetic` | `id: string` | `true` | ShopService |
| `AdminCommand` | `name: string, args: {string}` | `message: string` (pt-BR; em erro também é uma mensagem) | AdminService (lobby e partida; seção 8.18) |

Todo handler **valida tipos** (`typeof`) e faixas de todos os argumentos antes de usar.

---

## 3. Estado replicado (`StateService` no servidor, `StateController` no cliente)

### 3.1 Servidor: `Services/StateService.lua` (serviço-folha)
- `StateService.Init()` — registra `Request "GetFullState"`; inicia um loop que envia as mudanças pendentes a **10 Hz** (uma mensagem `State(key, value)` por chave suja, por jogador).
- `StateService.Set(player, key, value)` — guarda e marca como sujo.
- `StateService.SetAll(key, value)` — guarda como valor **global** (vale para todos os jogadores, inclusive os que entrarem depois) e marca sujo para todos.
- `StateService.Get(player, key)` — valor do jogador, ou o global.
- `StateService.GetAll(player)` — mistura global + do jogador.
- `StateService.Clear(player)` — no `PlayerRemoving`.
- `StateService.Notify(player, text, kind?, duration?, extra?)` e `StateService.NotifyAll(text, kind?, duration?, extra?)` — atalhos para o evento `Notify`. `extra` é opcional: quando `extra.Achievement` é um texto (até 64 letras), ele vai no pacote como `Achievement` (seção 2.1). Sem `extra`, o pacote é exatamente o de antes.

### 3.2 Cliente: `Controllers/StateController.lua`
- `Init()`: conecta `Net.On("State")`, depois chama `Request("GetFullState")` e aplica tudo.
- `StateController.Get(key)`, `StateController.OnChanged(key, fn(value)) -> conexão` (chama `fn` quando a chave muda), `StateController.Changed: Signal(key, value)`.
- `StateController.GetStats()` → `Formulas.ComputeStats(Match.MapId, PlayerUpgrades, TeamUpgrades, Recipes, StateController.GetStatExtras())`, com cache refeito quando `Match`, `PlayerUpgrades`, `TeamUpgrades`, `Recipes`, `Gamepasses` ou `GlobalEvent` mudam. `StateController.StatsChanged: Signal(stats)`. Se não há `Match` (lobby), retorna `nil`.
- `StateController.GetStatExtras()` → tabela nova `{DoubleCoins = Gamepasses.DoubleCoins, VIP = Gamepasses.VIP, DoubleDamage = Gamepasses.DoubleDamage, Event = GlobalEvent.Effects}` (os `extras` dos game passes e do evento global ativo, iguais aos do `StatService`; `Event = nil` sem evento; a `StallWindow` usa o mesmo na prévia do próximo nível, e o HUD/`StallWindow` mostram a recompensa da missão × `Formulas.PassCoinMult` com isto).
- `StateController.WaitFor(key)` — espera até a chave existir.
- `StateController.GetSettings()` → tabela nova com `Profile.Settings` completado pelos padrões (`DEFAULT_SETTINGS`, os mesmos do template 4.2, incluindo os 7 campos novos da 2.0: `CameraShake`, `ViewBob`, `EffectsQuality`, `UIScale`, `AmbientVolume`, `AimAssist`, `AutoFire`). Campo com tipo diferente do padrão é trocado pelo padrão. `StateController.GetKeybind(actionId) -> Enum.KeyCode`.
- `StateController.GetEffectsQuality() -> 1|2|3` — quanto efeito visual mostrar (1 baixa, 2 média, 3 alta). `Settings.EffectsQuality` de 1 a 3 manda; com `0` (automático, o padrão) segue o gráfico do Roblox, `UserSettings():GetService("UserGameSettings").SavedQualityLevel` (lido em `pcall`): `Automatic` → 2, níveis 1-3 → 1, 4-7 → 2, 8-10 → 3. Barato (sem tabelas novas): os efeitos podem chamar sempre.
- `StateController.QualityChanged: Signal(level)` — dispara quando o nível acima muda: o perfil trouxe outro `EffectsQuality` ou, no automático, o jogador mudou o gráfico do Roblox (conferido a cada 2 s e pelo `GetPropertyChangedSignal("SavedQualityLevel")`). Não dispara para o valor inicial: quem usa chama `GetEffectsQuality()` ao iniciar.

### 3.3 Chaves (lista fechada)
| Chave | Escopo | Valor |
|---|---|---|
| `Profile` | jogador | visão do perfil (seção 4.3) |
| `Match` | global | `{MapId, Act, HostUserId, Members = {userId}, StartedAt}` |
| `Coins` | jogador | `number` (carteira; se `SharedWallet`, é o cofre do time, enviado com `SetAll`) |
| `Income` | jogador | `number` moedas/s (média móvel) |
| `PlayerUpgrades` | jogador | `{[upgradeId] = level}` |
| `TeamUpgrades` | global | `{[upgradeId] = level}` |
| `ShelfLevel` | global | `number` (1..MaxShelf) |
| `ShelfReady` | global | `boolean` — `UpgradeService.IsShelfMaxed(Team.ShelfLevel)`: a prateleira atual pode ser melhorada (o botão "Melhorar Barraca" usa isto) |
| `Recipes` | global | `{[recipeId] = true}` (receitas permanentes aplicadas nesta partida) |
| `Buffs` | global | `{TimedEnchantUntil = number, NextWaveGiant = boolean}` |
| `Quest` | jogador | `{Active = nil \| {Id, Type, Text, Target, Progress, Reward}, CooldownEnd = number}` |
| `Ingredients` | jogador | `{[ingredientId] = count}` |
| `Supreme` | global | `{Progress = 0..1, Height = number}` |
| `Heat` | jogador | `{Value = number, Capacity = number, Overheated = boolean}` |
| `Portal` | global | `{Open = boolean, Target = mapId?, Votes = number, Needed = number, Decision = "Host"\|"Majority", Decider = userId?}` (`Decider` só no modo Host: quem pode ativar agora; o HUD mostra "Entrar" só para ele) |
| `Turrets` | global | `{Placed = number, Max = number}` |
| `Gamepasses` | jogador | `{DoubleCoins = boolean, AutoCollect = boolean, ExtraTurret = boolean, VIP = boolean, DoubleDamage = boolean}` — `true` = o jogador tem o pass. Enviada no lobby e na partida. |
| `Board` | global | `{CooldownEnd = number}` |
| `Alive` | global | `number` brainrots vivos |
| `TeamList` | global | `{{UserId, Name, Coins}}` (1 Hz) |
| `Completed` | global | `boolean` — ato atual concluído (todas as prateleiras maxadas) |
| `GlobalEvent` | global | `nil` ou `{Key, Name, EndsAt = number (relógio de workspace:GetServerTimeNow()), Effects = {...}}` — evento global ligado por um admin (`:event`), no lobby e na partida (seção 8.18). `Effects` = cópia de `Config.Admins.Events[Key].Effects` |

---

## 4. Dados persistentes (`Services/DataService.lua`, serviço-folha)

### 4.1 Armazenamento
- DataStore principal: `Config.Game.DataStoreName`, chave `"Player_" .. userId`.
- DataStore das partidas salvas (time): `Config.Game.RunStoreName`, chave `"Run_" .. hostUserId .. "_" .. mapId`.
- Se `DataStoreService` falhar no Studio (API desligada), usar um **armazenamento em memória** (mock) com a mesma interface e avisar no Output uma vez: `"[DataService] Usando dados temporários (ative Studio Access to API Services para salvar de verdade)"`.
- **Studio com acesso às APIs:** a menos que `Config.Game.StudioLiveData == true`, o Studio abre DataStores separados, com `"_Studio"` no fim do nome (`BrainrotIncremental_Player_v1_Studio`, `BrainrotIncremental_Runs_v1_Studio`; a sonda que testa o acesso também usa o nome `_Studio`), e avisa no Output: `"[DataService] Studio: usando lojas _Studio (dados reais protegidos)"`. Assim um teste no Studio nunca apaga nem sobrescreve o perfil ou a partida salva de verdade. `DataService.UsesStudioStores()` diz se é esse o caso; o `LobbyService` usa isso para não gravar no placar público (seção 9.1). Os nomes `DataStoreName`/`RunStoreName`/`LeaderboardStoreName` nunca mudam.
- **Trava de sessão** feita com `UpdateAsync`: o registro guarda `{Data = perfil, Lock = {JobId, Time}}`. Ao carregar: se há trava de outro `JobId` com `Time` há menos de `Config.Game.SessionLockTimeout` (padrão 90 s), espera 5 s e tenta de novo (até 6 vezes) e depois assume a trava. O autosave renova `Time`. Ao sair/teleportar, grava `Lock = nil`.
- Autosave a cada `Config.Game.AutosaveInterval` s. `game:BindToClose` salva todos (em paralelo, com `task.spawn` e espera até 25 s).
- Novas chaves do template são adicionadas a perfis antigos (reconcile), sem apagar dados (inclusive os campos novos da 2.0 em `Settings`, `Stats.Huge` e `LastResult`). Chaves desconhecidas nunca são apagadas.

### 4.2 Template do perfil
```lua
{
  Version = 1,
  UnlockedMaps = { Meadow = true },
  CompletedMaps = {},             -- [mapId] = true
  GameCompleted = false,
  Stats = {
    Kills = { Low = 0, Medium = 0, High = 0 },
    KillsTotal = 0, TotalCoins = 0, Shots = 0, Crits = 0, Chains = 0,
    Giants = 0, Enchanted = 0, Galactic = 0, PlayTime = 0,
    ActsCompleted = 0, RecipesDiscovered = 0, QuestsCompleted = 0,
    Huge = 0,                     -- 2.0: brainrots de tamanho "Enorme" destruídos
  },
  Achievements = {},              -- [achievementId] = os.time()
  RecipesKnown = {},              -- [recipeId] = true
  Settings = {
    Sensitivity = 0.5, InvertY = false, FOV = 80, ToggleSprint = false,
    MusicVolume = 0.5, SfxVolume = 0.7, DamageNumbers = true,
    Keybinds = {},                -- [actionName] = "KeyCodeName" (só os alterados)
    -- 2.0 (as faixas aceitas estão na seção 8.15; quem usa cada campo chega nas próximas etapas):
    CameraShake = 1,              -- força do tremor da câmera (0 = desligado, 1 = normal)
    ViewBob = true,               -- balanço da câmera ao andar
    EffectsQuality = 0,           -- 0 = automática, 1 = baixa, 2 = média, 3 = alta
    UIScale = 1,                  -- tamanho da interface (0,85 a 1,25)
    AmbientVolume = 0.6,          -- volume dos sons de ambiente
    AimAssist = true,             -- mira assistida (só toque e controle)
    AutoFire = true,              -- tiro automático no celular
  },
  Tokens = 0,
  Cosmetics = { Owned = { Classic = true }, Equipped = "Classic" },
  LastMatch = nil,                -- {AccessCode, PrivateServerId, MapId, Time = os.time()}
  RunSaves = {},                  -- [mapId] = os.time() (este jogador é dono de uma partida salva nesse mapa)
  MapRecords = {},                -- [mapId] = {BestCoins = number} (mais moedas ganhas numa partida desse mapa; mostrado no card do mapa)
  RunData = {},                   -- [mapId] = {HostUserId, Coins, Upgrades, Ingredients, SavedAt}
  LastResult = {},                -- 2.0: resumo da última partida; {} até a primeira, depois tem pelo menos MapId (texto)
}
```

### 4.3 API
- `DataService.Init()` — conecta `PlayerAdded` (carrega; também para jogadores já presentes), `PlayerRemoving` (salva e libera), `BindToClose`, autosave; incrementa `Stats.PlayTime` a cada minuto.
- `DataService.GetProfile(player) -> profile | nil` — a tabela viva (pode mutar e depois chamar `SyncProfile`).
- `DataService.WaitForProfile(player, timeout?) -> profile | nil` (padrão 30 s).
- `DataService.ProfileLoaded: Signal(player, profile)`.
- `DataService.Save(player)` (espera terminar). 
- `DataService.ReleaseForTeleport(player)` — salva e libera a trava; marca o perfil como liberado (autosave e `PlayerRemoving` não salvam mais por cima).
- `DataService.Reacquire(player)` — se o teleporte falhou, pega a trava de novo e volta a salvar normalmente.
- `DataService.IsReleased(player) -> boolean` — `true` depois de `ReleaseForTeleport` até um `Reacquire`. Quem grava progresso confere antes: `AchievementService.Award` não dá nada (a checagem retroativa do próximo servidor dá), `MatchService.AddCoins`/`syncRunToProfile` pulam o perfil (a partida salva do time guarda as moedas).
- `DataService.UsesStudioStores() -> boolean` — `true` no Studio usando as lojas `_Studio` (o normal); `false` no jogo publicado ou com `Config.Game.StudioLiveData = true` (seção 4.1).
- `DataService.SyncProfile(player)` — envia `StateService.Set(player, "Profile", DataService.BuildClientView(profile))`, com limite de 2 vezes por segundo (junta chamadas seguidas).
- `DataService.BuildClientView(profile)` → cópia com `UnlockedMaps, CompletedMaps, GameCompleted, Stats, Achievements, RecipesKnown, Settings, Tokens, Cosmetics, RunSaves, MapRecords` + `CanReconnect: boolean` (há `LastMatch` com menos de `Config.Lobby.ReconnectWindowSeconds`) + `LastMatchMap: string?` + `LastResult: table?` (cópia de `profile.LastResult`, só quando ele tem `MapId` texto) + `ReconnectUntil: number?` (`LastMatch.Time + ReconnectWindowSeconds`, em `os.time()`, só quando `CanReconnect`). **Não** envia `RunData` nem `AccessCode`.
- `DataService.IncrementStat(player, path, amount, quiet?)` — `path` tipo `"Kills.Low"` ou `"TotalCoins"`; soma, dispara `StatChanged` e chama `SyncProfile`. Com `quiet == true` (stats de alta frequência: `Shots`, `Crits`, `PlayTime`, `TotalCoins` das moedas) soma e dispara `StatChanged` do mesmo jeito, mas só marca o perfil como "sujo": um único `SyncProfile` junto sai em até 5 s (um `task.delay` pendente por jogador) ou na próxima chamada sem `quiet`. As chamadas antigas com 3 argumentos funcionam igual.
- `DataService.StatChanged: Signal(player, path, newValue)`.
- `DataService.LoadRun(key) -> table|nil`, `DataService.SaveRun(key, data)`, `DataService.DeleteRun(key)` — partidas do time (com `pcall` e 3 tentativas).
- Se o perfil não carregar: `player:Kick("Não foi possível carregar seus dados. Tente entrar de novo.")`.

---

## 5. Configurações (`Shared/Config/*`)

Todos retornam uma tabela. Valores de custo/valor/vida são escritos em **unidades do Ato 1** e multiplicados pelo `CostScale`, `ValueScale` ou `HealthScale` do mapa.

### 5.1 `Config/Game.lua`
```lua
{
  GameName = "Brainrot Incremental But With Guns",
  LobbyPlaceId = 0, MatchPlaceId = 0,           -- o dono preenche depois de publicar
  StudioRole = "Lobby",                         -- papel ao testar no Studio: "Lobby" (padrão; o Play abre o lobby) ou "Match"
  StudioMapId = "Meadow",                       -- mapa da partida no Studio (só vale com StudioRole = "Match")
  StudioInPlaceMatch = true,                    -- só Studio: iniciar um grupo no lobby vira a partida NO MESMO servidor
  UseTerrain = true,                            -- true = mapas com Terrain (chão, morros, lagos, trilhas); false = só peças
  DebugMode = false,                            -- comandos de teste fora do Studio (mesmo ligado, lá só admins usam)
  StudioLiveData = false,                       -- false = Studio usa DataStores "_Studio" e não grava placar; true = dados reais (só para investigar)
  DataStoreName = "BrainrotIncremental_Player_v1",
  RunStoreName = "BrainrotIncremental_Runs_v1",
  AutosaveInterval = 60, SessionLockTimeout = 90,
  SharedWallet = false,                         -- true = todas as moedas vão para um cofre do time
  WeaponMaxRule = "AnyPlayer",                  -- "AnyPlayer" ou "AllPlayers" (para concluir o ato)
  TurretCoinSplit = "Owner",                    -- moedas de abate das torretas: "Owner" (dono) ou "Team" (divididas entre o time)
  PortalDecision = "Majority",                  -- "Host" ou "Majority"
  HealthScalePerExtraPlayer = 0.35,
  MaxBrainrotsAlive = 60,
  BoardCooldown = 3,
  AutoRespawnThreshold = 0.3,                   -- respawn automático quando vivos < 30% da leva
  PlayerExclusionRadius = 12, MinBrainrotSpacing = 6, SpawnAttempts = 30,
  BulletHitRadius = 1.2,                        -- raio do spherecast (multiplicado pelo Caliber)
  ExplosionDamageFraction = 0.4, ExplosionBaseRadius = 6,
  IgniteDpsFraction = 0.1, IgniteDuration = 3, IgniteRadius = 10,
  SlowDuration = 2,
  SlowDamageBonus = 0.5,                        -- brainrot lento leva dano × (1 + (1 - SlowFactor) × isto)
  AttractSpeed = 3, AttractStopDistance = 18,
  FrozenShieldFraction = 0.5,
  WalkSpeed = 16, SprintSpeed = 26,
  DesertHeat = { SafeTime = 20, SlowMultiplier = 0.85 },
  Gamepasses = { Enabled = false, DoubleCoins = 0, AutoCollect = 0, ExtraTurret = 0, VIP = 0, DoubleDamage = 0 },  -- ids (0 = não vende); preços só no Creator Hub
  GamepassAutoCollectRadius = 30,               -- raio do ímã de quem tem AutoCollect
  GamepassVipCoinMult = 1.25,                   -- VIP: moedas × 1,25 (multiplica junto com o DoubleCoins)
  -- Sons e músicas (vale para Music e Sounds): > 0 = id fixo, 0 = automático (biblioteca de áudio), -1 = mudo
  Music = { Lobby = 0, Meadow = 0, Winter = 0, Desert = 0, Ending = 0 },
  Sounds = { Shoot = 0, Hit = 0, Crit = 0, Coin = 0, Death = 0, Explosion = 0, Purchase = 0,
             Error = 0, Notify = 0, Turret = 0, Portal = 0, Craft = 0 },
}
```
- `StudioRole`: papel do servidor no Studio (passo 5 da seção 1.4). `"Lobby"` (padrão da 2.0) abre o lobby; com `StudioInPlaceMatch` ligado, criar um grupo e iniciar transforma o mesmo servidor na partida (seção 8.16). `"Match"` abre direto a partida em `StudioMapId`, como antes. Valor inválido = `"Lobby"`.
- `StudioInPlaceMatch`: quem lê usa `GameConfig.StudioInPlaceMatch ~= false` (campo faltando = ligado). Só vale no Studio com o papel `"Lobby"`: o `Main` registra a troca com `TravelService.SetStudioMatchSwitch`. Com `false`, iniciar um grupo no lobby do Studio só mostra o aviso `MSG_STUDIO_MATCH`. Num jogo publicado é ignorado (o grupo sempre é teleportado).
- `UseTerrain`: quem lê usa `Common.UseTerrain()` (= `GameConfig.UseTerrain ~= false`). `true` (padrão): os builders fazem chão, morros, lagos e trilhas com o Terrain (`Common.Terrain*`, seção 7.4); `false`: voltam para o chão e as colinas de peças (`Common.Ground`/`Common.Hill`), útil se algum aparelho sofrer.
- `Music`/`Sounds` — o que cada número quer dizer (resolvido por `UIKit.ResolveSound`, seções 5.16 e 10.2):
  - **maior que 0** = id fixo: toca exatamente esse áudio (`rbxassetid://<id>`), acima de tudo.
  - **0** (padrão) = automático: segue para `Config.Audio.Pinned`, depois o que a busca do servidor achou (`ReplicatedStorage.AudioLibrary`) e, por fim, um som embutido do Roblox (`Config.Audio.Slots[vaga].Fallback`); sem nada disso, silêncio (sem erro).
  - **-1** = mudo: esse som (ou a música desse lugar) nunca toca, nem o automático.
  - Um texto com `"://"` (ex.: `"rbxassetid://123"`) também é aceito e usado como está.
  - `Sounds[k]` vale para a vaga `k` (ex.: `Sounds.Purchase` → vaga `"Purchase"`); `Music[k]` vale para a vaga `"Music_" .. k` (ex.: `Music.Meadow` → `"Music_Meadow"`).
- `StudioLiveData`: quem lê usa `GameConfig.StudioLiveData == true` (se o campo faltar, conta como `false`). Com `false` (padrão), no Studio o `DataService` usa os DataStores `_Studio` e o `LobbyService` não escreve no placar (seções 4.1 e 9.1). `true` só para investigar um problema nos dados reais; desligue logo depois.
- `DebugMode`: fora do Studio só libera os comandos de teste para **admins** (`AdminService.IsAdmin`); o atributo `DebugMode` do `workspace` só é lido no Studio (seção 8.17).

### 5.2 `Config/Lobby.lua`
```lua
{ MinMaxPlayers = 1, MaxPlayersLimit = 8, DefaultMaxPlayers = 4, CountdownSeconds = 5,
  TeleportRetries = 3, ReconnectWindowSeconds = 7200,
  HandoffMapName = "BrainrotMatchHandoff", HandoffExpiration = 10800,
  LeaderboardStoreName = "BrainrotIncremental_TopCoins_v1", LeaderboardRefresh = 60, LeaderboardSize = 10,
  Privacy = { Public = "Público", Friends = "Só amigos", Invite = "Só convidados" },
  Lighting = { ... } }                            -- 2.0: iluminação do lobby (formato da seção 5.3)
```
- `Lighting` (2.0): "pôr do sol de festival", no mesmo formato de `Config.Maps[x].Lighting` (seção 5.3). O `MapBuilder.Build("Lobby")` aplica esta tabela (o lobby não está em `Config.Maps`). Valores iniciais: `ClockTime 17.6`, `GeographicLatitude 30`, `Brightness 2.1`, Atmosphere `Density 0.3`/`Offset 0.22`, `Sky.SunAngularSize 21`, nuvens `Cover 0.5`, `PostFX` com Bloom, ColorCorrection, SunRays e um `DepthOfField` leve (`FarIntensity 0.12`, `FocusDistance 55`, `InFocusRadius 80`, `NearIntensity 0`: o fundo distante fica um pouco desfocado, como maquete), `Wind (4, 0, 2)` e `Water`.
- `HandoffExpiration = 10800` (3 h, em segundos): validade dos dados do grupo no MemoryStore. Um prazo curto evita lotar a cota do MemoryStore com muitos grupos por dia; o `MatchService.SaveAll` renova a entrada (mesmo conteúdo, mesmo prazo) no máximo a cada 10 min enquanto há jogadores na partida (seção 8.2), então uma partida longa não perde o handoff (reconexão e quem entra depois continuam funcionando).

### 5.3 `Config/Maps.lua`
```lua
{
  Order = { "Meadow", "Winter", "Desert" },
  Meadow = { Id = "Meadow", Act = 1, DisplayName = "Prado Brainrot", Description = "...", Image = "",
    Weapon = "SpaghettiPistol", Next = "Winter",
    CostScale = 1, ValueScale = 1, HealthScale = 1,
    MaxShelf = 3, ShelfCosts = { [2] = 4e4, [3] = 1e6 },
    TokensReward = 10, FrozenChance = 0,
    Stalls = { "Weapon", "Brainrot", "Quest" },
    HasTurrets = false, HasRecipes = false, HasSupreme = false,
    StatOverrides = {},
    Lighting = { ClockTime = 14.6, GeographicLatitude = 35, Brightness = 2.4, Ambient = Color3, OutdoorAmbient = Color3,
                 ColorShift_Top = Color3, EnvironmentSpecularScale = 0.7, ShadowSoftness = 0.2,
                 Atmosphere = { Density = 0.27, Offset = 0.2, Color = Color3, Decay = Color3, Glare = 0.12, Haze = 1.1 },
                 Sky = { SunAngularSize = 14 },
                 Clouds = { Cover = 0.55, Density = 0.5, Color = Color3 },
                 PostFX = { Bloom = {...}, ColorCorrection = {...}, SunRays = {...} },
                 Wind = Vector3.new(6, 0, 3),
                 Water = { Color = Color3, Transparency = 0.55, WaveSize = 0.08, WaveSpeed = 6, Reflectance = 0.6 } },
  },
  Winter = { ..., Act = 2, DisplayName = "Tundra Congelini", Weapon = "GelatoCannon", Next = "Desert",
    CostScale = 25, ValueScale = 25, HealthScale = 30, TokensReward = 20, FrozenChance = 0.2,
    Stalls = { "Weapon", "Brainrot", "Quest", "Turret" }, HasTurrets = true,
    StatOverrides = { TurretDamage = 20 }, AtmosphereDensity = 0.45, VisibilityFactor = 0.75, ... },
  Desert = { ..., Act = 3, DisplayName = "Deserto Sahur", Weapon = "TralaleroMinigun", Next = nil,
    CostScale = 625, ValueScale = 625, HealthScale = 900, TokensReward = 50,
    Stalls = { "Weapon", "Brainrot", "Quest", "Turret", "Growth" },
    HasTurrets = true, HasRecipes = true, HasSupreme = true,
    StatOverrides = { TurretDamage = 600 },
    Supreme = { BrainrotId = "TralaleroSupremo", BaseFullCost = 1e6, MinHeight = 8, MaxHeight = 500 }, ... },
}
```
(`Winter` e `Desert` também têm `Id`, `Description`, `Image`, `ShelfCosts` (iguais aos do Prado), `MaxShelf`, `Lighting`.)
Atmosfera no Inverno: `Density = AtmosphereDensity * VisibilityFactor ^ stats.Visibility`.

**Formato de `Lighting` (2.0)** — aplicado por `Common.ApplyLighting` (seção 7.4) em `MapBuilder.Build`. Toda chave é opcional; o que faltar fica como na **BASE**:
- Chaves do `Lighting` (`LIGHTING_KEYS`): `ClockTime`, `Brightness`, `Ambient`, `OutdoorAmbient`, `ExposureCompensation`, `EnvironmentDiffuseScale`, `EnvironmentSpecularScale`, `GeographicLatitude`, `ColorShift_Top`, `ColorShift_Bottom`, `ShadowSoftness`, `GlobalShadows`, `LightingStyle` (`"Realistic"`/`"Soft"` ou o `Enum.LightingStyle`), `PrioritizeLightingQuality`, `FogColor`, `FogStart`, `FogEnd`.
- `Atmosphere = { Density, Offset, Color, Decay, Glare, Haze }` — a **única** `Atmosphere` do `Lighting` (reaproveitada; nunca marcada `MapEffect`: o `StatService` mexe na `Density` do Inverno e o `SupremeService` escurece o Deserto).
- `PostFX = { Bloom = {Intensity, Size, Threshold}, ColorCorrection = {Brightness, Contrast, Saturation, TintColor}, SunRays = {Intensity, Spread}, DepthOfField = {FarIntensity, FocusDistance, InFocusRadius, NearIntensity} }` — cada um vira um efeito `Map<Classe>` no `Lighting` (`MapBloomEffect`, `MapColorCorrectionEffect`...) via `Common.LightingEffect`.
- `Sky = { SunAngularSize, MoonAngularSize, StarCount }` — um `Sky` `MapSky` (se o dono pôs um `Sky` próprio no `Lighting`, ele é usado e só recebe estes tamanhos).
- `Clouds = { Cover, Density, Color }` — um `Clouds` `MapClouds` dentro de `workspace.Terrain`.
- `Wind = Vector3` — vira `workspace.GlobalWind` (grama do terreno, nuvens e partículas com `WindAffectsDrag`).
- `Water = { Color, Transparency, WaveSize, WaveSpeed, Reflectance }` — propriedades de água do `Terrain` (`WaterColor`, `WaterTransparency`, `WaterWaveSize`, `WaterWaveSpeed`, `WaterReflectance`; o que faltar volta ao padrão do Roblox).

**BASE** (aplicada antes de cada mapa, para nada do mapa anterior vazar): `Ambient (0,0,0)`, `OutdoorAmbient (128,128,128)`, `ColorShift_Top`/`ColorShift_Bottom (0,0,0)`, `EnvironmentDiffuseScale 1`, `EnvironmentSpecularScale 1`, `ShadowSoftness 0.2`, `Brightness 2`, `ExposureCompensation 0`, `GeographicLatitude 41.733`, `FogStart 0`, `FogEnd 100000`, `ClockTime 14`, `GlobalShadows true`, `LightingStyle Realistic`, `PrioritizeLightingQuality true`, `workspace.GlobalWind = (0,0,0)`; apaga os efeitos, o céu e as nuvens marcados com o atributo `MapEffect = true` (filhos do `Lighting` e do `Terrain`); a `Atmosphere` volta aos valores padrão do Roblox antes de receber os do mapa. `Lighting.Technology = Future` e `Terrain.Decoration = true` não podem ser mudados por script: ficam no `default.project.json` (junto com `LightingStyle`, `PrioritizeLightingQuality`, `GlobalShadows`, `EnvironmentDiffuseScale/SpecularScale`, `ShadowSoftness` e `StarterGui.ScreenOrientation = LandscapeSensor`).

Valores iniciais por lugar (direção de arte; ajustes finos depois só mexem nesta tabela):

| Chave | Prado (tarde de verão) | Inverno (nevasca) | Deserto (hora dourada) | Lobby (`Config.Lobby`, pôr do sol) |
|---|---|---|---|---|
| `ClockTime` / `GeographicLatitude` | 14.6 / 35 | 12.5 / 64 | 16.5 / 41.733 | 17.6 / 30 |
| `Brightness` | 2.4 | 1.7 | 2.8 | 2.1 |
| `ShadowSoftness` | 0.2 | 0.55 | 0.12 | 0.3 |
| Atmosphere `Density` / `Offset` | 0.27 / 0.2 | **0.45** (= `AtmosphereDensity`) / 0.3 | 0.3 / 0.24 | 0.3 / 0.22 |
| Atmosphere `Glare` / `Haze` | 0.12 / 1.1 | 0 / 2.4 | 0.55 / 2.1 | 0.45 / 1.6 |
| `Sky.SunAngularSize` | 14 | 9 | 28 | 21 |
| `Clouds.Cover` / `Density` | 0.55 / 0.5 | 0.86 / 0.42 | 0.22 / 0.28 | 0.5 / 0.5 |
| Bloom `Intensity` / `Size` / `Threshold` | 0.3 / 24 / 1.3 | 0.22 / 28 / 1.7 | 0.38 / 30 / 1.35 | 0.42 / 26 / 1.25 |
| SunRays `Intensity` / `Spread` | 0.06 / 0.55 | 0.02 / 0.4 | 0.11 / 0.8 | 0.07 / 0.7 |
| `DepthOfField` | não | não | não | Far 0.12, Focus 55, InFocus 80 |
| `Wind` | (6, 0, 3) | (16, 0, 7) | (11, 0, -4) | (4, 0, 2) |

Regras: no Inverno a `Atmosphere.Density` do `Lighting` tem de ser igual a `AtmosphereDensity` (o `StatService` é o dono dela durante a partida). Nas partidas não há `DepthOfField` (atrapalha mirar). Luzes locais (`PointLight`) ficam com `Shadows = false`, menos até 2 luzes "herói" por mapa; limite de luzes por mapa: Prado 12, Inverno 12, Deserto 16, Lobby 24.

### 5.4 `Config/Stats.lua`
```lua
{
  Defaults = {
    -- arma (sobrescritos por Weapons[x].Stats)
    Damage = 5, FireRate = 3, Projectiles = 1, Pierce = 0, CritChance = 0.02, CritMult = 2,
    Caliber = 1, Spread = 6, Range = 350, SplashRadius = 0, SlowPower = 0,
    HeatPerShot = 0, HeatCapacity = 0, HeatCooling = 0,
    -- campo / time
    SpawnCount = 5, ExplodeChance = 0, GiantChance = 0, GrowthMult = 1, MagnetRadius = 0,
    AutoCollect = 0, AttractValuable = 0, AutoRespawn = 0, TierLuck = 0, EnchantChance = 0,
    EnchantPower = 1, CoinMult = 1, QuestReward = 1, QuestCooldown = 60, Visibility = 0,
    HeatImmunity = 0, IngredientLuck = 1,
    -- torretas
    TurretCount = 0, TurretDamage = 0, TurretFireRate = 1, TurretRange = 45,
    TurretAccuracy = 0.6, TurretSlow = 0, TurretCoinMult = 1,
    -- supremo
    SupremeFeed = 1, SupremePassive = 0.00005, SupremeKill = 0,
  },
  Clamps = { CritChance = {0, 1}, ExplodeChance = {0, 0.9}, GiantChance = {0, 0.9},
             EnchantChance = {0, 0.95}, TurretAccuracy = {0, 0.99}, SlowPower = {0, 0.8},
             TurretSlow = {0, 0.8}, Projectiles = {1, 20}, QuestCooldown = {5, 600}, SpawnCount = {1, 60},
             FireRate = {0.1, 30} },           -- trava de segurança: o servidor valida a cadência com isto
  -- Leque dos projéteis (NÃO é stat; fica fora de Clamps, que o Formulas.ComputeStats percorre inteiro):
  Fan = { MaxDegrees = 40,        -- abertura total máxima do leque (graus)
          JitterDegrees = 0.6,    -- desvio aleatório de cada projétil no cliente, para cada lado
          ToleranceDegrees = 1.5 },  -- folga da conferência do servidor (maior que 2 × JitterDegrees)
  Display = { [statKey] = { Name = "Dano", Format = "number" | "percent" | "multiplier" | "rate" | "studs" | "seconds" | "bool" | "integer" } },
}
```

### 5.5 `Config/Weapons.lua`
```lua
{
  SpaghettiPistol = { Id, DisplayName = "Pistola de Espaguete", Map = "Meadow",
    Stats = { Damage = 5, FireRate = 3, Projectiles = 1, Pierce = 0, CritChance = 0.02, CritMult = 2,
              Caliber = 1, Spread = 6, Range = 350 },
    GunColor = Color3, TracerColor = Color3, BulletVisualSpeed = 700, SoundId = 0 },
  GelatoCannon = { DisplayName = "Canhão de Gelato", Map = "Winter",
    Stats = { Damage = 300, FireRate = 1.5, Caliber = 1.5, Spread = 4, Range = 350, SplashRadius = 6, SlowPower = 0.2, ... } },
  TralaleroMinigun = { DisplayName = "Metralhadora de Tralalero", Map = "Desert",
    Stats = { Damage = 450, FireRate = 10, Pierce = 1, CritChance = 0.03, Spread = 8, Range = 300,
              HeatPerShot = 1, HeatCapacity = 40, HeatCooling = 6, ... } },
}
```

### 5.6 `Config/Upgrades.lua`
Cada upgrade:
```lua
{ Id = "M_Damage", Map = "Meadow", Stall = "Weapon", Shelf = 1, Scope = "Player",
  Name = "Dano", Description = "+25% de dano por nível",
  MaxLevel = 25, BaseCost = 10, CostMult = 1.41,
  Stat = "Damage", Mode = "Pow", Value = 1.25 }
```
- `Scope`: `"Player"` (cada jogador tem o seu nível e paga) ou `"Team"` (nível do time; qualquer um paga; vale para todos).
- `Mode`: `"Add"` → `v + Value * level`; `"Mult"` → `v * (1 + Value * level)`; `"Pow"` → `v * Value ^ level`.
- O módulo retorna `{ List = {...em ordem...}, ById = {...}, ByMap = {[mapId] = {...}}, Stalls = {Weapon = {Name = "Barraca de Arma", Color = Color3}, Brainrot = {...}, Quest = {...}, Turret = {...}, Growth = {...}} }` (ById/ByMap montados por código no fim do arquivo).

**Tabela de upgrades** (formato: `Id | Barraca | Prateleira | Escopo | Nome | Máx | Custo base | Mult | Stat Mode Value`):

Prado (`Meadow`):
```
M_Damage       Weapon   1 Player Dano                     25 10    1.41 Damage Pow 1.25
M_FireRate     Weapon   1 Player Cadência                 20 15    1.45 FireRate Mult 0.08
M_Projectiles  Weapon   1 Player Projéteis                 8 250   2.65 Projectiles Add 1
M_Pierce       Weapon   1 Player Perfuração                6 500   2.88 Pierce Add 1
M_Crit         Weapon   1 Player Chance de Crítico        15 100   1.68 CritChance Add 0.03
M_Caliber      Weapon   1 Player Calibre                  10 60    1.6  Caliber Mult 0.1
M_Spawn        Brainrot 1 Team   Mais Brainrots           20 20    1.49 SpawnCount Add 1
M_Explode      Brainrot 1 Team   Brainrot Explosivo       15 150   1.68 ExplodeChance Add 0.02
M_Giant        Brainrot 1 Team   Brainrot Gigante         15 200   1.71 GiantChance Add 0.02
M_Growth       Brainrot 1 Team   Adubo Brainrot           20 40    1.53 GrowthMult Pow 1.1
M_QuestReward  Quest    1 Player Recompensa de Missão     10 300   1.9  QuestReward Mult 0.1
M_QuestCooldown Quest   1 Player Espera de Missão          8 300   1.98 QuestCooldown Pow 0.92
M_CritMult     Weapon   2 Player Multiplicador de Crítico 10 5e3   1.68 CritMult Add 0.25
M_Damage2      Weapon   2 Player Dano+                    15 1e4   1.45 Damage Pow 1.2
M_FireRate2    Weapon   2 Player Cadência+                10 1e4   1.53 FireRate Mult 0.06
M_Magnet       Brainrot 2 Team   Ímã de Moedas            10 3e3   1.6  MagnetRadius Add 4
M_AutoCollect  Brainrot 2 Team   Coleta Automática         1 5e5   1    AutoCollect Add 1
M_Attract      Brainrot 2 Team   Atrair Brainrots Valiosos 1 1e5   1    AttractValuable Add 1
M_AutoRespawn  Brainrot 2 Team   Respawn Automático        1 5e4   1    AutoRespawn Add 1
M_TierLuck     Brainrot 2 Team   Sorte de Tier            10 8e3   1.68 TierLuck Add 0.15
M_Enchant      Brainrot 2 Team   Chance de Encantamento   10 2e4   1.68 EnchantChance Add 0.02
M_Spawn2       Brainrot 3 Team   Mais Brainrots+          10 2e5   1.34 SpawnCount Add 1
M_Explode2     Brainrot 3 Team   Explosivo+               10 2e5   1.34 ExplodeChance Add 0.02
M_Giant2       Brainrot 3 Team   Gigante+                 10 2e5   1.34 GiantChance Add 0.02
M_Growth2      Brainrot 3 Team   Adubo+                   10 2e5   1.34 GrowthMult Pow 1.03
M_CoinMult     Brainrot 3 Team   Multiplicador de Moedas  10 4e5   1.34 CoinMult Mult 0.3
M_EnchantPower Brainrot 3 Team   Poder de Encantamento    10 4e5   1.34 EnchantPower Mult 0.15
```
Inverno (`Winter`, prefixo `W_`), tabela completa. Os upgrades que também existem no Prado têm o mesmo Máx/Stat/Value, mas `Mult` menores e, nas prateleiras 2 e 3, custo base 1/5 do Prado (o campo pequeno do Prado faz a renda crescer mais rápido lá; meta: cada ato leva ~30 a 60 min jogando sozinho):
```
W_Damage       Weapon   1 Player Dano                     25 10    1.33 Damage Pow 1.25
W_FireRate     Weapon   1 Player Cadência                 20 15    1.36 FireRate Mult 0.08
W_Splash       Weapon   1 Player Raio da Explosão         10 200   1.84 SplashRadius Add 1.5
W_Slow         Weapon   1 Player Congelamento             10 150   1.72 SlowPower Add 0.05
W_Crit         Weapon   1 Player Chance de Crítico        15 100   1.54 CritChance Add 0.03
W_Caliber      Weapon   1 Player Calibre                  10 60    1.48 Caliber Mult 0.1
W_Spawn        Brainrot 1 Team   Mais Brainrots           20 20    1.39 SpawnCount Add 1
W_Explode      Brainrot 1 Team   Brainrot Explosivo       15 150   1.54 ExplodeChance Add 0.02
W_Giant        Brainrot 1 Team   Brainrot Gigante         15 200   1.57 GiantChance Add 0.02
W_Growth       Brainrot 1 Team   Adubo Brainrot           20 40    1.42 GrowthMult Pow 1.1
W_QuestReward  Quest    1 Player Recompensa de Missão     10 300   1.72 QuestReward Mult 0.1
W_QuestCooldown Quest   1 Player Espera de Missão          8 300   1.78 QuestCooldown Pow 0.92
W_TurretCount  Turret   1 Team   Mais Torretas             8 100   1.96 TurretCount Add 1
W_TurretDamage Turret   1 Team   Dano das Torretas        20 50    1.42 TurretDamage Pow 1.25
W_TurretRate   Turret   1 Team   Cadência das Torretas    15 80    1.45 TurretFireRate Mult 0.1
W_TurretRange  Turret   1 Team   Alcance das Torretas     10 60    1.48 TurretRange Add 5
W_TurretAim    Turret   1 Team   Mira das Torretas         9 70    1.54 TurretAccuracy Add 0.04
W_Visibility   Brainrot 2 Team   Farol da Nevasca          5 400   1.9  Visibility Add 1
W_Magnet       Brainrot 2 Team   Ímã de Moedas            10 600   1.48 MagnetRadius Add 4
W_AutoCollect  Brainrot 2 Team   Coleta Automática         1 1e5   1    AutoCollect Add 1
W_Attract      Brainrot 2 Team   Atrair Brainrots Valiosos 1 2e4   1    AttractValuable Add 1
W_TurretFreeze Turret   2 Team   Torreta Congelante        5 1e3   1.72 TurretSlow Add 0.1
W_IceAura      Brainrot 2 Team   Aura de Gelo             10 600   1.54 EnchantChance Add 0.03
W_TierLuck     Brainrot 2 Team   Sorte de Tier            10 1.6e3 1.54 TierLuck Add 0.15
W_CritMult     Weapon   2 Player Multiplicador de Crítico 10 1e3   1.54 CritMult Add 0.25
W_Spawn2       Brainrot 3 Team   Mais Brainrots+          10 4e4   1.27 SpawnCount Add 1
W_Growth2      Brainrot 3 Team   Adubo+                   10 4e4   1.27 GrowthMult Pow 1.03
W_CoinMult     Brainrot 3 Team   Multiplicador de Moedas  10 8e4   1.27 CoinMult Mult 0.3
W_EnchantPower Brainrot 3 Team   Poder de Encantamento    10 8e4   1.27 EnchantPower Mult 0.15
W_TurretCoins  Turret   3 Team   Moedas de Torreta        10 4e4   1.27 TurretCoinMult Mult 0.2
W_Damage2      Weapon   3 Player Dano+                    15 2e3   1.36 Damage Pow 1.2
```
Deserto (`Desert`, prefixo `D_`), tabela completa (mesma regra do Inverno):
```
D_Damage       Weapon   1 Player Dano                     25 10    1.33 Damage Pow 1.25
D_FireRate     Weapon   1 Player Cadência                 20 15    1.36 FireRate Mult 0.08
D_Projectiles  Weapon   1 Player Projéteis                 5 300   2.44 Projectiles Add 1
D_Pierce       Weapon   1 Player Perfuração                6 500   2.5  Pierce Add 1
D_Crit         Weapon   1 Player Chance de Crítico        15 100   1.54 CritChance Add 0.03
D_Cooling      Weapon   1 Player Resfriamento             15 80    1.48 HeatCooling Mult 0.15
D_HeatCap      Weapon   1 Player Tanque de Calor          15 80    1.48 HeatCapacity Mult 0.15
D_Spawn        Brainrot 1 Team   Mais Brainrots           20 20    1.39 SpawnCount Add 1
D_Explode      Brainrot 1 Team   Brainrot Explosivo       15 150   1.54 ExplodeChance Add 0.02
D_Giant        Brainrot 1 Team   Brainrot Gigante         15 200   1.57 GiantChance Add 0.02
D_Growth       Brainrot 1 Team   Adubo Brainrot           20 40    1.42 GrowthMult Pow 1.1
D_Straw        Brainrot 1 Team   Chapéu de Palha           1 500   1    HeatImmunity Add 1
D_QuestReward  Quest    1 Player Recompensa de Missão     10 300   1.72 QuestReward Mult 0.1
D_QuestCooldown Quest   1 Player Espera de Missão          8 300   1.78 QuestCooldown Pow 0.92
D_TurretCount  Turret   1 Team   Mais Torretas             6 150   2.08 TurretCount Add 1
D_TurretDamage Turret   1 Team   Dano das Torretas        20 50    1.42 TurretDamage Pow 1.25
D_TurretRate   Turret   1 Team   Cadência das Torretas    15 80    1.45 TurretFireRate Mult 0.1
D_Fertilizer   Growth   1 Team   Fertilizante Supremo     20 200   1.42 SupremeFeed Mult 0.25
D_Irrigation   Growth   1 Team   Irrigação                15 300   1.54 SupremePassive Pow 1.15
D_Roots        Growth   1 Team   Raiz Profunda            10 400   1.6  SupremeKill Add 0.00002
D_Magnet       Brainrot 2 Team   Ímã de Moedas            10 600   1.48 MagnetRadius Add 4
D_AutoCollect  Brainrot 2 Team   Coleta Automática         1 1e5   1    AutoCollect Add 1
D_Attract      Brainrot 2 Team   Atrair Brainrots Valiosos 1 2e4   1    AttractValuable Add 1
D_AutoRespawn  Brainrot 2 Team   Respawn Automático        1 1e4   1    AutoRespawn Add 1
D_Enchant      Brainrot 2 Team   Chance de Encantamento   10 4e3   1.54 EnchantChance Add 0.02
D_CritMult     Weapon   2 Player Multiplicador de Crítico 10 1e3   1.54 CritMult Add 0.25
D_Ingredients  Brainrot 2 Team   Sorte de Ingredientes    10 600   1.54 IngredientLuck Mult 0.2
D_CoinMult     Brainrot 3 Team   Multiplicador de Moedas  10 8e4   1.27 CoinMult Mult 0.3
D_EnchantPower Brainrot 3 Team   Poder de Encantamento    10 8e4   1.27 EnchantPower Mult 0.15
D_Damage2      Weapon   3 Player Dano+                    15 2e3   1.36 Damage Pow 1.2
D_Spawn2       Brainrot 3 Team   Mais Brainrots+          10 4e4   1.27 SpawnCount Add 1
```

### 5.7 `Config/Brainrots.lua`
```lua
{
  Tiers = { Low = { Name = "Baixo", Color = Color3 }, Medium = { Name = "Médio", ... }, High = { Name = "Alto", ... } },
  List = { { Id = "TungTungSahur", DisplayName = "Tung Tung Tung Sahur", Map = "Meadow", Tier = "Low",
             BaseHealth = 10, BaseCoinValue = 2, BaseScale = 1.0, GrowTime = 5, SpawnWeight = 20,
             Archetype = "Totem", Colors = { Primary = Color3, Secondary = Color3, Accent = Color3 },
             ModelName = "TungTungSahur", SoundId = 0, Catchphrase = "tung tung tung!" }, ... },
  Supreme = { Id = "TralaleroSupremo", DisplayName = "Tralalero Supremo", Archetype = "Fish", Colors = {...}, ModelName = "TralaleroSupremo" },
  ById = {}, ByMap = {},   -- montados por código
}
```
- 9 brainrots por mapa: 3 `Low` (Health 10, Coin 2, Scale 1.0, GrowTime 5, Weight 20), 3 `Medium` (40, 10, 1.3, 8, 10), 3 `High` (150, 45, 1.7, 11, 3.3). Pode variar ±20% entre eles para ter personalidade.
- Prado: Low = Tung Tung Tung Sahur, Brr Brr Patapim, Trippi Troppi; Medium = Chimpanzini Bananini, Boneca Ambalabu, Ballerina Cappuccina; High = Tralalero Tralala, Cappuccino Assassino, Bombardiro Crocodilo.
- Inverno: Low = Frigo Camelo, Pinguino Congelino, Ta Ta Ta Sahur; Medium = Glorbo Gelatino, Orsetto Ghiacciolo, Bombombini Gusini; High = Tric Trac Baraboom, Tigrrullini Watermellini, La Vaca Saturno Saturnita.
- Deserto: Low = Lirilì Larilà, Cactusino Bandito, Sahur del Deserto; Medium = Camello Tostato, Garamararam, Bananita Dolfinita; High = Burbaloni Luliloli, Graipussi Medussi, Tralalero Faraone.
- `Archetype` ∈ `"Totem"` (tronco em pé com braços, ex. Tung Tung), `"Quadruped"` (corpo + 4 pernas + cabeça), `"Flyer"` (corpo + asas), `"Fish"` (corpo de peixe/tubarão com pernas), `"Blob"` (esfera com olhos), `"Biped"` (humanoide simples, ex. bailarina), `"Tree"` (tronco + copa, ex. Patapim), `"Cactus"`.
- Escala 1 = modelo com ~5 studs de altura.

### 5.8 `Config/Enchants.lua`
```lua
{ List = {
  { Id = "Golden", Name = "Dourado", Color = Color3, CoinMult = 3, SizeMult = 1, GrowthMult = 1, Weight = 50 },
  { Id = "Ice", Name = "Gelo", Color = Color3, CoinMult = 2, SizeMult = 2, GrowthMult = 1, Weight = 30,
    MapOverrides = { Winter = { CoinMult = 6, WeightMult = 3 } } },
  { Id = "Fire", Name = "Fogo", CoinMult = 2, Weight = 25, Special = "Ignite" },
  { Id = "Rainbow", Name = "Arco-íris", CoinMult = 10, Weight = 8, Rainbow = true },
  { Id = "Radioactive", Name = "Radioativo", CoinMult = 2, GrowthMult = 3, Weight = 15 },
  { Id = "Galactic", Name = "Galáctico", CoinMult = 50, Weight = 1, Announce = true },
}, ById = {} }
```
Campos ausentes: `SizeMult = 1`, `GrowthMult = 1`, `Maps = nil` (nil = todos os mapas). Multiplicador efetivo de moedas: `1 + (CoinMult - 1) * stats.EnchantPower`.

### 5.9 `Config/Coins.lua`
```lua
{ Tiers = { { Name = "Bronze", Value = 1, Color, Size = 0.8 }, { "Prata", 10, 0.95 }, { "Ouro", 100, 1.1 },
            { "Esmeralda", 1e3, 1.3 }, { "Diamante", 1e4, 1.5 }, { "Rubi", 1e5, 1.8 }, { "Brainrot Dourado", 1e6, 2.2 } },
  MaxPiecesPerDeath = 8, MaxCoinsOnGround = 250, DespawnTime = 120, PickupRadius = 4,
  SettleTime = 1.2, CrateScatter = 7, AutoCollectDelay = 0.6, MagnetPullSpeed = 60,
  DropMode = "Crate" }   -- "Crate" (moedas caem perto do caixote, como no original) ou "OnDeath"
```

### 5.10 `Config/Quests.lua`
```lua
{ Templates = {
  { Id = "Kill", Type = "Kill", Text = "Destrua %s brainrots", Base = 40 },
  { Id = "KillHigh", Type = "KillTier", Tier = "High", Text = "Destrua %s brainrots de tier Alto", Base = 5 },
  { Id = "Collect", Type = "Collect", Text = "Colete %s moedas", BaseSeconds = 60 },
  { Id = "Chain", Type = "Chain", Text = "Cause %s explosões de brainrot", Base = 3, Requires = { Stat = "ExplodeChance", Min = 0.01 } },
  { Id = "Giant", Type = "KillGiant", Text = "Destrua %s brainrot(s) gigante(s)", Base = 1, Requires = { Stat = "GiantChance", Min = 0.01 } },
  { Id = "Crit", Type = "Crit", Text = "Acerte %s críticos", Base = 20 },
  { Id = "Enchanted", Type = "KillEnchanted", Text = "Destrua %s brainrots encantados", Base = 3, Requires = { Stat = "EnchantChance", Min = 0.01 } },
}, RewardSeconds = 45, RewardFloor = 50, ScalePerUpgradeLevel = 1 / 40 }
```
Alvo = `ceil(Base * (1 + somaDeNíveisDoJogadorETime * ScalePerUpgradeLevel))`; para `Collect`: `max(RewardFloor*CostScale, Income * BaseSeconds)`. Recompensa = `max(RewardFloor * CostScale, Income * RewardSeconds) * stats.QuestReward`, com `Income = run.IncomeSlow / Formulas.PassCoinMult(passes de moedas do jogador + evento global)` (a renda já vem com os passes e o evento, e o `AddCoins` aplica os dois de novo ao pagar; o HUD e a `StallWindow` mostram `Reward × PassCoinMult`, o que cai na carteira).

### 5.11 `Config/Recipes.lua`
```lua
{ Ingredients = {
    { Id = "MysticSand", Name = "Areia Mística", Color, DropChance = { Low = 0.03, Medium = 0.06, High = 0.12 } },
    { Id = "AssassinEspresso", Name = "Espresso Assassino", ... }, { Id = "CosmicBanana", Name = "Banana Cósmica", ... },
    { Id = "SahurDrum", Name = "Tamborim de Sahur", ... }, { Id = "EternalIce", Name = "Gelo Eterno", ... } },
  Recipes = {
    { Id = "DoubleDamage", Name = "Molho de Tralalero", Hint = "Algo arenoso com algo muito forte...",
      Ingredients = { MysticSand = 1, AssassinEspresso = 2 }, CoinCost = 5e4, Kind = "Permanent",
      Effects = { { Stat = "Damage", Mode = "Mult", Value = 1 } } },           -- Mult 1 → ×2
    { Id = "TripleCoins", Kind = "Permanent", Effects = { { Stat = "CoinMult", Mode = "Mult", Value = 2 } }, ... },
    { Id = "GrowthBoost", Kind = "Permanent", Effects = { { Stat = "GrowthMult", Mode = "Pow", Value = 1.5 } }, ... },
    { Id = "TurretFrenzy", Kind = "Permanent", Effects = { { Stat = "TurretFireRate", Mode = "Mult", Value = 1 } }, ... },
    { Id = "EnchantStorm", Kind = "Timed", Special = "EnchantAll", Duration = 60, ... },
    { Id = "GiantWave", Kind = "Instant", Special = "NextWaveGiant", ... },
    { Id = "SupremeSoup", Kind = "Instant", Special = "SupremeBoost", Amount = 0.05, ... },
    { Id = "HeatSink", Kind = "Permanent", Effects = { { Stat = "HeatCapacity", Mode = "Mult", Value = 1 } }, ... },
  }, ById = {}, IngredientsById = {} }
```
`CoinCost` em unidades do Ato 1 (multiplicar pelo `CostScale` do Deserto). Receitas `Permanent` só podem ser feitas uma vez por partida. Cada receita usa 2 ou 3 ingredientes (contagem total ≤ 3) e todas as combinações são diferentes.

### 5.12 `Config/Achievements.lua`
```lua
{ List = {
  { Id = "FirstBlood", Name = "Primeiro Brainrot", Description = "Destrua 1 brainrot", Stat = "KillsTotal", Threshold = 1, Tokens = 1 },
  { Id = "LowHarvest", Name = "Colheita de Sahur", Description = "Destrua 1.000 brainrots de tier Baixo", Stat = "Kills.Low", Threshold = 1000, Tokens = 5 },
  { Id = "MediumCollection", ..., Stat = "Kills.Medium", Threshold = 500 },
  { Id = "LegendHunter", ..., Stat = "Kills.High", Threshold = 100 },
  { Id = "CompleteMeadow", ..., Event = "CompleteMap", Map = "Meadow" },
  { Id = "CompleteWinter", ..., Event = "CompleteMap", Map = "Winter" },
  { Id = "EclipseBrainrot", Name = "Eclipse Brainrot", Secret = true, Event = "CompleteMap", Map = "Desert", Tokens = 25 },
  { Id = "FirstGalactic", Stat = "Galactic", Threshold = 1 }, { Id = "ChainMaster", Stat = "Chains", Threshold = 100 },
  { Id = "Billionaire", Stat = "TotalCoins", Threshold = 1e9 }, { Id = "SquadGoals", Event = "PlayWithFriends", Count = 4 },
  { Id = "MasterChef", Stat = "RecipesDiscovered", Threshold = 8 }, { Id = "QuestLover", Stat = "QuestsCompleted", Threshold = 50 },
}, ById = {} }
```
Cada um tem `BadgeId = 0` (o dono preenche) e `Tokens`.

### 5.13 `Config/Cosmetics.lua`
`{ Skins = { { Id = "Classic", Name = "Clássica", Price = 0, GunColor, TracerColor }, { Id = "NeonPink", "Rosa Neon", 10 }, { "ToxicGreen", "Verde Tóxico", 15 }, { "IceBlue", "Azul Gelo", 20 }, { "Golden", "Dourada", 40 }, { "Rainbow", "Arco-íris", 60, Rainbow = true } }, ById = {} }`

### 5.14 `Config/Keybinds.lua`
`{ Actions = { { Id = "Forward", Name = "Andar para frente", Default = Enum.KeyCode.W }, Back (S), Left (A), Right (D), Jump (Space), Sprint (LeftShift), Interact (E), Rotate (R), Cancel (Q) }, ById = {} }`

### 5.15 `Config/Admins.lua`
Lido pelo servidor (`AdminService`, que confere tudo) e pelo cliente (painel de admin e ajuda).
```lua
{
  OwnerIsAdmin = true,            -- o dono da experiência é admin ("Owner"): game.CreatorId (CreatorType User)
                                  -- ou o dono do grupo, cargo 255 (CreatorType Group)
  OwnerUserIds = { 335101108 },   -- sempre "Owner" (mesmo se o jogo for passado para um grupo)
  UserIds = { 1179661787 },       -- admins com o cargo "Admin"
  GroupMinRank = 0,               -- jogo de grupo: cargo >= isto vira "Admin" (0 = desligado)
  StudioEveryoneAdmin = true,     -- no Studio todo jogador de teste é "Admin"
  ChatPrefix = ":",               -- ":fly", ":coins all 1000"
  MaxMinutes = 120,               -- duração máxima de um evento global (no nível de cima, não dentro de Events)
  AnnounceMaxLength = 200, AnnounceDuration = 8,   -- letras e segundos na tela do ":announce"
  CoinRainDefault = 1000, CoinRainPiles = 4,       -- ":coinrain" sem número: moedas por jogador (× CostScale) e montinhos
  Commands = { { Name, Args = { {Name, Type, Optional?, Min?, Max?, Integer?} }, Scope = "Any"|"Match", Category, Description } },
  CommandsByName = { [name] = command },          -- montado por código
  Events = { moedas2x = {Name, Description, Effects}, sorte = ..., gigantes = ..., abuse = ... },
  EventOrder = { "moedas2x", "sorte", "gigantes", "abuse" },
}
```
- Tipos de argumento: `"player"` (começo do nome, começo do nome de exibição, UserId, `"me"`, `"all"`, `"others"`; também `"eu"`, `"todos"`, `"outros"`; um texto só de dígitos nunca é lido como começo de nome; em `kick`/`ban` só vale nome completo, nome de exibição completo ou UserId, e número é sempre UserId), `"number"` (aceita `1000`, `2,5`, `1e6`, `10k`, `3m`, `1b`, `1t`; `Min`/`Max`/`Integer` opcionais), `"text"` (o último argumento junta o resto da frase), `"duration"` (`"30m"`, `"2h"`, `"1d"`, `"7d"`, `"perm"` = -1; até 365 dias), `"event"` (chave de `Events`). Argumento `"player"` opcional ausente = o próprio admin.
- `Commands` (ordem do painel e da ajuda; `Scope`):
  - Movimento (`Any`): `fly`, `speed <velocidade 1..200>`, `jump <força 0..300>`, `tp <jogador>`, `bring <jogador>`, `respawn [jogador]`.
  - Partida (`Match`): `coins <jogador> <quantia>`, `wave`, `giant`, `coinrain [quantia]`, `maxall`, `nextact`, `supreme <0..1>`, `ingredients [jogador]`.
  - Perfil (`Any`): `tokens <jogador> <quantia>`, `unlockall <jogador>`.
  - Eventos (`Any`): `announce <texto>`, `event <evento> <minutos 1..MaxMinutes>`, `endevent`.
  - Moderação (`Any`): `kick <jogador> [motivo]`, `ban <jogador> <duração> [motivo]`, `unban <userId>`.
  - Ajuda (`Any`): `cmds`.
- `Events[key].Effects` (números; ausente = sem efeito): `CoinMult` (moedas × isto para todos, no `AddCoins`), `TierLuckAdd` (+ Sorte de Tier), `EnchantChanceMult` (chance de encantamento × isto), `GiantChanceAdd` (+ chance de gigante), `BoardCooldownMult` (recarga do quadro × isto). Valores: `moedas2x = {CoinMult = 2}`, `sorte = {TierLuckAdd = 1, EnchantChanceMult = 2}`, `gigantes = {GiantChanceAdd = 0.3}`, `abuse` = tudo junto + `BoardCooldownMult = 0.5`. Os eventos são **grátis** (ninguém paga Robux), então não são sorte paga e não precisam mostrar chances.

### 5.16 `Config/Audio.lua` (2.0)
A "biblioteca de áudio": cada som do jogo é pedido por uma **vaga** (slot, um nome curto como `"Click"`, `"Coin"`, `"Music_Meadow"`, `"Amb_Winter"`), nunca por um id solto no código. Lido pelo cliente (`UIKit.ResolveSound`, seção 10.2) e, a partir da etapa 7, pelo servidor (`AudioService`, que preenche `ReplicatedStorage.AudioLibrary`).
```lua
{
  CacheStoreName = "BrainrotIncremental_AudioCache_v1", -- DataStore compartilhado com o que a busca automática achou
  SearchSpacing = 3,                -- segundos entre duas buscas de áudio
  MaxSearchesPerServer = 40,        -- máximo de buscas na vida de um servidor
  Pinned = {},                      -- [vaga] = assetId (número > 0): áudio fixado pelo dono
  Blocked = {},                     -- lista de assetIds (ou {[id] = true}) que nunca são usados
  Slots = {
    [vaga] = { Group = "SFX"|"UI"|"Music"|"Ambient", Volume = 0..1, Speed = número?, Looped = boolean?,
               Query = "palavras de busca (em inglês)", SubType = "SoundEffect"|"Music",
               MinDuration = s?, MaxDuration = s?,
               Fallback = { Id = "rbxasset://sounds/...", Volume, Speed }? },
  },
}
```
- **Resolução** de uma vaga (mesma ordem no cliente e no servidor; `UIKit.ResolveSound(key)`):
  1. `Config.Game.Sounds[key]` (efeitos) ou `Config.Game.Music[X]` (vagas `"Music_X"`): **> 0** = id fixo (`rbxassetid://<id>`); **-1** = mudo (resolve para `nil`, nada toca); **0** = automático (segue). Texto com `"://"` é usado como está.
  2. `Config.Audio.Pinned[key]` > 0 → esse id.
  3. `ReplicatedStorage.AudioLibrary` (Folder, criada pelo servidor na etapa 7; lida só **se existir**): atributo `"Slot_" .. key` (texto `"rbxassetid://..."`), ignorado se o id estiver em `Blocked`.
  4. `Config.Audio.Slots[key].Fallback` (arquivo que já vem instalado no cliente, com `Volume`/`Speed` próprios) ou `nil` = silêncio.
- `SubType`: só `"SoundEffect"` ou `"Music"` (os únicos valores de `Enum.AudioSubType`); fundos de ambiente (`Amb_*`) usam `"SoundEffect"` com `MinDuration ≥ 20`. `Group` decide o `SoundGroup` (seção 10.2); vaga sem `Group` usa `"Music"` para `Music_*`, `"Ambient"` para `Amb_*`/`Spot_*` e `"SFX"` para o resto.
- **Vagas** (lista fechada; novas vagas só entram aqui):
  - Efeitos antigos (as chaves de `Config.Game.Sounds`): `Shoot`, `Hit`, `Crit`, `Coin`, `Death`, `Explosion`, `Purchase`, `Error`, `Notify`, `Turret`, `Portal`, `Craft`.
  - Interface: `Click`, `Hover`, `Open`, `Close`, `Tick`, `Reward`, `Rare`, `Fanfare`.
  - Combate: `Pistol_Fire`, `Pistol_Mech`, `Gelato_Fire`, `Gelato_Layer`, `Minigun_Fire`, `Minigun_Spin`, `Minigun_Tail`, `Overheat`, `Ready`, `Whoosh`, `Splat`, `Tinkle`, `Hit_Squish`, `Kill_Pop`, `Casing`.
  - Momentos especiais: `Sting`, `Chime`.
  - Músicas: `Music_Lobby`, `Music_Meadow`, `Music_Winter`, `Music_Desert`, `Music_Ending` (sem `Fallback`: silêncio é melhor que uma música errada).
  - Fundos de ambiente (loop): `Amb_Lobby`, `Amb_Meadow`, `Amb_Winter`, `Amb_Desert`.
  - Sons de lugar (3D, tag `AmbientSound`, seção 7.8): `Spot_Birds`, `Spot_Water`, `Spot_Wind`, `Spot_Fire`, `Spot_Crowd`.
- **Sons embutidos** usados como `Fallback` (existem em todo aparelho): `Click`/`Tick`/`Hover` → `rbxasset://sounds/volume_slider.ogg` (tom 1,1 a 2,0); `Explosion` → `rbxasset://sounds/impact_explosion_03.mp3`; `Splat` → `rbxasset://sounds/impact_water.mp3`; `Death`/`Kill_Pop` → `rbxasset://sounds/action_jump_land.mp3` (tom 1,4); `Error` → `rbxasset://sounds/ouch.ogg` (volume baixo).
- Para fixar um áudio: copie o id para `Pinned` (ex.: `Pinned.Coin = 1234567890`) ou direto em `Config.Game.Sounds`/`Music`. Para nunca usar um áudio que a busca achou: ponha o id em `Blocked`.

---

## 6. Utilitários compartilhados

### 6.1 `Util/NumberFormat.lua`
- `NumberFormat.Abbrev(n, decimals?)` → `"999"`, `"1,23K"`, `"45,6M"`, `"7,89B"`, sufixos `K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc, Ud, Dd, Td` e, acima disso, notação `1,23e45`. Vírgula decimal (pt-BR). Negativos com `-`.
- `NumberFormat.Commas(n)` → `"1.234.567"`.
- `NumberFormat.Percent(x, decimals?)` → `0.153` → `"15,3%"`.
- `NumberFormat.Time(seconds)` → `"1:05"` ou `"1:02:03"`.
- `NumberFormat.Stat(value, format)` usando `Config.Stats.Display[..].Format`.

### 6.2 `Util/Tables.lua`
`DeepCopy(t)`, `Reconcile(target, template)` (adiciona chaves faltantes recursivamente), `Count(t)`, `Keys(t)`, `Shuffle(t)`, `WeightedPick(list, weightFn) -> item`.

### 6.3 `Util/Formulas.lua`
- `Formulas.ApplyEffect(value, mode, perLevel, level) -> number`.
- `Formulas.UpgradeCost(def, currentLevel) -> number` = `def.BaseCost * Maps[def.Map].CostScale * def.CostMult ^ currentLevel`.
- `Formulas.CostForLevels(def, currentLevel, count) -> totalCost, levels` (respeita `MaxLevel`).
- `Formulas.MaxAffordable(def, currentLevel, coins) -> levels, totalCost`.
- `Formulas.ShelfCost(mapId, nextShelf) -> number` = `ShelfCosts[nextShelf] * CostScale`.
- `Formulas.ComputeStats(mapId, playerLevels, teamLevels, recipesApplied, extras) -> stats`:
  1. copia `Stats.Defaults`; 2. aplica `Weapons[Maps[mapId].Weapon].Stats`; 3. aplica `Maps[mapId].StatOverrides`; 4. percorre `Upgrades.ByMap[mapId]` em ordem aplicando `ApplyEffect` com o nível do escopo certo; 5. aplica efeitos das receitas `Permanent` aplicadas (`Mode/Value` com nível 1); 6. game passes e evento global: `CoinMult *= Formulas.PassCoinMult(extras)` (menos quando `extras.Team == true`), se `extras.DoubleDamage`, `Damage *= Gamepasses.DAMAGE_MULT` (2; só o dano da arma, `TurretDamage` não muda), e `Formulas.ApplyEventEffects(stats, extras.Event)`; 7. aplica `Clamps`. `Projectiles` e `Pierce` são arredondados para baixo. `extras = {DoubleCoins = boolean, VIP = boolean, DoubleDamage = boolean, Event = Effects?, Team = boolean?}` (passes do próprio jogador; campos ausentes = `false`/`nil`; nos stats do time vai `{Team = true, Event = ...}`: o bônus de moedas fica de fora do `CoinMult` do time porque o `AddCoins` aplica ele em cada jogador).
- `Formulas.PassCoinMult(extras) -> number` = `(DoubleCoins ? 2 : 1) × (VIP ? Config.Game.GamepassVipCoinMult : 1) × Formulas.EventCoinMult(extras.Event)`. Usado no passo 6 e no `MatchService.AddCoins` (a mesma conta nos dois).
- Evento global (`extras.Event` = `Config.Admins.Events[key].Effects`, seção 5.15): `Formulas.EventCoinMult(effects) -> number` (`CoinMult`, 1 sem evento, limitado a 1..10), `Formulas.EventBoardCooldownMult(effects) -> number` (`BoardCooldownMult`, 1 sem evento, limitado a 0,1..1), `Formulas.ApplyEventEffects(stats, effects)` (muda a tabela: `TierLuck += TierLuckAdd`, `EnchantChance *= EnchantChanceMult`, `GiantChance += GiantChanceAdd`; depois dos upgrades e antes dos `Clamps`).
- `Formulas.BrainrotMaxHealth(def, mapId, sizeFactor, playerCount)` = `def.BaseHealth * HealthScale * sizeFactor^2 * (1 + Game.HealthScalePerExtraPlayer * (playerCount - 1))`.
- `Formulas.BrainrotCoinValue(def, mapId, sizeFactor)` = `def.BaseCoinValue * ValueScale * sizeFactor^2`.
- `Formulas.EnchantCoinMult(enchantDef, mapId, enchantPower)`.
- `Formulas.QuestReward(mapId, income, questRewardStat)`.
- `Formulas.IsUpgradeMaxed(def, level)`.

`sizeFactor` = tamanho relativo do brainrot (1 = tamanho base adulto sem upgrades). A escala do modelo é `def.BaseScale * sizeFactor`.

### 6.4 `Util/Gamepasses.lua`
Lista dos game passes e a regra de venda, usada pelo servidor (`MonetizationService`) e pelo cliente (HUD e loja do lobby):
- `Gamepasses.List` = `{ {Key, Name, Description, BuffText, Color} }` na ordem das lojas: `DoubleCoins` ("Moedas em Dobro"), `AutoCollect` ("Coleta Automática"), `ExtraTurret` ("Torreta Extra"), `VIP` ("VIP"), `DoubleDamage` ("Dano em Dobro"). `Gamepasses.ByKey[key]`.
- `Gamepasses.IsValidKey(key)` (lista fechada), `Gamepasses.GetId(key) -> id?` (só se `Config.Game.Gamepasses.Enabled == true` e id > 0), `Gamepasses.IsForSale(key)` (= ligado aqui), `Gamepasses.AnyForSale()`, `Gamepasses.KeyFromId(passId) -> key?`.
- `Gamepasses.VipCoinMult()` lê `Config.Game.GamepassVipCoinMult` com valor seguro (valor inválido = sem bônus). `Gamepasses.DAMAGE_MULT = 2` (Dano em Dobro).
- `Gamepasses.FetchSaleInfo(key, maxAge?) -> {IsForSale, Price}?` — `MarketplaceService:GetProductInfoAsync(id, Enum.InfoType.GamePass)` em `pcall` (pode esperar): `IsForSale` e `PriceInRobux` do Creator Hub. Guarda por id (por `maxAge` s, ou a sessão toda sem `maxAge`); falha = `nil` e não fica guardada. Preços nunca ficam no código.
- Todos os passes dão bônus fixos e só ao dono: nada de sorte paga, e o jogo nunca vende moedas por Robux (as moedas compram upgrades de sorte, que virariam "itens aleatórios pagos").

---

## 7. Mundo e prompts (`World/*`)

### 7.1 `World/MapBuilder.lua`
- `MapBuilder.Build(mapId) -> ctx` — `mapId` ∈ `"Lobby"`, `"Meadow"`, `"Winter"`, `"Desert"`. Ordem:
  1. Limpa o mundo antigo (`clearOldWorld`): apaga `workspace.Map`, o `Baseplate` padrão e `SpawnLocation`s soltas; limpa o terreno (`workspace.Terrain:Clear()`, em `pcall`, depois de apagar a pasta) e destrói os filhos do `Terrain` com o atributo `MapEffect = true` (nuvens). Depois `Common.ClearLightingEffects()` (efeitos, céu, nuvens, vento e cores do terreno do mapa anterior).
  2. Aplica a iluminação com `Common.ApplyLighting` (BASE + config): `Config.Lobby.Lighting` para `"Lobby"` (o lobby não está em `Config.Maps`) ou `Config.Maps[mapId].Lighting`; sem config, só a BASE. A luz é aplicada antes do builder (o Deserto usa a direção do sol para pôr a Grande Cova) e **de novo depois** dele, no mesmo quadro: a config sempre vence (builders não devem mexer na luz).
  3. Cria `workspace.Map` (Folder), chama `Builders[mapId].Build(folder)` e confere o `ctx` (seção 7.2).
  Na troca lobby → partida do Studio (seção 8.16) é esta limpeza que garante que nada do lobby (terreno, nuvens, vento, efeitos) sobre na partida.
- `MapBuilder.SetShelfLevel(ctx, level)` — mostra as prateleiras `<= level` de todas as barracas (as outras ficam invisíveis e sem colisão).
- `MapBuilder.OpenPortal(ctx, targetDisplayName) -> ProximityPrompt` — cria/ativa (uma vez só) o portal em `ctx.PortalSpot`, com um prompt (`ServerAction = "Portal"`, tag `GamePrompt`), e o retorna. **2.0: tudo ancorado, sem física** (nada de dobradiça nem `SetNetworkOwner`): o anel (Model) tem a tag `AmbientSpin` com `Axis` = eixo Z do portal e `Speed = 1.2` rad/s, e quem gira é cada cliente (`AmbientController`, seção 7.8). O miolo são 2 `Beam`s cruzados com `rbxasset://textures/particles/smoke_main.dds` (`TextureSpeed` 0.5, transparência 0.3 no meio e 0.8 nas pontas), o segundo girando ao contrário, mais as faíscas de antes. Mantém a peça `PortalAnchor` (segura prompt, luz, partículas e o texto), o billboard com o nome do destino e `lightPortalOrbs` (acende as `PortalOrb` do `PortalPad`).

### 7.2 Contexto `ctx` de uma partida
```lua
{
  MapId = "Meadow", Folder = workspace.Map,
  SpawnLocation = SpawnLocation, GroundY = number,
  FieldArea = Part,             -- invisível, CanCollide/CanQuery/CanTouch = false. Área onde brainrots nascem (usar CFrame e Size)
  Board = Part,                 -- quadro com ProximityPrompt (ServerAction = "Board", ActionText "Plantar brainrots")
  BoardPrompt = ProximityPrompt,
  Crate = Part, CoinDropPoint = Vector3,
  Stalls = { [stallId] = { Model = Model, Counter = BasePart, Prompt = ProximityPrompt, Shelves = { [shelfLevel] = {BasePart} }, Position = Vector3 } },
  PortalSpot = CFrame,
  TurretZones = { Part },       -- (Inverno/Deserto) partes invisíveis onde se pode pôr torreta
  TurretBase = { CFrame },      -- (Inverno/Deserto) pads para onde as torretas voltam no recall (>= 10)
  RecallPrompt = ProximityPrompt?,  -- (Inverno/Deserto) ServerAction = "RecallTurrets"
  Platform = Part?,             -- (Inverno) plataforma elevada
  Cauldron = Part?,             -- (Deserto) ClientAction = "Cauldron"
  Pit = Vector3?, PitPrompt = ProximityPrompt?,   -- (Deserto) Grande Cova; prompt ClientAction = "Supreme"
  OasisCenter = Vector3?, OasisRadius = number?,  -- (Deserto)
  SnowEmitterPart = Part?,      -- (Inverno) peça "SnowEmitter"; atributo ClientSnow = true = neve desenhada no cliente (seção 7.8)
}
```
Contexto do Lobby: `{ MapId = "Lobby", Folder, SpawnLocation, CreateTerminal = Part, PartyBoard = Part, Leaderboard = Part (com SurfaceGui "Board" que tem Frame "List"; é o painel de moedas), Leaderboards = { Coins = Part, Kills = Part, Acts = Part } (mesmo formato), ShopStand = Part, AchievementsStand = Part }`.

### 7.3 Prompts
- Todo `ProximityPrompt` tem `RequiresLineOfSight = false`, `MaxActivationDistance = 12`, `HoldDuration = 0` (menos o "Recolher" da torreta, 0.3), `KeyboardKeyCode = E`, `GamepadKeyCode = ButtonX`, `Style = Default` (os de `Common.Prompt` também `Exclusivity = OnePerButton`). Exceção: o prompt de modo da torreta usa `F` e o direcional para a direita, para não disputar a tecla com o "Recolher" no mesmo lugar.
- **Tag `GamePrompt` (2.0):** todo `ProximityPrompt` criado pelo jogo recebe a tag `GamePrompt` (CollectionService): os de `Common.Prompt`, os dois da torreta (`TurretFactory`) e o do portal (`MapBuilder.OpenPortal`, que usa `Common.Prompt`). O `PromptController` acha os prompts por essa tag (seção 10.3), sem vasculhar o `workspace` inteiro. Prompt novo feito à mão por código deve receber a tag também.
- Prompt tratado pelo **cliente**: atributo `ClientAction` = `"Stall:Weapon"`, `"Stall:Brainrot"`, `"Stall:Quest"`, `"Stall:Turret"`, `"Stall:Growth"`, `"Cauldron"`, `"Supreme"`, `"CreateParty"`, `"PartyList"`, `"Shop"`, `"Achievements"`, `"Settings"`. Formato: `"Ação"` ou `"Ação:Argumento"` (o `PromptController` corta no primeiro `:` e entrega o argumento ao handler).
- ClientActions do **lobby** (2.0; tratadas pelo `LobbyUI`, seção 10.4, e colocadas pelo builder do Lobby): `CreateParty[:<MapId>]`, `QuickPlay:<MapId>`, `Reconnect`, `PartyList`, `Shop[:Passes]`, `Achievements[:Stats|Goals]`, `Settings` (este continua registrado pela `SettingsWindow`). Exemplos: `"CreateParty:Winter"`, `"QuickPlay:Meadow"`, `"Shop:Passes"`, `"Achievements:Stats"`.
- Prompt tratado pelo **servidor**: atributo `ServerAction` = `"Board"`, `"RecallTurrets"`, `"Portal"`, `"PickupTurret"`, `"TurretMode"`. O serviço dono conecta `prompt.Triggered` usando a referência do `ctx` (ou do modelo da torreta).
- Partes auxiliares invisíveis (FieldArea, TurretZones etc.) e cercas/decoração baixa têm `CanQuery = false` (não bloqueiam tiros). Chão, pedras grandes e paredes têm `CanQuery = true`.

### 7.4 `World/Builders/Common.lua`
Helpers usados pelos builders (módulo de World: não dá `require` em serviço nenhum, só em `Shared/Config`). **API v2 (2.0):** todas as assinaturas antigas continuam valendo; as novas só acrescentam.

**Básicos (desde a 1.0):** `Common.Part(props) -> Part` (ancorado por padrão), `Common.Model(name, parent)`, `Common.Folder(name, parent)`, `Common.Prompt(parent, actionText, objectText, attributes) -> ProximityPrompt` (regras da seção 7.3, **com a tag `GamePrompt`**), `Common.Sign(part, face, text, textColor?, bgColor?) -> SurfaceGui, TextLabel`, `Common.Billboard(part, text, offset)`, `Common.Rock(parent, position, size, options?)`, `Common.Fence(parent, center: Vector3, size: Vector2, height, gapSide?)`, `Common.Stall(parent, stallId, cframe, color, title) -> stallTable` (base, balcão com prompt `ClientAction = "Stall:<id>"`, telhado listrado, placa com o nome, **3 prateleiras** atrás do balcão com itens decorativos — prateleira 1 visível, 2 e 3 escondidas até `SetShelfLevel`), `Common.Board(parent, cframe) -> part, prompt`, `Common.Crate(parent, cframe) -> part`, `Common.Ground(parent, size, color, material)`, `Common.Hill(parent, center, capRadius, height, color, material)`, `Common.SurfaceHeight(hills, x, z, baseY)`, `Common.Lamp(parent, position)` (desde a 2.0 é um `Common.Lantern` num poste de 10 studs; continua com as peças `Pole` e `Lantern`). Ajudantes de peça: `Common.Block`, `Common.Cylinder`, `Common.Ball`, `Common.Slab`, `Common.CylinderBetween`, `Common.Zone` (peça invisível e fantasma com atributos), `Common.Bounds`, `Common.SetVisible`, `Common.CoinMarker`, `Common.SpawnPad`, `Common.TurretPad`, `Common.RecallStation`, `Common.PortalPad`, `Common.SignPost`, `Common.SetSun`, `Common.Colors`.

**Tags e folhagem:**
- `Common.Tag(instance, tagName, attributes?) -> instance` — grava os atributos **antes** da tag (quem escuta a tag já encontra tudo pronto) e põe a tag (CollectionService). Ex.: `Common.Tag(moinho, "AmbientSpin", { Axis = Vector3.zAxis, Speed = 0.5 })`. Vocabulário na seção 7.8.
- `Common.Ghost(instance) -> instance` — "folhagem": `CanCollide`, `CanQuery` e `CanTouch = false` e, nas peças pequenas (segunda maior medida < 1 stud), `CastShadow = false`. Vale para a peça e todos os descendentes (modelos). Não mexe no `Terrain`.

**Terreno (voxels de 4 studs; seção 3.4 do plano):** só usado quando `Common.UseTerrain()` é `true`; senão os builders usam `Common.Ground`/`Common.Hill` (plano B). Toda chamada ao `Terrain` é protegida: um erro avisa no Output e o mapa continua. Ordem boa: `TerrainBase` → `TerrainHill` → `TerrainPond`/`TerrainCave` → `TerrainPath`.
- `Common.UseTerrain() -> boolean` — `GameConfig.UseTerrain ~= false`.
- `Common.TerrainBase(size: number, material: Enum.Material, center: Vector3?)` — chão quadrado de lado `size`, 8 studs de espessura, com o **topo em Y = 0** (ou em `center.Y`), alinhado na grade de 4 studs e preenchido em pedaços de 512 studs.
- `Common.TerrainHill(center: Vector3, capRadius: number, height: number, material, capMaterial?) -> {Position: Vector3, Size: Vector3}` — colina com o formato do `Common.Hill` (tampa de esfera), escrita só do chão para cima e somada ao terreno que já existe; `capMaterial` cobre o alto (acima de ~62% da altura, com borda irregular; ex.: neve no pico). O retorno tem o formato da esfera e serve direto no `Common.SurfaceHeight`.
- `Common.TerrainPath(points: {Vector3}, width: number, material)` — trilha ligando os pontos, com **1 voxel de fundo** (troca a camada de cima: Y −4..0 quando o ponto está em Y = 0), rente à grama. Chamar depois das colinas.
- `Common.TerrainPond(center: Vector3, radius: number, depth: number, shoreMaterial) -> {Center, Radius, Depth, WaterLevel}` — lago em "tigela", água um pouco abaixo do chão, margem de `shoreMaterial` até 1,35 × o raio.
- `Common.TerrainCave(center: Vector3, outerRadius: number, innerRadius: number, shellMaterial, options?) -> {Position, Size}` — casca (bola `outerRadius`) com o oco (bola `innerRadius`) e piso reto na altura de `center.Y`. `options = { Entrance = Vector3 (direção da boca no plano XZ), EntranceWidth = 10, EntranceHeight = 10, Floor = Enum.Material }`; sem `Entrance` a caverna fica fechada.
- `Common.TerrainColors(map: {[Enum.Material]: Color3})` — `Terrain:SetMaterialColor` de cada material; as cores originais voltam no `Common.ClearLightingEffects` (troca de mapa).
- Regras dos mapas: dentro de uma `FieldArea` o terreno fica entre `GroundY − 3` e `GroundY + 3` e **sem água** (o raio do chão dos brainrots não ignora água); um piso de `Part` continua embaixo do `CoinDropPoint` e de cada estação; água de terreno dentro de uma `TurretZone` precisa de uma peça `LakeCap` invisível (`Transparency 1`, `CanCollide false`, `CanQuery true`) na linha d'água (a sonda de chão do `TurretService` ignora água).

**Natureza e enfeites (kit v2):** materiais "de verdade" (`Wood`, `WoodPlanks`, `Slate`, `Rock`, `Fabric`, `Metal`, `Brick`...); `SmoothPlastic` só para coisas de brinquedo. Folhas, galhos e enfeites pequenos são fantasmas (`Common.Ghost`: não bloqueiam tiros nem jogadores).
- `Common.Tree(parent, position, style, scale, options?) -> Model` — `style`: `"Oak"` (carvalho), `"Birch"` (bétula), `"Pine"` (pinheiro), `"Palm"` (palmeira com folhas caídas de 3 lâminas e cocos) ou `"Dead"` (seca); estilo desconhecido vira `"Oak"` (os estilos antigos continuam). `options = { Lod = "Hero"|"Standard"|"Far" (padrão "Standard"), Snow = true (pinheiro com capinhas de neve inclinadas), Ghost = true (tronco sem colisão), Color = Color3 (folhas), Fronds = n (palmeira; padrão 12 Hero, 7 Standard) }`. Peças (Standard/Hero/Far): Oak 9/12/3, Birch 7/9/3, Pine 10/14/3, Palm 27/45/3, Dead 6/8/3. `"Far"` (horizonte): sem sombra, sem colisão, sem `CanQuery`.
- `Common.Bush(parent, position, scale?, color?)` — 3 bolas de folhas (fantasma).
- `Common.FlowerPatch(parent, position, palette?: {Color3})` — tufo com 4 flores nas cores da paleta.
- `Common.GrassTuft(parent, position, color?)` — 3 folhas pontudas em leque.
- `Common.Stump(parent, position, scale?)` — toco com o topo cortado e duas raízes.
- `Common.Log(parent, cframe, length, diameter?) -> Model, Part` — tora deitada na direção do `LookVector` do `cframe` (diâmetro padrão 1,4), pontas com a madeira cortada.
- `Common.Mushroom(parent, position, scale?, glow?: boolean)` — cogumelo; `glow = true` = chapéu Neon ciano (para cavernas), **sem** luz (quem monta o mapa decide onde vai a `PointLight`).
- `Common.Lantern(parent, cframe, options?) -> Model` — lampião v2 (no chão com poste, ou pendurado com `options.Hanging = true`), com a tag `AmbientFlicker`; luz `PointLight` `Range 16`, `Brightness 1.2`, `Shadows = false`. `options = { Hanging, Height = 8, ChainLength = 1.2, Color, MetalColor, Light = false (sem luz, para caber no limite de luzes), Range, Brightness, Shadows = true (só nas até 2 luzes "herói" do mapa), Name = "Lantern" }`.
- `Common.Critter(parent, position, kind, radius, count?)` — âncora invisível (fantasma, 1 stud) com a tag `AmbientCritter` e os atributos `Kind`, `Radius` e `Count` (opcional). `kind` ∈ `"Butterfly"`, `"Bird"`, `"Fish"`, `"Koi"`, `"Tumbleweed"`, `"Vulture"`, `"Firefly"` (`"Pet"` não usa âncora: a tag vai no Model do bichinho, com `Common.Tag`; `Common.Critter` com `"Pet"` só avisa no Output e devolve `nil`). Pássaros e urubus: âncora na altura do voo.
- `Common.SecretZone(parent, cframe, size, secretId, title)` — zona invisível e fantasma com a tag `Secret` e os atributos `SecretId` e `Title` (seção 7.8).

**Iluminação (seção 5.3):**
- `Common.ApplyLighting(config)` — aplica a **BASE** primeiro (apaga efeitos/céu/nuvens `MapEffect`, zera vento e água), depois as chaves do `Lighting` (`LIGHTING_KEYS`, agora com `LightingStyle` e `PrioritizeLightingQuality`), a `Atmosphere` (uma só, reaproveitada) e as sub-tabelas opcionais `PostFX`, `Sky`, `Clouds`, `Wind`, `Water`. Valor inválido numa chave só gera `warn`.
- `Common.LightingEffect(className, props) -> Instance` — **upsert**: reaproveita `Lighting["Map" .. className]` se já existe (senão cria), ajusta as propriedades e marca `MapEffect = true`. Chamar de novo com a mesma classe só ajusta o mesmo efeito.
- `Common.ClearLightingEffects()` — apaga os filhos com `MapEffect = true` do `Lighting` **e** do `workspace.Terrain` (nuvens), zera `workspace.GlobalWind` e devolve as cores originais do terreno (`TerrainColors`).

### 7.5 Mapas
- **Lobby**: praça de ~200×200 studs, tema fazenda brainrot colorida: spawn no centro, placa grande com o nome do jogo, terminal "Criar Partida" (prompt `CreateParty`), quadro "Partidas Abertas" (prompt `PartyList`), placar de líderes (SurfaceGui com lista), barraca de skins (prompt `Shop`), estátua de conquistas (prompt `Achievements`), árvores, cerca, lampiões, estátuas de brainrot decorativas (pode usar `BrainrotFactory`? **Não**: World não depende de ordem; o builder do Lobby pode fazer `require(script.Parent.Parent.BrainrotFactory)` porque é outro módulo de World). Iluminação de pôr do sol: `Config.Lobby.Lighting` (seção 5.2), aplicada pelo `MapBuilder` (o builder não mexe na luz).
- **Prado (Meadow)**: chão de grama ~420×420; campo retangular ~200×150 cercado (FieldArea = o retângulo do campo, ~2 studs acima do chão); do lado sul, a "praça" com Board, Crate, as 3 barracas lado a lado, PortalSpot; colinas (esferas grandes meio enterradas ou `Common.TerrainHill`) e árvores ao redor; sol visível (luz em `Config.Maps.Meadow.Lighting`).
- **Inverno (Winter)**: vale nevado ~420×420 (material Snow), plataforma de madeira elevada (~70×70, altura 14) no centro com rampa até o chão; na plataforma: Board, Crate, as 4 barracas, RecallPrompt, TurretBase (pads) e PortalSpot; FieldArea = anel em volta (use uma área retangular grande; o BrainrotService evita o volume da plataforma porque não nasce dentro de `ctx.Platform` expandida em 6 studs). TurretZones = plataforma + o vale. Pinheiros e pedras com neve. `SnowEmitterPart` (peça `SnowEmitter` alta; com o atributo `ClientSnow = true` o emissor do servidor fica com `Rate = 0` e cada cliente desenha a neve em volta da câmera, seção 7.8). Atmosfera densa.
- **Deserto (Desert)**: areia ~460×460, dunas; oásis central (lago azul, palmeiras, sombra) com as 5 barracas em volta, Board, Crate, Cauldron, RecallPrompt, TurretBase; a **Grande Cova** (cratera) a ~150 studs do oásis **na direção do sol** (use `game.Lighting:GetSunDirection()` depois de ajustar `ClockTime`, projetado no plano XZ) com `PitPrompt` na borda; FieldArea = região de areia entre o oásis e as bordas (evitar o oásis por raio: o BrainrotService não nasce a menos de `OasisRadius + 6` do centro, nem a menos de 40 studs do Pit). TurretZones = campo inteiro. Miragem: `ColorCorrection`/`BloomEffect` leve (em `Config.Maps.Desert.Lighting.PostFX`).

### 7.6 `World/BrainrotFactory.lua`
- `BrainrotFactory.Build(def) -> Model` — se `game.ServerStorage:FindFirstChild("BrainrotModels")` tiver um modelo com `def.ModelName`, clona e normaliza (todas as BaseParts `Anchored = true`, `CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `CollisionGroup = "Brainrots"`; `PrimaryPart` definido; `WorldPivot` no centro da base; escala ajustada para ~5 studs de altura). Senão, monta um modelo provisório pelo `Archetype` com as cores de `def.Colors`: corpo, olhos brancos com pupila preta, detalhes do personagem. `PrimaryPart` = parte chamada `"Body"`. Retorna o modelo em escala 1, sem pai.
- `BrainrotFactory.BuildSupreme(def) -> Model` — versão mais detalhada para o Brainrot Supremo.
- **Segurança dos modelos importados:** `BrainrotFactory.SanitizeTemplate(model)` roda logo depois do `Clone()` do modelo de `ServerStorage.BrainrotModels`, antes de medir, escalar ou pôr em qualquer lugar. Destrói `LuaSourceContainer` (Script/LocalScript/ModuleScript), `Sound`, `SpawnLocation`, `Seat`, `VehicleSeat`, `ProximityPrompt`, `ClickDetector`, `Tool`, `Explosion`, `ForceField`, `BillboardGui`, `SurfaceGui`; deixa no máximo 2 de cada `ParticleEmitter`, `Fire`, `Smoke`, `Sparkles` e luzes (`PointLight`/`SpotLight`/`SurfaceLight`); mantém `Humanoid` (com `EvaluateStateMachine = false`), roupas, acessórios e juntas. Avisa uma vez por modelo o que tirou. Partes invisíveis (`Transparency >= 0.98` e sem `Decal`/`Texture` visível; uma parte transparente com imagem, como um meme em 2D, conta como visível) não contam na medida do tamanho e ficam com `CanQuery = false` (se o modelo não tiver nenhuma parte visível, todas continuam atingíveis).
- **Cache de moldes:** o primeiro `Build(def)`/`BuildSupreme(def)` monta (ou normaliza) o modelo uma vez e guarda o molde sem pai; os seguintes devolvem `molde:Clone()`. Quem chama continua pondo nome, vida, encantamento, gelo e atributos no clone, como antes. `BrainrotFactory.Prewarm(def, supreme?)` monta o molde antes (o `BrainrotService.Start` pré-aquece os brainrots do mapa com `task.defer`).
- `BrainrotFactory.AttachBillboard(model, displayName, tierColor, enchantName?, enchantColor?) -> {Gui, Fill}` — BillboardGui (`AlwaysOnTop = false`, `MaxDistance = 250`, `StudsOffsetWorldSpace` acima da cabeça) com nome, tag de encantamento e barra de vida (`Fill` é o Frame cuja `Size.X.Scale` = fração de vida).
- `BrainrotFactory.ApplyEnchantVisual(model, enchantDef)` — partículas/brilho na cor do encantamento (não usar `Highlight`, que tem limite de 31).
- `BrainrotFactory.AddIceBlock(model) -> Part` — bloco de gelo translúcido em volta (Inverno).

### 7.7 `World/TurretFactory.lua`
- `TurretFactory.Build(ownerName, colors?) -> Model` com partes `Base` (PrimaryPart) e `Head` (gira no eixo Y; o cano aponta para `-Z` do Head), `Muzzle` (Attachment no Head), `MuzzleFlash` (2.0: Attachment no mesmo ponto do `Muzzle`, reservado para o clarão do tiro no cliente), um `BillboardGui` `OwnerTag` com o nome do dono e o modo de mira (TextLabels `OwnerName` e `Mode`), e dois prompts (tag `GamePrompt`): `PickupPrompt` com `ServerAction = "PickupTurret"` (ActionText "Recolher", `HoldDuration = 0.3`) e `ModePrompt` com `ServerAction = "TurretMode"` (ActionText "Mirar: mais valioso"). `CollisionGroup = "Turrets"` em tudo.
- **Cabeça soldada (2.0):** `Base`, coluna e `Head` são ancoradas; as outras peças da cabeça (canos, olho, antena...) ficam **soltas** (`Anchored = false`), `Massless = true` e presas na `Head` com um `WeldConstraint` `HeadWeld`. Cada uma continua com o atributo `HeadOffset` (CFrame relativo à `Head`). Materiais `Metal`/`DiamondPlate`; o "olho" é uma pecinha Neon pequena com a tag `AmbientFlicker` (a luz fraca dele treme no cliente).
- `TurretFactory.AimHead(model, targetPosition)` — gira o Head para o alvo mudando **só `Head.CFrame`**: as peças soldadas acompanham e a rede replica uma peça por mira (antes eram 11). Um modelo antigo (peças da cabeça ainda ancoradas com `HeadOffset`) ainda funciona: essas peças são movidas junto com `workspace:BulkMoveTo`.

### 7.8 Tags de ambiente (2.0)
O servidor (builders e `Common`) só **marca** as coisas com tags do `CollectionService` e atributos; quem anima é cada cliente (`AmbientController`, seção 10.3), sem nenhum laço por quadro no servidor e sem replicar movimento. Os atributos são gravados **antes** da tag (`Common.Tag`). Nada disso dá recompensa. Tag de um modelo vale para o modelo todo (peças ancoradas movidas juntas com `workspace:BulkMoveTo`; o movimento local de uma peça ancorada do servidor não replica).

| Tag | Onde vai | Atributos | O que o cliente faz |
|---|---|---|---|
| `AmbientSpin` | BasePart ou Model (anel do portal, moinho, estátua, catavento, polia) | `Axis: Vector3` (eixo no espaço do objeto; padrão Y), `Speed: number` (rad/s; negativo gira ao contrário; padrão 1) | gira em volta do pivô |
| `AmbientBob` | BasePart ou Model (balões, cristais) | `Amplitude: number` (studs; padrão 0.5), `Period: number` (s; padrão 3) | sobe e desce |
| `AmbientSway` | BasePart ou Model (bandeirinhas, placas, galhos) | `Angle: number` (graus; padrão 5), `Period: number` (s; padrão 3); opcional `SwayAxis: Vector3` (padrão Z; sem `AmbientSpin` junto, `Axis` também serve) | balança de um lado para o outro |
| `AmbientFlicker` | uma `Light` (`PointLight`/`SpotLight`/`SurfaceLight`), ou uma peça/modelo cujas luzes descendentes tremem | — | brilho × (0,88 a 1,0) com ruído suave (chama de lampião, fogueira, olho da torreta) |
| `AmbientEmitter` | um `ParticleEmitter` ou a peça que é pai dele | `MaxDistance: number` (studs; padrão 150) | o emissor só fica ligado perto da câmera (e dentro do limite de emissores) |
| `AmbientCritter` | uma âncora invisível (`Common.Critter`); para `Pet`, o Model do bichinho | `Kind: "Butterfly"\|"Bird"\|"Fish"\|"Koi"\|"Pet"\|"Tumbleweed"\|"Vulture"\|"Firefly"`, `Radius: number` (studs), `Count: number?` | cria os bichinhos no cliente (pasta `ClientAmbient`) e anima; `Pet` passeia com o próprio modelo |
| `AmbientAurora` | Model com os `Beam`s da aurora (desligados por padrão) | — | liga os Beams (com fade) quando `Lighting.Atmosphere.Density <= 0.12` (upgrades "Farol da Nevasca" no Inverno) e abre as nuvens (Cover 0.35) localmente |
| `AmbientSound` | uma peça âncora (o ponto do som) | `SoundKey: string` (vaga de `Config/Audio`, ex.: `"Spot_Water"`) | som 3D em loop do `UIKit.ResolveSound(SoundKey)` (grupo `Ambient`, `RollOffMaxDistance` 80), criado a até 120 studs e apagado depois de 150; sem áudio resolvido = nada |
| `Secret` | zona invisível e fantasma (`Common.SecretZone`) | `SecretId: string`, `Title: string` | etapa 7: perto da zona (8 studs), aviso "Segredo encontrado: <Title>!" uma vez por sessão; só visual, nada vai ao servidor |
| `LobbyNPC` | Model de um NPC guia do lobby | `Role: string` (ex.: `"CreateParty"`, `"Shop"`) | reservado para a interface do lobby (etapas 3 e 5); o prompt do NPC fica numa peça separada, fora do modelo |
| `LibraryModel` | Model de brainrot decorativo do lobby (estátuas, NPCs, pets) | `BrainrotDefId: string`, `LibraryScale: number` | etapa 4: o servidor troca a geometria pelo modelo pronto da ModelLibrary, mantendo nome, pivô, tags e atributos |
| `GamePrompt` | todo `ProximityPrompt` do jogo | (os de sempre: `ClientAction`/`ServerAction`) | o `PromptController` aplica a tecla `Interact` e acompanha o prompt (seção 7.3) |

Atributos de apoio:
- `MaxDistance` (opcional) numa peça/modelo com `AmbientSpin`/`AmbientBob`/`AmbientSway`: distância da câmera até onde ele se mexe (padrão 150 studs; útil para marcos grandes vistos de longe).
- `ClientSnow = true` na peça `SnowEmitter` do Inverno (`ctx.SnowEmitterPart`, gravado pelo builder do Inverno): "o emissor do servidor está desligado (`Rate = 0`), o cliente desenha a neve". Sem o atributo, o cliente não desenha neve (não duplica a do servidor).
- `MapEffect = true`: marca efeitos de pós-processamento, `Sky` e `Clouds` criados pelo mapa (apagados na troca de mapa; seção 5.3).

Clima que segue a câmera (sem tag; pelo tipo do mapa): neve no Inverno (só com `ClientSnow`), areia no Deserto, pólen no Prado e vaga-lumes no Lobby. Limites (cliente): até 1.500 partículas de ambiente vivas no Inverno e 600 nos outros lugares, até 10 emissores de ambiente ligados, até 30 peças de bichinhos, movimento a 30 Hz só até 150 studs da câmera, escolhas (quem está perto, liga/desliga) a 4 Hz, e ≤ 0,3 ms por quadro. Com `StateController.GetEffectsQuality() == 1` (baixa): metade das partículas e nenhum bichinho.

---

## 8. Serviços da partida

### 8.1 `Main.server.lua`
1. `Net.Init()`; registra grupos de colisão com `PhysicsService:RegisterCollisionGroup` (`"Players"`, `"Brainrots"`, `"Coins"`, `"Turrets"`) e regras: `Coins` não colide com `Players`, `Brainrots`, `Coins`, `Turrets`; `Brainrots` não colide com `Players` nem `Brainrots`.
2. `role = PlaceRole.Get()`; `workspace:SetAttribute("Role", role)`; se debug estiver ligado, `workspace:SetAttribute("DebugEnabled", true)`.
3. Comuns: `StateService`, `DataService`, `SettingsService`, `AchievementService`, `DebugService`, `AdminService`, `TravelService` (Init; o Start deles roda depois do Init dos serviços do papel).
4. Lobby: `LobbyService`, `PartyService`, `ShopService`, `MonetizationService` (Init, depois Start de todos).
5. Partida: `MatchService.Init()` (resolve a partida e constrói o mapa — pode esperar), depois `StatService, MonetizationService, CoinService, BrainrotService, CombatService, UpgradeService, ProgressionService, QuestService, TurretService, RecipeService, SupremeService` (Init de todos, depois Start de todos), e por fim `MatchService.Start()` (começa a aceitar jogadores).
6. Cada Init/Start dentro de `pcall`/`xpcall` com `warn` do erro e o nome do serviço (um serviço quebrado não derruba os outros).
7. `callPhase(name, method)` roda cada fase **no máximo uma vez por servidor**: a tabela `phaseDone[name .. "." .. method]` é marcada antes de rodar, e uma segunda chamada é ignorada (ex.: `MonetizationService` está nas listas do lobby e da partida).
8. No passo 2, o atributo `DebugMode` do `workspace` só conta no Studio (seção 8.17); num place publicado, só `Config.Game.DebugMode` liga o `DebugEnabled`.
9. **Só no Studio (2.0):** no ramo do Lobby, depois do Start dos serviços do lobby, se `RunService:IsStudio()` e `GameConfig.StudioInPlaceMatch ~= false`, chama `TravelService.SetStudioMatchSwitch(switchToMatch)`. `switchToMatch(handoff)` transforma o lobby de teste na partida no mesmo servidor (passos na seção 8.16); roda no máximo uma vez (flag local `switched`; uma segunda chamada só avisa) e só a partir do papel `"Lobby"`. `callPhase` devolve `true` (rodou sem erro), `false` (erro, ou serviço/função faltando) ou `nil` (já tinha rodado); só a troca usa esse retorno. O `phaseDone` continua valendo: o `MonetizationService`, que já rodou no lobby, é pulado na partida.

### 8.2 `MatchService`
Estado:
```lua
MatchService.MapId, MatchService.MapDef, MatchService.Act, MatchService.Context (ctx), MatchService.Handoff
MatchService.StudioHandoff = nil  -- 2.0, só Studio: handoff da troca lobby -> partida (o Main preenche antes do Init)
MatchService.Team = { Upgrades = {}, ShelfLevel = 1, Recipes = {}, Buffs = { TimedEnchantUntil = 0, NextWaveGiant = false },
                      SupremeProgress = 0, Turrets = { { OwnerUserId, Position = {x,y,z}, RotY } }, SharedCoins = 0 }
MatchService.Runs[userId] = { UserId, Name, Coins = 0, Upgrades = {}, Ingredients = {}, Quest = nil, QuestCooldownEnd = 0,
                              IncomeEMA = 0, Heat = 0, Overheated = false }
```
Funções:
- `Init()` — resolve o handoff: no Studio, se `MatchService.StudioHandoff` é uma tabela (troca lobby → partida, seção 8.16), usa ela por cima do handoff padrão: `MapId` conferido (inválido → `StudioMapId`), `HostUserId` do grupo se ele está no servidor, `Members = nil` (**todos os jogadores presentes entram**), `MaxPlayers` nunca menor que o número de jogadores presentes, `Resume` só quando `DataService.UsesStudioStores()`, sem `AccessCode`/`PrivateServerId`/`CreatedAt` (nada de `LastMatch` nem MemoryStore), `Studio = true`, e ninguém é mandado embora. Nessa partida, com o Studio usando os DataStores reais (`StudioLiveData = true`), o save do time e o `RunData` do perfil não são gravados nem apagados. No `Start`, o dono do grupo entra primeiro na ordem de entrada. Sem `StudioHandoff`, no Studio → `MapId = Config.Game.StudioMapId`, sem lista de membros (todos entram), host = primeiro jogador. Em servidor reservado (`game.PrivateServerId ~= ""` e `game.PrivateServerOwnerId == 0`) → lê `MemoryStoreService:GetHashMap(Config.Lobby.HandoffMapName):GetAsync(game.PrivateServerId)` (até 10 tentativas, 1 s entre elas). Sem handoff → usa `TeleportData.MapId` do primeiro jogador (valida que existe) e aceita todos. Servidor público do place de partida → manda todo mundo para o lobby (`TravelService.SendToLobby`). Depois: `ctx = MapBuilder.Build(MapId)`, cria pastas `workspace.Brainrots`, `workspace.Coins`, `workspace.Turrets`, e se `Handoff.Resume`, carrega `DataService.LoadRun("Run_"..host.."_"..MapId)` em `Team`. Publica `StateService.SetAll("Match", ...)`, `"TeamUpgrades"`, `"ShelfLevel"`, `"Recipes"`, `"Buffs"`, `"Completed" = false`.
- `Start()` — `PlayerAdded` (e jogadores já presentes): confere membro (senão `TravelService.SendToLobby({player})` com Notify e, se falhar, Kick) e limite de jogadores; espera o perfil; cria/restaura o `Run` (cache em memória se voltou; senão `profile.RunData[MapId]` se `Resume` e o `HostUserId` bate; senão novo e limpa `profile.RunData[MapId]`); grava `profile.LastMatch` com `AccessCode`/`PrivateServerId` do handoff; envia chaves de estado do jogador; `CharacterAdded` → partes no grupo `"Players"`, `Humanoid.WalkSpeed = Config.Game.WalkSpeed`, spawn no `ctx.SpawnLocation`. `PlayerRemoving` → salva o run dele no perfil (`RunData[MapId]`), mantém o run em memória. Autosave do time a cada `AutosaveInterval` (e grava `RunSaves[MapId]` no perfil do host se ele estiver presente). Loop de 1 Hz: `TeamList`. Na entrada, `AchievementService.FireEvent(player, "PlayWithFriends", {Count = nº de amigos na partida})`.
- `GetRun(player)`, `GetRunByUserId(userId)`, `GetTeam()`, `GetMapId()`, `GetMapDef()`, `GetContext()`, `GetHostUserId()`, `IsMember(userId)`, `GetPlayerCount()`.
- `MatchService.GetJoinOrder() -> {userId}` — cópia da ordem em que os jogadores aceitos entraram pela primeira vez (sem repetir; quem saiu continua na lista). O `ProgressionService` usa para escolher quem decide o portal quando o dono sai (o participante mais antigo presente, com run).
- `AddCoins(player, amount, source)` — `source` ∈ `"Pickup"`, `"Quest"`, `"Turret"`, `"Debug"`, `"Refund"`. Multiplica por `Formulas.PassCoinMult({DoubleCoins = HasPass(player, "DoubleCoins"), VIP = HasPass(player, "VIP"), Event = AdminService.GetEventEffects()})` (×2, ×1,25 ou ×2,5 dos passes, × 2 durante o evento `moedas2x`/`abuse`; exceto `"Refund"`/`"Debug"`). O evento global é lido pelo padrão de serviço opcional (`Services:FindFirstChild("AdminService")` uma vez, módulo em cache, `GetEventEffects` em `pcall`; faltando ou com erro = sem evento), nunca esperando o `AdminService`. Soma na carteira (ou `Team.SharedCoins` se `SharedWallet`), `IncrementStat(player, "TotalCoins", valor, true)` (quieto; exceto Refund/Debug; pulado se `DataService.IsReleased(player)`, a partida salva guarda as moedas), atualiza `IncomeEMA` (janela de ~10 s, mostrada no HUD) e `IncomeSlow` (janela de 120 s, usada no alvo e na recompensa das missões), manda `Coins`/`Income` e dispara `MatchService.CoinsAdded: Signal(player, amount, source)`.
- `SpendCoins(player, amount) -> boolean`, `GetCoins(player) -> number`.
- `SaveAll()` — também **renova o handoff** no MemoryStore: fora do Studio, em servidor reservado (`game.PrivateServerId ~= ""`) e no máximo a cada 600 s, grava de novo a mesma tabela lida no `Init` com `SetAsync(game.PrivateServerId, handoff, Config.Lobby.HandoffExpiration)` em `pcall` (falha só vira `warn`).
- `MatchService.GrantActRewards(player) -> boolean` — as recompensas do ato para um jogador, direto no perfil: `CompletedMaps[MapId] = true`, próximo mapa em `UnlockedMaps` (ou, no último ato, `GameCompleted = true` + skin de jogo concluído), `Tokens += MapDef.TokensReward`, limpa `RunData`/`RunSaves` desse mapa, `IncrementStat("ActsCompleted")`, `AchievementService.FireEvent(player, "CompleteMap", {Map = MapId})`. Uma vez só por jogador (conjunto `rewardedUserIds`); devolve `true` só quando deu agora (`false` se já recebeu, não tem run ou o perfil está liberado).
- `MatchService.FinalizeAct()` — encerra o ato neste servidor **só se pelo menos um jogador recebeu** a recompensa: `actCompleted = true` (o `SaveAll`/`syncRunToProfile` param de recolocar `RunSaves`/`RunData`) e apaga a partida salva do time (`DeleteRun`). Sem ninguém recompensado não faz nada (o autosave continua). Pode ser chamada várias vezes (o `DeleteRun` roda uma vez).
- `CompleteAct()` — para cada jogador presente: `CompletedMaps[MapId] = true`, `UnlockedMaps[Next] = true`, `Tokens += MapDef.TokensReward`, `Stats.ActsCompleted += 1`, `AchievementService.FireEvent(player, "CompleteMap", {Map = MapId})`, limpa `RunData[MapId]` e `RunSaves[MapId]` (tudo via `GrantActRewards`, pulando quem já recebeu); depois `FinalizeAct()` (a partida salva do time só é apagada se alguém recebeu; nunca com zero jogadores recompensados). Se o mapa tem `Next` → `TravelService.SendToNewMatch(jogadores, {MapId = Next, HostUserId = host atual, MaxPlayers = handoff ou 8, Privacy = handoff ou "Invite", Resume = false})`. Se não tem (Deserto) → marca `GameCompleted = true`, dá a skin `"Rainbow"` (se o jogador ainda não tem) e `TravelService.SendToLobby(jogadores)`.
- Request `ReturnToLobby` → salva o run do jogador e manda ele para o lobby.
- `MatchService.CoinsAdded: Signal`, `MatchService.RunReady: Signal(player, run)`.

### 8.3 `StatService`
- `StatService.Get(player) -> stats` (cache por jogador), `StatService.GetTeam() -> stats` (calculado com níveis vazios de jogador; usado para stats de time), `StatService.Invalidate(player?)` (nil = todos + time), `StatService.Changed: Signal(player?)`.
- Usa `Formulas.ComputeStats(MapId, run.Upgrades, Team.Upgrades, Team.Recipes, {DoubleCoins = HasPass(player, "DoubleCoins"), VIP = HasPass(player, "VIP"), DoubleDamage = HasPass(player, "DoubleDamage"), Event = AdminService.GetEventEffects()})`. `GetTeam()` usa `{Team = true, Event = AdminService.GetEventEffects()}` (nenhum pass mexe nos stats do time; o evento global mexe: sorte, encantamento e gigantes). O `AdminService` chama `Invalidate()` quando um evento começa ou acaba.
- Efeitos de ambiente quando o time muda: no Inverno, `Lighting.Atmosphere.Density = MapDef.AtmosphereDensity * MapDef.VisibilityFactor ^ teamStats.Visibility`.

### 8.4 `CoinService`
- `CoinService.SpawnCoins(totalValue, position, opts?)` — `opts = {AtPosition = true, Scatter = studs?}` solta em `position` mesmo com `DropMode == "Crate"` (chuva de moedas do admin). Divide o valor em peças (tier mais alto que caiba, até `MaxPiecesPerDeath`; a última peça leva o resto; acima do maior tier, a moeda do maior tier leva o valor inteiro), cria `Part` esféricas/cilíndricas na cor do tier em `workspace.Coins`, grupo `"Coins"`, atributo `"Value"`. Posição: se `DropMode == "Crate"`, perto de `ctx.CoinDropPoint` espalhado em `CrateScatter`; senão em `position`. Solta com velocidade para cima e aleatória para os lados; `SetNetworkOwner(nil)`. Depois de `SettleTime` s fica ancorada.
- Loop 10 Hz: expira moedas velhas (`DespawnTime`, exceto com coleta automática); coleta quando um personagem vivo está a `PickupRadius` (credita com `MatchService.AddCoins(player, value, "Pickup")` e `Net.FireClient(player, "CoinPopup", value, pos)`); ímã: moedas a menos de `teamStats.MagnetRadius` (ou `GamepassAutoCollectRadius` para quem tem o gamepass) de um jogador deslizam até ele a `MagnetPullSpeed`; coleta automática (`teamStats.AutoCollect >= 1`): depois de `AutoCollectDelay` s a moeda vai para o jogador vivo mais perto.
- Se passar de `MaxCoinsOnGround`, funde a moeda mais velha na moeda mais próxima dela (soma o valor e atualiza cor/tamanho pelo novo tier).
- `CoinService.CreditDirect(player, amount, position, source) -> number` — moedas direto na carteira, sem moeda no chão (ex.: abate de torreta): `local credited = MatchService.AddCoins(player, amount, source)`; se `credited > 0`, `CoinPopup` só para esse jogador em `position` (o mesmo "+moedas" da coleta). Devolve o valor creditado de verdade (com os bônus); `0` só se nada entrou (jogador sem run, fora do servidor, valor inválido ou erro). Perfil já liberado para teleporte (`DataService.IsReleased`) **não** devolve 0: as moedas entram no run (que vai no save do time) e só a estatística `TotalCoins` do perfil é pulada.

### 8.5 `BrainrotService`
Entidade:
```lua
{ Id, Def, Model, Position (Vector3, no chão), SizeFactor, TargetSize, StartSize, GrowStart, GrowDuration,
  HealthFrac = 1, MaxHealth, IceShield = 0, IceShieldMax = 0, IceBlock = Part?, Enchant = enchantDef?, Giant = boolean,
  SlowUntil = 0, SlowFactor = 1, BurnUntil = 0, BurnDps = 0, LastHitBy = Player?, SpawnTime, Dead = false, Billboard }
```
- `BrainrotService.SpawnWave(triggeredBy?, opts?) -> ok, msg` — `opts = {AllGiant = true?, IgnoreCooldown = true?}` (comando de admin `:giant`: todos gigantes, sem esperar a recarga; não gasta o buff `NextWaveGiant`). Respeita `Board.CooldownEnd` (`Config.Game.BoardCooldown × Formulas.EventBoardCooldownMult(evento global)`), `MaxBrainrotsAlive`; quantidade = `teamStats.SpawnCount`. Sorteio: peso do tier × (`Low` 1, `Medium` 1+TierLuck, `High` 1+2·TierLuck). Gigante com `GiantChance` (ou todos se `Buffs.NextWaveGiant`, que depois volta a false). Encantamento com `EnchantChance` (ou sempre, se `now < Buffs.TimedEnchantUntil`), escolhido por peso (com `MapOverrides`). Congelado com `MapDef.FrozenChance` (escudo = `FrozenShieldFraction` × vida máx). Posição aleatória dentro de `FieldArea`, longe de jogadores (`PlayerExclusionRadius`), de outros brainrots (`MinBrainrotSpacing`), fora da plataforma/oásis/cova (ver 7.5), até `SpawnAttempts` tentativas. Tamanho alvo = `GrowthMult × (Giant 3 ou 1) × enchant.SizeMult`; começa em 25% e cresce até 100% em `def.GrowTime / enchant.GrowthMult` s (ease-out). Efeito `"Spawn"`.
- Board: conecta `ctx.BoardPrompt.Triggered` → `SpawnWave(player)`; se estiver em recarga, `Notify` com o tempo.
- Loop 5 Hz: crescimento (`Model:ScaleTo(def.BaseScale * SizeFactor)` e `PivotTo` na posição; para não inundar a rede, só reescala quando o tamanho mudou 8% ou mais **e** passaram 0,5 s desde o último `ScaleTo` daquele brainrot; o tamanho final é sempre aplicado exato; `SizeFactor` continua contínuo para vida e moedas), `MaxHealth` recalculado mantendo `HealthFrac`, barra de vida, queimadura (`BurnDps`), atração (se `teamStats.AttractValuable >= 1`: `High` ou `Giant` andam até o jogador mais perto a `AttractSpeed × SlowFactor` até `AttractStopDistance`, sem sair da `FieldArea`; no Inverno a atração vem de `W_Attract`), cor dos arco-íris, respawn automático (`AutoRespawn >= 1` e vivos < `AutoRespawnThreshold × SpawnCount` e fora da recarga). `StateService.SetAll("Alive", n)`.
- `BrainrotService.GetEntity(id)`, `GetEntityFromPart(part)` (sobe até o Model com atributo `"BrainrotId"`), `GetAlive() -> {entity}`, `GetFolder()`.
- `BrainrotService.Damage(entity, amount, attacker?, info) -> dealt, killed` — `info = {Crit = boolean, Source = "Gun"|"Turret"|"Explosion"|"Burn"|"Splash", TurretOwnerUserId = number?}`. Enquanto o brainrot está lento (`SlowUntil > agora`), o dano é multiplicado por `BrainrotService.GetDamageMult(entity)` = `1 + (1 - SlowFactor) × Config.Game.SlowDamageBonus` (congelado fica frágil); o `CombatService` usa o mesmo multiplicador no `Damage` do `HitConfirm`. Escudo de gelo absorve primeiro (ao quebrar: remove o bloco e efeito `"IceBreak"`). Guarda `LastHitBy` quando `attacker` é Player.
- `BrainrotService.ApplySlow(entity, factor, duration)`, `BrainrotService.Ignite(entity, dps, duration)`.
- `BrainrotService.Kill(entity, killer?, info)` — valor = `Formulas.BrainrotCoinValue × Formulas.EnchantCoinMult × teamStats.CoinMult`. Se `info.Source == "Turret"`: com `Config.Game.TurretCoinSplit == "Team"` divide `valor × teamStats.TurretCoinMult` igualmente entre os jogadores com run (`AddCoins(p, parte, "Turret")`); com `"Owner"` (padrão), se o dono está no servidor: `MatchService.AddCoins(dono, valor × teamStats.TurretCoinMult, "Turret")`; senão (dono fora do servidor) `CoinService.SpawnCoins(valor × teamStats.TurretCoinMult, pos)`. Abate que não é de torreta: `CoinService.SpawnCoins(valor, pos)`. Os créditos diretos de torreta passam por `CoinService.CreditDirect(jogador, parte, centro, "Turret")` (mostra o "+moedas"); quando ele devolve 0 (jogador sem run ou que saiu do servidor), a parte cai no chão com `SpawnCoins` (as partes que falharam no mesmo abate são somadas numa chamada só). Explosão (chance `ExplodeChance`): dano `ExplosionDamageFraction × MaxHealth` nos vizinhos em `ExplosionBaseRadius + 3 × SizeFactor`, `Source = "Explosion"`, efeito `"Explosion"`, dispara `Exploded`. Encantamento Fogo: `Ignite` nos vizinhos em `IgniteRadius`. Receitas: `RecipeService.RollIngredient(killer, entity)` se o mapa tem receitas. Supremo: `SupremeService.OnKill(entity)` se o mapa tem supremo. Galáctico: `StateService.NotifyAll(..., "rare")`. Efeito `"Death"`. Stats do matador: `Kills.<Tier>`, `KillsTotal`, `Giants`, `Enchanted`, `Galactic`. Dispara `Killed`.
- Sinais: `BrainrotService.Killed: Signal(killer: Player?, entity, info)`, `BrainrotService.Exploded: Signal(player?)`, `BrainrotService.Spawned: Signal(entity)`.

### 8.6 `CombatService`
- `Net.OnEvent("Fire", ...)` com validação: personagem vivo; `origin` perto da cabeça: `8 + velocidade da cabeça × clamp(ping × 2, 0,1, 0,5)` studs, **nunca mais que 24**; `directions` é tabela com 1..`stats.Projectiles` Vector3 (normaliza; rejeita NaN/zero); **leque conferido** (com `n > 1` direções: `total = min(Spread × (n - 1), Stats.Fan.MaxDegrees)`, `passo = total / (n - 1)`, folga `Stats.Fan.ToleranceDegrees`; recusa o tiro se algum projétil está a mais de `total / 2 + folga` do centro do leque ou, quando `passo > folga`, se dois projéteis estão a menos de `passo - folga` um do outro; assim ninguém empilha todos os projéteis no mesmo alvo); cadência por token bucket (recarga `FireRate × 1.25`/s, capacidade 3; `FireRate` limitado por `Stats.Clamps.FireRate`); calor (se `HeatCapacity > 0`: `Heat += HeatPerShot`; se ≥ capacidade → `Overheated = true` até esfriar para 30%; tiros com `Overheated` são ignorados).
- **Encostados na origem:** uma vez por tiro, `workspace:GetPartBoundsInRadius(origin, raio, overlapParams)` (`OverlapParams` criado uma vez, `Include` = pasta dos brainrots) acha os brainrots que já encostam na esfera da bala (o `Spherecast` não enxerga o que já começa dentro dela: tiro à queima-roupa ou de dentro de um gigante). Em cada projétil eles são atingidos primeiro (mais perto primeiro, só os que ficam à frente: `direção · (centro - origem) > -raio`; se a origem está dentro da caixa de uma peça do brainrot, ele é atingido em qualquer direção), cada um gastando um dos alvos da perfuração.
- Depois, para cada direção: `workspace:Spherecast(origin, BulletHitRadius × Caliber, dir × Range, params)` com um `RaycastParams` por tiro (a lista de excluídos cresce com os brainrots já atingidos); até `1 + Pierce` alvos no total. O tiro para ao atingir algo que não é brainrot.
- Dano = `stats.Damage × (crítico ? CritMult : 1)`, crítico com `CritChance`. `SplashRadius > 0`: 50% do dano em outros brainrots no raio (`Source = "Splash"`). `SlowPower > 0`: `ApplySlow(entity, 1 - SlowPower, SlowDuration)`.
- Stats: `Shots` (+1 por evento), `Crits` — os dois com `IncrementStat(..., true)` (quietos). Sinal `CombatService.Crit: Signal(player, count)`.
- `HitConfirm` para o atirador, um por tiro (cada linha de acerto direto leva `Id` = `BrainrotId` do alvo; o dano de splash não gera linhas no `HitConfirm`); `RemoteShot` para os outros (com a cor do tracer da skin equipada), jogador por jogador: pula quem está a mais de 400 studs da origem e manda no máximo 1 `RemoteShot` de cada atirador a cada 0,1 s para cada jogador (a memória desse limite é limpa quando alguém sai).
- Calor esfria em `Heartbeat` a `HeatCooling`/s; `StateService.Set(player, "Heat", ...)` quando muda (no máximo 10 Hz).
- `CharacterAdded`: solda um modelo simples de arma na mão direita (cor da skin equipada, `Config.Cosmetics`), para os outros verem.

### 8.7 `UpgradeService`
- `BuyUpgrade(upgradeId, amount)`: upgrade existe e é do mapa atual; `def.Shelf <= Team.ShelfLevel`; stall existe no mapa; `amount` inteiro 1..1000 ou `"max"`; calcula custo com `Formulas`; `MatchService.SpendCoins`; soma níveis no escopo certo; `StatService.Invalidate`; envia `PlayerUpgrades` ou `TeamUpgrades`; compra de time → `NotifyAll("<Nome> comprou <Upgrade> (nv. N)")`; efeito `"Purchase"` na barraca; publica `ShelfReady`; `ProgressionService.CheckCompletion()`.
- `BuyShelf()`: só se `IsShelfMaxed(Team.ShelfLevel)` e `ShelfLevel < MaxShelf`; custo `Formulas.ShelfCost`; `ShelfLevel += 1`; `MapBuilder.SetShelfLevel(ctx, level)`; `SetAll("ShelfLevel")` e `PublishShelfReady()`; `NotifyAll`.
- `UpgradeService.PublishShelfReady()` — `StateService.SetAll("ShelfReady", IsShelfMaxed(Team.ShelfLevel))`, só quando o valor muda; chamado no `Start` (valor inicial), depois de `BuyUpgrade` e `BuyShelf`, em `MatchService.RunReady` e num laço de 1 s (pega saída de jogadores e comandos de teste como `maxall`/`reset`).
- `UpgradeService.IsShelfMaxed(shelf) -> boolean` — todos os upgrades do mapa com `Shelf <= shelf` estão no máximo: `Team` pelo nível do time; `Player` conforme `Config.Game.WeaponMaxRule` (`"AnyPlayer"`: algum run, inclusive de quem saiu, tem o nível máximo; `"AllPlayers"`: todos os jogadores presentes).
- `UpgradeService.IsActComplete()` — `ShelfLevel == MaxShelf` e `IsShelfMaxed(MaxShelf)`.
- `UpgradeService.GetLevel(player, def)`.

### 8.8 `ProgressionService`
- `CheckCompletion()` — se `IsActComplete()` e ainda não marcado: `SetAll("Completed", true)`; se o mapa tem `Next`, abre o portal (`MapBuilder.OpenPortal`), `NotifyAll("Portal para <Next> aberto!", "rare")`, efeito `"Portal"`, `SetAll("Portal", {...})`. No Deserto, só avisa que o foco agora é o Supremo.
- `CheckCompletion()` também roda quando um jogador sai (dentro do `task.defer` do `PlayerRemoving`, depois de tirar os votos dele): com `WeaponMaxRule = "AllPlayers"`, a saída do último jogador sem a arma maxada conclui o ato em vez de travar.
- Portal: `Config.Game.PortalDecision == "Host"` → só o host ativa (se ele saiu, o participante com run presente que entrou primeiro, pela `MatchService.GetJoinOrder()`; publicado em `Portal.Decider`, republicado em RunReady, PlayerAdded e PlayerRemoving; os outros recebem aviso); `"Majority"` → cada prompt/`VotePortal` registra voto; com votos ≥ `ceil(jogadores/2)` → `MatchService.CompleteAct()`. Votos de quem saiu são removidos.

### 8.9 `QuestService`
- `TakeQuest`: sem missão ativa e fora da espera; escolhe template aleatório cujos `Requires` o time atende (conferido com os stats do time **sem** o evento global, para um evento de admin não liberar uma missão impossível depois que acaba); calcula alvo e recompensa (5.10); `Quest` do jogador.
- Progresso: `BrainrotService.Killed` (Kill, KillTier, KillGiant, KillEnchanted — só se `killer == player`), `MatchService.CoinsAdded` (Collect, exceto sources `"Quest"`, `"Refund"` e `"Debug"`), `BrainrotService.Exploded` (Chain), `CombatService.Crit` (Crit). Ao completar: `AddCoins(..., "Quest")`, `IncrementStat("QuestsCompleted")`, Notify `"success"`, espera = `now + stats.QuestCooldown`.
- `AbandonQuest`: remove a missão e aplica metade da espera.

### 8.10 `TurretService` (só se `MapDef.HasTurrets`; senão Init/Start não fazem nada e os requests retornam `false, "Não há torretas neste mapa"`)
- Torreta: `{Id, OwnerUserId, Model, Position, RotY, Mode = "Valuable"|"Nearest", NextShot}`.
- `SetTurretMode`: só o dono da torreta ou o host (`false, "Essa torreta não é sua."` para os outros), como o `PickupTurret`.
- `PlaceTurret`: total < `floor(teamStats.TurretCount) + (dono tem ExtraTurret ? 1 : 0)`; posição dentro de alguma `TurretZone` (teste no espaço do objeto da parte, só X/Z), a ≤ 60 studs do jogador; ajusta Y com raycast para baixo; ≥ 5 studs de outras torretas. `TurretFactory.Build`, conecta os prompts do modelo (Recolher só o dono ou o host; Modo alterna).
- Loop 10 Hz: cada torreta pronta escolhe alvo vivo dentro de `TurretRange` (mais valioso = maior valor de moedas; ou mais perto), mira (`TurretFactory.AimHead`), acerta com chance `TurretAccuracy`, dano `TurretDamage` via `BrainrotService.Damage(entity, dmg, donoPlayerOuNil, {Source = "Turret", TurretOwnerUserId = ...})`, lentidão `TurretSlow`. Próximo tiro em `1 / TurretFireRate`. Tiros do tick vão juntos em `TurretShots` para todos.
- `RecallTurrets`: move todas para os `ctx.TurretBase`. `PickupTurret`, `SetTurretMode`.
- Persistência: `Team.Turrets` atualizado ao pôr/recolher/recall; no Start, recria as salvas. `SetAll("Turrets", {Placed, Max})` quando muda (Max recalculado quando stats mudam).

### 8.11 `RecipeService` (só Deserto)
- `RecipeService.RollIngredient(killer, entity)` — para cada ingrediente, chance `DropChance[tier] × teamStats.IngredientLuck`; no máximo 1 por morte; soma em `run.Ingredients`, envia `Ingredients`, efeito `"Ingredient"`.
- `Craft(ids)`: 1..3 strings válidas; monta o multiconjunto; procura receita com os mesmos ingredientes e contagens; se não houver → `false, "Nada aconteceu... essa combinação não é uma receita."` (não consome nada). Permanente já feita → `false, "Essa receita já está ativa nesta partida."`. Paga `CoinCost × CostScale`, consome ingredientes; aplica (`Permanent` → `Team.Recipes[id] = true`, `StatService.Invalidate()`, `SetAll("Recipes")`; `EnchantAll` → `Buffs.TimedEnchantUntil = now + Duration`; `NextWaveGiant` → `Buffs.NextWaveGiant = true`; `SupremeBoost` → `SupremeService.AddProgress(Amount)`); `SetAll("Buffs")`; `profile.RecipesKnown[id] = true` (se novo, `IncrementStat("RecipesDiscovered")`); `NotifyAll`.

### 8.12 `SupremeService` (só Deserto)
- Cria o Supremo (`BrainrotFactory.BuildSupreme(Brainrots.Supreme)`) em `ctx.Pit`; altura = `MinHeight + (MaxHeight - MinHeight) × Progress^1.5`; o modelo fica de frente para o oásis.
- Loop 1 Hz: `Progress += teamStats.SupremePassive`. `OnKill(entity)`: `Progress += teamStats.SupremeKill`. `AddProgress(x)`.
- `FeedSupreme(fraction)`: gasta `floor(coins × fraction)` (mínimo 1 moeda) e soma `gasto / (BaseFullCost × CostScale × (1 + 3 × Progress)) × teamStats.SupremeFeed`.
- Iluminação escurece com o progresso (`Brightness`, `OutdoorAmbient`, `ExposureCompensation`).
- `SetAll("Supreme", {Progress, Height})` quando muda (máx. 2 Hz). `Team.SupremeProgress` salvo.
- Ao chegar em 1: uma vez só → **antes** do `Ending`, `MatchService.GrantActRewards(p)` para cada jogador com run e, se alguém recebeu, `MatchService.FinalizeAct()` (quem sai durante os 30 s de créditos não perde nada); depois `Net.FireAll("Ending", {Names = nomes dos jogadores, Duration = 30, SupremeName})`, `NotifyAll`, e depois de `Duration` s → `MatchService.CompleteAct()` (que pula quem já recebeu; as novas tentativas não apagam nada de novo). Quem entra durante a cena final (`RunReady`) também recebe `GrantActRewards` (e, se recebeu, `FinalizeAct()`).

### 8.13 `AchievementService` (lobby e partida)
- Checa conquistas `Stat` em `DataService.StatChanged` e em `DataService.ProfileLoaded` (retroativo). `Stat` usa caminho com ponto (`"Kills.Low"`).
- `AchievementService.FireEvent(player, eventName, data)` — `CompleteMap` (`data.Map`), `PlayWithFriends` (`data.Count >= Count`).
- `AchievementService.Award(player, id)` — se ainda não tem: grava `os.time()`, soma `Tokens`, `BadgeService:AwardBadgeAsync` se `BadgeId > 0`, `Notify` `"rare"` ("Conquista desbloqueada: ...") com `extra = {Achievement = def.Id}` (vai no pacote como `Achievement`, seção 2.1), `SyncProfile`. Se `DataService.IsReleased(player)` (perfil liberado para teleporte), não dá nada: a checagem retroativa do próximo servidor dá. Vários avisos de conquista do mesmo jogador (ex.: várias retroativas juntas) saem espaçados 1,5 s com `task.delay`, nunca descartados.

### 8.14 `MonetizationService` (lobby e partida)
- Passes = `Util/Gamepasses` (`DoubleCoins`, `AutoCollect`, `ExtraTurret`, `VIP`, `DoubleDamage`). Só vale o que tem `Config.Game.Gamepasses.Enabled` e id > 0 (`Gamepasses.GetId`).
- Entrada: `UserOwnsGamePassAsync` (em `pcall`) para cada pass à venda, até 3 tentativas seguidas (1 s entre elas); o que falhar por erro na web é conferido de novo a cada 30 s (até 4 rodadas). `PromptGamePassPurchaseFinished` (`wasPurchased`) ativa na hora e mostra "Obrigado! Vantagem ativada: ...".
- Request `BuyGamepass(key)` (lista fechada; `Rate = 1, Burst = 3`): recusa chave desconhecida, loja desligada, pass sem id ou já comprado; confere `Gamepasses.FetchSaleInfo(key, 60)` e recusa com "Esta vantagem não está à venda no momento." se `IsForSale == false` (se o Roblox não responder, segue); senão `PromptGamePassPurchase` em `pcall`.
- `MonetizationService.HasPass(player, key) -> boolean`. Envia `Gamepasses` (seção 3.3) ao jogador quando muda.
- Efeitos: `DoubleCoins`/`VIP` → `MatchService.AddCoins` (`Formulas.PassCoinMult`); `DoubleDamage` → `StatService` (`Damage × 2` do dono, via `extras`); `AutoCollect` → `CoinService`; `ExtraTurret` → `TurretService`. Ao ganhar um pass na partida → `StatService.Invalidate(player)`.
- `VIP` (lobby e partida): `player:SetAttribute("VIP", true)` (replica; o `ChatTagController` põe `[VIP]` no chat) e um `BillboardGui` `"VipTag"` na `Head` (dourado, 58×22 px, `StudsOffsetWorldSpace = (0, 3.2, 0)`, `MaxDistance = 80`, `AlwaysOnTop = false`, `Active = false`), recriado a cada `CharacterAdded`. Na partida `PlayerToHideFrom = dono` (câmera em primeira pessoa).
- No lobby nada que dependa da partida roda (`workspace.Role ~= "Match"`: sem `StatService`).

### 8.15 `SettingsService` (lobby e partida)
- `SaveSettings(tbl)`: aceita pacotes **parciais** (só os campos que vieram mudam). Valida e limita cada campo (`NUMBER_RANGES`: `Sensitivity` 0.05–2, `FOV` 60–110, `MusicVolume`/`SfxVolume` 0–1, `CameraShake` 0–1, `EffectsQuality` 0–3 **arredondado para inteiro**, `UIScale` 0.85–1.25, `AmbientVolume` 0–1; `BOOLEAN_FIELDS`: `InvertY`, `ToggleSprint`, `DamageNumbers`, `ViewBob`, `AimAssist`, `AutoFire`; `Keybinds` = mapa `actionId → nome de Enum.KeyCode válido`, só actions de `Config.Keybinds`, e quando vem substitui o mapa inteiro); números só se finitos, booleanos só se boolean de verdade; campo desconhecido é ignorado; grava no perfil; `SyncProfile`. Recusa com "Seus dados ainda estão carregando..." se o perfil não carregou.

### 8.16 `TravelService`
- `TravelService.SendToNewMatch(players, handoff) -> ok, err` — primeiro confere o mapa (também no Studio): `handoff.MapId` tem de ser um id de `Config.Maps` com `Act` (nunca `"Lobby"`), senão `false` com mensagem. **No Studio** (não teleporta nunca):
  - papel atual `"Match"` → `false, MSG_STUDIO_NEXT_ACT` ("No Studio o próximo ato não abre no mesmo servidor. Pare o teste e dê Play de novo; no lobby use /unlockall e escolha o mapa.");
  - papel `"Lobby"` sem troca registrada (`StudioInPlaceMatch = false`) → `false, MSG_STUDIO_MATCH` (explica o `StudioInPlaceMatch` e o `StudioRole = "Match"`);
  - troca já agendada por outro grupo → `false` ("A partida de teste já está sendo preparada neste servidor. Aguarde.");
  - senão: monta um `studioHandoff` **novo** `{MapId, HostUserId, MaxPlayers, Privacy, Resume = handoff.Resume == true and DataService.UsesStudioStores(), Members = nil, CreatedAt = nil, AccessCode = nil, PrivateServerId = nil, Studio = true}`, agenda `task.defer(switchFn, studioHandoff)` e devolve `true`. Nada vai para o MemoryStore, o `LastMatch` não é gravado e nenhum perfil é liberado.

  Fora do Studio: `TeleportService:ReserveServerAsync(Config.Game.MatchPlaceId)` → `accessCode, privateServerId`; completa `handoff.AccessCode`, `handoff.PrivateServerId`, `handoff.Members = {userIds}`, `handoff.CreatedAt = os.time()`; grava no MemoryStore (`HandoffMapName`, chave `privateServerId`, expiração `HandoffExpiration`); para cada jogador grava `profile.LastMatch` e chama `DataService.ReleaseForTeleport`; `TeleportOptions` com `ReservedServerAccessCode` e `SetTeleportData({MapId = handoff.MapId})`; `TeleportService:TeleportAsync(MatchPlaceId, players, options)` com até `TeleportRetries` tentativas (espera 2 s, 4 s). Se falhar de vez → `DataService.Reacquire` em todos e retorna `false, mensagem`.
- `TravelService.SendToLobby(players)` — salva, libera e teleporta para `LobbyPlaceId` (no Studio: `Kick` com "Fim do teste no Studio: pare e dê Play de novo para voltar ao lobby."; a saída salva os dados normalmente). Fora do Studio devolve `false` com mensagem em português, sem teleportar, quando `LobbyPlaceId == game.PlaceId` (ou `0`) ou quando `LobbyPlaceId == MatchPlaceId`: teleportar para o próprio place seria um loop. Com `false`, o `MatchService` expulsa (Kick) quem ele estava mandando embora.
- `SendToNewMatch` também recusa (`false`, mensagem) quando `LobbyPlaceId == MatchPlaceId`. O handoff é gravado com `Config.Lobby.HandoffExpiration` (3 h) e renovado pela partida (seção 8.2).
- `TravelService.Reconnect(player) -> ok, err` — usa `profile.LastMatch` (dentro da janela) e teleporta com o `AccessCode` salvo. No Studio devolve `false` com uma mensagem explicando que lá não dá para reconectar (crie um grupo e clique em Iniciar).
- `TravelService.SetStudioMatchSwitch(fn)` (2.0) — **só no Studio**: o `Main` registra aqui a função que transforma o lobby de teste na partida (`switchToMatch`). Com ela registrada, `SendToNewMatch` no lobby do Studio chama `fn(studioHandoff)` com `task.defer` em vez de teleportar. `nil` desliga; valor que não é função é recusado com `warn`. Fora do Studio a chamada é ignorada com `warn`.
- `TeleportService.TeleportInitFailed` → tenta de novo aquele jogador até 3 vezes; depois `Reacquire` e Notify de erro.
- Tela de carregamento: o cliente chama `TeleportService:SetTeleportGui` (ver LobbyUI).

**Fluxo do Studio: lobby → partida no mesmo servidor (2.0).** O teleporte não funciona no Studio, então com `StudioRole = "Lobby"` e `StudioInPlaceMatch = true` (padrões) o servidor de teste vira a partida sozinho. Num jogo publicado nenhum destes passos existe (todo ramo novo é guardado por `RunService:IsStudio()`).
1. O jogador cria um grupo no lobby (terminal, portal `CreateParty:<MapId>` ou `QuickPlay:<MapId>`) e inicia. O `PartyService` termina a contagem e chama `TravelService.SendToNewMatch`, que agenda `switchToMatch(studioHandoff)` e devolve `true`.
2. `switchToMatch(handoff)` (no `Main`, uma vez só, protegido por `xpcall`):
   - a) `workspace:SetAttribute("StudioSwitchMap", handoff.MapId)` e `workspace:SetAttribute("StudioSwitching", true)` (o cliente mostra a tela de transição).
   - b) Prende (`Anchored = true`, em `pcall`) o `HumanoidRootPart` de todos os personagens, para ninguém cair enquanto o mapa troca.
   - c) `PartyService.Stop()` e `LobbyService.Stop()` (seções 9.1 e 9.2; erro vira `warn` e a troca continua).
   - d) `MatchService.StudioHandoff = handoff`; `callPhase("MatchService", "Init")` (o `MapBuilder` apaga o lobby, o terreno, as nuvens, o vento e a luz dele e monta o mapa). Se o Init falhar ou o mapa não for montado, a troca para com erro.
   - e) `runPhase(MATCH_SERVICES, "Init")` (o `MonetizationService` é pulado pelo `phaseDone`).
   - f) `PlaceRole.SetRuntimeRole("Match")` e `workspace:SetAttribute("Role", "Match")` (o cliente liga os módulos da partida).
   - g) `runPhase(MATCH_SERVICES, "Start")` e `callPhase("MatchService", "Start")` (ele trata os jogadores que já estão no servidor; o dono do grupo primeiro).
   - h) `player:LoadCharacterAsync()` para todos (em `pcall`): nascem no `SpawnLocation` da partida e a etiqueta VIP é refeita. Quem não renasceu tem o `HumanoidRootPart` solto de novo.
   - i) Apaga `StudioSwitching` e `StudioSwitchMap` (`nil`), dando certo ou não.

   Se algum passo der erro, o Output recebe um aviso bem visível e todos são expulsos com "O teste no Studio não conseguiu abrir a partida (veja o erro no Output). Pare o teste e dê Play de novo."
3. Dentro da partida de teste: `ReturnToLobby` (e o fim do jogo) expulsam com a mensagem de fim de teste (`SendToLobby`); concluir o ato dá as recompensas, mas o próximo ato não abre (`MSG_STUDIO_NEXT_ACT`). Para testar Inverno ou Deserto: `/unlockall` no lobby e escolher o mapa ao criar o grupo.
4. Dados: com Studio isolado (`DataService.UsesStudioStores()`, o normal) a partida de teste salva nas lojas `_Studio` como uma partida de verdade e o "Continuar partida salva" funciona; com `StudioLiveData = true`, o `Resume` fica desligado e a partida não grava nem apaga o save real do time.
5. `StudioRole = "Match"` continua abrindo direto a partida em `StudioMapId` (sem lobby, sem troca).

### 8.17 `DebugService`
- Ligado se `RunService:IsStudio()` ou `Config.Game.DebugMode == true`. O atributo `DebugMode` do `workspace` só seria lido no Studio (onde tudo já está ligado): num place publicado ele é **ignorado** (também no `Main`/`DebugEnabled`). Request `Debug(command, arg)` e também `player.Chatted` com `/comando arg`.
- **Trava de admin:** fora do Studio, `execute` só roda o comando se `AdminService.IsAdmin(player)` for `true` (em `pcall`, pelo padrão de serviço opcional), **mesmo com o `DebugMode` ligado**; os outros recebem a mensagem de comandos desligados. O `bypassGate` (usado por `RunCommand` com `adminCaller` admin) continua pulando a trava.
- Comandos: `coins <n>` (AddCoins "Debug"), `maxall` (maxa todos os upgrades do mapa e as prateleiras, depois `CheckCompletion`), `wave`, `nextact` (`CompleteAct`), `supreme <0..1>`, `ingredients` (5 de cada), `unlockall` (libera todos os mapas no perfil), `tokens <n>`, `reset` (zera o run do jogador).
- `DebugService.RunCommand(player, commandName, arg, adminCaller?) -> ok, msg` — roda um comando em `player`. Com `adminCaller` (o admin que pediu), confere `AdminService.IsAdmin(adminCaller)` e, se for admin, pula a trava do modo de teste (só o `AdminService` passa `adminCaller`). As regras "só na partida" continuam. `DebugService.ParseNumber(arg) -> number?` é o leitor de números dos comandos.

### 8.18 `AdminService` (lobby e partida)
- Cargo (`Config.Admins`, conferido só no servidor): `"Owner"` = `OwnerUserIds`, o criador (`game.CreatorType == User` e `game.CreatorId`) ou o dono do grupo (`GroupService:GetGroupInfoAsync(CreatorId).Owner.Id`, ou cargo 255) se `OwnerIsAdmin`; `"Admin"` = `UserIds`, cargo no grupo `>= GroupMinRank` (`GroupService:GetRolesInGroupAsync`, maior `Rank`) e, no Studio, todos se `StudioEveryoneAdmin`. Chamadas web em `pcall`; cache por UserId (refeito depois de 30 s se uma chamada falhou; apagado quando o jogador sai).
- `AdminService.GetRole(player) -> "Owner"|"Admin"|nil`, `AdminService.IsAdmin(player) -> boolean`, `AdminService.GetEventEffects() -> Effects?` (tabela do Config; só ler), `AdminService.EventChanged: Signal(effects?)`.
- Atributos do `Player` (só o servidor grava): `IsAdmin` (bool), `AdminRole` (`"Owner"`/`"Admin"`, só admins), `AdminFly` (bool, `:fly` alterna; o voo é física do cliente), `AdminWalkSpeed`/`AdminJumpPower` (número enquanto `:speed`/`:jump` estão fora do normal). O servidor aplica `Humanoid.WalkSpeed` (e `UseJumpPower = true` + `JumpPower`) direto e reaplica a cada `CharacterAdded`.
- Request `AdminCommand(name, args)` (`Rate = 2, Burst = 6`) e chat com `Config.Admins.ChatPrefix` (um `TextChatCommand` por comando, `PrimaryAlias = ":" .. nome`, `AutocompleteVisible = false`, pasta `TextChatService.AdminCommands`, + `Player.Chatted`, com filtro de repetição de 1 s; quem não é admin é ignorado em silêncio). Em todo pedido: confere o cargo de novo, valida `name` (texto) e `args` (lista 1..n de até 8 textos), limite próprio de 1 comando/s (rajada 5, vale para chat e painel), `Scope == "Match"` fora da partida → `"O comando :x só funciona dentro de uma partida (você está no lobby)."`, lê os argumentos pelo `Config.Admins.Commands` e escreve `[Admin] Nome (UserId, cargo) via chat|painel: :cmd args -> ok|falhou: mensagem` no Output.
- `coins`, `wave`, `maxall`, `nextact`, `supreme`, `ingredients`, `tokens`, `unlockall` usam `DebugService.RunCommand(alvo, ..., admin)` (moedas com source `"Debug"`); quem recebe (se não é o admin) ganha um `Notify`. `giant` → `BrainrotService.SpawnWave(admin, {AllGiant = true, IgnoreCooldown = true})`. `coinrain [n]` → `CoinService.SpawnCoins(n / CoinRainPiles, pos, {AtPosition = true})` em `CoinRainPiles` montinhos a 10 studs de cada jogador vivo (sem `n`: `CoinRainDefault × CostScale` por jogador; `n` até 1e9, porque essas moedas são pegas do chão e contam em `TotalCoins`/placar).
- `tp`/`bring` movem o personagem com `PivotTo` (`tp` só 1 jogador); `respawn` → `Player:LoadCharacterAsync()` em `pcall`.
- `announce <texto>` (até `AnnounceMaxLength` letras, 1 a cada 10 s por admin): `TextService:FilterStringAsync(texto, admin.UserId, PublicChat)` + `GetNonChatStringForBroadcastAsync()` em `pcall` (falhou → recusa). Mostra aqui (`Net.FireAll("Announcement", {Text, From = DisplayName, Duration = AnnounceDuration})`) e publica `MessagingService:PublishAsync("BrainrotAdmin", {Kind = "Announce", Id, Text, From, Duration})`; cada servidor que recebe dispara o mesmo `Announcement` (ids já vistos são ignorados).
- `event <evento> <minutos>`: grava `{Key, EndsAt = os.time() + s, StartedBy, Id}` no `MemoryStoreService:GetHashMap("BrainrotAdminEvent_v1")`, chave `"Current"`, expiração = duração; liga aqui; publica `{Kind = "Event", Id, Event = {..., Stored}}`. `endevent`: `RemoveAsync("Current")`, desliga aqui, publica `{Kind = "EventEnd", Id, EventId}` (se o `RemoveAsync` falhar, responde com erro: o evento salvo voltaria na próxima leitura, então o admin precisa repetir). Todo servidor lê `"Current"` no `Start` e a cada 60 s (mensagens podem se perder), liga/desliga ao receber mensagens, publica `GlobalEvent` (convertendo `EndsAt` para `GetServerTimeNow`), confere a cada 1 s se acabou (então `GlobalEvent = nil` e `NotifyAll`) e, na partida, chama `StatService.Invalidate()` quando muda. Evento recebido que dura mais que `MaxMinutes` (+2 min de folga) é ignorado. Efeitos: seção 5.15 (moedas no `AddCoins`, sorte/gigantes no `ComputeStats`, recarga no `SpawnWave`).
- `kick <jogador> [motivo]`: `player:Kick(mensagem)` com "Você foi expulso do servidor por um administrador." + o motivo filtrado para o alvo (`FilterStringAsync` + `GetNonChatStringForUserAsync`, em `pcall`; se o filtro falhar, sai sem o motivo). `ban <jogador> <duração> [motivo]`: jogador do servidor ou UserId de quem não está; `Players:BanAsync({UserIds = {id}, ApplyToUniverse = true, Duration = segundos ou -1, DisplayReason = texto em português + motivo (≤ 400), PrivateReason = "Banido por <admin> (UserId) ..." (≤ 1000), ExcludeAltAccounts = false, ApplyDeviceBlock = false})` em `pcall`; se o alvo está neste servidor, `Kick` na hora (mesmo se o ban falhar). `unban <userId>`: `Players:UnbanAsync({UserIds = {id}, ApplyToUniverse = true})` em `pcall`. Admins e o dono nunca podem ser expulsos nem banidos (conferido também para quem está fora do servidor; se o cargo não pôde ser conferido por erro na web, recusa); `all`/`others` são recusados em `kick`/`ban`, e em `tokens` com número negativo. Quem não é admin e usa o `AdminCommand` gera um único `warn` por jogador (nome cortado, sem quebras de linha); o registro `[Admin]` também troca caracteres de controle por espaço. O ban precisa de `Players.BanningEnabled` ligado; o `default.project.json` já liga (o código não consegue mudar essa propriedade).
- `cmds`: a lista dos comandos que valem no lugar atual (lobby ou partida), por categoria.

---

## 9. Lobby

### 9.1 `LobbyService`
- `Init`: `ctx = MapBuilder.Build("Lobby")`; placar: `OrderedDataStore` `Config.Lobby.LeaderboardStoreName`, pontuação `floor(log10(TotalCoins + 1) * 1e6)` (moedas podem passar de 2^63); grava na entrada, ao sair e a cada `LeaderboardRefresh`; lê o top `LeaderboardSize` e escreve no `SurfaceGui` (nome + moedas `Abbrev(10^(score/1e6) - 1)`), com cache de nomes. Há mais dois placares com valor inteiro direto: `LeaderboardStoreName .. "_Kills"` (`Stats.KillsTotal`, painel `ctx.Leaderboards.Kills`) e `LeaderboardStoreName .. "_Acts"` (`Stats.ActsCompleted`, painel `ctx.Leaderboards.Acts`).
- **Studio:** com `DataService.UsesStudioStores()` (Studio sem `StudioLiveData`), o placar guarda os valores só em memória e **nunca** chama `SetAsync`/`UpdateAsync` no `OrderedDataStore` (testes não aparecem no placar público).
- Leitura: um placar por vez, em rodízio, com pelo menos 20 s entre dois `GetSortedAsync` do servidor (`MIN_READ_SPACING`). Ao sair, depois da última gravação, o jogador sai das memórias dos placares (a não ser que esteja no top mostrado); o cache de nomes guarda só quem aparece nos placares e quem está online.
- Request `Reconnect` → `TravelService.Reconnect`.
- `LobbyService.Stop()` (2.0) — desliga o lobby neste servidor. Usado só pela troca lobby → partida do Studio (seção 8.16), **antes** de o `MapBuilder` apagar o mapa do lobby. Para o laço de rodízio do placar (`refreshLoop`) e os outros laços, derruba as conexões do serviço (entrada/saída de jogadores, perfil carregado; tudo no Trove do serviço), esquece o `ctx` do lobby (nenhum placar é desenhado em peças que vão sumir; uma leitura que estava esperando a web sai sem desenhar) e o Request `Reconnect` passa a responder `false, "O lobby foi fechado."`. Idempotente (da segunda chamada em diante não faz nada).

### 9.2 `PartyService`
Grupo: `{Id, HostUserId, MapId, MaxPlayers, Privacy, Resume, Members = {userId} (ordem de entrada), Ready = {[userId] = true}, Invited = {[userId] = true}, State = "Waiting"|"Countdown"|"Teleporting", CountdownEnd}`.
- Regras: um jogador em no máximo um grupo; mapa precisa estar em `UnlockedMaps` do host; `Resume` só se o host tem `RunSaves[MapId]`; `MaxPlayers` entre `MinMaxPlayers` e `MaxPlayersLimit` e ≥ membros atuais; visibilidade/entrada: `Public` todos, `Friends` só amigos do host (`player:IsFriendsWith(hostUserId)` com cache), `Invite` só convidados; quem foi expulso (`PartyKick`) fica em `party.Kicked` e não entra de novo em nenhum modo (nem pelo convite do Roblox) até o host convidar de novo; o host sai → liderança para o membro mais antigo; grupo vazio some.
- `PartyStart(force)`: só host; todos prontos (o host conta como pronto) ou `force`; contagem de `CountdownSeconds` (cancela se alguém sai, desmarca pronto ou o host cancela); no fim → `TravelService.SendToNewMatch(jogadores, {MapId, HostUserId, MaxPlayers, Privacy, Resume})`; se falhar → volta a `"Waiting"` e Notify do erro.
- `PartyInvite(userId)`: host convida alguém do servidor → `Invited`, Notify para o convidado com o nome do host. Convidar de novo quem já está convidado devolve `true` sem outro aviso; o mesmo host só avisa o mesmo jogador a cada 30 s.
- Amizade (`Friends`) com `player:IsFriendsWithAsync(userId)` em `pcall`, com cache. Convite do Roblox (`LaunchData`/`ReferredByPlayerId`): só entra no grupo quem foi chamado pelo host ou por um membro daquele grupo.
- Limites de pedidos: `PartyReady` usa `{Rate = 1, Burst = 3}`. `PartyReady`, `PartySetMaxPlayers` e `PartySetResume` devolvem `true` sem mandar nada quando o valor não mudou.
- `PartyService.Stop()` (2.0) — fecha os grupos neste servidor. Usado só pela troca lobby → partida do Studio (seção 8.16). Marca `stopped = true`; cancela a contagem regressiva e o vigia de teleporte de cada grupo (o Trove de cada grupo cancela as threads agendadas e um token novo invalida as que já rodam); apaga grupos, convites e caches **sem** mandar `PartyState` (a interface do lobby some junto); limpa o Trove do serviço (conexões de entrada/saída de jogadores). Daí em diante todo Request de grupo (`PartyCreate`, `PartyJoin`, `PartyStart`...) responde `false, "O lobby foi fechado."` (o `Net` não tem como desregistrar uma action, então a trava fica no handler). Idempotente.
- Após qualquer mudança real: envia `PartyState` a cada jogador do lobby (só quem teria um pacote diferente do último que recebeu: o servidor guarda um resumo JSON do último envio por jogador e pula o `FireClient` se for igual):
```lua
PartyStatePayload = {
  MyParty = PartyView?,          -- grupo do jogador, se tiver
  Parties = { PartyView },       -- grupos visíveis para ele (Public; Friends se amigo do host; Invite se convidado)
  Invites = { partyId },         -- convites pendentes
}
PartyView = { Id, HostUserId, HostName, MapId, MaxPlayers, Privacy, Resume, State, CountdownEnd,
              Members = { { UserId, Name, DisplayName, Ready } }, CanJoin = boolean, JoinBlockReason = string? }
```

### 9.3 `ShopService`
- `BuyCosmetic(id)`: existe, não tem, `Tokens >= Price` → desconta e adiciona. `EquipCosmetic(id)`: precisa ter. `SyncProfile`.

---

## 10. Cliente

### 10.1 `Main.client.lua`
Espera `workspace:GetAttribute("Role")` (usa `GetAttributeChangedSignal` se ainda não existe). Carrega e chama `Init()` e depois `Start()` (cada um em `pcall` com `warn`) na ordem:
- Sempre (`ALWAYS`): `StateController`, `NotifyController`, `UI/UIKit` (se tiver Init), `PromptController`, `MobileController`, `MusicController`, `AmbientController` (2.0; **opcional**: se o arquivo faltar, espera pouco, avisa uma vez e segue), `MovementController`, `ChatTagController`, `FlyController`, `AnnouncementController`, `UI/SettingsWindow`, `UI/DebugPanel`, `UI/AdminPanel`.
- Partida (`MATCH_ONLY`): `CameraController`, `EffectsController`, `WeaponController`, `PlacementController`, `HUDController`, `UI/StallWindow`, `UI/CauldronWindow`, `UI/SupremeWindow`, `EndingController`.
- Lobby (`LOBBY_ONLY`): `UI/LobbyUI`.

**`bootList(list)` (2.0):** a partida do boot fica numa função: carrega todos os módulos da lista (`loadModule`, que tolera módulo opcional faltando), depois `Init` de todos na ordem e por fim `Start` de todos na ordem (`runLifecycle`, com os mesmos tempos máximos: require 15 s, Init 15 s — `StateController` 45 s —, Start 10 s). Um módulo nunca liga duas vezes (tabela dos já ligados). O primeiro boot é `bootList(ALWAYS + MATCH_ONLY)` ou `bootList(ALWAYS + LOBBY_ONLY)`, numa lista só (todos os Init antes de todos os Start, como sempre).

**Troca de papel (Studio, seção 8.16):** depois do primeiro boot com o papel `"Lobby"`, o script ouve `workspace:GetAttributeChangedSignal("Role")` (e confere uma vez logo em seguida, caso o papel tenha mudado durante o boot). Quando o `Role` vira `"Match"` (uma vez só): `bootList(MATCH_ONLY)` e **só depois** `pcall(LobbyUI.Shutdown)` — a tela de transição do lobby fica por cima enquanto o HUD da partida liga. `"Match"` → `"Lobby"` é ignorado (o servidor expulsa no fim do teste). Módulos que dependem do papel leem o atributo `Role` ao vivo (`MovementController`, `MobileController`, `MusicController`, `DebugPanel`, `SettingsWindow`).

### 10.2 `UI/UIKit.lua`
**UIKit v2 (2.0):** tudo é acrescentado no lugar; toda chave antiga do `Theme` e toda função antiga continuam existindo com a mesma assinatura (mais de 20 arquivos usam `UIKit.Theme`, `Button`, `Label`, `Window`, `ProgressBar` e `PlaySound`).

**Tokens do `UIKit.Theme`:**
- Paleta (seção 3.8 do plano): `Bg (18,12,34)`, `Surface (29,21,53)`, `SurfaceRaised (40,29,72)`, `SurfaceHover (51,38,91)`, `SurfaceSunken (12,8,23)`, `Backdrop (6,3,12)` com `BackdropTransparency 0.4`, `Accent (255,84,178)` e `Accent2 (146,94,255)` (só em botões principais, foco e faixinhas de destaque; nunca num cabeçalho inteiro), `Text (255,255,255)`, `TextDim (201,191,227)`, `TextMuted (142,132,173)`, `TextDark (28,18,48)`, `Success (63,210,122)` ("pode comprar"), `Danger (240,72,90)` ("sem moedas"), `Warning (255,181,46)`, `Info (74,168,255)`, `Coin (255,204,51)`, `CoinDeep (199,133,26)`, `Rare (255,216,74)`, `Stroke (7,4,14)`, `Disabled`, `Highlight`/`HighlightTransparency` (brilho de 1 px no topo dos painéis). As chaves antigas viram valores derivados: `Background = Bg`, `Panel = Surface`, `PanelLight = SurfaceRaised`, `PanelDark = SurfaceSunken`, `Corner = CornerRadius = Radius.M`, `TextSize`, `TitleSize`, `SmallTextSize`, `Kinds`, `Fonts` e os apelidos (`Green`, `Red`, `Gold`...). Chave que não existe devolve um valor razoável e avisa uma vez (nunca `nil`).
- Fontes: `Theme.TitleFont`/`ButtonFont = FredokaOne`, `Theme.Font = Enum.Font.BuilderSansBold` (fonte local, muito legível), `Theme.NumberFont = BuilderSansExtraBold`.
- `Theme.Type` (aplicado por `UIKit.TextStyle`): `Display` FredokaOne 36, `Title` FredokaOne 26, `Heading` FredokaOne 20, `Button` FredokaOne 20, `Body` BuilderSansMedium 16, `BodyStrong` BuilderSansBold 16, `Caption` BuilderSansMedium 13, `Number` BuilderSansExtraBold 18. No celular `Body`/`BodyStrong`/`Caption` ganham +2; o "Tamanho do texto" do Roblox (`GuiService.PreferredTextSize`: Medium/Large/Larger/Largest) soma +0/+2/+4/+6; nunca abaixo de 12 pt na tela.
- `Theme.Space`: `XS 4`, `S 8`, `M 12`, `L 16`, `XL 24`, `XXL 32` (+ `ButtonX 12`, `ButtonY 6`, `Card 12`, `Window 16`, `Hud 16`, `HudPhone 12` + área segura).
- `Theme.Radius`: `S 6`, `M 10` (botões), `L 14` (cartões), `XL 18` (janelas), `Pill = UDim.new(1, 0)` (valores `UDim`).
- `Theme.Elevation`: `[1]`/`E1` = uma camada preta (deslocamento (0,3), transparência 0.7); `[2]`/`E2` = duas ((0,6) a 0.72 e (0,14) a 0.88). Sem texturas.
- `Theme.Motion`: `Press 0.08`, `Hover 0.14`, `Base 0.18`, `Enter 0.24` (Back Out), `Exit 0.14` (Quad In), `Pop 0.3` (Back), `Roll 0.6` (máximo de um número "correndo"). Com "menos movimento" (`UIKit.IsReducedMotion()`), escala e deslize viram instantâneos e só os "fades" ficam.
- `Theme.Rarity`: montada ao carregar, a partir de `Config.Brainrots.Tiers[x].Color` (`Low`, `Medium`, `High`) e das cores de `Config.Enchants.List` (por `Id`), mais `Supreme = Theme.Rare`.

**Funções:**
- `UIKit.New(className, props, children?) -> Instance`.
- `UIKit.GetScreen(name, displayOrder?, insets?) -> ScreenGui` (cria em `PlayerGui`, `ResetOnSpawn = false`, com `UIScale` automático). 2.0: o padrão é `ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets` com `IgnoreGuiInset` deixado em `false` (não ligue `IgnoreGuiInset`: ele troca o `ScreenInsets` para `DeviceSafeInsets` e a tela volta a ficar embaixo da barra do Roblox e do "notch"). Nesse padrão o conteúdo já fica abaixo da barra, então quem usa a tela padrão **não** soma `GuiService:GetGuiInset()`. `insets` troca o padrão (ex.: `None` para um fundo de tela cheia). Telas que fazem a própria conta com `GetGuiInset` ou ficam de propósito dentro da faixa da barra usam `DeviceSafeInsets` (o comportamento antigo): o `HUD` pede isso no `GetScreen` (a mira fica no centro real da tela, onde o tiro vai, e `layoutTop` desconta a barra), e o UIKit aplica isso sozinho às telas `TopBanners` (AnnouncementController), `Notifications` (NotifyController, que recebe o `SetTopOffset` medido na `TopBanners`), `AdminButton` e `DebugButton` (tabela `LEGACY_SCREEN_INSETS`; o argumento `insets` vale por cima dela).
- `UIKit.Window(name, title, size: UDim2) -> window` — `{Gui, Frame, Content (ScrollingFrame ou Frame), Open(), Close(), IsOpen(), OnClose: Signal}`; botão X; tecla Esc/B do controle fecha. Abrir chama `OpenModal(name)`, fechar `CloseModal(name)`. **v2:** cabeçalho limpo com uma faixinha de destaque (os filhos `Header`/`HeaderFill` continuam com esses nomes: a `StallWindow` e o `AdminPanel` leem), `SetAccent(color)` (cor da faixinha; `nil` = padrão), `HeaderHeight` (altura do cabeçalho em px), `SetFooter(frame)` (rodapé fixo fora da rolagem; `nil` tira), também `Toggle()`, `SetTitle(texto)`, `Destroy()`, `OnOpen: Signal`, `IsSheet()`; animação de abrir/fechar com `Theme.Motion`; um `BlurEffect` (tamanho 12, criado pelo cliente no `Lighting`) atrás enquanto uma janela está aberta; no celular (`Phone`) janelas grandes viram **folha de tela cheia** dentro da área segura.
- `UIKit.Button(props, onClick) -> TextButton` — `props: {Text, Color, Size, Position, LayoutOrder, Parent}` como antes (com `UICorner`, `UIStroke`, animação de clique, som) e, na v2, `Variant = "Primary"|"Secondary"|"Ghost"|"Danger"` (estilo pronto), `Loading = true` (girador, ignora cliques; depois `button:SetAttribute("Loading", bool)`), `Disabled`, `Sound` (vaga de som; `false` = mudo), `Selected`/`SelectedColor` (abas). Estados: normal, mouse em cima, apertado, desativado, carregando; no toque usa `PressHapticEffect` quando existe (em `pcall`). Área de toque de pelo menos 44 px reais.
- `UIKit.Label(props)`, `UIKit.Corner(inst, radius)`, `UIKit.Stroke(inst, thickness, color)`, `UIKit.Padding(inst, px)`, `UIKit.List(parent, padding, direction)`, `UIKit.Grid(parent, cellSize, padding)`, `UIKit.Tween(inst, props, time?)`, `UIKit.Pop(inst)` (efeito de "pulo").
- `UIKit.ProgressBar(parent, props) -> {Frame, Set(fraction, text?)}` (+ `Fill`, `Label`, `SetColor(cor)`); **v2:** `props.Style = "Default"|"Coin"|"Tier"|"Thin"`.
- `UIKit.TextStyle(label, styleName, over3D?) -> label` — aplica um estilo de `Theme.Type` (fonte e tamanho com as regras acima; refeito quando o layout muda). `over3D = true` põe contorno escuro (só texto em cima do mundo 3D).
- `UIKit.Shadow(frame, level) -> {Frames, SetEnabled(bool), Destroy()}?` — sombra de nível 1 ou 2 (`Theme.Elevation`) atrás de um frame solto (não dentro de listas); no máximo **12 frames de sombra** na tela (acima disso devolve `nil`).
- `UIKit.Panel(props) -> Frame` — cartão/painel: `Color`, `Transparency`, `Glass = true` (vidro do HUD: `Bg` a 0.22 + gradiente + brilho de 1 px), `Radius`, `Padding`, `Stroke`, `Highlight`, `Elevation`, `List`.
- `UIKit.Chip(props) -> Frame|TextButton` — etiqueta em pílula (`Text`, `Color`, `Filled`, `Icon`, `OnClick`...).
- `UIKit.IconButton(props, onClick) -> TextButton` — botão quadrado com ícone (`Icon` imagem ou `Text` símbolo, `Size` padrão 44, `Variant`, `Tooltip`, `Badge`).
- `UIKit.Tabs(parent, tabs, onSelect) -> {Select(id), Selected, Frame, Buttons}` — barra de abas; `tabs = {{Id, Text}}` ou lista de textos; `Select(id, true)` troca sem chamar `onSelect`.
- `UIKit.Tooltip(target, text) -> {SetText, Destroy}?` — dica depois de 0,4 s com o mouse em cima, com o controle selecionando ou segurando o dedo.
- `UIKit.Banner(props) -> {Frame, Level, Dismiss(), IsShowing(), Dismissed: Signal}` — faixa de comemoração (escada de momentos, seção 3.10 do plano): `Title`, `Subtitle`, `Color`, `Level = 3` (faixa central ~3 s) ou `4` (épica, lado a lado, ~7 s), `Duration` (0 = só com `Dismiss`), `Sound`. Aparece na hora; a **fila** é de quem chama (espera `Dismissed` para mostrar a próxima).
- Modais: `UIKit.OpenModal(name)`, `UIKit.CloseModal(name)`, `UIKit.IsAnyModalOpen()`, `UIKit.ModalChanged: Signal(isAnyOpen)`, `UIKit.CloseAllWindows()`. Abrir uma janela fecha as outras janelas (só uma aberta por vez).
- Extras: `UIKit.GetScale()`, `UIKit.Darken(cor, t)`, `UIKit.Lighten(cor, t)`.

**Layout e acessibilidade:**
- `UIKit.GetLayout() -> {Class, Scale, SafeInsets, TopbarHeight, IsTouch}` (+ `TextOffset`, `ReducedMotion`) — `Class`: `"Phone"` (toque e lado curto < 500 px), `"Tablet"` (outro toque), `"Desktop"` (teclado e mouse) ou `"Console"` (controle; pelo `UserInputService.PreferredInput`); `Scale` = `GetScale()`; `SafeInsets = {Top, Left, Right, Bottom}` em px; `TopbarHeight` de `GuiService.TopbarInset`; `IsTouch`.
- `UIKit.LayoutChanged: Signal(layout)` — quando algo do layout muda (tipo de tela, escala, área segura, barra do Roblox, tamanho do texto ou "menos movimento"); não dispara para o valor inicial.
- `UIKit.IsReducedMotion() -> boolean` — `GuiService.ReducedMotionEnabled` (lido em `pcall`).
- No `Init`: `PlayerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor` (celular sempre deitado). No celular a escala segue a altura da tela, texto de corpo nunca fica abaixo de 12 pt reais e botões de toque têm pelo menos 44 px reais.

**Áudio (seções 5.1 e 5.16):**
- `UIKit.ResolveSound(key) -> (soundId: string?, volume: number, speed: number, group: string)` — resolve uma vaga na ordem: `Config.Game.Sounds[key]` / `Config.Game.Music[X]` para `"Music_X"` (**> 0** id fixo, **-1** mudo → `soundId = nil`, **0** automático) → `Config.Audio.Pinned[key]` → atributo `"Slot_" .. key` de `ReplicatedStorage.AudioLibrary` (se a pasta existir; id em `Blocked` é ignorado) → `Config.Audio.Slots[key].Fallback` → `nil` (silêncio). Também aceita um número (id) ou um texto `"rbxassetid://..."`. Sem cache: quando a biblioteca muda, o próximo som já usa o novo.
- `UIKit.PlaySound(key, opts?) -> Sound?` — mesma assinatura de antes; usa o `ResolveSound` e toca no `SoundGroup` da vaga. Mudo, sem áudio ou grupo com volume 0 = não toca (devolve `nil`). `opts` (2.0): `Volume` (multiplicador), `Pitch`/`PlaybackSpeed` (tom exato; senão o da vaga com ±5% quando repete), `Position: Vector3?` (som **3D** naquele ponto, num `Attachment` de uma peça invisível só do cliente; `MinDistance`/`MaxDistance` padrão 8 e 150), `Group` (troca o grupo). Sons reaproveitados (pool): no máximo **4 vozes por vaga** e **24 sons ao mesmo tempo**. O clique padrão da interface (`Click`) sai do som embutido `rbxasset://sounds/volume_slider.ogg` (volume 0.35, tom 1.1) quando nada foi configurado. Os volumes das Configurações são lidos uma vez por mudança do `Profile` (não a cada som).
- `UIKit.GetSoundGroup(name) -> SoundGroup` — `"Master"`, `"Music"`, `"SFX"`, `"UI"`, `"Ambient"` (nome desconhecido = `"SFX"` com aviso), criados pelo cliente dentro do `SoundService`, com volumes que seguem as Configurações na hora: `Music` = 0,5 × `MusicVolume`, `SFX` = 0,7 × `SfxVolume`, `UI` = 0,6 × `SfxVolume`, `Ambient` = 0,6 × `AmbientVolume` (todos dentro do `Master`).

### 10.3 Controllers
- `NotifyController`: `Net.On("Notify")` → toasts empilhados no topo (cor por Kind, "rare" com brilho e som). `NotifyController.Show(text, kind, duration)`. `NotifyController.SetTopOffset(px?)` desce a pilha para baixo das faixas do `AnnouncementController` (`nil` volta ao lugar normal).
- `PromptController`: `ProximityPromptService.PromptTriggered` → se o prompt tem `ClientAction`, `PromptController.Dispatch(action, arg)` (`"Ação:Argumento"` é cortado no primeiro `:`). `PromptController.Register(action, fn(arg, prompt)) -> conexão` (com `Disconnect()`; o `LobbyUI.Shutdown` usa para desfazer os registros). Também trata `Net.On("OpenUI")`. Aplica a tecla `Interact` (keybind) nos prompts do jogo. **2.0:** acha os prompts pela tag `GamePrompt` (`CollectionService:GetTagged` + `GetInstanceAddedSignal`/`GetInstanceRemovedSignal`; seção 7.3) e "adota" um prompt sem a tag na primeira vez que ele aparece na tela (`ProximityPromptService.PromptShown`); não vasculha mais o `workspace.DescendantAdded` (pesava ao montar um mapa). Esconde o prompt padrão enquanto uma janela está aberta (`PromptController.SetHidden(reason, hidden)`).
- `CameraController` (partida): câmera de primeira pessoa própria: `CameraType = Scriptable`, `MouseBehavior = LockCenter`, `UserInputService:GetMouseDelta()`, sensibilidade e Inverter Y das configurações, `FieldOfView` das configurações, pitch limitado a ±80°. Gira o personagem no yaw (`Humanoid.AutoRotate = false`). Controle: `Thumbstick2`. Toque: arrastar na metade direita da tela (toques que não começaram em GUI). Esconde o próprio corpo (`LocalTransparencyModifier = 1`). Quando `UIKit.IsAnyModalOpen()` → solta o mouse (`MouseBehavior = Default`, ícone visível) e para de girar. `CameraController.GetAimCFrame() -> CFrame`, `CameraController.SetEnabled(bool)` (usado no final). Balanço leve ao andar e "coice" com `CameraController.Kick(amount)`.
- `MovementController`: correr (segurar ou alternar, keybind `Sprint`, botão no celular) com `Config.Game.WalkSpeed/SprintSpeed`; se o jogador mudou teclas de movimento (Forward/Back/Left/Right/Jump), desliga os controles padrão de teclado (`PlayerModule:GetControls():Disable()` só quando não é toque) e move com `Humanoid:Move(direção relativa à câmera)`; calor do deserto (fora da sombra do oásis por mais de `DesertHeat.SafeTime` s sem `HeatImmunity` → velocidade × `SlowMultiplier` e `ColorCorrection` alaranjada). O centro/raio do oásis vêm de atributos `OasisCenter`/`OasisRadius` em `workspace.Map` (o builder do Deserto grava esses atributos). Com o atributo `AdminWalkSpeed` no jogador (`:speed` do admin, seção 8.18), ele é a velocidade base (correr = base × `SprintSpeed / WalkSpeed`). `MovementController.GetBaseWalkSpeed() -> number`. **2.0:** o papel vem do atributo `Role` lido ao vivo (o calor do deserto só vale na partida, também depois da troca do Studio).
- `MobileController`: se `TouchEnabled`, cria botões grandes "Atirar" (segurar), "Correr" e, na partida com torretas, "Torreta". `MobileController.IsFireHeld() -> boolean`, `MobileController.IsSprintHeld() -> boolean`, `MobileController.FireChanged: Signal(bool)`. **2.0:** lê o papel do atributo `Role` ao vivo (no Studio o lobby vira partida e o "Atirar" precisa aparecer). `MobileController.SetSuppressed(reason: string, suppressed: boolean)` esconde os botões enquanto houver **algum** motivo ativo (conjunto de motivos, combinado com "modo toque" e "nenhuma janela aberta"); só este módulo liga/desliga a tela dos botões, os outros pedem por aqui. Ex.: o `EndingController` chama `SetSuppressed("Ending", true)` no começo da cena final e `("Ending", false)` no fim (os botões não voltam no meio da cena quando alguém entra).
- `MusicController`: toca em loop a música do lugar: a vaga `"Music_Lobby"` no lobby ou `"Music_<MapId>"` na partida (o `Role` e o estado `Match` são acompanhados ao vivo), resolvida por `UIKit.ResolveSound` (`Config.Game.Music[X]`: > 0 fixo, 0 automático, -1 sem música). Os sons ficam no `SoundGroup` `"Music"` do UIKit (volume = `MusicVolume`); trocas com fade. API: `MusicController.Play(key)` — aceita `"Ending"` ou a vaga `"Music_Ending"`; `Play(nil)` volta para a música normal do lugar; `MusicController.Stop()` (silêncio até o próximo `Play`); **2.0:** `MusicController.PlayAmbient(key|nil)` troca, com fade, o fundo de ambiente em loop (`"Lobby"` ou `"Amb_Lobby"`; grupo `"Ambient"`; `nil` desliga); `MusicController.Duck(amount: 0..1, duration: number, target?)` abaixa a música por um tempo (`0.3` = 30% mais baixo; vários se multiplicam; volta devagar; `target` = `"Music"` (padrão), `"Ambient"` ou `"All"`) e devolve uma função que encerra antes da hora. Quando a `ReplicatedStorage.AudioLibrary` ganha ids novos, a música é resolvida de novo.
- `AmbientController` (2.0; lobby e partida; no topo só `Shared`, `UIKit` e `StateController`): a "vida" do mapa, feita só no cliente. Usa o `CollectionService` para todas as tags de ambiente da seção 7.8 (sinais de entrada/saída num Trove) e **um único** `RenderStepped`: movimento (`AmbientSpin`/`AmbientBob`/`AmbientSway`, bichinhos, luzes tremendo) a 30 Hz e só até 150 studs da câmera (modelos de várias peças movidos com `workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)`; o movimento local de peças ancoradas do servidor não replica); escolhas lentas (quem está perto, liga/desliga `AmbientEmitter`, sons de lugar, clima) a 4 Hz. Bichinhos criados na pasta `ClientAmbient` (ancorados, `CanCollide`/`CanQuery`/`CanTouch = false`; até 30 peças). Clima que segue a câmera numa peça fantasma re-centralizada a cada 0,25 s: neve no Inverno (só quando a peça `SnowEmitter` tem `ClientSnow == true`; `Rate` 180, 70 na qualidade baixa; rajadas de ±60% a cada 8-15 s mexendo só na aceleração local das partículas, porque o `GlobalWind` é do servidor), areia no Deserto (`Rate` 25), pólen no Prado (`Rate` 12), vaga-lumes no Lobby (`Rate` 4). `AmbientAurora` liga quando `Lighting.Atmosphere.Density <= 0.12`. `AmbientSound` cria um `Sound` 3D em loop com `UIKit.ResolveSound(SoundKey)` (grupo `Ambient`, `RollOffMaxDistance` 80) só a até 120 studs, e tenta de novo depois se a vaga ainda não tem áudio. `StateController.GetEffectsQuality() == 1`: metade das partículas e nenhum bichinho. O tipo do mapa vem de `workspace.Map:GetAttribute("MapId")` (ou `Role == "Lobby"`), e tudo é refeito quando a pasta `Map` muda (a troca do Studio monta um mapa novo). Limites: seção 7.8. API: `AmbientController.Init()`, `AmbientController.Start()`, `AmbientController.GetMapType() -> "Lobby"|"Meadow"|"Winter"|"Desert"|nil`. Nada aqui dá recompensa.
- `WeaponController` (partida): atira segurando o botão (mouse 1, R2, botão do celular) quando nenhum modal está aberto, não está colocando torreta e não está superaquecido (`Heat.Overheated`). Intervalo `1 / stats.FireRate`. Direções: `stats.Projectiles` raios em leque horizontal (abertura total `min(stats.Spread × (n-1), Stats.Fan.MaxDegrees)` graus) mais um desvio aleatório pequeno (`Stats.Fan.JitterDegrees`); o servidor confere o leque com os mesmos números (seção 8.6). Envia `Net.Fire("Fire", origin = câmera, dirs, shotId)`. Visual local imediato: arma na câmera (viewmodel simples feito de Parts, cor da skin), clarão, som, tracer até o ponto atingido (raycast local), `CameraController.Kick`. O ponto final do tracer usa a mesma conferência de "encostado na origem" do servidor (`GetPartBoundsInRadius`); os `RaycastParams` são criados uma vez no módulo, a lista de excluídos fica em cache (refeita quando entra/sai jogador ou nasce personagem) e cada bala faz no máximo 2 raios de perfuração. `HitConfirm` → hitmarker (`HUDController.ShowHitmarker(crit)`, no máximo 1 a cada 50 ms; um crítico passa na frente de um normal pendente) e números de dano (se `DamageNumbers`) via `EffectsController`.
- `EffectsController`: `Effect` (explosão de partículas na morte, anel de explosão, poeira no spawn, gelo quebrando, confete), `RemoteShot` e `TurretShots` (tracers), `CoinPopup` (número "+1,2K" subindo e som), números de dano. API: `EffectsController.Tracer(from, to, color, width?)`, `EffectsController.DamageNumber(position, amount, crit, id?)` (`id` opcional = `BrainrotId` da linha do `HitConfirm`; serve para juntar números do mesmo alvo, regras abaixo), `EffectsController.Burst(position, color, size)`. Efeitos locais ficam numa pasta `workspace.ClientEffects` criada pelo cliente; tudo com limite e reciclagem. Limites da 2.0: até 140 tracers, com 40 vagas só para os tiros do próprio jogador (os dos outros nunca tiram essas); `RemoteShot`: no máximo 1 tiro desenhado por jogador a cada 0,05 s (o servidor já manda no máximo 1 a cada 0,1 s; a folga absorve a variação da rede) e no máximo 3 pontas por tiro (as duas das bordas e a do meio), sem faísca de impacto a mais de 60 studs da câmera (o mesmo vale para as faíscas das torretas); números de dano: um número novo de menos de 0,15 s a até 3 studs (ou com o mesmo `Id` do `HitConfirm`) soma no que já existe (crítico nunca junta com normal), no máximo 15 números novos por segundo e 30 vivos; `CoinPopup` a menos de 6 studs da câmera não mostra o texto. Emissores de faíscas por cor (cor fixa) separados dos de explosão; com todos ocupados, a explosão é pulada em vez de mudar a cor de partículas vivas.
- `HUDController` (partida): moedas (com animação), renda/s, brainrots vivos, recarga do quadro, mira no centro com hitmarker, missão ativa com barra, barra de calor (Deserto), barra do Supremo (Deserto), lista do time, botões (Configurações, Voltar ao lobby com confirmação, Receitas no Deserto, Colocar torreta quando houver torretas, Vantagens quando `Gamepasses.AnyForSale()`), aviso do portal/votos, painel de "Buffs" ativos (evento global com nome, tempo e efeitos, receitas, buffs e os passes do jogador: `BuffText` de cada pass; `ExtraTurret` só em mapa com torretas). Janela **Vantagens**: um cartão por pass à venda (nome, descrição, preço lido com `Gamepasses.FetchSaleInfo` — "..." carregando, some se falhar —, botão "Comprar" → `BuyGamepass`, "Já é seu!" ou "Indisponível" desativado se `IsForSale == false`). A recompensa da missão aparece já multiplicada por `Formulas.PassCoinMult`. `HUDController.ShowHitmarker(crit)`. As moedas do HUD só são "semeadas" quando o estado `Coins` já chegou (sem isso a chegada do valor real apareceria como um ganho enorme, ex.: ao continuar uma partida salva ou na troca do Studio). No PC (`UserInputService.PreferredInput == KeyboardAndMouse`), a janela do chat (`TextChatService` → `ChatWindowConfiguration.VerticalAlignment = Bottom`, em `pcall`) vai para baixo, para não cobrir as moedas e a missão.
- `ChatTagController` (lobby e partida): `TextChatService.OnIncomingMessage` → uma etiqueta antes do nome, por prioridade: `IsAdmin` com `AdminRole == "Owner"` → `'<font color="#FF5A5A">[DONO]</font> '`; outro admin → `'<font color="#4DC3FF">[ADMIN]</font> '`; senão, atributo `"VIP" == true` → `'<font color="#FFCD3C">[VIP]</font> '`; devolve `TextChatMessageProperties` com `PrefixText = etiqueta .. message.PrefixText`. Não mexe nos `TextChatCommand` do `DebugService` nem do `AdminService`. É o único dono do callback `OnIncomingMessage`.
- `FlyController` (lobby e partida): enquanto o atributo `AdminFly` do jogador é `true` (só o servidor grava), o personagem voa: `Humanoid.PlatformStand = true`, `LinearVelocity` (mundo) e `AlignOrientation` (um attachment, em pé virado para a câmera) no `HumanoidRootPart`, atualizados num `BindToRenderStep` com prioridade `Character` (depois da câmera de primeira pessoa). Direção = frente da câmera × Forward/Back + lado × Left/Right (teclas do `Config.Keybinds` ou `GetMoveVector` dos controles padrão) + subir (Jump, A) / descer (Ctrl ou Q, L2); `Sprint`/L3/"Correr" acelera. Velocidade 60 × `GetBaseWalkSpeed() / WalkSpeed`. Volta sozinho depois de renascer; limpa tudo ao desligar ou morrer. `FlyController.IsFlying()`.
- `AnnouncementController` (lobby e partida, `ScreenGui` `TopBanners`, `DisplayOrder = 55`): no meio do topo, abaixo da barra do Roblox, (1) a faixa do evento global (`GlobalEvent`: nome, descrição, efeitos e contagem até `EndsAt` no relógio `GetServerTimeNow`; some enquanto `UIKit.IsAnyModalOpen()` para não cobrir janelas) e (2) a fila (até 10) de avisos `Net.On("Announcement")`: `"📢 Aviso de <From>: <Text>"` por `Duration` s, com barra de tempo; clicar fecha. Empurra os toasts com `NotifyController.SetTopOffset`. API: `AnnouncementController.DescribeEffects(effects) -> {string}` (pt-BR, usado pelo HUD e pelo `AdminPanel`), `GetActiveEvent()`, `GetBottomOffset() -> number?` (onde as faixas terminam; a contagem do `LobbyUI` desce para baixo delas).
- `PlacementController` (Inverno/Deserto): `PlacementController.Enter()` → fantasma verde/vermelho da torreta onde a mira aponta no chão (até 60 studs), `Rotate` (R) gira 45°, clique/R2 confirma (`PlaceTurret`), `Cancel` (Q)/B cancela. No celular, botões Confirmar/Cancelar. `PlacementController.IsActive()`.
- `EndingController`: `Net.On("Ending")` → desliga a câmera do jogador, câmera sobe mostrando o Supremo na frente do sol, tela escurece, música `"Ending"`, créditos rolando com `Names` e "Obrigado por jogar!", dura `Duration`. Os botões de toque somem com `MobileController.SetSuppressed("Ending", true/false)` (não mexe na tela de outro módulo). No fim, `MusicController.Play(nil)` (volta à música do lugar).

### 10.4 Janelas
- `StallWindow`: `PromptController.Register("Stall", fn)`. Mostra os upgrades daquela barraca no mapa atual, agrupados por prateleira (prateleiras acima de `ShelfLevel` aparecem trancadas com cadeado e o custo para liberar). Cada linha: nome, descrição, `nível/máx`, efeito atual → próximo (`Formulas`/`NumberFormat.Stat`), custo (verde se dá, vermelho se não), botões `x1`, `x10`, `Máx`. Botão "Melhorar Barraca (prateleira N)" com o custo (`BuyShelf`), ativo quando o global `ShelfReady` é `true` (o servidor decide, porque a regra `AnyPlayer` conta até runs de quem já saiu; o cliente calcula com `PlayerUpgrades`/`TeamUpgrades` só a lista do texto "Faltam N: ..."). Na barraca `Quest`, um painel no topo: missão ativa com progresso ou botão "Pegar missão" / tempo de espera, e "Abandonar". Na barraca `Turret`: botões "Colocar torreta" (fecha a janela e chama `PlacementController.Enter()`) e "Chamar torretas de volta", e contagem `Placed/Max`. Na barraca `Growth`: progresso do Supremo e botão para abrir a `SupremeWindow`. Atualiza sozinha quando o estado muda. **Montada uma vez, atualizada depois:** `builtStall` guarda qual barraca está montada; `Open(stallId)` só remonta (`rebuild`, centenas de objetos) quando a barraca é outra, senão só chama `refreshAll(true)`; o `refreshAll` remonta sozinho se a prateleira ou o mapa mudaram.
- `CauldronWindow`: `Register("Cauldron")`. Inventário de ingredientes (grade de 2 colunas, célula `UDim2.new(0.5, -4, 0, 84)`), 3 espaços de seleção, custo da receita (se reconhecida no Livro), botão "Cozinhar" (`Craft`), aba "Livro de Receitas" (conhecidas: nome, ingredientes, efeito; desconhecidas: `???` + dica). Também abre pelo botão do HUD. Várias mudanças de estado no mesmo quadro viram uma atualização só (`task.defer`); os cartões do Livro só são remontados quando a "assinatura" muda (receitas conhecidas + receitas ativas + multiplicador de custo do mapa), porque o `Profile` muda várias vezes por segundo com as moedas.
- `SupremeWindow`: `Register("Supreme")`. Barra de progresso ("X% do céu"), altura, botões "Alimentar 10% / 50% / 100% das moedas" (`FeedSupreme`).
- `SettingsWindow`: `Register("Settings")`. Sensibilidade, Inverter Y, FOV, Alternar corrida, volumes, números de dano, e remapear teclas (clica e aperta a nova tecla; "Restaurar padrão"). Salva com `SaveSettings` (debounce de 1 s). As outras partes leem de `Profile.Settings`. Regras de salvamento (2.0):
  - Conjunto `dirty` (configurações) e `dirtyKeys` (ações de tecla) preenchidos por `changeSetting`, `assignKey` (as duas ações quando há troca) e `restoreDefaultKeys` (todas as ações). O pacote leva **só os campos mexidos**; `Keybinds` só vai quando alguma ação de tecla foi mexida (e vai o mapa inteiro: o salvo no perfil + as trocas).
  - Quando o servidor confirma, sai do `dirty` o que foi enviado (menos o que o jogador mudou de novo enquanto o pedido viajava); até o `Profile` novo chegar (no máximo 10 s), o valor confirmado vale mais que um perfil antigo que ainda esteja a caminho.
  - Quando o `Profile` chega ou muda, o rascunho vira `GetSettings()` + os valores ainda não confirmados. Enquanto não existe `Profile`, uma capa "Carregando suas configurações..." cobre a lista, nada pode ser mexido e nada é salvo (assim uma mudança feita cedo nunca apaga o FOV ou as teclas salvas).
  - Troca de tecla: ignorada enquanto uma caixa de texto tem o foco (`UserInputService:GetFocusedTextBox()`); teclas reservadas: Esc, `/`, Tab, Alt, F, **F2** (painel de testes), **F3** (painel de admin), F9, F11, Windows/Command, Menu e Print Screen.
  - No lobby (`workspace` `Role == "Lobby"`), as descrições de Sensibilidade, Inverter Y, Campo de visão e Números de dano ganham " (vale na partida)" (atualiza se o papel mudar).
  - Os 7 campos novos da 2.0 (`CameraShake`, `ViewBob`, `EffectsQuality`, `UIScale`, `AmbientVolume`, `AimAssist`, `AutoFire`) ainda não têm linha na janela: elas entram quando os módulos que usam cada um existirem.
- `DebugPanel`: se `workspace:GetAttribute("DebugEnabled")`, botão "DEBUG" que abre painel com botões para cada comando do DebugService.
- `AdminPanel` (lobby e partida): botão "ADMIN" (tela `AdminButton`, `DisplayOrder = 25`, no topo, ao lado do "DEBUG" quando ele aparece) visível só enquanto o atributo `IsAdmin` é `true`; F3 também abre. Janela "Painel de Admin" com abas **Eu** (voo, velocidade, pulo, renascer), **Jogadores** (lista com foto e etiquetas VOCÊ/DONO/ADMIN, linha "Todos"; ir até, trazer, renascer, liberar mapas, ingredientes, moedas (só na partida), tokens; expulsar e banir com motivo e duração, sempre com confirmação e desligados para admins, você e "Todos"; desbanir por UserId), **Partida** (leva, gigantes, chuva de moedas, moedas, maxar, concluir ato com confirmação, ingredientes, Supremo só em mapa com Supremo), **Eventos** (aviso com contador de `AnnounceMaxLength` letras e confirmação; escolher evento de `Config.Admins.Events` na ordem `EventOrder` e os minutos; encerrar) e **Comandos** (linha de comando igual ao chat e a lista de `Config.Admins.Commands` por categoria). Todo botão chama `Net.Request("AdminCommand", nome, {argumentos em texto})` (jogador = UserId ou `"all"`/`"me"`) e mostra a resposta com `NotifyController`. LB/RB trocam de aba no controle.
- `LobbyUI` (pode ser dividido em vários ModuleScripts dentro de `UI/`, com prefixo `Lobby`): botões laterais (Criar Partida, Partidas Abertas, Loja, Conquistas, Configurações, Reconectar se `CanReconnect`), janela **Criar Partida** (mapas de `Config.Maps.Order` com cadeado se não liberado, 1..8 jogadores, privacidade, "Continuar partida salva" se `RunSaves[mapa]`), janela **Meu Grupo** (membros com foto `GetUserThumbnailAsync`, prontos, botões do host: trocar mapa/limite/privacidade, expulsar, passar liderança, convidar jogador do servidor, convite do Roblox via `SocialService:PromptGameInvite`, iniciar/forçar/cancelar; contagem regressiva grande), janela **Partidas Abertas** (lista do `PartyState.Parties` com botão Entrar ou o motivo do bloqueio), popup de convite recebido (Entrar/Recusar), **Loja** (`LobbyShop`: aba "Skins" com as skins pagas com tokens e, só quando `Gamepasses.AnyForSale()`, aba "Vantagens" com um cartão por pass à venda: nome, descrição, preço em Robux (`Gamepasses.FetchSaleInfo`, "..." carregando, some se falhar) e botão "Comprar" → `Net.Request("BuyGamepass", key)`, "Já é seu!" quando `Gamepasses[key]` ou "Indisponível" (desativado) se o Roblox diz que não está à venda; sem passes à venda não há abas e a janela é só a "Loja de Skins"; `LobbyUI.Open("Shop", "Passes")` abre direto na aba Vantagens), **Conquistas e Estatísticas**. Registra `CreateParty`, `PartyList`, `Shop`, `Achievements` (e, na 2.0, `QuickPlay` e `Reconnect`; lista abaixo). Quando o grupo entra em `"Teleporting"`, chama `TeleportService:SetTeleportGui` com uma tela de carregamento com o nome e a cor do mapa.
  - **ClientActions do lobby (2.0)** — o `PromptController` entrega o argumento depois do `:`; `LobbyUI.Open(key, arg)` repassa `arg` para a janela. Enquanto a tela de carregamento está aberta os prompts não fazem nada.

    | ClientAction | O que faz |
    |---|---|
    | `CreateParty` / `CreateParty:<MapId>` | abre **Criar Partida** (`LobbyCreate.Open(mapId?)`: com o mapa já escolhido quando ele existe e está liberado; mapa trancado ou inválido é ignorado); se o jogador já está num grupo, abre **Meu Grupo** |
    | `QuickPlay:<MapId>` | partida solo sem janela: `Request("PartyCreate", {MapId, MaxPlayers = 1, Privacy = "Invite", Resume = <tem save desse mapa em Profile.RunSaves>})` e depois `Request("PartyStart", true)`; erro do servidor vira aviso (a mensagem em pt-BR que ele devolveu); já estar num grupo → aviso e abre **Meu Grupo**; grupo criado mas não iniciado → abre **Meu Grupo** |
    | `Reconnect` | o mesmo que o botão "Reconectar"; cada cliente liga/desliga os prompts `Reconnect` do mundo **só para ele** (`Profile.CanReconnect` e, se veio, `ReconnectUntil` ainda no futuro pelo relógio do servidor) |
    | `PartyList` | abre **Partidas Abertas** (como antes) |
    | `Shop` / `Shop:Passes` | abre a **Loja** (na aba Vantagens com `Passes`) |
    | `Achievements` / `Achievements:Stats` / `Achievements:Goals` | abre **Conquistas e Estatísticas** na aba pedida (`Goals` = "Próximos objetivos", etapa 6; a janela pode ignorar o argumento até lá) |
    | `Settings` | continua registrado pela `SettingsWindow` (não pelo LobbyUI) |

    Mapa trancado (fora de `Profile.UnlockedMaps`) em `CreateParty:<MapId>` ou `QuickPlay:<MapId>`: aviso "Conclua <mapa anterior> para liberar" (com o som de erro) em vez de abrir.
  - **Troca lobby → partida no Studio (2.0; seções 8.16 e 10.1):**
    - `LobbyUI.ShowTransition(mapId)` — mostra a tela de carregamento (a mesma do teleporte, com o nome e a cor do mapa) com "Preparando <nome do mapa> (teste no Studio)...", **sem** `SetTeleportGui` (não há teleporte). O `Start` ouve `workspace:GetAttributeChangedSignal("StudioSwitching")` e chama com `workspace:GetAttribute("StudioSwitchMap")` quando vira `true` (também se a troca já começou enquanto o lobby ligava). Se a troca terminar sem virar partida (erro no servidor), a tela some depois de alguns segundos.
    - `LobbyUI.HideLoading()` — esconde na hora a tela de carregamento/transição e devolve o menu lateral.
    - `LobbyUI.Shutdown()` — desliga toda a interface do lobby quando a partida começa no mesmo servidor (o `Main.client` chama depois de ligar os módulos da partida): fecha as janelas (`CloseAll`), desfaz registros de prompt, conexões, a ação do controle `LobbyUIGamepadMenu` e os relógios (tudo num `lifeTrove`), limpa a contagem e os convites, destrói as janelas dos submódulos (quem tem `Destroy()`, ex.: `LobbyCreate.Destroy()`), destrói as telas `LobbyHUD` e `LobbyPopup` e faz a tela de transição sumir aos poucos, mostrando a partida por trás. Idempotente; depois dele o `LobbyUI.Open` não abre mais nada.
  - Tela de teleporte (2.0): enquanto ela está aberta, acompanha `LocalPlayer.OnTeleport`; em `Enum.TeleportState.Failed` mostra "O teleporte falhou, tentando de novo..." e, se nada mais acontecer em 20 s, esconde a tela com um aviso. O botão "Reconectar" some quando `os.time()` do servidor passa de `Profile.ReconnectUntil`. Um convite já mostrado não volta enquanto o grupo existir, e o grupo do próprio jogador nunca vira popup de convite. A ação do controle do menu lateral devolve `Pass` quando a seleção está em outra interface (popup de convite, painel de admin...).
