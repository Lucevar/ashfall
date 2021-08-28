
local CampfireUtil = require "mer.ashfall.camping.campfire.CampfireUtil"
local this = {}
local common = require("mer.ashfall.common.common")
local config = require("mer.ashfall.config.config").config
local foodConfig = common.staticConfigs.foodConfig
local teaConfig = common.staticConfigs.teaConfig
local conditionsCommon = require("mer.ashfall.conditionController")
local statsEffect = require("mer.ashfall.needs.statsEffect")
local temperatureController = require("mer.ashfall.temperatureController")
temperatureController.registerBaseTempMultiplier({ id = "thirstEffect", warmOnly = true })

local heatMulti = 4.0
local dysentryMulti = 5.0
local THIRST_EFFECT_LOW = 1.3
local THIRST_EFFECT_HIGH = 1.0
local restMultiplier = 1.0

local conditionConfig = common.staticConfigs.conditionConfig
local thirst = conditionConfig.thirst

function this.handleEmpties(data)
    if data.waterAmount and data.waterAmount < 1 then
        data.waterType = nil
        data.waterAmount = nil
        data.stewLevels = nil
        data.waterHeat = nil
        --restack / remove sound

        tes3ui.updateInventoryTiles()
    end
end

function this.calculate(scriptInterval, forceUpdate)
    if  scriptInterval == 0 and not forceUpdate then return end
    if not thirst:isActive() then
        thirst:setValue(0)
        return
    end
    if common.data.drinkingRain then
        return
    end
    if common.data.blockNeeds == true then
        return
    end
    if common.data.blockThirst == true then
        return
    end

    local thirstRate = config.thirstRate / 10
    local currentThirst = thirst:getValue()
    local temp = conditionConfig.temp
    --Hotter it gets the faster you become thirsty
    local heatEffect = math.clamp(temp:getValue(), temp.states.warm.min, temp.states.scorching.max )
    heatEffect = math.remap(heatEffect, temp.states.warm.min, temp.states.scorching.max, 1.0, heatMulti)
     --if you have dysentry you get thirsty more quickly
     local dysentryEffect = common.staticConfigs.conditionConfig.dysentery:isAffected() and dysentryMulti or 1.0
    --Calculate thirst
    local isResting = (tes3.mobilePlayer.sleeping or tes3.menuMode())
    if isResting then
        currentThirst = currentThirst + ( scriptInterval * thirstRate * heatEffect * dysentryEffect * restMultiplier )
    else
        currentThirst = currentThirst + ( scriptInterval * thirstRate * heatEffect * dysentryEffect )
    end
    currentThirst = math.clamp(currentThirst, 0, 100)
    thirst:setValue(currentThirst)
    --The thirstier you are, the more extreme heat temps are
    local thirstEffect = math.remap(currentThirst, 0, 100, THIRST_EFFECT_HIGH, THIRST_EFFECT_LOW)
    common.data.thirstEffect = thirstEffect
end

function this.update()
    this.calculate(0, true)
end

function this.getBottleData(id)
    return common.staticConfigs.bottleList[id and string.lower(id)]
end


function this.playerHasEmpties()
    for stack in tes3.iterate(tes3.player.object.inventory.iterator) do
        local bottleData = this.getBottleData(stack.object.id)
        if bottleData then
            common.log:trace("Found a bottle")
            if stack.variables then
                common.log:trace("Has data")
                if #stack.variables < stack.count then
                    common.log:trace("Some bottles have no data")
                    return true
                end

                for _, itemData in pairs(stack.variables) do
                    if itemData then
                        common.log:trace("itemData: %s", itemData)
                        common.log:trace("waterAmount: %s", itemData and itemData.data.waterAmount )
                        if itemData.data.waterAmount then
                            if itemData.data.waterAmount < bottleData.capacity then
                                --at least one bottle can be filled
                                common.log:trace("below capacity")
                                return true
                            end
                        else
                            --no itemData means empty bottle
                            common.log:trace("no waterAmount")
                            return true
                        end
                    end
                end
            else
                --no itemData means empty bottle
                common.log:trace("no variables")
                return true
            end
        end
    end
    return false
end


local function addDysentry(amountDrank)
    local survival = common.skills.survival.value
    local survivalRoll = math.random(100)
    if survivalRoll < survival then
        common.log:debug("Survival Effect of %s bypassed dysentery with a roll of %s", survival, survivalRoll)
        return
    end

    --determine max added dysentery
    local maxDysentery = math.remap(amountDrank, 0, 100, 85, 120)
    local minDysentery = maxDysentery / 4

    local dysentery = common.staticConfigs.conditionConfig.dysentery
    local dysentryAmount = math.random(minDysentery, maxDysentery)
    common.log:debug("Adding %s dysentery. Max was %s", dysentryAmount, maxDysentery)
    dysentery:setValue(dysentery:getValue() + dysentryAmount)
    common.log:debug("New dysentery amount is %s", dysentery:getValue())
