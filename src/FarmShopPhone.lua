-------------------------------------------------------------------------------
-- FarmShopPhone — телефон фермерских магазинов для FS25
--
-- Назначение: через телефонный оверлей звонить на торговые точки карты,
-- открывать стандартный каталог магазина, выбирать самовывоз или разовую
-- доставку и получать покупку в выбранном месте.
--
-- Архитектура:
--   1. discoverStores()   — сканирует mapHotspots карты и составляет список
--      точек с типом SHOP (магазины), исключая точки приёма сыпучих товаров
--      (spec_sellingStation). Список перестраивается при загрузке карты и
--      при каждом открытии телефона — поэтому работает на разных картах
--      без ручной настройки.
--   2. drawPhone()        — отрисовывает оверлей со списком точек, режимом
--      получения (самовывоз или доставка к игроку).
--   3. openShop()         — открывает штатный интерфейс выбранной точки
--      (VehicleShopDialog, паллетный магазин, WorkshopScreen) либо стандартный
--      ShopMenu для торговых точек-триггеров (ShopTrigger).
--   4. Доставка            — по образцу Store Deliveries: первая запись
--      storeSpawnPlaces временно переносится в точку доставки; плата 2.5%
--      начисляется через FarmStats.changeFinanceStats и списывается при
--      закрытии каталога.
--
-- Ограничения: каталог остаётся общим (не фильтруется по выбранной точке);
-- доставка экспериментальная (без проверки столкновений); только однопользовательский режим.
-------------------------------------------------------------------------------

FarmShopPhone = {}

-- Имя мода, под которым загружен скрипт (необходимо для g_currentModName).
FarmShopPhone.MOD_NAME = g_currentModName
FarmShopPhone.MOD_DIRECTORY = g_currentModDirectory or ''


-- Перехватываем создание стандартных торговых точек-триггеров (ShopTrigger),
-- чтобы включать их в список телефона как магазины со стандартным каталогом.
if ShopTrigger ~= nil and ShopTrigger.new ~= nil and not FarmShopPhone.shopTriggerInterceptorInstalled then
    FarmShopPhone.shopTriggerInterceptorInstalled = true

    local originalShopTriggerNew = ShopTrigger.new
    ShopTrigger.new = function(node)
        local instance = originalShopTriggerNew(node)

        if instance ~= nil then
            FarmShopPhone.shopTriggers = FarmShopPhone.shopTriggers or {}
            table.insert(FarmShopPhone.shopTriggers, instance)
        end

        return instance
    end
end

-- Состояние инициализации и жизни мода.
FarmShopPhone.isInitialized = false
FarmShopPhone.phoneOpen = false          -- телефон открыт

-- Список обнаруженных торговых точек и выделенная точка.
FarmShopPhone.stores = {}
FarmShopPhone.selectedStore = 1

-- Способ получения заказа: "pickup" (самовывоз) или "delivery" (доставка).
FarmShopPhone.fulfillment = "pickup"

-- Раскладка телефона в нормализованных координатах экрана.
FarmShopPhone.UI = {
    x = 0.365, y = 0.08, w = 0.27, h = 0.86,
    pad = 0.014,
    innerX = 0.383, innerW = 0.234,
    headerY = 0.805, headerH = 0.08,
    contentY = 0.235, contentH = 0.57,
    footerY = 0.145, footerH = 0.088,
    listX = 0.389, listTop = 0.76, listW = 0.222, rowH = 0.045, rows = 6,
    listContentW = 0.214, scrollW = 0.0022,
    cardX = 0.389, cardW = 0.107, cardH = 0.05,
    deliveryX = 0.504, fulfillmentY = 0.375,
    buttonX = 0.41, buttonY = 0.29, buttonW = 0.18, buttonH = 0.06
}

-- Первая видимая строка списка магазинов (прокрутка).
FarmShopPhone.storeScrollOffset = 1

--- Возвращает true, если точка находится внутри прямоугольника.
local function inRect(x, y, rx, ry, w, h)
    return x >= rx and x <= rx + w and y >= ry and y <= ry + h
end

--- Обрезает строку по символам UTF-8, не разрезая многобайтовые символы.
local function limitUtf8(value, maxChars)
    if value == nil then
        return ""
    end

    local i, count = 1, 0
    while i <= string.len(value) do
        count = count + 1
        if count > maxChars then
            return string.sub(value, 1, i - 1) .. "..."
        end

        local byte = string.byte(value, i)
        local charLen = 1
        if byte >= 0xF0 then
            charLen = 4
        elseif byte >= 0xE0 then
            charLen = 3
        elseif byte >= 0xC0 then
            charLen = 2
        end
        i = i + charLen
    end

    return value
end


-- Точка доставки: позиция игрока в момент вызова каталога.
-- Ручной выбор точки на карте не поддерживается.
FarmShopPhone.callPosition = nil

-- Проверка безопасности места доставки (все пороги — в одном месте).
FarmShopPhone.DELIVERY_SAFETY = {
    debug = false,
    defaultSize = { width = 2.5, length = 3.0, height = 2.0 },
    radii = { 0, 3, 6, 10, 15, 20 },
    directions = 12,
    maxSlopeDeg = 8.0,
    preferredSlopeDeg = 3.0,
    maxHeightDiff = 0.8,
    minPlayerClearance = 2.0,
    maxScoreDistance = 20.0
}

-- Выбранное автоматически безопасное место доставки.
FarmShopPhone.deliveryTarget = nil
FarmShopPhone.deliveryValidationFailed = false

-- Флаг того, что каталог магазина открыт и заказ ожидает завершения.
FarmShopPhone.orderActive = false
FarmShopPhone.shopWasVisible = false

-- История нажатий клавиш для определения одиночных нажатий ( edge detection ).
FarmShopPhone.keyStates = {}

-- Состояние блокировки ввода игрока, пока открыт телефон.
FarmShopPhone.lockedInput = nil
FarmShopPhone.previousCursorVisibility = nil

-- Стандартные торговые точки-триггеры карты (ShopTrigger).
FarmShopPhone.shopTriggers = {}

-- Доставка: исходное место спавна покупок и плата за доставку.
FarmShopPhone.originalSpawnPlace = nil
FarmShopPhone.deliveryApplied = false
FarmShopPhone.deliveryRate = 0.025
FarmShopPhone.deliveryMaxCharge = 5000
FarmShopPhone.deliveryTotalCharges = 0
FarmShopPhone.deliveryFarmId = nil
FarmShopPhone.financeHookInstalled = false

-- Места спавна паллет станции (подмена для паллетных магазинов).
FarmShopPhone.palletSpawnBackup = nil
FarmShopPhone.palletDeliveryApplied = false
FarmShopPhone.palletRestoreTimer = 0

-------------------------------------------------------------------------------
-- Вспомогательные функции
-------------------------------------------------------------------------------

