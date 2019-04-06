-- Path of Building
--
-- Module: Global
-- Global constants
--

colorCodes = {
	NORMAL = "^xC8C8C8",
	MAGIC = "^x8888FF",
	RARE = "^xFFFF77",
	UNIQUE = "^xAF6025",
	RELIC = "^x60C060",
	GEM = "^x1AA29B",
	PROPHECY = "^xB54BFF",
	CURRENCY = "^xAA9E82",
	CRAFTED = "^xB8DAF1",
	CUSTOM = "^x5CF0BB",
	SOURCE = "^x88FFFF",
	UNSUPPORTED = "^xF05050",
	WARNING = "^xFF9922",
	TIP = "^x80A080",
	FIRE = "^xD02020",
	COLD = "^x60A0E7",
	LIGHTNING = "^xFFD700",
	CHAOS = "^xD02090",
	POSITIVE = "^x33FF77",
	NEGATIVE = "^xDD0022",
	OFFENCE = "^xE07030",
	DEFENCE = "^x8080E0",
	SCION = "^xFFF0F0",
	MARAUDER = "^xE05030",
	RANGER = "^x70FF70",
	WITCH = "^x7070FF",
	DUELIST = "^xE0E070",
	TEMPLAR = "^xC040FF",
	SHADOW = "^x30C0D0",
	MAINHAND = "^x50FF50",
	MAINHANDBG = "^x071907",
	OFFHAND = "^xB7B7FF",
	OFFHANDBG = "^x070719",
	SHAPER = "^x55BBFF",
	ELDER = "^xAA77CC",
	FRACTURED = "^xA29160",
}
colorCodes.STRENGTH = colorCodes.MARAUDER
colorCodes.DEXTERITY = colorCodes.RANGER
colorCodes.INTELLIGENCE = colorCodes.WITCH

ModFlag = { }
-- Damage modes
ModFlag.Attack =	 0x00000001
ModFlag.Spell =		 0x00000002
ModFlag.Hit =		 0x00000004
ModFlag.Dot =		 0x00000008
ModFlag.Cast =		 0x00000010
-- Damage sources
ModFlag.Melee =		 0x00000100
ModFlag.Area =		 0x00000200
ModFlag.Projectile = 0x00000400
ModFlag.SourceMask = 0x00000600
ModFlag.Ailment =	 0x00000800
-- Weapon types
ModFlag.Axe =		 0x00001000
ModFlag.Bow =		 0x00002000
ModFlag.Claw =		 0x00004000
ModFlag.Dagger =	 0x00008000
ModFlag.Mace =		 0x00010000
ModFlag.Staff =		 0x00020000
ModFlag.Sword =		 0x00040000
ModFlag.Wand =		 0x00080000
ModFlag.Unarmed =	 0x00100000
-- Weapon classes
ModFlag.WeaponMelee =0x00200000
ModFlag.WeaponRanged=0x00400000
ModFlag.Weapon =	 0x00800000
ModFlag.Weapon1H =	 0x01000000
ModFlag.Weapon2H =	 0x02000000

KeywordFlag = { }
-- Skill keywords
KeywordFlag.Aura =		0x00000001
KeywordFlag.Curse =		0x00000002
KeywordFlag.Warcry =	0x00000004
KeywordFlag.Movement =	0x00000008
KeywordFlag.Fire =		0x00000010
KeywordFlag.Cold =		0x00000020
KeywordFlag.Lightning =	0x00000040
KeywordFlag.Chaos =		0x00000080
KeywordFlag.Vaal =		0x00000100
KeywordFlag.Bow =		0x00000200
-- Skill types
KeywordFlag.Trap =		0x00001000
KeywordFlag.Mine =		0x00002000
KeywordFlag.Totem =		0x00004000
KeywordFlag.Minion =	0x00008000
KeywordFlag.Attack =	0x00010000
KeywordFlag.Spell =		0x00020000
KeywordFlag.Hit =		0x00040000
KeywordFlag.Ailment =	0x00080000
-- Other effects
KeywordFlag.Poison =	0x00100000
KeywordFlag.Bleed =		0x00200000
KeywordFlag.Ignite =	0x00400000
-- Damage over Time types
KeywordFlag.PhysicalDot=0x01000000
KeywordFlag.LightningDot=0x02000000
KeywordFlag.ColdDot =	0x04000000
KeywordFlag.FireDot =	0x08000000
KeywordFlag.ChaosDot =	0x10000000

