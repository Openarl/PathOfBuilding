-- Path of Building
--
-- Module: Calcs
-- Performs all the offense and defense calculations.
-- Here be dragons!
-- This file is 3400 lines long, over half of which is in one function...
--

local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_abs = math.abs
local m_ceil = math.ceil
local m_floor = math.floor
local m_min = math.min
local m_max = math.max
local s_format = string.format
local band = bit.band
local bor = bit.bor
local bnot = bit.bnot

-- List of all damage types, ordered according to the conversion sequence
local dmgTypeList = {"Physical", "Lightning", "Cold", "Fire", "Chaos"}

local resistTypeList = { "Fire", "Cold", "Lightning", "Chaos" }

local isElemental = { Fire = true, Cold = true, Lightning = true }

-- Calculate and combine INC/MORE modifiers for the given modifier names
local function calcMod(modDB, cfg, ...)
	return (1 + (modDB:Sum("INC", cfg, ...)) / 100) * modDB:Sum("MORE", cfg, ...)
end

-- Calculate value, optionally adding additional base
local function calcVal(modDB, name, cfg, base)
	local baseVal = modDB:Sum("BASE", cfg, name) + (base or 0)
	if baseVal ~= 0 then
		return baseVal * calcMod(modDB, cfg, name)
	else
		return 0
	end
end

-- Calculate hit chance
local function calcHitChance(evasion, accuracy)
	local rawChance = accuracy / (accuracy + (evasion / 4) ^ 0.8) * 100
	return m_max(m_min(m_floor(rawChance + 0.5), 95), 5)	
end

-- Merge gem modifiers with given mod list
local function mergeGemMods(modList, gem)
	modList:AddList(gem.data.baseMods)
	if gem.quality > 0 then
		for i = 1, #gem.data.qualityMods do
			local scaledMod = copyTable(gem.data.qualityMods[i])
			scaledMod.value = m_floor(scaledMod.value * gem.quality)
			modList:AddMod(scaledMod)
		end
	end
	gem.level = m_max(gem.level, 1)
	if not gem.data.levels[gem.level] then
		gem.level = m_min(gem.level, #gem.data.levels)
	end
	local levelData = gem.data.levels[gem.level]
	for col, mod in pairs(gem.data.levelMods) do
		if levelData[col] then
			local newMod = copyTable(mod)
			if type(newMod.value) == "table" then
				newMod.value.value = levelData[col]
			else
				newMod.value = levelData[col]
			end
			modList:AddMod(newMod)
		end
	end
end

-- Check if given support gem can support the given active skill
-- Global function, as GemSelectControl needs to use it too
function gemCanSupport(gem, activeSkill)
	if gem.data.unsupported then
		return false
	end
	for _, skillType in pairs(gem.data.excludeSkillTypes) do
		if activeSkill.skillTypes[skillType] then
			return false
		end
	end
	if not gem.data.requireSkillTypes[1] then
		return true
	end
	for _, skillType in pairs(gem.data.requireSkillTypes) do
		if activeSkill.skillTypes[skillType] then
			return true
		end
	end
	return false
end

-- Check if given gem is of the given type ("all", "strength", "melee", etc)
-- Global function, as ModDBClass and ModListClass need to use it too
function gemIsType(gem, type)
	return type == "all" or (type == "elemental" and (gem.data.fire or gem.data.cold or gem.data.lightning)) or gem.data[type]
end

-- Create an active skill using the given active gem and list of support gems
-- It will determine the base flag set, and check which of the support gems can support this skill
local function createActiveSkill(activeGem, supportList)
	local activeSkill = { }
	activeSkill.activeGem = {
		name = activeGem.name,
		data = activeGem.data,
		level = activeGem.level,
		quality = activeGem.quality,
		fromItem = activeGem.fromItem,
		srcGem = activeGem,
	}
	activeSkill.gemList = { activeSkill.activeGem }

	activeSkill.skillTypes = copyTable(activeGem.data.skillTypes)

	activeSkill.skillData = { }

	-- Initialise skill flag set ('attack', 'projectile', etc)
	local skillFlags = copyTable(activeGem.data.baseFlags)
	activeSkill.skillFlags = skillFlags
	skillFlags.hit = activeSkill.skillTypes[SkillType.Attack] or activeSkill.skillTypes[SkillType.Hit]

	for _, gem in ipairs(supportList) do
		if gemCanSupport(gem, activeSkill) then
			if gem.data.addFlags then
				-- Support gem adds flags to supported skills (eg. Remote Mine adds 'mine')
				for k in pairs(gem.data.addFlags) do
					skillFlags[k] = true
				end
			end
			for _, skillType in pairs(gem.data.addSkillTypes) do
				activeSkill.skillTypes[skillType] = true
			end
		end
	end

	-- Process support gems
	for _, gem in ipairs(supportList) do
		if gemCanSupport(gem, activeSkill) then
			t_insert(activeSkill.gemList, {
				name = gem.name,
				data = gem.data,
				level = gem.level,
				quality = gem.quality,
				fromItem = gem.fromItem,
				srcGem = gem,
			})
			if gem.isSupporting then
				gem.isSupporting[activeGem.name] = true
			end
		end
	end

	return activeSkill
end

local function getWeaponFlags(weaponData, weaponTypes)
	local info = data.weaponTypeInfo[weaponData.type]
	if not info then
		return
	end
	if weaponTypes and not weaponTypes[weaponData.type] and 
		(not weaponData.countsAsAll1H or not (weaponTypes["Claw"] or weaponTypes["Dagger"] or weaponTypes["One Handed Axe"] or weaponTypes["One Handed Mace"] or weaponTypes["One Handed Sword"])) then
		return
	end
	local flags = info.flag
	if weaponData.countsAsAll1H then
		flags = bor(ModFlag.Axe, ModFlag.Claw, ModFlag.Dagger, ModFlag.Mace, ModFlag.Sword)
	end
	if weaponData.type ~= "None" then
		flags = bor(flags, ModFlag.Weapon)
		if info.oneHand then
			flags = bor(flags, ModFlag.Weapon1H)
		else
			flags = bor(flags, ModFlag.Weapon2H)
		end
		if info.melee then
			flags = bor(flags, ModFlag.WeaponMelee)
		else
			flags = bor(flags, ModFlag.WeaponRanged)
		end
	end
	return flags, info
end

-- Build list of modifiers for given active skill
local function buildActiveSkillModList(env, activeSkill)
	local skillTypes = activeSkill.skillTypes
	local skillFlags = activeSkill.skillFlags

	-- Handle multipart skills
	local activeGemParts = activeSkill.activeGem.data.parts
	if activeGemParts then
		if activeSkill == env.mainSkill then
			activeSkill.skillPart = m_min(#activeGemParts, env.skillPart or activeSkill.activeGem.srcGem.skillPart or 1)
		else
			activeSkill.skillPart = m_min(#activeGemParts, activeSkill.activeGem.srcGem.skillPart or 1)
		end
		local part = activeGemParts[activeSkill.skillPart]
		for k, v in pairs(part) do
			if v == true then
				skillFlags[k] = true
			elseif v == false then
				skillFlags[k] = nil
			end
		end
		activeSkill.skillPartName = part.name
		skillFlags.multiPart = #activeGemParts > 1
	end

	if skillTypes[SkillType.Shield] and (not env.itemList["Weapon 2"] or env.itemList["Weapon 2"].type ~= "Shield") then
		-- Skill requires a shield to be equipped
		skillFlags.disable = true
	end

	if skillFlags.attack then
		-- Set weapon flags
		local weaponTypes = activeSkill.activeGem.data.weaponTypes
		local weapon1Flags, weapon1Info = getWeaponFlags(env.weaponData1, weaponTypes)
		if weapon1Flags then
			activeSkill.weapon1Flags = weapon1Flags
			skillFlags.weapon1Attack = true
			if weapon1Info.melee and skillFlags.melee then
				skillFlags.projectile = nil
			elseif not weapon1Info.melee and skillFlags.projectile then
				skillFlags.melee = nil
			end
		elseif skillTypes[SkillType.DualWield] or not skillTypes[SkillType.CanDualWield] or skillTypes[SkillType.MainHandOnly] or skillFlags.forceMainHand then
			-- Skill requires a compatible main hand weapon
			skillFlags.disable = true
		end
		if skillTypes[SkillType.DualWield] or skillTypes[SkillType.CanDualWield] then
			if not skillTypes[SkillType.MainHandOnly] and not skillFlags.forceMainHand then
				local weapon2Flags = getWeaponFlags(env.weaponData2, weaponTypes)
				if weapon2Flags then
					activeSkill.weapon2Flags = weapon2Flags
					skillFlags.weapon2Attack = true
				elseif skillTypes[SkillType.DualWield] or not skillFlags.weapon1Attack then
					-- Skill requires a compatible off hand weapon
					skillFlags.disable = true
				end
			end
		elseif env.weaponData2.type then
			-- Skill cannot be used while dual wielding
			skillFlags.disable = true
		end
		skillFlags.bothWeaponAttack = skillFlags.weapon1Attack and skillFlags.weapon2Attack
	end
	
	-- Build skill mod flag set
	local skillModFlags = 0
	if skillFlags.hit then
		skillModFlags = bor(skillModFlags, ModFlag.Hit)
	end
	if skillFlags.attack then
		skillModFlags = bor(skillModFlags, ModFlag.Attack)
	else
		skillModFlags = bor(skillModFlags, ModFlag.Cast)
		if skillFlags.spell then
			skillModFlags = bor(skillModFlags, ModFlag.Spell)
		end
	end
	if skillFlags.melee then
		skillModFlags = bor(skillModFlags, ModFlag.Melee)
	elseif skillFlags.projectile then
		skillModFlags = bor(skillModFlags, ModFlag.Projectile)
	end
	if skillFlags.area then
		skillModFlags = bor(skillModFlags, ModFlag.Area)
	end

	-- Build skill keyword flag set
	local skillKeywordFlags = 0
	if skillFlags.aura then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Aura)
	end
	if skillFlags.curse then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Curse)
	end
	if skillFlags.warcry then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Warcry)
	end
	if skillFlags.movement then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Movement)
	end
	if skillFlags.vaal then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Vaal)
	end
	if skillFlags.lightning then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Lightning)
	end
	if skillFlags.cold then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Cold)
	end
	if skillFlags.fire then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Fire)
	end
	if skillFlags.chaos then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Chaos)
	end
	if skillFlags.minion then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Minion)
	elseif skillFlags.totem then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Totem)
	elseif skillFlags.trap then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Trap)
	elseif skillFlags.mine then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Mine)
	end

	-- Get skill totem ID for totem skills
	-- This is used to calculate totem life
	if skillFlags.totem then
		activeSkill.skillTotemId = activeSkill.activeGem.data.skillTotemId
		if not activeSkill.skillTotemId then
			if activeSkill.activeGem.data.color == 2 then
				activeSkill.skillTotemId = 2
			elseif activeSkill.activeGem.data.color == 3 then
				activeSkill.skillTotemId = 3
			else
				activeSkill.skillTotemId = 1
			end
		end
	end

	-- Build config structure for modifier searches
	activeSkill.skillCfg = {
		flags = bor(skillModFlags, activeSkill.weapon1Flags or activeSkill.weapon2Flags or 0),
		keywordFlags = skillKeywordFlags,
		skillName = activeSkill.activeGem.name:gsub("^Vaal ",""), -- This allows modifiers that target specific skills to also apply to their Vaal counterpart
		skillGem = activeSkill.activeGem,
		skillPart = activeSkill.skillPart,
		skillTypes = activeSkill.skillTypes,
		skillCond = { },
		skillDist = env.buffMode == "EFFECTIVE" and env.configInput.projectileDistance,
		slotName = activeSkill.slotName,
	}
	if skillFlags.weapon1Attack then
		activeSkill.weapon1Cfg = copyTable(activeSkill.skillCfg, true)
		activeSkill.weapon1Cfg.skillCond = { ["MainHandAttack"] = true }
		activeSkill.weapon1Cfg.flags = bor(skillModFlags, activeSkill.weapon1Flags)
	end
	if skillFlags.weapon2Attack then
		activeSkill.weapon2Cfg = copyTable(activeSkill.skillCfg, true)
		activeSkill.weapon2Cfg.skillCond = { ["OffHandAttack"] = true }
		activeSkill.weapon2Cfg.flags = bor(skillModFlags, activeSkill.weapon2Flags)
	end

	-- Apply gem property modifiers from the item this skill is socketed into
	for _, value in ipairs(env.modDB:Sum("LIST", activeSkill.skillCfg, "GemProperty")) do
		for _, gem in pairs(activeSkill.gemList) do
			if not gem.fromItem and gemIsType(gem, value.keyword) then
				gem[value.key] = (gem[value.key] or 0) + value.value
			end
		end
	end

	-- Initialise skill modifier list
	local skillModList = common.New("ModList")
	activeSkill.skillModList = skillModList

	if skillFlags.disable then
		wipeTable(skillFlags)
		skillFlags.disable = true
		return
	end

	-- Add support gem modifiers to skill mod list
	for _, gem in pairs(activeSkill.gemList) do
		if gem.data.support then
			mergeGemMods(skillModList, gem)
		end
	end

	-- Apply gem/quality modifiers from support gems
	if not activeSkill.activeGem.fromItem then
		for _, value in ipairs(skillModList:Sum("LIST", activeSkill.skillCfg, "GemProperty")) do
			if value.keyword == "active_skill" then
				activeSkill.activeGem[value.key] = activeSkill.activeGem[value.key] + value.value
			end
		end
	end

	-- Add active gem modifiers
	mergeGemMods(skillModList, activeSkill.activeGem)

	-- Add extra modifiers
	for _, value in ipairs(env.modDB:Sum("LIST", activeSkill.skillCfg, "ExtraSkillMod")) do
		skillModList:AddMod(value.mod)
	end

	-- Extract skill data
	for _, value in ipairs(skillModList:Sum("LIST", activeSkill.skillCfg, "Misc")) do
		if value.type == "SkillData" then
			activeSkill.skillData[value.key] = value.value
		end
	end

	-- Separate global effect modifiers (mods that can affect defensive stats or other skills)
	local i = 1
	while skillModList[i] do
		local destList
		for _, tag in ipairs(skillModList[i].tagList) do
			if tag.type == "GlobalEffect" then
				if tag.effectType == "Buff" then
					destList = "buffModList"
				elseif tag.effectType == "Aura" then
					destList = "auraModList"
				elseif tag.effectType == "Debuff" then
					destList = "debuffModList"
				elseif tag.effectType == "Curse" then
					destList = "curseModList"
				end
				break
			end
		end
		if destList then
			if not activeSkill[destList] then
				activeSkill[destList] = { }
			end
			local sig = modLib.formatModParams(skillModList[i])
			for d = 1, #activeSkill[destList] do
				local destMod = activeSkill[destList][d]
				if sig == modLib.formatModParams(destMod) and (destMod.type == "BASE" or destMod.type == "INC") then
					destMod.value = destMod.value + skillModList[i].value
					sig = nil
					break
				end
			end
			if sig then
				t_insert(activeSkill[destList],  skillModList[i])
			end
			t_remove(skillModList, i)
		else
			i = i + 1
		end
	end

	if activeSkill.buffModList or activeSkill.auraModList or activeSkill.debuffModList or activeSkill.curseModList then
		-- Add to auxillary skill list
		t_insert(env.auxSkillList, activeSkill)
	end
end

-- Build list of modifiers from the listed tree nodes
local function buildNodeModList(env, nodeList, finishJewels)
	-- Initialise radius jewels
	for _, rad in pairs(env.radiusJewelList) do
		wipeTable(rad.data)
	end

	-- Add node modifers
	local modList = common.New("ModList")
	for _, node in pairs(nodeList) do
		-- Merge with output list
		if node.type == "keystone" then
			modList:AddMod(node.keystoneMod)
		else
			modList:AddList(node.modList)
		end

		-- Run radius jewels
		for _, rad in pairs(env.radiusJewelList) do
			if rad.nodes[node.id] then
				rad.func(node.modList, modList, rad.data)
			end
		end
	end

	if finishJewels then
		-- Finalise radius jewels
		for _, rad in pairs(env.radiusJewelList) do
			rad.func(nil, modList, rad.data, rad.attributes)
			if env.mode == "MAIN" then
				if not rad.item.jewelRadiusData then
					rad.item.jewelRadiusData = { }
				end
				rad.item.jewelRadiusData[rad.nodeId] = rad.data
			end
		end
	end

	return modList
end

-- Merge an instance of a buff, taking the highest value of each modifier
local function mergeBuff(src, destTable, destKey)
	if not destTable[destKey] then
		destTable[destKey] = { }
	end
	local dest = destTable[destKey]
	for _, mod in ipairs(src) do
		local param = modLib.formatModParams(mod)
		for index, destMod in ipairs(dest) do
			if param == modLib.formatModParams(destMod) then
				if type(destMod.value) == "number" and mod.value > destMod.value then
					dest[index] = mod
				end
				param = nil
				break
			end
		end
		if param then
			t_insert(dest, mod)
		end
	end
end

-- Calculate min/max damage of a hit for the given damage type
local function calcHitDamage(env, source, cfg, breakdown, damageType, ...)
	local modDB = env.modDB

	local damageTypeMin = damageType.."Min"
	local damageTypeMax = damageType.."Max"

	-- Calculate base values
	local damageEffectiveness = source.damageEffectiveness or 1
	local addedMin = modDB:Sum("BASE", cfg, damageTypeMin)
	local addedMax = modDB:Sum("BASE", cfg, damageTypeMax)
	local baseMin = (source[damageTypeMin] or 0) + addedMin * damageEffectiveness
	local baseMax = (source[damageTypeMax] or 0) + addedMax * damageEffectiveness

	if breakdown and not (...) and baseMin ~= 0 and baseMax ~= 0 then
		t_insert(breakdown, "Base damage:")
		local plus = ""
		if (source[damageTypeMin] or 0) ~= 0 or (source[damageTypeMax] or 0) ~= 0 then
			t_insert(breakdown, s_format("%d to %d ^8(base damage from %s)", source[damageTypeMin], source[damageTypeMax], env.mode_skillType == "ATTACK" and "weapon" or "skill"))
			plus = "+ "
		end
		if addedMin ~= 0 or addedMax ~= 0 then
			if damageEffectiveness ~= 1 then
				t_insert(breakdown, s_format("%s(%d to %d) x %.2f ^8(added damage multiplied by damage effectiveness)", plus, addedMin, addedMax, damageEffectiveness))
			else
				t_insert(breakdown, s_format("%s%d to %d ^8(added damage)", plus, addedMin, addedMax))
			end
		end
		t_insert(breakdown, s_format("= %.1f to %.1f", baseMin, baseMax))
	end

	-- Calculate conversions
	local addMin, addMax = 0, 0
	local conversionTable = env.conversionTable
	for _, otherType in ipairs(dmgTypeList) do
		if otherType == damageType then
			-- Damage can only be converted from damage types that preceed this one in the conversion sequence, so stop here
			break
		end
		local convMult = conversionTable[otherType][damageType]
		if convMult > 0 then
			-- Damage is being converted/gained from the other damage type
			local min, max = calcHitDamage(env, source, cfg, breakdown, otherType, damageType, ...)
			addMin = addMin + min * convMult
			addMax = addMax + max * convMult
		end
	end
	if addMin ~= 0 and addMax ~= 0 then
		addMin = round(addMin)
		addMax = round(addMax)
	end

	if baseMin == 0 and baseMax == 0 then
		-- No base damage for this type, don't need to calculate modifiers
		if breakdown and (addMin ~= 0 or addMax ~= 0) then
			t_insert(breakdown.damageComponents, {
				source = damageType,
				convSrc = (addMin ~= 0 or addMax ~= 0) and (addMin .. " to " .. addMax),
				total = addMin .. " to " .. addMax,
				convDst = (...) and s_format("%d%% to %s", conversionTable[damageType][...] * 100, ...),
			})
		end
		return addMin, addMax
	end

	-- Build lists of applicable modifier names
	local addElemental = isElemental[damageType]
	local modNames = { damageType.."Damage", "Damage" }
	for i = 1, select('#', ...) do
		local dstElem = select(i, ...)
		-- Add modifiers for damage types to which this damage is being converted
		addElemental = addElemental or isElemental[dstElem]
		t_insert(modNames, dstElem.."Damage")
	end
	if addElemental then
		-- Damage is elemental or is being converted to elemental damage, add global elemental modifiers
		t_insert(modNames, "ElementalDamage")
	end

	-- Combine modifiers
	local inc = 1 + modDB:Sum("INC", cfg, unpack(modNames)) / 100
	local more = m_floor(modDB:Sum("MORE", cfg, unpack(modNames)) * 100 + 0.50000001) / 100

	if breakdown then
		t_insert(breakdown.damageComponents, {
			source = damageType,
			base = baseMin .. " to " .. baseMax,
			inc = (inc ~= 1 and "x "..inc),
			more = (more ~= 1 and "x "..more),
			convSrc = (addMin ~= 0 or addMax ~= 0) and (addMin .. " to " .. addMax),
			total = (round(baseMin * inc * more) + addMin) .. " to " .. (round(baseMax * inc * more) + addMax),
			convDst = (...) and s_format("%d%% to %s", conversionTable[damageType][...] * 100, ...),
		})
	end

	return (round(baseMin * inc * more) + addMin),
		   (round(baseMax * inc * more) + addMax)
