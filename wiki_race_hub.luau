-- Wiki Race Hub (WindUI)
-- Auto-Win: drives the game's own navigation state machine so the GUI stays in sync.
-- Stats / status log: live round + action log.

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local NavigateArticle = Remotes:WaitForChild("NavigateArticle", 15)
local BrowserNavigate = Remotes:WaitForChild("BrowserNavigate", 15)
local RoundStarted = Remotes:WaitForChild("RoundStarted", 15)
local ArticleUpdated = Remotes:WaitForChild("ArticleUpdated", 15)
local RoundStateChanged = Remotes:WaitForChild("RoundStateChanged", 15)

-- ---------------------------------------------------------------------------
-- Settings + runtime state (kept in STATE so live-reloads keep the toggle on)
-- ---------------------------------------------------------------------------
local cfg = STATE.cfg or {
	Enabled = false,
	Backtrack = true,
	ClickDelay = 0.35,
	HopCap = 40,
	BackCap = 8,
}
cfg.DirectJump = false
STATE.cfg = cfg

local rt = STATE.rt or {
	GameState = nil,
	Target = nil,
	Visited = {},
	Rejected = {},
	Stack = {},
	Hops = 0,
	Backtracks = 0,
	PendingReq = nil,
	NavAwaiting = false,
	Busy = false,
	RoundActive = false,
	WinReached = false,
	Log = {},
	Temp = nil,
	CurrentTitle = "",
	LastError = "",
	LogStop = false,
}
STATE.rt = rt
local st = rt

