local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Machina = script.Parent
local Config = require(Machina:WaitForChild("Config"))
local PcSystem = require(Machina.platforms.x86:WaitForChild("PcSystem"))

local AUTO_POWER = true
local SCREEN_ASPECT = Config.SCREEN_W / Config.SCREEN_H

local THEME = {
	AppBackground = Color3.fromRGB(7, 9, 12),
	ShellBackground = Color3.fromRGB(12, 15, 20),
	ShellStroke = Color3.fromRGB(33, 39, 49),
	PanelBackground = Color3.fromRGB(16, 20, 26),
	PanelStroke = Color3.fromRGB(39, 46, 57),
	ScreenBackground = Color3.fromRGB(0, 0, 0),
	Text = Color3.fromRGB(238, 241, 245),
	MutedText = Color3.fromRGB(138, 147, 160),
	Success = Color3.fromRGB(99, 208, 141),
	Warning = Color3.fromRGB(255, 191, 92),
	Danger = Color3.fromRGB(255, 110, 110),
	Button = Color3.fromRGB(26, 31, 39),
	ButtonDanger = Color3.fromRGB(56, 27, 31),
}

local CORE_GUI_TYPES = {}
for _, coreGuiType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
	if coreGuiType ~= Enum.CoreGuiType.All then
		table.insert(CORE_GUI_TYPES, coreGuiType)
	end
end

local function create(className, props, parent)
	local instance = Instance.new(className)
	for key, value in pairs(props or {}) do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local function addCorner(instance, radius)
	return create("UICorner", {
		CornerRadius = UDim.new(0, radius),
	}, instance)
end

local function addStroke(instance, color, thickness, transparency)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, instance)
end

local function setButtonEnabled(button, enabled)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.TextTransparency = enabled and 0 or 0.45
	button.BackgroundTransparency = enabled and 0 or 0.25
end

local function createActionButton(text, backgroundColor, parent)
	local button = create("TextButton", {
		Name = text .. "Button",
		Size = UDim2.fromOffset(text == "Shutdown" and 88 or 76, 32),
		BackgroundColor3 = backgroundColor,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Enum.Font.GothamMedium,
		Text = text,
		TextColor3 = THEME.Text,
		TextSize = 13,
	}, parent)

	addCorner(button, 10)
	addStroke(button, THEME.PanelStroke, 1)

	return button
end

local function tryCoreGuiCall(callback)
	for _ = 1, 8 do
		local ok = pcall(callback)
		if ok then
			return true
		end
		task.wait(0.25)
	end

	return false
end

local function disableCoreGui()
	for _, coreGuiType in ipairs(CORE_GUI_TYPES) do
		tryCoreGuiCall(function()
			StarterGui:SetCoreGuiEnabled(coreGuiType, false)
		end)
	end

	tryCoreGuiCall(function()
		StarterGui:SetCore("TopbarEnabled", false)
	end)
end

local function fitDisplay(screenFrame, containerFrame)
	local containerSize = containerFrame.AbsoluteSize
	if containerSize.X <= 0 or containerSize.Y <= 0 then
		return
	end

	local width = containerSize.X
	local height = math.floor(width / SCREEN_ASPECT)

	if height > containerSize.Y then
		height = containerSize.Y
		width = math.floor(height * SCREEN_ASPECT)
	end

	screenFrame.Size = UDim2.fromOffset(width, height)
end

local function createEditableImage(imageLabel)
	local editableImage = AssetService:CreateEditableImage({
		Size = Vector2.new(Config.SCREEN_W, Config.SCREEN_H),
	})

	imageLabel.ImageContent = Content.fromObject(editableImage)

	return editableImage
end

