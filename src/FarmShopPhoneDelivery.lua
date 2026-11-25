-- FarmShopPhoneDelivery.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
end

--- Высота рельефа в точке. Возвращает nil для невалидной координаты.
local function deliveryTerrainHeight(x, z)
    local node = g_currentMission ~= nil and g_currentMission.terrainRootNode or g_terrainNode
    if node == nil then
        return nil
    end

    local ok, height = pcall(getTerrainHeightAtWorldPos, node, x, 0, z)
    if not ok or height == nil or height < -1000 then
        return nil
    end

    return height
end

--- Колбэк overlapBox: любое попадание считается препятствием.
function FarmShopPhone:deliveryOverlapCallback(node)
    if node ~= nil then
        self.deliveryOverlapHit = true
    end
end

--- Проверяет свободно ли место для габаритов объекта.
-- Если collision API недоступен, честно возвращает "неизвестно" (true) —
-- итоговую проверку всё равно выполняет placementManager движка.
function FarmShopPhone:deliveryCollisionFree(x, y, z, size)
    if overlapBox == nil or CollisionFlag == nil then
        self:logValidation("deliveryCollisionFree: overlapBox or CollisionFlag unavailable")
        return false  -- FAIL-SAFE: если API недоступно, считаем место небезопасным
    end

    local mask = (CollisionFlag.VEHICLE or 0) + (CollisionFlag.DYNAMIC_OBJECT or 0)
            + (CollisionFlag.STATIC_OBJECT or 0) + (CollisionFlag.BUILDING or 0)
            + (CollisionFlag.TREE or 0) + (CollisionFlag.WATER or 0)
    if mask == 0 then
        self:logValidation("deliveryCollisionFree: collision mask is zero")
        return false
    end

    self.deliveryOverlapHit = false
    local ok, err = pcall(overlapBox, x, y, z, 0, 0, 0,
        size.width * 0.5, size.height * 0.5, size.length * 0.5,
        "deliveryOverlapCallback", self, mask, true, true, false, true)
    
    if not ok then
        self:logValidation("deliveryCollisionFree: overlapBox failed: " .. tostring(err))
        return false  -- FAIL-SAFE
    end

    return not self.deliveryOverlapHit
end

--- Проверяет одну кандидатную точку: рельеф, уклон, коллизии, игрока/машину.
-- @return boolean ok, string reasonKey, number score, number y
function FarmShopPhone:validateDeliveryArea(point, size)
    local cfg = FarmShopPhone.DELIVERY_SAFETY
    size = size or cfg.defaultSize

    -- 9 точек: центр, 4 угла и 4 середины сторон.
    local hx, hz = size.width * 0.5, size.length * 0.5
    local samples = {
        { point[1], point[3] },
        { point[1] - hx, point[3] - hz }, { point[1] + hx, point[3] - hz },
        { point[1] - hx, point[3] + hz }, { point[1] + hx, point[3] + hz },
        { point[1], point[3] - hz }, { point[1], point[3] + hz },
        { point[1] - hx, point[3] }, { point[1] + hx, point[3] }
    }

    local minH, maxH, centerH = math.huge, -math.huge, nil
    for i, sample in ipairs(samples) do
        local h = deliveryTerrainHeight(sample[1], sample[2])
        if h == nil then
            self:logValidation("candidate " .. i .. ": invalid terrain height")
            return false, "FSP_DELIVERY_WATER", 0, 0
        end
        if i == 1 then
            centerH = h
        end
        minH = math.min(minH, h)
        maxH = math.max(maxH, h)
    end

    local heightDiff = maxH - minH
    if heightDiff > cfg.maxHeightDiff then
        self:logValidation(string.format("candidate rejected: height diff %.2f", heightDiff))
        return false, "FSP_DELIVERY_UNEVEN", 0, centerH
    end

    local run = math.max(0.5, math.min(size.width, size.length))
    local slopeDeg = math.deg(math.atan(heightDiff / run))
    if slopeDeg > cfg.maxSlopeDeg then
        self:logValidation(string.format("candidate rejected: slope %.1f deg", slopeDeg))
        return false, "FSP_DELIVERY_STEEP", 0, centerH
    end

    -- Игрок и его машина: не подпускаем товар вплотную.
    local player = g_localPlayer
    local checkNode = nil
    if player ~= nil then
        if player.getCurrentVehicle ~= nil and player:getCurrentVehicle() ~= nil then
            local vehicle = player:getCurrentVehicle()
            checkNode = vehicle ~= nil and vehicle.rootNode or nil
        elseif player.rootNode ~= nil then
            checkNode = player.rootNode
        end
    end

    if checkNode ~= nil and getWorldTranslation ~= nil then
        local ox, _, oz = getWorldTranslation(checkNode)
        local dist = math.sqrt((point[1] - ox) ^ 2 + (point[3] - oz) ^ 2)
        local footprint = math.max(size.width, size.length) * 0.5
        if dist < cfg.minPlayerClearance + footprint then
            self:logValidation("candidate rejected: too close to player/vehicle")
            return false, "FSP_DELIVERY_TOO_SMALL", 0, centerH
        end
    end

    if not self:deliveryCollisionFree(point[1], centerH + size.height * 0.5,
            point[3], size) then
        self:logValidation("candidate rejected: collision detected")
        return false, "FSP_DELIVERY_OBSTRUCTED", 0, centerH
    end

    -- Оценка: чем ровнее и ближе к игроку, тем лучше.
    local distance = 0
    if checkNode ~= nil and getWorldTranslation ~= nil then
        local ox, _, oz = getWorldTranslation(checkNode)
        distance = math.sqrt((point[1] - ox) ^ 2 + (point[3] - oz) ^ 2)
    end

    local score = 100.0 - slopeDeg * 4.0 - heightDiff * 6.0
            - math.min(distance, cfg.maxScoreDistance) * 1.5
    self:logValidation(string.format("candidate accepted: score %.1f slope %.1f diff %.2f",
        score, slopeDeg, heightDiff))

    return true, nil, score, centerH