end

--
-- The following functions perform various steps in the calculations process.
-- Depending on what is being done with the output, other code may run inbetween steps, however the steps must always be performed in order:
-- 1. Initialise environment (initEnv)
-- 2. Run calculations (performCalcs)
--
-- Thus a basic calculation pass would look like this:
-- 
-- local env = initEnv(build, mode)
-- performCalcs(env)
--

local tempTable1 = { }
local tempTable2 = { }
local tempTable3 = { }

-- Initialise environment: 
-- 1. Initialises the modifier databases
-- 2. Merges modifiers for all items
-- 3. Builds a list of jewels with radius functions
-- 4. Merges modifiers for all allocated passive nodes
-- 5. Builds a list of active skills and their supports
-- 6. Builds modifier lists for all active skills
local function initEnv(build, mode, override)
	override = override or { }

	local env = { }
	env.build = build
	env.configInput = build.configTab.input
	env.calcsInput = build.calcsTab.input
	env.mode = mode
	env.spec = override.spec or build.spec
	env.classId = env.spec.curClassId

	-- Initialise modifier database with base values
	local modDB = common.New("ModDB")
	env.modDB = modDB
	local classStats = build.tree.characterData[env.classId]
	for _, stat in pairs({"Str","Dex","Int"}) do
		modDB:NewMod(stat, "BASE", classStats["base_"..stat:lower()], "Base")
	end
	modDB.multipliers["Level"] = m_max(1, m_min(100, build.characterLevel))
	modDB:NewMod("Life", "BASE", 12, "Base", { type = "Multiplier", var = "Level", base = 38 })
	modDB:NewMod("Mana", "BASE", 6, "Base", { type = "Multiplier", var = "Level", base = 34 })
	modDB:NewMod("ManaRegen", "BASE", 0.0175, "Base", { type = "PerStat", stat = "Mana", div = 1 })
	modDB:NewMod("Evasion", "BASE", 3, "Base", { type = "Multiplier", var = "Level", base = 53 })
	modDB:NewMod("Accuracy", "BASE", 2, "Base", { type = "Multiplier", var = "Level", base = -2 })
	modDB:NewMod("FireResistMax", "BASE", 75, "Base")
	modDB:NewMod("FireResist", "BASE", -60, "Base")
	modDB:NewMod("ColdResistMax", "BASE", 75, "Base")
	modDB:NewMod("ColdResist", "BASE", -60, "Base")
	modDB:NewMod("LightningResistMax", "BASE", 75, "Base")
	modDB:NewMod("LightningResist", "BASE", -60, "Base")
	modDB:NewMod("ChaosResistMax", "BASE", 75, "Base")
	modDB:NewMod("ChaosResist", "BASE", -60, "Base")
	modDB:NewMod("BlockChanceMax", "BASE", 75, "Base")
	modDB:NewMod("PowerChargesMax", "BASE", 3, "Base")
	modDB:NewMod("CritChance", "INC", 50, "Base", { type = "Multiplier", var = "PowerCharge" })
	modDB:NewMod("FrenzyChargesMax", "BASE", 3, "Base")
	modDB:NewMod("Speed", "INC", 4, "Base", { type = "Multiplier", var = "FrenzyCharge" })
	modDB:NewMod("Damage", "MORE", 4, "Base", { type = "Multiplier", var = "FrenzyCharge" })
	modDB:NewMod("EnduranceChargesMax", "BASE", 3, "Base")
	modDB:NewMod("ElementalResist", "BASE", 4, "Base", { type = "Multiplier", var = "EnduranceCharge" })
	modDB:NewMod("MaxLifeLeechRate", "BASE", 20, "Base")
	modDB:NewMod("MaxManaLeechRate", "BASE", 20, "Base")
	modDB:NewMod("ActiveTrapLimit", "BASE", 3, "Base")
	modDB:NewMod("ActiveMineLimit", "BASE", 5, "Base")
	modDB:NewMod("ActiveTotemLimit", "BASE", 1, "Base")
	modDB:NewMod("EnemyCurseLimit", "BASE", 1, "Base")
	modDB:NewMod("ProjectileCount", "BASE", 1, "Base")
	modDB:NewMod("Speed", "MORE", 10, "Base", ModFlag.Attack, { type = "Condition", var = "DualWielding" })
	modDB:NewMod("PhysicalDamage", "MORE", 20, "Base", ModFlag.Attack, { type = "Condition", var = "DualWielding" })
	modDB:NewMod("BlockChance", "BASE", 15, "Base", { type = "Condition", var = "DualWielding" })
	modDB:NewMod("LifeRegenPercent", "BASE", 4, "Base", { type = "Condition", var = "OnConsecratedGround" })
	modDB:NewMod("Misc", "LIST", { type = "EnemyModifier", mod = modLib.createMod("DamageTaken", "INC", 50, "Shock") }, "Base", { type = "Condition", var = "EnemyShocked" })
	modDB:NewMod("Misc", "LIST", { type = "EnemyModifier", mod = modLib.createMod("HitChance", "MORE", -50, "Blind") }, "Base", { type = "Condition", var = "EnemyBlinded" })
	
	-- Add bandit mods
	if build.banditNormal == "Alira" then
		modDB:NewMod("Mana", "BASE", 60, "Bandit")
	elseif build.banditNormal == "Kraityn" then
		modDB:NewMod("ElementalResist", "BASE", 10, "Bandit")
	elseif build.banditNormal == "Oak" then
		modDB:NewMod("Life", "BASE", 40, "Bandit")
	else
		modDB:NewMod("ExtraPoints", "BASE", 1, "Bandit")
	end
	if build.banditCruel == "Alira" then
		modDB:NewMod("Speed", "INC", 5, "Bandit", ModFlag.Spell)
	elseif build.banditCruel == "Kraityn" then
		modDB:NewMod("Speed", "INC", 8, "Bandit", ModFlag.Attack)
	elseif build.banditCruel == "Oak" then
		modDB:NewMod("PhysicalDamage", "INC", 16, "Bandit")
	else
		modDB:NewMod("ExtraPoints", "BASE", 1, "Bandit")
	end
	if build.banditMerciless == "Alira" then
		modDB:NewMod("PowerChargesMax", "BASE", 1, "Bandit")
	elseif build.banditMerciless == "Kraityn" then
		modDB:NewMod("FrenzyChargesMax", "BASE", 1, "Bandit")
	elseif build.banditMerciless == "Oak" then
		modDB:NewMod("EnduranceChargesMax", "BASE", 1, "Bandit")
	else
		modDB:NewMod("ExtraPoints", "BASE", 1, "Bandit")
	end

	-- Initialise enemy modifier database
	local enemyDB = common.New("ModDB")
	env.enemyDB = enemyDB
	env.enemyLevel = m_max(1, m_min(100, env.configInput.enemyLevel and env.configInput.enemyLevel or m_min(env.build.characterLevel, 84)))
	enemyDB:NewMod("Accuracy", "BASE", data.monsterAccuracyTable[env.enemyLevel], "Base")
	enemyDB:NewMod("Evasion", "BASE", data.monsterEvasionTable[env.enemyLevel], "Base")

	-- Add mods from the config tab
	modDB:AddList(build.configTab.modList)
	enemyDB:AddList(build.configTab.enemyModList)

	-- Build list of passive nodes
	local nodes
	if override.addNodes or override.removeNodes then
		nodes = { }
		if override.addNodes then
			for node in pairs(override.addNodes) do
				nodes[node.id] = node
			end
		end
		for _, node in pairs(env.spec.allocNodes) do
			if not override.removeNodes or not override.removeNodes[node] then
				nodes[node.id] = node
			end
		end
	else
		nodes = env.spec.allocNodes
	end

	-- Build and merge item modifiers, and create list of radius jewels
	env.radiusJewelList = wipeTable(env.radiusJewelList)
	env.itemList = { }
	env.flasks = { }
	env.modDB.conditions["UsingAllCorruptedItems"] = true
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item
		if slotName == override.repSlotName then
			item = override.repItem
		elseif slot.nodeId and override.spec then
			item = build.itemsTab.list[env.spec.jewels[slot.nodeId]]
		else
			item = build.itemsTab.list[slot.selItemId]
		end
		if slot.nodeId then
			-- Slot is a jewel socket, check if socket is allocated
			if not nodes[slot.nodeId] then
				item = nil
			elseif item and item.jewelRadiusIndex then
				-- Jewel has a radius,  add it to the list
				local funcList = item.jewelData.funcList or { function(nodeMods, out, data)
					-- Default function just tallies all stats in radius
					if nodeMods then
						for _, stat in pairs({"Str","Dex","Int"}) do
							data[stat] = (data[stat] or 0) + nodeMods:Sum("BASE", nil, stat)
						end
					end
				end }
				for _, func in ipairs(funcList) do
					local node = build.spec.nodes[slot.nodeId]
					t_insert(env.radiusJewelList, {
						nodes = node.nodesInRadius[item.jewelRadiusIndex],
						func = func,
						item = item,
						nodeId = slot.nodeId,
						attributes = node.attributesInRadius[item.jewelRadiusIndex],
						data = { }
					})
				end
			end
		end
		if item and item.type == "Flask" then
			if slot.active then
				env.flasks[item] = true
			end
			item = nil
		end
		env.itemList[slotName] = item
		if item then
			-- Merge mods for this item
			local srcList = item.modList or item.slotModList[slot.slotNum]
			env.modDB:AddList(srcList)
			if item.type ~= "Jewel" and item.type ~= "Flask" then
				-- Update item counts
				local key
				if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
					key = "UniqueItem"
				elseif item.rarity == "RARE" then
					key = "RareItem"
				elseif item.rarity == "MAGIC" then
					key = "MagicItem"
				else
					key = "NormalItem"
				end
				env.modDB.multipliers[key] = (env.modDB.multipliers[key] or 0) + 1
				if item.corrupted then
					env.modDB.multipliers.CorruptedItem = (env.modDB.multipliers.CorruptedItem or 0) + 1
				else
					env.modDB.conditions["UsingAllCorruptedItems"] = false
				end
			end
		end
	end

	if override.toggleFlask then
		if env.flasks[override.toggleFlask] then
			env.flasks[override.toggleFlask] = nil
		else
			env.flasks[override.toggleFlask] = true
		end
	end
	
	if env.mode == "MAIN" then
		-- Process extra skills granted by items
		local markList = { }
		for _, mod in ipairs(env.modDB.mods["ExtraSkill"] or { }) do
			-- Extract the name of the slot containing the item this skill was granted by
			local slotName
			for _, tag in ipairs(mod.tagList) do
				if tag.type == "SocketedIn" then
					slotName = tag.slotName
					break
				end
			end

			-- Check if a matching group already exists
			local group
			for index, socketGroup in pairs(build.skillsTab.socketGroupList) do
				if socketGroup.source == mod.source and socketGroup.slot == slotName then
					if socketGroup.gemList[1] and socketGroup.gemList[1].nameSpec == mod.value.name then
						group = socketGroup
						markList[socketGroup] = true
						break
					end
				end
			end
			if not group then
				-- Create a new group for this skill
				group = { label = "", enabled = true, gemList = { }, source = mod.source, slot = slotName }
				t_insert(build.skillsTab.socketGroupList, group)
				markList[group] = true
			end

			-- Update the group
			group.sourceItem = build.itemsTab.list[tonumber(mod.source:match("Item:(%d+):"))]
			wipeTable(group.gemList)
			t_insert(group.gemList, {
				nameSpec = mod.value.name,
				level = mod.value.level,
				quality = 0,
				enabled = true,
				fromItem = true,
			})
			if mod.value.noSupports then
				group.noSupports = true
			else
				for _, socketGroup in pairs(build.skillsTab.socketGroupList) do
					-- Look for other groups that are socketed in the item
					if socketGroup.slot == slotName and not socketGroup.source then
						-- Add all support gems to the skill's group
						for _, gem in ipairs(socketGroup.gemList) do
							if gem.data and gem.data.support then
								t_insert(group.gemList, gem)
							end
						end
					end
				end
			end
			build.skillsTab:ProcessSocketGroup(group)
		end
		
		-- Remove any socket groups that no longer have a matching item
		local i = 1
		while build.skillsTab.socketGroupList[i] do
			local socketGroup = build.skillsTab.socketGroupList[i]
			if socketGroup.source and not markList[socketGroup] then
				t_remove(build.skillsTab.socketGroupList, i)
				if build.skillsTab.displayGroup == socketGroup then
					build.skillsTab.displayGroup = nil
				end
			else
				i = i + 1
			end
		end
	end

	-- Get the weapon data tables for the equipped weapons
	env.weaponData1 = env.itemList["Weapon 1"] and env.itemList["Weapon 1"].weaponData and env.itemList["Weapon 1"].weaponData[1] or copyTable(data.unarmedWeaponData[env.classId])
	if env.weaponData1.countsAsDualWielding then
		env.weaponData2 = env.itemList["Weapon 1"].weaponData[2]
	else
		env.weaponData2 = env.itemList["Weapon 2"] and env.itemList["Weapon 2"].weaponData and env.itemList["Weapon 2"].weaponData[2] or { }
	end

	-- Build and merge modifiers for allocated passives
	env.modDB:AddList(buildNodeModList(env, nodes, true))

	-- Determine main skill group
	if env.mode == "CALCS" then
		env.calcsInput.skill_number = m_min(m_max(#build.skillsTab.socketGroupList, 1), env.calcsInput.skill_number or 1)
		env.mainSocketGroup = env.calcsInput.skill_number
		env.skillPart = env.calcsInput.skill_part or 1
		env.buffMode = env.calcsInput.misc_buffMode
	else
		build.mainSocketGroup = m_min(m_max(#build.skillsTab.socketGroupList, 1), build.mainSocketGroup or 1)
		env.mainSocketGroup = build.mainSocketGroup
		env.buffMode = "EFFECTIVE"
	end

	-- Build list of active skills
	env.activeSkillList = { }
	local groupCfg = wipeTable(tempTable1)
	for index, socketGroup in pairs(build.skillsTab.socketGroupList) do
		local socketGroupSkillList = { }
		if socketGroup.enabled or index == env.mainSocketGroup then
			-- Build list of supports for this socket group
			local supportList = wipeTable(tempTable2)
			if not socketGroup.source then
				groupCfg.slotName = socketGroup.slot
				for _, value in ipairs(env.modDB:Sum("LIST", groupCfg, "ExtraSupport")) do
					-- Add extra supports from the item this group is socketed in
					local gemData = data.gems[value.name]
					if gemData then
						t_insert(supportList, { 
							name = value.name,
							data = gemData,
							level = value.level,
							quality = 0, 
							enabled = true, 
							fromItem = true
						})
					end
				end
			end
			for _, gem in ipairs(socketGroup.gemList) do
				if gem.enabled and gem.data and gem.data.support then
					-- Add support gems from this group
					local add = true
					for _, otherGem in pairs(supportList) do
						-- Check if there's another support with the same name already present
						if gem.data == otherGem.data then
							add = false
							if gem.level > otherGem.level then
								otherGem.level = gem.level
								otherGem.quality = gem.quality
							elseif gem.level == otherGem.level then
								otherGem.quality = m_max(gem.quality, otherGem.quality)
							end
							break
						end
					end
					if add then
						gem.isSupporting = { }
						t_insert(supportList, gem)
					end
				end
			end

			-- Create active skills
			for _, gem in ipairs(socketGroup.gemList) do
				if gem.enabled and gem.data and not gem.data.support and not gem.data.unsupported then
					local activeSkill = createActiveSkill(gem, supportList)
					activeSkill.slotName = socketGroup.slot
					t_insert(socketGroupSkillList, activeSkill)
					t_insert(env.activeSkillList, activeSkill)
				end
			end

			if index == env.mainSocketGroup and #socketGroupSkillList > 0 then
				-- Select the main skill from this socket group
				local activeSkillIndex
				if env.mode == "CALCS" then
					env.calcsInput.skill_activeNumber = m_min(#socketGroupSkillList, env.calcsInput.skill_activeNumber or 1)
					activeSkillIndex = env.calcsInput.skill_activeNumber
				else
					socketGroup.mainActiveSkill = m_min(#socketGroupSkillList, socketGroup.mainActiveSkill or 1)
					activeSkillIndex = socketGroup.mainActiveSkill
				end
				env.mainSkill = socketGroupSkillList[activeSkillIndex]
			end
		end

		if env.mode == "MAIN" then
			-- Create display label for the socket group if the user didn't specify one
			if socketGroup.label and socketGroup.label:match("%S") then
				socketGroup.displayLabel = socketGroup.label
			else
				socketGroup.displayLabel = nil
				for _, gem in ipairs(socketGroup.gemList) do
					if gem.enabled and gem.data and not gem.data.support then
						socketGroup.displayLabel = (socketGroup.displayLabel and socketGroup.displayLabel..", " or "") .. gem.name
					end
				end
				socketGroup.displayLabel = socketGroup.displayLabel or "<No active skills>"
			end

			-- Save the active skill list for display in the socket group tooltip
			socketGroup.displaySkillList = socketGroupSkillList
		end
	end

	if not env.mainSkill then
		-- Add a default main skill if none are specified
		local defaultGem = {
			name = "Default Attack",
			level = 1,
			quality = 0,
			enabled = true,
			data = data.gems._default
		}
		env.mainSkill = createActiveSkill(defaultGem, { })
		t_insert(env.activeSkillList, env.mainSkill)
	end

	-- Build skill modifier lists
	env.auxSkillList = { }
	for _, activeSkill in pairs(env.activeSkillList) do
		buildActiveSkillModList(env, activeSkill)
	end

	return env
end

-- Finalise environment and perform the calculations
-- This function is 2100 lines long. Enjoy!
local function performCalcs(env)
	local modDB = env.modDB
	local enemyDB = env.enemyDB

	local output = { }
	env.output = output
	modDB.stats = output
	local breakdown
	if env.mode == "CALCS" then
		breakdown = { }
		env.breakdown = breakdown
	end

	-- Set modes
	if env.buffMode == "EFFECTIVE" then
		env.mode_buffs = true
		env.mode_combat = true
		env.mode_effective = true
	elseif env.buffMode == "COMBAT" then
		env.mode_buffs = true
		env.mode_combat = true
		env.mode_effective = false
	elseif env.buffMode == "BUFFED" then
		env.mode_buffs = true
		env.mode_combat = false
		env.mode_effective = false
	else
		env.mode_buffs = false
		env.mode_combat = false
		env.mode_effective = false
	end
	
	-- Merge keystone modifiers
	do
		local keystoneList = wipeTable(tempTable1)
		for _, name in ipairs(modDB:Sum("LIST", nil, "Keystone")) do
			keystoneList[name] = true
		end
		for name in pairs(keystoneList) do
			modDB:AddList(env.build.tree.keystoneMap[name].modList)
		end
	end

	-- Merge flask modifiers
	if env.mode_combat then
		local effectInc = modDB:Sum("INC", nil, "FlaskEffect")
		local flaskBuffs = { }
		for item in pairs(env.flasks) do
			modDB.conditions["UsingFlask"] = true
			-- Avert thine eyes, lest they be forever scarred
			-- I have no idea how to determine which buff is applied by a given flask, 
			-- so utility flasks are grouped by base, unique flasks are grouped by name, and magic flasks by their modifiers
			local effectMod = 1 + (effectInc + item.flaskData.effectInc) / 100
			if item.buffModList[1] then
				local srcList = common.New("ModList")
				srcList:ScaleAddList(item.buffModList, effectMod)
				mergeBuff(srcList, flaskBuffs, item.baseName)
			end
			if item.modList[1] then
				local srcList = common.New("ModList")
				srcList:ScaleAddList(item.modList, effectMod)
				local key
				if item.rarity == "UNIQUE" then
					key = item.title
				else
					key = ""
					for _, mod in ipairs(item.modList) do
						key = key .. modLib.formatModParams(mod) .. "&"
					end
				end
				mergeBuff(srcList, flaskBuffs, key)
			end
		end
		for _, buffModList in pairs(flaskBuffs) do
			modDB:AddList(buffModList)
		end
	end

	-- Set conditions
	local condList = modDB.conditions
	if env.weaponData1.type == "Staff" then
		condList["UsingStaff"] = true
	end
	if env.weaponData1.type == "Bow" then
		condList["UsingBow"] = true
	end
	if env.itemList["Weapon 2"] and env.itemList["Weapon 2"].type == "Shield" then
		condList["UsingShield"] = true
	end
	if env.weaponData1.type and env.weaponData2.type then
		condList["DualWielding"] = true
		if env.weaponData1.type == "Claw" and env.weaponData2.type == "Claw" then
			condList["DualWieldingClaws"] = true
		end
	end
	if env.weaponData1.type == "None" then
		condList["Unarmed"] = true
	end
	if (modDB.multipliers["NormalItem"] or 0) > 0 then
		condList["UsingNormalItem"] = true
	end
	if (modDB.multipliers["MagicItem"] or 0) > 0 then
		condList["UsingMagicItem"] = true
	end
	if (modDB.multipliers["RareItem"] or 0) > 0 then
		condList["UsingRareItem"] = true
	end
	if (modDB.multipliers["UniqueItem"] or 0) > 0 then
		condList["UsingUniqueItem"] = true
	end
	if (modDB.multipliers["CorruptedItem"] or 0) > 0 then
		condList["UsingCorruptedItem"] = true
	else
		condList["NotUsingCorruptedItem"] = true
	end
	if env.mode_buffs then
		condList["Buffed"] = true
	end
	if env.mode_combat then
		condList["Combat"] = true
		if not modDB:Sum("FLAG", nil, "NeverCrit") then
			condList["CritInPast8Sec"] = true
		end
		if not env.mainSkill.skillData.triggered then 
			if env.mainSkill.skillFlags.attack then
				condList["AttackedRecently"] = true
			elseif env.mainSkill.skillFlags.spell then
				condList["CastSpellRecently"] = true
			end
		end
		if env.mainSkill.skillFlags.hit and not env.mainSkill.skillFlags.trap and not env.mainSkill.skillFlags.mine and not env.mainSkill.skillFlags.totem then
			condList["HitRecently"] = true
		end
		if env.mainSkill.skillFlags.movement then
			condList["UsedMovementSkillRecently"] = true
		end
		if env.mainSkill.skillFlags.totem then
			condList["HaveTotem"] = true
			condList["SummonedTotemRecently"] = true
		end
		if env.mainSkill.skillFlags.mine then
			condList["DetonatedMinesRecently"] = true
		end
	end
	if env.mode_effective then
		condList["Effective"] = true
	end
	
	-- Check for extra modifiers to apply to aura skills
	local extraAuraModList = { }
	for _, value in ipairs(modDB:Sum("LIST", nil, "ExtraAuraEffect")) do
		t_insert(extraAuraModList, value.mod)
	end

	-- Combine buffs/debuffs and calculate skill life and mana reservations
	local buffs = { }
	local debuffs = { }
	local curses = { }
	env.reserved_LifeBase = 0
	env.reserved_LifePercent = 0
	env.reserved_ManaBase = 0
	env.reserved_ManaPercent = 0
	if breakdown then
		breakdown.LifeReserved = { reservations = { } }
		breakdown.ManaReserved = { reservations = { } }
	end
	for _, activeSkill in pairs(env.activeSkillList) do
		local skillModList = activeSkill.skillModList
		local skillCfg = activeSkill.skillCfg

		-- Combine buffs/debuffs
		if env.mode_buffs then
			if activeSkill.buffModList and 
			   not activeSkill.skillFlags.curse and 
			   (not activeSkill.skillFlags.totem or activeSkill.skillData.allowTotemBuff) and 
			   (not activeSkill.skillData.offering or modDB:Sum("FLAG", nil, "OfferingsAffectPlayer")) then
				activeSkill.buffSkill = true
				local srcList = common.New("ModList")
				local inc = modDB:Sum("INC", skillCfg, "BuffEffect")
				local more = modDB:Sum("MORE", skillCfg, "BuffEffect")
				srcList:ScaleAddList(activeSkill.buffModList, (1 + inc / 100) * more)
				mergeBuff(srcList, buffs, activeSkill.activeGem.name)
			end
			if activeSkill.auraModList and not activeSkill.skillData.auraCannotAffectSelf then
				activeSkill.buffSkill = true
				local srcList = common.New("ModList")
				local inc = modDB:Sum("INC", skillCfg, "AuraEffect", "BuffEffect") + skillModList:Sum("INC", skillCfg, "AuraEffect", "BuffEffect")
				local more = modDB:Sum("MORE", skillCfg, "AuraEffect", "BuffEffect") * skillModList:Sum("MORE", skillCfg, "AuraEffect", "BuffEffect")
				srcList:ScaleAddList(activeSkill.auraModList, (1 + inc / 100) * more)
				srcList:ScaleAddList(extraAuraModList, (1 + inc / 100) * more)
				mergeBuff(srcList, buffs, activeSkill.activeGem.name)
				condList["HaveAuraActive"] = true
			end
		end
		if env.mode_effective then
			if activeSkill.debuffModList then
				activeSkill.debuffSkill = true
				local srcList = common.New("ModList")
				srcList:ScaleAddList(activeSkill.debuffModList, activeSkill.skillData.stackCount or 1)
				mergeBuff(srcList, debuffs, activeSkill.activeGem.name)
			end
			if activeSkill.curseModList or (activeSkill.skillFlags.curse and activeSkill.buffModList) then
				local curse = {
					name = activeSkill.activeGem.name,
					priority = activeSkill.skillTypes[SkillType.Aura] and 3 or 1,
				}
				local inc = modDB:Sum("INC", skillCfg, "CurseEffect") + enemyDB:Sum("INC", nil, "CurseEffect") + skillModList:Sum("INC", skillCfg, "CurseEffect")
				local more = modDB:Sum("MORE", skillCfg, "CurseEffect") * enemyDB:Sum("MORE", nil, "CurseEffect") * skillModList:Sum("MORE", skillCfg, "CurseEffect")
				if activeSkill.curseModList then
					curse.modList = common.New("ModList")
					curse.modList:ScaleAddList(activeSkill.curseModList, (1 + inc / 100) * more)
				end
				if activeSkill.buffModList then
					-- Curse applies a buff; scale by curse effect, then buff effect
					local temp = common.New("ModList")
					temp:ScaleAddList(activeSkill.buffModList, (1 + inc / 100) * more)
					curse.buffModList = common.New("ModList")
					local buffInc = modDB:Sum("INC", skillCfg, "BuffEffect")
					local buffMore = modDB:Sum("MORE", skillCfg, "BuffEffect")
					curse.buffModList:ScaleAddList(temp, (1 + buffInc / 100) * buffMore)
				end
				t_insert(curses, curse)
			end
		end

		-- Calculate reservations
		if activeSkill.skillTypes[SkillType.ManaCostReserved] and not activeSkill.skillFlags.totem then
			local baseVal = activeSkill.skillData.manaCostOverride or activeSkill.skillData.manaCost
			local suffix = activeSkill.skillTypes[SkillType.ManaCostPercent] and "Percent" or "Base"
			local mult = skillModList:Sum("MORE", skillCfg, "ManaCost")
			local more = modDB:Sum("MORE", skillCfg, "ManaReserved") * skillModList:Sum("MORE", skillCfg, "ManaReserved")
			local inc = modDB:Sum("INC", skillCfg, "ManaReserved") + skillModList:Sum("INC", skillCfg, "ManaReserved")
			local base = m_floor(baseVal * mult)
			local cost = base - m_floor(base * -m_floor((100 + inc) * more - 100) / 100)
			local pool
			if modDB:Sum("FLAG", skillCfg, "BloodMagic", "SkillBloodMagic") or skillModList:Sum("FLAG", skillCfg, "SkillBloodMagic") then
				pool = "Life"
			else
				pool = "Mana"
			end
			env["reserved_"..pool..suffix] = env["reserved_"..pool..suffix] + cost
			if breakdown then
				t_insert(breakdown[pool.."Reserved"].reservations, {
					skillName = activeSkill.activeGem.name,
					base = baseVal .. (activeSkill.skillTypes[SkillType.ManaCostPercent] and "%" or ""),
					mult = mult ~= 1 and ("x "..mult),
					more = more ~= 1 and ("x "..more),
					inc = inc ~= 0 and ("x "..(1 + inc/100)),
					total = cost .. (activeSkill.skillTypes[SkillType.ManaCostPercent] and "%" or ""),
				})
			end
		end
	end

	-- Check for extra curses
	for _, value in ipairs(modDB:Sum("LIST", nil, "ExtraCurse")) do
		local curse = {
			name = value.name,
			priority = 2,
			modList = common.New("ModList")
		}
		local gemModList = common.New("ModList")
		mergeGemMods(gemModList, {
			level = value.level,
			quality = 0,
			data = data.gems[value.name],
		})
		local curseModList = { }
		for _, mod in ipairs(gemModList) do
			for _, tag in ipairs(mod.tagList) do
				if tag.type == "GlobalEffect" and tag.effectType == "Curse" then
					t_insert(curseModList, mod)
					break
				end
			end
		end
		curse.modList:ScaleAddList(curseModList, (1 + enemyDB:Sum("INC", nil, "CurseEffect") / 100) * enemyDB:Sum("MORE", nil, "CurseEffect"))
		t_insert(curses, curse)
	end

	-- Assign curses to slots
	local curseSlots = { }
	env.curseSlots = curseSlots
	output.EnemyCurseLimit = modDB:Sum("BASE", nil, "EnemyCurseLimit")
	for _, curse in ipairs(curses) do
		local slot
		for i = 1, output.EnemyCurseLimit do
			if not curseSlots[i] then
				slot = i
				break
			elseif curseSlots[i].name == curse.name then
				if curseSlots[i].priority < curse.priority then
					slot = i
				else
					slot = nil
				end
				break
			elseif curseSlots[i].priority < curse.priority then
				slot = i
			end
		end
		if slot then
			curseSlots[slot] = curse
		end
	end

	-- Merge buff/debuff modifiers
	for _, modList in pairs(buffs) do
		modDB:AddList(modList)
	end
	for _, modList in pairs(debuffs) do
		enemyDB:AddList(modList)
	end
	modDB.multipliers["CurseOnEnemy"] = #curseSlots
	for _, slot in ipairs(curseSlots) do
		condList["EnemyCursed"] = true
		if slot.modList then
			enemyDB:AddList(slot.modList)
		end
		if slot.buffModList then
			modDB:AddList(slot.buffModList)
		end
	end

	-- Calculate current and maximum charges
	output.PowerChargesMax = modDB:Sum("BASE", nil, "PowerChargesMax")
	output.FrenzyChargesMax = modDB:Sum("BASE", nil, "FrenzyChargesMax")
	output.EnduranceChargesMax = modDB:Sum("BASE", nil, "EnduranceChargesMax")
	if env.configInput.usePowerCharges and env.mode_combat then
		output.PowerCharges = output.PowerChargesMax
	else
		output.PowerCharges = 0
	end
	if env.configInput.useFrenzyCharges and env.mode_combat then
		output.FrenzyCharges = output.FrenzyChargesMax
	else
		output.FrenzyCharges = 0
	end
	if env.configInput.useEnduranceCharges and env.mode_combat then
		output.EnduranceCharges = output.EnduranceChargesMax
	else
		output.EnduranceCharges = 0
	end
	modDB.multipliers["PowerCharge"] = output.PowerCharges
	modDB.multipliers["FrenzyCharge"] = output.FrenzyCharges
	modDB.multipliers["EnduranceCharge"] = output.EnduranceCharges
	if output.PowerCharges == 0 then
		condList["HaveNoPowerCharges"] = true
	end
	if output.PowerCharges == output.PowerChargesMax then
		condList["AtMaxPowerCharges"] = true
	end
	if output.FrenzyCharges == 0 then
		condList["HaveNoFrenzyCharges"] = true
	end
	if output.FrenzyCharges == output.FrenzyChargesMax then
		condList["AtMaxFrenzyCharges"] = true
	end
	if output.EnduranceCharges == 0 then
		condList["HaveNoEnduranceCharges"] = true
	end
	if output.EnduranceCharges == output.EnduranceChargesMax then
		condList["AtMaxEnduranceCharges"] = true
	end

	-- Process misc modifiers
	for _, value in ipairs(modDB:Sum("LIST", nil, "Misc")) do
		if value.type == "Condition" then
			condList[value.var] = true
		elseif value.type == "EnemyCondition" then
			enemyDB.conditions[value.var] = true
		elseif value.type == "Multiplier" then
			modDB.multipliers[value.var] = (modDB.multipliers[value.var] or 0) + value.value
		end
	end
	-- Process enemy modifiers last in case they depend on conditions that were set by misc modifiers
	for _, value in ipairs(modDB:Sum("LIST", nil, "Misc")) do
		if value.type == "EnemyModifier" then
			enemyDB:AddMod(value.mod)
		end
	end

	-- Process conditions that can depend on other conditions
	if condList["EnemyIgnited"] then
		condList["EnemyBurning"] = true
	end

	-- Add misc buffs
	if env.mode_combat then
		if condList["Onslaught"] then
			local effect = m_floor(20 * (1 + modDB:Sum("INC", nil, "OnslaughtEffect", "BuffEffect") / 100))
			modDB:NewMod("Speed", "INC", effect, "Onslaught")
			modDB:NewMod("MovementSpeed", "INC", effect, "Onslaught")
		end
		if condList["UnholyMight"] then
			local effect = m_floor(30 * (1 + modDB:Sum("INC", nil, "BuffEffect") / 100))
			modDB:NewMod("PhysicalDamageGainAsChaos", "BASE", effect, "Unholy Might")
		end
	end

	-- Helper functions for stat breakdowns
	local simpleBreakdown, modBreakdown, slotBreakdown, effMultBreakdown, dotBreakdown
	if breakdown then
		simpleBreakdown = function(extraBase, cfg, total, ...)
			extraBase = extraBase or 0
			local base = modDB:Sum("BASE", cfg, (...))
			if (base + extraBase) ~= 0 then
				local inc = modDB:Sum("INC", cfg, ...)
				local more = modDB:Sum("MORE", cfg, ...)
				if inc ~= 0 or more ~= 1 or (base ~= 0 and extraBase ~= 0) then
					local out = { }
					if base ~= 0 and extraBase ~= 0 then
						out[1] = s_format("(%g + %g) ^8(base)", extraBase, base)
					else
						out[1] = s_format("%g ^8(base)", base + extraBase)
					end
					if inc ~= 0 then
						t_insert(out, s_format("x %.2f", 1 + inc/100).." ^8(increased/reduced)")
					end
					if more ~= 1 then
						t_insert(out, s_format("x %.2f", more).." ^8(more/less)")
					end
					t_insert(out, s_format("= %g", total))
					return out
				end
			end
		end
		modBreakdown = function(cfg, ...)
			local inc = modDB:Sum("INC", cfg, ...)
			local more = modDB:Sum("MORE", cfg, ...)
			if inc ~= 0 and more ~= 1 then
				return { 
					s_format("%.2f", 1 + inc/100).." ^8(increased/reduced)",
					s_format("x %.2f", more).." ^8(more/less)",
					s_format("= %.2f", (1 + inc/100) * more),
				}
			end
		end
		slotBreakdown = function(source, sourceName, cfg, base, total, ...)
			local inc = modDB:Sum("INC", cfg, ...)
			local more = modDB:Sum("MORE", cfg, ...)
			t_insert(breakdown[...].slots, {
				base = base,
				inc = (inc ~= 0) and s_format(" x %.2f", 1 + inc/100),
				more = (more ~= 1) and s_format(" x %.2f", more),
				total = s_format("%.2f", total or (base * (1 + inc / 100) * more)),
				source = source,
				sourceName = sourceName,
				item = env.itemList[source],
			})
		end
		effMultBreakdown = function(damageType, resist, pen, taken, mult)
			local out = { }
			local resistForm = (damageType == "Physical") and "physical damage reduction" or "resistance"
			if resist ~= 0 then
				t_insert(out, s_format("Enemy %s: %d%%", resistForm, resist))
			end
			if pen ~= 0 then
				t_insert(out, "Effective resistance:")
				t_insert(out, s_format("%d%% ^8(resistance)", resist))
				t_insert(out, s_format("- %d%% ^8(penetration)", pen))
				t_insert(out, s_format("= %d%%", resist - pen))
			end
			if (resist - pen) ~= 0 and taken ~= 0 then
				t_insert(out, "Effective DPS modifier:")
				t_insert(out, s_format("%.2f ^8(%s)", 1 - (resist - pen) / 100, resistForm))
				t_insert(out, s_format("x %.2f ^8(increased/reduced damage taken)", 1 + taken / 100))
				t_insert(out, s_format("= %.3f", mult))
			end
			return out
		end
		dotBreakdown = function(out, baseVal, inc, more, rate, effMult, total)
			t_insert(out, s_format("%.1f ^8(base damage per second)", baseVal))
			if inc ~= 0 then
				t_insert(out, s_format("x %.2f ^8(increased/reduced)", 1 + inc/100))
			end
			if more ~= 1 then
				t_insert(out, s_format("x %.2f ^8(more/less)", more))
			end
			if rate and rate ~= 1 then
				t_insert(out, s_format("x %.2f ^8(rate modifier)", rate))
			end
			if effMult ~= 1 then
				t_insert(out, s_format("x %.3f ^8(effective DPS modifier)", effMult))
			end
			t_insert(out, s_format("= %.1f ^8per second", total))
		end
	end

	-- Calculate attributes
	for _, stat in pairs({"Str","Dex","Int"}) do
		output[stat] = round(calcVal(modDB, stat))
		if breakdown then
			breakdown[stat] = simpleBreakdown(nil, nil, output[stat], stat)
		end
	end

	-- Add attribute bonuses
	modDB:NewMod("Life", "BASE", m_floor(output.Str / 2), "Strength")
	local strDmgBonus = round((output.Str + modDB:Sum("BASE", nil, "DexIntToMeleeBonus")) / 5)
	modDB:NewMod("PhysicalDamage", "INC", strDmgBonus, "Strength", ModFlag.Melee)
	modDB:NewMod("Accuracy", "BASE", output.Dex * 2, "Dexterity")
	if not modDB:Sum("FLAG", nil, "IronReflexes") then
		modDB:NewMod("Evasion", "INC", round(output.Dex / 5), "Dexterity")
	end
	modDB:NewMod("Mana", "BASE", round(output.Int / 2), "Intelligence")
	modDB:NewMod("EnergyShield", "INC", round(output.Int / 5), "Intelligence")

	-- ---------------------- --
	-- Defensive Calculations --
	-- ---------------------- --

	-- Life/mana pools
	if modDB:Sum("FLAG", nil, "ChaosInoculation") then
		output.Life = 1
		condList["FullLife"] = true
	else
		local base = modDB:Sum("BASE", cfg, "Life")
		local inc = modDB:Sum("INC", cfg, "Life")
		local more = modDB:Sum("MORE", cfg, "Life")
		local conv = modDB:Sum("BASE", nil, "LifeConvertToEnergyShield")
		output.Life = round(base * (1 + inc/100) * more * (1 - conv/100))
		if breakdown then
			if inc ~= 0 or more ~= 1 or conv ~= 0 then
				breakdown.Life = { }
				breakdown.Life[1] = s_format("%g ^8(base)", base)
				if inc ~= 0 then
					t_insert(breakdown.Life, s_format("x %.2f ^8(increased/reduced)", 1 + inc/100))
				end
				if more ~= 1 then
					t_insert(breakdown.Life, s_format("x %.2f ^8(more/less)", more))
				end
				if conv ~= 0 then
					t_insert(breakdown.Life, s_format("x %.2f ^8(converted to Energy Shield)", 1 - conv/100))
				end
				t_insert(breakdown.Life, s_format("= %g", output.Life))
			end
		end
	end
	output.Mana = round(calcVal(modDB, "Mana"))
	output.ManaRegen = round((modDB:Sum("BASE", nil, "ManaRegen") + output.Mana * modDB:Sum("BASE", nil, "ManaRegenPercent") / 100) * calcMod(modDB, nil, "ManaRegen", "ManaRecovery"), 1)
	if breakdown then
		breakdown.Mana = simpleBreakdown(nil, nil, output.Mana, "Mana")
		breakdown.ManaRegen = simpleBreakdown(nil, nil, output.ManaRegen, "ManaRegen", "ManaRecovery")
	end

	-- Life/mana reservation
	for _, pool in pairs({"Life", "Mana"}) do
		local max = output[pool]
		local reserved = env["reserved_"..pool.."Base"] + m_ceil(max * env["reserved_"..pool.."Percent"] / 100)
		output[pool.."Reserved"] = reserved
		output[pool.."ReservedPercent"] = reserved / max * 100
		output[pool.."Unreserved"] = max - reserved
		output[pool.."UnreservedPercent"] = (max - reserved) / max * 100
		if (max - reserved) / max <= 0.35 then
			condList["Low"..pool] = true
		end
		if reserved == 0 then
			condList["No"..pool.."Reserved"] = true
		end
	end

	-- Resistances
	for _, elem in ipairs(resistTypeList) do
		local max, total
		if elem == "Chaos" and modDB:Sum("FLAG", nil, "ChaosInoculation") then
			max = 100
			total = 100
		else
			max = modDB:Sum("BASE", nil, elem.."ResistMax")
			total = modDB:Sum("BASE", nil, elem.."Resist", isElemental[elem] and "ElementalResist")
		end
		output[elem.."Resist"] = m_min(total, max)
		output[elem.."ResistTotal"] = total
		output[elem.."ResistOverCap"] = m_max(0, total - max)
		if breakdown then
			breakdown[elem.."Resist"] = {
				"Max: "..max.."%",
				"Total: "..total.."%",
				"In hideout: "..(total + 60).."%",
			}
		end
	end
	condList.UncappedLightningResistIsLowest = (output.LightningResistTotal <= output.ColdResistTotal and output.LightningResistTotal <= output.FireResistTotal)
	condList.UncappedColdResistIsLowest = (output.ColdResistTotal <= output.LightningResistTotal and output.ColdResistTotal <= output.FireResistTotal)
	condList.UncappedFireResistIsLowest = (output.FireResistTotal <= output.LightningResistTotal and output.FireResistTotal <= output.ColdResistTotal)
	condList.UncappedLightningResistIsHighest = (output.LightningResistTotal >= output.ColdResistTotal and output.LightningResistTotal >= output.FireResistTotal)
	condList.UncappedColdResistIsHighest = (output.ColdResistTotal >= output.LightningResistTotal and output.ColdResistTotal >= output.FireResistTotal)
	condList.UncappedFireResistIsHighest = (output.FireResistTotal >= output.LightningResistTotal and output.FireResistTotal >= output.ColdResistTotal)

	-- Primary defences: Energy shield, evasion and armour
	do
		local ironReflexes = modDB:Sum("FLAG", nil, "IronReflexes")
		local energyShield = 0
		local armour = 0
		local evasion = 0
		if breakdown then
			breakdown.EnergyShield = { slots = { } }
			breakdown.Armour = { slots = { } }
			breakdown.Evasion = { slots = { } }
		end
		local energyShieldBase = modDB:Sum("BASE", nil, "EnergyShield")
		if energyShieldBase > 0 then
			energyShield = energyShield + energyShieldBase * calcMod(modDB, nil, "EnergyShield", "Defences")
			if breakdown then
				slotBreakdown("Global", nil, nil, energyShieldBase, nil, "EnergyShield", "Defences")
			end
		end
		local armourBase = modDB:Sum("BASE", nil, "Armour", "ArmourAndEvasion")
		if armourBase > 0 then
			armour = armour + armourBase * calcMod(modDB, nil, "Armour", "ArmourAndEvasion", "Defences")
			if breakdown then
				slotBreakdown("Global", nil, nil, armourBase, nil, "Armour", "ArmourAndEvasion", "Defences")
			end
		end
		local evasionBase = modDB:Sum("BASE", nil, "Evasion", "ArmourAndEvasion")
		if evasionBase > 0 then
			if ironReflexes then
				armour = armour + evasionBase * calcMod(modDB, nil, "Armour", "Evasion", "ArmourAndEvasion", "Defences")
				if breakdown then
					slotBreakdown("Conversion", "Evasion to Armour", nil, evasionBase, nil, "Armour", "Evasion", "ArmourAndEvasion", "Defences")
				end
			else
				evasion = evasion + evasionBase * calcMod(modDB, nil, "Evasion", "ArmourAndEvasion", "Defences")
				if breakdown then
					slotBreakdown("Global", nil, nil, evasionBase, nil, "Evasion", "ArmourAndEvasion", "Defences")
				end
			end
		end
		local gearEnergyShield = 0
		local gearArmour = 0
		local gearEvasion = 0
		local slotCfg = wipeTable(tempTable1)
		for _, slot in pairs({"Helmet","Body Armour","Gloves","Boots","Weapon 2"}) do
			local armourData = env.itemList[slot] and env.itemList[slot].armourData
			if armourData then
				slotCfg.slotName = slot
				energyShieldBase = armourData.EnergyShield or 0
				if energyShieldBase > 0 then
					energyShield = energyShield + energyShieldBase * calcMod(modDB, slotCfg, "EnergyShield", "Defences")
					gearEnergyShield = gearEnergyShield + energyShieldBase
					if breakdown then
						slotBreakdown(slot, nil, slotCfg, energyShieldBase, nil, "EnergyShield", "Defences")
					end
				end
				armourBase = armourData.Armour or 0
				if armourBase > 0 then
					if slot == "Body Armour" and modDB:Sum("FLAG", nil, "Unbreakable") then
						armourBase = armourBase * 2
					end
					armour = armour + armourBase * calcMod(modDB, slotCfg, "Armour", "ArmourAndEvasion", "Defences")
					gearArmour = gearArmour + armourBase
					if breakdown then
						slotBreakdown(slot, nil, slotCfg, armourBase, nil, "Armour", "ArmourAndEvasion", "Defences")
					end
				end
				evasionBase = armourData.Evasion or 0
				if evasionBase > 0 then
					if ironReflexes then
						armour = armour + evasionBase * calcMod(modDB, slotCfg, "Armour", "Evasion", "ArmourAndEvasion", "Defences")
						gearArmour = gearArmour + evasionBase
						if breakdown then
							slotBreakdown(slot, nil, slotCfg, evasionBase, nil, "Armour", "Evasion", "ArmourAndEvasion", "Defences")
						end
					else
						evasion = evasion + evasionBase * calcMod(modDB, slotCfg, "Evasion", "ArmourAndEvasion", "Defences")
						gearEvasion = gearEvasion + evasionBase
						if breakdown then
							slotBreakdown(slot, nil, slotCfg, evasionBase, nil, "Evasion", "ArmourAndEvasion", "Defences")
						end
					end
				end
			end
		end
		local convManaToES = modDB:Sum("BASE", nil, "ManaGainAsEnergyShield")
		if convManaToES > 0 then
			energyShieldBase = modDB:Sum("BASE", nil, "Mana") * convManaToES / 100
			energyShield = energyShield + energyShieldBase * calcMod(modDB, nil, "Mana", "EnergyShield", "Defences") 
			if breakdown then
				slotBreakdown("Conversion", "Mana to Energy Shield", nil, energyShieldBase, nil, "EnergyShield", "Defences", "Mana")
			end
		end
		local convLifeToES = modDB:Sum("BASE", nil, "LifeConvertToEnergyShield", "LifeGainAsEnergyShield")
		if convLifeToES > 0 then
			energyShieldBase = modDB:Sum("BASE", nil, "Life") * convLifeToES / 100
			local total
			if modDB:Sum("FLAG", nil, "ChaosInoculation") then
				total = 1
			else
				total = energyShieldBase * calcMod(modDB, nil, "Life", "EnergyShield", "Defences")
			end
			energyShield = energyShield + total
			if breakdown then
				slotBreakdown("Conversion", "Life to Energy Shield", nil, energyShieldBase, total, "EnergyShield", "Defences", "Life")
			end
		end
		output.EnergyShield = round(energyShield)
		output.Armour = round(armour)
		output.Evasion = round(evasion)
		output.LowestOfArmourAndEvasion = m_min(output.Armour, output.Evasion)
		output["Gear:EnergyShield"] = gearEnergyShield
		output["Gear:Armour"] = gearArmour
		output["Gear:Evasion"] = gearEvasion
		output.EnergyShieldRecharge = round(output.EnergyShield * 0.2 * calcMod(modDB, nil, "EnergyShieldRecharge", "EnergyShieldRecovery"), 1)
		output.EnergyShieldRechargeDelay = 2 / (1 + modDB:Sum("INC", nil, "EnergyShieldRechargeFaster") / 100)
		if breakdown then
			breakdown.EnergyShieldRecharge = simpleBreakdown(output.EnergyShield * 0.2, nil, output.EnergyShieldRecharge, "EnergyShieldRecharge", "EnergyShieldRecovery")
			if output.EnergyShieldRechargeDelay ~= 2 then
				breakdown.EnergyShieldRechargeDelay = {
					"2.00s ^8(base)",
					s_format("/ %.2f ^8(faster start)", 1 + modDB:Sum("INC", nil, "EnergyShieldRechargeFaster") / 100),
					s_format("= %.2fs", output.EnergyShieldRechargeDelay)
				}
			end
		end
		if modDB:Sum("FLAG", nil, "CannotEvade") then
			output.EvadeChance = 0
		else
			local enemyAccuracy = round(calcVal(enemyDB, "Accuracy"))
			output.EvadeChance = 100 - calcHitChance(output.Evasion, enemyAccuracy) * calcMod(enemyDB, nil, "HitChance")
			if breakdown then
				breakdown.EvadeChance = {
					s_format("Enemy level: %d ^8(%s the Configuration tab)", env.enemyLevel, env.configInput.enemyLevel and "overridden from" or "can be overridden in"),
					s_format("Average enemy accuracy: %d", enemyAccuracy),
					s_format("Approximate evade chance: %d%%", output.EvadeChance),
				}
			end
		end
	end

	-- Life and energy shield regen
	do
		if modDB:Sum("FLAG", nil, "NoLifeRegen") then
			output.LifeRegen = 0
		elseif modDB:Sum("FLAG", nil, "ZealotsOath") then
			output.LifeRegen = 0
			local lifeBase = modDB:Sum("BASE", nil, "LifeRegen")
			if lifeBase > 0 then
				modDB:NewMod("EnergyShieldRegen", "BASE", lifeBase, "Zealot's Oath")
			end
			local lifePercent = modDB:Sum("BASE", nil, "LifeRegenPercent")
			if lifePercent > 0 then
				modDB:NewMod("EnergyShieldRegenPercent", "BASE", lifePercent, "Zealot's Oath")
			end
		else
			local lifeBase = modDB:Sum("BASE", nil, "LifeRegen")
			local lifePercent = modDB:Sum("BASE", nil, "LifeRegenPercent")
			if lifePercent > 0 then
				lifeBase = lifeBase + output.Life * lifePercent / 100
			end
			if lifeBase > 0 then
				output.LifeRegen = lifeBase * calcMod(modDB, nil, "LifeRecovery")
				output.LifeRegenPercent = round(output.LifeRegen / output.Life * 100, 1)
			else
				output.LifeRegen = 0
			end
		end
		local esBase = modDB:Sum("BASE", nil, "EnergyShieldRegen")
		local esPercent = modDB:Sum("BASE", nil, "EnergyShieldRegenPercent")
		if esPercent > 0 then
			esBase = esBase + output.EnergyShield * esPercent / 100
		end
		if esBase > 0 then
			output.EnergyShieldRegen = esBase * calcMod(modDB, nil, "EnergyShieldRecovery")
			output.EnergyShieldRegenPercent = round(output.EnergyShieldRegen / output.EnergyShield * 100, 1)
		else
			output.EnergyShieldRegen = 0
		end
	end

	-- Leech caps
	if modDB:Sum("FLAG", nil, "GhostReaver") then
		output.MaxEnergyShieldLeechRate = output.EnergyShield * modDB:Sum("BASE", nil, "MaxLifeLeechRate") / 100
		if breakdown then
			breakdown.MaxEnergyShieldLeechRate = {
				s_format("%d ^8(maximum energy shield)", output.EnergyShield),
				s_format("x %d%% ^8(percenage of life to maximum leech rate)", modDB:Sum("BASE", nil, "MaxLifeLeechRate")),
				s_format("= %.1f", output.MaxEnergyShieldLeechRate)
			}
		end
	else
		output.MaxLifeLeechRate = output.Life * modDB:Sum("BASE", nil, "MaxLifeLeechRate") / 100
		if breakdown then
			breakdown.MaxLifeLeechRate = {
				s_format("%d ^8(maximum life)", output.Life),
				s_format("x %d%% ^8(percenage of life to maximum leech rate)", modDB:Sum("BASE", nil, "MaxLifeLeechRate")),
				s_format("= %.1f", output.MaxLifeLeechRate)
			}
		end
	end
	output.MaxManaLeechRate = output.Mana * modDB:Sum("BASE", nil, "MaxManaLeechRate") / 100
	if breakdown then
		breakdown.MaxManaLeechRate = {
			s_format("%d ^8(maximum mana)", output.Mana),
			s_format("x %d%% ^8(percenage of mana to maximum leech rate)", modDB:Sum("BASE", nil, "MaxManaLeechRate")),
			s_format("= %.1f", output.MaxManaLeechRate)
		}
	end

	-- Other defences: block, dodge, stun recovery/avoidance
	do
		output.MovementSpeedMod = calcMod(modDB, nil, "MovementSpeed")
		if modDB:Sum("FLAG", nil, "MovementSpeedCannotBeBelowBase") then
			output.MovementSpeedMod = m_max(output.MovementSpeedMod, 1)
		end
		output.BlockChanceMax = modDB:Sum("BASE", nil, "BlockChanceMax")
		local shieldData = env.itemList["Weapon 2"] and env.itemList["Weapon 2"].armourData
		output.BlockChance = m_min(((shieldData and shieldData.BlockChance or 0) + modDB:Sum("BASE", nil, "BlockChance")) * calcMod(modDB, nil, "BlockChance"), output.BlockChanceMax) 
		output.SpellBlockChance = m_min(modDB:Sum("BASE", nil, "SpellBlockChance") * calcMod(modDB, nil, "SpellBlockChance") + output.BlockChance * modDB:Sum("BASE", nil, "BlockChanceConv") / 100, output.BlockChanceMax) 
		if breakdown then
			breakdown.BlockChance = simpleBreakdown(shieldData and shieldData.BlockChance, nil, output.BlockChance, "BlockChance")
			breakdown.SpellBlockChance = simpleBreakdown(output.BlockChance * modDB:Sum("BASE", nil, "BlockChanceConv") / 100, nil, output.SpellBlockChance, "SpellBlockChance")
		end
		if modDB:Sum("FLAG", nil, "CannotBlockAttacks") then
			output.BlockChance = 0
		end
		output.AttackDodgeChance = m_min(modDB:Sum("BASE", nil, "AttackDodgeChance"), 75)
		output.SpellDodgeChance = m_min(modDB:Sum("BASE", nil, "SpellDodgeChance"), 75)
		local stunChance = 100 - modDB:Sum("BASE", nil, "AvoidStun")
		if output.EnergyShield > output.Life * 2 then
			stunChance = stunChance * 0.5
		end
		output.StunAvoidChance = 100 - stunChance
		if output.StunAvoidChance >= 100 then
			output.StunDuration = 0
			output.BlockDuration = 0
		else
			output.StunDuration = 0.35 / (1 + modDB:Sum("INC", nil, "StunRecovery") / 100)
			output.BlockDuration = 0.35 / (1 + modDB:Sum("INC", nil, "StunRecovery", "BlockRecovery") / 100)
			if breakdown then
				breakdown.StunDuration = {
					"0.35s ^8(base)",
					s_format("/ %.2f ^8(increased/reduced recovery)", 1 + modDB:Sum("INC", nil, "StunRecovery") / 100),
					s_format("= %.2fs", output.StunDuration)
				}
				breakdown.BlockDuration = {
					"0.35s ^8(base)",
					s_format("/ %.2f ^8(increased/reduced recovery)", 1 + modDB:Sum("INC", nil, "StunRecovery", "BlockRecovery") / 100),
					s_format("= %.2fs", output.BlockDuration)
				}
			end
		end
	end

	-- ---------------------- --
	-- Offensive Calculations --
	-- ---------------------- --

	if env.mainSkill.skillFlags.disable then
		-- Skill is disabled
		output.CombinedDPS = 0
		return
	end

	-- Merge main skill mods
	modDB:AddList(env.mainSkill.skillModList)

	local skillData = env.mainSkill.skillData
	local skillFlags = env.mainSkill.skillFlags
	local skillCfg = env.mainSkill.skillCfg
	if skillFlags.attack then
		env.mode_skillType = "ATTACK"
	else
		env.mode_skillType = "SPELL"
	end
	if skillData.showAverage then
		skillFlags.showAverage = true
	else
		skillFlags.notAverage = true
	end
	if env.mode_buffs then
		skillFlags.buffs = true
	end
	if env.mode_combat then
		skillFlags.combat = true
	end
	if env.mode_effective then
		skillFlags.effective = true
	end

	-- Update skill data
	for _, value in ipairs(modDB:Sum("LIST", skillCfg, "Misc")) do
		if value.type == "SkillData" then
			if value.merge == "MAX" then
				skillData[value.key] = m_max(value.value, skillData[value.key] or 0)
			else
				skillData[value.key] = value.value
			end
		end
	end

	env.modDB.conditions["SkillIsTriggered"] = skillData.triggered

	-- Add addition stat bonuses
	if modDB:Sum("FLAG", nil, "IronGrip") then
		modDB:NewMod("PhysicalDamage", "INC", strDmgBonus, "Strength", bor(ModFlag.Attack, ModFlag.Projectile))
	end
	if modDB:Sum("FLAG", nil, "IronWill") then
		modDB:NewMod("Damage", "INC", strDmgBonus, "Strength", ModFlag.Spell)
	end

	if modDB:Sum("FLAG", nil, "MinionDamageAppliesToPlayer") then
		-- Minion Damage conversion from The Scourge
		for _, mod in ipairs(modDB.mods.Damage or { }) do
			if mod.type == "INC" and mod.keywordFlags == KeywordFlag.Minion then
				modDB:NewMod("Damage", "INC", mod.value, mod.source, 0, 0, unpack(mod.tagList))
			end
		end
	end
	if modDB:Sum("FLAG", nil, "SpellDamageAppliesToAttacks") then
		-- Spell Damage conversion from Crown of Eyes
		for i, mod in ipairs(modDB.mods.Damage or { }) do
			if mod.type == "INC" and band(mod.flags, ModFlag.Spell) ~= 0 then
				modDB:NewMod("Damage", "INC", mod.value, mod.source, bor(band(mod.flags, bnot(ModFlag.Spell)), ModFlag.Attack), mod.keywordFlags, unpack(mod.tagList))
			end
		end
	end
	if modDB:Sum("FLAG", nil, "ClawDamageAppliesToUnarmed") then
		-- Claw Damage conversion from Rigwald's Curse
		for i, mod in ipairs(modDB.mods.PhysicalDamage or { }) do
			if band(mod.flags, ModFlag.Claw) ~= 0 then
				modDB:NewMod("PhysicalDamage", mod.type, mod.value, mod.source, bor(band(mod.flags, bnot(ModFlag.Claw)), ModFlag.Unarmed), mod.keywordFlags, unpack(mod.tagList))
			end
		end
	end
	if modDB:Sum("FLAG", nil, "ClawAttackSpeedAppliesToUnarmed") then
		-- Claw Attack Speed conversion from Rigwald's Curse
		for i, mod in ipairs(modDB.mods.Speed or { }) do
			if band(mod.flags, ModFlag.Claw) ~= 0 and band(mod.flags, ModFlag.Attack) ~= 0 then
				modDB:NewMod("Speed", mod.type, mod.value, mod.source, bor(band(mod.flags, bnot(ModFlag.Claw)), ModFlag.Unarmed), mod.keywordFlags, unpack(mod.tagList))
			end
		end
	end
	if modDB:Sum("FLAG", nil, "ClawCritChanceAppliesToUnarmed") then
		-- Claw Crit Chance conversion from Rigwald's Curse
		for i, mod in ipairs(modDB.mods.CritChance or { }) do
			if band(mod.flags, ModFlag.Claw) ~= 0 then
				modDB:NewMod("CritChance", mod.type, mod.value, mod.source, bor(band(mod.flags, bnot(ModFlag.Claw)), ModFlag.Unarmed), mod.keywordFlags, unpack(mod.tagList))
			end
		end
	end

	local isAttack = (env.mode_skillType == "ATTACK")

	-- Calculate skill type stats
	if skillFlags.projectile then
		if modDB:Sum("FLAG", nil, "PointBlank") then
			modDB:NewMod("Damage", "MORE", 50, "Point Blank", bor(ModFlag.Attack, ModFlag.Projectile), { type = "DistanceRamp", ramp = {{10,1},{35,0},{150,-1}} })
		end
		output.ProjectileCount = modDB:Sum("BASE", skillCfg, "ProjectileCount")
		output.PierceChance = m_min(100, modDB:Sum("BASE", skillCfg, "PierceChance"))
		output.ProjectileSpeedMod = calcMod(modDB, skillCfg, "ProjectileSpeed")
		if breakdown then
			breakdown.ProjectileSpeedMod = modBreakdown(skillCfg, "ProjectileSpeed")
		end
	end
	if skillFlags.area then
		output.AreaOfEffectMod = calcMod(modDB, skillCfg, "AreaOfEffect")
		if breakdown then
			breakdown.AreaOfEffectMod = modBreakdown(skillCfg, "AreaOfEffect")
		end
	end
	if skillFlags.trap then
		output.ActiveTrapLimit = modDB:Sum("BASE", skillCfg, "ActiveTrapLimit")
		output.TrapCooldown = (skillData.trapCooldown or 4) / calcMod(modDB, skillCfg, "CooldownRecovery")
		if breakdown then
			breakdown.TrapCooldown = {
				s_format("%.2fs ^8(base)", skillData.trapCooldown or 4),
				s_format("/ %.2f ^8(increased/reduced cooldown recovery)", 1 + modDB:Sum("INC", skillCfg, "CooldownRecovery") / 100),
				s_format("= %.2fs", output.TrapCooldown)
			}
		end
	end
	if skillFlags.mine then
		output.ActiveMineLimit = modDB:Sum("BASE", skillCfg, "ActiveMineLimit")
	end
	if skillFlags.totem then
		output.ActiveTotemLimit = modDB:Sum("BASE", skillCfg, "ActiveTotemLimit")
		output.TotemLifeMod = calcMod(modDB, skillCfg, "TotemLife")
		output.TotemLife = round(data.monsterLifeTable[skillData.totemLevel] * data.totemLifeMult[env.mainSkill.skillTotemId] * output.TotemLifeMod)
		if breakdown then
			breakdown.TotemLifeMod = modBreakdown(skillCfg, "TotemLife")
			breakdown.TotemLife = {
				"Totem level: "..skillData.totemLevel,
				data.monsterLifeTable[skillData.totemLevel].." ^8(base life for a level "..skillData.totemLevel.." monster)",
				"x "..data.totemLifeMult[env.mainSkill.skillTotemId].." ^8(life multiplier for this totem type)",
				"x "..output.TotemLifeMod.." ^8(totem life modifier)",
				"= "..output.TotemLife,
			}
		end
	end

	-- Skill duration
	local debuffDurationMult
	if env.mode_effective then
		debuffDurationMult = 1 / calcMod(enemyDB, skillCfg, "BuffExpireFaster")
	else
		debuffDurationMult = 1
	end
	do
		output.DurationMod = calcMod(modDB, skillCfg, "Duration")
		if breakdown then
			breakdown.DurationMod = modBreakdown(skillCfg, "Duration")
		end
		local durationBase = skillData.duration or 0
		if durationBase > 0 then
			output.Duration = durationBase * output.DurationMod
			if skillData.debuff then
				output.Duration = output.Duration * debuffDurationMult
			end
			if breakdown and output.Duration ~= durationBase then
				breakdown.Duration = {
					s_format("%.2fs ^8(base)", durationBase),
				}
				if output.DurationMod ~= 1 then
					t_insert(breakdown.Duration, s_format("x %.2f ^8(duration modifier)", output.DurationMod))
				end
				if skillData.debuff and debuffDurationMult ~= 1 then
					t_insert(breakdown.Duration, s_format("/ %.2f ^8(debuff expires slower/faster)", 1 / debuffDurationMult))
				end
				t_insert(breakdown.Duration, s_format("= %.2fs", output.Duration))
			end
		end
	end

	-- Run skill setup function
	do
		local setupFunc = env.mainSkill.activeGem.data.setupFunc
		if setupFunc then
			setupFunc(env, output)
		end
	end

	-- Cache global damage disabling flags
	local canDeal = { }
	for _, damageType in pairs(dmgTypeList) do
		canDeal[damageType] = not modDB:Sum("FLAG", skillCfg, "DealNo"..damageType)
	end

	-- Calculate damage conversion percentages
	env.conversionTable = wipeTable(env.conversionTable)
	for damageTypeIndex = 1, 4 do
		local damageType = dmgTypeList[damageTypeIndex]
		local globalConv = wipeTable(tempTable1)
		local skillConv = wipeTable(tempTable2)
		local add = wipeTable(tempTable3)
		local globalTotal, skillTotal = 0, 0
		for otherTypeIndex = damageTypeIndex + 1, 5 do
			-- For all possible destination types, check for global and skill conversions
			otherType = dmgTypeList[otherTypeIndex]
			globalConv[otherType] = modDB:Sum("BASE", skillCfg, damageType.."DamageConvertTo"..otherType, isElemental[damageType] and "ElementalDamageConvertTo"..otherType or nil)
			globalTotal = globalTotal + globalConv[otherType]
			skillConv[otherType] = modDB:Sum("BASE", skillCfg, "Skill"..damageType.."DamageConvertTo"..otherType)
			skillTotal = skillTotal + skillConv[otherType]
			add[otherType] = modDB:Sum("BASE", skillCfg, damageType.."DamageGainAs"..otherType, isElemental[damageType] and "ElementalDamageGainAs"..otherType or nil)
		end
		if skillTotal > 100 then
			-- Skill conversion exceeds 100%, scale it down and remove non-skill conversions
			local factor = 100 / skillTotal
			for type, val in pairs(skillConv) do
				-- The game currently doesn't scale this down even though it is supposed to
				--skillConv[type] = val * factor
			end
			for type, val in pairs(globalConv) do
				globalConv[type] = 0
			end
		elseif globalTotal + skillTotal > 100 then
			-- Conversion exceeds 100%, scale down non-skill conversions
			local factor = (100 - skillTotal) / globalTotal
			for type, val in pairs(globalConv) do
				globalConv[type] = val * factor
			end
			globalTotal = globalTotal * factor
		end
		local dmgTable = { }
		for type, val in pairs(globalConv) do
			dmgTable[type] = (globalConv[type] + skillConv[type] + add[type]) / 100
		end
		dmgTable.mult = 1 - m_min((globalTotal + skillTotal) / 100, 1)
		env.conversionTable[damageType] = dmgTable
	end
	env.conversionTable["Chaos"] = { mult = 1 }

	-- Calculate mana cost (may be slightly off due to rounding differences)
	do
		local more = m_floor(modDB:Sum("MORE", skillCfg, "ManaCost") * 100 + 0.0001) / 100
		local inc = modDB:Sum("INC", skillCfg, "ManaCost")
		local base = modDB:Sum("BASE", skillCfg, "ManaCost")
		output.ManaCost = m_floor(m_max(0, (skillData.manaCost or 0) * more * (1 + inc / 100) + base))
		if env.mainSkill.skillTypes[SkillType.ManaCostPercent] and skillFlags.totem then
			output.ManaCost = m_floor(output.Mana * output.ManaCost / 100)
		end
		if breakdown and output.ManaCost ~= (skillData.manaCost or 0) then
			breakdown.ManaCost = {
				s_format("%d ^8(base mana cost)", skillData.manaCost or 0)
			}
			if more ~= 1 then
				t_insert(breakdown.ManaCost, s_format("x %.2f ^8(mana cost multiplier)", more))
			end
			if inc ~= 0 then
				t_insert(breakdown.ManaCost, s_format("x %.2f ^8(increased/reduced mana cost)", 1 + inc/100))
			end	
			if base ~= 0 then
				t_insert(breakdown.ManaCost, s_format("- %d ^8(- mana cost)", -base))
			end
			t_insert(breakdown.ManaCost, s_format("= %d", output.ManaCost))
		end
	end

	-- Configure damage passes
	local passList = { }
	if isAttack then
		output.MainHand = { }
		output.OffHand = { }
		if skillFlags.weapon1Attack then
			if breakdown then
				breakdown.MainHand = { }
			end
			env.mainSkill.weapon1Cfg.skillStats = output.MainHand
			t_insert(passList, {
				label = "Main Hand",
				source = env.weaponData1,
				cfg = env.mainSkill.weapon1Cfg,
				output = output.MainHand,
				breakdown = breakdown and breakdown.MainHand,
			})
		end
		if skillFlags.weapon2Attack then
			if breakdown then
				breakdown.OffHand = { }
			end
			env.mainSkill.weapon2Cfg.skillStats = output.OffHand
			t_insert(passList, {
				label = "Off Hand",
				source = env.weaponData2,
				cfg = env.mainSkill.weapon2Cfg,
				output = output.OffHand,
				breakdown = breakdown and breakdown.OffHand,
			})
		end
	else
		t_insert(passList, {
			label = "Skill",
			source = skillData,
			cfg = skillCfg,
			output = output,
			breakdown = breakdown,
		})
	end

	local function combineStat(stat, mode, ...)
		-- Combine stats from Main Hand and Off Hand according to the mode
		if mode == "OR" or not skillFlags.bothWeaponAttack then
			output[stat] = output.MainHand[stat] or output.OffHand[stat]
		elseif mode == "ADD" then
			output[stat] = (output.MainHand[stat] or 0) + (output.OffHand[stat] or 0)
		elseif mode == "AVERAGE" then
			output[stat] = ((output.MainHand[stat] or 0) + (output.OffHand[stat] or 0)) / 2
		elseif mode == "CHANCE" then
			if output.MainHand[stat] and output.OffHand[stat] then
				local mainChance = output.MainHand[...] * output.MainHand.HitChance
				local offChance = output.OffHand[...] * output.OffHand.HitChance
				local mainPortion = mainChance / (mainChance + offChance)
				local offPortion = offChance / (mainChance + offChance)
				output[stat] = output.MainHand[stat] * mainPortion + output.OffHand[stat] * offPortion
				if breakdown then
					if not breakdown[stat] then
						breakdown[stat] = { }
					end
					t_insert(breakdown[stat], "Contribution from Main Hand:")
					t_insert(breakdown[stat], s_format("%.1f", output.MainHand[stat]))
					t_insert(breakdown[stat], s_format("x %.3f ^8(portion of instances created by main hand)", mainPortion))
					t_insert(breakdown[stat], s_format("= %.1f", output.MainHand[stat] * mainPortion))
					t_insert(breakdown[stat], "Contribution from Off Hand:")
					t_insert(breakdown[stat], s_format("%.1f", output.OffHand[stat]))
					t_insert(breakdown[stat], s_format("x %.3f ^8(portion of instances created by off hand)", offPortion))
					t_insert(breakdown[stat], s_format("= %.1f", output.OffHand[stat] * offPortion))
					t_insert(breakdown[stat], "Total:")
					t_insert(breakdown[stat], s_format("%.1f + %.1f", output.MainHand[stat] * mainPortion, output.OffHand[stat] * offPortion))
					t_insert(breakdown[stat], s_format("= %.1f", output[stat]))
				end
			else
				output[stat] = output.MainHand[stat] or output.OffHand[stat]
			end
		elseif mode == "DPS" then
			output[stat] = (output.MainHand[stat] or 0) + (output.OffHand[stat] or 0)
			if not skillData.doubleHitsWhenDualWielding then
				output[stat] = output[stat] / 2
			end
		end
	end

	for _, pass in ipairs(passList) do
		local source, output, cfg, breakdown = pass.source, pass.output, pass.cfg, pass.breakdown
		
		-- Calculate hit chance
		output.Accuracy = calcVal(modDB, "Accuracy", cfg)
		if breakdown then
			breakdown.Accuracy = simpleBreakdown(nil, cfg, output.Accuracy, "Accuracy")
		end
		if not isAttack or modDB:Sum("FLAG", cfg, "CannotBeEvaded") or skillData.cannotBeEvaded then
			output.HitChance = 100
		else
			local enemyEvasion = round(calcVal(enemyDB, "Evasion"))
			output.HitChance = calcHitChance(enemyEvasion, output.Accuracy)
			if breakdown then
				breakdown.HitChance = {
					"Enemy level: "..env.enemyLevel..(env.configInput.enemyLevel and " ^8(overridden from the Configuration tab" or " ^8(can be overridden in the Configuration tab)"),
					"Average enemy evasion: "..enemyEvasion,
					"Approximate hit chance: "..output.HitChance.."%",
				}
			end
		end

		-- Calculate attack/cast speed
		if skillData.timeOverride then
			output.Time = skillData.timeOverride
			output.Speed = 1 / output.Time
		else
			local baseSpeed
			if isAttack then
				if skillData.castTimeOverridesAttackTime then
					-- Skill is overriding weapon attack speed
					baseSpeed = 1 / skillData.castTime * (1 + (source.AttackSpeedInc or 0) / 100)
				else
					baseSpeed = source.attackRate or 1
				end
			else
				baseSpeed = 1 / (skillData.castTime or 1)
			end
			output.Speed = baseSpeed * round(calcMod(modDB, cfg, "Speed"), 2)
			output.Time = 1 / output.Speed
			if breakdown then
				breakdown.Speed = simpleBreakdown(baseSpeed, cfg, output.Speed, "Speed")
			end
		end
		if skillData.hitTimeOverride then
			output.HitTime = skillData.hitTimeOverride
			output.HitSpeed = 1 / output.HitTime
		end
	end

	if isAttack then
		-- Combine hit chance and attack speed
		combineStat("HitChance", "AVERAGE")
		combineStat("Speed", "AVERAGE")
		output.Time = 1 / output.Speed
		if skillFlags.bothWeaponAttack then
			if breakdown then
				breakdown.Speed = {
					"Both weapons:",
					s_format("(%.2f + %.2f) / 2", output.MainHand.Speed, output.OffHand.Speed),
					s_format("= %.2f", output.Speed),
				}
			end
		end
	end

	for _, pass in ipairs(passList) do
		local globalOutput, globalBreakdown = output, breakdown
		local source, output, cfg, breakdown = pass.source, pass.output, pass.cfg, pass.breakdown

		-- Calculate crit chance, crit multiplier, and their combined effect
		if modDB:Sum("FLAG", nil, "NeverCrit") then
			output.PreEffectiveCritChance = 0
			output.CritChance = 0
			output.CritMultiplier = 0
			output.CritEffect = 1
		else
			local baseCrit = source.critChance or 0
			if baseCrit == 100 then
				output.PreEffectiveCritChance = 100
				output.CritChance = 100
			else
				local base = modDB:Sum("BASE", cfg, "CritChance")
				local inc = modDB:Sum("INC", cfg, "CritChance")
				local more = modDB:Sum("MORE", cfg, "CritChance")
				output.CritChance = (baseCrit + base) * (1 + inc / 100) * more
				if env.mode_effective then
					output.CritChance = output.CritChance + enemyDB:Sum("BASE", nil, "SelfExtraCritChance")
				end
				local preCapCritChance = output.CritChance
				output.CritChance = m_min(output.CritChance, 95)
				if (baseCrit + base) > 0 then
					output.CritChance = m_max(output.CritChance, 5)
				end
				output.PreEffectiveCritChance = output.CritChance
				local preLuckyCritChance = output.CritChance
				if env.mode_effective and modDB:Sum("FLAG", cfg, "CritChanceLucky") then
					output.CritChance = (1 - (1 - output.CritChance / 100) ^ 2) * 100
				end
				local preHitCheckCritChance = output.CritChance
				if env.mode_effective then
					output.CritChance = output.CritChance * output.HitChance / 100
				end
				if breakdown and output.CritChance ~= baseCrit then
					local enemyExtra = enemyDB:Sum("BASE", nil, "SelfExtraCritChance")
					breakdown.CritChance = { }
					if base ~= 0 then
						t_insert(breakdown.CritChance, s_format("(%g + %g) ^8(base)", baseCrit, base))
					else
						t_insert(breakdown.CritChance, s_format("%g ^8(base)", baseCrit + base))
					end
					if inc ~= 0 then
						t_insert(breakdown.CritChance, s_format("x %.2f", 1 + inc/100).." ^8(increased/reduced)")
					end
					if more ~= 1 then
						t_insert(breakdown.CritChance, s_format("x %.2f", more).." ^8(more/less)")
					end
					if env.mode_effective and enemyExtra ~= 0 then
						t_insert(breakdown.CritChance, s_format("+ %g ^8(extra chance for enemy to be crit)", enemyExtra))
					end
					t_insert(breakdown.CritChance, s_format("= %g", preLuckyCritChance))
					if preCapCritChance > 95 then
						local overCap = preCapCritChance - 95
						t_insert(breakdown.CritChance, s_format("Crit is overcapped by %.2f%% (%d%% increased Critical Strike Chance)", overCap, overCap / more / (baseCrit + base) * 100))
					end
					if env.mode_effective and modDB:Sum("FLAG", cfg, "CritChanceLucky") then
						t_insert(breakdown.CritChance, "Crit Chance is Lucky:")
						t_insert(breakdown.CritChance, s_format("1 - (1 - %.4f) x (1 - %.4f)", preLuckyCritChance / 100, preLuckyCritChance / 100))
						t_insert(breakdown.CritChance, s_format("= %.2f", preHitCheckCritChance))
					end
					if env.mode_effective and output.HitChance < 100 then
						t_insert(breakdown.CritChance, "Crit confirmation roll:")
						t_insert(breakdown.CritChance, s_format("%.2f", preHitCheckCritChance))
						t_insert(breakdown.CritChance, s_format("x %.2f ^8(chance to hit)", output.HitChance / 100))
						t_insert(breakdown.CritChance, s_format("= %.2f", output.CritChance))
					end
				end
			end
			if modDB:Sum("FLAG", cfg, "NoCritMultiplier") then
				output.CritMultiplier = 1
			else
				local extraDamage = 0.5 + modDB:Sum("BASE", cfg, "CritMultiplier") / 100
				if env.mode_effective then
					extraDamage = round(extraDamage * (1 + enemyDB:Sum("INC", nil, "SelfCritMultiplier") / 100), 2)
				end
				output.CritMultiplier = 1 + m_max(0, extraDamage)
				if breakdown and output.CritMultiplier ~= 1.5 then
					breakdown.CritMultiplier = {
						"50% ^8(base)",
					}
					local base = modDB:Sum("BASE", cfg, "CritMultiplier")
					if base ~= 0 then
						t_insert(breakdown.CritMultiplier, s_format("+ %d%% ^8(additional extra damage)", base))
					end
					local enemyInc = 1 + enemyDB:Sum("INC", nil, "SelfCritMultiplier") / 100
					if env.mode_effective and enemyInc ~= 1 then
						t_insert(breakdown.CritMultiplier, s_format("x %.2f ^8(increased/reduced extra crit damage taken by enemy)", enemyInc))
					end
					t_insert(breakdown.CritMultiplier, s_format("= %d%% ^8(extra crit damage)", extraDamage * 100))
				end
			end
			output.CritEffect = 1 - output.CritChance / 100 + output.CritChance / 100 * output.CritMultiplier
			if breakdown and output.CritEffect ~= 1 then
				breakdown.CritEffect = {
					s_format("(1 - %.4f) ^8(portion of damage from non-crits)", output.CritChance/100),
					s_format("+ (%.4f x %g) ^8(portion of damage from crits)", output.CritChance/100, output.CritMultiplier),
					s_format("= %.3f", output.CritEffect),
				}
			end
		end

		-- Calculate hit damage for each damage type
		local totalHitMin, totalHitMax = 0, 0
		local totalCritMin, totalCritMax = 0, 0
		output.LifeLeech = 0
		output.LifeLeechInstant = 0
		output.ManaLeech = 0
		output.ManaLeechInstant = 0
		for pass = 1, 2 do
			-- Pass 1 is critical strike damage, pass 2 is non-critical strike
			condList["CriticalStrike"] = (pass == 1)
			local lifeLeechTotal = 0
			local manaLeechTotal = 0
			for _, damageType in ipairs(dmgTypeList) do
				local min, max
				if skillFlags.hit and canDeal[damageType] then
					if breakdown then
						breakdown[damageType] = {
							damageComponents = { }
						}
					end
					min, max = calcHitDamage(env, source, cfg, breakdown and breakdown[damageType], damageType)
					local convMult = env.conversionTable[damageType].mult
					if breakdown then
						t_insert(breakdown[damageType], "Hit damage:")
						t_insert(breakdown[damageType], s_format("%d to %d ^8(total damage)", min, max))
						if convMult ~= 1 then
							t_insert(breakdown[damageType], s_format("x %g ^8(%g%% converted to other damage types)", convMult, (1-convMult)*100))
						end
					end
					min = min * convMult
					max = max * convMult
					if pass == 1 then
						-- Apply crit multiplier
						min = min * output.CritMultiplier
						max = max * output.CritMultiplier
					end
					if (min ~= 0 or max ~= 0) and env.mode_effective then
						-- Apply enemy resistances and damage taken modifiers
						local preMult
						local resist = 0
						local pen = 0
						local taken = enemyDB:Sum("INC", nil, "DamageTaken", damageType.."DamageTaken")
						if damageType == "Physical" then
							resist = enemyDB:Sum("INC", nil, "PhysicalDamageReduction")
						else
							resist = enemyDB:Sum("BASE", nil, damageType.."Resist")
							if isElemental[damageType] then
								resist = resist + enemyDB:Sum("BASE", nil, "ElementalResist")
								pen = modDB:Sum("BASE", cfg, damageType.."Penetration", "ElementalPenetration")
								taken = taken + enemyDB:Sum("INC", nil, "ElementalDamageTaken")
							end
							resist = m_min(resist, 75)
						end
						if skillFlags.projectile then
							taken = taken + enemyDB:Sum("INC", nil, "ProjectileDamageTaken")
						end
						local effMult = (1 + taken / 100)
						if not isElemental[damageType] or not modDB:Sum("FLAG", cfg, "IgnoreElementalResistances") then
							effMult = effMult * (1 - (resist - pen) / 100)
						end
						min = min * effMult
						max = max * effMult
						if env.mode == "CALCS" then
							output[damageType.."EffMult"] = effMult
						end
						if breakdown and effMult ~= 1 then
							t_insert(breakdown[damageType], s_format("x %.3f ^8(effective DPS modifier)", effMult))
							breakdown[damageType.."EffMult"] = effMultBreakdown(damageType, resist, pen, taken, effMult)
						end
					end
					if breakdown then
						t_insert(breakdown[damageType], s_format("= %d to %d", min, max))
					end
					if skillFlags.mine or skillFlags.trap or skillFlags.totem then
						if not modDB:Sum("FLAG", cfg, "CannotLeechLife") then
							local lifeLeech = modDB:Sum("BASE", cfg, "DamageLifeLeechToPlayer")
							if lifeLeech > 0 then
								lifeLeechTotal = lifeLeechTotal + (min + max) / 2 * lifeLeech / 100
							end
						end
					else
						if not modDB:Sum("FLAG", cfg, "CannotLeechLife") then				
							local lifeLeech = modDB:Sum("BASE", cfg, "DamageLifeLeech", damageType.."DamageLifeLeech", isElemental[damageType] and "ElementalDamageLifeLeech" or nil) + enemyDB:Sum("BASE", nil, "SelfDamageLifeLeech") / 100
							if lifeLeech > 0 then
								lifeLeechTotal = lifeLeechTotal + (min + max) / 2 * lifeLeech / 100
							end
						end
						if not modDB:Sum("FLAG", cfg, "CannotLeechMana") then
							local manaLeech = modDB:Sum("BASE", cfg, "DamageManaLeech", damageType.."DamageManaLeech", isElemental[damageType] and "ElementalDamageManaLeech" or nil) + enemyDB:Sum("BASE", nil, "SelfDamageManaLeech") / 100
							if manaLeech > 0 then
								manaLeechTotal = manaLeechTotal + (min + max) / 2 * manaLeech / 100
							end
						end
					end
				else
					min, max = 0, 0
					if breakdown then
						breakdown[damageType] = {
							"You can't deal "..damageType.." damage"
						}
					end
				end
				if pass == 1 then
					output[damageType.."CritAverage"] = (min + max) / 2
					totalCritMin = totalCritMin + min
					totalCritMax = totalCritMax + max
				else
					if env.mode == "CALCS" then
						output[damageType.."Min"] = min
						output[damageType.."Max"] = max
					end
					output[damageType.."HitAverage"] = (min + max) / 2
					totalHitMin = totalHitMin + min
					totalHitMax = totalHitMax + max
				end
			end
			local portion = (pass == 1) and (output.CritChance / 100) or (1 - output.CritChance / 100)
			if modDB:Sum("FLAG", cfg, "InstantLifeLeech") then
				output.LifeLeechInstant = output.LifeLeechInstant + lifeLeechTotal * portion
			else
				output.LifeLeech = output.LifeLeech + lifeLeechTotal * portion
			end
			if modDB:Sum("FLAG", cfg, "InstantManaLeech") then
				output.ManaLeechInstant = output.ManaLeechInstant + manaLeechTotal * portion
			else
				output.ManaLeech = output.ManaLeech + manaLeechTotal * portion
			end
		end
		output.TotalMin = totalHitMin
		output.TotalMax = totalHitMax

		if not env.configInput.EEIgnoreHitDamage and (output.FireHitAverage + output.ColdHitAverage + output.LightningHitAverage > 0) then
			-- Update enemy hit-by-damage-type conditions
			enemyDB.conditions.HitByFireDamage = output.FireHitAverage > 0
			enemyDB.conditions.HitByColdDamage = output.ColdHitAverage > 0
			enemyDB.conditions.HitByLightningDamage = output.LightningHitAverage > 0
		end

		local hitRate = output.HitChance / 100 * (globalOutput.HitSpeed or globalOutput.Speed) * (skillData.dpsMultiplier or 1)

		-- Calculate leech
		output.LifeLeechDuration = output.LifeLeech / (modDB:Sum("FLAG", nil, "GhostReaver") and globalOutput.EnergyShield or globalOutput.Life) / 0.02
		output.LifeLeechInstances = output.LifeLeechDuration * hitRate
		output.LifeLeechInstantRate = output.LifeLeechInstant * hitRate
		output.ManaLeechDuration = output.ManaLeech / globalOutput.Mana / 0.02
		output.ManaLeechInstances = output.ManaLeechDuration * hitRate
		output.ManaLeechInstantRate = output.ManaLeechInstant * hitRate

		-- Calculate gain on hit
		if skillFlags.mine or skillFlags.trap or skillFlags.totem then
			output.LifeOnHit = 0
			output.EnergyShieldOnHit = 0
			output.ManaOnHit = 0
		else
			output.LifeOnHit = modDB:Sum("BASE", skillCfg, "LifeOnHit") + enemyDB:Sum("BASE", skillCfg, "SelfLifeOnHit")
			output.EnergyShieldOnHit = modDB:Sum("BASE", skillCfg, "EnergyShieldOnHit") + enemyDB:Sum("BASE", skillCfg, "SelfEnergyShieldOnHit")
			output.ManaOnHit = modDB:Sum("BASE", skillCfg, "ManaOnHit") + enemyDB:Sum("BASE", skillCfg, "SelfManaOnHit")
		end
		output.LifeOnHitRate = output.LifeOnHit * hitRate
		output.EnergyShieldOnHitRate = output.EnergyShieldOnHit * hitRate
		output.ManaOnHitRate = output.ManaOnHit * hitRate

		-- Calculate average damage and final DPS
		output.AverageHit = (totalHitMin + totalHitMax) / 2 * (1 - output.CritChance / 100) + (totalCritMin + totalCritMax) / 2 * output.CritChance / 100
		output.AverageDamage = output.AverageHit * output.HitChance / 100
		output.TotalDPS = output.AverageDamage * (globalOutput.HitSpeed or globalOutput.Speed) * (skillData.dpsMultiplier or 1)
		if breakdown then
			if output.CritEffect ~= 1 then
				breakdown.AverageHit = {
					s_format("%.1f x (1 - %.4f) ^8(damage from non-crits)", (totalHitMin + totalHitMax) / 2, output.CritChance / 100),
					s_format("+ %.1f x %.4f ^8(damage from crits)", (totalCritMin + totalCritMax) / 2, output.CritChance / 100),
					s_format("= %.1f", output.AverageHit),
				}
			end
			if isAttack then
				breakdown.AverageDamage = { }
				t_insert(breakdown.AverageDamage, s_format("%s:", pass.label))
				t_insert(breakdown.AverageDamage, s_format("%.1f ^8(average hit)", output.AverageHit))
				t_insert(breakdown.AverageDamage, s_format("x %.2f ^8(chance to hit)", output.HitChance / 100))
				t_insert(breakdown.AverageDamage, s_format("= %.1f", output.AverageDamage))
			end
		end
	end

	if isAttack then
		-- Combine crit stats, average damage and DPS
		combineStat("PreEffectiveCritChance", "AVERAGE")
		combineStat("CritChance", "AVERAGE")
		combineStat("CritMultiplier", "AVERAGE")
		combineStat("AverageDamage", "DPS")
		combineStat("TotalDPS", "DPS")
		combineStat("LifeLeechDuration", "DPS")
		combineStat("LifeLeechInstances", "DPS")
		combineStat("LifeLeechInstant", "DPS")
		combineStat("LifeLeechInstantRate", "DPS")
		combineStat("ManaLeechDuration", "DPS")
		combineStat("ManaLeechInstances", "DPS")
		combineStat("ManaLeechInstant", "DPS")
		combineStat("ManaLeechInstantRate", "DPS")
		combineStat("LifeOnHit", "DPS")
		combineStat("LifeOnHitRate", "DPS")
		combineStat("EnergyShieldOnHit", "DPS")
		combineStat("EnergyShieldOnHitRate", "DPS")
		combineStat("ManaOnHit", "DPS")
		combineStat("ManaOnHitRate", "DPS")
		if skillFlags.bothWeaponAttack then
			if breakdown then
				breakdown.AverageDamage = { }
				t_insert(breakdown.AverageDamage, "Both weapons:")
				if skillData.doubleHitsWhenDualWielding then
					t_insert(breakdown.AverageDamage, s_format("%.1f + %.1f ^8(skill hits with both weapons at once)", output.MainHand.AverageDamage, output.OffHand.AverageDamage))
				else
					t_insert(breakdown.AverageDamage, s_format("(%.1f + %.1f) / 2 ^8(skill alternates weapons)", output.MainHand.AverageDamage, output.OffHand.AverageDamage))
				end
				t_insert(breakdown.AverageDamage, s_format("= %.1f", output.AverageDamage))
			end
		end
	end
	if env.mode == "CALCS" then
		if skillData.showAverage then
			output.DisplayDamage = s_format("%.1f average damage", output.AverageDamage)
		else
			output.DisplayDamage = s_format("%.1f DPS", output.TotalDPS)
		end
	end
	if breakdown then
		if isAttack then
			breakdown.TotalDPS = {
				s_format("%.1f ^8(average damage)", output.AverageDamage),
				output.HitSpeed and s_format("x %.2f ^8(hit rate)", output.HitSpeed) or s_format("x %.2f ^8(attack rate)", output.Speed),
			}
		else
			breakdown.TotalDPS = {
				s_format("%.1f ^8(average hit)", output.AverageDamage),
				output.HitSpeed and s_format("x %.2f ^8(hit rate)", output.HitSpeed) or s_format("x %.2f ^8(cast rate)", output.Speed),
			}
		end
		if skillData.dpsMultiplier then
			t_insert(breakdown.TotalDPS, s_format("x %g ^8(DPS multiplier for this skill)", skillData.dpsMultiplier))
		end
		t_insert(breakdown.TotalDPS, s_format("= %.1f", output.TotalDPS))
	end

	-- Calculate leech rates
	if modDB:Sum("FLAG", nil, "GhostReaver") then
		output.LifeLeechRate = 0
		output.LifeLeechPerHit = 0
		output.EnergyShieldLeechInstanceRate = output.EnergyShield * 0.02 * calcMod(modDB, skillCfg, "LifeLeechRate")
		output.EnergyShieldLeechRate = output.LifeLeechInstantRate + m_min(output.LifeLeechInstances * output.EnergyShieldLeechInstanceRate, output.MaxEnergyShieldLeechRate)
		output.EnergyShieldLeechPerHit = m_min(output.EnergyShieldLeechInstanceRate,  output.MaxEnergyShieldLeechRate) * output.LifeLeechDuration + output.LifeLeechInstant
	else
		output.LifeLeechInstanceRate = output.Life * 0.02 * calcMod(modDB, skillCfg, "LifeLeechRate")
		output.LifeLeechRate = output.LifeLeechInstantRate + m_min(output.LifeLeechInstances * output.LifeLeechInstanceRate, output.MaxLifeLeechRate)
		output.LifeLeechPerHit = m_min(output.LifeLeechInstanceRate, output.MaxLifeLeechRate) * output.LifeLeechDuration + output.LifeLeechInstant
		output.EnergyShieldLeechRate = 0
		output.EnergyShieldLeechPerHit = 0
	end
	output.ManaLeechInstanceRate = output.Mana * 0.02 * calcMod(modDB, skillCfg, "ManaLeechRate")
	output.ManaLeechRate = output.ManaLeechInstantRate + m_min(output.ManaLeechInstances * output.ManaLeechInstanceRate, output.MaxManaLeechRate)
	output.ManaLeechPerHit = m_min(output.ManaLeechInstanceRate, output.MaxManaLeechRate) * output.ManaLeechDuration + output.ManaLeechInstant
	skillFlags.leechES = output.EnergyShieldLeechRate > 0
	skillFlags.leechLife = output.LifeLeechRate > 0
	skillFlags.leechMana = output.ManaLeechRate > 0
	if skillData.showAverage then
		output.LifeLeechGainPerHit = output.LifeLeechPerHit + output.LifeOnHit
		output.EnergyShieldLeechGainPerHit = output.EnergyShieldLeechPerHit + output.EnergyShieldOnHit
		output.ManaLeechGainPerHit = output.ManaLeechPerHit + output.ManaOnHit
	else
		output.LifeLeechGainRate = output.LifeLeechRate + output.LifeOnHitRate
		output.EnergyShieldLeechGainRate = output.EnergyShieldLeechRate + output.EnergyShieldOnHitRate
		output.ManaLeechGainRate = output.ManaLeechRate + output.ManaOnHitRate
	end
	if breakdown then
		local function leechBreakdown(instant, instantRate, instances, pool, rate, max, dur)
			local out = { }
			if skillData.showAverage then
				if instant > 0 then
					t_insert(out, s_format("Instant Leech: %.1f", instant))
				end
				if instances > 0 then
					t_insert(out, "Total leeched per instance:")
					t_insert(out, s_format("%d ^8(size of leech destination pool)", pool))
					t_insert(out, "x 0.02 ^8(base leech rate is 2% per second)")
					local rateMod = calcMod(modDB, skillCfg, rate)
					if rateMod ~= 1 then
						t_insert(out, s_format("x %.2f ^8(leech rate modifier)", rateMod))
					end
					t_insert(out, s_format("x %.2fs ^8(instance duration)", dur))
					t_insert(out, s_format("= %.1f", pool * 0.02 * rateMod * dur))
				end
			else
				if instantRate > 0 then
					t_insert(out, s_format("Instant Leech per second: %.1f", instantRate))
				end
				if instances > 0 then
					t_insert(out, "Rate per instance:")
					t_insert(out, s_format("%d ^8(size of leech destination pool)", pool))
					t_insert(out, "x 0.02 ^8(base leech rate is 2% per second)")
					local rateMod = calcMod(modDB, skillCfg, rate)
					if rateMod ~= 1 then
						t_insert(out, s_format("x %.2f ^8(leech rate modifier)", rateMod))
					end
					t_insert(out, s_format("= %.1f ^8per second", pool * 0.02 * rateMod))
					t_insert(out, "Maximum leech rate against one target:")
					t_insert(out, s_format("%.1f", pool * 0.02 * rateMod))
					t_insert(out, s_format("x %.1f ^8(average instances)", instances))
					local total = pool * 0.02 * rateMod * instances
					t_insert(out, s_format("= %.1f ^8per second", total))
					if total <= max then
						t_insert(out, s_format("Time to reach max: %.1fs", dur))
					end
					t_insert(out, s_format("Leech rate cap: %.1f", max))
					if total > max then
						t_insert(out, s_format("Time to reach cap: %.1fs", dur / total * max))
					end
				end
			end
			return out
		end
		if skillFlags.leechLife then
			breakdown.LifeLeech = leechBreakdown(output.LifeLeechInstant, output.LifeLeechInstantRate, output.LifeLeechInstances, output.Life, "LifeLeechRate", output.MaxLifeLeechRate, output.LifeLeechDuration)
		end
		if skillFlags.leechES then
			breakdown.EnergyShieldLeech = leechBreakdown(output.LifeLeechInstant, output.LifeLeechInstantRate, output.LifeLeechInstances, output.EnergyShield, "LifeLeechRate", output.MaxEnergyShieldLeechRate, output.LifeLeechDuration)
		end
		if skillFlags.leechMana then
			breakdown.ManaLeech = leechBreakdown(output.ManaLeechInstant, output.ManaLeechInstantRate, output.ManaLeechInstances, output.Mana, "ManaLeechRate", output.MaxManaLeechRate, output.ManaLeechDuration)
		end
	end

	-- Calculate skill DOT components
	local dotCfg = {
		skillName = skillCfg.skillName,
		skillPart = skillCfg.skillPart,
		slotName = skillCfg.slotName,
		flags = bor(band(skillCfg.flags, ModFlag.SourceMask), ModFlag.Dot, skillData.dotIsSpell and ModFlag.Spell or 0, skillData.dotIsArea and ModFlag.Area or 0),
		keywordFlags = skillCfg.keywordFlags
	}
	env.mainSkill.dotCfg = dotCfg
	output.TotalDot = 0
	for _, damageType in ipairs(dmgTypeList) do
		local baseVal 
		if canDeal[damageType] then
			baseVal = skillData[damageType.."Dot"] or 0
		else
			baseVal = 0
		end
		if baseVal > 0 then
			skillFlags.dot = true
			local effMult = 1
			if env.mode_effective then
				local resist = 0
				local taken = enemyDB:Sum("INC", nil, "DamageTaken", damageType.."DamageTaken", "DotTaken")
				if damageType == "Physical" then
					resist = enemyDB:Sum("INC", nil, "PhysicalDamageReduction")
				else
					resist = enemyDB:Sum("BASE", nil, damageType.."Resist")
					if isElemental[damageType] then
						resist = resist + enemyDB:Sum("BASE", nil, "ElementalResist")
						taken = taken + enemyDB:Sum("INC", nil, "ElementalDamageTaken")
					end
					if damageType == "Fire" then
						taken = taken + enemyDB:Sum("INC", nil, "BurningDamageTaken")
					end
					resist = m_min(resist, 75)
				end
				effMult = (1 - resist / 100) * (1 + taken / 100)
				output[damageType.."DotEffMult"] = effMult
				if breakdown and effMult ~= 1 then
					breakdown[damageType.."DotEffMult"] = effMultBreakdown(damageType, resist, 0, taken, effMult)
				end
			end
			local inc = modDB:Sum("INC", dotCfg, "Damage", damageType.."Damage", isElemental[damageType] and "ElementalDamage" or nil)
			local more = round(modDB:Sum("MORE", dotCfg, "Damage", damageType.."Damage", isElemental[damageType] and "ElementalDamage" or nil), 2)
			local total = baseVal * (1 + inc/100) * more * effMult
			output[damageType.."Dot"] = total
			output.TotalDot = output.TotalDot + total
			if breakdown then
				breakdown[damageType.."Dot"] = { }
				dotBreakdown(breakdown[damageType.."Dot"], baseVal, inc, more, nil, effMult, total)
			end
		end
	end

	skillFlags.bleed = false
	skillFlags.poison = false
	skillFlags.ignite = false
	skillFlags.igniteCanStack = modDB:Sum("FLAG", skillCfg, "IgniteCanStack")
	skillFlags.shock = false
	skillFlags.freeze = false
	for _, pass in ipairs(passList) do
		local globalOutput, globalBreakdown = output, breakdown
		local source, output, cfg, breakdown = pass.source, pass.output, pass.cfg, pass.breakdown

		-- Calculate chance to inflict secondary dots/status effects
		condList["CriticalStrike"] = true
		if modDB:Sum("FLAG", cfg, "CannotBleed") then
			output.BleedChanceOnCrit = 0
		else
			output.BleedChanceOnCrit = m_min(100, modDB:Sum("BASE", cfg, "BleedChance"))
		end
		output.PoisonChanceOnCrit = m_min(100, modDB:Sum("BASE", cfg, "PoisonChance"))
		if modDB:Sum("FLAG", cfg, "CannotIgnite") then
			output.IgniteChanceOnCrit = 0
		else
			output.IgniteChanceOnCrit = 100
		end
		if modDB:Sum("FLAG", cfg, "CannotShock") then
			output.ShockChanceOnCrit = 0
		else
			output.ShockChanceOnCrit = 100
		end
		if modDB:Sum("FLAG", cfg, "CannotFreeze") then
			output.FreezeChanceOnCrit = 0
		else
			output.FreezeChanceOnCrit = 100
		end
		condList["CriticalStrike"] = false
		if modDB:Sum("FLAG", cfg, "CannotBleed") then
			output.BleedChanceOnHit = 0
		else
			output.BleedChanceOnHit = m_min(100, modDB:Sum("BASE", cfg, "BleedChance"))
		end
		output.PoisonChanceOnHit = m_min(100, modDB:Sum("BASE", cfg, "PoisonChance"))
		if modDB:Sum("FLAG", cfg, "CannotIgnite") then
			output.IgniteChanceOnHit = 0
		else
			output.IgniteChanceOnHit = m_min(100, modDB:Sum("BASE", cfg, "EnemyIgniteChance") + enemyDB:Sum("BASE", nil, "SelfIgniteChance"))
		end
		if modDB:Sum("FLAG", cfg, "CannotShock") then
			output.ShockChanceOnHit = 0
		else
			output.ShockChanceOnHit = m_min(100, modDB:Sum("BASE", cfg, "EnemyShockChance") + enemyDB:Sum("BASE", nil, "SelfShockChance"))
		end
		if modDB:Sum("FLAG", cfg, "CannotFreeze") then
			output.FreezeChanceOnHit = 0
		else
			output.FreezeChanceOnHit = m_min(100, modDB:Sum("BASE", cfg, "EnemyFreezeChance") + enemyDB:Sum("BASE", nil, "SelfFreezeChance"))
			if modDB:Sum("FLAG", cfg, "CritsDontAlwaysFreeze") then
				output.FreezeChanceOnCrit = output.FreezeChanceOnHit
			end
		end
		if skillFlags.attack and skillFlags.projectile and modDB:Sum("FLAG", cfg, "ArrowsThatPierceCauseBleeding") then
			output.BleedChanceOnHit = 100 - (1 - output.BleedChanceOnHit / 100) * (1 - globalOutput.PierceChance / 100) * 100
			output.BleedChanceOnCrit = 100 - (1 - output.BleedChanceOnCrit / 100) * (1 - globalOutput.PierceChance / 100) * 100
		end

		local function calcSecondaryEffectBase(type, sourceHitDmg, sourceCritDmg)
			-- Calculate the inflict chance and base damage of a secondary effect (bleed/poison/ignite/shock/freeze)
			local chanceOnHit, chanceOnCrit = output[type.."ChanceOnHit"], output[type.."ChanceOnCrit"]
			local chanceFromHit = chanceOnHit * (1 - output.CritChance / 100)
			local chanceFromCrit = chanceOnCrit * output.CritChance / 100
			local chance = chanceFromHit + chanceFromCrit
			output[type.."Chance"] = chance
			local baseFromHit = sourceHitDmg * chanceFromHit / (chanceFromHit + chanceFromCrit)
			local baseFromCrit = sourceCritDmg * chanceFromCrit / (chanceFromHit + chanceFromCrit)
			local baseVal = baseFromHit + baseFromCrit
			if breakdown and chance ~= 0 then
				local breakdownChance = breakdown[type.."Chance"] or { }
				breakdown[type.."Chance"] = breakdownChance
				if breakdownChance[1] then
					t_insert(breakdownChance, "")
				end
				if isAttack then
					t_insert(breakdownChance, pass.label..":")
				end
				t_insert(breakdownChance, s_format("Chance on Non-crit: %d%%", chanceOnHit))
				t_insert(breakdownChance, s_format("Chance on Crit: %d%%", chanceOnCrit))
				if chanceOnHit ~= chanceOnCrit then
					t_insert(breakdownChance, "Combined chance:")
					t_insert(breakdownChance, s_format("%d x (1 - %.4f) ^8(chance from non-crits)", chanceOnHit, output.CritChance/100))
					t_insert(breakdownChance, s_format("+ %d x %.4f ^8(chance from crits)", chanceOnCrit, output.CritChance/100))
					t_insert(breakdownChance, s_format("= %.2f", chance))
				end
			end
			if breakdown and baseVal > 0 then
				local breakdownDPS = breakdown[type.."DPS"] or { }
				breakdown[type.."DPS"] = breakdownDPS
				if breakdownDPS[1] then
					t_insert(breakdownDPS, "")
				end
				if isAttack then
					t_insert(breakdownDPS, pass.label..":")
				end
				if sourceHitDmg == sourceCritDmg then
					t_insert(breakdownDPS, "Base damage:")
					t_insert(breakdownDPS, s_format("%.1f ^8(source damage)",sourceHitDmg))
				else
					if baseFromHit > 0 then
						t_insert(breakdownDPS, "Base from Non-crits:")
						t_insert(breakdownDPS, s_format("%.1f ^8(source damage from non-crits)", sourceHitDmg))
						t_insert(breakdownDPS, s_format("x %.3f ^8(portion of instances created by non-crits)", chanceFromHit / (chanceFromHit + chanceFromCrit)))
						t_insert(breakdownDPS, s_format("= %.1f", baseFromHit))
					end
					if baseFromCrit > 0 then
						t_insert(breakdownDPS, "Base from Crits:")
						t_insert(breakdownDPS, s_format("%.1f ^8(source damage from crits)", sourceCritDmg))
						t_insert(breakdownDPS, s_format("x %.3f ^8(portion of instances created by crits)", chanceFromCrit / (chanceFromHit + chanceFromCrit)))
						t_insert(breakdownDPS, s_format("= %.1f", baseFromCrit))
					end
					if baseFromHit > 0 and baseFromCrit > 0 then
						t_insert(breakdownDPS, "Total base damage:")
						t_insert(breakdownDPS, s_format("%.1f + %.1f", baseFromHit, baseFromCrit))
						t_insert(breakdownDPS, s_format("= %.1f", baseVal))
					end
				end
			end
			return baseVal
		end

		-- Calculate bleeding chance and damage
		if canDeal.Physical and (output.BleedChanceOnHit + output.BleedChanceOnCrit) > 0 then
			local sourceHitDmg = output.PhysicalHitAverage
			local sourceCritDmg = output.PhysicalCritAverage
			local baseVal = calcSecondaryEffectBase("Bleed", sourceHitDmg, sourceCritDmg) * 0.1
			if baseVal > 0 then
				skillFlags.bleed = true
				skillFlags.duration = true
				if not env.mainSkill.bleedCfg then
					env.mainSkill.bleedCfg = {
						skillName = skillCfg.skillName,
						slotName = skillCfg.slotName,
						flags = bor(band(skillCfg.flags, ModFlag.SourceMask), ModFlag.Dot, skillData.dotIsSpell and ModFlag.Spell or 0),
						keywordFlags = bor(skillCfg.keywordFlags, KeywordFlag.Bleed)
					}
				end
				local dotCfg = env.mainSkill.bleedCfg
				local effMult = 1
				if env.mode_effective then
					local resist = enemyDB:Sum("INC", nil, "PhysicalDamageReduction")
					local taken = enemyDB:Sum("INC", dotCfg, "DamageTaken", "PhysicalDamageTaken", "DotTaken")
					effMult = (1 - resist / 100) * (1 + taken / 100)
					globalOutput["BleedEffMult"] = effMult
					if breakdown and effMult ~= 1 then
						globalBreakdown.BleedEffMult = effMultBreakdown("Physical", resist, 0, taken, effMult)
					end
				end
				local inc = modDB:Sum("INC", dotCfg, "Damage", "PhysicalDamage")
				local more = round(modDB:Sum("MORE", dotCfg, "Damage", "PhysicalDamage"), 2)
				output.BleedDPS = baseVal * (1 + inc/100) * more * effMult
				local durationMod = calcMod(modDB, dotCfg, "Duration") * calcMod(enemyDB, nil, "SelfBleedDuration")
				globalOutput.BleedDuration = 5 * durationMod * debuffDurationMult
				if breakdown then
					t_insert(breakdown.BleedDPS, "x 0.1 ^8(bleed deals 10% per second)")
					t_insert(breakdown.BleedDPS, s_format("= %.1f", baseVal))
					t_insert(breakdown.BleedDPS, "Bleed DPS:")
					dotBreakdown(breakdown.BleedDPS, baseVal, inc, more, nil, effMult, output.BleedDPS)
					if globalOutput.BleedDuration ~= 5 then
						globalBreakdown.BleedDuration = {
							"5.00s ^8(base duration)"
						}
						if durationMod ~= 1 then
							t_insert(globalBreakdown.BleedDuration, s_format("x %.2f ^8(duration modifier)", durationMod))
						end
						if debuffDurationMult ~= 1 then
							t_insert(globalBreakdown.BleedDuration, s_format("/ %.2f ^8(debuff expires slower/faster)", 1 / debuffDurationMult))
						end
						t_insert(globalBreakdown.BleedDuration, s_format("= %.2fs", globalOutput.BleedDuration))
					end
				end
			end
		end

		-- Calculate poison chance and damage
		if canDeal.Chaos and (output.PoisonChanceOnHit + output.PoisonChanceOnCrit) > 0 then
			local sourceHitDmg = output.PhysicalHitAverage + output.ChaosHitAverage
			local sourceCritDmg = output.PhysicalCritAverage + output.ChaosCritAverage
			local baseVal = calcSecondaryEffectBase("Poison", sourceHitDmg, sourceCritDmg * modDB:Sum("MORE", cfg, "PoisonDamageOnCrit")) * 0.08
			if baseVal > 0 then
				skillFlags.poison = true
				skillFlags.duration = true
				if not env.mainSkill.poisonCfg then
					env.mainSkill.poisonCfg = {
						skillName = skillCfg.skillName,
						slotName = skillCfg.slotName,
						flags = bor(band(skillCfg.flags, ModFlag.SourceMask), ModFlag.Dot, skillData.dotIsSpell and ModFlag.Spell or 0),
						keywordFlags = bor(skillCfg.keywordFlags, KeywordFlag.Poison)
					}
				end
				local dotCfg = env.mainSkill.poisonCfg
				local effMult = 1
				if env.mode_effective then
					local resist = m_min(enemyDB:Sum("BASE", nil, "ChaosResist"), 75)
					local taken = enemyDB:Sum("INC", nil, "DamageTaken", "ChaosDamageTaken", "DotTaken")
					effMult = (1 - resist / 100) * (1 + taken / 100)
					globalOutput["PoisonEffMult"] = effMult
					if breakdown and effMult ~= 1 then
						globalBreakdown.PoisonEffMult = effMultBreakdown("Chaos", resist, 0, taken, effMult)
					end
				end
				local inc = modDB:Sum("INC", dotCfg, "Damage", "ChaosDamage")
				local more = round(modDB:Sum("MORE", dotCfg, "Damage", "ChaosDamage"), 2)
				output.PoisonDPS = baseVal * (1 + inc/100) * more * effMult
				local durationBase
				if skillData.poisonDurationIsSkillDuration then
					durationBase = skillData.duration
				else
					durationBase = 2
				end
				local durationMod = calcMod(modDB, dotCfg, "Duration") * calcMod(enemyDB, nil, "SelfPoisonDuration")
				globalOutput.PoisonDuration = durationBase * durationMod * debuffDurationMult
				output.PoisonDamage = output.PoisonDPS * globalOutput.PoisonDuration
				if skillData.showAverage then
					output.TotalPoisonAverageDamage = output.HitChance / 100 * output.PoisonChance / 100 * output.PoisonDamage
				else
					output.TotalPoisonDPS = output.HitChance / 100 * output.PoisonChance / 100 * output.PoisonDamage * (globalOutput.HitSpeed or globalOutput.Speed) * (skillData.dpsMultiplier or 1)
				end
				if breakdown then
					t_insert(breakdown.PoisonDPS, "x 0.08 ^8(poison deals 8% per second)")
					t_insert(breakdown.PoisonDPS, s_format("= %.1f", baseVal, 1))
					t_insert(breakdown.PoisonDPS, "Poison DPS:")
					dotBreakdown(breakdown.PoisonDPS, baseVal, inc, more, nil, effMult, output.PoisonDPS)
					if globalOutput.PoisonDuration ~= 2 then
						globalBreakdown.PoisonDuration = {
							s_format("%.2fs ^8(base duration)", durationBase)
						}
						if durationMod ~= 1 then
							t_insert(globalBreakdown.PoisonDuration, s_format("x %.2f ^8(duration modifier)", durationMod))
						end
						if debuffDurationMult ~= 1 then
							t_insert(globalBreakdown.PoisonDuration, s_format("/ %.2f ^8(debuff expires slower/faster)", 1 / debuffDurationMult))
						end
						t_insert(globalBreakdown.PoisonDuration, s_format("= %.2fs", globalOutput.PoisonDuration))
					end
					breakdown.PoisonDamage = { }
					if isAttack then
						t_insert(breakdown.PoisonDamage, pass.label..":")
					end
					t_insert(breakdown.PoisonDamage, s_format("%.1f ^8(damage per second)", output.PoisonDPS))
					t_insert(breakdown.PoisonDamage, s_format("x %.2fs ^8(poison duration)", globalOutput.PoisonDuration))
					t_insert(breakdown.PoisonDamage, s_format("= %.1f ^8damage per poison stack", output.PoisonDamage))
				end
			end
		end	

		-- Calculate ignite chance and damage
		if canDeal.Fire and (output.IgniteChanceOnHit + output.IgniteChanceOnCrit) > 0 then
			local sourceHitDmg = 0
			local sourceCritDmg = 0
			if canDeal.Fire and not modDB:Sum("FLAG", cfg, "FireCannotIgnite") then
				sourceHitDmg = sourceHitDmg + output.FireHitAverage
				sourceCritDmg = sourceCritDmg + output.FireCritAverage
			end
			if canDeal.Cold and modDB:Sum("FLAG", cfg, "ColdCanIgnite") then
				sourceHitDmg = sourceHitDmg + output.ColdHitAverage
				sourceCritDmg = sourceCritDmg + output.ColdCritAverage
			end
			local igniteMode = env.configInput.igniteMode or "AVERAGE"
			if igniteMode == "CRIT" then
				output.IgniteChanceOnHit = 0
			end
			if globalBreakdown then
				globalBreakdown.IgniteDPS = {
					s_format("Ignite mode: %s ^8(can be changed in the Configuration tab)", igniteMode == "CRIT" and "Crit Damage" or "Average Damage")
				}
			end
			local baseVal = calcSecondaryEffectBase("Ignite", sourceHitDmg, sourceCritDmg) * 0.2
			if baseVal > 0 then
				skillFlags.ignite = true
				if not env.mainSkill.igniteCfg then
					env.mainSkill.igniteCfg = {
						skillName = skillCfg.skillName,
						slotName = skillCfg.slotName,
						flags = bor(band(skillCfg.flags, ModFlag.SourceMask), ModFlag.Dot, skillData.dotIsSpell and ModFlag.Spell or 0),
						keywordFlags = skillCfg.keywordFlags,
					}
				end
				local dotCfg = env.mainSkill.igniteCfg
				local effMult = 1
				if env.mode_effective then
					local resist = m_min(enemyDB:Sum("BASE", nil, "FireResist", "ElementalResist"), 75)
					local taken = enemyDB:Sum("INC", dotCfg, "DamageTaken", "FireDamageTaken", "ElementalDamageTaken", "BurningDamageTaken", "DotTaken")
					effMult = (1 - resist / 100) * (1 + taken / 100)
					globalOutput["IgniteEffMult"] = effMult
					if breakdown and effMult ~= 1 then
						globalBreakdown.IgniteEffMult = effMultBreakdown("Fire", resist, 0, taken, effMult)
					end
				end
				local inc = modDB:Sum("INC", dotCfg, "Damage", "FireDamage", "ElementalDamage")
				local more = round(modDB:Sum("MORE", dotCfg, "Damage", "FireDamage", "ElementalDamage"), 2)
				local burnRateMod = calcMod(modDB, cfg, "IgniteBurnRate")
				output.IgniteDPS = baseVal * (1 + inc/100) * more * burnRateMod * effMult
				local incDur = modDB:Sum("INC", dotCfg, "EnemyIgniteDuration") + enemyDB:Sum("INC", nil, "SelfIgniteDuration")
				local moreDur = enemyDB:Sum("MORE", nil, "SelfIgniteDuration")
				globalOutput.IgniteDuration = 4 * (1 + incDur / 100) * moreDur / burnRateMod * debuffDurationMult
				if skillFlags.igniteCanStack then
					output.IgniteDamage = output.IgniteDPS * globalOutput.IgniteDuration
					if skillData.showAverage then
						output.TotalIgniteAverageDamage = output.HitChance / 100 * output.IgniteChance / 100 * output.IgniteDamage
					else
						output.TotalIgniteDPS = output.HitChance / 100 * output.IgniteChance / 100 * output.IgniteDamage * (globalOutput.HitSpeed or globalOutput.Speed) * (skillData.dpsMultiplier or 1)
					end
				end
				if breakdown then
					t_insert(breakdown.IgniteDPS, "x 0.2 ^8(ignite deals 20% per second)")
					t_insert(breakdown.IgniteDPS, s_format("= %.1f", baseVal, 1))
					t_insert(breakdown.IgniteDPS, "Ignite DPS:")
					dotBreakdown(breakdown.IgniteDPS, baseVal, inc, more, burnRateMod, effMult, output.IgniteDPS)
					if skillFlags.igniteCanStack then
						breakdown.IgniteDamage = { }
						if isAttack then
							t_insert(breakdown.IgniteDamage, pass.label..":")
						end
						t_insert(breakdown.IgniteDamage, s_format("%.1f ^8(damage per second)", output.IgniteDPS))
						t_insert(breakdown.IgniteDamage, s_format("x %.2fs ^8(ignite duration)", globalOutput.IgniteDuration))
						t_insert(breakdown.IgniteDamage, s_format("= %.1f ^8damage per ignite stack", output.IgniteDamage))
					end
					if globalOutput.IgniteDuration ~= 4 then
						globalBreakdown.IgniteDuration = {
							s_format("4.00s ^8(base duration)", durationBase)
						}
						if incDur ~= 0 then
							t_insert(globalBreakdown.IgniteDuration, s_format("x %.2f ^8(increased/reduced duration)", 1 + incDur/100))
						end
						if moreDur ~= 1 then
							t_insert(globalBreakdown.IgniteDuration, s_format("x %.2f ^8(more/less duration)", moreDur))
						end
						if burnRateMod ~= 1 then
							t_insert(globalBreakdown.IgniteDuration, s_format("/ %.2f ^8(rate modifier)", burnRateMod))
						end
						if debuffDurationMult ~= 1 then
							t_insert(globalBreakdown.IgniteDuration, s_format("/ %.2f ^8(debuff expires slower/faster)", 1 / debuffDurationMult))
						end
						t_insert(globalBreakdown.IgniteDuration, s_format("= %.2fs", globalOutput.IgniteDuration))
					end
				end
			end
		end

		-- Calculate shock and freeze chance + duration modifier
		if (output.ShockChanceOnHit + output.ShockChanceOnCrit) > 0 then
			local sourceHitDmg = 0
			local sourceCritDmg = 0
			if canDeal.Lightning and not modDB:Sum("FLAG", cfg, "LightningCannotShock") then
				sourceHitDmg = sourceHitDmg + output.LightningHitAverage
				sourceCritDmg = sourceCritDmg + output.LightningCritAverage
			end
			if canDeal.Physical and modDB:Sum("FLAG", cfg, "PhysicalCanShock") then
				sourceHitDmg = sourceHitDmg + output.PhysicalHitAverage
				sourceCritDmg = sourceCritDmg + output.PhysicalCritAverage
			end
			if canDeal.Fire and modDB:Sum("FLAG", cfg, "FireCanShock") then
				sourceHitDmg = sourceHitDmg + output.FireHitAverage
				sourceCritDmg = sourceCritDmg + output.FireCritAverage
			end
			if canDeal.Chaos and modDB:Sum("FLAG", cfg, "ChaosCanShock") then
				sourceHitDmg = sourceHitDmg + output.ChaosHitAverage
				sourceCritDmg = sourceCritDmg + output.ChaosCritAverage
			end
			local baseVal = calcSecondaryEffectBase("Shock", sourceHitDmg, sourceCritDmg)
			if baseVal > 0 then
				skillFlags.shock = true
				output.ShockDurationMod = 1 + modDB:Sum("INC", cfg, "EnemyShockDuration") / 100 + enemyDB:Sum("INC", nil, "SelfShockDuration") / 100
				if breakdown then
					t_insert(breakdown.ShockDPS, s_format("For shock to apply, target must have no more than %d life.", baseVal * 20 * output.ShockDurationMod))
				end
 			end
		end
		if (output.FreezeChanceOnHit + output.FreezeChanceOnCrit) > 0 then
			local sourceHitDmg = 0
			local sourceCritDmg = 0
			if canDeal.Cold and not modDB:Sum("FLAG", cfg, "ColdCannotFreeze") then
				sourceHitDmg = sourceHitDmg + output.ColdHitAverage
				sourceCritDmg = sourceCritDmg + output.ColdCritAverage
			end
			if canDeal.Lightning and modDB:Sum("FLAG", cfg, "LightningCanFreeze") then
				sourceHitDmg = sourceHitDmg + output.LightningHitAverage
				sourceCritDmg = sourceCritDmg + output.LightningCritAverage
			end
			local baseVal = calcSecondaryEffectBase("Freeze", sourceHitDmg, sourceCritDmg)
			if baseVal > 0 then
				skillFlags.freeze = true
				output.FreezeDurationMod = 1 + modDB:Sum("INC", cfg, "EnemyFreezeDuration") / 100 + enemyDB:Sum("INC", nil, "SelfFreezeDuration") / 100
				if breakdown then
					t_insert(breakdown.FreezeDPS, s_format("For freeze to apply, target must have no more than %d life.", baseVal * 20 * output.FreezeDurationMod))
				end
			end
		end

		-- Calculate enemy stun modifiers
		local enemyStunThresholdRed = -modDB:Sum("INC", cfg, "EnemyStunThreshold")
		if enemyStunThresholdRed > 75 then
			output.EnemyStunThresholdMod = 1 - (75 + (enemyStunThresholdRed - 75) * 25 / (enemyStunThresholdRed - 50)) / 100
		else
			output.EnemyStunThresholdMod = 1 - enemyStunThresholdRed / 100
		end
		local incDur = modDB:Sum("INC", cfg, "EnemyStunDuration")
		local incRecov = enemyDB:Sum("INC", nil, "StunRecovery")
		output.EnemyStunDuration = 0.35 * (1 + incDur / 100) / (1 + incRecov / 100)
		if breakdown then
			if output.EnemyStunDuration ~= 0.35 then
				breakdown.EnemyStunDuration = {
					"0.35s ^8(base duration)"
				}
				if incDur ~= 0 then
					t_insert(breakdown.EnemyStunDuration, s_format("x %.2f ^8(increased/reduced stun duration)", 1 + incDur/100))
				end
				if incRecov ~= 0 then
					t_insert(breakdown.EnemyStunDuration, s_format("/ %.2f ^8(increased/reduced enemy stun recovery)", 1 + incRecov/100))
				end
				t_insert(breakdown.EnemyStunDuration, s_format("= %.2fs", output.EnemyStunDuration))
			end
		end

	end

	-- Combine secondary effect stats
	if isAttack then
		combineStat("BleedChance", "AVERAGE")
		combineStat("BleedDPS", "CHANCE", "BleedChance")
		combineStat("PoisonChance", "AVERAGE")
		combineStat("PoisonDPS", "CHANCE", "PoisonChance")
		combineStat("PoisonDamage", "CHANCE", "PoisonChance")
		if skillData.showAverage then
			combineStat("TotalPoisonAverageDamage", "DPS")
		else
			combineStat("TotalPoisonDPS", "DPS")
		end
		combineStat("IgniteChance", "AVERAGE")
		combineStat("IgniteDPS", "CHANCE", "IgniteChance")
		if skillFlags.igniteCanStack then
			combineStat("IgniteDamage", "CHANCE", "IgniteChance")
			if skillData.showAverage then
				combineStat("TotalIgniteAverageDamage", "DPS")
			else
				combineStat("TotalIgniteDPS", "DPS")
			end
		end
		combineStat("ShockChance", "AVERAGE")
		combineStat("ShockDurationMod", "AVERAGE")
		combineStat("FreezeChance", "AVERAGE")
		combineStat("FreezeDurationMod", "AVERAGE")
	end

	if skillFlags.hit and skillData.decay then
		-- Calculate DPS for Essence of Delirium's Decay effect
		skillFlags.decay = true
		env.mainSkill.decayCfg = {
			slotName = skillCfg.slotName,
			flags = bor(band(skillCfg.flags, ModFlag.SourceMask), ModFlag.Dot, skillData.dotIsSpell and ModFlag.Spell or 0),
			keywordFlags = skillCfg.keywordFlags,
		}
		local dotCfg = env.mainSkill.decayCfg
		local effMult = 1
		if env.mode_effective then
			local resist = m_min(enemyDB:Sum("BASE", nil, "ChaosResist"), 75)
			local taken = enemyDB:Sum("INC", nil, "DamageTaken", "ChaosDamageTaken", "DotTaken")
			effMult = (1 - resist / 100) * (1 + taken / 100)
			output["DecayEffMult"] = effMult
			if breakdown and effMult ~= 1 then
				breakdown.DecayEffMult = effMultBreakdown("Chaos", resist, 0, taken, effMult)
			end
		end
		local inc = modDB:Sum("INC", dotCfg, "Damage", "ChaosDamage")
		local more = round(modDB:Sum("MORE", dotCfg, "Damage", "ChaosDamage"), 2)
		output.DecayDPS = skillData.decay * (1 + inc/100) * more * effMult
		local durationMod = calcMod(modDB, dotCfg, "Duration")
		output.DecayDuration = 10 * durationMod * debuffDurationMult
		if breakdown then
			breakdown.DecayDPS = { }
			t_insert(breakdown.DecayDPS, "Decay DPS:")
			dotBreakdown(breakdown.DecayDPS, skillData.decay, inc, more, nil, effMult, output.DecayDPS)
			if output.DecayDuration ~= 2 then
				breakdown.DecayDuration = {
					s_format("%.2fs ^8(base duration)", 10)
				}
				if durationMod ~= 1 then
					t_insert(breakdown.DecayDuration, s_format("x %.2f ^8(duration modifier)", durationMod))
				end
				if debuffDurationMult ~= 1 then
					t_insert(breakdown.DecayDuration, s_format("/ %.2f ^8(debuff expires slower/faster)", 1 / debuffDurationMult))
				end
				t_insert(breakdown.DecayDuration, s_format("= %.2fs", output.DecayDuration))
			end
		end
	end

	-- Calculate combined DPS estimate, including DoTs
	local baseDPS = output[(skillData.showAverage and "AverageDamage") or "TotalDPS"] + output.TotalDot
	output.CombinedDPS = baseDPS
	if skillFlags.poison then
		if skillData.showAverage then
			output.CombinedDPS = output.CombinedDPS + output.TotalPoisonAverageDamage
			output.WithPoisonAverageDamage = baseDPS + output.TotalPoisonAverageDamage
		else
			output.CombinedDPS = output.CombinedDPS + output.TotalPoisonDPS
			output.WithPoisonDPS = baseDPS + output.TotalPoisonDPS
		end
	end
	if skillFlags.ignite then
		if skillFlags.igniteCanStack then
			if skillData.showAverage then
				output.CombinedDPS = output.CombinedDPS + output.TotalIgniteAverageDamage
				output.WithIgniteAverageDamage = baseDPS + output.TotalIgniteAverageDamage
			else
				output.CombinedDPS = output.CombinedDPS + output.TotalIgniteDPS
				output.WithIgniteDPS = baseDPS + output.TotalIgniteDPS
			end
		else
			output.CombinedDPS = output.CombinedDPS + output.IgniteDPS
		end
	end
	if skillFlags.bleed then
		output.CombinedDPS = output.CombinedDPS + output.BleedDPS
	end
	if skillFlags.decay then
		output.CombinedDPS = output.CombinedDPS + output.DecayDPS
	end
    
    output.RFSelfDamage = (output.Life * 0.9 + output.EnergyShield * 0.7) * (1 - output.FireResist / 100)
end

-- Print various tables to the console
local function infoDump(env, output)	
	env.modDB:Print()
	ConPrintf("=== Enemy Mod DB ===")
	env.enemyDB:Print()
	ConPrintf("=== Main Skill ===")
	for _, gem in ipairs(env.mainSkill.gemList) do
		ConPrintf("%s %d/%d", gem.name, gem.level, gem.quality)
	end
	ConPrintf("=== Main Skill Flags ===")
	ConPrintf("Mod: %s", modLib.formatFlags(env.mainSkill.skillCfg.flags, ModFlag))
	ConPrintf("Keyword: %s", modLib.formatFlags(env.mainSkill.skillCfg.keywordFlags, KeywordFlag))
	ConPrintf("=== Main Skill Mods ===")
	env.mainSkill.skillModList:Print()
	ConPrintf("== Aux Skills ==")
	for i, aux in ipairs(env.auxSkillList) do
		ConPrintf("Skill #%d:", i)
		for _, gem in ipairs(aux.gemList) do
			ConPrintf("  %s %d/%d", gem.name, gem.level, gem.quality)
		end
	end
--	ConPrintf("== Conversion Table ==")
--	ConPrintTable(env.conversionTable)
	ConPrintf("== Output Table ==")
	local outNames = { }
	for name in pairs(env.output) do
		t_insert(outNames, name)
	end
	table.sort(outNames)
	for _, name in ipairs(outNames) do
		if type(env.output[name]) == "table" then
			local subNames = { }
			for subName in pairs(env.output[name]) do
				t_insert(subNames, subName)
			end
			table.sort(subNames)
			for _, subName in ipairs(subNames) do
				ConPrintf("%s.%s = %s", name, subName, tostring(env.output[name][subName]))
			end
		else
			ConPrintf("%s = %s", name, tostring(env.output[name]))
		end
	end
end

-- Generate a function for calculating the effect of some modification to the environment
local function getCalculator(build, fullInit, modFunc)
	-- Initialise environment
	local env = initEnv(build, "CALCULATOR")

	-- Save a copy of the initial mod database
	local initModDB = common.New("ModDB")
	initModDB:AddDB(env.modDB)
	initModDB.conditions = copyTable(env.modDB.conditions)
	initModDB.multipliers = copyTable(env.modDB.multipliers)
	local initEnemyDB = common.New("ModDB")
	initEnemyDB:AddDB(env.enemyDB)
	initEnemyDB.conditions = copyTable(env.enemyDB.conditions)
	initEnemyDB.multipliers = copyTable(env.enemyDB.multipliers)

	-- Run base calculation pass
	performCalcs(env)
	local baseOutput = env.output

	return function(...)
		-- Restore initial mod database
		env.modDB.mods = wipeTable(env.modDB.mods)
		env.modDB:AddDB(initModDB)
		env.modDB.conditions = copyTable(initModDB.conditions)
		env.modDB.multipliers = copyTable(initModDB.multipliers)
		env.enemyDB.mods = wipeTable(env.enemyDB.mods)
		env.enemyDB:AddDB(initEnemyDB)
		env.enemyDB.conditions = copyTable(initEnemyDB.conditions)
		env.enemyDB.multipliers = copyTable(initEnemyDB.multipliers)
		
		-- Call function to make modifications to the enviroment
		modFunc(env, ...)
		
		-- Run calculation pass
		performCalcs(env)

		return env.output
	end, baseOutput	
end

local calcs = { }

-- Get fast calculator for adding tree node modifiers
function calcs.getNodeCalculator(build)
	return getCalculator(build, true, function(env, nodeList)
		-- Build and merge modifiers for these nodes
		env.modDB:AddList(buildNodeModList(env, nodeList))
		--[[local nodeModList = buildNodeModList(env, nodeList)
		if remove then
			for _, mod in ipairs(nodeModList) do
				if mod.type == "LIST" or mod.type == "FLAG" then
					for i, dbMod in ipairs(env.modDB.mods[mod.name] or { }) do
						if mod == dbMod then
							t_remove(env.modDB.mods[mod.name], i)
							break
						end
					end
				elseif mod.type == "MORE" then
					env.modDB:NewMod(mod.name, mod.type, (1 / (1 + mod.value / 100) - 1) * 100, mod.source, mod.flags, mod.keywordFlags, unpack(mod.tagList))
				else
					env.modDB:NewMod(mod.name, mod.type, -mod.value, mod.source, mod.flags, mod.keywordFlags, unpack(mod.tagList))
				end
			end
		else
			env.modDB:AddList(nodeModList)
		end]]
	end)
end

-- Get calculator for other changes (adding/removing nodes, items, gems, etc)
function calcs.getMiscCalculator(build)
	-- Run base calculation pass
	local env = initEnv(build, "CALCULATOR")
	performCalcs(env)
	local baseOutput = env.output

	return function(override)
		env = initEnv(build, "CALCULATOR", override)
		performCalcs(env)
		return env.output
	end, baseOutput	
end

-- Build output for display in the side bar or calcs tab
function calcs.buildOutput(build, mode)
	-- Build output
	local env = initEnv(build, mode)
	performCalcs(env)

	local output = env.output

	if mode == "MAIN" then
		output.ExtraPoints = env.modDB:Sum("BASE", nil, "ExtraPoints")

		local specCfg = {
			source = "Tree"
		}
		output["Spec:LifeInc"] = env.modDB:Sum("INC", specCfg, "Life")
		output["Spec:ManaInc"] = env.modDB:Sum("INC", specCfg, "Mana")
		output["Spec:ArmourInc"] = env.modDB:Sum("INC", specCfg, "Armour", "ArmourAndEvasion")
		output["Spec:EvasionInc"] = env.modDB:Sum("INC", specCfg, "Evasion", "ArmourAndEvasion")
		output["Spec:EnergyShieldInc"] = env.modDB:Sum("INC", specCfg, "EnergyShield")

		env.conditionsUsed = { }
		local function addCond(var, mod)
			if not env.conditionsUsed[var] then
				env.conditionsUsed[var] = { }
			end
			t_insert(env.conditionsUsed[var], mod)
		end
		for _, db in ipairs{env.modDB, env.enemyDB} do
			for modName, modList in pairs(db.mods) do
				for _, mod in ipairs(modList) do
					for _, tag in ipairs(mod.tagList) do
						if tag.type == "Condition" then
							if tag.varList then
								for _, var in ipairs(tag.varList) do
									addCond(var, mod)
								end
							else
								addCond(tag.var, mod)
							end
						end
					end
				end
			end
		end
	elseif mode == "CALCS" then
		local buffList = { }
		local combatList = { }
		local curseList = { }
		if output.PowerCharges > 0 then
			t_insert(combatList, s_format("%d Power Charges", output.PowerCharges))
		end
		if output.FrenzyCharges > 0 then
			t_insert(combatList, s_format("%d Frenzy Charges", output.FrenzyCharges))
		end
		if output.EnduranceCharges > 0 then
			t_insert(combatList, s_format("%d Endurance Charges", output.EnduranceCharges))
		end
		if env.modDB.conditions.Onslaught then
			t_insert(combatList, "Onslaught")
		end
		if env.modDB.conditions.UnholyMight then
			t_insert(combatList, "Unholy Might")
		end
		for _, activeSkill in ipairs(env.activeSkillList) do
			if activeSkill.buffSkill then
				if activeSkill.skillFlags.multiPart then
					t_insert(buffList, activeSkill.activeGem.name .. " (" .. activeSkill.skillPartName .. ")")
				else
					t_insert(buffList, activeSkill.activeGem.name)
				end
			end
			if activeSkill.debuffSkill then
				if activeSkill.skillFlags.multiPart then
					t_insert(curseList, activeSkill.activeGem.name .. " (" .. activeSkill.skillPartName .. ")")
				else
					t_insert(curseList, activeSkill.activeGem.name)
				end
			end
		end
		for _, slot in ipairs(env.curseSlots) do
			t_insert(curseList, slot.name)
		end
		output.BuffList = table.concat(buffList, ", ")
		output.CombatList = table.concat(combatList, ", ")
		output.CurseList = table.concat(curseList, ", ")

		infoDump(env)
	end

	return env
end

return calcs