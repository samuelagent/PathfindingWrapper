--[[
author: samuelagent

This library handles general-use pathfinding functionality, including dynamic chasing and recomputation of paths,
as well as distance-based prioritizing for greater performance. It also solves various common problems that come with
utilizing roblox's pathfinding typically, such as avoiding cliffs, knowing when a path becomes irrevelant, and when
an NPC can chase the player directly. 

Have some API:

----------------------------------------------------------------------------------------------------------------------
Variable > Target: Character | BasePart | Vector3
	The current target of the Actor. Can be a Character, BasePart, Vector3, or false.

Variable > Enabled: Bool
	Whether or not the current Actor is enabled. Controls whether or not the Actor is capable of functioning within
	the scope of this module.

EVENT > PathStatusChanged(NewPathState : String)
	Fires when the pathfinding mode of the actor changes. If using a path, the NewPathState will be "Pathfinding"
	and when chasing directly, the NewPathState will be "Following". Does not fire on Target or Enabled changes.

EVENT > PathComputed(Path: Path)
	Fires when a new path is computed by the actor. Passes the path itself as the first and only argument.

EVENT > WaypointReached(Waypoint : PathWaypoint)
	Fires when the actor reaches a waypoint along its current path. Passes the waypoint instance as the argument.

FUNCTION > module:ComputePath()
	Computes a path to the Actor's target. If possible, the actor will begin moving along the path towards its
	target, if the Actor does not have a target or no path is possible, the NPC will remain idle.

FUNCTION > module:LifeCycle()
	Initiates the lifecycle of the actor. This function yields indefinitely so it should typically be called in a
	separate thread. The lifecycle will run until the actor object is destroyed.

FUNCTION > module:Destroy()
	Destroys the given actor object, this does not ever get called by default so you have to assign your own connections
	to this.
	
FUNCTION > [Object] module.New(Character: Model, [Optional] PathComputeParams | Table)
	Constructs a new object for the given character, with custom default PathComputeParams if provided, returns the
	constructed actor. This does not begin any NPC behavior.
	
----------------------------------------------------------------------------------------------------------------------
]]

--// Services
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

--// Constants
local DistanceToRecomputePath = 15
local DistanceToChaseDirectly = 20 -- Studs
local SlopeToChaseDirectly = 0.5 -- Rise / Run

local DownVector = Vector3.new(0, -5, 0) -- For checking if cliff
local DownOffset = 8

--// Auxillary Functions

local function GetTickRate(DistanceFromTarget)
	return 0.1 + (DistanceFromTarget > 25 and math.clamp(DistanceFromTarget * 0.01, 0, 2) or 0)
end

local function ShallowCopy(Original)
	local Copy = {}
	for i, v in pairs(Original) do
		Copy[i] = v
	end
	return Copy
end

local function GetDistanceSquared(PosA, PosB) -- Returns squared magnitude between two positions
	local Vector = PosA - PosB
	return Vector:Dot(Vector)
end

--// Auxillary Variables

local DistanceToRecomputePathSquared = DistanceToRecomputePath ^ 2
local DistanceToChaseDirectlySquared = DistanceToChaseDirectly ^ 2

local FlatVector = Vector3.new(1, 0, 1)

--> Module <--

local module = {}
module.__index = module

module.PathComputeParams = {
	["DynamicTargetting"] = false, -- Retargetting to nearest player
	["CheckDirectMove"] = true,
	["CheckForDrops"] = true,
	["CheckDistance"] = true,
	["CheckSlope"] = true,
	["CheckLOF"] = true
}

module.Path = PathfindingService:CreatePath({
	WaypointSpacing = math.huge,
	CanJump = true
})

--// Auxillary Functions

function module:GetTargetPosition()
	if typeof(self.Target) == "Vector3" then
		return self.Target
	elseif self.Target:IsA("Model") then
		return self.Target.PrimaryPart.Position
	elseif self.Target:IsA("BasePart") then
		return self.Target.Position
	end
end

function module:GetTargetPart()
	if typeof(self.Target) == "Vector3" then
		return nil
	elseif self.Target:IsA("Model") then
		return self.Target.PrimaryPart
	elseif self.Target:IsA("BasePart") then
		return self.Target
	end
end

function module:GetRelations()
	if not self.PathComputeParams["CheckDirectMove"] then return nil end
	local VectorRaw = self:GetTargetPosition() - self.HumanoidRootPart.Position
	local RootPosition = self.HumanoidRootPart.Position
	local VectorFlat = VectorRaw * FlatVector

	local DropCheckOrigin = RootPosition + VectorFlat.Unit * DownOffset
	local LineOfSightResult = workspace:Raycast(RootPosition, VectorRaw, self.RaycastParams)
	local DropCheckResult = workspace:Raycast(DropCheckOrigin, DownVector, self.RaycastParams)

	local Slope = VectorRaw.Y / VectorFlat.Magnitude -- Rise / Run
	return {
		["InChaseDistance"] = GetDistanceSquared(self:GetTargetPosition(), RootPosition) < DistanceToChaseDirectlySquared,
		["LineOfSight"] = if LineOfSightResult then false else true,
		["DropCheck"] = DropCheckResult and true or false,
		["RelationVectorSlope"] = Slope
	}
