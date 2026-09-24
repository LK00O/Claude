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
                                           Enchants, Coins, Quests, Recipes, Achievements, Cosmetics, Keybinds
      Util/                      (Folder)  Signal, Trove, Net, NumberFormat, Formulas, PlaceRole, Tables
  ServerScriptService/
    Main.server.lua              (Script: inicializa tudo)
    Services/                    (Folder)  DataService, StateService, SettingsService, TravelService,
                                           AchievementService, DebugService,
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
                                           HUDController, PlacementController, EndingController
      UI/                        (Folder)  UIKit, StallWindow, CauldronWindow, SupremeWindow,
                                           SettingsWindow, DebugPanel, LobbyUI
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
  1. Se `workspace:GetAttribute("ForceRole")` for `"Lobby"`/`"Match"`, usa isso.
  2. Se `game.PlaceId ~= 0` e `game.PlaceId == Config.Game.MatchPlaceId` → `"Match"`.
  3. Se `game.PlaceId ~= 0` e `game.PlaceId == Config.Game.LobbyPlaceId` → `"Lobby"`.
  4. Se `RunService:IsStudio()` → `Config.Game.StudioRole`.
  5. Senão → `"Lobby"`.
- O servidor, no `Main`, grava `workspace:SetAttribute("Role", role)`. **O cliente lê o papel desse atributo** (espera até existir), nunca calcula sozinho.
- `PlaceRole.IsStudio()` → `RunService:IsStudio()`.

---

## 2. Rede (`Shared/Util/Net.lua`)

O servidor cria `ReplicatedStorage.Remotes` (Folder) com os remotes abaixo. O cliente espera por eles (`WaitForChild`).

### 2.1 RemoteEvents
| Nome | Direção | Argumentos |
|---|---|---|
| `State` | S→C | `(key: string, value: any)` |
| `Notify` | S→C | `(payload: {Text: string, Kind: "info"\|"success"\|"warning"\|"error"\|"rare", Duration: number?})` |
| `Fire` | C→S | `(origin: Vector3, directions: {Vector3}, shotId: number)` |
| `HitConfirm` | S→C | `(hits: {{Position: Vector3, Damage: number, Crit: boolean, Killed: boolean}})` |
| `RemoteShot` | S→C | `(userId: number, origin: Vector3, endpoints: {Vector3}, tracerColor: Color3)` |
| `Effect` | S→C | `(kind: string, data: table)` — kinds na seção 2.4 |
| `CoinPopup` | S→C | `(amount: number, position: Vector3)` |
| `TurretShots` | S→C | `(shots: {{From: Vector3, To: Vector3, Hit: boolean}})` |
| `OpenUI` | S→C | `(action: string, arg: string?)` — mesmo formato de `ClientAction` (seção 7) |
| `Ending` | S→C | `(data: {Names: {string}, Duration: number, SupremeName: string})` |
| `PartyState` | S→C | `(state: PartyStatePayload)` — seção 9 |

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
| `BuyGamepass` | `key: string` | `true` | MonetizationService |
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
- `StateService.Notify(player, text, kind?, duration?)` e `StateService.NotifyAll(text, kind?, duration?)` — atalhos para o evento `Notify`.

### 3.2 Cliente: `Controllers/StateController.lua`
- `Init()`: conecta `Net.On("State")`, depois chama `Request("GetFullState")` e aplica tudo.
- `StateController.Get(key)`, `StateController.OnChanged(key, fn(value)) -> conexão` (chama `fn` quando a chave muda), `StateController.Changed: Signal(key, value)`.
- `StateController.GetStats()` → `Formulas.ComputeStats(Match.MapId, PlayerUpgrades, TeamUpgrades, Recipes, {DoubleCoins = Gamepasses.DoubleCoins})`, com cache refeito quando `Match`, `PlayerUpgrades`, `TeamUpgrades`, `Recipes` ou `Gamepasses` mudam. `StateController.StatsChanged: Signal(stats)`. Se não há `Match` (lobby), retorna `nil`.
- `StateController.WaitFor(key)` — espera até a chave existir.

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
| `Gamepasses` | jogador | `{DoubleCoins = boolean, AutoCollect = boolean, ExtraTurret = boolean}` |
| `Board` | global | `{CooldownEnd = number}` |
| `Alive` | global | `number` brainrots vivos |
| `TeamList` | global | `{{UserId, Name, Coins}}` (1 Hz) |
| `Completed` | global | `boolean` — ato atual concluído (todas as prateleiras maxadas) |

---

## 4. Dados persistentes (`Services/DataService.lua`, serviço-folha)