end

--- Ищет безопасное место рядом с игроком детерминированным перебором.
function FarmShopPhone:findSafeDeliveryTarget(size)
    if not self:captureCallPosition() then
        return nil
    end

    local cfg = FarmShopPhone.DELIVERY_SAFETY
    local best, bestScore, bestHeight = nil, -math.huge, 0

    for _, radius in ipairs(cfg.radii) do
        for direction = 0, cfg.directions - 1 do
            local angle = direction * (2.0 * math.pi / cfg.directions)
            local point = {
                self.callPosition[1] + math.cos(angle) * radius,
                self.callPosition[2],
                self.callPosition[3] + math.sin(angle) * radius
            }

            local ok, _, score, height = self:validateDeliveryArea(point, size)
            if ok and score > bestScore then
                best, bestScore, bestHeight = point, score, height
            end
        end

        if best ~= nil then
            break
        end
    end

    if best == nil then
        self:logValidation("no safe delivery location found")
        return nil
    end

    best[2] = bestHeight
    best.rotX, best.rotY, best.rotZ = 0, 0, 0
    best.dirX, best.dirY, best.dirZ = 1, 0, 0
    best.dirPerpX, best.dirPerpY, best.dirPerpZ = 0, 0, 1

    self:logValidation("selected candidate X=" .. string.format("%.1f", best[1])
        .. " Z=" .. string.format("%.1f", best[3]))
    return best
end

--- Проверка этапа A: подготовить безопасную точку перед открытием каталога.
function FarmShopPhone:prepareDeliveryTarget(store, size)

    if store ~= nil and store.kind == "palletBuying" and store.placeable ~= nil then
        local spec = store.placeable.spec_palletBuyingStation
        if spec ~= nil and spec.palletSpawner ~= nil and spec.palletSpawner.pallets ~= nil then
            for _, pallet in ipairs(spec.palletSpawner.pallets) do
                if pallet ~= nil and pallet.size ~= nil then
                    size = {
                        width = pallet.size.width or pallet.size.x or size.width,
                        length = pallet.size.length or pallet.size.z or size.length,
                        height = pallet.size.height or pallet.size.y or size.height
                    }
                    break
                end
            end
        end
    elseif store ~= nil and (store.kind == "vehicleBuying" or store.kind == "vehicleSelling") and store.placeable ~= nil then
        -- For vehicle stores, use a larger default size to accommodate vehicles
        size = { width = 4.0, height = 2.0, length = 6.0 }
    end

    -- Store the delivery size for later use
    self.deliverySize = size

    self.deliveryTarget = self:findSafeDeliveryTarget(size)

    if self.deliveryTarget == nil then
        self:notifyDeliveryError("FSP_DELIVERY_UNSAFE")
        return false
    end

    return true
end


--- Пытается найти безопасное место доставки рядом с заданной точкой.
-- Возвращает таблицу {x,y,z,rotX,rotY,rotZ,dirX,dirY,dirZ,dirPerpX,dirPerpY,dirPerpZ} или nil
function FarmShopPhone:findSafeDeliveryLocation(origX, origY, origZ, origRot, size)
    local mission = g_currentMission
    if mission == nil or mission.terrainRootNode == nil then
        return nil
    end

    -- Use the provided size or stored delivery size
    size = size or self.deliverySize or FarmShopPhone.DELIVERY_SAFETY.defaultSize

    local radius = FarmShopPhone.UI.deliveryCheckRadius or 3.0
    local step = 1.0
    local maxAttempts = 20
    local ry = 0
    local player = g_localPlayer
    if player ~= nil and player.rootNode ~= nil then
        local _, ry, _ = getWorldRotation(player.rootNode)
    end

    -- Список смещений для поиска (справа, слева, вперёд, назад, по диагоналям)
    local offsets = {
        {0, 0}, -- исходная точка (уже проверена)
        {radius, 0}, {-radius, 0}, {0, radius}, {0, -radius},
        {radius, radius}, {radius, -radius}, {-radius, radius}, {-radius, -radius},
        {radius*1.5, 0}, {-radius*1.5, 0}, {0, radius*1.5}, {0, -radius*1.5},
    }

    for i, offset in ipairs(offsets) do
        local x = origX + offset[1]
        local z = origZ + offset[2]
        local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)

        local safe, reason = self:isDeliveryLocationSafe(x, y, z, size)
        if safe then
            return {x, y, z, 0, 0, 0, 0, 0, 1, 1, 0, 0}
        end
    end

    return nil
end

function FarmShopPhone:isDeliveryLocationSafe(x, y, z, size)
    -- Используем единую систему валидации через validateDeliveryArea
    size = size or FarmShopPhone.DELIVERY_SAFETY.defaultSize
    local ok, reason, _, _ = self:validateDeliveryArea({x, 0, z}, size)
    if not ok then
        return false, reason or getText("FSP_DELIVERY_UNSAFE_GENERIC")
    end
    return true, nil
end