local maxLogLines = 60
local autoThread = nil
local paragraphStatus = nil
local paragraphLog = nil

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local function renderLog()
	if not paragraphLog then
		return
	end
	local tail = st.Log
	if #tail > maxLogLines then
		local startI = #tail - maxLogLines + 1
		local out = {}
		for i = startI, #tail do
			out[#out + 1] = tail[i]
		end
		tail = out
	end
	paragraphLog:SetDesc(table.concat(tail, "\n") or "No activity yet.")
end

local function log(msg)
	local clock = os.clock()
	local mm = math.floor(clock / 60)
	local ss = math.floor(clock % 60)
	local line = ("[%02d:%02d] %s"):format(mm, ss, msg)
	table.insert(st.Log, line)
	if #st.Log > maxLogLines then
		table.remove(st.Log, 1)
	end
	renderLog()
end

-- ---------------------------------------------------------------------------
-- State table discovery (game-owned state machine)
-- ---------------------------------------------------------------------------
local function findGameState()
	if st.GameState then
		return st.GameState
	end
	local ok, tbl = pcall(function()
		return filtergc("table", {
			Keys = {
				"NextRequestId",
				"NavigationPending",
				"PlayerRows",
				"RoundState",
				"RenderArticle",
			},
		}, true)
	end)
	if ok and typeof(tbl) == "table" and type(tbl.RoundState) == "string" then
		st.GameState = tbl
		return tbl
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Round recovery (reload mid-round: RoundStarted already fired, so rebuild
-- Target from the game's own state table using title/summary only)
-- ---------------------------------------------------------------------------
local function recoverRound(gs)
	if st.Target or not gs then
		return
	end
	if gs.RoundState ~= "Playing" or not gs.IsParticipant then
		return
	end
	local title = gs.CurrentTargetTitle
	if type(title) ~= "string" or title == "" then
		return
	end
	local summary = gs.CurrentTargetSummary
	st.Target = {
		Id = nil,
		Title = title,
		Summary = type(summary) == "string" and summary or nil,
	}
	recomputeTargetTokens()
	st.RoundActive = true
	st.WinReached = false
	st.Hops = 0
	st.Backtracks = 0
	st.Visited = {}
	st.Rejected = {}
	st.Stack = {}
	st.PendingReq = nil
	st.NavAwaiting = false
	st.LastError = ""
	st.LogStop = false
	log("RECOVERED round -> target: " .. title .. " (direct jump disabled, Id unknown)")
end

-- ---------------------------------------------------------------------------
-- Status paragraph
-- ---------------------------------------------------------------------------
local function refreshStatus()
	if not paragraphStatus then
		return
	end
	local gs = findGameState()
	local lines = {}
	table.insert(lines, ("Auto-win: %s"):format(cfg.Enabled and "ON" or "OFF"))
	table.insert(lines, ("Round: %s | Temp: %s"):format(
		(gs and gs.RoundState) or "?",
		(st.Temp and tostring(st.Temp)) or "-"
	))
	if st.Target then
		table.insert(lines, ("Target: %s"):format(st.Target.Title))
	end
	table.insert(lines, ("Current: %s"):format(
		st.CurrentTitle ~= "" and st.CurrentTitle or (gs and gs.CurrentArticleId) or "-"
	))
	table.insert(lines, ("Hops: %d | Backtracks: %d%s"):format(
		st.Hops,
		st.Backtracks,
		st.WinReached and " | WON" or ""
	))
	paragraphStatus:SetDesc(table.concat(lines, "\n"))
end

-- ---------------------------------------------------------------------------
-- GUI helpers
-- ---------------------------------------------------------------------------
local function guiRoot()
	local pgui = LocalPlayer:FindFirstChild("PlayerGui")
	if not pgui then
		return nil
	end
	local candidates = { "LocalLaptopSurfaceGui", "WikiLaptopGui" }
	for _, name in candidates do
		local root = pgui:FindFirstChild(name)
		local mf = root and root:FindFirstChild("MainFrame")
		if mf and mf:FindFirstChild("BrowserWindow") then
			return root
		end
	end
	return nil
end

local function articleContent()
	local root = guiRoot()
	if not root then
		return nil
	end
	local mf = root:FindFirstChild("MainFrame")
	local bw = mf and mf:FindFirstChild("BrowserWindow")
	local af = bw and bw:FindFirstChild("ArticleFrame")
	local vp = af and af:FindFirstChild("WikiPageViewport")
	local sf = vp and vp:FindFirstChild("ScrollingFrame")
	local ac = sf and sf:FindFirstChild("ArticleContent")
	return ac
end

local function collectLinks()
	local links = {}
	local ac = articleContent()
	if not ac then
		return links
	end
	for _, d in ac:GetDescendants() do
		if d:IsA("TextButton") then
			local id = d:GetAttribute("TargetArticleId")
			if type(id) == "string" and id ~= "" and not links[id] then
				links[id] = d.Text or d.Name
			end
		end
	end
	return links
end

-- ---------------------------------------------------------------------------
-- Similarity scoring (link text vs target)
-- ---------------------------------------------------------------------------
local STOP = {
	["the"] = true, ["and"] = true, ["for"] = true, ["with"] = true, ["from"] = true,
	["this"] = true, ["that"] = true, ["its"] = true, ["are"] = true, ["was"] = true,
	["were"] = true, ["you"] = true, ["your"] = true, ["which"] = true, ["who"] = true,
	["whom"] = true, ["where"] = true, ["when"] = true, ["have"] = true, ["has"] = true,
	["had"] = true, ["but"] = true, ["not"] = true, ["all"] = true, ["any"] = true,
	["can"] = true, ["will"] = true, ["into"] = true, ["onto"] = true, ["upon"] = true,
	["their"] = true, ["there"] = true, ["they"] = true, ["them"] = true, ["some"] = true,
	["may"] = true, ["more"] = true, ["most"] = true, ["than"] = true, ["about"] = true,
}

local function tokens(s)
	local out = {}
	for w in tostring(s):lower():gmatch("%a+") do
		if #w >= 3 and not STOP[w] then
			out[#out + 1] = w
		end
	end
	return out
end

local targetTokens = nil

local function recomputeTargetTokens()
	targetTokens = nil
	if not st.Target then
		return
	end
	local t = st.Target
	local all = {}
	for _, w in tokens(t.Title) do
		all[w] = (all[w] or 0) + 1
	end
	if type(t.Summary) == "string" then
		for _, w in tokens(t.Summary) do
			all[w] = (all[w] or 0) + 0.5
		end
	end
	targetTokens = all
end

local function scoreLink(text)
	if not targetTokens then
		return 0
	end
	local score = 0
	for _, w in tokens(text) do
		local v = targetTokens[w]
		if v then
			score = score + (0.5 + v)
		end
	end
	if score > 0 and st.Temp and st.Temp <= 1 then
		score = score * 1.6
	end
	return score
end

-- ---------------------------------------------------------------------------
-- Navigation (replicates the game's own requestNavigation exactly)
-- ---------------------------------------------------------------------------
local function beginPendingNav(gs)
	gs.NextRequestId = gs.NextRequestId + 1
	gs.PendingRequestId = gs.NextRequestId
	gs.NavigationPending = true
	return gs.PendingRequestId
end

local function navigateTo(gs, targetId)
	if not gs or gs.NavigationPending or gs.RoundState ~= "Playing" or not gs.IsParticipant then
		return false
	end
	local req = beginPendingNav(gs)
	NavigateArticle:FireServer(gs.CurrentArticleId, targetId, req)
	return true
end

local function navigateBack(gs)
	if not gs or gs.NavigationPending or gs.RoundState ~= "Playing" or not gs.IsParticipant then
		return false
	end
	if gs.CanGoBack ~= true then
		return false
	end
	local req = beginPendingNav(gs)
	BrowserNavigate:FireServer("Back", req)
	return true
end

local function awaitSettle(targetId, timeout)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		local gs = findGameState()
		if gs and not gs.NavigationPending then
			if gs.CurrentArticleId == targetId then
				return true
			end
			return false
		end
		task.wait(0.05)
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Round lifecycle hooks
-- ---------------------------------------------------------------------------
STATE.connect(RoundStarted.OnClientEvent, function(p)
	st.Target = nil
	if type(p) == "table" then
		local t = p.TargetArticle
		if type(t) == "table" and type(t.Id) == "string" then
			st.Target = { Id = t.Id, Title = t.Title or t.Id, Summary = t.Description }
			recomputeTargetTokens()
			st.Visited = {}
			st.Rejected = {}
			st.Stack = {}
			st.Hops = 0
			st.Backtracks = 0
			st.WinReached = false
			st.PendingReq = nil
			st.NavAwaiting = false
			st.RoundActive = true
			st.LastError = ""
			st.LogStop = false
			log("ROUND START -> target: " .. (t.Title or t.Id))
		end
	end
	refreshStatus()
end)

STATE.connect(ArticleUpdated.OnClientEvent, function(p)
	if type(p) == "table" then
		if type(p.Temperature) == "number" then
			st.Temp = p.Temperature
		end
		local a = p.Article
		if type(a) == "table" then
			st.CurrentTitle = a.Title or st.CurrentTitle
			if st.Target and (a.Id ~= nil and a.Id == st.Target.Id) then
				st.WinReached = true
				st.RoundActive = false
				log("REACHED TARGET: " .. (a.Title or a.Id))
			elseif st.Target and st.Target.Id == nil and type(a.Title) == "string" and a.Title == st.Target.Title then
				st.WinReached = true
				st.RoundActive = false
				log("REACHED TARGET (by title): " .. a.Title)
			end
		end
		if p.Error or p.ErrorCode then
			st.LastError = p.Message or p.Error or "navigation rejected"
		end
	end
	refreshStatus()
end)

STATE.connect(RoundStateChanged.OnClientEvent, function(newState, _p)
	if type(newState) == "string" then
		if newState ~= "Playing" and st.RoundActive then
			log("Round state -> " .. newState)
			if st.WinReached then
				log("WIN: finished in " .. st.Hops .. " hops")
			end
			st.RoundActive = false
		end
	end
	refreshStatus()
end)

-- ---------------------------------------------------------------------------
-- Auto-win loop
-- ---------------------------------------------------------------------------
local function autoLoop()
	while STATE.alive() do
		task.wait(0.1)
		if not (cfg.Enabled and st.RoundActive and st.Target and not st.WinReached) then
			if cfg.Enabled then
				refreshStatus()
			end
			continue
		end
		local gs = findGameState()
		if not gs or gs.RoundState ~= "Playing" or not gs.IsParticipant or not gs.CurrentArticleId then
			task.wait(0.2)
			continue
		end
		if gs.NavigationPending then
			task.wait(0.1)
			continue
		end
		if st.Hops >= cfg.HopCap then
			if not st.LogStop then
				st.LogStop = true
				log("Hop cap reached (" .. cfg.HopCap .. "); waiting for round end")
			end
			task.wait(0.5)
			continue
		end

		local currentId = gs.CurrentArticleId

		if st.Target.Id ~= nil and st.Target.Id == currentId then
			st.WinReached = true
			log("ON TARGET automatically")
			task.wait(0.5)
			continue
		end

		local links = collectLinks()
		if not next(links) then
			task.wait(0.2)
			continue
		end

		local chosen = nil

		if st.Target.Id ~= nil and links[st.Target.Id] and not st.Rejected[st.Target.Id] then
			chosen = st.Target.Id
		end

		if cfg.DirectJump and st.Target.Id ~= nil and not chosen and not st.Rejected[st.Target.Id] then
			chosen = st.Target.Id
		end

		if not chosen then
			local bestId, best = nil, -1
			for id, text in links do
				if not st.Visited[id] and not st.Rejected[id] then
					local s = scoreLink(text)
					if s > best then
						best = s
						bestId = id
					end
				end
			end
			if bestId then
				chosen = bestId
			end
		end

		if not chosen and cfg.Backtrack and st.Backtracks < cfg.BackCap then
			local ok = navigateBack(gs)
			if ok then
				st.Backtracks = st.Backtracks + 1
				log("Backtracking (dead end)")
				task.wait(cfg.ClickDelay)
				continue
			end
		end

		if not chosen then
			st.LogStop = true
			log("Stuck: no reachable links left")
			task.wait(0.5)
			continue
		end

		local ok = navigateTo(gs, chosen)
		if not ok then
			task.wait(0.2)
			continue
		end
		st.PendingReq = gs.PendingRequestId
		st.Hops = st.Hops + 1
		st.Visited[currentId] = true
		table.insert(st.Stack, currentId)
		log("Hop " .. st.Hops .. " -> " .. (links[chosen] or chosen))

		local settledOk = awaitSettle(chosen, 10)
		local gs2 = findGameState()
		if not settledOk or (gs2 and gs2.CurrentArticleId == currentId) then
			st.Rejected[chosen] = true
			st.Hops = st.Hops - 1
			if st.LastError ~= "" then
				log("Navigation rejected: " .. st.LastError)
				st.LastError = ""
			else
				log("Navigation did not land on: " .. chosen)
			end
			table.remove(st.Stack)
		end

		task.wait(cfg.ClickDelay)
		refreshStatus()
	end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
if STATE.Window then
	pcall(function()
		STATE.Window:Destroy()
	end)
	STATE.Window = nil
end

local Window = WindUI:CreateWindow({
	Title = "Wiki Race Hub",
	Icon = "book-open",
	Author = "auto-win",
	Folder = "WikiRaceHub",
	Size = UDim2.fromOffset(520, 500),
	Theme = "Dark",
	HideSearchBar = true,
	Resizable = false,
})
STATE.Window = Window

local TabMain = Window:Tab({ Title = "Auto Win", Icon = "zap" })
local TabLog = Window:Tab({ Title = "Log", Icon = "list" })

local function initUI()
	TabMain:Toggle({
		Title = "Auto Win",
		Icon = "zap",
		Value = cfg.Enabled,
		Callback = function(v)
			cfg.Enabled = v
			if v then
				log("Auto-win ENABLED")
			else
				log("Auto-win disabled")
			end
			refreshStatus()
			if v and not autoThread then
				autoThread = task.spawn(autoLoop)
			end
		end,
	})

	TabMain:Toggle({
		Title = "Try direct jump to target",
		Icon = "send",
		Value = cfg.DirectJump,
		Callback = function(v)
			cfg.DirectJump = v
		end,
	})

	TabMain:Toggle({
		Title = "Backtrack out of dead ends",
		Icon = "undo",
		Value = cfg.Backtrack,
		Callback = function(v)
			cfg.Backtrack = v
		end,
	})

	TabMain:Slider({
		Title = "Click delay (s)",
		Desc = "Delay between hops to look human",
		Value = { Min = 0.1, Max = 3, Default = cfg.ClickDelay },
		Step = 0.05,
		Callback = function(v)
			cfg.ClickDelay = v
		end,
	})

	TabMain:Slider({
		Title = "Max hops per round",
		Desc = "Stops trying after this many clicks",
		Value = { Min = 10, Max = 120, Default = cfg.HopCap },
		Step = 5,
		Callback = function(v)
			cfg.HopCap = v
		end,
	})

	TabMain:Button({
		Title = "Reset round memory",
		Icon = "rotate-ccw",
		Callback = function()
			st.Visited = {}
			st.Rejected = {}
			st.Stack = {}
			st.Backtracks = 0
			st.LogStop = false
			log("Round memory reset")
		end,
	})

	paragraphStatus = TabMain:Paragraph({
		Title = "Round status",
		Desc = "Waiting for a round...",
	})

	paragraphLog = TabLog:Paragraph({
		Title = "Action log",
		Desc = "No activity yet.",
	})
end

initUI()
renderLog()

if cfg.Enabled and not autoThread then
	autoThread = task.spawn(autoLoop)
end

refreshStatus()
task.spawn(function()
	while STATE.alive() do
		task.wait(1)
		recoverRound(findGameState())
		refreshStatus()
	end
end)