local function buildGui()
	local existing = playerGui:FindFirstChild("MachinaGui")
	
	if existing then
		existing:Destroy()
	end

	local gui = create("ScreenGui", {
		Name = "MachinaGui",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	local background = create("ScreenGui", {
		Name = "Background",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 0,
	}, playerGui)

	create("Frame", {
		Name = "Foreground",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.AppBackground,
	}, background)
	
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)

	local root = create("Frame", {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.AppBackground,
		BorderSizePixel = 0,
	}, gui)

	create("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, root)

	local shell = create("Frame", {
		Name = "Shell",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.ShellBackground,
		BorderSizePixel = 0,
	}, root)
	addCorner(shell, 16)
	addStroke(shell, THEME.ShellStroke, 1)

	local topBar = create("Frame", {
		Name = "TopBar",
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 42),
		BackgroundColor3 = THEME.PanelBackground,
		BorderSizePixel = 0,
	}, shell)
	addCorner(topBar, 12)
	addStroke(topBar, THEME.PanelStroke, 1)

	create("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.fromOffset(120, 42),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "Machina x86",
		TextColor3 = THEME.Text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, topBar)

	local stageDot = create("Frame", {
		Name = "StageDot",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 132, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = THEME.Danger,
		BorderSizePixel = 0,
	}, topBar)
	addCorner(stageDot, 99)

	local stageLabel = create("TextLabel", {
		Name = "StageLabel",
		Position = UDim2.fromOffset(148, 0),
		Size = UDim2.fromOffset(180, 42),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		Text = "offline",
		TextColor3 = THEME.MutedText,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, topBar)

	local actions = create("Frame", {
		Name = "Actions",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(172, 32),
		BackgroundTransparency = 1,
	}, topBar)

	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
	}, actions)

	local rebootButton = createActionButton("Reboot", THEME.Button, actions)
	local shutdownButton = createActionButton("Shutdown", THEME.ButtonDanger, actions)

	local screenHost = create("Frame", {
		Name = "ScreenHost",
		Position = UDim2.fromOffset(12, 66),
		Size = UDim2.new(1, -24, 1, -78),
		BackgroundColor3 = THEME.PanelBackground,
		BorderSizePixel = 0,
	}, shell)
	addCorner(screenHost, 14)
	addStroke(screenHost, THEME.PanelStroke, 1)

	local screenFrame = create("Frame", {
		Name = "ScreenFrame",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = THEME.ScreenBackground,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Active = true,
	}, screenHost)
	addCorner(screenFrame, 14)
	addStroke(screenFrame, Color3.fromRGB(28, 32, 39), 1)

	local imageLabel = create("ImageLabel", {
		Name = "Screen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.ScreenBackground,
		BorderSizePixel = 0,
		ScaleType = Enum.ScaleType.Stretch,
		ResampleMode = Enum.ResamplerMode.Pixelated,
	}, screenFrame)

	local statsPanel = create("Frame", {
		Name = "StatsPanel",
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(250, 150),
		BackgroundColor3 = Color3.fromRGB(9, 12, 17),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 5,
	}, screenHost)
	addCorner(statsPanel, 12)
	addStroke(statsPanel, THEME.PanelStroke, 1)

	local statsLabel = create("TextLabel", {
		Name = "StatsLabel",
		Size = UDim2.new(1, -20, 1, -20),
		Position = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		Text = "",
		TextColor3 = THEME.Text,
		TextSize = 12,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 6,
	}, statsPanel)

	local offOverlay = create("TextButton", {
		Name = "OffOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(5, 6, 9),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		Text = "Click to boot",
		TextColor3 = THEME.MutedText,
		TextSize = 18,
		ZIndex = 4,
	}, screenFrame)

	local offHint = create("TextLabel", {
		Name = "OffHint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(220, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = "F12 opens runtime stats",
		TextColor3 = THEME.MutedText,
		TextSize = 12,
		ZIndex = 5,
	}, offOverlay)

	fitDisplay(screenFrame, screenHost)
	screenHost:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		fitDisplay(screenFrame, screenHost)
	end)

	return {
		gui = gui,
		screenFrame = screenFrame,
		imageLabel = imageLabel,
		stageDot = stageDot,
		stageLabel = stageLabel,
		rebootButton = rebootButton,
		shutdownButton = shutdownButton,
		offOverlay = offOverlay,
		offHint = offHint,
		statsPanel = statsPanel,
		statsLabel = statsLabel,
	}
end

local function setStage(ui, machine)
	local powered = machine and machine:isPowered() or false
	local stage = machine and machine:getBootStage() or "OFF"
	local color = THEME.Danger
	local text = "offline"

	if powered then
		text = string.lower(stage)
		if stage == "RUNNING" then
			color = THEME.Success
		elseif stage == "FAULT" then
			color = THEME.Danger
		else
			color = THEME.Warning
		end
	end

	ui.stageDot.BackgroundColor3 = color
	ui.stageLabel.Text = text
	ui.stageLabel.TextColor3 = powered and THEME.Text or THEME.MutedText
	ui.offOverlay.Visible = not powered
	setButtonEnabled(ui.rebootButton, powered)
	setButtonEnabled(ui.shutdownButton, powered)
end

local function updateStats(ui, machine)
	if not ui.statsPanel.Visible then
		return
	end

	if not machine or not machine:isPowered() then
		ui.statsLabel.Text = "POWERED OFF"
		return
	end

	local stats = machine:getStats()
	local cpu = stats.cpuStats or {}
	local ram = stats.ramStats or {}
	local hdd = stats.hddStats or {}
	local bus = stats.busStats or {}

	ui.statsLabel.Text = string.format(
		"Machina  [F12]\n"
			.. "Stage:  %s\n"
			.. "Uptime: %.1fs\n"
			.. "CPU cycles: %d\n"
			.. "CPU instrs: %d\n"
			.. "RAM  r/w: %d/%d\n"
			.. "HDD  r/w: %d/%d\n"
			.. "Bus IRQs: %d\n"
			.. "GPU flush: %d",
		tostring(stats.bootStage),
		stats.uptime or 0,
		cpu.cycles or 0,
		cpu.instructions or 0,
		ram.reads or 0,
		ram.writes or 0,
		hdd.reads or 0,
		hdd.writes or 0,
		bus.irqFired or 0,
		(stats.gpuStats and stats.gpuStats.flushes) or 0
	)
end

local machine = nil

local function powerOnMachine()
	if not machine or machine:isPowered() then
		return
	end

	machine:powerOn()
	machine:bindInput(UserInputService)
end

local function shutdownMachine()
	if machine and machine:isPowered() then
		machine:shutdown()
	end
end

local function rebootMachine()
	if machine and machine:isPowered() then
		machine:reboot()
	end
end

local function main()
	local ui = buildGui()
	local editableImage = createEditableImage(ui.imageLabel)

	machine = PcSystem.new(Config, editableImage)

	ui.offOverlay.Activated:Connect(powerOnMachine)
	ui.rebootButton.Activated:Connect(rebootMachine)
	ui.shutdownButton.Activated:Connect(shutdownMachine)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.KeyCode == Enum.KeyCode.F12 then
			ui.statsPanel.Visible = not ui.statsPanel.Visible
		end
	end)

	local statsTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		setStage(ui, machine)

		statsTimer = statsTimer + dt
		if statsTimer >= 0.5 then
			statsTimer = 0
			updateStats(ui, machine)
		end
	end)

	player.CharacterRemoving:Connect(function()
		shutdownMachine()
	end)

	player.CharacterAdded:Connect(function()
		task.defer(disableCoreGui)
		if AUTO_POWER then
			task.delay(0.25, powerOnMachine)
		end
	end)

	task.defer(disableCoreGui)

	if AUTO_POWER then
		task.defer(powerOnMachine)
	end
end

main()