--[[
	This is a highly optimized perlin noise method for pseudorandom map generation
	with persistent chunk saving for consistent world generation
	
	Made by wurq5
]]--
local WorldGenerator = {}

-- You may edit the settings below freely to your liking
local GRID_SCALE = 128 -- 128 studs
local RENDER_DISTANCE = 6
local ORIGIN_HEIGHT = 0 -- Starting height of the ground
local SKY_LIMIT_HEIGHT = 100
local MIN_TREES_PER_CHUNK = 2 -- Minimum number of trees per chunk
local MAX_TREES_PER_CHUNK = 7 -- Maximum number of trees per chunk
local TREE_MIN_DISTANCE = 10 -- Minimum distance between trees to prevent overlap
local TERRAIN_SMOOTHNESS = 3
local SEED = 300
local CHUNK_COOLDOWN = 0 -- Time in seconds between chunk processing to reduce lag
local BLOCK_SCALE = GRID_SCALE / 16  -- Each "block" is 1/16th of a chunk
local HEIGHT_STEP = 4 -- The step height
local HEIGHT_VARIATION_SCALE = 1 -- Reduce height changes (lower value = flatter world)

-- Do not edit below here
local FloorTiles, BarrierTile, Trees
local ChunkData = {} -- Currently loaded chunks
local ChunkKeys = {} -- For fast lookup of loaded chunks
local SavedChunkData = {} -- Persistent chunk data
local LastProcessedTime = 0
local ChunksToProcess = {} -- Queue for chunks to process

-- Public functions

-- Loads the chunks around the client
function WorldGenerator:LoadChunks(X, Z)
	-- Set random seed at the beginning of loading to avoid deterministic patterns
	math.randomseed(tick())

	-- Only process chunks periodically to reduce per-frame lag
	local CurrentTime = os.clock()
	if CurrentTime - LastProcessedTime < CHUNK_COOLDOWN then
		return
	end
	LastProcessedTime = CurrentTime

	-- Create a queue of chunks to process
	ChunksToProcess = {}

	local ScaledRenderDistance = RENDER_DISTANCE * GRID_SCALE
	local HalfScaledRenderDistance = ScaledRenderDistance * 0.5

	for PosX = 0, RENDER_DISTANCE do
		for PosZ = 0, RENDER_DISTANCE do
			local ScaledPosX, ScaledPosZ = PosX * GRID_SCALE, PosZ * GRID_SCALE
			local ActualPos = Vector2.new(X + (ScaledPosX - HalfScaledRenderDistance), Z + (ScaledPosZ - HalfScaledRenderDistance))

			if (ActualPos - Vector2.new(X, Z)).Magnitude <= ScaledRenderDistance then
				local SnappedX, SnappedZ = SnapToGrid(ActualPos.X, ActualPos.Y)
				local ChunkKey = GetChunkKey(SnappedX, SnappedZ)

				-- Only add to processing queue if not already loaded
				if not ChunkKeys[ChunkKey] then
					table.insert(ChunksToProcess, {
						X = SnappedX,
						Z = SnappedZ
					})
				end
			end
		end
	end

	-- Process a single chunk per frame to reduce lag
	if #ChunksToProcess > 0 then
		local ChunkInfo = table.remove(ChunksToProcess, 1)
		LoadOrCreateChunk(ChunkInfo.X, ChunkInfo.Z)
	end

	-- Unload chunks that are too far away
	self:UnloadChunks(X, Z)
end

-- Unloads chunks that are far from the client
function WorldGenerator:UnloadChunks(X, Z)
	local ScaledRenderDistance = RENDER_DISTANCE * GRID_SCALE

	-- Process only a few chunks per frame for unloading
	local ChunksToUnload = {}
	local MaxUnloadsPerFrame = 3

	for _, Chunk in pairs(ChunkData) do
		if Chunk.PrimaryPart then
			local ChunkPos = Vector2.new(Chunk.PrimaryPart.Position.X, Chunk.PrimaryPart.Position.Z)
			local PlayerPos = Vector2.new(X, Z)

			if (ChunkPos - PlayerPos).Magnitude > ScaledRenderDistance then
				table.insert(ChunksToUnload, Chunk)
				if #ChunksToUnload >= MaxUnloadsPerFrame then
					break
				end
			end
		end
	end

	-- Unload the selected chunks
	for _, Chunk in ipairs(ChunksToUnload) do
		UnloadChunk(Chunk.PrimaryPart.Position.X, Chunk.PrimaryPart.Position.Z)
	end
end

-- Provide the parts to be used in generation
function WorldGenerator:Settings(Floor, Barrier, TreeTable)
	FloorTiles = Floor
	BarrierTile = Barrier
	Trees = TreeTable