end

function module:DisconnectPath()
	if self.Connections.ReachedConnection then self.Connections.ReachedConnection:Disconnect() self.Connections.ReachedConnection = nil end
	if self.Connections.BlockedConnection then self.Connections.BlockedConnection:Disconnect() self.Connections.BlockedConnection = nil end
end

function module:CheckIfFallen(ElevationDifference, CurrentWaypoint)
	return ElevationDifference > 8 and self.Waypoints[CurrentWaypoint].Action ~= Enum.PathWaypointAction.Jump
end

function module:HandleJump(Waypoint)
	if Waypoint and Waypoint.Action == Enum.PathWaypointAction.Jump then
		self.Humanoid.Jump = true
	end
end

function module:GetPathDistanceFromTargetSquared()
	return self.Waypoints[#self.Waypoints] and GetDistanceSquared(self.Waypoints[#self.Waypoints].Position, self:GetTargetPosition())
end

function module:CanMoveDirectly(Relations)
	return (
		(Relations["RelationVectorSlope"] < SlopeToChaseDirectly or not self.PathComputeParams["CheckSlope"]) and (Relations["InChaseDistance"] or
			not self.PathComputeParams["CheckDistance"]) and (Relations["DropCheck"] or not self.PathComputeParams["CheckForDrops"]) and
			(Relations["LineOfSight"] or not self.PathComputeParams["CheckLOF"])
	)
end

--// Index Change Functions

function module:EnabledChanged(NewValue)
	if not NewValue then
		self:DisconnectPath()
		self.Humanoid:MoveTo(self.HumanoidRootPart.Position)
	end
end

function module:TargetChanged(NewValue)
	if NewValue then
		local Character = NewValue
		if NewValue:IsA("BasePart") then
			Character = NewValue:FindFirstAncestorWhichIsA("Model")
			if Character == workspace then Character = nil end
		end
		self.RaycastParams.FilterDescendantsInstances = {workspace.Actors, Character, self.Character}
		self.PathComputeParams["CheckDirectMove"] = self.DefaultPathComputeParams["CheckDirectMove"]
	else
		self:DisconnectPath()
		self.Humanoid:MoveTo(self.HumanoidRootPart.Position)
	end
end

--// Main Functions

function module:Destroy()
	self.Enabled = false
	self.Target = false

	self:DisconnectPath()
	task.cancel(self.LifeThread)

	setmetatable(self, nil)
	table.clear(self)
end

function module:ComputePath()
	if not self.Target then return end
	local Success, Error = pcall(function()
		self.Path:ComputeAsync((self.HumanoidRootPart.CFrame * self.OffsetPath).Position, self:GetTargetPosition())
	end)

	if Success and self.Path.Status == Enum.PathStatus.Success then
		self.BindableEvents["PathStatusChanged"]:Fire("Pathfinding")
		local CurrentWaypoint = 2 -- The index of the current goal waypoint. Waypoints[#Waypoints] = Target Position | Waypoints[1] = Actor Start Position

		self.BindableEvents["PathComputed"]:Fire(self.Path)
		self.Waypoints = self.Path:GetWaypoints()
		self:DisconnectPath()

		self.Connections.BlockedConnection = self.Path.Blocked:Connect(function(WaypointIndex)
			if WaypointIndex >= CurrentWaypoint then self:ComputePath() end
		end)

		self.Connections.ReachedConnection = self.Humanoid.MoveToFinished:Connect(function(PointReached)
			if not PointReached then return end

			local ElevationDifference = (self.Waypoints[CurrentWaypoint] and self.Waypoints[CurrentWaypoint].Position.Y - self.HumanoidRootPart.Position.Y) or 0

			if self:CheckIfFallen(ElevationDifference, CurrentWaypoint) then -- We probably accidentally fell
				self.PathComputeParams["CheckDirectMove"] = self.DefaultPathComputeParams["CheckDirectMove"]
				self:ComputePath()
			elseif CurrentWaypoint < #self.Waypoints then -- We've reached the next waypoint of our path
				self.BindableEvents["WaypointReached"]:Fire(self.Waypoints[CurrentWaypoint])
				CurrentWaypoint += 1

				self:HandleJump(self.Waypoints[CurrentWaypoint])

				self.Humanoid:MoveTo(self.Waypoints[CurrentWaypoint] and self.Waypoints[CurrentWaypoint].Position or self.HumanoidRootPart.Position)
			else -- We've reached the final waypoint of our path and can now end
				self:DisconnectPath()
			end
		end)

		self.Humanoid:MoveTo(self.Waypoints[CurrentWaypoint] and self.Waypoints[CurrentWaypoint].Position or self.HumanoidRootPart.Position)
		self:HandleJump(self.Waypoints[CurrentWaypoint])
	end
end

function module:LifeCycle()
	if self.LifeThread then return end
	self.LifeThread = task.spawn(function()
		while true do
			if self.PathComputeParams["DynamicTargetting"] then
				local Target = nil
				local NearestDistance = math.huge
				for _, Player in pairs(Players:GetPlayers()) do
					if Player.Character and not Player.Character:GetAttribute("NonTarget") and Player.Character.PrimaryPart then
						local Distance = GetDistanceSquared(self.HumanoidRootPart.Position, Player.Character.PrimaryPart.Position)
						if Distance < NearestDistance then
							NearestDistance = Distance
							Target = Player.Character
						end
					end
				end
				if Target and Target ~= self.Target then
					self.Target = Target
				end
			end
			if self.Target and self.Enabled then
				local DistanceFromTarget = (self:GetTargetPosition() - self.HumanoidRootPart.Position).Magnitude
				self.TickRate = GetTickRate(DistanceFromTarget)

				local PathDistanceFromTargetSquared = self:GetPathDistanceFromTargetSquared()
				local Relations = self:GetRelations()

				if Relations and self:CanMoveDirectly(Relations) then
					self:DisconnectPath()
					self.BindableEvents["PathStatusChanged"]:Fire("Following")
					repeat
						self.Humanoid:MoveTo(self:GetTargetPosition(), self:GetTargetPart())
						task.wait(self.TickRate)
						Relations = self:GetRelations()
						if not Relations["DropCheck"] then
							self.PathComputeParams["CheckDirectMove"] = false
							self:ComputePath()
						end
					until not self:CanMoveDirectly(Relations)

					self.PathComputeParams["CheckDirectMove"] = self.DefaultPathComputeParams["CheckDirectMove"]
					self:ComputePath()
				elseif PathDistanceFromTargetSquared and PathDistanceFromTargetSquared > DistanceToRecomputePathSquared then
					self.PathComputeParams["CheckDirectMove"] = self.DefaultPathComputeParams["CheckDirectMove"]
					self:ComputePath()
				end

				self.LastVelocity = self.HumanoidRootPart.Velocity.Magnitude
				local VelocityCutOff = self.Humanoid.WalkSpeed * 0.3

				if self.LastVelocity < VelocityCutOff and (not PathDistanceFromTargetSquared or PathDistanceFromTargetSquared < 9) then
					task.wait(self.TickRate)
					if self.LastVelocity < VelocityCutOff then
						self.PathComputeParams["CheckDirectMove"] = self.DefaultPathComputeParams["CheckDirectMove"]
						self.Humanoid.Jump = true
						self:ComputePath()
					end
				end

			end

			task.wait(self.TickRate)
		end	
	end)
end

function module.New(Character, PathComputeParams)
	for _, BasePart in pairs(Character:GetDescendants()) do
		if BasePart:IsA("BasePart") then
			BasePart:SetNetworkOwnershipAuto(false)
			BasePart:SetNetworkOwner(nil)
		end
	end
	Character.Parent = workspace.Actors
	local NewActor = {}
	NewActor.HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart") or error(Character .. " does not have a humanoidrootpart")
	NewActor.Humanoid = Character:FindFirstChildWhichIsA("Humanoid") or error(Character .. " does not have a humanoid")
	NewActor.Character = Character

	NewActor.Waypoints = {}
	NewActor.Connections = {}

	NewActor.BindableEvents = {
		["PathStatusChanged"] = Instance.new("BindableEvent"),
		["WaypointReached"] = Instance.new("BindableEvent"),
		["PathComputed"] = Instance.new("BindableEvent"),
	}

	NewActor.PathStatusChanged = NewActor.BindableEvents["PathStatusChanged"].Event
	NewActor.WaypointReached = NewActor.BindableEvents["WaypointReached"].Event
	NewActor.PathComputed = NewActor.BindableEvents["PathComputed"].Event

	NewActor.DefaultPathComputeParams = PathComputeParams or module.PathComputeParams
	NewActor.PathComputeParams = ShallowCopy(NewActor.DefaultPathComputeParams)

	NewActor.RaycastParams = RaycastParams.new()
	NewActor.RaycastParams.FilterType = Enum.RaycastFilterType.Blacklist
	NewActor.RaycastParams.FilterDescendantsInstances = {workspace.Actors, Character, NewActor.Character}

	NewActor.Enabled = true

	NewActor.LastVelocity = Vector3.zero
	NewActor.OffsetPath = CFrame.new(0, 0, 1)
	NewActor.TickRate = 1

	NewActor.LifeThread = nil
	NewActor.Target = false

	NewActor.__index = NewActor

	NewActor.__newindex = function(Table, Index, Value)
		local ChangedFunction = NewActor[Index .. "Changed"]
		rawset(NewActor, Index, Value)
		if ChangedFunction then ChangedFunction(NewActor, Value) end
	end

	local ProxyTable = {}
	setmetatable(ProxyTable, NewActor)
	setmetatable(NewActor, module)

	return ProxyTable -- We can just use getmetatable to get NewActor for things such as iteration
end

return module
