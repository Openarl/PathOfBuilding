-- Path of Building
--
-- Module: Calc Active Skill
-- Active skill setup.
--
local calcs = ...

local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor
local m_min = math.min
local m_max = math.max
local bor = bit.bor
local band = bit.band
local bnot = bit.bnot

-- Merge level modifier with given mod list
local mergeLevelCache = { }
local function mergeLevelMod(modList, mod, value)
	if not value then
		modList:AddMod(mod)
		return
	end
	if not mergeLevelCache[mod] then
		mergeLevelCache[mod] = { }
	end
	if mergeLevelCache[mod][value] then
		modList:AddMod(mergeLevelCache[mod][value])
	elseif value then
		local newMod = copyTable(mod, true)
		if type(newMod.value) == "table" then
			newMod.value = copyTable(newMod.value, true)
			if newMod.value.mod then
				newMod.value.mod = copyTable(newMod.value.mod, true)
				newMod.value.mod.value = value
			else
				newMod.value.value = value
			end
		else
			newMod.value = value
		end
		mergeLevelCache[mod][value] = newMod
		modList:AddMod(newMod)
	else
		modList:AddMod(mod)
	end
end

-- Merge skill modifiers with given mod list
function calcs.mergeSkillInstanceMods(env, modList, skillEffect)
	calcLib.validateGemLevel(skillEffect)
	local grantedEffect = skillEffect.grantedEffect
	modList:AddList(grantedEffect.baseMods)
	local stats = calcLib.buildSkillInstanceStats(skillEffect, grantedEffect)
	for stat, statValue in pairs(stats) do
		local map = grantedEffect.statMap[stat]
		if map then
			for _, mod in ipairs(map) do
				mergeLevelMod(modList, mod, statValue * (map.mult or 1) / (map.div or 1))
			end
		end
	end
end

-- Create an active skill using the given active gem and list of support gems
-- It will determine the base flag set, and check which of the support gems can support this skill
function calcs.createActiveSkill(activeEffect, supportList, summonSkill)
	local activeSkill = {
		activeEffect = activeEffect,
		supportList = supportList,
		summonSkill = summonSkill,
		skillData = { },
		buffList = { },
	}

	local activeGrantedEffect = activeEffect.grantedEffect
	
	-- Initialise skill types
	activeSkill.skillTypes = copyTable(activeGrantedEffect.skillTypes)
	if activeEffect.grantedEffect.minionSkillTypes then
		activeSkill.minionSkillTypes = copyTable(activeGrantedEffect.minionSkillTypes)
	end

	-- Initialise skill flag set ('attack', 'projectile', etc)
	local skillFlags = copyTable(activeGrantedEffect.baseFlags)
	activeSkill.skillFlags = skillFlags
	skillFlags.hit = skillFlags.hit or activeSkill.skillTypes[SkillType.Attack] or activeSkill.skillTypes[SkillType.Hit] or activeSkill.skillTypes[SkillType.Projectile]

	-- Process support skills
	activeSkill.effectList = { activeEffect }
	for _, supportEffect in ipairs(supportList) do
		-- Pass 1: Add skill types from compatible supports
		if calcLib.canGrantedEffectSupportActiveSkill(supportEffect.grantedEffect, activeSkill) then
			for _, skillType in pairs(supportEffect.grantedEffect.addSkillTypes) do
				activeSkill.skillTypes[skillType] = true
			end
		end
	end
	for _, supportEffect in ipairs(supportList) do
		-- Pass 2: Add all compatible supports
		if calcLib.canGrantedEffectSupportActiveSkill(supportEffect.grantedEffect, activeSkill) then
			t_insert(activeSkill.effectList, supportEffect)
			if supportEffect.isSupporting and activeEffect.srcInstance then
				supportEffect.isSupporting[activeEffect.srcInstance] = true
			end
			if supportEffect.grantedEffect.addFlags and not summonSkill then
				-- Support skill adds flags to supported skills (eg. Remote Mine adds 'mine')
				for k in pairs(supportEffect.grantedEffect.addFlags) do
					skillFlags[k] = true
				end
			end
		end
	end

	return activeSkill
