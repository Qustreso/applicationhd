--// Services
-- Getting ReplicatedStorage becuase thats where all our assets live
-- Could use ServerStorage but RS is better for client-server communcation
local RS = game:GetService("ReplicatedStorage")

--// Folders
-- WaitForChild is used here incase the script loads before the folders (rare but happens)
-- I prefer waiting rather than getting nil errors later on
local Assets = RS:WaitForChild("Assets") -- This holds all our game assets like animations, sounds, etc
local Libaries = RS:WaitForChild("Libaries") -- Spelled wrong on purpose but its the libraries folder lol
local Animations = Assets:WaitForChild("Animations") -- Specifically grabbing animations subfolder

--// Classes
-- Import system is custom, basically lets us require modules easier
-- Instead of doing require(path.to.module) we just do import "module"
local import = require(Libaries:WaitForChild("import"))
-- FastNet2 is a networking library, faster than regular remotes
-- We use it for sending combat data to the server
local Fastnet2 = require(Libaries:WaitForChild("FastNet2"))

--// Events
-- Creating a new FastNet event for combat data
-- This will send hit detection info to the server
local SendCombatData = Fastnet2.new("SendCombatData")

--// Modules
-- Data module contains all the hardcoded values like combo timings, damage, etc
-- I keep it in a submodule so its easier to tweak values without touching main code
local Data = require(script:WaitForChild("SubModules"):WaitForChild("Data"))
-- Animator handles all animation related stuff
-- Separated it because the main module was getting to cluttered
local Animator = require(script:WaitForChild("SubModules"):WaitForChild("Animator"))

--// Libraries
-- Importing multiple libraries at once using our custom import system
-- utility = general helper functions, maid = cleanup, input = input handling, new = instance creation
local utility, maid, input, new = import "utility", import "maid", import "input", import "new"
-- Maid is used for cleaning up connections when the player leaves
-- Its basically a garbage collector that we control manually
local connections = maid()

--// Hardcoded Configuration Values
-- These should probably be in a config module but im lazy so they're here
-- I hardcoded them because changing these requires restarting the game anyway
local COMBO_RESET_TIME = 2.5 -- Time in seconds before combo resets back to 1
local MAX_COMBO_COUNT = 4 -- Maximum number of attacks in a combo chain
local ATTACK_COOLDOWN = 0.35 -- Cooldown between individual attacks in seconds
local DAMAGE_MULTIPLIER = 1.0 -- Base damage multiplier, can be changed for buffs/debuffs
local CRITICAL_HIT_CHANCE = 0.15 -- 15% chance to crit, hardcoded for balance reasons
local CRITICAL_DAMAGE_BONUS = 1.5 -- Crits do 1.5x damage, pretty standard

-- Movement thresholds (hardcoded because they never change)
local IDLE_THRESHOLD = 1 -- Speed below this = idle
local WALKING_THRESHOLD = 16 -- Speed above this = running instead of walking
local SPRINTING_THRESHOLD = 22 -- Speed above this = sprinting

--// Class
-- Main combat service class, handles all combat logic for a single player
-- Using metatables here for OOP style programming in lua
local CombatService = {}
CombatService.__index = CombatService

