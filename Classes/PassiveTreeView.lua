-- Path of Building
--
-- Class: Passive Tree View
-- Passive skill tree viewer.
-- Draws the passive skill tree, and also maintains the current view settings (zoom level, position, etc)
--

local bit = require("bit")

local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local m_max = math.max
local m_floor = math.floor
local band = bit.band
local b_rshift = bit.rshift

local PassiveTreeViewClass = newClass("PassiveTreeView", function(self)
	self.ring = NewImageHandle()
	self.ring:Load("Assets/ring.png", "CLAMP")
	self.highlightRing = NewImageHandle()
	self.highlightRing:Load("Assets/small_ring.png", "CLAMP")

	self.tooltip = new("Tooltip")

	self.zoomLevel = 3
	self.zoom = 1.2 ^ self.zoomLevel
	self.zoomX = 0
	self.zoomY = 0

	self.searchStr = ""
	self.searchStrCached = ""
	self.searchStrResults = {}
	self.searchResultColormap = {
		-- Color list generated from Google's FOSS colormap, 'Turbo':
		{r = 0.941, g = 0.356, b = 0.070},
		{r = 0.996, g = 0.643, b = 0.192},
		{r = 0.883, g = 0.866, b = 0.217},
		{r = 0.644, g = 0.990, b = 0.234},
		{r = 0.276, g = 0.971, b = 0.517},
		{r = 0.098, g = 0.837, b = 0.803},
		{r = 0.244, g = 0.609, b = 0.997},
		{r = 0.270, g = 0.349, b = 0.796},
	}
	self.searchTermsLimit = #self.searchResultColormap
	self.searchTermSentinal = "|"

	self.showStatDifferences = true
end)

function PassiveTreeViewClass:Load(xml, fileName)
	if xml.attrib.zoomLevel then
		self.zoomLevel = tonumber(xml.attrib.zoomLevel)
		self.zoom = 1.2 ^ self.zoomLevel
	end
	if xml.attrib.zoomX and xml.attrib.zoomY then
		self.zoomX = tonumber(xml.attrib.zoomX)
		self.zoomY = tonumber(xml.attrib.zoomY)
	end
	if xml.attrib.searchStr then
		self.searchStr = xml.attrib.searchStr
	end
	if xml.attrib.showHeatMap then
		self.showHeatMap = xml.attrib.showHeatMap == "true"
	end
	if xml.attrib.showStatDifferences then
		self.showStatDifferences = xml.attrib.showStatDifferences == "true"
	end
end

function PassiveTreeViewClass:Save(xml)
	xml.attrib = {
		zoomLevel = tostring(self.zoomLevel),
		zoomX = tostring(self.zoomX),
		zoomY = tostring(self.zoomY),
		searchStr = self.searchStr,
		showHeatMap = tostring(self.showHeatMap),
		showStatDifferences = tostring(self.showStatDifferences),
	}
end