end


local function blockMagickaAtronach()
    common.log:debug("Checking atronach settings")
    if tes3.isAffectedBy{ reference = tes3.player, effect = tes3.effect.stuntedMagicka} then
        common.log:debug("Is an atronach")
        if config.atronachRecoverMagickaDrinking ~= true then
            common.log:debug("Atronachs not allowed to recover magicka from drinking")
            return true
        end
    end
    return false
end


function this.drinkAmount(e)
    common.log:debug("drinkAmount. WaterType: %s", e.waterType)
    local amount = e.amount or 100
    local waterType = e.waterType
    if not conditionConfig.thirst:isActive() then
        return 0
    end

    local currentThirst = thirst:getValue()
    if currentThirst <= 0.1 then
        tes3.messageBox("You are fully hydrated.")
        return 0
    end
    local amountDrank = math.min( currentThirst, amount )

    local before = statsEffect.getMaxStat("magicka")
    thirst:setValue(currentThirst - amountDrank)
    local after = statsEffect.getMaxStat("magicka")

    if not blockMagickaAtronach() then
        --local magickaIncrease = tes3.mobilePlayer.magicka.base * ( amountDrank / 100 )
        local magickaIncrease = after - before
        tes3.modStatistic{
            reference = tes3.mobilePlayer,
            current = magickaIncrease,
            name = "magicka",
        }
    end
    conditionsCommon.updateCondition("thirst")
    this.update()
    event.trigger("Ashfall:updateTemperature", { source = "drinkAmount" } )
    event.trigger("Ashfall:updateNeedsUI")
    event.trigger("Ashfall:UpdateHud")

    tes3.playSound({reference = tes3.player, sound = "Drink"})

    if waterType == "dirty" then
        addDysentry(amountDrank)
    end
    return amountDrank
end

event.register("Ashfall:Drink", this.drinkAmount, {reference = tes3.player})

function this.callWaterMenuAction(callback)
    common.log:debug("calling water menu action")
    if common.data.drinkingRain == true then
        common.log:debug("Drinking rain is true")
        common.data.drinkingRain = nil
        common.helper.fadeTimeOut( 0.25, 2, callback )
    else
        common.log:debug("Drinking rain is false")
        callback()
    end
    common.data.drinkingWaterType = nil
end


--[[
    Transfers water, stew or tea
]]
function this.transferLiquid(e)
    --initialise itemData
    local item = e.item
    ---@type any
    local target = e.itemData
    local cost = e.cost
    local source = e.source
    local callback = e.callback
    local amount = e.amount

    if item and not target then
        target = tes3.addItemData{
            to = tes3.player,
            item = item,
            updateGUI = true
        }
    end

    --dirty container if drinking from raw water
    if common.data.drinkingWaterType then
        common.log:debug("Fill water DIRTY")
        target.data.waterType = common.data.drinkingWaterType
        common.data.drinkingWaterType = nil
    end
    local fillAmount
    local bottleData = this.getBottleData(item and item.id)
    local utensilData = target.object and CampfireUtil.getUtensilData(target)
    local capacity = (bottleData and bottleData.capacity) or ( utensilData and utensilData.capacity )


    target.data.waterAmount = target.data.waterAmount or 0

    local waterBefore = target.data.waterAmount
    if source then
        --add tea or stew
        if source.data.waterType then
            target.data.waterType = source.data.waterType
        elseif source.data.stewLevels then
            target.data.stewLevels = table.copy(source.data.stewLevels, {} )
        end

        fillAmount = math.min(
            capacity - target.data.waterAmount,
            source.data.waterAmount
        )
        if amount then
            fillAmount = math.min(amount, fillAmount)
        end

        --Set new waterHeat based on heat and amount of incoming and existing water
        local fillHeat = source.data.waterHeat or 0
        local existingHeat = target.data.waterHeat or 0
        local existingAmount = target.data.waterAmount or 0
        target.data.waterHeat =
            (fillHeat * fillAmount + existingHeat * existingAmount)
            / (fillAmount + existingAmount)

        common.helper.transferQuantity(source.data, target.data, "waterAmount", "waterAmount", fillAmount)

        target.data.lastWaterUpdated = nil

        common.log:debug("fillHeat: %s", fillHeat)
        common.log:debug("fillAmount: %s", fillAmount)
        common.log:debug("existingHeat: %s", existingHeat)
        common.log:debug("existingAmount: %s", existingAmount)
        common.log:debug("New water heat: %s", target.data.waterHeat)

        --clean source if empty
        if source.data.waterAmount < 1 then
            this.handleEmpties(source.data)
        end
        if source.object then
            event.trigger("Ashfall:UpdateAttachNodes", {campfire = source})
        end
    else
        target.data.waterAmount = capacity
    end

    local waterAfter = target.data.waterAmount
    --reduce ingredient levels
    if target.data.stewLevels then
        local ratio = waterBefore / waterAfter
        for name, stewLevel in pairs( target.data.stewLevels) do
            target.data.stewLevels[name] = stewLevel * ratio
        end
    end

    tes3ui.updateInventoryTiles()
    tes3.playSound({reference = tes3.player, sound = "Swim Left"})
    local contents = "water"
    if target.data.waterType == "dirty" then
        contents = "dirty water"
    elseif teaConfig.teaTypes[target.data.waterType] then
        contents = teaConfig.teaTypes[target.data.waterType].teaName
    elseif target.data.stewLevels then
        contents = foodConfig.isStewNotSoup(target.data.stewLevels) and "stew" or "soup"
    end
    if item then
        tes3.messageBox(
            "%s filled with %s.",
            item.name,
            contents
        )
    end

    if callback then callback() end

    if cost then
        mwscript.removeItem({ reference = tes3.player, item = "Gold_001", count = cost})
        local message = string.format(tes3.findGMST(tes3.gmst.sNotifyMessage63).value, cost, "Gold")
        tes3.messageBox(message)
        tes3.playSound{ reference = tes3.player, sound = "Item Gold Down"}
    end