-- Active skill types, used in ActiveSkills.dat and GrantedEffects.dat
-- Had to reverse engineer this, not sure what all of the values mean
SkillType = {
	Attack = 1,
	Spell = 2,
	Projectile = 3, -- Specifically skills which fire projectiles
	DualWield = 4, -- Attack requires dual wielding, only used on Dual Strike
	Buff = 5,
	Removed6 = 6, -- Now removed, was CanDualWield: Attack can be used while dual wielding
	MainHandOnly = 7, -- Attack only uses the main hand; removed in 3.5 but still needed for 2.6
	Removed8 = 8, -- Now removed, was only used on Cleave
	Minion = 9,
	Hit = 10, -- Skill hits (not used on attacks because all of them hit)
	Area = 11,
	Duration = 12,
	Shield = 13, -- Skill requires a shield
	ProjectileDamage = 14, -- Skill deals projectile damage but doesn't fire projectiles
	ManaCostReserved = 15, -- The skill's mana cost is a reservation
	ManaCostPercent = 16, -- The skill's mana cost is a percentage
	SkillCanTrap = 17, -- Skill can be turned into a trap
	SpellCanTotem = 18, -- Spell can be turned into a totem
	SkillCanMine = 19, -- Skill can be turned into a mine
	CauseElementalStatus = 20, -- Causes elemental status effects, but doesn't hit (used on Herald of Ash to allow Elemental Proliferation to apply)
	CreateMinion = 21, -- Creates or summons minions
	AttackCanTotem = 22, -- Attack can be turned into a totem
	Chaining = 23,
	Melee = 24,
	MeleeSingleTarget = 25,
	SpellCanRepeat = 26, -- Spell can repeat via Spell Echo
	Type27 = 27, -- No idea, used on auras and certain damage skills
	AttackCanRepeat = 28, -- Attack can repeat via Multistrike
	CausesBurning = 29, -- Deals burning damage
	Totem = 30,
	Type31 = 31, -- No idea, used on Molten Shell and the Thunder glove enchants, and added by Blasphemy
	Curse = 32,
	FireSkill = 33,
	ColdSkill = 34,
	LightningSkill = 35,
	TriggerableSpell = 36,
	Trap = 37,
	MovementSkill = 38,
	Removed39 = 39, -- Now removed, was Cast
	DamageOverTime = 40,
	Mine = 41,
	TriggeredSpell = 42,
	Vaal = 43,
	Aura = 44,
	LightningSpell = 45, -- Used for Mjolner
	Type46 = 46, -- Doesn't appear to be used at all
	TriggeredAttack = 47,
	ProjectileAttack = 48,
	MinionSpell = 49, -- Used for Null's Inclination
	ChaosSkill = 50,
	Type51 = 51, -- Not used by any skill
	Type52 = 52, -- Allows Contagion, Blight and Scorching Ray to be supported by Iron Will
	Type53 = 53, -- Allows Burning Arrow and Vigilant Strike to be supported by Inc AoE and Conc Effect
	Type54 = 54, -- Not used by any skill
	Type55 = 55, -- Allows Burning Arrow to be supported by Inc/Less Duration and Rapid Decay
	Type56 = 56, -- Not used by any skill
	Type57 = 57, -- Appears to be the same as 47
	Channelled = 58,
	Type59 = 59, -- Allows Contagion, Blight and Scorching Ray to be supported by Controlled Destruction
	ColdSpell = 60, -- Used for Cospri's Malice
	TriggeredGrantedSkill = 61, -- Skill granted by item that is automatically triggered, prevents trigger gems and trap/mine/totem from applying
	Golem = 62,
	Herald = 63,
	AuraDebuff = 64, -- Used by Death Aura, added by Blasphemy
	Type65 = 65, -- Excludes Ruthless from Cyclone
	Type66 = 66, -- Allows Iron Will
	SpellCanCascade = 67, -- Spell can cascade via Spell Cascade
	SkillCanVolley = 68, -- Skill can be supported by Volley
	SkillCanMirageArcher = 69, -- Skill can be supported by Mirage Archer
	Type70 = 70, -- Excludes Volley from Vaal Fireball and Vaal Spark
	Type71 = 71, -- Excludes Volley from Spectral Shield Throw
	Type72 = 72, -- Excludes Summon Phantasm on Kill from Manifest Dancing Dervish
	Type73 = 73, -- Allows LMP/GMP on Rain of Arrows and Toxic Rain
	Warcry = 74, -- Warcry
	Instant = 75, -- Instant cast skill
	Brand = 76,
	DestroysCorpse = 77, -- Consumes corpses on use
	NonHitChill = 78,
	ChillingArea = 79,
	AppliesCurse = 80,
	CanRapidFire = 81,
	AuraDuration = 82,
	AreaSpell = 83,
	OR = 84,
	AND = 85,
	NOT = 86,
}
