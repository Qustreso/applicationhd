--// Services
-- Getting ReplicatedStorage becuase thats where all our assets live
local RS = game:GetService("ReplicatedStorage")
-- Could use ServerStorage but RS is better for client-server communcation

--// Folders
local Assets = RS:WaitForChild("Assets")
-- WaitForChild is used here incase the script loads before the folders (rare but happens)
local Libaries = RS:WaitForChild("Libaries")
local Animations = Assets:WaitForChild("Animations")
-- I prefer waiting rather than getting nil errors later on

--// Classes
local import = require(Libaries:WaitForChild("import"))
-- Import system is custom, basically lets us require modules easier
-- Instead of doing require(path.to.module) we just do import "module"
local Fastnet2 = require(Libaries:WaitForChild("FastNet2"))
-- FastNet2 is a networking library, faster than regular remotes

--// Events
local SendCombatData = Fastnet2.new("SendCombatData")
-- Creating a new FastNet event for combat data
-- This will send hit detection info to the server

--// Modules
local Data = require(script:WaitForChild("SubModules"):WaitForChild("Data"))
-- Data module contains all the hardcoded values like combo timings, damage, etc
local Animator = require(script:WaitForChild("SubModules"):WaitForChild("Animator"))
-- I keep it in a submodule so its easier to tweak values without touching main code

--// Libraries
local utility, maid, input, new = import "utility", import "maid", import "input", import "new"
-- Importing multiple libraries at once using our custom import system
-- utility = general helper functions, maid = cleanup, input = input handling, new = instance creation
local connections = maid()
-- Maid is used for cleaning up connections when the player leaves

--// Hardcoded Configuration Values
local COMBO_RESET_TIME = 2.5
-- Time in seconds before combo resets back to 1
-- These should probably be in a config module but im lazy so they're here
local MAX_COMBO_COUNT = 4
-- Maximum number of attacks in a combo chain
local ATTACK_COOLDOWN = 0.35
-- Cooldown between individual attacks in seconds
local DAMAGE_MULTIPLIER = 1.0
-- Base damage multiplier, can be changed for buffs/debuffs
-- I hardcoded them because changing these requires restarting the game anyway
local CRITICAL_HIT_CHANCE = 0.15
-- 15% chance to crit, hardcoded for balance reasons
local CRITICAL_DAMAGE_BONUS = 1.5
-- Crits do 1.5x damage, pretty standard

local IDLE_THRESHOLD = 1
-- Movement thresholds (hardcoded because they never change)
-- Speed below this = idle
local WALKING_THRESHOLD = 16
-- Speed above this = running instead of walking
local SPRINTING_THRESHOLD = 22
-- Speed above this = sprinting

--// Class
local CombatService = {}
CombatService.__index = CombatService
-- Main combat service class, handles all combat logic for a single player
-- Using metatables here for OOP style programming in lua