### 4.1 Armazenamento
- DataStore principal: `Config.Game.DataStoreName`, chave `"Player_" .. userId`.
- DataStore das partidas salvas (time): `Config.Game.RunStoreName`, chave `"Run_" .. hostUserId .. "_" .. mapId`.
- Se `DataStoreService` falhar no Studio (API desligada), usar um **armazenamento em memória** (mock) com a mesma interface e avisar no Output uma vez: `"[DataService] Usando dados temporários (ative Studio Access to API Services para salvar de verdade)"`.
- **Trava de sessão** feita com `UpdateAsync`: o registro guarda `{Data = perfil, Lock = {JobId, Time}}`. Ao carregar: se há trava de outro `JobId` com `Time` há menos de `Config.Game.SessionLockTimeout` (padrão 90 s), espera 5 s e tenta de novo (até 6 vezes) e depois assume a trava. O autosave renova `Time`. Ao sair/teleportar, grava `Lock = nil`.
- Autosave a cada `Config.Game.AutosaveInterval` s. `game:BindToClose` salva todos (em paralelo, com `task.spawn` e espera até 25 s).
- Novas chaves do template são adicionadas a perfis antigos (reconcile), sem apagar dados.

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
  },
  Achievements = {},              -- [achievementId] = os.time()
  RecipesKnown = {},              -- [recipeId] = true
  Settings = {
    Sensitivity = 0.5, InvertY = false, FOV = 80, ToggleSprint = false,
    MusicVolume = 0.5, SfxVolume = 0.7, DamageNumbers = true,
    Keybinds = {},                -- [actionName] = "KeyCodeName" (só os alterados)
  },
  Tokens = 0,
  Cosmetics = { Owned = { Classic = true }, Equipped = "Classic" },
  LastMatch = nil,                -- {AccessCode, PrivateServerId, MapId, Time = os.time()}
  RunSaves = {},                  -- [mapId] = os.time() (este jogador é dono de uma partida salva nesse mapa)
  MapRecords = {},                -- [mapId] = {BestCoins = number} (mais moedas ganhas numa partida desse mapa; mostrado no card do mapa)
  RunData = {},                   -- [mapId] = {HostUserId, Coins, Upgrades, Ingredients, SavedAt}
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
- `DataService.SyncProfile(player)` — envia `StateService.Set(player, "Profile", DataService.BuildClientView(profile))`, com limite de 2 vezes por segundo (junta chamadas seguidas).
- `DataService.BuildClientView(profile)` → cópia com `UnlockedMaps, CompletedMaps, GameCompleted, Stats, Achievements, RecipesKnown, Settings, Tokens, Cosmetics, RunSaves, MapRecords` + `CanReconnect: boolean` (há `LastMatch` com menos de `Config.Lobby.ReconnectWindowSeconds`) + `LastMatchMap: string?`. **Não** envia `RunData` nem `AccessCode`.
- `DataService.IncrementStat(player, path, amount)` — `path` tipo `"Kills.Low"` ou `"TotalCoins"`; soma, dispara `StatChanged` e chama `SyncProfile`.
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
  StudioRole = "Match",                         -- "Lobby" ou "Match" ao testar no Studio
  StudioMapId = "Meadow",                       -- mapa usado no Studio
  DebugMode = false,                            -- comandos de teste fora do Studio
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
  Gamepasses = { Enabled = false, DoubleCoins = 0, AutoCollect = 0, ExtraTurret = 0 },
  GamepassAutoCollectRadius = 30,
  Music = { Lobby = 0, Meadow = 0, Winter = 0, Desert = 0, Ending = 0 },
  Sounds = { Shoot = 0, Hit = 0, Crit = 0, Coin = 0, Death = 0, Explosion = 0, Purchase = 0,
             Error = 0, Notify = 0, Turret = 0, Portal = 0, Craft = 0 },  -- 0 = sem som
}
```

### 5.2 `Config/Lobby.lua`
```lua
{ MinMaxPlayers = 1, MaxPlayersLimit = 8, DefaultMaxPlayers = 4, CountdownSeconds = 5,
  TeleportRetries = 3, ReconnectWindowSeconds = 7200,
  HandoffMapName = "BrainrotMatchHandoff", HandoffExpiration = 86400,
  LeaderboardStoreName = "BrainrotIncremental_TopCoins_v1", LeaderboardRefresh = 60, LeaderboardSize = 10,
  Privacy = { Public = "Público", Friends = "Só amigos", Invite = "Só convidados" } }