end

-- Private functions
function GetChunkKey(X, Z)
	return X .. "," .. Z
end

function CalculateNoise(X, Z)
	local DividedX = X / TERRAIN_SMOOTHNESS
	local DividedZ = Z / TERRAIN_SMOOTHNESS

	local NoiseValue = math.noise(DividedX, DividedZ, SEED) -- Between -1 and 1
	local HeightVariation = NoiseValue * HEIGHT_VARIATION_SCALE -- Reduce variation

	-- Snap height to "step" levels to create a blocky effect
	local SteppedHeight = math.floor((ORIGIN_HEIGHT + HeightVariation * 10) / HEIGHT_STEP) * HEIGHT_STEP

	return SteppedHeight
end

-- Check if a tree position would overlap with existing trees
function IsTreePositionValid(TreePositions, NewX, NewZ)
	for _, pos in ipairs(TreePositions) do
		local distanceSquared = (NewX - pos.X)^2 + (NewZ - pos.Z)^2
		if distanceSquared < (TREE_MIN_DISTANCE * TREE_MIN_DISTANCE) then
			return false -- Too close to an existing tree
		end
	end
	return true -- Position is valid
end

-- Generate tree positions that don't overlap
function GenerateTreePositions(X, Z, ChunkHeight)
	local TreePositions = {}

	-- Use deterministic seed for this chunk to ensure consistent generation
	local ChunkSeed = X * 1000 + Z * 10 + SEED
	math.randomseed(ChunkSeed)

	-- Determine how many trees to place
	local TreeCount = math.random(MIN_TREES_PER_CHUNK, MAX_TREES_PER_CHUNK)

	for i = 1, TreeCount do
		local attempts = 0
		local validPosition = false
		local newX, newZ

		while not validPosition and attempts < 20 do
			attempts = attempts + 1

			-- Generate random offset within the chunk
			local OffsetX = (math.random() - 0.5) * (GRID_SCALE * 0.8)
			local OffsetZ = (math.random() - 0.5) * (GRID_SCALE * 0.8)

			newX = X + OffsetX
			newZ = Z + OffsetZ

			-- Check if position is valid
			if IsTreePositionValid(TreePositions, newX, newZ) then
				validPosition = true
				-- Use the chunk height for consistent placement
				table.insert(TreePositions, {X = newX, Z = newZ, Y = ChunkHeight})
			end
		end
	end

	return TreePositions
end

-- Save chunk data for future reloading
function SaveChunkData(X, Z, ChunkModel)
	local ChunkKey = GetChunkKey(X, Z)

	-- Extract tree positions from the chunk model
	local TreePositions = {}
	for _, Object in pairs(ChunkModel:GetChildren()) do
		-- Check if this is a tree model
		if Object:IsA("Model") and Object.Name:find("Tree") then
			if Object.PrimaryPart then
				-- Store tree position relative to chunk
				local TreePos = Object.PrimaryPart.Position
				table.insert(TreePositions, {
					OffsetX = TreePos.X - X,
					OffsetY = TreePos.Y - ChunkModel.PrimaryPart.Position.Y, -- Store offset from chunk height
					OffsetZ = TreePos.Z - Z
				})
			end
		end
	end

	-- Save chunk data for later loading
	SavedChunkData[ChunkKey] = {
		X = X,
		Z = Z,
		Height = ChunkModel.PrimaryPart.Position.Y,
		Trees = TreePositions
	}
end

-- Load a chunk either from saved data or create a new one
function LoadOrCreateChunk(X, Z)
	local ChunkKey = GetChunkKey(X, Z)

	-- Check if chunk already exists
	if ChunkKeys[ChunkKey] then
		return
	end

	-- Check if we have saved data for this chunk
	if SavedChunkData[ChunkKey] then
		CreateChunkFromSaved(SavedChunkData[ChunkKey])
	else
		-- Calculate the base height for this chunk
		local ChunkHeight = CalculateNoise(X, Z)
		-- Generate a new chunk
		CreateNewChunk(X, Z, ChunkHeight)
	end
end