end

-- Get weapon flags and info for given weapon
local function getWeaponFlags(env, weaponData, weaponTypes)
	local info = env.data.weaponTypeInfo[weaponData.type]
	if not info then
		return
	end
	if weaponTypes and not weaponTypes[weaponData.type] and 
		(not weaponData.countsAsAll1H or not (weaponTypes["Claw"] or weaponTypes["Dagger"] or weaponTypes["One Handed Axe"] or weaponTypes["One Handed Mace"] or weaponTypes["One Handed Sword"])) then
		return nil, info
	end
	local flags = ModFlag[info.flag]
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
function calcs.buildActiveSkillModList(env, actor, activeSkill)
	local skillTypes = activeSkill.skillTypes
	local skillFlags = activeSkill.skillFlags
	local activeEffect = activeSkill.activeEffect
	local activeGrantedEffect = activeEffect.grantedEffect
	calcLib.validateGemLevel(activeEffect)
	activeEffect.grantedEffectLevel = activeGrantedEffect.levels[activeEffect.level]

	-- Set mode flags
	if env.mode_buffs then
		skillFlags.buffs = true
	end
	if env.mode_combat then
		skillFlags.combat = true
	end
	if env.mode_effective then
		skillFlags.effective = true
	end

	-- Handle multipart skills
	local activeGemParts = activeGrantedEffect.parts
	if activeGemParts then
		if env.mode == "CALCS" and activeSkill == env.player.mainSkill then
			activeEffect.srcInstance.skillPartCalcs = m_min(#activeGemParts, activeEffect.srcInstance.skillPartCalcs or 1)
			activeSkill.skillPart = activeEffect.srcInstance.skillPartCalcs
		else
			activeEffect.srcInstance.skillPart = m_min(#activeGemParts, activeEffect.srcInstance.skillPart or 1)
			activeSkill.skillPart = activeEffect.srcInstance.skillPart
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

	if (skillTypes[SkillType.Shield] or skillFlags.shieldAttack) and not activeSkill.summonSkill and (not actor.itemList["Weapon 2"] or actor.itemList["Weapon 2"].type ~= "Shield") then
		-- Skill requires a shield to be equipped
		skillFlags.disable = true
		activeSkill.disableReason = "This skill requires a Shield"
	end

	if skillFlags.shieldAttack then
		-- Special handling for Spectral Shield Throw
		skillFlags.weapon2Attack = true
		activeSkill.weapon2Flags = 0
	elseif skillFlags.attack then
		-- Set weapon flags
		local weaponTypes = activeGrantedEffect.weaponTypes
		local weapon1Flags, weapon1Info = getWeaponFlags(env, actor.weaponData1, weaponTypes)
		if not weapon1Flags and activeSkill.summonSkill then
			-- Minion skills seem to ignore weapon types
			weapon1Flags, weapon1Info = ModFlag[env.data.weaponTypeInfo["None"].flag], env.data.weaponTypeInfo["None"]
		end
		if weapon1Flags then
			activeSkill.weapon1Flags = weapon1Flags
			skillFlags.weapon1Attack = true
			if weapon1Info.melee and skillFlags.melee then
				skillFlags.projectile = nil
			elseif not weapon1Info.melee and skillFlags.projectile then
				skillFlags.melee = nil
			end
		elseif skillTypes[SkillType.DualWield] or skillTypes[SkillType.MainHandOnly] or skillFlags.forceMainHand or (env.build.targetVersion ~= "2_6" and weapon1Info) then
			-- Skill requires a compatible main hand weapon
			skillFlags.disable = true
			activeSkill.disableReason = "Main Hand weapon is not usable with this skill"
		end
		if not skillTypes[SkillType.MainHandOnly] and not skillFlags.forceMainHand then
			local weapon2Flags, weapon2Info = getWeaponFlags(env, actor.weaponData2, weaponTypes)
			if weapon2Flags then
				activeSkill.weapon2Flags = weapon2Flags
				skillFlags.weapon2Attack = true
			elseif skillTypes[SkillType.DualWield] or (env.build.targetVersion ~= "2_6" and weapon2Info) then
				-- Skill requires a compatible off hand weapon
				skillFlags.disable = true
				activeSkill.disableReason = activeSkill.disableReason or "Off Hand weapon is not usable with this skill"
			elseif not skillFlags.weapon1Attack then
				-- Neither weapon is compatible
				skillFlags.disable = true
				activeSkill.disableReason = "No usable weapon equipped"
			end
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
		skillFlags.chaining = true
	end
	if skillFlags.area then
		skillModFlags = bor(skillModFlags, ModFlag.Area)
	end

	-- Build skill keyword flag set
	local skillKeywordFlags = 0
	if skillFlags.hit then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Hit)
	end
	if skillFlags.aura then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Aura)
	end
	if skillFlags.curse then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Curse)
	end
	if skillFlags.warcry then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Warcry)
	end
	if skillTypes[SkillType.MovementSkill] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Movement)
	end
	if skillTypes[SkillType.Vaal] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Vaal)
	end
	if skillTypes[SkillType.Brand] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Brand)
	end
	if skillTypes[SkillType.LightningSkill] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Lightning)
	end
	if skillTypes[SkillType.ColdSkill] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Cold)
	end
	if skillTypes[SkillType.FireSkill] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Fire)
	end
	if skillTypes[SkillType.ChaosSkill] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Chaos)
	end
	if skillFlags.weapon1Attack and band(activeSkill.weapon1Flags, ModFlag.Bow) ~= 0 then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Bow)
	end
	if skillFlags.totem then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Totem)
	elseif skillFlags.trap then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Trap)
	elseif skillFlags.mine then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Mine)
	else
		skillFlags.selfCast = true
	end
	if skillTypes[SkillType.Attack] then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Attack)
	end
	if skillTypes[SkillType.Spell] and not skillFlags.cast then
		skillKeywordFlags = bor(skillKeywordFlags, KeywordFlag.Spell)
	end

	-- Get skill totem ID for totem skills
	-- This is used to calculate totem life
	if skillFlags.totem then
		activeSkill.skillTotemId = activeGrantedEffect.skillTotemId
		if not activeSkill.skillTotemId then
			if activeGrantedEffect.color == 2 then
				activeSkill.skillTotemId = 2
			elseif activeGrantedEffect.color == 3 then
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
		skillName = activeGrantedEffect.name:gsub("^Vaal ",""):gsub("Summon Skeletons","Summon Skeleton"), -- This allows modifiers that target specific skills to also apply to their Vaal counterpart
		summonSkillName = activeSkill.summonSkill and activeSkill.summonSkill.activeEffect.grantedEffect.name,
		skillGem = activeEffect.gemData,
		skillGrantedEffect = activeGrantedEffect,
		skillPart = activeSkill.skillPart,
		skillTypes = activeSkill.skillTypes,
		skillCond = { },
		skillDist = env.mode_effective and env.configInput.projectileDistance,
		slotName = activeSkill.slotName,
	}
	if skillFlags.weapon1Attack then
		activeSkill.weapon1Cfg = copyTable(activeSkill.skillCfg, true)
		activeSkill.weapon1Cfg.skillCond = setmetatable({ ["MainHandAttack"] = true }, { __index = activeSkill.skillCfg.skillCond })
		activeSkill.weapon1Cfg.flags = bor(skillModFlags, activeSkill.weapon1Flags)
	end
	if skillFlags.weapon2Attack then
		activeSkill.weapon2Cfg = copyTable(activeSkill.skillCfg, true)
		activeSkill.weapon2Cfg.skillCond = setmetatable({ ["OffHandAttack"] = true }, { __index = activeSkill.skillCfg.skillCond })
		activeSkill.weapon2Cfg.flags = bor(skillModFlags, activeSkill.weapon2Flags)
	end

	-- Initialise skill modifier list
	local skillModList = new("ModList", actor.modDB)
	activeSkill.skillModList = skillModList
	activeSkill.baseSkillModList = skillModList

	if skillModList:Flag(activeSkill.skillCfg, "DisableSkill") then
		skillFlags.disable = true
		activeSkill.disableReason = "Skills of this type are disabled"
	end

	if skillFlags.disable then
		wipeTable(skillFlags)
		skillFlags.disable = true
		return
	end

	-- Add support gem modifiers to skill mod list
	for _, skillEffect in pairs(activeSkill.effectList) do
		if skillEffect.grantedEffect.support then
			calcs.mergeSkillInstanceMods(env, skillModList, skillEffect)
			local level = skillEffect.grantedEffect.levels[skillEffect.level]
			if level.manaMultiplier then
				skillModList:NewMod("ManaCost", "MORE", level.manaMultiplier, skillEffect.grantedEffect.modSource)
			end
			if level.manaCostOverride then
				activeSkill.skillData.manaCostOverride = level.manaCostOverride
			end
			if level.cooldown then
				activeSkill.skillData.cooldown = level.cooldown
			end
		end
	end

	-- Apply gem/quality modifiers from support gems
	for _, value in ipairs(skillModList:List(activeSkill.skillCfg, "SupportedGemProperty")) do
		if value.keyword == "active_skill" then
			activeEffect[value.key] = activeEffect[value.key] + value.value
		end
	end

	-- Add active gem modifiers
	activeEffect.actorLevel = actor.minionData and actor.level
	calcs.mergeSkillInstanceMods(env, skillModList, activeEffect)

	-- Add extra modifiers from granted effect level
	local level = activeEffect.grantedEffectLevel
	activeSkill.skillData.CritChance = level.critChance
	if level.damageMultiplier then
		skillModList:NewMod("Damage", "MORE", level.damageMultiplier, activeEffect.grantedEffect.modSource, ModFlag.Attack)
	end
	if level.cooldown then
		activeSkill.skillData.cooldown = level.cooldown
	end
	
	-- Add extra modifiers from other sources
	activeSkill.extraSkillModList = { }
	for _, value in ipairs(skillModList:List(activeSkill.skillCfg, "ExtraSkillMod")) do
		skillModList:AddMod(value.mod)
		t_insert(activeSkill.extraSkillModList, value.mod)
	end

	-- Extract skill data
	for _, value in ipairs(skillModList:List(activeSkill.skillCfg, "SkillData")) do
		activeSkill.skillData[value.key] = value.value
	end

	-- Create minion
	local minionList, isSpectre
	if activeGrantedEffect.minionList then
		if activeGrantedEffect.minionList[1] then
			minionList = copyTable(activeGrantedEffect.minionList)
		else
			minionList = copyTable(env.build.spectreList)
			--isSpectre = true
		end
	else
		minionList = { }
	end
	for _, skillEffect in ipairs(activeSkill.effectList) do
		if skillEffect.grantedEffect.support and skillEffect.grantedEffect.addMinionList then
			for _, minionType in ipairs(skillEffect.grantedEffect.addMinionList) do
				t_insert(minionList, minionType)
			end
		end
	end
	activeSkill.minionList = minionList
	if minionList[1] and not actor.minionData then
		local minionType
		if env.mode == "CALCS" and activeSkill == env.player.mainSkill then
			local index = isValueInArray(minionList, activeEffect.srcInstance.skillMinionCalcs) or 1
			minionType = minionList[index]
			activeEffect.srcInstance.skillMinionCalcs = minionType
		else
			local index = isValueInArray(minionList, activeEffect.srcInstance.skillMinion) or 1
			minionType = minionList[index]
			activeEffect.srcInstance.skillMinion = minionType
		end
		if minionType then
			local minion = { }
			activeSkill.minion = minion
			skillFlags.haveMinion = true
			minion.parent = env.player
			minion.enemy = env.enemy
			minion.type = minionType
			minion.minionData = env.data.minions[minionType]
			minion.level = activeSkill.skillData.minionLevelIsEnemyLevel and env.enemyLevel or activeSkill.skillData.minionLevel or activeEffect.grantedEffectLevel.levelRequirement
			-- fix minion level between 1 and 100
			minion.level = m_min(m_max(minion.level,1),100) 
			minion.itemList = { }
			minion.uses = activeGrantedEffect.minionUses
			minion.lifeTable = isSpectre and env.data.monsterLifeTable or env.data.monsterAllyLifeTable
			local attackTime = minion.minionData.attackTime * (1 - (minion.minionData.damageFixup or 0))
			local damage = env.data.monsterDamageTable[minion.level] * minion.minionData.damage * attackTime
			if activeGrantedEffect.minionHasItemSet then
				if env.mode == "CALCS" and activeSkill == env.player.mainSkill then
					if not env.build.itemsTab.itemSets[activeEffect.srcInstance.skillMinionItemSetCalcs] then
						activeEffect.srcInstance.skillMinionItemSetCalcs = env.build.itemsTab.itemSetOrderList[1]
					end
					minion.itemSet = env.build.itemsTab.itemSets[activeEffect.srcInstance.skillMinionItemSetCalcs]
				else
					if not env.build.itemsTab.itemSets[activeEffect.srcInstance.skillMinionItemSet] then
						activeEffect.srcInstance.skillMinionItemSet = env.build.itemsTab.itemSetOrderList[1]
					end
					minion.itemSet = env.build.itemsTab.itemSets[activeEffect.srcInstance.skillMinionItemSet]
				end
			end
			if activeSkill.skillData.minionUseBowAndQuiver and env.player.weaponData1.type == "Bow" then
				minion.weaponData1 = env.player.weaponData1
			else
				minion.weaponData1 = {
					type = minion.minionData.weaponType1 or "None",
					AttackRate = 1 / attackTime,
					CritChance = 5,
					PhysicalMin = round(damage * (1 - minion.minionData.damageSpread)),
					PhysicalMax = round(damage * (1 + minion.minionData.damageSpread)),
					range = minion.minionData.attackRange,
				}
			end
			minion.weaponData2 = { }
			if minion.uses then
				if minion.uses["Weapon 1"] then
					if minion.itemSet then
						local item = env.build.itemsTab.items[minion.itemSet[minion.itemSet.useSecondWeaponSet and "Weapon 1 Swap" or "Weapon 1"].selItemId]
						if item then
							minion.weaponData1 = item.weaponData[1]
						end
					else
						minion.weaponData1 = env.player.weaponData1
					end
				end
				if minion.uses["Weapon 2"] then	
					if minion.itemSet then
						local item = env.build.itemsTab.items[minion.itemSet[minion.itemSet.useSecondWeaponSet and "Weapon 2 Swap" or "Weapon 2"].selItemId]
						if item and item.weaponData then
							minion.weaponData2 = item.weaponData[2]
						end
					else
						minion.weaponData2 = env.player.weaponData2
					end
				end
			end
		end
	end

	-- Separate global effect modifiers (mods that can affect defensive stats or other skills)
	local i = 1
	while skillModList[i] do
		local effectType, effectName, effectTag
		for _, tag in ipairs(skillModList[i]) do
			if tag.type == "GlobalEffect" then
				effectType = tag.effectType
				effectName = tag.effectName or activeGrantedEffect.name
				effectTag = tag
				break
			end
		end
		if effectType then
			local buff
			for _, skillBuff in ipairs(activeSkill.buffList) do
				if skillBuff.type == effectType and skillBuff.name == effectName then
					buff = skillBuff
					break
				end
			end
			if not buff then
				buff = {
					type = effectType,
					name = effectName,
					allowTotemBuff = effectTag.allowTotemBuff,
					cond = effectTag.effectCond,
					enemyCond = effectTag.effectEnemyCond,
					stackVar = effectTag.effectStackVar,
					stackLimit = effectTag.effectStackLimit,
					stackLimitVar = effectTag.effectStackLimitVar,
					modList = { },
				}
				if skillModList[i].source == activeGrantedEffect.modSource then
					-- Inherit buff configuration from the active skill
					buff.activeSkillBuff = true
					buff.applyNotPlayer = activeSkill.skillData.buffNotPlayer
					buff.applyMinions = activeSkill.skillData.buffMinions
					buff.applyAllies = activeSkill.skillData.buffAllies
					buff.allowTotemBuff = activeSkill.skillData.allowTotemBuff
				end
				t_insert(activeSkill.buffList, buff)
			end
			local match = false
			for d = 1, #buff.modList do
				local destMod = buff.modList[d]
				if modLib.compareModParams(skillModList[i], destMod) and (destMod.type == "BASE" or destMod.type == "INC") then
					destMod = copyTable(destMod)
					destMod.value = destMod.value + skillModList[i].value
					buff.modList[d] = destMod
					match = true
					break
				end
			end
			if not match then
				t_insert(buff.modList, skillModList[i])
			end
			t_remove(skillModList, i)
		else
			i = i + 1
		end
	end

	if activeSkill.buffList[1] then
		-- Add to auxillary skill list
		t_insert(env.auxSkillList, activeSkill)
	end
