-- Path of Building
--
-- Module: Calc Tools
-- Various functions used by the calculation modules
--
local pairs = pairs
local m_floor = math.floor
local m_min = math.min
local m_max = math.max

calcLib = { }

-- Calculate and combine INC/MORE modifiers for the given modifier names
function calcLib.mod(modStore, cfg, ...)
	return (1 + (modStore:Sum("INC", cfg, ...)) / 100) * modStore:More(cfg, ...)
end

-- Calculate value
function calcLib.val(modStore, name, cfg)
	local baseVal = modStore:Sum("BASE", cfg, name)
	if baseVal ~= 0 then
		return baseVal * calcLib.mod(modStore, cfg, name)
	else
		return 0
	end
end

-- Calculate hit chance
function calcLib.hitChance(evasion, accuracy)
	local rawChance = accuracy / (accuracy + (evasion / 4) ^ 0.8) * 100
	return m_max(m_min(round(rawChance), 95), 5)	
end

-- Calculate physical damage reduction from armour
function calcLib.armourReduction(armour, raw)
	return round(armour / (armour + raw * 10) * 100)
end

-- Validate the level of the given gem
function calcLib.validateGemLevel(gemInstance)
	local grantedEffect = gemInstance.grantedEffect or gemInstance.gemData.grantedEffect
	if not grantedEffect.levels[gemInstance.level] then
		if gemInstance.gemData and gemInstance.gemData.defaultLevel then
			gemInstance.level = gemInstance.gemData.defaultLevel
		else
			-- Try limiting to the level range of the skill
			gemInstance.level = m_max(1, gemInstance.level)
			if #grantedEffect.levels > 0 then
				gemInstance.level = m_min(#grantedEffect.levels, gemInstance.level)
			end
			if not grantedEffect.levels[gemInstance.level] then
				-- That failed, so just grab any level
				gemInstance.level = next(grantedEffect.levels)
			end
		end
	end	
end

-- Check if given support skill can support the given skill types
function calcLib.canGrantedEffectSupportTypes(grantedEffect, skillTypes)
	for _, skillType in pairs(grantedEffect.excludeSkillTypes) do
		if skillTypes[skillType] then
			return false
		end
	end
	if not grantedEffect.requireSkillTypes[1] then
		return true
	end
	for _, skillType in pairs(grantedEffect.requireSkillTypes) do
		if skillTypes[skillType] then
			return true
		end
	end
	return false
end

-- Check if given support skill can support the given active skill
function calcLib.canGrantedEffectSupportActiveSkill(grantedEffect, activeSkill)
	if grantedEffect.unsupported then
		return false
	end
	if grantedEffect.supportGemsOnly and not activeSkill.activeEffect.gemData then
		return false
	end
	if activeSkill.summonSkill then
		return calcLib.canGrantedEffectSupportActiveSkill(grantedEffect, activeSkill.summonSkill)
	end
	if activeSkill.minionSkillTypes and calcLib.canGrantedEffectSupportTypes(grantedEffect, activeSkill.minionSkillTypes) then
		return true
	end
	return calcLib.canGrantedEffectSupportTypes(grantedEffect, activeSkill.skillTypes)
end

-- Check if given gem is of the given type ("all", "strength", "melee", etc)
function calcLib.gemIsType(gem, type)
	return (type == "all" or 
			(type == "elemental" and (gem.tags.fire or gem.tags.cold or gem.tags.lightning)) or 
			(type == "aoe" and gem.tags.area) or
			(type == "trap or mine" and (gem.tags.trap or gem.tags.mine)) or
			gem.tags[type])
end

-- From PyPoE's formula.py
function calcLib.getGemStatRequirement(level, isSupport, multi)
	if multi == 0 then
		return 0
	end
	local a, b
	if isSupport then
        b = 6 * multi / 100
		if multi == 100 then
			a = 1.495
        elseif multi == 60 then
            a = 0.945
        elseif multi == 40 then
            a = 0.6575
		else
			return 0
		end
    else
        b = 8 * multi / 100
        if multi == 100 then
            a = 2.1
            b = 7.75
        elseif multi == 60 then
            a = 1.325
        elseif multi == 40 then
            a = 0.924
		else
			return 0
		end
	end
	local req = round(level * a + b)
    return req < 14 and 0 or req
end