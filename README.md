The world generation module has multiple uses as it is very editable with a very simple API:

Example API:
```
local WorldGenerationModule = require(PathToModule)
local RunService = game:GetService("RunService")

local Player = game.Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")


-- Setup the Blocks to be used in generation
local FloorTiles = {
  Plains = script.Plains;
  Block = script.Block;
  Step = script.Step;
}

local Trees = {
  Tree = script.Tree;
}

WorldGenerationModules:Settings(FloorTiles, nil, Trees) -- The module currently doesn't have functionality for the barriers around the generated map however it will be updated eventually

RunService.RenderStepped:Connect(function()
  WorldGenerationModule:LoadChunks(HumanoidRootPart.Position.X, HumanoidRootPart.Position.Z)
end)
```
