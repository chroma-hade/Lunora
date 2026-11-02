# Lunora

A tiny game framework for Roblox! You hand it your modules, it starts them up, and your server and client can call each other by name. The whole thing is one ModuleScript, under 500 lines.

I use it for my own games☆

## Getting it

Grab `Lunora.rbxm` from the [releases page](https://github.com/chroma-hade/Lunora/releases) and put it in a folder inside ReplicatedStorage, like `ReplicatedStorage.Packages`.

Not straight into ReplicatedStorage itself, though! Lunora makes a folder there called `Lunora` for its remotes, and the two would clash.

If you use Wally, add it to your `wally.toml`:

```toml
[dependencies]
Lunora = "chroma-hade/lunora@1.0.3"
```

Or just copy `src/init.luau` into your project.

## Setting it up

One script on each side, that's it! Tell Lunora where your modules are, then start it.

```lua
-- ServerScriptService/Server.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Lunora = require(ReplicatedStorage.Packages.Lunora)
Lunora.AddModules(ServerStorage.Services)

Lunora.Start()
```

```lua
-- StarterPlayerScripts/Client.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lunora = require(ReplicatedStorage.Packages.Lunora)
Lunora.AddModules(script.Parent.Controllers)

Lunora.Start()
```

Every ModuleScript in those folders gets loaded, nested folders too. Lunora keeps track of them by name, so give each one a different name. If two share a name, Lunora warns you and keeps the first one.

If a ModuleScript sits directly inside another ModuleScript, Lunora leaves it alone. Handy for private helpers☆

## A module

A module is just a table. `Init` and `Start` are optional.

```lua
local ShopService = {
    Public = {},
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Lunora = require(ReplicatedStorage.Packages.Lunora)

local ShopController = Lunora.Load("ShopController")

local CashService = nil

local Prices = {
    Sword = 100,
    Shield = 80,
}

local function GetPrice(Player: Player, ItemName: string): number?
    return Prices[ItemName]
end

local function Buy(Player: Player, ItemName: string)
    local Price = Prices[ItemName]
    if not Price then
        return
    end
    if not CashService.TakeCash(Player, Price) then
        return
    end
    ShopController.ShowPurchase(ItemName):Fire(Player)
end

function ShopService.Init()
    CashService = Lunora.LoadSelf("CashService")
end

function ShopService.Start()
    Players.PlayerAdded:Connect(function(Player: Player)
        ShopController.ShowPrices(Prices):Fire(Player)
    end)
end

ShopService.Public.GetPrice = GetPrice
ShopService.Public.Buy = Buy

return ShopService
```

`Init` runs on every module first. Use it to grab other modules on the same side with `LoadSelf`, and that's about it.

`Start` only runs once every `Init` is done, so by the time it runs, `CashService` is already there. This is where your module actually comes alive! Hook up events, start loops, send things to clients. Each `Start` gets its own thread, so one slow module won't hold up the others.

Don't count on modules starting in any particular order.

`Prices[ItemName]` doubles as the check on what the client sent. If someone sends an item that isn't on the list, `Buy` just stops there☆

## Talking across

`Lunora.Load("Name")` gives you the module on the other side. Call a function on it, then `:Fire()` to send it off or `:Invoke()` to wait for an answer.

From the client:

```lua
local ShopService = Lunora.Load("ShopService")
local Price = ShopService.GetPrice("Sword"):Invoke()
ShopService.Buy("Sword"):Fire()
```

On the server that runs `ShopService.Public.Buy(Player, "Sword")`. Only functions inside `Public` can be reached from a client, and the player always comes first. Anything else a client sends could be made up, so always check it!

From the server:

```lua
local ShopController = Lunora.Load("ShopController")
ShopController.ShowPurchase("Sword"):Fire(Player)
ShopController.Refresh():Fire()
```

`:Fire(Player)` goes to one player and `:Fire()` goes to everyone. `:Invoke(Player)` needs a player, and if that client errors you get `nil` back instead of an error on the server.

Anything you send before your modules start gets dropped with a warning, and that includes sending from inside `Init`.

## Signals

For events that stay on one side, no remotes involved☆

```lua
local Damaged = Lunora.NewSignal()

local Connection = Damaged:Connect(function(Victim, Amount)
    print(Victim, Amount)
end)

Damaged:Fire(Victim, 10)

Connection:Disconnect()
```

Each listener runs in its own thread. `Damaged:Wait()` waits for the next `Fire` and gives you its arguments, and `Damaged:Destroy()` drops every listener.

## Everything

That's the whole API!

| | |
|---|---|
| `Lunora.AddModules(Folder)` | Loads every ModuleScript under the folder |
| `Lunora.Start()` | Sets up the remotes, then runs every `Init`, then every `Start` |
| `Lunora.Load(Name)` | A module on the other side |
| `Lunora.LoadSelf(Name)` | A module on the same side |
| `Lunora.NewSignal()` | A new same-side signal |
| `Lunora.IsReady()` | Whether `Start` has run yet |
| `Lunora.OnReady()` | Waits until `Start` has run |
| `Lunora.Stop()` | Calls `Stop` on modules that have one and disconnects the remotes |

The client waits up to five seconds for the server's remote folder before it gives up.

## License

MIT, so go wild☆ Just keep the license file around.
