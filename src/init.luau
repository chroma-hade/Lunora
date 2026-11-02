local Lunora = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IsServer = RunService:IsServer()

local Started = false

local Modules = {}
local Connections = {}
local ReadyWaiters = {}

local RemoteEvent: RemoteEvent
local RemoteFunction: RemoteFunction

local function GetFolder(): Folder?
	return ReplicatedStorage:FindFirstChild("Lunora")
end

local function WaitFolder(): Folder?
	local Folder = GetFolder()
	if Folder then
		return Folder
	end

	local Count = 0
	while not Folder and Count < 5 do
		task.wait(1)
		Count += 1
		Folder = GetFolder()
	end

	return Folder
end

local function CreateFolder(): Folder
	local Existing = GetFolder()
	if Existing then
		return Existing
	end

	local Folder = Instance.new("Folder")
	Folder.Name = "Lunora"

	local Function = Instance.new("RemoteFunction")
	Function.Name = "RemoteFunction"
	Function.Parent = Folder

	local Event = Instance.new("RemoteEvent")
	Event.Name = "RemoteEvent"
	Event.Parent = Folder

	Folder.Parent = ReplicatedStorage
	return Folder
end

local function ResolveRemotes()
	local Folder = WaitFolder()
	if not Folder then
		warn("[Lunora]: Failed to find network folder.")
		return false
	end

	RemoteEvent = Folder:FindFirstChildOfClass("RemoteEvent")
	RemoteFunction = Folder:FindFirstChildOfClass("RemoteFunction")

	return RemoteEvent ~= nil and RemoteFunction ~= nil
end

local function ImportModule(Module: ModuleScript)
	if Modules[Module.Name] then
		return Modules[Module.Name]
	end

	local Success, Result = pcall(require, Module)
	if not Success then
		warn(string.format("[Lunora]: Failed to require '%s'. %s", Module.Name, tostring(Result)))
		return nil
	end

	if typeof(Result) ~= "table" then
		warn(string.format("[Lunora]: Module '%s' did not return a table.", Module.Name))
		return nil
	end

	Modules[Module.Name] = Result
	return Result
end

local function CollectFolder(Folder: Folder)
	for _, Object: Instance in Folder:GetDescendants() do
		if not Object:IsA("ModuleScript") then
			continue
		end
		if Object.Parent and Object.Parent:IsA("ModuleScript") then
			continue
		end
		ImportModule(Object)
	end
end

local function ResolvePublic(Module: { [string]: any }, Index: string): ((...any) -> any)?
	local Public = Module.Public
	if typeof(Public) ~= "table" then
		return nil
	end

	local Function = Public[Index]
	if typeof(Function) ~= "function" then
		return nil
	end

	return Function
end

local function NewBind(Name: string, Index: string, ...)
	local Bind = {}
	local Data = table.pack(...)

	local function BuildPayload()
		return {
			ModuleName = Name,
			Index = Index,
			InData = Data,
		}
	end

	function Bind:Fire(Player: Player?)
		if not Started then
			warn(string.format("[Lunora]: Fire called before Start. (%s.%s)", Name, Index))
			return
		end
		if not IsServer then
			RemoteEvent:FireServer(BuildPayload())
		elseif Player then
			RemoteEvent:FireClient(Player, BuildPayload())
		else
			RemoteEvent:FireAllClients(BuildPayload())
		end
	end

	function Bind:Invoke(Player: Player?)
		if not Started then
			warn(string.format("[Lunora]: Invoke called before Start. (%s.%s)", Name, Index))
			return nil
		end

		if not IsServer then
			return RemoteFunction:InvokeServer(BuildPayload())
		end

		if not Player then
			warn("[Lunora]: Invoke from server requires a player.")
			return nil
		end

		local Success, Result = pcall(RemoteFunction.InvokeClient, RemoteFunction, Player, BuildPayload())
		if not Success then
			warn(string.format("[Lunora]: InvokeClient failed. %s", tostring(Result)))
			return nil
		end

		return Result
	end

	return Bind
end

local function NewSender(Name: string)
	return setmetatable({}, {
		__index = function(_, Index: string)
			return function(...)
				return NewBind(Name, Index, ...)
			end
		end,
	})
end

local function ResolvePayload(Data: any): (string?, string?, { any })
	if typeof(Data) ~= "table" then
		return nil, nil, {}
	end

	local ModuleName = Data.ModuleName
	local Index = Data.Index
	if typeof(ModuleName) ~= "string" or typeof(Index) ~= "string" then
		return nil, nil, {}
	end

	local InData = Data.InData
	if typeof(InData) ~= "table" then
		InData = { n = 0 }
	end

	return ModuleName, Index, InData
end