--- Возвращает локализованную строку по имени ключа из modDesc.xml (секция <l10n>).
local function getText(name)
    return g_i18n:getText(name)
end

--- Возвращает текущие мировые координаты локального игрока (x, y, z).
-- @return таблица {x, y, z} или nil, если игрок недоступен.
local function getPlayerPosition()
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return nil
    end
    return {getWorldTranslation(g_localPlayer.rootNode)}
end

--- Сохраняет позицию и поворот игрока для заморозки на время открытого телефона.
function FarmShopPhone:freezePlayerPosition()
    self.frozenPosition = nil
    self.frozenRotation = nil

    if g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return
    end

    self.frozenPosition = {getWorldTranslation(g_localPlayer.rootNode)}
    self.frozenRotation = {getWorldRotation(g_localPlayer.rootNode)}
end

--- Возвращает игрока в замороженную позицию (вызывается каждый кадр при открытом телефоне).
function FarmShopPhone:applyFrozenPosition()
    if not self.phoneOpen or g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return
    end

    if self.frozenPosition ~= nil then
        setWorldTranslation(g_localPlayer.rootNode, self.frozenPosition[1], self.frozenPosition[2], self.frozenPosition[3])
    end

    if self.frozenRotation ~= nil then
        setWorldRotation(g_localPlayer.rootNode, self.frozenRotation[1], self.frozenRotation[2], self.frozenRotation[3])
    end
end

--- Снимает заморозку позиции игрока.
function FarmShopPhone:unfreezePlayerPosition()
    self.frozenPosition = nil
    self.frozenRotation = nil
end

--- Блокирует ввод игрока (движение, обзор) и показывает курсор, пока открыт телефон.
function FarmShopPhone:lockPlayerInput()
    local player = g_localPlayer or (g_currentMission ~= nil and g_currentMission.player) or nil
    local input = player ~= nil and player.inputComponent or nil

    if input ~= nil and input.lock ~= nil and not input.locked then
        input:lock()
        self.lockedInput = input
    end

    if g_inputBinding ~= nil and g_inputBinding.setShowMouseCursor ~= nil then
        if self.previousCursorVisibility == nil then
            self.previousCursorVisibility = g_inputBinding:getShowMouseCursor()
        end
        g_inputBinding:setShowMouseCursor(true)
    end
end

--- Снимает блокировку ввода и возвращает прежнюю видимость курсора.
function FarmShopPhone:unlockPlayerInput()
    if self.lockedInput ~= nil then
        if self.lockedInput.unlock ~= nil then
            self.lockedInput:unlock()
        end
        self.lockedInput = nil
    end

    if g_inputBinding ~= nil and g_inputBinding.setShowMouseCursor ~= nil then
        g_inputBinding:setShowMouseCursor(self.previousCursorVisibility == true)
        self.previousCursorVisibility = nil
    end
end

--- Проверяет, является ли объект точкой приёма сыпучих товаров (элеватор, силос и т.п.).
-- Такие точки исключаются из списка магазинов, потому что они продают сыпучее,
-- а не штучные товары (палеты, ящики, техника).
-- @param placeable объект места (placeable) у горячей точки карты
-- @return true, если у объекта есть специализация spec_sellingStation
local function hasSellingStation(placeable)
    if placeable == nil then
        return false
    end

    -- Прямая специализация на самом месте.
    if placeable.spec_sellingStation ~= nil then
        return true
    end

    -- В некоторых иерархиях объекта специализация лежит во вложенном placeable.
    local innerPlaceable = placeable.placeable
    return innerPlaceable ~= nil and innerPlaceable.spec_sellingStation ~= nil
end

-------------------------------------------------------------------------------
-- Жизненный цикл мода (события addModEventListener)
-------------------------------------------------------------------------------

--- Загружает текстуры интерфейса из папки мода (палитра UI Kit).
function FarmShopPhone:loadUiAssets()
    if self.uiAssets ~= nil then
        return self.uiAssetsReady
    end

    self.uiAssets = {}
    self.uiAssetsReady = false

    if Overlay == nil or Utils == nil then
        return false
    end

    local dir = Utils.getFilename("ui/textures/", self.MOD_DIRECTORY)
    local names = {
        "tablet_frame_blue", "phone_screen_background", "phone_header_panel", "phone_content_panel", "phone_footer_panel", "phone_32",
        "call_button_wide", "package_grey", "store_grey", "tractor_grey", "store_lime", "truck_lime", "check_lime"
    
    }

    local loaded = true
    for _, name in ipairs(names) do
        local ok, overlay = pcall(function()
            return Overlay.new(dir .. name .. ".png", 0, 0, 0.1, 0.1)
        end)
        if ok and overlay ~= nil and overlay.overlayId ~= 0 then
            self.uiAssets[name] = overlay
        else
            loaded = false
        end
    end

    self.uiAssetsReady = loaded
    if not loaded then
        print("[FarmShopPhone] Some UI textures are missing; fallback drawing is used.")
    end
    return loaded
end

--- Освобождает загруженные текстуры интерфейса.
function FarmShopPhone:deleteUiAssets()
    if self.uiAssets == nil then
        return
    end

    for _, overlay in pairs(self.uiAssets) do
        if overlay ~= nil and overlay.delete ~= nil then
            overlay:delete()
        end
    end

    self.uiAssets = nil
    self.uiAssetsReady = false
end

function FarmShopPhone:loadMap()
    self.isInitialized = true
    self.phoneOpen = false
    self.orderActive = false
    self.shopWasVisible = false
    self.deliveryApplied = false
    self.deliveryTotalCharges = 0
    self.deliveryFarmId = nil
    self:loadUiAssets()
    self:installFinanceHook()
    self:discoverStores()
    print("[FarmShopPhone] Loaded. Press O to open the phone.")
end

-------------------------------------------------------------------------------

function FarmShopPhone:deleteMap()
    self:deleteUiAssets()
    self.isInitialized = false
    self.phoneOpen = false
    self.orderActive = false
    self.shopWasVisible = false
    self.callPosition = nil
    self.stores = {}
    FarmShopPhone.shopTriggers = {}

    -- Возвращаем места спавна и списываем накопленную плату за доставку
    self.palletRestoreTimer = 0
    self:restoreSpawnPlaceToOriginal()
    self:restorePalletSpawnPlaces()
    self:chargeDeliveryFee()

    -- Разблокируем движение при выгрузке карты
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
    -- Снимаем заморозку и блокировку ввода при выгрузке карты
    self:unfreezePlayerPosition()
    self:unlockPlayerInput()
end

