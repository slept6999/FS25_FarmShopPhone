-- FarmShopPhoneStores.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
end

--- Определяет, можно ли открыть оригинальный интерфейс торговой точки.
-- Возвращает режим открытия ("vehicle", "pallet", "trigger")
-- или nil. Наличие одной лишь специализации недостаточно — проверяем реальный
-- интерфейс (activatable/sellingPoint/openShop), поэтому точка не попадает в список,
-- если её нельзя открыть.
local function getStoreOpenMode(placeable)
    if placeable == nil then
        return nil
    end

    -- Точки приёма сыпучих товаров и дилеры животных не являются магазинами покупки.
    if placeable.spec_sellingStation ~= nil or placeable.spec_animalDealer ~= nil then
        return nil
    end

    if placeable.spec_vehicleBuyingStation ~= nil and placeable.spec_vehicleBuyingStation.activatable ~= nil then
        return "vehicle"
    end

    if placeable.spec_palletBuyingStation ~= nil and placeable.spec_palletBuyingStation.activatable ~= nil then
        return "pallet"
    end

    -- Важно: spec_buyingStation/getBuyingStation — это станции ПРОДАЖИ/приёмки
    -- (BuyingStation наследует LoadingStation), а не магазины покупки. Опускаем их,
    -- чтобы цистерны, мельницы и приёмные пункты не попадали в список.
    -- Пользовательские торговые объекты с реальным интерфейсом покупки должны быть
    -- обнаружены через свои специализации выше; иначе точка отфильтровывается.
    return nil
end

--- Категория точки для иконки и подписи.
local function storeKindFromMode(mode)
    if mode == "pallet" then
        return "palletBuying"
    elseif mode == "vehicle" then
        return "vehicleBuying"
    end
    return "standard"
end

--- Безопасно вызывает метод объекта через pcall; возвращает true при успехе.
local function callMethodSafe(object, methodName)
    if object == nil or object[methodName] == nil then
        return false
    end

    local ok, err = pcall(object[methodName], object)
    if not ok then
        print(string.format("[FarmShopPhone] Failed to open the store UI via %s(): %s", methodName, tostring(err)))
        return false
    end

    return true
end

--- Устойчивый идентификатор торговой точки.
-- Приоритет: ссылка на placeable -> ссылка на хотспот -> узел триггера -> координаты.
-- Не используется только название или только координаты (ТЗ §1).
local function storeKey(store)
    if store.placeable ~= nil then
        return "p:" .. tostring(store.placeable)
    end
    if store.hotspot ~= nil then
        return "h:" .. tostring(store.hotspot)
    end
    if store.triggerNode ~= nil then
        return "t:" .. tostring(store.triggerNode)
    end
    return string.format("c:%.2f %.2f %.2f", store.posX or 0, store.posY or 0, store.posZ or 0)
end

--- Добавляет запись магазина, если она ещё не встречалась (дедупликация по источнику-объекту).
-- @param source строка-источник обнаружения для журнала ("placeable", "hotspot", "trigger")
local function addDiscoveredStore(self, entry, source, seenKeys, seenNames)
    local key = storeKey(entry)
    if seenKeys[key] then
        print(string.format("[FarmShopPhone][ShopDiscovery] Duplicate skipped (%s): %s",
            source, entry.name))
        return false
    end

    -- Резервная защита от дублей по названию, только когда ссылка на объект недоступна.
    if entry.placeable == nil and entry.hotspot == nil and seenNames[entry.name] then
        print(string.format("[FarmShopPhone][ShopDiscovery] Duplicate name skipped (%s): %s",
            source, entry.name))
        return false
    end

    seenKeys[key] = true
    seenNames[entry.name] = true
    -- Возможность открытия подтверждена проверкой интерфейса выше.
    entry.canOpenInterface = entry.openMode ~= nil
    entry.pickupAvailable = true
    entry.deliveryAvailable = true
    table.insert(self.stores, entry)
    print(string.format("[FarmShopPhone][ShopDiscovery] Store discovered (%s): %s [%s]",
        source, entry.name, entry.kind or "standard"))
    return true
end

--- Возвращает мировую позицию placeable объекта.
local function getPlaceablePosition(placeable)
    if placeable == nil then
        return nil
    end
    local node = placeable.rootNode
    if node == nil then
        node = placeable
    end
    if node == nil then
        return nil
    end

    local ok, x, y, z = pcall(getWorldTranslation, node)
    if not ok or x == nil then
        return nil
    end
    return {x = x, y = y, z = z}
end

