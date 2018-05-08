--
-- export The Pantheon data
--
local function kv2str(key, value)
	return '[' .. key .. '] = ' .. value
end
local function zip(a, b)
	local zipped = { }
	for i, _ in pairs(a) do
		table.insert(zipped, { a[i], b[i] })
	end
	return zipped
end
local function tuple2kv(a)
	local kv = { }
	for _, pair in pairs(a) do
		kv[pair[1]] = pair[2]
	end
	return kv
end

loadStatFile("stat_descriptions.txt")

local out = io.open("../Data/3_0/Pantheons.lua", "w")
out:write('-- This file is automatically generated, do not edit!\n')
out:write('-- The Pantheon data (c) Grinding Gear Games\n\n')
out:write('return {\n')

for i = 0, PantheonPanelLayout.maxRow do
	local p = PantheonPanelLayout[i]
	if not p.IsEnabled then
		out:write('\t["', p.Name, '"] = {\n')
		out:write('\t\tisMajorGod = ', tostring(p.IsMajorGod), ',\n')
		out:write('\t\tsouls = {\n')
		local gods = {
			{ name = p.GodName1, statKeys = p.Effect1_StatsKeys, values = p.Effect1_Values },
			{ name = p.GodName2, statKeys = p.Effect2_StatsKeys, values = p.Effect2_Values },
			{ name = p.GodName3, statKeys = p.Effect3_StatsKeys, values = p.Effect3_Values },
			{ name = p.GodName4, statKeys = p.Effect4_StatsKeys, values = p.Effect4_Values },
		}
		for i, god in pairs(gods) do
			if next(god.statKeys) then
				out:write('\t\t\t['..i..'] = { ')
				out:write('name = "', god.name, '",\n')
				out:write('\t\t\t\tmods = {\n')
				for j, souls in pairs(zip(god.statKeys, god.values)) do
					local key = souls[1]
					local value = souls[2]
					local stats = { }
					stats[Stats[key].Id] = { min = value, max = value }
					out:write('\t\t\t\t\t['..j..'] = { line = "', table.concat(describeStats(stats), ' '), '", ')
					out:write('statOrderKey = ', key, ', ')
					out:write('statOrder = { ', key, ' }, ')
					out:write('statId = "'..Stats[key].Id..'", ')
					out:write('value = { ', value, ' }, ')
					out:write('},\n')
				end
				out:write('\t\t\t\t},\n')
				out:write('\t\t\t},\n')
			end
		end
		out:write('\t\t},\n')
		out:write('\t},\n')
	end
end

out:write('}')
out:close()

print("Pantheon data exported.")