--- Добавляет горячую точку в список магазинов, если она ещё не есть.
-- @param hotspot горячая точка карты
-- @param seen таблица уже добавленных имён
-- @param target целевой список self.stores
--- Определяет тип магазина штучных товаров по специализациям объекта.
-- Возвращает "vehicleBuying" (техника), "palletBuying" (паллеты/ящики),
-- "vehicleSelling" (дилерская мастерская) или nil, если точка не подходит.
-- Исключает: spec_sellingStation (сыпучие, элеваторы), spec_animalDealer (животные),
--            собственные мастерские (ownWorkshop = true).
local function getRetailStoreKind(placeable)
    if placeable == nil then
        return nil
    end

    -- Магазины техники
    if placeable.spec_vehicleBuyingStation ~= nil then
        return "vehicleBuying"
    end

    -- Паллетные магазины (строймаргазины, товары в ящиках/на паллетах)
    if placeable.spec_palletBuyingStation ~= nil then
        return "palletBuying"
    end

    -- Исключаем точки приёма сыпучих товаров (элеваторы, силоса и т.п.)
    if placeable.spec_sellingStation ~= nil then
        return nil
    end

    -- Исключаем дилеров животных
    if placeable.spec_animalDealer ~= nil then
        return nil
    end

    -- Дилерская мастерская техники (ownWorkshop = false)
    local workshop = placeable.spec_workshop
    if workshop ~= nil and workshop.sellingPoint ~= nil and workshop.sellingPoint.ownWorkshop == false then
        return "vehicleSelling"
    end

    return nil
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

--- Добавляет горячую точку (mapHotspot) в список магазинов, если она ещё не добавлена.
-- Используется только как дополнительный источник координат/названия.
local function addHotspotStore(self, hotspot, seen, kind)
    local name = hotspot.name
    if hotspot.getName ~= nil then
        name = hotspot:getName()
    end
    if name == nil or name == "" then
        name = getText("FSP_STORE_UNKNOWN")
    end
    if not seen[name] then
        seen[name] = true
        local pos = getPlaceablePosition(hotspot.placeable)
        table.insert(self.stores, {
            name = name,
            kind = kind,
            hotspot = hotspot,
            placeable = hotspot.placeable,
            posX = pos and pos.x or 0,
            posY = pos and pos.y or 0,
            posZ = pos and pos.z or 0
        })
    end
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
    local x, y, z = getWorldTranslation(node)
    return {x = x, y = y, z = z}
end

--- Добавляет placeable объект в список магазинов.
local function addPlaceableStore(self, placeable, seen, kind)
    local name = placeable:getName() or placeable.name or getText("FSP_STORE_UNKNOWN")
    if name == nil or name == "" then
        name = getText("FSP_STORE_UNKNOWN")
    end
    if not seen[name] then
        seen[name] = true
        local pos = getPlaceablePosition(placeable)
        table.insert(self.stores, {
            name = name,
            kind = kind,
            hotspot = nil,
            placeable = placeable,
            posX = pos and pos.x or 0,
            posY = pos and pos.y or 0,
            posZ = pos and pos.z or 0
        })
    end
end