end

-- Initialise the active skill's minion skills
function calcs.createMinionSkills(env, activeSkill)
	local activeEffect = activeSkill.activeEffect
	local minion = activeSkill.minion
	local minionData = minion.minionData

	minion.activeSkillList = { }
	local skillIdList = { }
	for _, skillId in ipairs(minionData.skillList) do
		if env.data.skills[skillId] then
			t_insert(skillIdList, skillId)
		end
	end
	for _, skill in ipairs(env.modDB:List(activeSkill.skillCfg, "ExtraMinionSkill")) do
		if not skill.minionList or isValueInArray(skill.minionList, minion.type) then
			t_insert(skillIdList, skill.skillId)
		end
	end
	for _, skillId in ipairs(skillIdList) do
		local activeEffect = {
			grantedEffect = env.data.skills[skillId],
			level = 1,
			quality = 0,
		}
		if #activeEffect.grantedEffect.levels > 1 then
			for level, levelData in ipairs(activeEffect.grantedEffect.levels) do
				if levelData[1] > minion.level then
					break
				else
					activeEffect.level = level
				end
			end
		end
		local minionSkill = calcs.createActiveSkill(activeEffect, activeSkill.supportList, activeSkill)
		calcs.buildActiveSkillModList(env, minion, minionSkill)
		minionSkill.skillFlags.minion = true
		minionSkill.skillFlags.minionSkill = true
		minionSkill.skillFlags.haveMinion = true
		minionSkill.skillFlags.spectre = activeSkill.skillFlags.spectre
		minionSkill.skillData.damageEffectiveness = 1 + (activeSkill.skillData.minionDamageEffectiveness or 0) / 100
		t_insert(minion.activeSkillList, minionSkill)
	end
	local skillIndex 
	if env.mode == "CALCS" then
		skillIndex = m_max(m_min(activeEffect.srcInstance.skillMinionSkillCalcs or 1, #minion.activeSkillList), 1)
		activeEffect.srcInstance.skillMinionSkillCalcs = skillIndex
	else
		skillIndex = m_max(m_min(activeEffect.srcInstance.skillMinionSkill or 1, #minion.activeSkillList), 1)
		if env.mode == "MAIN" then
			activeEffect.srcInstance.skillMinionSkill = skillIndex
		end
	end
	minion.mainSkill = minion.activeSkillList[skillIndex]
end