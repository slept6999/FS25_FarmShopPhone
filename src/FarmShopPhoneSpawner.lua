-- FarmShopPhoneSpawner.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

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


local function getText(name)
    return g_i18n:getText(name)
end

--- Снимок всех скалярных полей места спавна (полное восстановление и проверка).
function FarmShopPhone:snapshotPlace(place)
    local snap = {}
    if place == nil then
        return snap
    end
    for key, value in pairs(place) do
        local valueType = type(value)
        if valueType == "number" or valueType == "string" or valueType == "boolean" then
            snap[key] = value
        end
    end
    return snap
end

function FarmShopPhone:saveSpawnPlace(place)
    return self:snapshotPlace(place)
end

--- Восстанавливает все известные скалярные поля места спавна из снимка.
function FarmShopPhone:restoreSpawnPlace(place, backup)
    if place == nil or backup == nil then
        return
    end
    for key, value in pairs(backup) do
        if place[key] ~= nil then
            place[key] = value
        end
    end
end

--- Сравнение двух снимков по всем полям (числа — с допуском).
local function snapshotsEqual(a, b)
    for key, value in pairs(a) do
        local other = b[key]
        if type(value) == "number" and type(other) == "number" then
            if math.abs(value - other) > 1e-4 then
                return false, key
            end
        elseif other ~= value then
            return false, key
        end
    end
    return true, nil
end

--- Сохраняет исходную первую точку спавна магазина, если она ещё не сохранена.
function FarmShopPhone:captureOriginalSpawnPlace()
    if self.originalSpawnPlace ~= nil or g_currentMission == nil then
        return
    end

    local place = g_currentMission.storeSpawnPlaces ~= nil and g_currentMission.storeSpawnPlaces[1] or nil
    if place == nil then
        return
    end

    self.originalSpawnPlace = self:saveSpawnPlace(place)
end

--- Переносит стандартное место появления покупок в точку доставки.
-- Подобно Store Deliveries: координаты первой записи storeSpawnPlaces временно
-- заменяются и восстанавливаются после закрытия каталога.
function FarmShopPhone:applyDeliverySpawnPlace(target)
    if target == nil or g_currentMission == nil then
        print("[FarmShopPhone] Delivery skipped: destination is unavailable.")
        return false
    end

    -- Use the stored delivery size for collision checking
    local size = self.deliverySize or FarmShopPhone.DELIVERY_SAFETY.defaultSize

    -- ПРОВЕРКА БЕЗОПАСНОСТИ: проверяем место доставки перед применением
    local safe, reason = self:isDeliveryLocationSafe(target[1], target[2], target[3], size)
    if not safe then
        print("[FarmShopPhone] Delivery skipped: " .. (reason or "unsafe location"))
        self:showDeliveryError(reason)
        
        -- Пытаемся найти безопасное место рядом
        local safeTarget = self:findSafeDeliveryLocation(target[1], target[2], target[3], target, size)
        if safeTarget ~= nil then
            print("[FarmShopPhone] Found safe alternative delivery location")
            self:showDeliverySuccess("FSP_DELIVERY_FALLBACK")
            target = safeTarget
        else
            return false
        end
    end

    local place = g_currentMission.storeSpawnPlaces ~= nil and g_currentMission.storeSpawnPlaces[1] or nil
    if place == nil then
        print("[FarmShopPhone] Delivery skipped: no store spawn place on this map.")
        return false
    end

    self:captureOriginalSpawnPlace()

    place.startX, place.startY, place.startZ = target[1], target[2], target[3]
    if target.rotX ~= nil then
        place.rotX, place.rotY, place.rotZ = target.rotX, target.rotY, target.rotZ
        place.dirX, place.dirY, place.dirZ = target.dirX, target.dirY, target.dirZ
        place.dirPerpX, place.dirPerpY, place.dirPerpZ =
            target.dirPerpX, target.dirPerpY, target.dirPerpZ
    end

    local playerPos = FarmShopPhone:getPlayerPosition()
    if playerPos ~= nil then
        place.teleportX, place.teleportY, place.teleportZ = playerPos[1], playerPos[2], playerPos[3]
    end

    self.deliveryApplied = true
    self.appliedSpawnSnapshot = self:saveSpawnPlace(place)
    print(string.format("[FarmShopPhone][Delivery] Delivery point applied: X=%.1f Z=%.1f", target[1], target[3]))
    return true