-- Constructor function, creates a new combat service instance for a player
-- @param Plr: Player - The player this combat service is for
-- @return CombatService - New instance of the combat service
function CombatService.new(Plr: Player)
	-- Creating the instance using setmetatable for OOP functionality
	-- This lets us use self and inheritance properly
	local self = setmetatable({}, CombatService)
	
	-- Storing player reference, needed for basically everything
	self._Plr = Plr
	
	-- Getting character, waiting if it doesn't exist yet
	-- The or statement handles respawning characters
	self._Char = Plr.Character or Plr.CharacterAdded:Wait()
	
	-- Humanoid is needed for health, state changes, animations etc
	-- WaitForChild becuase sometimes character loads before humanoid (roblox moment)
	self._Hum = self._Char:WaitForChild("Humanoid")
	
	-- Animator is a child of humanoid, used to load and play animations
	-- Could create our own but using roblox's is more reliable
	self._Animator = self._Hum:WaitForChild("Animator")
	
	-- HumanoidRootPart is the main physics part, used for velocity checks
	-- Also used for calculating distances and directional attacks
	self._HumRP = self._Char:WaitForChild("HumanoidRootPart")
	
	-- Combo tracking variables
	self._ComboIndex = 1 -- Current position in combo chain, starts at 1
	self._Debounce = false -- Prevents attack spamming, false = can attack
	self._ComboOrder = {} -- Ordered list of combo animations
	self._LoadedTracks = {} -- Pre-loaded animation tracks for performance
	self._LastAttackTime = 0 -- Timestamp of last attack for combo reset logic
	self._IsAttacking = false -- Flag to track if currently in attack animation
	self._ComboResetConnection = nil -- Connection for combo reset timer
	
	-- Damage tracking (hardcoded initialization)
	self._TotalDamageDealt = 0 -- Career damage counter
	self._CurrentComboHits = 0 -- Number of hits in current combo
	self._HighestComboReached = 0 -- Highest combo achieved in this session
	
	-- Combat statistics (hardcoded defaults)
	self._AttackSpeed = 1.0 -- Animation speed multiplier
	self._ComboPower = 1.0 -- Damage multiplier for combo finishers
	self._StunDuration = 0.5 -- How long enemies are stunned on hit
	
	-- State management system
	-- Using a StringValue so other scripts can read the state easily
	-- Parented to player instead of character incase of respawns
	self._State = new "StringValue" {
		Name = "State", -- Named for easy finding in explorer
		Parent = self._Plr, -- Parented to player not character for persistance
		Value = "Idle" -- Default state when spawning
	}
	
	-- Animation handler instance
	-- This manages all animation blending and transitions
	-- Separated into its own class becuase animation code got messy
	self._AnimationHandler = Animator.new(self._Plr)
	
	-- Building combo order table from Data module
	-- We iterate through all combos and store them with their index
	-- This is done at construction time for performance (dont want to sort every attack)
	for key, anim in pairs(Data.Combos) do
		-- Each combo has an index number and animation reference
		-- Using table.insert instead of direct assignment for safety
		table.insert(self._ComboOrder, {
			Index = tonumber(key), -- Convert key to number for sorting
			Animation = anim, -- Store the animation instance
			Name = anim.Name or "Combo_" .. key, -- Fallback name if animation unnamed
			Duration = 0, -- Will be calculated after loading
		})
	end
	
	-- Sorting combo order by index to ensure proper sequence
	-- Without this, combos might play in wrong order (really bad)
	-- Using a custom sort function that compares Index fields
	table.sort(self._ComboOrder, function(a, b)
		return a.Index < b.Index -- Ascending order sort
	end)
	
	-- Pre-loading all animation tracks at initialization
	-- This prevents lag spikes when playing animations for first time
	-- Nested loop structure for proper error handling
	for i, comboData in ipairs(self._ComboOrder) do
		-- LoadAnimation returns an AnimationTrack object
		-- We store these in a table indexed by combo number
		local track = self._Animator:LoadAnimation(comboData.Animation)
		
		-- Storing the track for later use
		self._LoadedTracks[i] = track
		
		-- Also storing track duration back to combo data
		-- This is needed for timing combo windows properly
		if track then
			comboData.Duration = track.Length -- Get animation length
			
			-- Setting animation priority so combat anims override idle/walk
			-- Action priority is high enough without blocking emotes
			track.Priority = Enum.AnimationPriority.Action
			
			-- Adjusting animation speed based on attack speed stat
			-- This is where we apply the hardcoded attack speed multiplier
			track:AdjustSpeed(self._AttackSpeed)
		else
			-- Fallback if animation fails to load (shouldn't happen but safety first)
			warn("Failed to load animation track for combo " .. i)
			comboData.Duration = 1.0 -- Default duration
		end
	end
	
	-- Initialize combo reset timer
	self:_StartComboResetTimer()
	
	-- Return the fully constructed instance
	return self
end

-- Sets the combat state (Idle, Moving, Attacking, etc)
-- Only updates if the state is actually changing to avoid unnecessary operations
-- @param newState: string - The state to transition to
function CombatService:_SetState(newState: string)
	-- Only update if state is actually changing
	-- Prevents unnecessary property changes and event firings
	if self._State.Value ~= newState then
		-- Setting the value triggers any listeners on this StringValue
		self._State.Value = newState
		
		-- Could add state transition callbacks here if needed
		-- For now just doing the basic assignment
	end
end

-- Gets current combat state
-- Simple getter function, returns string value
-- @return string - Current state ("Idle", "Moving", "Attacking", etc)
function CombatService:_GetState()
	-- Direct return of state value
	return self._State.Value
end

-- Checks if player can initiate an attack
-- Attacks are allowed in Idle, Moving, or Attacking states
-- NOT allowed when Jumping, Stunned, Dead, etc
-- @return boolean - true if attack is allowed
function CombatService:_CanAttack()
	-- Getting current state first for comparison
	local currentState = self:_GetState()
	
	-- Nested conditions for attack validation
	-- We allow attacking from multiple states for fluid combat
	if currentState == "Idle" or currentState == "Moving" then
		-- Can always attack from idle or moving
		return true
	elseif currentState == "Attacking" then
		-- Can chain combo during attack (this enables combo chaining)
		-- But we still check debounce seperately
		return true
	else
		-- Any other state blocks attacks (jumping, stunned, etc)
		return false
	end
end

-- Updates movement state based on character velocity
-- Called every frame to keep state synced with actual movement
-- Uses hardcoded thresholds for state transitions
function CombatService:_UpdateMovementState()
	-- Getting velocity from HumanoidRootPart physics
	-- AssemblyLinearVelocity is more reliable than CFrame calculations
	local velocity = self._HumRP.AssemblyLinearVelocity
	
	-- Calculate horizontal speed (ignoring Y axis)
	-- We use X and Z because Y is vertical (jumping/falling)
	-- Pythagorean theorem for magnitude
	local horizontalSpeed = math.sqrt(velocity.X^2 + velocity.Z^2)
	
	-- Nested state checking logic
	-- We have different thresholds for different movement states
	if horizontalSpeed > IDLE_THRESHOLD then
		-- Player is moving
		
		if horizontalSpeed > SPRINTING_THRESHOLD then
			-- Moving fast enough to be sprinting
			-- Only change state if not idle (prevents overriding attacks)
			if self:_GetState() == "Idle" or self:_GetState() == "Moving" then
				self:_SetState("Sprinting")
			end
		elseif horizontalSpeed > WALKING_THRESHOLD then
			-- Moving at running speed
			if self:_GetState() == "Idle" then
				self:_SetState("Running")
			end
		else
			-- Moving but below running threshold = walking
			if self:_GetState() == "Idle" then
				self:_SetState("Moving")
			end
		end
	else
		-- Horizontal speed is below idle threshold
		-- Player is standing still
		if self:_GetState() == "Moving" or self:_GetState() == "Running" or self:_GetState() == "Sprinting" then
			-- Transition back to idle from any movement state
			self:_SetState("Idle")
		end
	end
end

-- Starts a timer that resets combo back to 1 after inactivity
-- This is why combos reset if you wait too long between attacks
function CombatService:_StartComboResetTimer()
	-- Clean up existing connection if it exists
	-- Prevents multiple timers running at once
	if self._ComboResetConnection then
		self._ComboResetConnection:Disconnect()
		self._ComboResetConnection = nil
	end
	
	-- Using task.delay for the timer instead of wait() becuase its more precise
	-- COMBO_RESET_TIME is hardcoded at the top of the file
	self._ComboResetConnection = task.delay(COMBO_RESET_TIME, function()
		-- Check if combo should actually reset
		-- Only reset if not currently attacking
		if not self._IsAttacking and self._ComboIndex > 1 then
			-- Reset combo back to first attack
			self._ComboIndex = 1
			self._CurrentComboHits = 0
			
			-- Could play a visual effect here to show combo reset
			-- Maybe particle effect or sound cue
		end
	end)
end

-- Calculates if this attack is a critical hit
-- Uses hardcoded crit chance from top of file
-- @return boolean - true if attack crits
function CombatService:_RollForCritical()
	-- Generate random number between 0 and 1
	-- If its below crit chance, we got a crit
	local roll = math.random()
	
	-- Nested check for special conditions
	if roll <= CRITICAL_HIT_CHANCE then
		-- Base crit success
		return true
	else
		-- Could add guaranteed crit conditions here
		-- Like "every 5th hit is guaranteed crit"
		if self._CurrentComboHits >= 10 then
			-- Guaranteed crit after 10 hits (rare but cool)
			return true
		end
	end
	
	return false
end

-- Main combo attack function
-- Handles animation playback, state changes, and server communication
function CombatService:_PlayCombo()
	-- First check debounce and attack permission
	-- Return early if we cant attack to avoid nested if statements
	if self._Debounce or not self:_CanAttack() then 
		return 
	end
	
	-- Set debounce immediately to prevent double-attacks
	-- This is critical for preventing exploits
	self._Debounce = true
	self._IsAttacking = true
	
	-- Update state to attacking
	-- This prevents movement state updates from overriding
	self:_SetState("Attacking")
	
	-- Debug print for testing (should remove in production but useful for debugging)
	print("Playing combo index:", self._ComboIndex)
	
	-- Get the animation track for current combo index
	-- This is why we pre-loaded all tracks in the constructor
	local animTrack = self._LoadedTracks[self._ComboIndex]
	
	-- Safety check incase track doesn't exist
	-- Shouldn't happen but better safe than erroring
	if not animTrack then
		warn("Animation track not found for combo " .. self._ComboIndex)
		-- Reset to first combo as fallback
		self._ComboIndex = 1
		animTrack = self._LoadedTracks[self._ComboIndex]
	end
	
	-- Play the animation
	-- This triggers the visual attack animation
	if animTrack then
		animTrack:Play()
		
		-- Nested combat calculations
		local isCritical = self:_RollForCritical()
		local damageAmount = 0
		
		-- Calculate base damage (hardcoded formula)
		if self._ComboIndex == 1 then
			damageAmount = 10 -- First hit does 10 damage
		elseif self._ComboIndex == 2 then
			damageAmount = 15 -- Second hit does 15 damage
		elseif self._ComboIndex == 3 then
			damageAmount = 20 -- Third hit does 20 damage
		else
			-- Final hit does most damage
			damageAmount = 30 * self._ComboPower -- Multiplied by combo power stat
		end
		
		-- Apply damage multiplier
		damageAmount = damageAmount * DAMAGE_MULTIPLIER
		
		-- Apply crit bonus if we crit
		if isCritical then
			damageAmount = damageAmount * CRITICAL_DAMAGE_BONUS
			print("CRITICAL HIT!") -- Debug message
		end
		
		-- Update statistics
		self._TotalDamageDealt = self._TotalDamageDealt + damageAmount
		self._CurrentComboHits = self._CurrentComboHits + 1
		
		-- Track highest combo
		if self._CurrentComboHits > self._HighestComboReached then
			self._HighestComboReached = self._CurrentComboHits
		end
	end
	
	-- Determine attack type and send to server
	-- Last attack in combo is special (finisher)
	local lastComboIndex = #self._ComboOrder
	if self._ComboIndex == lastComboIndex then
		-- This is the combo finisher attack
		-- Send different event so server can apply bonus effects
		SendCombatData:Fire("Combo_Hit", self._ComboIndex, {
			Damage = 30 * self._ComboPower,
			IsCritical = self:_RollForCritical(),
			Timestamp = tick(),
		})
	else
		-- Normal combo hit
		SendCombatData:Fire("Normal_Hit", self._ComboIndex, {
			Damage = 10 + (self._ComboIndex * 5),
			IsCritical = self:_RollForCritical(),
			Timestamp = tick(),
		})
	end
	
	-- Increment combo index for next attack
	self._ComboIndex += 1
	
	-- Reset combo if we exceeded max
	-- This is why combo loops back to start
	if self._ComboIndex > lastComboIndex then
		self._ComboIndex = 1
	end
	
	-- Update last attack time for combo reset timer
	self._LastAttackTime = tick()
	self:_StartComboResetTimer()
	
	-- Wait for animation to finish before allowing next attack
	-- Using Ended event instead of wait() for better performance
	animTrack.Ended:Connect(function()
		-- Animation finished, player can move again
		self._IsAttacking = false
		
		-- Only reset to idle if not moving
		-- This prevents jarring state transitions
		if self:_GetState() == "Attacking" then
			self:_SetState("Idle")
		end
	end)
	
	-- Cooldown delay before next attack allowed
	-- Using hardcoded ATTACK_COOLDOWN value
	task.delay(ATTACK_COOLDOWN, function()
		-- Reset debounce flag
		self._Debounce = false
	end)
end

-- Initializes the combat system
-- Binds input and starts all necessary connections
function CombatService:Init()
	-- Bind the attack input
	-- Data.Button contains the keybind (probably MouseButton1 or a key)
	connections["CombatConnection"] = input:BindAction(Data.Button, Enum.UserInputState.Begin, function()
		-- Input callback, triggers when button is pressed
		self:_PlayCombo()
	end)
	
	-- Initialize movement state tracking
	-- Separated into its own function becuase it has multiple connections
	self:InitMovement()
end

-- Initializes movement tracking connections
-- Monitors velocity and state changes to update combat state
function CombatService:InitMovement()
	-- Heartbeat connection for velocity-based movement detection
	-- Runs every frame which is needed for smooth state transitions
	connections["MovementConnection"] = game:GetService("RunService").Heartbeat:Connect(function()
		-- Only update movement if not attacking
		-- Attacking state takes priority over movement states
		if self:_GetState() ~= "Attacking" then
			self:_UpdateMovementState()
		end
	end)
	
	-- Listen for humanoid state changes (jumping, falling, etc)
	-- This catches state changes that velocity might miss
	connections["JumpConnection"] = self._Hum.StateChanged:Connect(function(oldState, newState)
		-- Check if player started jumping or falling
		-- Nested state checking for different humanoid states
		if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
			-- Player is in air
			if self:_GetState() ~= "Attacking" then
				-- Set to jumping unless currently attacking
				-- Attacks can continue in air (anime combat style)
				self:_SetState("Jumping")
			end
		elseif newState == Enum.HumanoidStateType.Landed then
			-- Player landed on ground
			if self:_GetState() == "Jumping" then
				-- Only transition from jumping to idle
				-- Dont want to override other states
				self:_SetState("Idle")
			end
		elseif newState == Enum.HumanoidStateType.Dead then
			-- Player died, reset everything
			self:_SetState("Dead")
			self._ComboIndex = 1
			self._IsAttacking = false
			self._Debounce = false
		end
	end)
end

-- Cleanup function
-- Disconnects all connections and destroys objects
-- Call this when player leaves or character dies
function CombatService:Destroy()
	-- Maid automatically disconnects all stored connections
	-- This is why we used maid instead of manual connection management
	connections:Destroy()
	
	-- Clean up state value
	if self._State then
		self._State:Destroy()
		self._State = nil
	end
	
	-- Stop and destroy all animation tracks
	-- Important to prevent memory leaks
	for _, track in pairs(self._LoadedTracks) do
		if track then
			track:Stop(0) -- Stop immediately (0 fade time)
			track:Destroy()
		end
	end
	
	-- Clear references
	self._LoadedTracks = {}
	self._ComboOrder = {}
	
	-- Disconnect combo reset timer if it exists
	if self._ComboResetConnection then
		-- Note: task.delay connections might not have disconnect method
		-- This is fine, they'll just complete and garbage collect
		self._ComboResetConnection = nil
	end
	
	-- Could add more cleanup here if we had more systems
	-- Things like particle effects, sound effects, etc
end

-- Return the class so it can be required by other scripts
return CombatService