```

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
    Lighting = { ClockTime = 14, Brightness = 2.2, Ambient = Color3, OutdoorAmbient = Color3,
                 Atmosphere = { Density = 0.25, Offset = 0.1, Color = Color3, Decay = Color3, Glare = 0, Haze = 1 } },
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
             TurretSlow = {0, 0.8}, Projectiles = {1, 20}, QuestCooldown = {5, 600}, SpawnCount = {1, 60} },
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
Alvo = `ceil(Base * (1 + somaDeNíveisDoJogadorETime * ScalePerUpgradeLevel))`; para `Collect`: `max(RewardFloor*CostScale, Income * BaseSeconds)`. Recompensa = `max(RewardFloor * CostScale, Income * RewardSeconds) * stats.QuestReward`.

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
  1. copia `Stats.Defaults`; 2. aplica `Weapons[Maps[mapId].Weapon].Stats`; 3. aplica `Maps[mapId].StatOverrides`; 4. percorre `Upgrades.ByMap[mapId]` em ordem aplicando `ApplyEffect` com o nível do escopo certo; 5. aplica efeitos das receitas `Permanent` aplicadas (`Mode/Value` com nível 1); 6. `extras.DoubleCoins` → `CoinMult *= 2`; 7. aplica `Clamps`. `Projectiles` e `Pierce` são arredondados para baixo.
- `Formulas.BrainrotMaxHealth(def, mapId, sizeFactor, playerCount)` = `def.BaseHealth * HealthScale * sizeFactor^2 * (1 + Game.HealthScalePerExtraPlayer * (playerCount - 1))`.
- `Formulas.BrainrotCoinValue(def, mapId, sizeFactor)` = `def.BaseCoinValue * ValueScale * sizeFactor^2`.
- `Formulas.EnchantCoinMult(enchantDef, mapId, enchantPower)`.
- `Formulas.QuestReward(mapId, income, questRewardStat)`.
- `Formulas.IsUpgradeMaxed(def, level)`.

`sizeFactor` = tamanho relativo do brainrot (1 = tamanho base adulto sem upgrades). A escala do modelo é `def.BaseScale * sizeFactor`.

---

## 7. Mundo e prompts (`World/*`)

### 7.1 `World/MapBuilder.lua`
- `MapBuilder.Build(mapId) -> ctx` — `mapId` ∈ `"Lobby"`, `"Meadow"`, `"Winter"`, `"Desert"`. Apaga `workspace.Map` antigo, cria `workspace.Map` (Folder), chama `Builders[mapId].Build(folder)` e aplica a iluminação do mapa (`Config.Maps[mapId].Lighting`; o Lobby tem iluminação própria no builder). Remove o `Baseplate` padrão se existir.
- `MapBuilder.SetShelfLevel(ctx, level)` — mostra as prateleiras `<= level` de todas as barracas (as outras ficam invisíveis e sem colisão).
- `MapBuilder.OpenPortal(ctx, targetDisplayName) -> ProximityPrompt` — cria/ativa um portal girando em `ctx.PortalSpot`, com um prompt (`ServerAction = "Portal"`), e o retorna.

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
  SnowEmitterPart = Part?,      -- (Inverno)
}
```
Contexto do Lobby: `{ MapId = "Lobby", Folder, SpawnLocation, CreateTerminal = Part, PartyBoard = Part, Leaderboard = Part (com SurfaceGui "Board" que tem Frame "List"; é o painel de moedas), Leaderboards = { Coins = Part, Kills = Part, Acts = Part } (mesmo formato), ShopStand = Part, AchievementsStand = Part }`.

### 7.3 Prompts
- Todo `ProximityPrompt` tem `RequiresLineOfSight = false`, `MaxActivationDistance = 12`, `HoldDuration = 0`, `KeyboardKeyCode = E`, `Style = Default`.
- Prompt tratado pelo **cliente**: atributo `ClientAction` = `"Stall:Weapon"`, `"Stall:Brainrot"`, `"Stall:Quest"`, `"Stall:Turret"`, `"Stall:Growth"`, `"Cauldron"`, `"Supreme"`, `"CreateParty"`, `"PartyList"`, `"Shop"`, `"Achievements"`, `"Settings"`. Formato: `"Ação"` ou `"Ação:Argumento"`.
- Prompt tratado pelo **servidor**: atributo `ServerAction` = `"Board"`, `"RecallTurrets"`, `"Portal"`, `"PickupTurret"`, `"TurretMode"`. O serviço dono conecta `prompt.Triggered` usando a referência do `ctx` (ou do modelo da torreta).
- Partes auxiliares invisíveis (FieldArea, TurretZones etc.) e cercas/decoração baixa têm `CanQuery = false` (não bloqueiam tiros). Chão, pedras grandes e paredes têm `CanQuery = true`.

### 7.4 `World/Builders/Common.lua`
Helpers usados pelos builders: `Common.Part(props) -> Part` (ancorado por padrão), `Common.Model(name, parent)`, `Common.Prompt(parent, actionText, objectText, attributes) -> ProximityPrompt`, `Common.Sign(part, face, text, textColor?, bgColor?)` (SurfaceGui com TextLabel), `Common.Billboard(part, text, offset)`, `Common.Tree(parent, position, style: "Oak"|"Pine"|"Palm", scale)`, `Common.Rock(parent, position, size)`, `Common.Fence(parent, center: Vector3, size: Vector2, height, gapSide?)`, `Common.Stall(parent, stallId, cframe, color, title) -> stallTable` (base, balcão com prompt `ClientAction = "Stall:<id>"`, telhado listrado, placa com o nome, **3 prateleiras** atrás do balcão com itens decorativos — prateleira 1 visível, 2 e 3 escondidas até `SetShelfLevel`), `Common.Board(parent, cframe) -> part, prompt`, `Common.Crate(parent, cframe) -> part`, `Common.Ground(parent, size, color, material)`, `Common.Lamp(parent, position)`.

### 7.5 Mapas
- **Lobby**: praça de ~200×200 studs, tema fazenda brainrot colorida: spawn no centro, placa grande com o nome do jogo, terminal "Criar Partida" (prompt `CreateParty`), quadro "Partidas Abertas" (prompt `PartyList`), placar de líderes (SurfaceGui com lista), barraca de skins (prompt `Shop`), estátua de conquistas (prompt `Achievements`), árvores, cerca, lampiões, estátuas de brainrot decorativas (pode usar `BrainrotFactory`? **Não**: World não depende de ordem; o builder do Lobby pode fazer `require(script.Parent.Parent.BrainrotFactory)` porque é outro módulo de World). Iluminação de fim de tarde.
- **Prado (Meadow)**: chão de grama ~420×420; campo retangular ~200×150 cercado (FieldArea = o retângulo do campo, ~2 studs acima do chão); do lado sul, a "praça" com Board, Crate, as 3 barracas lado a lado, PortalSpot; colinas (esferas grandes meio enterradas) e árvores ao redor; sol visível (ClockTime 14).
- **Inverno (Winter)**: vale nevado ~420×420 (material Snow), plataforma de madeira elevada (~70×70, altura 14) no centro com rampa até o chão; na plataforma: Board, Crate, as 4 barracas, RecallPrompt, TurretBase (pads) e PortalSpot; FieldArea = anel em volta (use uma área retangular grande; o BrainrotService evita o volume da plataforma porque não nasce dentro de `ctx.Platform` expandida em 6 studs). TurretZones = plataforma + o vale. Pinheiros e pedras com neve. `SnowEmitterPart` (partícula de neve cobrindo o mapa, alta). Atmosfera densa.
- **Deserto (Desert)**: areia ~460×460, dunas; oásis central (lago azul, palmeiras, sombra) com as 5 barracas em volta, Board, Crate, Cauldron, RecallPrompt, TurretBase; a **Grande Cova** (cratera) a ~150 studs do oásis **na direção do sol** (use `game.Lighting:GetSunDirection()` depois de ajustar `ClockTime`, projetado no plano XZ) com `PitPrompt` na borda; FieldArea = região de areia entre o oásis e as bordas (evitar o oásis por raio: o BrainrotService não nasce a menos de `OasisRadius + 6` do centro, nem a menos de 40 studs do Pit). TurretZones = campo inteiro. Miragem: `ColorCorrection`/`BloomEffect` leve.

### 7.6 `World/BrainrotFactory.lua`
- `BrainrotFactory.Build(def) -> Model` — se `game.ServerStorage:FindFirstChild("BrainrotModels")` tiver um modelo com `def.ModelName`, clona e normaliza (todas as BaseParts `Anchored = true`, `CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `CollisionGroup = "Brainrots"`; `PrimaryPart` definido; `WorldPivot` no centro da base; escala ajustada para ~5 studs de altura). Senão, monta um modelo provisório pelo `Archetype` com as cores de `def.Colors`: corpo, olhos brancos com pupila preta, detalhes do personagem. `PrimaryPart` = parte chamada `"Body"`. Retorna o modelo em escala 1, sem pai.
- `BrainrotFactory.BuildSupreme(def) -> Model` — versão mais detalhada para o Brainrot Supremo.
- `BrainrotFactory.AttachBillboard(model, displayName, tierColor, enchantName?, enchantColor?) -> {Gui, Fill}` — BillboardGui (`AlwaysOnTop = false`, `MaxDistance = 250`, `StudsOffsetWorldSpace` acima da cabeça) com nome, tag de encantamento e barra de vida (`Fill` é o Frame cuja `Size.X.Scale` = fração de vida).
- `BrainrotFactory.ApplyEnchantVisual(model, enchantDef)` — partículas/brilho na cor do encantamento (não usar `Highlight`, que tem limite de 31).
- `BrainrotFactory.AddIceBlock(model) -> Part` — bloco de gelo translúcido em volta (Inverno).

### 7.7 `World/TurretFactory.lua`
- `TurretFactory.Build(ownerName, colors?) -> Model` com partes `Base` (PrimaryPart) e `Head` (gira no eixo Y; o cano aponta para `-Z` do Head), `Muzzle` (Attachment no Head), um `BillboardGui` com o nome do dono, e dois prompts: `ServerAction = "PickupTurret"` (ActionText "Recolher") e `ServerAction = "TurretMode"` (ActionText "Mirar: mais valioso") com `HoldDuration = 0.3` no de recolher. Tudo ancorado, `CollisionGroup = "Turrets"`.
- `TurretFactory.AimHead(model, targetPosition)` — gira o Head para o alvo.

---

## 8. Serviços da partida

### 8.1 `Main.server.lua`
1. `Net.Init()`; registra grupos de colisão com `PhysicsService:RegisterCollisionGroup` (`"Players"`, `"Brainrots"`, `"Coins"`, `"Turrets"`) e regras: `Coins` não colide com `Players`, `Brainrots`, `Coins`, `Turrets`; `Brainrots` não colide com `Players` nem `Brainrots`.
2. `role = PlaceRole.Get()`; `workspace:SetAttribute("Role", role)`; se debug estiver ligado, `workspace:SetAttribute("DebugEnabled", true)`.
3. Comuns: `StateService`, `DataService`, `SettingsService`, `AchievementService`, `DebugService` (Init).
4. Lobby: `LobbyService`, `PartyService`, `ShopService` (Init, depois Start de todos).
5. Partida: `MatchService.Init()` (resolve a partida e constrói o mapa — pode esperar), depois `StatService, MonetizationService, CoinService, BrainrotService, CombatService, UpgradeService, ProgressionService, QuestService, TurretService, RecipeService, SupremeService` (Init de todos, depois Start de todos), e por fim `MatchService.Start()` (começa a aceitar jogadores).
6. Cada Init/Start dentro de `pcall`/`xpcall` com `warn` do erro e o nome do serviço (um serviço quebrado não derruba os outros).

### 8.2 `MatchService`
Estado:
```lua
MatchService.MapId, MatchService.MapDef, MatchService.Act, MatchService.Context (ctx), MatchService.Handoff
MatchService.Team = { Upgrades = {}, ShelfLevel = 1, Recipes = {}, Buffs = { TimedEnchantUntil = 0, NextWaveGiant = false },
                      SupremeProgress = 0, Turrets = { { OwnerUserId, Position = {x,y,z}, RotY } }, SharedCoins = 0 }
MatchService.Runs[userId] = { UserId, Name, Coins = 0, Upgrades = {}, Ingredients = {}, Quest = nil, QuestCooldownEnd = 0,
                              IncomeEMA = 0, Heat = 0, Overheated = false }
```
Funções:
- `Init()` — resolve o handoff: no Studio → `MapId = Config.Game.StudioMapId`, sem lista de membros (todos entram), host = primeiro jogador. Em servidor reservado (`game.PrivateServerId ~= ""` e `game.PrivateServerOwnerId == 0`) → lê `MemoryStoreService:GetHashMap(Config.Lobby.HandoffMapName):GetAsync(game.PrivateServerId)` (até 10 tentativas, 1 s entre elas). Sem handoff → usa `TeleportData.MapId` do primeiro jogador (valida que existe) e aceita todos. Servidor público do place de partida → manda todo mundo para o lobby (`TravelService.SendToLobby`). Depois: `ctx = MapBuilder.Build(MapId)`, cria pastas `workspace.Brainrots`, `workspace.Coins`, `workspace.Turrets`, e se `Handoff.Resume`, carrega `DataService.LoadRun("Run_"..host.."_"..MapId)` em `Team`. Publica `StateService.SetAll("Match", ...)`, `"TeamUpgrades"`, `"ShelfLevel"`, `"Recipes"`, `"Buffs"`, `"Completed" = false`.
- `Start()` — `PlayerAdded` (e jogadores já presentes): confere membro (senão `TravelService.SendToLobby({player})` com Notify e, se falhar, Kick) e limite de jogadores; espera o perfil; cria/restaura o `Run` (cache em memória se voltou; senão `profile.RunData[MapId]` se `Resume` e o `HostUserId` bate; senão novo e limpa `profile.RunData[MapId]`); grava `profile.LastMatch` com `AccessCode`/`PrivateServerId` do handoff; envia chaves de estado do jogador; `CharacterAdded` → partes no grupo `"Players"`, `Humanoid.WalkSpeed = Config.Game.WalkSpeed`, spawn no `ctx.SpawnLocation`. `PlayerRemoving` → salva o run dele no perfil (`RunData[MapId]`), mantém o run em memória. Autosave do time a cada `AutosaveInterval` (e grava `RunSaves[MapId]` no perfil do host se ele estiver presente). Loop de 1 Hz: `TeamList`. Na entrada, `AchievementService.FireEvent(player, "PlayWithFriends", {Count = nº de amigos na partida})`.
- `GetRun(player)`, `GetRunByUserId(userId)`, `GetTeam()`, `GetMapId()`, `GetMapDef()`, `GetContext()`, `GetHostUserId()`, `IsMember(userId)`, `GetPlayerCount()`.
- `AddCoins(player, amount, source)` — `source` ∈ `"Pickup"`, `"Quest"`, `"Turret"`, `"Debug"`, `"Refund"`. Multiplica por 2 se o jogador tem o gamepass `DoubleCoins` (exceto `"Refund"`/`"Debug"`). Soma na carteira (ou `Team.SharedCoins` se `SharedWallet`), `IncrementStat("TotalCoins")` (exceto Refund/Debug), atualiza `IncomeEMA` (janela de ~10 s, mostrada no HUD) e `IncomeSlow` (janela de 120 s, usada no alvo e na recompensa das missões), manda `Coins`/`Income` e dispara `MatchService.CoinsAdded: Signal(player, amount, source)`.
- `SpendCoins(player, amount) -> boolean`, `GetCoins(player) -> number`.
- `SaveAll()`.
- `CompleteAct()` — para cada jogador presente: `CompletedMaps[MapId] = true`, `UnlockedMaps[Next] = true`, `Tokens += MapDef.TokensReward`, `Stats.ActsCompleted += 1`, `AchievementService.FireEvent(player, "CompleteMap", {Map = MapId})`, limpa `RunData[MapId]` e `RunSaves[MapId]`; apaga a partida salva do time. Se o mapa tem `Next` → `TravelService.SendToNewMatch(jogadores, {MapId = Next, HostUserId = host atual, MaxPlayers = handoff ou 8, Privacy = handoff ou "Invite", Resume = false})`. Se não tem (Deserto) → marca `GameCompleted = true`, dá a skin `"Rainbow"` (se o jogador ainda não tem) e `TravelService.SendToLobby(jogadores)`.
- Request `ReturnToLobby` → salva o run do jogador e manda ele para o lobby.
- `MatchService.CoinsAdded: Signal`, `MatchService.RunReady: Signal(player, run)`.

### 8.3 `StatService`
- `StatService.Get(player) -> stats` (cache por jogador), `StatService.GetTeam() -> stats` (calculado com níveis vazios de jogador; usado para stats de time), `StatService.Invalidate(player?)` (nil = todos + time), `StatService.Changed: Signal(player?)`.
- Usa `Formulas.ComputeStats(MapId, run.Upgrades, Team.Upgrades, Team.Recipes, {DoubleCoins = MonetizationService.HasPass(player, "DoubleCoins")})`.
- Efeitos de ambiente quando o time muda: no Inverno, `Lighting.Atmosphere.Density = MapDef.AtmosphereDensity * MapDef.VisibilityFactor ^ teamStats.Visibility`.

### 8.4 `CoinService`
- `CoinService.SpawnCoins(totalValue, position)` — divide o valor em peças (tier mais alto que caiba, até `MaxPiecesPerDeath`; a última peça leva o resto; acima do maior tier, a moeda do maior tier leva o valor inteiro), cria `Part` esféricas/cilíndricas na cor do tier em `workspace.Coins`, grupo `"Coins"`, atributo `"Value"`. Posição: se `DropMode == "Crate"`, perto de `ctx.CoinDropPoint` espalhado em `CrateScatter`; senão em `position`. Solta com velocidade para cima e aleatória para os lados; `SetNetworkOwner(nil)`. Depois de `SettleTime` s fica ancorada.
- Loop 10 Hz: expira moedas velhas (`DespawnTime`, exceto com coleta automática); coleta quando um personagem vivo está a `PickupRadius` (credita com `MatchService.AddCoins(player, value, "Pickup")` e `Net.FireClient(player, "CoinPopup", value, pos)`); ímã: moedas a menos de `teamStats.MagnetRadius` (ou `GamepassAutoCollectRadius` para quem tem o gamepass) de um jogador deslizam até ele a `MagnetPullSpeed`; coleta automática (`teamStats.AutoCollect >= 1`): depois de `AutoCollectDelay` s a moeda vai para o jogador vivo mais perto.
- Se passar de `MaxCoinsOnGround`, funde a moeda mais velha na moeda mais próxima dela (soma o valor e atualiza cor/tamanho pelo novo tier).

### 8.5 `BrainrotService`
Entidade:
```lua
{ Id, Def, Model, Position (Vector3, no chão), SizeFactor, TargetSize, StartSize, GrowStart, GrowDuration,
  HealthFrac = 1, MaxHealth, IceShield = 0, IceShieldMax = 0, IceBlock = Part?, Enchant = enchantDef?, Giant = boolean,
  SlowUntil = 0, SlowFactor = 1, BurnUntil = 0, BurnDps = 0, LastHitBy = Player?, SpawnTime, Dead = false, Billboard }
```
- `BrainrotService.SpawnWave(triggeredBy?) -> ok, msg` — respeita `Board.CooldownEnd` (`Config.Game.BoardCooldown`), `MaxBrainrotsAlive`; quantidade = `teamStats.SpawnCount`. Sorteio: peso do tier × (`Low` 1, `Medium` 1+TierLuck, `High` 1+2·TierLuck). Gigante com `GiantChance` (ou todos se `Buffs.NextWaveGiant`, que depois volta a false). Encantamento com `EnchantChance` (ou sempre, se `now < Buffs.TimedEnchantUntil`), escolhido por peso (com `MapOverrides`). Congelado com `MapDef.FrozenChance` (escudo = `FrozenShieldFraction` × vida máx). Posição aleatória dentro de `FieldArea`, longe de jogadores (`PlayerExclusionRadius`), de outros brainrots (`MinBrainrotSpacing`), fora da plataforma/oásis/cova (ver 7.5), até `SpawnAttempts` tentativas. Tamanho alvo = `GrowthMult × (Giant 3 ou 1) × enchant.SizeMult`; começa em 25% e cresce até 100% em `def.GrowTime / enchant.GrowthMult` s (ease-out). Efeito `"Spawn"`.
- Board: conecta `ctx.BoardPrompt.Triggered` → `SpawnWave(player)`; se estiver em recarga, `Notify` com o tempo.
- Loop 5 Hz: crescimento (`Model:ScaleTo(def.BaseScale * SizeFactor)` e `PivotTo` na posição), `MaxHealth` recalculado mantendo `HealthFrac`, barra de vida, queimadura (`BurnDps`), atração (se `teamStats.AttractValuable >= 1`: `High` ou `Giant` andam até o jogador mais perto a `AttractSpeed × SlowFactor` até `AttractStopDistance`, sem sair da `FieldArea`; no Inverno a atração vem de `W_Attract`), cor dos arco-íris, respawn automático (`AutoRespawn >= 1` e vivos < `AutoRespawnThreshold × SpawnCount` e fora da recarga). `StateService.SetAll("Alive", n)`.
- `BrainrotService.GetEntity(id)`, `GetEntityFromPart(part)` (sobe até o Model com atributo `"BrainrotId"`), `GetAlive() -> {entity}`, `GetFolder()`.
- `BrainrotService.Damage(entity, amount, attacker?, info) -> dealt, killed` — `info = {Crit = boolean, Source = "Gun"|"Turret"|"Explosion"|"Burn"|"Splash", TurretOwnerUserId = number?}`. Enquanto o brainrot está lento (`SlowUntil > agora`), o dano é multiplicado por `BrainrotService.GetDamageMult(entity)` = `1 + (1 - SlowFactor) × Config.Game.SlowDamageBonus` (congelado fica frágil); o `CombatService` usa o mesmo multiplicador no `Damage` do `HitConfirm`. Escudo de gelo absorve primeiro (ao quebrar: remove o bloco e efeito `"IceBreak"`). Guarda `LastHitBy` quando `attacker` é Player.
- `BrainrotService.ApplySlow(entity, factor, duration)`, `BrainrotService.Ignite(entity, dps, duration)`.
- `BrainrotService.Kill(entity, killer?, info)` — valor = `Formulas.BrainrotCoinValue × Formulas.EnchantCoinMult × teamStats.CoinMult`. Se `info.Source == "Turret"`: com `Config.Game.TurretCoinSplit == "Team"` divide `valor × teamStats.TurretCoinMult` igualmente entre os jogadores com run (`AddCoins(p, parte, "Turret")`); com `"Owner"` (padrão), se o dono está no servidor: `MatchService.AddCoins(dono, valor × teamStats.TurretCoinMult, "Turret")`; senão `CoinService.SpawnCoins(valor, pos)`. Explosão (chance `ExplodeChance`): dano `ExplosionDamageFraction × MaxHealth` nos vizinhos em `ExplosionBaseRadius + 3 × SizeFactor`, `Source = "Explosion"`, efeito `"Explosion"`, dispara `Exploded`. Encantamento Fogo: `Ignite` nos vizinhos em `IgniteRadius`. Receitas: `RecipeService.RollIngredient(killer, entity)` se o mapa tem receitas. Supremo: `SupremeService.OnKill(entity)` se o mapa tem supremo. Galáctico: `StateService.NotifyAll(..., "rare")`. Efeito `"Death"`. Stats do matador: `Kills.<Tier>`, `KillsTotal`, `Giants`, `Enchanted`, `Galactic`. Dispara `Killed`.
- Sinais: `BrainrotService.Killed: Signal(killer: Player?, entity, info)`, `BrainrotService.Exploded: Signal(player?)`, `BrainrotService.Spawned: Signal(entity)`.

### 8.6 `CombatService`
- `Net.OnEvent("Fire", ...)` com validação: personagem vivo; `origin` a ≤ 8 studs da cabeça; `directions` é tabela com 1..`stats.Projectiles` Vector3 (normaliza; rejeita NaN/zero); cadência por token bucket (recarga `FireRate × 1.25`/s, capacidade 3); calor (se `HeatCapacity > 0`: `Heat += HeatPerShot`; se ≥ capacidade → `Overheated = true` até esfriar para 30%; tiros com `Overheated` são ignorados).
- Para cada direção: `workspace:Spherecast(origin, BulletHitRadius × Caliber, dir × Range, params)` com `RaycastParams` `Exclude` = personagens, `workspace.Coins`, `workspace.Turrets` e os brainrots já atingidos por esse projétil; até `1 + Pierce` alvos. O tiro para ao atingir algo que não é brainrot.
- Dano = `stats.Damage × (crítico ? CritMult : 1)`, crítico com `CritChance`. `SplashRadius > 0`: 50% do dano em outros brainrots no raio (`Source = "Splash"`). `SlowPower > 0`: `ApplySlow(entity, 1 - SlowPower, SlowDuration)`.
- Stats: `Shots` (+1 por evento), `Crits`. Sinal `CombatService.Crit: Signal(player, count)`.
- `HitConfirm` para o atirador; `RemoteShot` para os outros (com a cor do tracer da skin equipada).
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
- Portal: `Config.Game.PortalDecision == "Host"` → só o host ativa (se ele saiu, o participante mais antigo presente; publicado em `Portal.Decider`, republicado em RunReady, PlayerAdded e PlayerRemoving; os outros recebem aviso); `"Majority"` → cada prompt/`VotePortal` registra voto; com votos ≥ `ceil(jogadores/2)` → `MatchService.CompleteAct()`. Votos de quem saiu são removidos.

### 8.9 `QuestService`
- `TakeQuest`: sem missão ativa e fora da espera; escolhe template aleatório cujos `Requires` o time atende; calcula alvo e recompensa (5.10); `Quest` do jogador.
- Progresso: `BrainrotService.Killed` (Kill, KillTier, KillGiant, KillEnchanted — só se `killer == player`), `MatchService.CoinsAdded` (Collect, exceto source `"Quest"`), `BrainrotService.Exploded` (Chain), `CombatService.Crit` (Crit). Ao completar: `AddCoins(..., "Quest")`, `IncrementStat("QuestsCompleted")`, Notify `"success"`, espera = `now + stats.QuestCooldown`.
- `AbandonQuest`: remove a missão e aplica metade da espera.

### 8.10 `TurretService` (só se `MapDef.HasTurrets`; senão Init/Start não fazem nada e os requests retornam `false, "Não há torretas neste mapa"`)
- Torreta: `{Id, OwnerUserId, Model, Position, RotY, Mode = "Valuable"|"Nearest", NextShot}`.
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
- Ao chegar em 1: uma vez só → `Net.FireAll("Ending", {Names = nomes dos jogadores, Duration = 30, SupremeName})`, `NotifyAll`, e depois de `Duration` s → `MatchService.CompleteAct()`.

### 8.13 `AchievementService` (lobby e partida)
- Checa conquistas `Stat` em `DataService.StatChanged` e em `DataService.ProfileLoaded` (retroativo). `Stat` usa caminho com ponto (`"Kills.Low"`).
- `AchievementService.FireEvent(player, eventName, data)` — `CompleteMap` (`data.Map`), `PlayWithFriends` (`data.Count >= Count`).
- `AchievementService.Award(player, id)` — se ainda não tem: grava `os.time()`, soma `Tokens`, `BadgeService:AwardBadge` se `BadgeId > 0`, `Notify` `"rare"` ("Conquista desbloqueada: ..."), `SyncProfile`.

### 8.14 `MonetizationService` (partida)
- Se `Config.Game.Gamepasses.Enabled` e o id > 0: `UserOwnsGamePassAsync` na entrada e `PromptGamePassPurchaseFinished`. `MonetizationService.HasPass(player, key) -> boolean`. Envia `Gamepasses`. Request `BuyGamepass(key)` → `PromptGamePassPurchase`. Quando muda → `StatService.Invalidate(player)`.

### 8.15 `SettingsService` (lobby e partida)
- `SaveSettings(tbl)`: valida e limita cada campo (`Sensitivity` 0.05–2, `InvertY` bool, `FOV` 60–110, `ToggleSprint` bool, `MusicVolume`/`SfxVolume` 0–1, `DamageNumbers` bool, `Keybinds` = mapa `actionId → nome de Enum.KeyCode válido`, só actions de `Config.Keybinds`); grava no perfil; `SyncProfile`.

### 8.16 `TravelService`
- `TravelService.SendToNewMatch(players, handoff) -> ok, err` — no Studio retorna `false, "O teleporte só funciona no jogo publicado. No Studio, mude Config.Game.StudioRole para \"Match\" para testar a partida."`. Senão: `TeleportService:ReserveServer(Config.Game.MatchPlaceId)` → `accessCode, privateServerId`; completa `handoff.AccessCode`, `handoff.PrivateServerId`, `handoff.Members = {userIds}`, `handoff.CreatedAt = os.time()`; grava no MemoryStore (`HandoffMapName`, chave `privateServerId`, expiração `HandoffExpiration`); para cada jogador grava `profile.LastMatch` e chama `DataService.ReleaseForTeleport`; `TeleportOptions` com `ReservedServerAccessCode` e `SetTeleportData({MapId = handoff.MapId})`; `TeleportService:TeleportAsync(MatchPlaceId, players, options)` com até `TeleportRetries` tentativas (espera 2 s, 4 s). Se falhar de vez → `DataService.Reacquire` em todos e retorna `false, mensagem`.
- `TravelService.SendToLobby(players)` — salva, libera e teleporta para `LobbyPlaceId` (no Studio: `Kick` com mensagem explicando).
- `TravelService.Reconnect(player) -> ok, err` — usa `profile.LastMatch` (dentro da janela) e teleporta com o `AccessCode` salvo.
- `TeleportService.TeleportInitFailed` → tenta de novo aquele jogador até 3 vezes; depois `Reacquire` e Notify de erro.
- Tela de carregamento: o cliente chama `TeleportService:SetTeleportGui` (ver LobbyUI).

### 8.17 `DebugService`
- Ligado se `RunService:IsStudio()` ou `Config.Game.DebugMode` ou `workspace:GetAttribute("DebugMode") == true`. Request `Debug(command, arg)` e também `player.Chatted` com `/comando arg`.
- Comandos: `coins <n>` (AddCoins "Debug"), `maxall` (maxa todos os upgrades do mapa e as prateleiras, depois `CheckCompletion`), `wave`, `nextact` (`CompleteAct`), `supreme <0..1>`, `ingredients` (5 de cada), `unlockall` (libera todos os mapas no perfil), `tokens <n>`, `reset` (zera o run do jogador).

---

## 9. Lobby

### 9.1 `LobbyService`
- `Init`: `ctx = MapBuilder.Build("Lobby")`; placar: `OrderedDataStore` `Config.Lobby.LeaderboardStoreName`, pontuação `floor(log10(TotalCoins + 1) * 1e6)` (moedas podem passar de 2^63); grava na entrada, ao sair e a cada `LeaderboardRefresh`; lê o top `LeaderboardSize` e escreve no `SurfaceGui` (nome + moedas `Abbrev(10^(score/1e6) - 1)`), com cache de nomes. Há mais dois placares com valor inteiro direto: `LeaderboardStoreName .. "_Kills"` (`Stats.KillsTotal`, painel `ctx.Leaderboards.Kills`) e `LeaderboardStoreName .. "_Acts"` (`Stats.ActsCompleted`, painel `ctx.Leaderboards.Acts`).
- Request `Reconnect` → `TravelService.Reconnect`.

### 9.2 `PartyService`
Grupo: `{Id, HostUserId, MapId, MaxPlayers, Privacy, Resume, Members = {userId} (ordem de entrada), Ready = {[userId] = true}, Invited = {[userId] = true}, State = "Waiting"|"Countdown"|"Teleporting", CountdownEnd}`.
- Regras: um jogador em no máximo um grupo; mapa precisa estar em `UnlockedMaps` do host; `Resume` só se o host tem `RunSaves[MapId]`; `MaxPlayers` entre `MinMaxPlayers` e `MaxPlayersLimit` e ≥ membros atuais; visibilidade/entrada: `Public` todos, `Friends` só amigos do host (`player:IsFriendsWith(hostUserId)` com cache), `Invite` só convidados; quem foi expulso (`PartyKick`) fica em `party.Kicked` e não entra de novo em nenhum modo (nem pelo convite do Roblox) até o host convidar de novo; o host sai → liderança para o membro mais antigo; grupo vazio some.
- `PartyStart(force)`: só host; todos prontos (o host conta como pronto) ou `force`; contagem de `CountdownSeconds` (cancela se alguém sai, desmarca pronto ou o host cancela); no fim → `TravelService.SendToNewMatch(jogadores, {MapId, HostUserId, MaxPlayers, Privacy, Resume})`; se falhar → volta a `"Waiting"` e Notify do erro.
- `PartyInvite(userId)`: host convida alguém do servidor → `Invited`, Notify para o convidado com o nome do host.
- Após qualquer mudança: envia `PartyState` a cada jogador do lobby:
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
- Sempre: `StateController`, `NotifyController`, `UI/UIKit` (se tiver Init), `PromptController`, `MobileController`, `MusicController`, `MovementController`, `UI/SettingsWindow`, `UI/DebugPanel`.
- Partida: `CameraController`, `EffectsController`, `WeaponController`, `PlacementController`, `HUDController`, `UI/StallWindow`, `UI/CauldronWindow`, `UI/SupremeWindow`, `EndingController`.
- Lobby: `UI/LobbyUI`.

### 10.2 `UI/UIKit.lua`
- `UIKit.Theme` (cores: fundo escuro translúcido, destaque rosa/roxo brainrot, verde para "pode comprar", vermelho para "sem moedas"; fontes `Enum.Font.FredokaOne` para títulos e `Enum.Font.GothamBold` para texto).
- `UIKit.New(className, props, children?) -> Instance`.
- `UIKit.GetScreen(name, displayOrder?) -> ScreenGui` (cria em `PlayerGui`, `ResetOnSpawn = false`, `IgnoreGuiInset = true`, com `UIScale` automático para telas pequenas).
- `UIKit.Window(name, title, size: UDim2) -> window` — `{Gui, Frame, Content (ScrollingFrame ou Frame), Open(), Close(), IsOpen(), OnClose: Signal}`; botão X; tecla Esc/B do controle fecha. Abrir chama `OpenModal(name)`, fechar `CloseModal(name)`.
- `UIKit.Button(props: {Text, Color, Size, Position, LayoutOrder, Parent}, onClick) -> TextButton` (com `UICorner`, `UIStroke`, animação de clique, som).
- `UIKit.Label(props)`, `UIKit.ProgressBar(parent, props) -> {Frame, Set(fraction, text?)}`, `UIKit.Corner(inst, radius)`, `UIKit.Stroke(inst, thickness, color)`, `UIKit.Padding(inst, px)`, `UIKit.List(parent, padding, direction)`, `UIKit.Grid(parent, cellSize, padding)`, `UIKit.Tween(inst, props, time?)`, `UIKit.Pop(inst)` (efeito de "pulo").
- Modais: `UIKit.OpenModal(name)`, `UIKit.CloseModal(name)`, `UIKit.IsAnyModalOpen()`, `UIKit.ModalChanged: Signal(isAnyOpen)`. Abrir uma janela fecha as outras janelas (só uma aberta por vez).
- `UIKit.PlaySound(key)` usa `Config.Game.Sounds[key]` (ignora se 0) com volume `Settings.SfxVolume`.

### 10.3 Controllers
- `NotifyController`: `Net.On("Notify")` → toasts empilhados no topo (cor por Kind, "rare" com brilho e som). `NotifyController.Show(text, kind, duration)`.
- `PromptController`: `ProximityPromptService.PromptTriggered` → se o prompt tem `ClientAction`, `PromptController.Dispatch(action, arg)`. `PromptController.Register(action, fn(arg, prompt))`. Também trata `Net.On("OpenUI")`. Aplica a tecla `Interact` (keybind) em todos os prompts de `workspace` (inclusive novos). Esconde o prompt padrão enquanto uma janela está aberta.
- `CameraController` (partida): câmera de primeira pessoa própria: `CameraType = Scriptable`, `MouseBehavior = LockCenter`, `UserInputService:GetMouseDelta()`, sensibilidade e Inverter Y das configurações, `FieldOfView` das configurações, pitch limitado a ±80°. Gira o personagem no yaw (`Humanoid.AutoRotate = false`). Controle: `Thumbstick2`. Toque: arrastar na metade direita da tela (toques que não começaram em GUI). Esconde o próprio corpo (`LocalTransparencyModifier = 1`). Quando `UIKit.IsAnyModalOpen()` → solta o mouse (`MouseBehavior = Default`, ícone visível) e para de girar. `CameraController.GetAimCFrame() -> CFrame`, `CameraController.SetEnabled(bool)` (usado no final). Balanço leve ao andar e "coice" com `CameraController.Kick(amount)`.
- `MovementController`: correr (segurar ou alternar, keybind `Sprint`, botão no celular) com `Config.Game.WalkSpeed/SprintSpeed`; se o jogador mudou teclas de movimento (Forward/Back/Left/Right/Jump), desliga os controles padrão de teclado (`PlayerModule:GetControls():Disable()` só quando não é toque) e move com `Humanoid:Move(direção relativa à câmera)`; calor do deserto (fora da sombra do oásis por mais de `DesertHeat.SafeTime` s sem `HeatImmunity` → velocidade × `SlowMultiplier` e `ColorCorrection` alaranjada). O centro/raio do oásis vêm de atributos `OasisCenter`/`OasisRadius` em `workspace.Map` (o builder do Deserto grava esses atributos).
- `MobileController`: se `TouchEnabled`, cria botões grandes "Atirar" (segurar), "Correr" e, na partida com torretas, "Torreta". `MobileController.IsFireHeld() -> boolean`, `MobileController.FireChanged: Signal(bool)`.
- `MusicController`: toca `Config.Game.Music[mapId ou "Lobby"]` em loop se ≠ 0, volume `MusicVolume`; `MusicController.Play(key)` (usado no final com `"Ending"`).
- `WeaponController` (partida): atira segurando o botão (mouse 1, R2, botão do celular) quando nenhum modal está aberto, não está colocando torreta e não está superaquecido (`Heat.Overheated`). Intervalo `1 / stats.FireRate`. Direções: `stats.Projectiles` raios em leque horizontal (abertura total `min(stats.Spread × (n-1), 40)` graus) mais um desvio aleatório pequeno. Envia `Net.Fire("Fire", origin = câmera, dirs, shotId)`. Visual local imediato: arma na câmera (viewmodel simples feito de Parts, cor da skin), clarão, som, tracer até o ponto atingido (raycast local), `CameraController.Kick`. `HitConfirm` → hitmarker (`HUDController.ShowHitmarker(crit)`) e números de dano (se `DamageNumbers`) via `EffectsController`.
- `EffectsController`: `Effect` (explosão de partículas na morte, anel de explosão, poeira no spawn, gelo quebrando, confete), `RemoteShot` e `TurretShots` (tracers), `CoinPopup` (número "+1,2K" subindo e som), números de dano. API: `EffectsController.Tracer(from, to, color, width?)`, `EffectsController.DamageNumber(position, amount, crit)`, `EffectsController.Burst(position, color, size)`. Efeitos locais ficam numa pasta `workspace.ClientEffects` criada pelo cliente; tudo com limite e reciclagem.
- `HUDController` (partida): moedas (com animação), renda/s, brainrots vivos, recarga do quadro, mira no centro com hitmarker, missão ativa com barra, barra de calor (Deserto), barra do Supremo (Deserto), lista do time, botões (Configurações, Voltar ao lobby com confirmação, Receitas no Deserto, Colocar torreta quando houver torretas), aviso do portal/votos, painel de "Buffs" ativos. `HUDController.ShowHitmarker(crit)`.
- `PlacementController` (Inverno/Deserto): `PlacementController.Enter()` → fantasma verde/vermelho da torreta onde a mira aponta no chão (até 60 studs), `Rotate` (R) gira 45°, clique/R2 confirma (`PlaceTurret`), `Cancel` (Q)/B cancela. No celular, botões Confirmar/Cancelar. `PlacementController.IsActive()`.
- `EndingController`: `Net.On("Ending")` → desliga a câmera do jogador, câmera sobe mostrando o Supremo na frente do sol, tela escurece, música `"Ending"`, créditos rolando com `Names` e "Obrigado por jogar!", dura `Duration`.

### 10.4 Janelas
- `StallWindow`: `PromptController.Register("Stall", fn)`. Mostra os upgrades daquela barraca no mapa atual, agrupados por prateleira (prateleiras acima de `ShelfLevel` aparecem trancadas com cadeado e o custo para liberar). Cada linha: nome, descrição, `nível/máx`, efeito atual → próximo (`Formulas`/`NumberFormat.Stat`), custo (verde se dá, vermelho se não), botões `x1`, `x10`, `Máx`. Botão "Melhorar Barraca (prateleira N)" com o custo (`BuyShelf`), ativo quando o global `ShelfReady` é `true` (o servidor decide, porque a regra `AnyPlayer` conta até runs de quem já saiu; o cliente calcula com `PlayerUpgrades`/`TeamUpgrades` só a lista do texto "Faltam N: ..."). Na barraca `Quest`, um painel no topo: missão ativa com progresso ou botão "Pegar missão" / tempo de espera, e "Abandonar". Na barraca `Turret`: botões "Colocar torreta" (fecha a janela e chama `PlacementController.Enter()`) e "Chamar torretas de volta", e contagem `Placed/Max`. Na barraca `Growth`: progresso do Supremo e botão para abrir a `SupremeWindow`. Atualiza sozinha quando o estado muda.
- `CauldronWindow`: `Register("Cauldron")`. Inventário de ingredientes, 3 espaços de seleção, custo da receita (se reconhecida no Livro), botão "Cozinhar" (`Craft`), aba "Livro de Receitas" (conhecidas: nome, ingredientes, efeito; desconhecidas: `???` + dica). Também abre pelo botão do HUD.
- `SupremeWindow`: `Register("Supreme")`. Barra de progresso ("X% do céu"), altura, botões "Alimentar 10% / 50% / 100% das moedas" (`FeedSupreme`).
- `SettingsWindow`: `Register("Settings")`. Sensibilidade, Inverter Y, FOV, Alternar corrida, volumes, números de dano, e remapear teclas (clica e aperta a nova tecla; "Restaurar padrão"). Salva com `SaveSettings` (debounce de 1 s). As outras partes leem de `Profile.Settings`.
- `DebugPanel`: se `workspace:GetAttribute("DebugEnabled")`, botão "DEBUG" que abre painel com botões para cada comando do DebugService.
- `LobbyUI` (pode ser dividido em vários ModuleScripts dentro de `UI/`, com prefixo `Lobby`): botões laterais (Criar Partida, Partidas Abertas, Loja, Conquistas, Configurações, Reconectar se `CanReconnect`), janela **Criar Partida** (mapas de `Config.Maps.Order` com cadeado se não liberado, 1..8 jogadores, privacidade, "Continuar partida salva" se `RunSaves[mapa]`), janela **Meu Grupo** (membros com foto `GetUserThumbnailAsync`, prontos, botões do host: trocar mapa/limite/privacidade, expulsar, passar liderança, convidar jogador do servidor, convite do Roblox via `SocialService:PromptGameInvite`, iniciar/forçar/cancelar; contagem regressiva grande), janela **Partidas Abertas** (lista do `PartyState.Parties` com botão Entrar ou o motivo do bloqueio), popup de convite recebido (Entrar/Recusar), **Loja** de skins (tokens), **Conquistas e Estatísticas**. Registra `CreateParty`, `PartyList`, `Shop`, `Achievements`. Quando o grupo entra em `"Teleporting"`, chama `TeleportService:SetTeleportGui` com uma tela de carregamento com o nome e a cor do mapa.