--- Название хотспота карты (с учётом возможных API).
local function getHotspotName(hotspot)
    local name = hotspot.name
    if (name == nil or name == "") and hotspot.getName ~= nil then
        local ok, value = pcall(hotspot.getName, hotspot)
        if ok then
            name = value
        end
    end
    if name == nil or name == "" then
        name = FarmShopPhone:getText("FSP_STORE_UNKNOWN")
    end
    return name
end

--- Сканирует карту и собирает список торговых точек.
-- Источники (в порядке приоритета):
--   1. placeableSystem.placeables — реальные объекты карты с торгующими специализациями;
--   2. mapHotspots типа SHOP      — уточнение названия/координат, без дублей;
--   3. ShopTrigger               — стандартные торговые точки-триггеры;
--   4. storeSpawnPlaces          — резерв, только если не найдено ничего другого.
-- Список пересобирается при каждом вызове, поэтому подстраивается под любую карту
-- без жёстко заданных имён и координат. Точки приёма сыпучих товаров, животные
-- и собственные мастерские отфильтровываются по специализациям (ТЗ §1).
function FarmShopPhone:discoverStores()
    self.stores = {}

    local mission = g_currentMission
    if mission == nil then
        print("[FarmShopPhone][ShopDiscovery] Store discovery unavailable: g_currentMission is nil.")
        return
    end

    local seenKeys, seenNames = {}, {}

    -- Названия маркеров карты — для точек-триггеров, у которых нет собственного имени.
    local hotspotNames = {}
    if mission.mapHotspots ~= nil then
        for _, hotspot in ipairs(mission.mapHotspots) do
            if hotspot ~= nil then
                local pos = getPlaceablePosition(hotspot.placeable)
                table.insert(hotspotNames, {
                    name = getHotspotName(hotspot),
                    x = pos and pos.x or 0,
                    z = pos and pos.z or 0
                })
            end
        end
    end

    -- Имена и позиции известных объектов карты — пригодятся для именования триггеров.
    local placeableNames = {}

    local function nearestNamedPlaceable(x, z, maxDist)
        local bestName, bestDist = nil, maxDist
        for _, info in ipairs(placeableNames) do
            local dist = math.sqrt((info.x - x) ^ 2 + (info.z - z) ^ 2)
            if dist < bestDist then
                bestDist, bestName = dist, info.name
            end
        end
        return bestName
    end

    local function nearestHotspotName(x, z, maxDist)
        local bestName, bestDist = nil, maxDist
        for _, info in ipairs(hotspotNames) do
            local dist = math.sqrt((info.x - x) ^ 2 + (info.z - z) ^ 2)
            if dist < bestDist then
                bestDist, bestName = dist, info.name
            end
        end
        return bestName
    end

    -- Источник 1: установленные объекты карты. Только объекты с реально доступным
    -- интерфейсом покупки (vehicleBuying/palletBuying).
    if mission.placeableSystem ~= nil and mission.placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(mission.placeableSystem.placeables) do
            if placeable ~= nil then
                local mode = getStoreOpenMode(placeable)
                local name = "unknown"
                if placeable.getName ~= nil then
                    local ok, value = pcall(placeable.getName, placeable)
                    if ok then name = value end
                end
                if name == nil or name == "" then
                    name = placeable.name or FarmShopPhone:getText("FSP_STORE_UNKNOWN")
                end

                if name ~= nil and name ~= "" and name ~= FarmShopPhone:getText("FSP_STORE_UNKNOWN") then
                    local ppos = getPlaceablePosition(placeable)
                    if ppos ~= nil then
                        table.insert(placeableNames, {
                            name = name,
                            x = ppos.x,
                            z = ppos.z
                        })
                    end
                end

                if mode == nil then
                    print(string.format("[FarmShopPhone][ShopDiscovery] Skipped placeable (нет открываемого интерфейса магазина): %s",
                        tostring(name)))
                else
                    local pos = getPlaceablePosition(placeable)
                    addDiscoveredStore(self, {
                        name = name,
                        kind = storeKindFromMode(mode),
                        openMode = mode,
                        hotspot = nil,
                        placeable = placeable,
                        triggerNode = nil,
                        posX = pos and pos.x or 0,
                        posY = pos and pos.y or 0,
                        posZ = pos and pos.z or 0
                    }, "placeable", seenKeys, seenNames)
                end
            end
        end
    end

    -- Источник 2: маркеры карты (mapHotspots). Сам по себе маркер не доказывает
    -- возможности покупки — проверяем интерфейс связанного объекта.
    if PlaceableHotspot ~= nil and PlaceableHotspot.TYPE ~= nil and PlaceableHotspot.TYPE.SHOP ~= nil and
            mission.mapHotspots ~= nil then
        for _, hotspot in ipairs(mission.mapHotspots) do
            if hotspot ~= nil and hotspot.placeableType == PlaceableHotspot.TYPE.SHOP then
                local placeable = hotspot.placeable
                local mode = getStoreOpenMode(placeable)
                local name = getHotspotName(hotspot)
                if mode == nil then
                    print(string.format("[FarmShopPhone][ShopDiscovery] Skipped hotspot (нет открываемого интерфейса магазина): %s",
                        tostring(name)))
                else
                    local pos = getPlaceablePosition(placeable)
                    addDiscoveredStore(self, {
                        name = name,
                        kind = storeKindFromMode(mode),
                        openMode = mode,
                        hotspot = hotspot,
                        placeable = placeable,
                        triggerNode = nil,
                        posX = pos and pos.x or 0,
                        posY = pos and pos.y or 0,
                        posZ = pos and pos.z or 0
                    }, "hotspot", seenKeys, seenNames)
                end
            end
        end
    end

    -- Источник 3: стандартные торговые точки-триггеры (ShopTrigger).
    -- Название берём из ближайшего маркера карты; не придумываем номера.
    for _, trigger in ipairs(FarmShopPhone.shopTriggers) do
        if trigger ~= nil then
            local node = trigger.shopPlayerSpawn or trigger.rootNode
            local ok, x, y, z = pcall(getWorldTranslation, node)
            if node ~= nil and ok and x ~= nil then
                local name = nearestHotspotName(x, z, 25.0)
                if name == nil then
                    name = nearestNamedPlaceable(x, z, 25.0)
                end
                if name == nil then
                    name = FarmShopPhone:getText("FSP_STORE_GENERIC")
                    print(string.format("[FarmShopPhone][ShopDiscovery] Trigger name not found, using generic name"))
                end

                addDiscoveredStore(self, {
                    name = name,
                    kind = "standard",
                    openMode = "trigger",
                    hotspot = nil,
                    placeable = nil,
                    triggerObject = trigger,
                    triggerNode = node,
                    posX = x,
                    posY = y,
                    posZ = z
                }, "trigger", seenKeys, seenNames)
            else
                print("[FarmShopPhone][ShopDiscovery] Skipped trigger without a valid spawn node")
            end
        end
    end

    table.sort(self.stores, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    if #self.stores == 0 then
        print("[FarmShopPhone][ShopDiscovery] No eligible shop points were found on this map.")
    else
        print(string.format("[FarmShopPhone][ShopDiscovery] Discovered %d shop point(s).", #self.stores))
    end
end



--- Проверяет актуальность списка магазинов и удаляет недоступные (ТЗ §1).
-- Точка исключается, если объект удалён, выгружен со сцены или потерял ссылку.
function FarmShopPhone:verifyStoreAvailability()
    local mission = g_currentMission
    if mission == nil then
        return false
    end

    -- Актуальное множество размещённых объектов карты.
    local validPlaceables = nil
    if mission.placeableSystem ~= nil and mission.placeableSystem.placeables ~= nil then
        validPlaceables = {}
        for _, placeable in ipairs(mission.placeableSystem.placeables) do
            if placeable ~= nil then
                validPlaceables[placeable] = true
            end
        end
    end

    local removed = 0
    for i = #self.stores, 1, -1 do
        local store = self.stores[i]
        local dead = false

        if store.placeable ~= nil then
            if store.placeable.isDeleted ~= nil and store.placeable.isDeleted then
                dead = true
            elseif validPlaceables ~= nil and not validPlaceables[store.placeable] then
                dead = true
            end
        elseif store.hotspot ~= nil then
            if store.hotspot.isDeleted ~= nil and store.hotspot.isDeleted then
                dead = true
            end
        elseif store.triggerObject ~= nil then
            -- shopPlayerSpawn/rootNode могут быть числовыми id: проверяем сам триггер.
            if store.triggerObject.isDeleted ~= nil and store.triggerObject.isDeleted then
                dead = true
            end
        end

        if dead then
            print("[FarmShopPhone][ShopDiscovery] Store became unavailable: " .. store.name)
            table.remove(self.stores, i)
            removed = removed + 1
        end
    end

    if removed > 0 then
        print(string.format("[FarmShopPhone][ShopDiscovery] Store list updated: %d removed, %d remaining.",
            removed, #self.stores))
        if self.selectedStore > #self.stores then
            self.selectedStore = math.max(1, #self.stores)
        end
        return true
    end

    return false
end