function PassiveTreeViewClass:Draw(build, viewPort, inputEvents)
	local spec = build.spec
	local tree = spec.tree

	local cursorX, cursorY = GetCursorPos()
	local mOver = cursorX >= viewPort.x and cursorX < viewPort.x + viewPort.width and cursorY >= viewPort.y and cursorY < viewPort.y + viewPort.height
	
	-- Process input events
	local treeClick
	for id, event in ipairs(inputEvents) do
		if event.type == "KeyDown" then
			if event.key == "LEFTBUTTON" then
				if mOver then
					-- Record starting coords of mouse drag
					-- Dragging won't actually commence unless the cursor moves far enough
					self.dragX, self.dragY = cursorX, cursorY
				end
			elseif event.key == "p" then
				self.showHeatMap = not self.showHeatMap
			elseif event.key == "d" and IsKeyDown("CTRL") then
				self.showStatDifferences = not self.showStatDifferences
			elseif event.key == "PAGEUP" then
				self:Zoom(IsKeyDown("SHIFT") and 3 or 1, viewPort)
			elseif event.key == "PAGEDOWN" then
				self:Zoom(IsKeyDown("SHIFT") and -3 or -1, viewPort)
			end
		elseif event.type == "KeyUp" then
			if event.key == "LEFTBUTTON" then
				if self.dragX and not self.dragging then
					-- Mouse button went down, but didn't move far enough to trigger drag, so register a normal click
					treeClick = "LEFT"
				end
			elseif mOver then
				if event.key == "RIGHTBUTTON" then
					treeClick = "RIGHT"
				elseif event.key == "WHEELUP" then
					self:Zoom(IsKeyDown("SHIFT") and 3 or 1, viewPort)
				elseif event.key == "WHEELDOWN" then
					self:Zoom(IsKeyDown("SHIFT") and -3 or -1, viewPort)
				end	
			end
		end
	end

	if not IsKeyDown("LEFTBUTTON") then
		-- Left mouse button isn't down, stop dragging if dragging was in progress
		self.dragging = false
		self.dragX, self.dragY = nil, nil
	end
	if self.dragX then
		-- Left mouse is down
		if not self.dragging then
			-- Check if mouse has moved more than a few pixels, and if so, initiate dragging
			if math.abs(cursorX - self.dragX) > 5 or math.abs(cursorY - self.dragY) > 5 then
				self.dragging = true
			end
		end
		if self.dragging then
			self.zoomX = self.zoomX + cursorX - self.dragX
			self.zoomY = self.zoomY + cursorY - self.dragY
			self.dragX, self.dragY = cursorX, cursorY
		end
	end

	-- Ctrl-click to zoom
	if treeClick and IsKeyDown("CTRL") then
		self:Zoom(treeClick == "RIGHT" and -2 or 2, viewPort)
		treeClick = nil
	end

	-- Clamp zoom offset
	local clampFactor = self.zoom * 2 / 3
	self.zoomX = m_min(m_max(self.zoomX, -viewPort.width * clampFactor), viewPort.width * clampFactor)
	self.zoomY = m_min(m_max(self.zoomY, -viewPort.height * clampFactor), viewPort.height * clampFactor)

	-- Create functions that will convert coordinates between the screen and tree coordinate spaces
	local scale = m_min(viewPort.width, viewPort.height) / tree.size * self.zoom
	local offsetX = self.zoomX + viewPort.x + viewPort.width/2
	local offsetY = self.zoomY + viewPort.y + viewPort.height/2
	local function treeToScreen(x, y)
		return x * scale + offsetX,
		       y * scale + offsetY
	end
	local function screenToTree(x, y)
		return (x - offsetX) / scale,
		       (y - offsetY) / scale
	end

	if IsKeyDown("SHIFT") then
		-- Enable path tracing mode
		self.traceMode = true
		self.tracePath = self.tracePath or { }
	else
		self.traceMode = false
		self.tracePath = nil
	end

	local hoverNode
	if mOver then
		-- Cursor is over the tree, check if it is over a node
		local curTreeX, curTreeY = screenToTree(cursorX, cursorY)
		for nodeId, node in pairs(spec.nodes) do
			if node.rsq and node.group and not node.isProxy and not node.group.isProxy then
				-- Node has a defined size (i.e has artwork)
				local vX = curTreeX - node.x
				local vY = curTreeY - node.y
				if vX * vX + vY * vY <= node.rsq then
					hoverNode = node
					break
				end
			end
		end
	end

	-- If hovering over a node, find the path to it (if unallocated) or the list of dependant nodes (if allocated)
	local hoverPath, hoverDep
	if self.traceMode then
		-- Path tracing mode is enabled
		if hoverNode then
			if not hoverNode.path then
				-- Don't highlight the node if it can't be pathed to
				hoverNode = nil
			elseif not self.tracePath[1] then
				-- Initialise the trace path using this node's path
				for _, pathNode in ipairs(hoverNode.path) do
					t_insert(self.tracePath, 1, pathNode)
				end
			else
				local lastPathNode = self.tracePath[#self.tracePath]
				if hoverNode ~= lastPathNode then
					-- If node is directly linked to the last node in the path, add it
					if isValueInArray(hoverNode.linked, lastPathNode) then
						local index = isValueInArray(self.tracePath, hoverNode)
						if index then
							-- Node is already in the trace path, remove it first
							t_remove(self.tracePath, index)
						end
						t_insert(self.tracePath, hoverNode)	
					else
						hoverNode = nil
					end
				end
			end
		end
		-- Use the trace path as the path 
		hoverPath = { }
		for _, pathNode in pairs(self.tracePath) do
			hoverPath[pathNode] = true
		end
	elseif hoverNode and hoverNode.path then
		-- Use the node's own path and dependance list
		hoverPath = { }
		if not hoverNode.dependsOnIntuitiveLeap then
			for _, pathNode in pairs(hoverNode.path) do
				hoverPath[pathNode] = true
			end
		end
		hoverDep = { }
		for _, depNode in pairs(hoverNode.depends) do
			hoverDep[depNode] = true
		end
	end

	if treeClick == "LEFT" then
		if hoverNode then
			-- User left-clicked on a node
			if hoverNode.alloc then
				-- Node is allocated, so deallocate it
				spec:DeallocNode(hoverNode)
				spec:AddUndoState()
				build.buildFlag = true
			elseif hoverNode.path then
				-- Node is unallocated and can be allocated, so allocate it
				spec:AllocNode(hoverNode, self.tracePath and hoverNode == self.tracePath[#self.tracePath] and self.tracePath)
				spec:AddUndoState()
				build.buildFlag = true
			end
		end
	elseif treeClick == "RIGHT" then
		if hoverNode and hoverNode.alloc and hoverNode.type == "Socket" then
			local slot = build.itemsTab.sockets[hoverNode.id]
			if slot:IsEnabled() then
				-- User right-clicked a jewel socket, jump to the item page and focus the corresponding item slot control
				slot.dropped = true
				build.itemsTab:SelectControl(slot)
				build.viewMode = "ITEMS"
			end
		end
	end

	-- Draw the background artwork
	local bg = tree.assets.Background1
	if bg.width == 0 then
		bg.width, bg.height = bg.handle:ImageSize()
	end
	if bg.width > 0 then
		local bgSize = bg.width * scale * 1.33 * 2.5
		SetDrawColor(1, 1, 1)
		DrawImage(bg.handle, viewPort.x, viewPort.y, viewPort.width, viewPort.height, (self.zoomX + viewPort.width/2) / -bgSize, (self.zoomY + viewPort.height/2) / -bgSize, (viewPort.width/2 - self.zoomX) / bgSize, (viewPort.height/2 - self.zoomY) / bgSize)
	end

	-- Hack to draw class background art, the position data doesn't seem to be in the tree JSON yet
	if build.spec.curClassId == 1 then
		local scrX, scrY = treeToScreen(-2750, 1600)
		self:DrawAsset(tree.assets.BackgroundStr, scrX, scrY, scale)
	elseif build.spec.curClassId == 2 then
		local scrX, scrY = treeToScreen(2550, 1600)
		self:DrawAsset(tree.assets.BackgroundDex, scrX, scrY, scale)
	elseif build.spec.curClassId == 3 then
		local scrX, scrY = treeToScreen(-250, -2200)
		self:DrawAsset(tree.assets.BackgroundInt, scrX, scrY, scale)
	elseif build.spec.curClassId == 4 then
		local scrX, scrY = treeToScreen(-150, 2350)
		self:DrawAsset(tree.assets.BackgroundStrDex, scrX, scrY, scale)
	elseif build.spec.curClassId == 5 then
		local scrX, scrY = treeToScreen(-2100, -1500)
		self:DrawAsset(tree.assets.BackgroundStrInt, scrX, scrY, scale)
	elseif build.spec.curClassId == 6 then
		local scrX, scrY = treeToScreen(2350, -1950)
		self:DrawAsset(tree.assets.BackgroundDexInt, scrX, scrY, scale)
	end

	local function renderGroup(group, isExpansion)
		local scrX, scrY = treeToScreen(group.x, group.y)
		if group.ascendancyName then
			if group.isAscendancyStart then
				if group.ascendancyName ~= spec.curAscendClassName then
					SetDrawColor(1, 1, 1, 0.25)
				end
				self:DrawAsset(tree.assets["Classes"..group.ascendancyName], scrX, scrY, scale)
				SetDrawColor(1, 1, 1)
			end
		elseif group.oo[3] then
			self:DrawAsset(tree.assets[isExpansion and "GroupBackgroundLargeHalfAlt" or "PSGroupBackground3"], scrX, scrY, scale, true)
		elseif group.oo[2] then
			self:DrawAsset(tree.assets[isExpansion and "GroupBackgroundMediumAlt" or "PSGroupBackground2"], scrX, scrY, scale)
		elseif group.oo[1] then
			self:DrawAsset(tree.assets[isExpansion and "GroupBackgroundSmallAlt" or "PSGroupBackground1"], scrX, scrY, scale)
		end
	end

	-- Draw the group backgrounds
	for _, group in pairs(tree.groups) do
		if not group.isProxy then
			renderGroup(group)
		end
	end
	for _, subGraph in pairs(spec.subGraphs) do
		renderGroup(subGraph.group, true)
	end

	local function renderConnector(connector)
		local node1, node2 = spec.nodes[connector.nodeId1], spec.nodes[connector.nodeId2]

		-- Determine the connector state
		local state = "Normal"
		if node1.alloc and node2.alloc then	
			state = "Active"
		elseif hoverPath then
			if (node1.alloc or node1 == hoverNode or hoverPath[node1]) and (node2.alloc or node2 == hoverNode or hoverPath[node2]) then
				state = "Intermediate"
			end
		end

		-- Convert vertex coordinates to screen-space and add them to the coordinate array
		local vert = connector.vert[state]
		connector.c[1], connector.c[2] = treeToScreen(vert[1], vert[2])
		connector.c[3], connector.c[4] = treeToScreen(vert[3], vert[4])
		connector.c[5], connector.c[6] = treeToScreen(vert[5], vert[6])
		connector.c[7], connector.c[8] = treeToScreen(vert[7], vert[8])

		if hoverDep and hoverDep[node1] and hoverDep[node2] then
			-- Both nodes depend on the node currently being hovered over, so color the line red
			SetDrawColor(1, 0, 0)
		elseif connector.ascendancyName and connector.ascendancyName ~= spec.curAscendClassName then
			-- Fade out lines in ascendancy classes other than the current one
			SetDrawColor(0.75, 0.75, 0.75)
		end
		DrawImageQuad(tree.assets[connector.type..state].handle, unpack(connector.c))
		SetDrawColor(1, 1, 1)
	end

	-- Draw the connecting lines between nodes
	SetDrawLayer(nil, 20)
	for _, connector in pairs(tree.connectors) do
		renderConnector(connector)
	end
	for _, subGraph in pairs(spec.subGraphs) do
		for _, connector in pairs(subGraph.connectors) do
			renderConnector(connector)
		end
	end

	if self.showHeatMap then
		-- Build the power numbers if needed
		build.calcsTab:BuildPower()
	end

	-- Update cached node search data
	if self.searchStrCached ~= self.searchStr then
		self:UpdateSearchCache(spec.nodes)
		self.searchStrCached = self.searchStr
	end

	-- Draw the nodes
	for nodeId, node in pairs(spec.nodes) do
		-- Determine the base and overlay images for this node based on type and state
		local base, overlay
		local isAlloc = node.alloc or build.calcsTab.mainEnv.grantedPassives[nodeId]
		SetDrawLayer(nil, 25)
		if node.type == "ClassStart" then
			overlay = isAlloc and node.startArt or "PSStartNodeBackgroundInactive"
		elseif node.type == "AscendClassStart" then
			overlay = treeVersions[tree.treeVersion].num >= 3.10 and "AscendancyMiddle" or "PassiveSkillScreenAscendancyMiddle"
		elseif node.type == "Mastery" then
			-- This is the icon that appears in the center of many groups
			SetDrawLayer(nil, 15)
			base = node.sprites.mastery
		else
			local state
			if self.showHeatMap or isAlloc or node == hoverNode or (self.traceMode and node == self.tracePath[#self.tracePath])then
				-- Show node as allocated if it is being hovered over
				-- Also if the heat map is turned on (makes the nodes more visible)
				state = "alloc"
			elseif hoverPath and hoverPath[node] then
				state = "path"
			else
				state = "unalloc"
			end
			if node.type == "Socket" then
				-- Node is a jewel socket, retrieve the socketed jewel (if present) so we can display the correct art
				base = tree.assets[node.overlay[state .. (node.expansionJewel and "Alt" or "")]]
				local socket, jewel = build.itemsTab:GetSocketAndJewelForNodeID(nodeId)
				if isAlloc and jewel then
					if jewel.baseName == "Crimson Jewel" then
						overlay = node.expansionJewel and "JewelSocketActiveRedAlt" or "JewelSocketActiveRed"
					elseif jewel.baseName == "Viridian Jewel" then
						overlay = node.expansionJewel and "JewelSocketActiveGreenAlt" or "JewelSocketActiveGreen"
					elseif jewel.baseName == "Cobalt Jewel" then
						overlay = node.expansionJewel and "JewelSocketActiveBlueAlt" or "JewelSocketActiveBlue"
					elseif jewel.baseName == "Prismatic Jewel" then
						overlay = node.expansionJewel and "JewelSocketActivePrismaticAlt" or "JewelSocketActivePrismatic"
					elseif jewel.baseName == "Timeless Jewel" then
						overlay = node.expansionJewel and "JewelSocketActiveLegionAlt" or "JewelSocketActiveLegion"
					elseif jewel.base.subType == "Abyss" then
						overlay = node.expansionJewel and "JewelSocketActiveAbyssAlt" or "JewelSocketActiveAbyss"
					elseif jewel.baseName == "Large Cluster Jewel" then
						-- Temp; waiting for art :/
						overlay = "JewelSocketActiveGreenAlt"
					elseif jewel.baseName == "Medium Cluster Jewel" then
						-- Temp; waiting for art :/
						overlay = "JewelSocketActiveBlueAlt"
					elseif jewel.baseName == "Small Cluster Jewel" then
						-- Temp; waiting for art :/
						overlay = "JewelSocketActiveRedAlt"
					end
				end
			else
				-- Normal node (includes keystones and notables)
				base = node.sprites[node.type:lower()..(isAlloc and "Active" or "Inactive")] 
				overlay = node.overlay[state .. (node.ascendancyName and "Ascend" or "") .. (node.isBlighted and "Blighted" or "")]
			end
		end

		-- Convert node position to screen-space
		local scrX, scrY = treeToScreen(node.x, node.y)
	
		-- Determine color for the base artwork
		if self.showHeatMap then
			if not isAlloc and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
				-- Calculate color based on DPS and defensive powers
				local offence = m_max(node.power.offence or 0, 0)
				local defence = m_max(node.power.defence or 0, 0)
				local dpsCol = (offence / build.calcsTab.powerMax.offence * 1.5) ^ 0.5
				local defCol = (defence / build.calcsTab.powerMax.defence * 1.5) ^ 0.5
				local mixCol = (m_max(dpsCol - 0.5, 0) + m_max(defCol - 0.5, 0)) / 2
				if main.nodePowerTheme == "RED/BLUE" then
					SetDrawColor(dpsCol, mixCol, defCol)
				elseif main.nodePowerTheme == "RED/GREEN" then
					SetDrawColor(dpsCol, defCol, mixCol)
				elseif main.nodePowerTheme == "GREEN/BLUE" then
					SetDrawColor(mixCol, dpsCol, defCol)
				end
			else
				SetDrawColor(1, 1, 1)
			end
		elseif launch.devModeAlt then
			-- Debug display
			if node.extra then
				SetDrawColor(1, 0, 0)
			elseif node.unknown then
				SetDrawColor(0, 1, 1)
			else
				SetDrawColor(0, 0, 0)
			end
		else
			SetDrawColor(1, 1, 1)
		end
		
		-- Draw base artwork
		if base then
			self:DrawAsset(base, scrX, scrY, scale)
		end

		if overlay then
			-- Draw overlay
			if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
				if hoverNode and hoverNode ~= node then
					-- Mouse is hovering over a different node
					if hoverDep and hoverDep[node] then
						-- This node depends on the hover node, turn it red
						SetDrawColor(1, 0, 0)
					elseif hoverNode.type == "Socket" and hoverNode.nodesInRadius then
						-- Hover node is a socket, check if this node falls within its radius and color it accordingly
						for index, data in ipairs(build.data.jewelRadius) do
							if hoverNode.nodesInRadius[index][node.id] then
								SetDrawColor(data.col)
								break
							end
						end
					end
				end
			end
			self:DrawAsset(tree.assets[overlay], scrX, scrY, scale)
			SetDrawColor(1, 1, 1)
		end
		if self.searchStrResults[nodeId] and self.searchStrResults[nodeId] ~= 0 then
			local searchResultsCounter = 0
			for searchIndex=1,self.searchTermsLimit do
				-- minus one to convert from one-based counting to zero-based
				if bit.band(self.searchStrResults[nodeId], (2 ^ (searchIndex - 1))) ~= 0 then
					SetDrawLayer(nil, 35 - searchResultsCounter)
					SetDrawColor(
						self.searchResultColormap[searchIndex].r,
						self.searchResultColormap[searchIndex].g,
						self.searchResultColormap[searchIndex].b
					)
					local size = (175 + 25 * (searchResultsCounter)) * scale / self.zoom ^ 0.4
					DrawImage(self.highlightRing, scrX - size, scrY - size, size * 2, size * 2)
					searchResultsCounter = searchResultsCounter + 1
				end
			end
		end

		if node == hoverNode and (node.type ~= "Socket" or not IsKeyDown("SHIFT")) and not main.popups[1] then
			-- Draw tooltip
			SetDrawLayer(nil, 100)
			local size = m_floor(node.size * scale)
			if self.tooltip:CheckForUpdate(node, self.showStatDifferences, self.tracePath, launch.devModeAlt, build.outputRevision) then
				self:AddNodeTooltip(self.tooltip, node, build)
			end
			self.tooltip:Draw(m_floor(scrX - size), m_floor(scrY - size), size * 2, size * 2, viewPort)
		end
	end
	
	-- Draw ring overlays for jewel sockets
	SetDrawLayer(nil, 25)
	for nodeId in pairs(tree.sockets) do
		local node = spec.nodes[nodeId]
		if node and (not node.expansionJewel or node.expansionJewel.size == 2) then
			if node == hoverNode then
				-- Mouse is over this socket, show all radius rings
				local scrX, scrY = treeToScreen(node.x, node.y)
				for _, radData in ipairs(build.data.jewelRadius) do
					local size = radData.rad * scale
					SetDrawColor(radData.col)
					DrawImage(self.ring, scrX - size, scrY - size, size * 2, size * 2)
				end
			elseif node.alloc then
				local socket, jewel = build.itemsTab:GetSocketAndJewelForNodeID(nodeId)
				if jewel and jewel.jewelRadiusIndex then
					-- Socket is allocated and there's a jewel socketed into it which has a radius, so show it
					local scrX, scrY = treeToScreen(node.x, node.y)
					local radData = build.data.jewelRadius[jewel.jewelRadiusIndex]
					local size = radData.rad * scale
					SetDrawColor(radData.col)
					DrawImage(self.ring, scrX - size, scrY - size, size * 2, size * 2)				
				end
			end
		end
	end
end

-- Draws the given asset at the given position
function PassiveTreeViewClass:DrawAsset(data, x, y, scale, isHalf)
	if not data then
		return
	end
	if data.width == 0 then
		data.width, data.height = data.handle:ImageSize()
		if data.width == 0 then
			return
		end
	end
	local width = data.width * scale * 1.33
	local height = data.height * scale * 1.33
	if isHalf then
		DrawImage(data.handle, x - width, y - height * 2, width * 2, height * 2)
		DrawImage(data.handle, x - width, y, width * 2, height * 2, 0, 1, 1, 0)
	else
		DrawImage(data.handle, x - width, y - height, width * 2, height * 2, unpack(data))
	end
end

-- Zoom the tree in or out
function PassiveTreeViewClass:Zoom(level, viewPort)
	-- Calculate new zoom level and zoom factor
	self.zoomLevel = m_max(0, m_min(12, self.zoomLevel + level))
	local oldZoom = self.zoom
	self.zoom = 1.2 ^ self.zoomLevel

	-- Adjust zoom center position so that the point on the tree that is currently under the mouse will remain under it
	local factor = self.zoom / oldZoom
	local cursorX, cursorY = GetCursorPos()
	local relX = cursorX - viewPort.x - viewPort.width/2
	local relY = cursorY - viewPort.y - viewPort.height/2
	self.zoomX = relX + (self.zoomX - relX) * factor
	self.zoomY = relY + (self.zoomY - relY) * factor
end

-- Parse searchStr and update searchStrResults cache
function PassiveTreeViewClass:UpdateSearchCache(nodes)
	local searchTerms = {}
	-- split searchStr on searchTermSentinal
	local i = 1
	for term in string.gmatch(self.searchStr, "[^"..self.searchTermSentinal.."]+") do
		searchTerms[i] = term
		i = i + 1
	end

	for nodeId, node in pairs(nodes) do
		local resultBitmap = 0

		for termIndex=1,self.searchTermsLimit do
			if searchTerms[termIndex] and self:DoesNodeMatchSearchStr(searchTerms[termIndex], node) then
				-- minus one to convert from one-based counting to zero-based
				resultBitmap = bit.bor(resultBitmap, (2 ^ (termIndex - 1)))
			end
		end

		self.searchStrResults[nodeId] = resultBitmap
	end
end

function PassiveTreeViewClass:DoesNodeMatchSearchStr(searchTerm, node)
	if node.type == "ClassStart" or node.type == "Mastery" then
		return
	end

	-- Check node name
	local errMsg, match = PCall(string.match, node.dn:lower(), searchTerm:lower())
	if match then
		return true
	end

	-- Check node description
	for index, line in ipairs(node.sd) do
		-- Check display text first
		errMsg, match = PCall(string.match, line:lower(), searchTerm:lower())
		if match then
			return true
		end
		if not match and node.mods[index].list then
			-- Then check modifiers
			for _, mod in ipairs(node.mods[index].list) do
				errMsg, match = PCall(string.match, mod.name:lower(), searchTerm:lower())
				if match then
					return true
				end
			end
		end
	end

	-- Check node type
	local errMsg, match = PCall(string.match, node.type:lower(), searchTerm:lower())
	if match then
		return true
	end
end

function PassiveTreeViewClass:AddNodeName(tooltip, node, build)
	tooltip:AddLine(24, "^7"..node.dn..(launch.devModeAlt and " ["..node.id.."]" or ""))
	if launch.devModeAlt and node.id > 65535 then
		-- Decompose cluster node Id
		local index = band(node.id, 0xF)
		local size = band(b_rshift(node.id, 4), 0x3)
		local large = band(b_rshift(node.id, 6), 0x7)
		local medium = band(b_rshift(node.id, 9), 0x3)
		tooltip:AddLine(16, string.format("^7Cluster node index: %d, size: %d, large index: %d, medium index: %d", index, size, large, medium))
	end
	if node.type == "Socket" and node.nodesInRadius then
		local attribTotals = { }
		for nodeId in pairs(node.nodesInRadius[2]) do
			local specNode = build.spec.nodes[nodeId]
			for _, attrib in ipairs{"Str","Dex","Int"} do
				attribTotals[attrib] = (attribTotals[attrib] or 0) + specNode.finalModList:Sum("BASE", nil, attrib)
			end
		end
		if attribTotals["Str"] >= 40 then
			tooltip:AddLine(16, "^7Can support "..colorCodes.STRENGTH.."Strength ^7threshold jewels")
		end
		if attribTotals["Dex"] >= 40 then
			tooltip:AddLine(16, "^7Can support "..colorCodes.DEXTERITY.."Dexterity ^7threshold jewels")
		end
		if attribTotals["Int"] >= 40 then
			tooltip:AddLine(16, "^7Can support "..colorCodes.INTELLIGENCE.."Intelligence ^7threshold jewels")
		end
	end
end

function PassiveTreeViewClass:AddNodeTooltip(tooltip, node, build)
	-- Special case for sockets
	if node.type == "Socket" and node.alloc then
		local socket, jewel = build.itemsTab:GetSocketAndJewelForNodeID(node.id)
		if jewel then
			build.itemsTab:AddItemTooltip(tooltip, jewel, { nodeId = node.id })
		else
			self:AddNodeName(tooltip, node, build)
		end
		tooltip:AddSeparator(14)
		if socket:IsEnabled() then
			tooltip:AddLine(14, colorCodes.TIP.."Tip: Right click this socket to go to the items page and choose the jewel for this socket.")
		end
		tooltip:AddLine(14, colorCodes.TIP.."Tip: Hold Shift to hide this tooltip.")
		return
	end
	
	-- Node name
	self:AddNodeName(tooltip, node, build)
	if launch.devModeAlt then
		if node.power and node.power.offence then
			-- Power debugging info
			tooltip:AddLine(16, string.format("DPS power: %g   Defence power: %g", node.power.offence, node.power.defence))
		end
	end

	-- Node description
	if node.sd[1] then
		tooltip:AddLine(16, "")
		for i, line in ipairs(node.sd) do
			if node.mods[i].list then
				if launch.devModeAlt then
					-- Modifier debugging info
					local modStr
					for _, mod in pairs(node.mods[i].list) do
						modStr = (modStr and modStr..", " or "^2") .. modLib.formatMod(mod)
					end
					if node.mods[i].extra then
						modStr = (modStr and modStr.."  " or "") .. "^1" .. node.mods[i].extra
					end
					if modStr then
						line = line .. "  " .. modStr
					end
				end
			end
			tooltip:AddLine(16, ((node.mods[i].extra or not node.mods[i].list) and colorCodes.UNSUPPORTED or colorCodes.MAGIC)..line)
		end
	end

	-- Reminder text
	if node.reminderText then
		tooltip:AddSeparator(14)
		for _, line in ipairs(node.reminderText) do
			tooltip:AddLine(14, "^xA0A080"..line)
		end
	end

	-- Mod differences
	if self.showStatDifferences then
		local calcFunc, calcBase = build.calcsTab:GetMiscCalculator(build)
		tooltip:AddSeparator(14)
		local path = (node.alloc and node.depends) or self.tracePath or node.path or { }
		local pathLength = #path
		local pathNodes = { }
		for _, node in pairs(path) do
			pathNodes[node] = true
		end
		local nodeOutput, pathOutput
		if node.alloc then
			-- Calculate the differences caused by deallocating this node and its dependants
			nodeOutput = calcFunc({ removeNodes = { [node] = true } })
			if pathLength > 1 then
				pathOutput = calcFunc({ removeNodes = pathNodes })
			end
		else
			-- Calculated the differences caused by allocating this node and all nodes along the path to it
			nodeOutput = calcFunc({ addNodes = { [node] = true } })
			if pathLength > 1 then
				pathOutput = calcFunc({ addNodes = pathNodes })
			end
		end
		local count = build:AddStatComparesToTooltip(tooltip, calcBase, nodeOutput, node.alloc and "^7Unallocating this node will give you:" or "^7Allocating this node will give you:")
		if pathLength > 1 then
			count = count + build:AddStatComparesToTooltip(tooltip, calcBase, pathOutput, node.alloc and "^7Unallocating this node and all nodes depending on it will give you:" or "^7Allocating this node and all nodes leading to it will give you:", pathLength)
		end
		if count == 0 then
			tooltip:AddLine(14, string.format("^7No changes from %s this node%s.", node.alloc and "unallocating" or "allocating", pathLength > 1 and " or the nodes leading to it" or ""))
		end
		tooltip:AddLine(14, colorCodes.TIP.."Tip: Press Ctrl+D to disable the display of stat differences.")
	else
		tooltip:AddSeparator(14)
		tooltip:AddLine(14, colorCodes.TIP.."Tip: Press Ctrl+D to enable the display of stat differences.")
	end

	-- Pathing distance
	tooltip:AddSeparator(14)
	if node.path and #node.path > 0 then
		if self.traceMode and isValueInArray(self.tracePath, node) then
			tooltip:AddLine(14, "^7"..#self.tracePath .. " nodes in trace path")
		else
			tooltip:AddLine(14, "^7"..#node.path .. " points to node")
			if #node.path > 1 then
				-- Handy hint!
				tooltip:AddLine(14, colorCodes.TIP)
				tooltip:AddLine(14, "Tip: To reach this node by a different path, hold Shift, then trace the path and click this node")
			end
		end
	end
	if node.type == "Socket" then
		tooltip:AddLine(14, colorCodes.TIP.."Tip: Hold Shift to hide this tooltip.")
	end
	if node.depends and #node.depends > 1 then
		tooltip:AddSeparator(14)
		tooltip:AddLine(14, "^7"..#node.depends .. " points gained from unallocating these nodes")
	end
end