function CombatService.new(Plr: Player)
	local self = setmetatable({}, CombatService)
	-- Creating the instance using setmetatable for OOP functionality
	
	self._Plr = Plr
	-- Storing player reference, needed for basically everything
	self._Char = Plr.Character or Plr.CharacterAdded:Wait()
	-- Getting character, waiting if it doesn't exist yet
	self._Hum = self._Char:WaitForChild("Humanoid")
	-- Humanoid is needed for health, state changes, animations etc
	self._Animator = self._Hum:WaitForChild("Animator")
	-- WaitForChild becuase sometimes character loads before humanoid (roblox moment)
	self._HumRP = self._Char:WaitForChild("HumanoidRootPart")
	-- HumanoidRootPart is the main physics part, used for velocity checks
	
	self._ComboIndex = 1
	-- Current position in combo chain, starts at 1
	self._Debounce = false
	-- Prevents attack spamming, false = can attack
	self._ComboOrder = {}
	self._LoadedTracks = {}
	-- Ordered list of combo animations and Pre-loaded animation tracks for performance
	self._LastAttackTime = 0
	-- Timestamp of last attack for combo reset logic
	self._IsAttacking = false
	self._ComboResetConnection = nil
	-- Flag to track if currently in attack animation
	
	self._TotalDamageDealt = 0
	-- Damage tracking (hardcoded initialization)
	-- Career damage counter
	self._CurrentComboHits = 0
	self._HighestComboReached = 0
	-- Number of hits in current combo
	
	self._AttackSpeed = 1.0
	-- Combat statistics (hardcoded defaults)
	self._ComboPower = 1.0
	self._StunDuration = 0.5
	-- Animation speed multiplier and damage multiplier for combo finishers
	
	self._State = new "StringValue" {
		Name = "State",
		Parent = self._Plr,
		Value = "Idle"
	}
	-- State management system using a StringValue so other scripts can read the state easily
	-- Parented to player instead of character incase of respawns
	
	self._AnimationHandler = Animator.new(self._Plr)
	-- Animation handler instance, manages all animation blending and transitions
	-- Separated into its own class becuase animation code got messy
	
	for key, anim in pairs(Data.Combos) do
		-- Building combo order table from Data module
		-- We iterate through all combos and store them with their index
		table.insert(self._ComboOrder, {
			Index = tonumber(key),
			Animation = anim,
			Name = anim.Name or "Combo_" .. key,
			Duration = 0,
		})
		-- Each combo has an index number and animation reference
		-- Using table.insert instead of direct assignment for safety
	end
	
	table.sort(self._ComboOrder, function(a, b)
		return a.Index < b.Index
	end)
	-- Sorting combo order by index to ensure proper sequence
	-- Without this, combos might play in wrong order (really bad)
	
	for i, comboData in ipairs(self._ComboOrder) do
		-- Pre-loading all animation tracks at initialization
		-- This prevents lag spikes when playing animations for first time
		local track = self._Animator:LoadAnimation(comboData.Animation)
		-- LoadAnimation returns an AnimationTrack object
		
		self._LoadedTracks[i] = track
		-- We store these in a table indexed by combo number
		
		if track then
			comboData.Duration = track.Length
			-- Also storing track duration back to combo data
			track.Priority = Enum.AnimationPriority.Action
			-- Setting animation priority so combat anims override idle/walk
			track:AdjustSpeed(self._AttackSpeed)
			-- Adjusting animation speed based on attack speed stat
		else
			warn("Failed to load animation track for combo " .. i)
			-- Fallback if animation fails to load (shouldn't happen but safety first)
			comboData.Duration = 1.0
		end
	end
	
	self:_StartComboResetTimer()
	-- Initialize combo reset timer
	
	return self
	-- Return the fully constructed instance
end

function CombatService:_SetState(newState: string)
	-- Sets the combat state (Idle, Moving, Attacking, etc)
	if self._State.Value ~= newState then
		-- Only update if state is actually changing
		self._State.Value = newState
		-- Prevents unnecessary property changes and event firings
	end
end

function CombatService:_GetState()
	return self._State.Value
	-- Gets current combat state, simple getter function
end

function CombatService:_CanAttack()
	-- Checks if player can initiate an attack
	local currentState = self:_GetState()
	-- Getting current state first for comparison
	
	if currentState == "Idle" or currentState == "Moving" then
		return true
		-- Can always attack from idle or moving
	elseif currentState == "Attacking" then
		return true
		-- Can chain combo during attack (this enables combo chaining)
	else
		return false
		-- Any other state blocks attacks (jumping, stunned, etc)
	end
	-- Nested conditions for attack validation
	-- We allow attacking from multiple states for fluid combat
end

function CombatService:_UpdateMovementState()
	-- Updates movement state based on character velocity
	local velocity = self._HumRP.AssemblyLinearVelocity
	-- Getting velocity from HumanoidRootPart physics
	-- AssemblyLinearVelocity is more reliable than CFrame calculations
	
	local horizontalSpeed = math.sqrt(velocity.X^2 + velocity.Z^2)
	-- Calculate horizontal speed (ignoring Y axis)
	-- We use X and Z because Y is vertical (jumping/falling)
	
	if horizontalSpeed > IDLE_THRESHOLD then
		-- Player is moving
		
		if horizontalSpeed > SPRINTING_THRESHOLD then
			-- Moving fast enough to be sprinting
			if self:_GetState() == "Idle" or self:_GetState() == "Moving" then
				self:_SetState("Sprinting")
				-- Only change state if not idle (prevents overriding attacks)
			end
		elseif horizontalSpeed > WALKING_THRESHOLD then
			-- Moving at running speed
			if self:_GetState() == "Idle" then
				self:_SetState("Running")
			end
		else
			if self:_GetState() == "Idle" then
				self:_SetState("Moving")
				-- Moving but below running threshold = walking
			end
		end
	else
		-- Horizontal speed is below idle threshold
		if self:_GetState() == "Moving" or self:_GetState() == "Running" or self:_GetState() == "Sprinting" then
			self:_SetState("Idle")
			-- Transition back to idle from any movement state
		end
	end
	-- Nested state checking logic with different thresholds for different movement states
end

function CombatService:_StartComboResetTimer()
	-- Starts a timer that resets combo back to 1 after inactivity
	if self._ComboResetConnection then
		self._ComboResetConnection:Disconnect()
		self._ComboResetConnection = nil
		-- Clean up existing connection if it exists
	end
	
	self._ComboResetConnection = task.delay(COMBO_RESET_TIME, function()
		-- Using task.delay for the timer instead of wait() becuase its more precise
		if not self._IsAttacking and self._ComboIndex > 1 then
			-- Check if combo should actually reset
			self._ComboIndex = 1
			self._CurrentComboHits = 0
			-- Reset combo back to first attack
		end
		-- Only reset if not currently attacking
	end)
	-- This is why combos reset if you wait too long between attacks
end

function CombatService:_RollForCritical()
	-- Calculates if this attack is a critical hit
	local roll = math.random()
	-- Generate random number between 0 and 1
	
	if roll <= CRITICAL_HIT_CHANCE then
		return true
		-- Base crit success
	else
		-- Could add guaranteed crit conditions here
		if self._CurrentComboHits >= 10 then
			return true
			-- Guaranteed crit after 10 hits (rare but cool)
		end
	end
	-- Nested check for special conditions
	
	return false
end

function CombatService:_PlayCombo()
	-- Main combo attack function
	if self._Debounce or not self:_CanAttack() then 
		return 
		-- First check debounce and attack permission
	end
	
	self._Debounce = true
	self._IsAttacking = true
	-- Set debounce immediately to prevent double-attacks
	
	self:_SetState("Attacking")
	-- Update state to attacking
	
	print("Playing combo index:", self._ComboIndex)
	-- Debug print for testing (should remove in production but useful for debugging)
	
	local animTrack = self._LoadedTracks[self._ComboIndex]
	-- Get the animation track for current combo index
	
	if not animTrack then
		warn("Animation track not found for combo " .. self._ComboIndex)
		-- Safety check incase track doesn't exist
		self._ComboIndex = 1
		animTrack = self._LoadedTracks[self._ComboIndex]
		-- Reset to first combo as fallback
	end
	
	if animTrack then
		animTrack:Play()
		-- Play the animation, this triggers the visual attack animation
		
		local isCritical = self:_RollForCritical()
		local damageAmount = 0
		-- Nested combat calculations
		
		if self._ComboIndex == 1 then
			damageAmount = 10
			-- First hit does 10 damage
		elseif self._ComboIndex == 2 then
			damageAmount = 15
			-- Second hit does 15 damage
		elseif self._ComboIndex == 3 then
			damageAmount = 20
			-- Third hit does 20 damage
		else
			damageAmount = 30 * self._ComboPower
			-- Final hit does most damage, multiplied by combo power stat
		end
		-- Calculate base damage (hardcoded formula)
		
		damageAmount = damageAmount * DAMAGE_MULTIPLIER
		-- Apply damage multiplier
		
		if isCritical then
			damageAmount = damageAmount * CRITICAL_DAMAGE_BONUS
			print("CRITICAL HIT!")
			-- Apply crit bonus if we crit
		end
		
		self._TotalDamageDealt = self._TotalDamageDealt + damageAmount
		self._CurrentComboHits = self._CurrentComboHits + 1
		-- Update statistics
		
		if self._CurrentComboHits > self._HighestComboReached then
			self._HighestComboReached = self._CurrentComboHits
			-- Track highest combo
		end
	end
	
	local lastComboIndex = #self._ComboOrder
	-- Determine attack type and send to server
	if self._ComboIndex == lastComboIndex then
		-- This is the combo finisher attack
		SendCombatData:Fire("Combo_Hit", self._ComboIndex, {
			Damage = 30 * self._ComboPower,
			IsCritical = self:_RollForCritical(),
			Timestamp = tick(),
		})
		-- Send different event so server can apply bonus effects
	else
		SendCombatData:Fire("Normal_Hit", self._ComboIndex, {
			Damage = 10 + (self._ComboIndex * 5),
			IsCritical = self:_RollForCritical(),
			Timestamp = tick(),
		})
		-- Normal combo hit
	end
	
	self._ComboIndex += 1
	-- Increment combo index for next attack
	
	if self._ComboIndex > lastComboIndex then
		self._ComboIndex = 1
		-- Reset combo if we exceeded max
	end
	
	self._LastAttackTime = tick()
	self:_StartComboResetTimer()
	-- Update last attack time for combo reset timer
	
	animTrack.Ended:Connect(function()
		-- Wait for animation to finish before allowing next attack
		self._IsAttacking = false
		-- Animation finished, player can move again
		
		if self:_GetState() == "Attacking" then
			self:_SetState("Idle")
			-- Only reset to idle if not moving
		end
	end)
	-- Using Ended event instead of wait() for better performance
	
	task.delay(ATTACK_COOLDOWN, function()
		self._Debounce = false
		-- Reset debounce flag
	end)
	-- Cooldown delay before next attack allowed
end

function CombatService:Init()
	-- Initializes the combat system
	connections["CombatConnection"] = input:BindAction(Data.Button, Enum.UserInputState.Begin, function()
		self:_PlayCombo()
		-- Input callback, triggers when button is pressed
	end)
	-- Bind the attack input, Data.Button contains the keybind
	
	self:InitMovement()
	-- Initialize movement state tracking
end

function CombatService:InitMovement()
	-- Initializes movement tracking connections
	connections["MovementConnection"] = game:GetService("RunService").Heartbeat:Connect(function()
		-- Heartbeat connection for velocity-based movement detection
		if self:_GetState() ~= "Attacking" then
			self:_UpdateMovementState()
			-- Only update movement if not attacking
		end
	end)
	-- Runs every frame which is needed for smooth state transitions
	
	connections["JumpConnection"] = self._Hum.StateChanged:Connect(function(oldState, newState)
		-- Listen for humanoid state changes (jumping, falling, etc)
		if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
			-- Check if player started jumping or falling
			if self:_GetState() ~= "Attacking" then
				self:_SetState("Jumping")
				-- Set to jumping unless currently attacking
			end
		elseif newState == Enum.HumanoidStateType.Landed then
			-- Player landed on ground
			if self:_GetState() == "Jumping" then
				self:_SetState("Idle")
				-- Only transition from jumping to idle
			end
		elseif newState == Enum.HumanoidStateType.Dead then
			-- Player died, reset everything
			self:_SetState("Dead")
			self._ComboIndex = 1
			self._IsAttacking = false
			self._Debounce = false
		end
		-- Nested state checking for different humanoid states
	end)
	-- This catches state changes that velocity might miss
end

function CombatService:Destroy()
	-- Cleanup function, disconnects all connections and destroys objects
	connections:Destroy()
	-- Maid automatically disconnects all stored connections
	
	if self._State then
		self._State:Destroy()
		self._State = nil
		-- Clean up state value
	end
	
	for _, track in pairs(self._LoadedTracks) do
		-- Stop and destroy all animation tracks
		if track then
			track:Stop(0)
			track:Destroy()
			-- Stop immediately (0 fade time)
		end
	end
	-- Important to prevent memory leaks
	
	self._LoadedTracks = {}
	self._ComboOrder = {}
	-- Clear references
	
	if self._ComboResetConnection then
		self._ComboResetConnection = nil
		-- Disconnect combo reset timer if it exists
	end
	-- Note: task.delay connections might not have disconnect method
end

return CombatService
-- Return the class so it can be required by other scripts