end

--- Возвращает исходное место появления покупок.
-- Идемпотентно. Сравниваются ВСЕ изменённые поля, а не только координаты.
-- При конфликте (значения изменил другой мод) восстановление НЕ считается
-- успешным: возвращается false и выставляется lastRestoreConflict.
function FarmShopPhone:restoreSpawnPlaceToOriginal()
    if not self.deliveryApplied then
        return true
    end

    local place = g_currentMission ~= nil and g_currentMission.storeSpawnPlaces ~= nil and g_currentMission.storeSpawnPlaces[1] or nil
    local original = self.originalSpawnPlace
    local applied = self.appliedSpawnSnapshot

    self.deliveryApplied = false
    self.appliedSpawnSnapshot = nil

    if place == nil or original == nil then
        print("[FarmShopPhone][SpawnRestore] WARNING: cannot restore store spawn place (no data).")
        self.lastRestoreConflict = true
        return false
    end

    if applied ~= nil then
        local current = self:snapshotPlace(place)
        local equal, badKey = snapshotsEqual(applied, current)
        if not equal then
            print(string.format("[FarmShopPhone][SpawnRestore] WARNING: spawn place changed by another system (поле '%s'); restore skipped.",
                tostring(badKey)))
            self.lastRestoreConflict = true
            return false
        end
    end

    self:restoreSpawnPlace(place, original)
    print("[FarmShopPhone][SpawnRestore] Delivery point restored to the store spawn place.")
    return true
end