local function ListenFromClient(Player: Player, Data: any)
	local ModuleName, Index, InData = ResolvePayload(Data)
	if not ModuleName then
		return nil
	end

	local Module = Modules[ModuleName]
	if not Module then
		warn(string.format("[Lunora]: Module '%s' not found.", ModuleName))
		return nil
	end

	local Function = ResolvePublic(Module, Index)
	if not Function then
		warn(string.format("[Lunora]: '%s.Public.%s' is not callable.", ModuleName, Index))
		return nil
	end

	return Function(Player, table.unpack(InData, 1, InData.n or #InData))
end

local function ListenFromServer(Data: any)
	local ModuleName, Index, InData = ResolvePayload(Data)
	if not ModuleName then
		return nil
	end

	local Module = Modules[ModuleName]
	if not Module then
		warn(string.format("[Lunora]: Module '%s' not found.", ModuleName))
		return nil
	end

	local Function = Module[Index]
	if typeof(Function) ~= "function" then
		warn(string.format("[Lunora]: '%s.%s' is not callable.", ModuleName, Index))
		return nil
	end

	return Function(table.unpack(InData, 1, InData.n or #InData))
end

local function ConnectServer()
	table.insert(Connections, RemoteEvent.OnServerEvent:Connect(ListenFromClient))
	RemoteFunction.OnServerInvoke = ListenFromClient
end

local function ConnectClient()
	table.insert(Connections, RemoteEvent.OnClientEvent:Connect(ListenFromServer))
	RemoteFunction.OnClientInvoke = ListenFromServer
end

local function NewSignal()
	local Signal = {}
	local Listeners = {}

	function Signal:Connect(Callback: (...any) -> ())
		local Connection = { Connected = true, Callback = Callback }
		table.insert(Listeners, Connection)

		function Connection:Disconnect()
			Connection.Connected = false
			local Index = table.find(Listeners, Connection)
			if Index then
				table.remove(Listeners, Index)
			end
		end
		return Connection
	end

	function Signal:Fire(...)
		local Snapshot = table.clone(Listeners)
		for _, Connection in Snapshot do
			if not Connection.Connected then
				continue
			end
			task.spawn(Connection.Callback, ...)
		end
	end

	function Signal:Wait()
		local Thread = coroutine.running()
		local Connection
		Connection = Signal:Connect(function(...)
			Connection:Disconnect()
			task.spawn(Thread, ...)
		end)
		return coroutine.yield()
	end

	function Signal:Destroy()
		table.clear(Listeners)
	end

	return Signal
end

local function RunInit()
	for _, Module in Modules do
		local Function = Module.Init
		if typeof(Function) ~= "function" then
			continue
		end
		local Success, Error = pcall(Function, Module)
		if not Success then
			warn(string.format("[Lunora]: Init failed. %s", tostring(Error)))
		end
	end
end

local function RunStart()
	for _, Module in Modules do
		local Function = Module.Start
		if typeof(Function) ~= "function" then
			continue
		end
		task.spawn(function()
			local Success, Error = pcall(Function, Module)
			if not Success then
				warn(string.format("[Lunora]: Start failed. %s", tostring(Error)))
			end
		end)
	end
end

function Lunora.AddModules(Folder: Folder)
	if typeof(Folder) ~= "Instance" or not Folder:IsA("Folder") then
		warn("[Lunora]: AddModules expects a Folder.")
		return
	end
	CollectFolder(Folder)
end

function Lunora.LoadSelf(Name: string)
	local Module = Modules[Name]
	if not Module then
		warn(string.format("[Lunora]: LoadSelf failed, '%s' not registered.", Name))
		return nil
	end
	return Module
end

function Lunora.Load(Name: string)
	return NewSender(Name)
end

function Lunora.NewSignal()
	return NewSignal()
end

function Lunora.IsReady(): boolean
	return Started
end

function Lunora.OnReady()
	if Started then
		return
	end
	local Thread = coroutine.running()
	table.insert(ReadyWaiters, Thread)
	coroutine.yield()
end

function Lunora.Start()
	if Started then
		warn("[Lunora]: Already started.")
		return
	end

	if IsServer then
		CreateFolder()
	end

	if not ResolveRemotes() then
		warn("[Lunora]: Failed to start, remote objects missing.")
		return
	end

	if IsServer then
		ConnectServer()
	else
		ConnectClient()
	end

	Started = true

	for _, Thread in ReadyWaiters do
		task.spawn(Thread)
	end
	table.clear(ReadyWaiters)

	RunInit()
	RunStart()

	print(string.format("[Lunora]: Started on %s.", IsServer and "Server" or "Client"))
end

function Lunora.Stop()
	if not Started then
		return
	end

	for _, Module in Modules do
		local Function = Module.Stop
		if typeof(Function) ~= "function" then
			continue
		end
		local Success, Error = pcall(Function, Module)
		if not Success then
			warn(string.format("[Lunora]: Stop failed. %s", tostring(Error)))
		end
	end

	for _, Connection in Connections do
		if Connection.Connected then
			Connection:Disconnect()
		end
	end
	table.clear(Connections)

	if IsServer and RemoteFunction then
		RemoteFunction.OnServerInvoke = nil :: any
	elseif RemoteFunction then
		RemoteFunction.OnClientInvoke = nil :: any
	end

	Started = false
end

return Lunora