end


--[[
    For inventorySelectMenu, filters containers that can be filled
]]
local function filterWaterContainer(e)
    --Filter out the source item
    if (e.source and e.source.data) == (e.itemData and e.itemData.data) then return false end

    local sourceStewLevels = e.source and e.source.data and e.source.data.stewLevels
    local targetStewLevels = e.itemData and e.itemData.data.stewLevels
    local sourceWaterType = e.source and e.source.data and e.source.data.waterType
    local targetWaterType = e.itemData and e.itemData.data.waterType
    local sourceIsTea = sourceWaterType and sourceWaterType ~= "dirty"
    local targetHasWater = (
        e.itemData and
        e.itemData.data.waterAmount and
        e.itemData.data.waterAmount > 0
    )

    --Can't mix water types
    if e.source and targetHasWater then
        if targetWaterType ~= sourceWaterType then
            return false
        end
    end
    if e.source and targetHasWater then
        if targetStewLevels ~= sourceStewLevels then
            return false
        end
    end

    --Check if we have a valid bottle
    local bottleData = this.getBottleData(e.item.id)
    if bottleData then
        local capacity = bottleData.capacity
        local currentAmount = e.itemData and e.itemData.data.waterAmount or 0

        --If adding a stew, check it's a valid pot
        if sourceStewLevels and not bottleData.holdsStew then
            return false
        end
        --Likewise, can't add tea to pots
        if sourceIsTea and bottleData.holdsStew then
            return false
        end
        return currentAmount < capacity
    else
        return false
    end
end


--Fill a bottle to max water capacity
function this.fillContainer(params)
    params = params or {}
    local cost = params.cost
    local source = params.source
    local fillContainerCallback = params.callback
    timer.delayOneFrame(function()
        local noResultsText =  "You have no containers to fill."
        if source and source.data and source.data.waterType then
            --because tea can only be placed in empty containers
            noResultsText = "You have no empty containers to fill."
        end
        tes3ui.showInventorySelectMenu{
            title = "Select Water Container",
            noResultsText = noResultsText,
            filter = function(e)
                return filterWaterContainer{
                    item = e.item,
                    itemData = e.itemData,
                    source = source
                }
            end,
            callback = function(e)
                if e.item then
                    this.callWaterMenuAction(function()
                        this.transferLiquid({
                            cost = cost,
                            source = source,
                            callback = fillContainerCallback,
                            item = e.item,
                            itemData = e.itemData,
                        })
                    end )
                end
            end
        }
        timer.delayOneFrame(function()
            common.log:debug("common.data.drinkingRain = false fill")
            common.data.drinkingRain = false
            common.data.drinkingWaterType = nil
        end)
    end)
end



return this