--- Переносит места спавна паллет паллетной станции в точку доставки.
-- Паллетные магазины создают товар через собственный PalletSpawner станции,
-- а не через общий storeSpawnPlaces, поэтому подменяются именно его места.
function FarmShopPhone:applyPalletSpawnPlaces(placeable, target)
    if placeable == nil or target == nil then
        return false
    end

    -- Use the stored delivery size for collision checking
    local size = self.deliverySize or FarmShopPhone.DELIVERY_SAFETY.defaultSize

    -- ПРОВЕРКА БЕЗОПАСНОСТИ для паллетной доставки
    local safe, reason = self:isDeliveryLocationSafe(target[1], target[2], target[3], size)
    if not safe then
        print("[FarmShopPhone] Pallet delivery skipped: " .. (reason or "unsafe location"))
        self:showDeliveryError(reason)
        
        -- Пытаемся найти безопасное место рядом
        local safeTarget = self:findSafeDeliveryLocation(target[1], target[2], target[3], target, size)
        if safeTarget ~= nil then
            print("[FarmShopPhone] Found safe alternative delivery location for pallet")
            target = safeTarget
        else
            return false
        end
    end

    local spec = placeable.spec_palletBuyingStation
    if spec == nil or spec.palletSpawner == nil then
        return false
    end

    local places = {}
    local seen = {}

    local function collect(list)
        for _, place in ipairs(list or {}) do
            if place ~= nil and not seen[place] then
                seen[place] = true
                table.insert(places, place)
            end
        end
    end

    collect(spec.palletSpawner.spawnPlaces)
    for _, list in pairs(spec.palletSpawner.fillTypeToSpawnPlaces or {}) do
        collect(list)
    end

    if #places == 0 then
        print("[FarmShopPhone] Pallet delivery unavailable: station has no spawn places.")
        return false
    end

    self.palletSpawnBackup = { placeable = placeable, places = {} }
    for _, place in ipairs(places) do
        table.insert(self.palletSpawnBackup.places, {
            place = place,
            snapshot = self:snapshotPlace(place)
        })
    end

    -- Распределяем паллеты по доступным местам спавна в одну линию вдоль
    -- перпендикуляра к направлению доставки, чтобы объекты не накладывались
    -- друг на друга (ТЗ §6, замечание о нескольких паллетах в одной точке).
    local maxPallets = math.min(#places, 10)  -- макс 10 паллет за раз
    local spec = placeable.spec_palletBuyingStation
    local perpX = target.dirPerpX or 0
    local perpZ = target.dirPerpZ or 1

    self.palletAppliedSnapshot = {}
    for i = 1, maxPallets do
        local place = places[i]

        -- Реальные габариты паллеты, если они известны специализации станции.
        local palletWidth, palletLength = 2.5, 3.0
        if spec and spec.palletSpawner and spec.palletSpawner.pallets and spec.palletSpawner.pallets[i] then
            local pallet = spec.palletSpawner.pallets[i]
            if pallet.size then
                palletWidth = pallet.size.width or pallet.size.x or palletWidth
                palletLength = pallet.size.length or pallet.size.z or palletLength
            end
        end

        -- Смещение от центральной точки: паллеты стоят рядом, а не в одной точке.
        local spacing = palletWidth + 1.0
        local offset = (i - (maxPallets + 1) * 0.5) * spacing
        local px = target[1] + perpX * offset
        local pz = target[3] + perpZ * offset
        local py = deliveryTerrainHeight(px, pz) or target[2]

        place.startX, place.startY, place.startZ = px, py, pz
        if target.rotX ~= nil then
            place.rotX, place.rotY, place.rotZ = target.rotX, target.rotY, target.rotZ
            place.dirX, place.dirY, place.dirZ = target.dirX, target.dirY, target.dirZ
            place.dirPerpX, place.dirPerpY, place.dirPerpZ =
                target.dirPerpX, target.dirPerpY, target.dirPerpZ
        end

        table.insert(self.palletAppliedSnapshot, {
            place = place,
            values = self:snapshotPlace(place)
        })
    end

    self.palletDeliveryApplied = true
    if spec ~= nil and spec.palletSpawner ~= nil then
        self.patchedSpawners[spec.palletSpawner] = true
    end
    print(string.format("[FarmShopPhone][Delivery] Pallet delivery point applied: X=%.1f Z=%.1f (pallets: %d)",
        target[1], target[3], maxPallets))
    return true
end


--- Возвращает места спавна паллет. Сравниваются ВСЕ изменённые поля.
-- При конфликте восстановление не считается успешным (false).
function FarmShopPhone:restorePalletSpawnPlaces()
    if not self.palletDeliveryApplied or self.palletSpawnBackup == nil then
        return true
    end

    local appliedByPlace = {}
    if self.palletAppliedSnapshot ~= nil then
        for _, snap in ipairs(self.palletAppliedSnapshot) do
            appliedByPlace[snap.place] = snap.values
        end
    end

    local ok = true
    for _, entry in ipairs(self.palletSpawnBackup.places) do
        local place = entry.place
        local applied = appliedByPlace[place]

        if applied ~= nil then
            local current = self:snapshotPlace(place)
            local equal, badKey = snapshotsEqual(applied, current)
            if not equal then
                print(string.format("[FarmShopPhone][SpawnRestore] WARNING: место паллеты изменила другая система (поле '%s'); пропуск.",
                    tostring(badKey)))
                self.lastRestoreConflict = true
                ok = false
            else
                self:restoreSpawnPlace(place, entry.snapshot)
            end
        else
            self:restoreSpawnPlace(place, entry.snapshot)
        end
    end

    self.palletDeliveryApplied = false
    self.palletSpawnBackup = nil
    self.palletAppliedSnapshot = nil
    self.patchedSpawners = {}

    if ok then
        print("[FarmShopPhone][SpawnRestore] Pallet delivery point restored.")
    end
    return ok
end