function CreateNewChunk(X, Z, ChunkHeight)
	local ChunkKey = GetChunkKey(X, Z)

	-- Create the base Plains chunk
	local ChunkModel = FloorTiles.Plains:Clone()
	if not ChunkModel.PrimaryPart then
		warn("ChunkModel has no PrimaryPart - cannot create chunk")
		ChunkModel:Destroy()
		return
	end

	-- Position the chunk at the correct height
	ChunkModel:PivotTo(CFrame.new(X, ChunkHeight, Z))

	-- Generate tree positions
	local TreePositions = GenerateTreePositions(X, Z, ChunkHeight)

	-- Add trees if we have the tree model
	if Trees and Trees.Tree then
		for _, TreePos in ipairs(TreePositions) do
			local TreeModel = Trees.Tree:Clone()

			if TreeModel.PrimaryPart then
				-- Position the tree flat with the floor tile
				-- Here we place the tree directly on top of the chunk (at the same height)
				-- The tree's own pivot point should already account for it sitting correctly on the ground
				TreeModel:PivotTo(CFrame.new(
					TreePos.X,
					ChunkHeight + 78.897, -- Place directly on the chunk surface
					TreePos.Z
					))
				TreeModel.Parent = ChunkModel
			else
				warn("Tree model has no PrimaryPart")
				TreeModel:Destroy()
			end
		end
	else
		warn("Trees or Trees.Tree is missing")
	end

	-- Register chunk in tracking systems
	ChunkModel.Parent = workspace
	table.insert(ChunkData, ChunkModel)
	ChunkKeys[ChunkKey] = true

	-- Save the chunk data
	SaveChunkData(X, Z, ChunkModel)
end

function CreateChunkFromSaved(ChunkInfo)
	local X, Z = ChunkInfo.X, ChunkInfo.Z
	local ChunkKey = GetChunkKey(X, Z)
	local ChunkHeight = ChunkInfo.Height or ORIGIN_HEIGHT

	-- Create the base Plains chunk
	local ChunkModel = FloorTiles.Plains:Clone()
	if not ChunkModel.PrimaryPart then
		warn("ChunkModel has no PrimaryPart")
		ChunkModel:Destroy()
		return
	end

	-- Position the chunk at the saved height
	ChunkModel:PivotTo(CFrame.new(X, ChunkHeight, Z))

	-- Add trees from saved data
	if Trees and Trees.Tree then
		for _, TreeInfo in ipairs(ChunkInfo.Trees) do
			local TreeModel = Trees.Tree:Clone()

			if TreeModel.PrimaryPart then
				-- Place the tree using saved offset from chunk surface
				TreeModel:PivotTo(CFrame.new(
					X + TreeInfo.OffsetX,
					ChunkHeight + TreeInfo.OffsetY, -- Use offset from chunk height
					Z + TreeInfo.OffsetZ
					))
				TreeModel.Parent = ChunkModel
			else
				warn("Tree model has no PrimaryPart")
				TreeModel:Destroy()
			end
		end
	end

	-- Register chunk in tracking systems
	ChunkModel.Parent = workspace
	table.insert(ChunkData, ChunkModel)
	ChunkKeys[ChunkKey] = true
end

function UnloadChunk(X, Z)
	local SnappedX, SnappedZ = SnapToGrid(X, Z)
	local ChunkKey = GetChunkKey(SnappedX, SnappedZ)

	-- Find the chunk to unload
	for Index, Chunk in pairs(ChunkData) do
		if Chunk.PrimaryPart then
			local CurrentX, CurrentZ = SnapToGrid(Chunk.PrimaryPart.Position.X, Chunk.PrimaryPart.Position.Z)
			local CurrentKey = GetChunkKey(CurrentX, CurrentZ)

			if CurrentKey == ChunkKey then
				-- Save the chunk data before removing it
				SaveChunkData(SnappedX, SnappedZ, Chunk)

				-- Remove the chunk
				Chunk:Destroy()
				table.remove(ChunkData, Index)
				ChunkKeys[ChunkKey] = nil
				return
			end
		end
	end
end

function SnapToGrid(X, Z)
	return math.floor(X / GRID_SCALE + 0.5) * GRID_SCALE, math.floor(Z / GRID_SCALE + 0.5) * GRID_SCALE
end

-- Make functions available to the module
WorldGenerator.SnapToGrid = SnapToGrid

-- Saves the current world state and exports it
function WorldGenerator:SaveAllChunks()
	for _, Chunk in pairs(ChunkData) do
		if Chunk.PrimaryPart then
			local X, Z = SnapToGrid(Chunk.PrimaryPart.Position.X, Chunk.PrimaryPart.Position.Z)
			SaveChunkData(X, Z, Chunk)
		end
	end
	return SavedChunkData -- Return the data in case you want to serialize it
end

-- Set saved chunk data to reload previously exported data
function WorldGenerator:SetSavedChunkData(Data)
	SavedChunkData = Data or {}
end

-- Clears the saved data
function WorldGenerator:ClearSavedData()
	SavedChunkData = {}
	return "Cleared all saved chunk data"
end

return WorldGenerator