--- Добавляет стандартную торговую точку-триггер (ShopTrigger) в список.
local function addShopTriggerStore(self, trigger, seen)
    local node = trigger.shopPlayerSpawn
    if node == nil then
        return
    end

    local x, y, z = getWorldTranslation(node)
    local name = string.format("%s %d", getText("FSP_STANDARD_STORE"), #self.stores + 1)

    if not seen[name] then
        seen[name] = true
        table.insert(self.stores, {
            name = name,
            kind = "standard",
            hotspot = nil,
            placeable = nil,
            posX = x,
            posY = y,
            posZ = z
        })
    end
end

--- Сканирует карту и собирает список торговых точек.
-- В список попадают только горячие точки с типом PlaceableHotspot.TYPE.SHOP
-- у которых нет специализации spec_sellingStation (то есть это магазины
-- штучных товаров, а не точки приёма зерна/корма и т.п.).
-- Список пересобирается при каждом вызове, поэтому автоматически подстраивается
-- под загруженную карту. Если тип SHOP не сработал, пробует fallback по названиям.
function FarmShopPhone:discoverStores()
    self.stores = {}

    local mission = g_currentMission
    if mission == nil then
        print("[FarmShopPhone] Store discovery unavailable: g_currentMission is nil.")
        return
    end

    local seen = {}

    -- Стратегия 1: placeable-объекты — магазины штучных товаров (основной источник).
    -- Тип точки определяется по специализациям GIANTS (техника, паллеты, дилерская мастерская).
    if mission.placeableSystem ~= nil and mission.placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(mission.placeableSystem.placeables) do
            if placeable ~= nil then
                local kind = getRetailStoreKind(placeable)
                if kind ~= nil then
                    addPlaceableStore(self, placeable, seen, kind)
                end
            end
        end
    end

    -- Стратегия 2: mapHotspots типа SHOP (доп. источник координат/названия).
    if PlaceableHotspot ~= nil and PlaceableHotspot.TYPE ~= nil and PlaceableHotspot.TYPE.SHOP ~= nil and
            mission.mapHotspots ~= nil then
        for _, hotspot in ipairs(mission.mapHotspots) do
            if hotspot ~= nil and hotspot.placeableType == PlaceableHotspot.TYPE.SHOP then
                local placeable = hotspot.placeable
                local kind = getRetailStoreKind(placeable)
                local alreadyAdded = false
                if placeable ~= nil then
                    for _, existing in ipairs(self.stores) do
                        if existing.placeable == placeable then
                            alreadyAdded = true
                            break
                        end
                    end
                end
                if kind ~= nil and not alreadyAdded then
                    addHotspotStore(self, hotspot, seen, kind)
                end
            end
        end
    end

    -- Стратегия 2a: стандартные торговые точки-триггеры (ShopTrigger).
    for _, trigger in ipairs(FarmShopPhone.shopTriggers) do
        if trigger ~= nil then
            addShopTriggerStore(self, trigger, seen)
        end
    end

    -- Стратегия 3 (последний fallback): storeSpawnPlaces как точки самовывоза,
    -- только если не найдено ни одной точки через placeable/mapHotspots.
    if #self.stores == 0 and mission.storeSpawnPlaces ~= nil then
        for i, spawnPlace in ipairs(mission.storeSpawnPlaces) do
            local name = string.format("%s %d", getText("FSP_STORE_UNKNOWN"), i)
            if not seen[name] then
                seen[name] = true
                table.insert(self.stores, {
                    name = name,
                    hotspot = nil,
                    placeable = nil,
                    posX = spawnPlace.startX or 0,
                    posY = spawnPlace.startY or 0,
                    posZ = spawnPlace.startZ or 0
                })
            end
        end
    end

    table.sort(self.stores, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    if #self.stores == 0 then
        print("[FarmShopPhone] No eligible shop points were found on this map.")
    else
        print(string.format("[FarmShopPhone] Discovered %d shop point(s).", #self.stores))
        for i, store in ipairs(self.stores) do
            print(string.format("[FarmShopPhone]   %d. %s [%s]", i, store.name, store.kind or "standard"))
        end
    end
end
function FarmShopPhone:openPhone()
    if g_currentMission == nil or g_gui == nil then
        return
    end

    if g_guidedTourManager ~= nil and g_guidedTourManager:getIsTourRunning() then
        return
    end

    if self.phoneOpen then
        self.phoneOpen = false
        -- Разблокируем движение при закрытии телефона
        if g_localPlayer ~= nil then
            g_localPlayer.isControlEnabled = true
        end
        -- Снимаем заморозку и блокировку ввода при toggle-закрытии
        self:unfreezePlayerPosition()
        self:unlockPlayerInput()
        return
    end

    -- Каждый раз при открытии телефона сбрасываем способ получения на "Самовывоз".
    self.fulfillment = "pickup"
    self.callPosition = nil
    self.deliveryTarget = nil
    self.deliveryValidationFailed = false
    self.storeScrollOffset = 1

    self:discoverStores()
    self.selectedStore = math.min(math.max(self.selectedStore, 1), math.max(#self.stores, 1))
    self.phoneOpen = true

    -- Блокируем движение персонажа при открытом телефоне
    if g_localPlayer ~= nil then
        -- Сохраняем позицию персонажа для жёсткой заморозки
        self:freezePlayerPosition()
        g_localPlayer.isControlEnabled = false
    end

    -- Блокируем управление персонажем и включаем курсор, чтобы окном можно было пользоваться мышью
    self:lockPlayerInput()
end

--- Закрывает телефон и сбрасывает состояние заказа.
function FarmShopPhone:closePhone()
    self.phoneOpen = false
    -- Разблокируем движение при закрытии телефона
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
    -- Снимаем заморозку персонажа и блокировку ввода
    self:unfreezePlayerPosition()
    self:unlockPlayerInput()
end

function FarmShopPhone:captureCallPosition()
    self.callPosition = getPlayerPosition()
    if self.callPosition == nil then
        print("[FarmShopPhone] Cannot capture the order position: local player is unavailable.")
        return false
    end
    return true
end

--- Отладочный лог валидации (по умолчанию выключен).
function FarmShopPhone:logValidation(message)
    if FarmShopPhone.DELIVERY_SAFETY.debug then
        print("[FarmShopPhone][DeliveryValidation] " .. tostring(message))
    end
end

--- Выводит понятное игроку уведомление об ошибке доставки.
function FarmShopPhone:notifyDeliveryError(key)
    if g_currentMission == nil or g_currentMission.hud == nil then
        return
    end

    g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        getText(key), nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
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
        return true
    end

    local mask = (CollisionFlag.VEHICLE or 0) + (CollisionFlag.DYNAMIC_OBJECT or 0)
            + (CollisionFlag.STATIC_OBJECT or 0) + (CollisionFlag.BUILDING or 0)
            + (CollisionFlag.TREE or 0) + (CollisionFlag.WATER or 0)
    if mask == 0 then
        return true
    end

    self.deliveryOverlapHit = false
    pcall(overlapBox, x, y, z, 0, 0, 0,
        size.width * 0.5, size.height * 0.5, size.length * 0.5,
        "deliveryOverlapCallback", self, mask, true, true, false, true)

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
    self.deliveryValidationFailed = false

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
    end

    self.deliveryTarget = self:findSafeDeliveryTarget(size)

    if self.deliveryTarget == nil then
        self.deliveryValidationFailed = true
        self:notifyDeliveryError("FSP_DELIVERY_UNSAFE")
        return false
    end

    return true
end

--- Открывает штатный интерфейс выбранной торговой точки.
-- Возвращает true, если удалось открыть собственное окно точки.
function FarmShopPhone:openStoreInterface(store)
    local placeable = store.placeable

    if placeable == nil or store.kind == nil then
        return false
    end

    if store.kind == "vehicleBuying" then
        local spec = placeable.spec_vehicleBuyingStation
        if spec ~= nil and spec.activatable ~= nil then
            return callMethodSafe(spec.activatable, "run")
        end
    elseif store.kind == "palletBuying" then
        local spec = placeable.spec_palletBuyingStation
        if spec ~= nil and spec.activatable ~= nil then
            return callMethodSafe(spec.activatable, "run")
        end
    elseif store.kind == "vehicleSelling" then
        local spec = placeable.spec_workshop
        if spec ~= nil and spec.sellingPoint ~= nil then
            if callMethodSafe(spec.sellingPoint, "openMenu") then
                return true
            end
            if spec.sellingPoint.activatable ~= nil then
                return callMethodSafe(spec.sellingPoint.activatable, "run")
            end
        end
    end

    return false
end

function FarmShopPhone:openShop()
    if g_gui == nil then
        print("[FarmShopPhone] GUI is not available.")
        return
    end

    -- Если предыдущий заказ ещё не завершён, сначала возвращаем места спавна.
    self:restorePalletSpawnPlaces()

    if self.fulfillment == "delivery" then
        local store = self.stores[self.selectedStore]

        -- Этап A: без безопасного места рядом с игроком каталог не открываем.
        if not self:prepareDeliveryTarget(store, FarmShopPhone.DELIVERY_SAFETY.defaultSize) then
            return
        end

        -- Доставка всегда идёт к безопасной точке рядом с игроком.
        local target = self.deliveryTarget
        local applied = false

        -- Паллетные магазины спавнят товар через собственный PalletSpawner.
        if store ~= nil and store.kind == "palletBuying" and store.placeable ~= nil then
            local ok, result = pcall(function()
                return self:applyPalletSpawnPlaces(store.placeable, target)
            end)
            if not ok then
                print("[FarmShopPhone] Pallet spawn patch failed: " .. tostring(result))
                self:restorePalletSpawnPlaces()
                applied = false
            else
                applied = result
            end
        end

        if not applied then
            local ok, result = pcall(function()
                return self:applyDeliverySpawnPlace(target)
            end)
            if not ok then
                print("[FarmShopPhone] Store spawn patch failed: " .. tostring(result))
                self:restoreSpawnPlaceToOriginal()
                applied = false
            else
                applied = result
            end
        end
    else
        self:restoreSpawnPlaceToOriginal()
    end

    -- При открытии каталога закрываем телефон, чтобы не блокировать ввод.
    self:closePhone()

    local opened = self:openStoreInterface(self.stores[self.selectedStore])

    if not opened then
        -- Резерв: стандартный каталог игры для точек без собственного интерфейса.
        if ShopMenu == nil then
            print("[FarmShopPhone] ShopMenu class is not available.")
            return
        end
        g_gui:changeScreen(nil, ShopMenu)
    end

    self.orderActive = true
    self.shopWasVisible = false
end

function FarmShopPhone:handleKey(keyCode, callback)
    local pressed = Input.isKeyPressed(keyCode)
    local key = tostring(keyCode)
    local wasPressed = self.keyStates[key]
    self.keyStates[key] = pressed
    if pressed and not wasPressed then
        callback(self)
    end
end

function FarmShopPhone:updatePhoneInput()
    if not self.phoneOpen or g_gui == nil then
        return
    end

    -- Если открыт каталог магазина (ShopMenu), не обрабатываем ввод телефона.
    if self.orderActive and g_gui:getIsGuiVisible() then
        return
    end

    -- Прямая обработка клавиши Esc для закрытия телефона (edge detection)
    local escPressed = Input.isKeyPressed(Input.KEY_esc)
    local escKey = tostring(Input.KEY_esc)
    local escWasPressed = self.keyStates[escKey]
    self.keyStates[escKey] = escPressed
    if escPressed and not escWasPressed then
        self:closePhone()
    end

    -- Обработка клика мыши по списку торговых точек
    local mouseX = g_inputBinding ~= nil and g_inputBinding.mousePosXLast or nil
    local mouseY = g_inputBinding ~= nil and g_inputBinding.mousePosYLast or nil
    local ui = FarmShopPhone.UI
    if #self.stores > 0 and mouseX ~= nil and mouseY ~= nil then
        local mousePressed = Input.isMouseButtonPressed(Input.MOUSE_BUTTON_LEFT)
        local mouseKey = "MOUSE_LEFT"
        local mouseWasPressed = self.keyStates[mouseKey]
        self.keyStates[mouseKey] = mousePressed
        if mousePressed and not mouseWasPressed then
            local firstIndex = self.storeScrollOffset
            local lastIndex = math.min(#self.stores, firstIndex + ui.rows - 1)

            if mouseX >= ui.listX and mouseX <= ui.listX + ui.listW then
                for i = firstIndex, lastIndex do
                    local rowY = ui.listTop - (i - firstIndex + 1) * ui.rowH
                    if inRect(mouseX, mouseY, ui.listX, rowY, ui.listW, ui.rowH) then
                        self.selectedStore = i
                        return
                    end
                end
            end

            if inRect(mouseX, mouseY, ui.cardX, ui.fulfillmentY, ui.cardW, ui.cardH) then
                self.fulfillment = "pickup"
                return
            end

            if inRect(mouseX, mouseY, ui.deliveryX, ui.fulfillmentY, ui.cardW, ui.cardH) then
                self.fulfillment = "delivery"
                self:prepareDeliveryTarget(self.stores[self.selectedStore],
                    FarmShopPhone.DELIVERY_SAFETY.defaultSize)
                return
            end

            if inRect(mouseX, mouseY, ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH) then
                self:openShop()
                return
            end
        end
    end

    -- Прокрутка списка колесом мыши при наведении на строки.
    local overList = mouseX ~= nil and mouseY ~= nil
            and inRect(mouseX, mouseY, ui.listX,
                ui.listTop - ui.rows * ui.rowH, ui.listW, ui.rows * ui.rowH)
    local wheelUp = Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP)
    local wheelDown = Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN)
    local upWas = self.keyStates["WHEEL_UP"]
    local downWas = self.keyStates["WHEEL_DOWN"]
    self.keyStates["WHEEL_UP"] = wheelUp
    self.keyStates["WHEEL_DOWN"] = wheelDown
    local maxOffset = math.max(1, #self.stores - ui.rows + 1)

    if overList and wheelUp and not upWas then
        self.storeScrollOffset = math.max(1, self.storeScrollOffset - 1)
    elseif overList and wheelDown and not downWas then
        self.storeScrollOffset = math.min(maxOffset, self.storeScrollOffset + 1)
    end

    self:handleKey(Input.KEY_up, function(phone)
        if #phone.stores > 0 then
            phone.selectedStore = ((phone.selectedStore - 2) % #phone.stores) + 1
            phone:keepSelectionVisible()
        end
    end)
    self:handleKey(Input.KEY_down, function(phone)
        if #phone.stores > 0 then
            phone.selectedStore = (phone.selectedStore % #phone.stores) + 1
            phone:keepSelectionVisible()
        end
    end)
    self:handleKey(Input.KEY_return, function(phone)
        phone:openShop()
    end)
    self:handleKey(Input.KEY_a, function(phone)
        phone.fulfillment = "pickup"
    end)
    self:handleKey(Input.KEY_d, function(phone)
        phone.fulfillment = "delivery"
        phone:prepareDeliveryTarget(phone.stores[phone.selectedStore],
            FarmShopPhone.DELIVERY_SAFETY.defaultSize)
    end)
    self:handleKey(Input.KEY_left, function(phone)
        phone.fulfillment = "pickup"
    end)
    self:handleKey(Input.KEY_right, function(phone)
        phone.fulfillment = "delivery"
        phone:prepareDeliveryTarget(phone.stores[phone.selectedStore],
            FarmShopPhone.DELIVERY_SAFETY.defaultSize)
    end)
end

--- Рисует текстуру из UI Kit в заданных нормализованных координатах.
function FarmShopPhone:drawTexture(name, x, y, w, h)
    local overlay = self.uiAssets ~= nil and self.uiAssets[name] or nil
    if overlay == nil or overlay.overlayId == 0 then
        return false
    end

    overlay:setPosition(x, y)
    overlay:setDimension(w, h)
    overlay:render()
    return true
end

--- Поддерживает выбранную строку в видимой области списка.
function FarmShopPhone:keepSelectionVisible()
    local rows = FarmShopPhone.UI.rows
    if self.selectedStore < self.storeScrollOffset then
        self.storeScrollOffset = self.selectedStore
    elseif self.selectedStore >= self.storeScrollOffset + rows then
        self.storeScrollOffset = math.max(1, self.selectedStore - rows + 1)
    end
end

--- Рисует квадратную иконку с учётом соотношения сторон экрана.
function FarmShopPhone:drawIconSquare(name, x, y, size)
    local aspect = g_screenAspectRatio or (16.0 / 9.0)
    return self:drawTexture(name, x, y, size / aspect, size)
end

--- Рисует текст строго по центру заданного прямоугольника.
-- В FS25 вертикальное выравнивание задаётся отдельно от горизонтального
-- (см. dataS/scripts/gui/base/ButtonOverlay.lua:120-148).
function FarmShopPhone:drawCenteredText(value, x, y, w, h, size, r, g, b, a)
    setTextColor(r, g, b, a)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    -- Компенсация базовой линии, как в ButtonOverlay.lua:128 (textYOffsetFactor = 0.17).
    renderText(x + w * 0.5, y + h * 0.5 + size * 0.15, size, value)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

--- Иконка типа поставщика для строки списка.
local function storeIconName(kind)
    if kind == "palletBuying" then
        return "package_grey"
    elseif kind == "vehicleBuying" or kind == "vehicleSelling" then
        return "tractor_grey"
    end
    return "store_grey"
end

--- Короткая локализованная категория точки вместо технического ключа.
local function storeKindLabel(kind)
    if kind == "palletBuying" then
        return getText("FSP_UI_KIND_PALLET")
    elseif kind == "vehicleBuying" or kind == "vehicleSelling" then
        return getText("FSP_UI_KIND_VEHICLE")
    elseif kind == "standard" then
        return getText("FSP_UI_KIND_STANDARD")
    end
    return getText("FSP_UI_KIND_OTHER")
end

function FarmShopPhone:drawPhone()
    if not self.phoneOpen then
        return
    end

    local ui = FarmShopPhone.UI
    local textured = self.uiAssetsReady

    -- Korpus планшета: синий защитный чехол, безель, камера, кнопки.
    -- Экранная область рамки прозрачна, панели рисуются поверх неё.
    if textured then
        self:drawTexture("tablet_frame_blue", ui.x - 0.014, ui.y - 0.012,
            ui.w + 0.028, ui.h + 0.024)
    end

    -- Экранная область строго внутри безеля корпуса (SVG: 50..830 x 50..810 из 880x860).
    local frameX = ui.x - 0.014
    local frameY = ui.y - 0.012
    local frameW = ui.w + 0.028
    local frameH = ui.h + 0.024
    local screenX = frameX + frameW * 0.057
    local screenY = frameY + frameH * 0.058
    local screenW = frameW * 0.886
    local screenH = frameH * 0.884

    -- Основа телефона: фон, шапка, контент, подвал.
    if not textured then
        drawFilledRect(screenX, screenY, screenW, screenH, 0.025, 0.035, 0.05, 0.96)
        drawFilledRect(ui.innerX, ui.headerY, ui.innerW, ui.headerH, 0.13, 0.16, 0.17, 1)
        drawFilledRect(ui.innerX, ui.contentY, ui.innerW, ui.contentH, 0.09, 0.11, 0.12, 1)
        drawFilledRect(ui.innerX, ui.footerY, ui.innerW, ui.footerH, 0.13, 0.16, 0.17, 1)
    else
        self:drawTexture("phone_screen_background", screenX, screenY, screenW, screenH)
        self:drawTexture("phone_header_panel", ui.innerX, ui.headerY, ui.innerW, ui.headerH)
        self:drawTexture("phone_content_panel", ui.innerX, ui.contentY, ui.innerW, ui.contentH)
        self:drawTexture("phone_footer_panel", ui.innerX, ui.footerY, ui.innerW, ui.footerH)
        self:drawIconSquare("phone_32", ui.innerX + ui.pad, ui.headerY + 0.018, 0.035)
    end

    -- Шапка: обе надписи строго по центру панели.
    self:drawCenteredText(getText("FSP_UI_TITLE"),
        ui.innerX, ui.headerY + 0.036, ui.innerW, 0.036, 0.021, 0.72, 0.95, 0.29, 1)
    self:drawCenteredText(getText("FSP_UI_SUBTITLE"),
        ui.innerX, ui.headerY + 0.004, ui.innerW, 0.03, 0.013, 0.62, 0.62, 0.62, 1)

    -- Заголовок списка поставщиков — по центру панели.
    self:drawCenteredText(getText("FSP_UI_SHOPS"),
        ui.innerX, ui.listTop + 0.002, ui.innerW, 0.026, 0.016, 0.72, 0.95, 0.29, 1)

    local firstIndex = self.storeScrollOffset
    local lastIndex = math.min(#self.stores, firstIndex + ui.rows - 1)
    local y = ui.listTop

    if #self.stores == 0 then
        setTextColor(0.94, 0.73, 0.29, 1)
        renderText(ui.listX + 0.012, y - 0.022, 0.015, getText("FSP_NO_STORES"))
        setTextColor(1, 1, 1, 1)
    else
        for i = firstIndex, lastIndex do
            local rowY = y - (i - firstIndex + 1) * ui.rowH
            local selected = i == self.selectedStore
            -- Прямоугольная подложка без скруглений: не растягиваем спрайт.
            drawFilledRect(ui.listX, rowY, ui.listContentW, ui.rowH - 0.003,
                selected and 0.17 or 0.13, selected and 0.22 or 0.16,
                selected and 0.13 or 0.17, 1)
            if selected then
                drawFilledRect(ui.listX, rowY, 0.004, ui.rowH - 0.003, 0.72, 0.95, 0.29, 1)
            end

            local iconName = storeIconName(self.stores[i].kind)
            local iconSize = 0.022
            if textured then
                self:drawIconSquare(iconName, ui.listX + 0.008,
                    rowY + (ui.rowH - iconSize) * 0.5, iconSize)
            end
            local textX = ui.listX + 0.036

            setTextColor(1, 1, 1, 1)
            local name = limitUtf8(self.stores[i].name, 28)
            renderText(textX, rowY + 0.021, 0.015, name)
            setTextColor(1, 1, 1, 1)
        end

        -- Вертикальный ползунок: показывается, если список не помещается.
        if #self.stores > ui.rows then
            local trackW = ui.scrollW
            local trackX = ui.listX + ui.listW - trackW - 0.003
            local trackH = ui.rows * ui.rowH
            local trackY = ui.listTop - trackH
            drawFilledRect(trackX, trackY, trackW, trackH, 0.16, 0.19, 0.20, 1)
            local thumbH = math.max(0.03, trackH * ui.rows / #self.stores)
            local progress = (self.storeScrollOffset - 1) / math.max(1, #self.stores - ui.rows)
            local thumbY = trackY + (trackH - thumbH) * (1.0 - progress)
            drawFilledRect(trackX, thumbY, trackW, thumbH, 0.72, 0.95, 0.29, 1)
        end
    end

    -- Заголовок способа получения — по центру, над карточками.
    self:drawCenteredText(getText("FSP_UI_FULFILLMENT"),
        ui.innerX, ui.fulfillmentY + ui.cardH + 0.008, ui.innerW, 0.026, 0.016,
        0.72, 0.95, 0.29, 1)

    local pickupSelected = self.fulfillment == "pickup"
    local deliverySelected = self.fulfillment == "delivery"

    -- Две одинаковые карточки в одну строку с симметричным зазором.
    drawFilledRect(ui.cardX, ui.fulfillmentY, ui.cardW, ui.cardH,
        pickupSelected and 0.17 or 0.13, pickupSelected and 0.22 or 0.16,
        pickupSelected and 0.13 or 0.17, 1)
    drawFilledRect(ui.deliveryX, ui.fulfillmentY, ui.cardW, ui.cardH,
        deliverySelected and 0.17 or 0.13, deliverySelected and 0.22 or 0.16,
        deliverySelected and 0.13 or 0.17, 1)
    if pickupSelected then
        drawFilledRect(ui.cardX, ui.fulfillmentY, 0.004, ui.cardH, 0.72, 0.95, 0.29, 1)
    end
    if deliverySelected then
        drawFilledRect(ui.deliveryX, ui.fulfillmentY, 0.004, ui.cardH, 0.72, 0.95, 0.29, 1)
    end

    if textured then
        self:drawIconSquare("store_lime", ui.cardX + 0.006, ui.fulfillmentY + 0.014, 0.022)
        self:drawIconSquare("truck_lime", ui.deliveryX + 0.006, ui.fulfillmentY + 0.014, 0.022)
        if pickupSelected then
            self:drawIconSquare("check_lime", ui.cardX + ui.cardW - 0.028,
                ui.fulfillmentY + 0.015, 0.02)
        end
        if deliverySelected then
            self:drawIconSquare("check_lime", ui.deliveryX + ui.cardW - 0.028,
                ui.fulfillmentY + 0.015, 0.02)
        end
    end

    local cardIconSize = 0.022
    local cardIconW = cardIconSize / (g_screenAspectRatio or (16.0 / 9.0))
    local textX = ui.cardX + 0.006 + cardIconW + 0.008
    local deliveryTextX = ui.deliveryX + 0.006 + cardIconW + 0.008
    local textY = ui.fulfillmentY + ui.cardH * 0.5 + 0.011 * 0.15

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)

    if pickupSelected then
        setTextColor(0.72, 0.95, 0.29, 1)
    else
        setTextColor(1, 1, 1, 1)
    end
    renderText(textX, textY, 0.011, getText("FSP_UI_PICKUP_TINY"))

    if deliverySelected then
        setTextColor(0.72, 0.95, 0.29, 1)
    else
        setTextColor(1, 1, 1, 1)
    end
    renderText(deliveryTextX, textY, 0.011, getText("FSP_UI_DELIVERY_TINY"))

    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextColor(1, 1, 1, 1)

    -- Главная кнопка.
    -- Кнопка вызова: широкая зелёная плашка с тёмной трубкой по центру.
    if textured then
        self:drawTexture("call_button_wide",
            ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH)
    else
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 0.72, 0.95, 0.29, 1)
    end

    -- Нижняя подсказка.
    self:drawCenteredText(getText("FSP_UI_HINT_1"),
        ui.innerX, ui.footerY + 0.062, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(getText("FSP_UI_HINT_2"),
        ui.innerX, ui.footerY + 0.038, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(getText("FSP_UI_HINT_3"),
        ui.innerX, ui.footerY + 0.014, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(getText("FSP_UI_FEE"),
        ui.innerX, ui.contentY + 0.004, ui.innerW, 0.02, 0.01, 0.94, 0.73, 0.29, 1)
end

function FarmShopPhone:saveSpawnPlace(place)
    return {
        startX = place.startX, startY = place.startY, startZ = place.startZ,
        rotX = place.rotX, rotY = place.rotY, rotZ = place.rotZ,
        dirX = place.dirX, dirY = place.dirY, dirZ = place.dirZ,
        dirPerpX = place.dirPerpX, dirPerpY = place.dirPerpY, dirPerpZ = place.dirPerpZ,
        teleportX = place.teleportX, teleportY = place.teleportY, teleportZ = place.teleportZ
    }
end

function FarmShopPhone:restoreSpawnPlace(place, backup)
    place.startX, place.startY, place.startZ = backup.startX, backup.startY, backup.startZ
    place.rotX, place.rotY, place.rotZ = backup.rotX, backup.rotY, backup.rotZ
    place.dirX, place.dirY, place.dirZ = backup.dirX, backup.dirY, backup.dirZ
    place.dirPerpX, place.dirPerpY, place.dirPerpZ = backup.dirPerpX, backup.dirPerpY, backup.dirPerpZ
    place.teleportX, place.teleportY, place.teleportZ = backup.teleportX, backup.teleportY, backup.teleportZ
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

    local playerPos = getPlayerPosition()
    if playerPos ~= nil then
        place.teleportX, place.teleportY, place.teleportZ = playerPos[1], playerPos[2], playerPos[3]
    end

    self.deliveryApplied = true
    print(string.format("[FarmShopPhone] Delivery point applied: X=%.1f Z=%.1f", target[1], target[3]))
    return true
end

--- Возвращает исходное место появления покупок.
function FarmShopPhone:restoreSpawnPlaceToOriginal()
    if not self.deliveryApplied then
        return
    end

    local place = g_currentMission ~= nil and g_currentMission.storeSpawnPlaces ~= nil and g_currentMission.storeSpawnPlaces[1] or nil
    if place ~= nil and self.originalSpawnPlace ~= nil then
        self:restoreSpawnPlace(place, self.originalSpawnPlace)
    end

    self.deliveryApplied = false
    print("[FarmShopPhone] Delivery point restored to the store spawn place.")
end

--- Переносит места спавна паллет паллетной станции в точку доставки.
-- Паллетные магазины спавнят товар через собственный PalletSpawner станции,
-- а не через общий storeSpawnPlaces, поэтому подменяются именно его места.
function FarmShopPhone:applyPalletSpawnPlaces(placeable, target)
    if placeable == nil or target == nil then
        return false
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
            startX = place.startX, startY = place.startY, startZ = place.startZ,
            rotX = place.rotX, rotY = place.rotY, rotZ = place.rotZ,
            dirX = place.dirX, dirY = place.dirY, dirZ = place.dirZ,
            dirPerpX = place.dirPerpX, dirPerpY = place.dirPerpY, dirPerpZ = place.dirPerpZ
        })
    end

    for _, place in ipairs(places) do
        place.startX, place.startY, place.startZ = target[1], target[2], target[3]
        if target.rotX ~= nil then
            place.rotX, place.rotY, place.rotZ = target.rotX, target.rotY, target.rotZ
            place.dirX, place.dirY, place.dirZ = target.dirX, target.dirY, target.dirZ
            place.dirPerpX, place.dirPerpY, place.dirPerpZ =
                target.dirPerpX, target.dirPerpY, target.dirPerpZ
        end
    end

    self.palletDeliveryApplied = true
    print(string.format("[FarmShopPhone] Pallet delivery point applied: X=%.1f Z=%.1f", target[1], target[3]))
    return true
end

--- Возвращает места спавна паллет станции.
function FarmShopPhone:restorePalletSpawnPlaces()
    if not self.palletDeliveryApplied or self.palletSpawnBackup == nil then
        return
    end

    for _, entry in ipairs(self.palletSpawnBackup.places) do
        local place = entry.place
        place.startX, place.startY, place.startZ = entry.startX, entry.startY, entry.startZ
        place.rotX, place.rotY, place.rotZ = entry.rotX, entry.rotY, entry.rotZ
        place.dirX, place.dirY, place.dirZ = entry.dirX, entry.dirY, entry.dirZ
        place.dirPerpX, place.dirPerpY, place.dirPerpZ = entry.dirPerpX, entry.dirPerpY, entry.dirPerpZ
    end

    self.palletDeliveryApplied = false
    self.palletSpawnBackup = nil
    print("[FarmShopPhone] Pallet delivery point restored.")
end

--- Откладывает возврат мест спавна паллет, чтобы асинхронный спавн
-- (placementManager.getPlaceAsync) успел получить точку доставки.
function FarmShopPhone:schedulePalletRestore(delay)
    if not self.palletDeliveryApplied then
        return
    end

    self.palletRestoreTimer = (delay ~= nil and delay or 1.5) * 1000.0
    if g_currentMission ~= nil then
        g_currentMission:addUpdateable(self)
    end
end

--- Устанавливает перехват статистики финансов для начисления платы за доставку.
function FarmShopPhone:installFinanceHook()
    if self.financeHookInstalled or FarmStats == nil or FarmStats.changeFinanceStats == nil then
        if not self.financeHookInstalled then
            print("[FarmShopPhone] WARNING: FarmStats.changeFinanceStats is unavailable; delivery fee is disabled.")
        end
        return
    end

    self.financeHookInstalled = true

    -- Соглашение вызова changeFinanceStats различается (метод с self или статическая
    -- функция), поэтому аргументы разбираем устойчиво по их типам.
    FarmStats.changeFinanceStats = Utils.appendedFunction(FarmStats.changeFinanceStats, function(...)
        local args = {...}
        local amount, statType
        if type(args[1]) == "number" then
            amount, statType = args[1], args[2]
        else
            amount, statType = args[2], args[3]
        end
        FarmShopPhone:handleFinanceStats(amount, statType)
    end)

    print("[FarmShopPhone] Finance hook installed (delivery fee).")
end

--- Начисляет плату за доставку (2.5% от стоимости покупки) во время покупок в каталоге.
function FarmShopPhone:handleFinanceStats(amount, statType)
    -- Доставка может быть активна через общую точку спавна или через
    -- palletSpawner выбранной паллетной станции.
    if not (FarmShopPhone.deliveryApplied or FarmShopPhone.palletDeliveryApplied) then
        return
    end
    if g_gui == nil or not g_gui:getIsGuiVisible() then
        return
    end
    if amount == nil or amount >= 0 or (-amount) <= 25.0 then
        return
    end

    local itemPurchase = false
    if statType ~= nil then
        for _, statName in ipairs({"other", "purchaseSeeds", "purchaseFertilizer",
                                   "purchaseSaplings", "purchasePallets"}) do
            if statName == statType then
                itemPurchase = true
                break
            end
        end

        -- Животные не относятся к доставке магазинных товаров.
        if itemPurchase and statType == "other" and FocusManager.currentGui ~= nil
                and string.upper(tostring(FocusManager.currentGui)) == "ANIMALSCREEN" then
            itemPurchase = false
        end
    end

    if statType == "newVehiclesCost" or statType == "vehicleLeasingCost"
            or statType == "purchasePallets" or itemPurchase then
        local charge = (-amount) * FarmShopPhone.deliveryRate
        if charge > FarmShopPhone.deliveryMaxCharge then
            charge = FarmShopPhone.deliveryMaxCharge
        end
        FarmShopPhone.deliveryTotalCharges = FarmShopPhone.deliveryTotalCharges + charge
        FarmShopPhone.deliveryFarmId = g_currentMission:getFarmId()
        print(string.format("[FarmShopPhone] Delivery fee +%.2f (pending %.2f)", charge, FarmShopPhone.deliveryTotalCharges))
    end
end

--- Списывает накопленную плату за доставку (вызывается при закрытии каталога).
function FarmShopPhone:chargeDeliveryFee()
    if FarmShopPhone.deliveryValidationFailed then
        FarmShopPhone.deliveryTotalCharges = 0
        FarmShopPhone.deliveryFarmId = nil
        FarmShopPhone:logValidation("delivery failed: fee not charged")
        FarmShopPhone:notifyDeliveryError("FSP_DELIVERY_FAILED")
        FarmShopPhone.deliveryValidationFailed = false
        return
    end

    if FarmShopPhone.deliveryTotalCharges < 0.01 then
        FarmShopPhone.deliveryTotalCharges = 0
        FarmShopPhone.deliveryFarmId = nil
        return
    end

    local fee = math.floor(FarmShopPhone.deliveryTotalCharges + 0.5)
    local farmId = FarmShopPhone.deliveryFarmId or (g_currentMission ~= nil and g_currentMission:getFarmId() or nil)

    if g_currentMission ~= nil and farmId ~= nil then
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end

    local text = string.format("%s: -%s", getText("FSP_DELIVERY_FEE"), g_i18n:formatMoney(fee, 0, false, true))
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text, nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end

    print(string.format("[FarmShopPhone] Delivery fee charged: %d", fee))
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
end

function FarmShopPhone:update(dt)
    -- Обработка клавиши O (открыть/закрыть телефон) через edge detection.
    -- Не используем перехват PlayerInputComponent, чтобы не конфликтовать с движением игрока и мышью.
    local oPressed = Input.isKeyPressed(Input.KEY_o)
    local oKey = tostring(Input.KEY_o)
    local oWasPressed = self.keyStates[oKey]
    self.keyStates[oKey] = oPressed
    if oPressed and not oWasPressed then
        self:openPhone()
    end

    if self.phoneOpen then
        -- Жёсткая заморозка: возвращаем персонажа в сохранённую позицию каждый кадр
        self:applyFrozenPosition()
        self:updatePhoneInput()
    end

    if self.orderActive and g_gui ~= nil then
        if g_gui:getIsGuiVisible() then
            self.shopWasVisible = true
        elseif self.shopWasVisible then
            self.orderActive = false
            self.shopWasVisible = false
            self.callPosition = nil
            -- Возвращаем места спавна и списываем плату за доставку
            self:restoreSpawnPlaceToOriginal()
            self:schedulePalletRestore(1.5)
            self:chargeDeliveryFee()

            -- Разблокируем движение после закрытия каталога
            if g_localPlayer ~= nil then
                g_localPlayer.isControlEnabled = true
            end
        end
    end

    -- Отложенный возврат мест спавна паллет после асинхронного размещения.
    if self.palletRestoreTimer > 0 then
        self.palletRestoreTimer = self.palletRestoreTimer - dt
        if self.palletRestoreTimer <= 0 then
            self.palletRestoreTimer = 0
            self:restorePalletSpawnPlaces()
        end
    end
end

function FarmShopPhone:draw()
    self:drawPhone()
end

addModEventListener(FarmShopPhone)

