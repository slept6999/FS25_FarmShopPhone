-------------------------------------------------------------------------------
-- FarmShopPhone — фермерский телефон для FS25 (Farm Shop Phone for FS25)
--
-- Version: 0.2.6.2
--
-- Назначение: через телефонный оверлей звонить на торговые точки карты,
-- открывать стандартный каталог магазина, выбирать самовывоз или разовую
-- доставку и получать покупку в выбранном месте.
--
-- Архитектура:
--   1. discoverStores()   — многоступенчатое обнаружение торговых точек:
--      placeableSystem.placeables, mapHotspots типа SHOP и ShopTrigger.
--      Дедупликация по ссылке на объект, а не по названию/координатам. Точки
--      приёма сыпучих товаров, животные и собственные мастерские
--      отфильтровываются по специализациям.
--   2. drawPhone()        — отрисовывает оверлей со списком поставщиков, способом
--      получения и кнопкой вызова; состояния normal/hover/pressed/selected/
--      disabled/focused.
--   3. openShop()         — открывает штатный интерфейс выбранной точки
--      (VehicleShopDialog, паллетный магазин, WorkshopScreen) либо стандартный
--      ShopMenu для торговых точек-триггеров (ShopTrigger). Общего fallback
--      на чужой ShopMenu нет: если точку открыть не удалось, заказ отменяется.
--   4. Машина состояний заказа (ORDER_STATE): переходы только по подтверждённым
--      событиям; факт покупки фиксируется реальным созданием объекта
--      (VehicleLoadingData/PlaceableLoadingData), а не закрытием каталога.
--      Финансовые события используются только для расчёта платы за доставку.
--   5. Доставка            — по образцу Store Deliveries: места спавна временно
--      переносятся в безопасную точку рядом с игроком (централизованный
--      beginSpawnOverride/apply/restore). Заказ завершается успехом только после
--      завершения ВСЕХ его загрузок; плата 2.5% списывается при успешном
--      завершении, а при выгрузке карты — сохраняется как долг.
--
-- Ограничения: каталог остаётся общим (ассортимент не фильтруется по точке);
-- размещение подтверждается реальным созданием объекта через хуки
-- VehicleLoadingData/PlaceableLoadingData/PalletSpawner; только одиночная игра.
-------------------------------------------------------------------------------

FarmShopPhone = {}


-- Машина состояний заказа (ТЗ §5). Переходы только по подтверждённым событиям.
FarmShopPhone.ORDER_STATE = {
    IDLE                = "IDLE",
    SHOP_SELECTED       = "SHOP_SELECTED",
    FULFILLMENT_SELECTED= "FULFILLMENT_SELECTED",
    SHOP_OPENING        = "SHOP_OPENING",
    SHOP_OPEN           = "SHOP_OPEN",
    PURCHASE_PENDING    = "PURCHASE_PENDING",
    PURCHASE_CONFIRMED  = "PURCHASE_CONFIRMED",
    DELIVERY_PENDING    = "DELIVERY_PENDING",
    DELIVERY_COMPLETED  = "DELIVERY_COMPLETED",
    DELIVERY_FAILED     = "DELIVERY_FAILED",
    CANCELLED           = "CANCELLED",
    COMPLETED           = "COMPLETED"
}
FarmShopPhone.orderState = FarmShopPhone.ORDER_STATE.IDLE
-- Уникальный идентификатор операции: связывает события создания объектов с заказом.
FarmShopPhone.orderToken = 0

-- Конфигурация поведения.
FarmShopPhone.SETTLE_TIMEOUT_MS = 4000     -- окно ожидания реального создания объекта после закрытия каталога
FarmShopPhone.RESTORE_DEBOUNCE_MS = 2000   -- пауза после последнего созданного объекта перед возвратом мест спавна

-- Признаки покупки и доставки (единый источник истины — только здесь).
FarmShopPhone.purchaseConfirmed = false
FarmShopPhone.pendingDelivery = false
FarmShopPhone.deliveryTotalCharges = 0
FarmShopPhone.deliveryFarmId = nil
FarmShopPhone.deliveryRate = 0.025
FarmShopPhone.deliveryMaxCharge = 5000
FarmShopPhone.financeHookInstalled = false
FarmShopPhone.purchaseHooksInstalled = false

-- Константы для проверки безопасности доставки (все пороги — в одном месте).
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


-- Имя мода, под которым загружен скрипт (необходимо для g_currentModName).
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

-- Выбранное автоматически безопасное место доставки.
FarmShopPhone.deliveryTarget = nil

-- Флаг того, что каталог магазина открыт и заказ ожидает завершения.
FarmShopPhone.orderActive = false
FarmShopPhone.shopWasVisible = false
FarmShopPhone.orderSettled = true       -- заказ полностью разрешён (успех/отмена/ошибка)
FarmShopPhone.settleTimer = 0           -- окно ожидания реального создания объекта после закрытия каталога
FarmShopPhone.restoreTimer = 0          -- отложенный возврат мест спавна после появления объектов
FarmShopPhone.evidenceObjects = 0       -- сколько объектов создано в рамках заказа
FarmShopPhone.evidenceSpent = 0         -- сумма списаний в рамках заказа (для платы за доставку)
FarmShopPhone.pendingLoads = {}         -- loading data, запущенные внутри заказа (токен -> заказ)
FarmShopPhone.pendingLoadCount = 0      -- сколько таких загрузок ещё не завершилось
FarmShopPhone.pendingWaitTimer = 0
FarmShopPhone.chargeVerifyPending = nil -- отложенная проверка списания (асинхронный баланс)      -- страховочный таймаут ожидания загрузок перед завершением заказа
FarmShopPhone.patchedSpawners = {}      -- palletSpawner'ы, чьи места подменял мод
FarmShopPhone.deliveryFailure = nil     -- причина неудачи размещения ("no_space", ...)
FarmShopPhone.deliveryPartial = false   -- часть товара не удалось разместить
FarmShopPhone.lastRestoreConflict = false

-- Непогашенная плата (если списание не удалось): сохраняется до следующей попытки.
FarmShopPhone.unpaidFee = 0
FarmShopPhone.unpaidFeeFarmId = nil

-- Плата за телефонный звонок (открытие магазина через телефон).
FarmShopPhone.CALL_FEE = 10

-- История нажатий клавиш для определения одиночных нажатий ( edge detection ).
FarmShopPhone.keyStates = {}

-- Состояния интерактивных элементов (ТЗ §3, §4).
FarmShopPhone.focusIndex = 0     -- индекс элемента в фокусе (0 — фокуса нет)
FarmShopPhone.hoverId = nil      -- элемент под курсором
FarmShopPhone.pressedId = nil    -- элемент, который сейчас нажат мышью

-- Состояние блокировки ввода игрока, пока открыт телефон.
FarmShopPhone.lockedInput = nil
FarmShopPhone.previousCursorVisibility = nil

-- Стандартные торговые точки-триггеры карты (ShopTrigger).
FarmShopPhone.shopTriggers = {}

-- Доставка: исходное место спавна покупок и плата за доставку.
FarmShopPhone.originalSpawnPlace = nil
FarmShopPhone.appliedSpawnSnapshot = nil   -- значения, которые мод выставил (для проверки конфликтов)
FarmShopPhone.deliveryApplied = false

-- Места спавна паллет станции (подмена для паллетных магазинов).
FarmShopPhone.palletSpawnBackup = nil
FarmShopPhone.palletDeliveryApplied = false

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
    self:installPurchaseHooks()
    self:discoverStores()
    FarmShopPhone.orderState = FarmShopPhone.ORDER_STATE.IDLE
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

    -- Возвращаем места спавна и безопасно завершаем незавершённый заказ.
    -- Выгрузка карты сама по себе НЕ инициирует списание комиссии.
    self.restoreTimer = 0
    self.pendingWaitTimer = 0
    self:restoreSpawnPlaces()
    if FarmShopPhone.purchaseConfirmed and self.fulfillment == "delivery" and self.deliveryFailure == nil then
    -- Заказ фактически успешен, но списывать при выгрузке нельзя: сохраняем долг,
    -- он будет погашен при следующем успешном заказе (chargeUnpaidFee).
        local total = self.evidenceSpent or 0
        local fee = self:computeDeliveryFee(total)
        if fee > 0 then
            FarmShopPhone.unpaidFee = (FarmShopPhone.unpaidFee or 0) + fee
            print("[FarmShopPhone][Delivery] Комиссия не списана при выгрузке; сохранена как долг: " .. fee)
        end
    end
    self:resetOrderContext()

    -- Разблокируем движение при выгрузке карты
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
    self:unlockPlayerInput()
end

--- Определяет, можно ли открыть оригинальный интерфейс торговой точки.
-- Возвращает режим открытия ("vehicle", "pallet", "workshop", "generic", "openShop")
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

    local workshop = placeable.spec_workshop
    if workshop ~= nil and workshop.sellingPoint ~= nil and workshop.sellingPoint.ownWorkshop == false then
        return "workshop"
    end

    -- Пользовательские торговые объекты: базовая станция покупки или собственный openShop.
    if placeable.spec_buyingStation ~= nil or placeable.getBuyingStation ~= nil then
        return "generic"
    end
    if placeable.openShop ~= nil then
        return "openShop"
    end

    return nil
end

--- Категория точки для иконки и подписи.
local function storeKindFromMode(mode)
    if mode == "pallet" then
        return "palletBuying"
    elseif mode == "vehicle" or mode == "workshop" then
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
        name = getText("FSP_STORE_UNKNOWN")
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
    -- интерфейсом покупки (activatable/sellingPoint/openShop).
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
                    name = placeable.name or getText("FSP_STORE_UNKNOWN")
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
                local name = nearestHotspotName(x, z, 8.0)
                if name == nil then
                    print("[FarmShopPhone][ShopDiscovery] Skipped trigger (нет названия среди маркеров карты)")
                else
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
                end
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
        elseif store.triggerNode ~= nil then
            if store.triggerNode.isDeleted ~= nil and store.triggerNode.isDeleted then
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


function FarmShopPhone:openPhone()
    if g_currentMission == nil or g_gui == nil then
        return
    end

    if g_guidedTourManager ~= nil and g_guidedTourManager:getIsTourRunning() then
        return
    end

    -- Нельзя открывать телефон поверх активного каталога магазина: это отменило бы
    -- подмену мест спавна и нарушило бы заказ (ТЗ §4, §6).
    if self.orderActive and g_gui:getIsGuiVisible() then
        print("[FarmShopPhone][UI] Phone cannot be reopened while the shop catalog is open.")
        return
    end

    if self.phoneOpen then
        self.phoneOpen = false
        -- Разблокируем движение при закрытии телефона
        if g_localPlayer ~= nil then
            g_localPlayer.isControlEnabled = true
        end
        self:unlockPlayerInput()
        return
    end

    -- Каждый раз при открытии телефона сбрасываем способ получения на "Самовывоз".
    self.fulfillment = "pickup"
    self.storeScrollOffset = 1

    -- Новый заказ: отменяем следы предыдущей операции и проверяем актуальность списка.
    if self:isSpawnOverrideActive() then
        self:restoreSpawnPlaces()
    end
    self:resetOrderContext()

    self:discoverStores()
    self.selectedStore = math.min(math.max(self.selectedStore, 1), math.max(#self.stores, 1))
    self.phoneOpen = true

    -- Фокус по умолчанию — на первой строке списка (без перескакивания к кнопке вызова).
    self.focusIndex = 0
    if #self.stores > 0 then
        if not self:focusById("store_" .. self.selectedStore) then
            self:stepFocus(1)
        end
    end

    -- Блокируем движение персонажа при открытом телефоне.
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = false
    end

    -- Блокируем управление персонажем и включаем курсор, чтобы окном можно было пользоваться мышью
    self:lockPlayerInput()
end

--- Закрывает телефон (оверлей). Не трогает активный заказ: подмена мест спавна
-- снимается только при отмене/завершении заказа или выгрузке миссии (ТЗ §6).
function FarmShopPhone:closePhone()
    self.phoneOpen = false
    -- Разблокируем движение при закрытии телефона
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
    -- Снимаем блокировку ввода
    self:unlockPlayerInput()
end

--- Принудительно отменяет текущий заказ: возврат мест спавна, очистка контекста.
function FarmShopPhone:abortOrder(reason)
    print("[FarmShopPhone][Order] Order cancelled: " .. tostring(reason))
    self:restoreSpawnPlaces()
    self:resetOrderContext()
    FarmShopPhone.orderState = FarmShopPhone.ORDER_STATE.CANCELLED
end

--- Устанавливает состояние заказа и журналирует переход (ТЗ §5).
function FarmShopPhone:setOrderState(state)
    if FarmShopPhone.orderState == state then
        return
    end
    print(string.format("[FarmShopPhone][Order] State: %s -> %s", FarmShopPhone.orderState, state))
    FarmShopPhone.orderState = state
end

-------------------------------------------------------------------------------
-- Централизованное управление временной подменой мест спавна (ТЗ §6)
-------------------------------------------------------------------------------

--- Начинает операцию подмены мест спавна. Исходное состояние сохраняется один раз.
function FarmShopPhone:beginSpawnOverride()
    self:captureOriginalSpawnPlace()
    print("[FarmShopPhone][SpawnRestore] Spawn override started.")
end

--- true, если подмена мест спавна сейчас активна.
function FarmShopPhone:isSpawnOverrideActive()
    return self.deliveryApplied or self.palletDeliveryApplied
end

--- Полный возврат мест спавна. Идемпотентно. Возвращает false, если хотя бы один
-- конфликт не позволил восстановить исходное состояние (не выдаём успех за факт).
function FarmShopPhone:restoreSpawnPlaces()
    local ok = true
    if not self:restoreSpawnPlaceToOriginal() then
        ok = false
    end
    if not self:restorePalletSpawnPlaces() then
        ok = false
    end

    if not ok or self.lastRestoreConflict then
        print("[FarmShopPhone][SpawnRestore] WARNING: не все места спавна восстановлены (конфликт с другой системой).")
        return false
    end

    if not self:isSpawnOverrideActive() then
        self.callPosition = nil
        self.deliveryTarget = nil
        self.deliverySize = nil
    end
    return true
end

--- Очищает временный контекст заказа (ссылки, флаги, блокировки).
-- Не трогает сведения о реально купленном товаре до завершения обработки доставки.
function FarmShopPhone:resetOrderContext()
    FarmShopPhone.orderState = FarmShopPhone.ORDER_STATE.IDLE
    FarmShopPhone.purchaseConfirmed = false
    FarmShopPhone.pendingDelivery = false
    self.orderActive = false
    self.shopWasVisible = false
    self.catalogOpenedByUs = false
    self.orderSettled = true
    self.settleTimer = 0
    self.restoreTimer = 0
    self.evidenceObjects = 0
    self.evidenceSpent = 0
    self.pendingLoads = {}
    self.pendingLoadCount = 0
    self.pendingWaitTimer = 0
    self.patchedSpawners = {}
    self.callFeeCharged = false
    self.deliveryFailure = nil
    self.deliveryPartial = false
    self.lastRestoreConflict = false
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
    self.callPosition = nil
    self.deliveryTarget = nil
    self.deliverySize = nil
    self.orderStoreName = nil
    FarmShopPhone.chargeVerifyPending = nil
end

--- Очищает временное состояние при выгрузке миссии.
function FarmShopPhone:cleanupDeliveryContext()
    self:restoreSpawnPlaces()
    self:resetOrderContext()
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
    self.phoneOpen = false
    print("[FarmShopPhone][SpawnRestore] Delivery context cleaned up on mission unload.")
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

--- Открывает штатный интерфейс выбранной торговой точки.
-- Способ открытия берётся из проверенного ранее openMode (см. getStoreOpenMode).
function FarmShopPhone:openStoreInterface(store)
    if store == nil then
        return false
    end

    local mode = store.openMode
    local placeable = store.placeable

    if mode == "trigger" then
        for _, trigger in ipairs(FarmShopPhone.shopTriggers) do
            if trigger ~= nil and (trigger == store.triggerObject
                    or trigger.shopPlayerSpawn == store.triggerNode
                    or trigger.rootNode == store.triggerNode) then
                if callMethodSafe(trigger, "openShop") then
                    return true
                end
            end
        end
        return false
    end

    if placeable == nil then
        return false
    end

    if mode == "vehicle" then
        local spec = placeable.spec_vehicleBuyingStation
        if spec ~= nil and spec.activatable ~= nil then
            return callMethodSafe(spec.activatable, "run")
        end
    elseif mode == "pallet" then
        local spec = placeable.spec_palletBuyingStation
        if spec ~= nil and spec.activatable ~= nil then
            return callMethodSafe(spec.activatable, "run")
        end
    elseif mode == "workshop" then
        local spec = placeable.spec_workshop
        if spec ~= nil and spec.sellingPoint ~= nil then
            if callMethodSafe(spec.sellingPoint, "openMenu") then
                return true
            end
            if spec.sellingPoint.activatable ~= nil then
                return callMethodSafe(spec.sellingPoint.activatable, "run")
            end
        end
    elseif mode == "generic" then
        -- Пользовательская торговая станция: базовый getBuyingStation/openShop.
        if placeable.getBuyingStation ~= nil then
            local ok, station = pcall(placeable.getBuyingStation, placeable)
            if ok and station ~= nil then
                if station.openMenu ~= nil and callMethodSafe(station, "openMenu") then
                    return true
                end
                if station.activatable ~= nil and callMethodSafe(station.activatable, "run") then
                    return true
                end
            end
        end
        if callMethodSafe(placeable, "openShop") then
            return true
        end
    elseif mode == "openShop" then
        if callMethodSafe(placeable, "openShop") then
            return true
        end
    end

    return false
end

function FarmShopPhone:openShop()
    if g_gui == nil then
        print("[FarmShopPhone][UI] GUI is not available.")
        return false
    end

    local store = self.stores[self.selectedStore]
    if store == nil or not store.canOpenInterface then
        print("[FarmShopPhone][Order] No usable store selected.")
        self:setOrderState(FarmShopPhone.ORDER_STATE.CANCELLED)
        return false
    end
    self.orderStoreName = store.name

    -- Новая операция: новый токен заказа; сбрасываем доказательства.
    FarmShopPhone.orderToken = FarmShopPhone.orderToken + 1
    FarmShopPhone.purchaseConfirmed = false
    FarmShopPhone.pendingDelivery = false
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
    self.shopWasVisible = false
    self.catalogOpenedByUs = false
    self.orderSettled = false
    self.settleTimer = 0
    self.restoreTimer = 0
    self.evidenceObjects = 0
    self.evidenceSpent = 0
    self.pendingLoads = {}
    self.pendingLoadCount = 0
    self.pendingWaitTimer = 0
    self.patchedSpawners = {}
    self.callFeeCharged = false
    self.deliveryFailure = nil
    self.deliveryPartial = false
    self.lastRestoreConflict = false
    self:setOrderState(FarmShopPhone.ORDER_STATE.SHOP_OPENING)

    -- Телефонный звонок: выбор продавца и открытие его магазина по кнопке «Позвонить».
    -- Плата списывается сразу при нажатии «Позвонить», до попытки открытия каталога.
    local feeOk, feeCharged, feeReason = pcall(FarmShopPhone.chargeCallFee, FarmShopPhone)
    if not feeOk or feeCharged == false then
        print("[FarmShopPhone][Order] Плата за звонок не списана: " .. tostring(feeOk and feeReason or feeCharged))
    end

    -- Если предыдущий заказ ещё не завершён, сначала возвращаем места спавна.
    if self:isSpawnOverrideActive() then
        self:restoreSpawnPlaces()
    end

    if self.fulfillment == "delivery" then
        -- Этап A: без безопасного места рядом с игроком каталог не открываем.
        if not self:prepareDeliveryTarget(store, FarmShopPhone.DELIVERY_SAFETY.defaultSize) then
            self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_FAILED)
            return false
        end

        self:beginSpawnOverride()

        local target = self.deliveryTarget
        local applied = false

        -- Паллетные магазины создают товар через собственный PalletSpawner.
        if store.kind == "palletBuying" and store.placeable ~= nil then
            local ok, result = pcall(function()
                return self:applyPalletSpawnPlaces(store.placeable, target)
            end)
            if not ok then
                print("[FarmShopPhone][Delivery] Pallet spawn patch failed: " .. tostring(result))
                self:restorePalletSpawnPlaces()
            else
                applied = result
            end
        end

        if not applied then
            local ok, result = pcall(function()
                return self:applyDeliverySpawnPlace(target)
            end)
            if not ok then
                print("[FarmShopPhone][Delivery] Store spawn patch failed: " .. tostring(result))
                self:restoreSpawnPlaceToOriginal()
            else
                applied = result
            end
        end

        if not applied then
            self:abortOrder("delivery spawn override failed")
            return false
        end
    else
        self:restoreSpawnPlaces()
    end

    -- При открытии каталога закрываем телефон, чтобы не блокировать ввод.
    self:closePhone()

    local opened = false
    local okOpen, resOpen = pcall(function()
        return self:openStoreInterface(store)
    end)
    if okOpen then
        opened = resOpen
    else
        print("[FarmShopPhone][UI] Store interface error: " .. tostring(resOpen))
    end

    if not opened then
        -- Резервного перехода на общий ShopMenu нет: иначе игрок может купить
        -- в чужой торговой точке вместо выбранной. Отменяем подготовку заказа.
        print(string.format("[FarmShopPhone][UI] Store interface could not be opened: name=%s kind=%s mode=%s placeable=%s trigger=%s",
            tostring(store.name), tostring(store.kind), tostring(store.openMode),
            store.placeable ~= nil and "yes" or "no", store.triggerObject ~= nil and "yes" or "no"))
        -- Звонок не удался: возвращаем плату за вызов, чтобы игрок не платил за неработающую точку.
        self:refundCallFee()
        self:notifyOrderResult("delivery", getText("FSP_STORE_OPEN_FAILED"))
        self:abortOrder("shop_interface_unavailable")
        return false
    end

    self.catalogOpenedByUs = true
    self.orderActive = true
    if self.fulfillment == "delivery" then
        self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_PENDING)
    else
        self:setOrderState(FarmShopPhone.ORDER_STATE.SHOP_OPEN)
    end
    return true
end

function FarmShopPhone:handleKey(keyCode, callback)
    if keyCode == nil then
        return
    end
    local pressed = Input.isKeyPressed(keyCode)
    local key = tostring(keyCode)
    local wasPressed = self.keyStates[key]
    self.keyStates[key] = pressed
    if pressed and not wasPressed then
        callback(self)
    end
end

-------------------------------------------------------------------------------
-- Реестр интерактивных элементов и навигация (ТЗ §3, §4)
-------------------------------------------------------------------------------

--- Возвращает упорядоченный список интерактивных элементов текущего экрана.
-- Каждый элемент: { id, rect = {x,y,w,h}, enabled, action(self) }.
function FarmShopPhone:getInteractiveElements()
    local ui = FarmShopPhone.UI
    local elements = {}
    local hasStore = #self.stores > 0

    local firstIndex = self.storeScrollOffset
    local lastIndex = math.min(#self.stores, firstIndex + ui.rows - 1)
    for i = firstIndex, lastIndex do
        local rowY = ui.listTop - (i - firstIndex + 1) * ui.rowH
        -- Важно: копия индекса для замыкания, иначе все action могли бы
        -- захватывать одно и то же значение переменной циклом.
        local storeIndex = i
        table.insert(elements, {
            id = "store_" .. storeIndex,
            rect = {ui.listX, rowY, ui.listContentW, ui.rowH - 0.003},
            enabled = true,
            action = function(self)
                self.selectedStore = storeIndex
                self:setOrderState(FarmShopPhone.ORDER_STATE.SHOP_SELECTED)
            end
        })
    end

    table.insert(elements, {
        id = "pickup",
        rect = {ui.cardX, ui.fulfillmentY, ui.cardW, ui.cardH},
        enabled = hasStore,
        action = function(self)
            self.fulfillment = "pickup"
            self:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
        end
    })

    table.insert(elements, {
        id = "delivery",
        rect = {ui.deliveryX, ui.fulfillmentY, ui.cardW, ui.cardH},
        enabled = hasStore,
        action = function(self)
            self.fulfillment = "delivery"
            self:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
            self:prepareDeliveryTarget(self.stores[self.selectedStore],
                FarmShopPhone.DELIVERY_SAFETY.defaultSize)
        end
    })

    table.insert(elements, {
        id = "call",
        rect = {ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH},
        enabled = hasStore,
        action = function(self)
            self:openShop()
        end
    })

    return elements
end

--- Переводит фокус на элемент по id (если он доступен).
function FarmShopPhone:focusById(id)
    local elements = self:getInteractiveElements()
    for index, element in ipairs(elements) do
        if element.id == id and element.enabled then
            self.focusIndex = index
            return true
        end
    end
    return false
end

--- Переводит фокус на следующий логичный шаг после активации элемента.
-- Не перескакиваем к кнопке вызова, пока не выбраны магазин и способ получения.
function FarmShopPhone:afterElementAction(id)
    if id:sub(1, 6) == "store_" then
        self:focusById("pickup")
    elseif id == "pickup" or id == "delivery" then
        self:focusById("call")
    end
end

--- Активирует элемент в фокусе. Возвращает true, если действие выполнено.
function FarmShopPhone:activateFocus()
    local elements = self:getInteractiveElements()
    local element = elements[self.focusIndex]
    if element == nil or not element.enabled then
        return false
    end

    element.action(self)
    self:afterElementAction(element.id)
    return true
end

--- Шаг фокуса вперёд/назад только по доступным элементам.
function FarmShopPhone:stepFocus(delta)
    local elements = self:getInteractiveElements()
    if #elements == 0 then
        self.focusIndex = 0
        return
    end

    local index = self.focusIndex
    for _ = 1, #elements do
        index = ((index - 1 + delta) % #elements) + 1
        if elements[index].enabled then
            self.focusIndex = index
            return
        end
    end
end

--- Находит элемент под курсором.
local function elementAt(elements, x, y)
    for index, element in ipairs(elements) do
        local r = element.rect
        if inRect(x, y, r[1], r[2], r[3], r[4]) then
            return index, element
        end
    end
    return nil, nil
end

function FarmShopPhone:updatePhoneInput()
    if not self.phoneOpen or g_gui == nil then
        return
    end

    -- Если открыт каталог магазина (ShopMenu), не обрабатываем ввод телефона:
    -- клавиши оригинального интерфейса не перехватываются (ТЗ §4).
    if self.orderActive and g_gui:getIsGuiVisible() then
        return
    end

    local ui = FarmShopPhone.UI
    local mouseX = g_inputBinding ~= nil and g_inputBinding.mousePosXLast or nil
    local mouseY = g_inputBinding ~= nil and g_inputBinding.mousePosYLast or nil
    local elements = self:getInteractiveElements()

    -- Hover: обновляется при перемещении мыши и не вызывает выбор элемента.
    self.hoverId = nil
    if mouseX ~= nil and mouseY ~= nil then
        local _, element = elementAt(elements, mouseX, mouseY)
        if element ~= nil and element.enabled then
            self.hoverId = element.id
        end
    end

    -- ESC: закрыть телефон (модальных окон у мода нет).
    self:handleKey(Input.KEY_esc, function(phone)
        phone:closePhone()
    end)

    -- BACKSPACE: вернуться назад — в одноэкранной схеме закрывает телефон.
    self:handleKey(Input.KEY_backspace, function(phone)
        phone:closePhone()
    end)

    -- TAB / SHIFT+TAB: перемещение фокуса по интерактивным элементам.
    self:handleKey(Input.KEY_tab, function(phone)
        local shift = false
        if Input.KEY_lshift ~= nil and Input.isKeyPressed(Input.KEY_lshift) then
            shift = true
        end
        if Input.KEY_rshift ~= nil and Input.isKeyPressed(Input.KEY_rshift) then
            shift = true
        end
        phone:stepFocus(shift and -1 or 1)
    end)

    -- ENTER: активирует только элемент в фокусе (без автоматического перескакивания).
    self:handleKey(Input.KEY_return, function(phone)
        if phone.focusIndex == 0 then
            phone:stepFocus(1)
        end
        phone:activateFocus()
    end)

    -- Мышь: нажатие лишь помечает элемент как pressed; действие выполняется
    -- по ОТПУСКАНИЮ, если курсор остался над тем же элементом.
    local mousePressed = Input.isMouseButtonPressed(Input.MOUSE_BUTTON_LEFT)
    local mouseWasPressed = self.keyStates["MOUSE_LEFT"]
    self.keyStates["MOUSE_LEFT"] = mousePressed

    if mousePressed and not mouseWasPressed and mouseX ~= nil and mouseY ~= nil then
        local index, element = elementAt(elements, mouseX, mouseY)
        if element ~= nil and element.enabled then
            self.pressedId = element.id
            self.focusIndex = index
        else
            self.pressedId = nil
        end
    elseif not mousePressed and mouseWasPressed then
        if self.pressedId ~= nil and self.hoverId == self.pressedId then
            local _, element = elementAt(elements, mouseX, mouseY)
            if element ~= nil and element.enabled then
                element.action(self)
                self:afterElementAction(element.id)
            end
        end
        self.pressedId = nil
    end

    -- Колесо мыши: прокрутка списка с реальными границами содержимого.
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
        self.focusIndex = 0
    elseif overList and wheelDown and not downWas then
        self.storeScrollOffset = math.min(maxOffset, self.storeScrollOffset + 1)
        self.focusIndex = 0
    end

    -- Стрелки вверх/вниз: выбор магазина; фокус уходит к способу получения.
    self:handleKey(Input.KEY_up, function(phone)
        if #phone.stores > 0 then
            phone.selectedStore = ((phone.selectedStore - 2) % #phone.stores) + 1
            phone:keepSelectionVisible()
            phone:setOrderState(FarmShopPhone.ORDER_STATE.SHOP_SELECTED)
            phone:afterElementAction("store_" .. phone.selectedStore)
        end
    end)
    self:handleKey(Input.KEY_down, function(phone)
        if #phone.stores > 0 then
            phone.selectedStore = (phone.selectedStore % #phone.stores) + 1
            phone:keepSelectionVisible()
            phone:setOrderState(FarmShopPhone.ORDER_STATE.SHOP_SELECTED)
            phone:afterElementAction("store_" .. phone.selectedStore)
        end
    end)

    -- A/D и стрелки влево/вправо: способ получения; фокус уходит к кнопке вызова.
    self:handleKey(Input.KEY_a, function(phone)
        phone.fulfillment = "pickup"
        phone:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
        phone:afterElementAction("pickup")
    end)
    self:handleKey(Input.KEY_d, function(phone)
        phone.fulfillment = "delivery"
        phone:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
        phone:prepareDeliveryTarget(phone.stores[phone.selectedStore],
            FarmShopPhone.DELIVERY_SAFETY.defaultSize)
        phone:afterElementAction("delivery")
    end)
    self:handleKey(Input.KEY_left, function(phone)
        phone.fulfillment = "pickup"
        phone:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
        phone:afterElementAction("pickup")
    end)
    self:handleKey(Input.KEY_right, function(phone)
        phone.fulfillment = "delivery"
        phone:setOrderState(FarmShopPhone.ORDER_STATE.FULFILLMENT_SELECTED)
        phone:prepareDeliveryTarget(phone.stores[phone.selectedStore],
            FarmShopPhone.DELIVERY_SAFETY.defaultSize)
        phone:afterElementAction("delivery")
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

--- Локализует причину, переданную как ключ FSP_*, либо возвращает текст как есть.
local function localizeReason(reason)
    if type(reason) == "string" and reason:sub(1, 4) == "FSP_" then
        return getText(reason)
    end
    return reason or ""
end

--- Показывает уведомление об ошибке доставки.
function FarmShopPhone:showDeliveryError(reason)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        local text = getText("FSP_DELIVERY_UNSAFE") .. " " .. localizeReason(reason)
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            text, nil, GuiSoundPlayer.SOUND_SAMPLES.ERROR)
    end
end

--- Показывает уведомление об успешном выборе/размещении доставки.
function FarmShopPhone:showDeliverySuccess(key)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        local text = getText(key)
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            text, nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
end

--- Показывает итоговое уведомление заказа (ТЗ §2, экран 5).
function FarmShopPhone:notifyOrderResult(kind, warningKey)
    if g_currentMission == nil or g_currentMission.hud == nil then
        return
    end

    local text
    if kind == "delivery" then
        text = getText("FSP_DELIVERY_DONE")
    else
        text = string.format(getText("FSP_ORDER_PICKUP_DONE"), self.orderStoreName or "")
    end

    if warningKey ~= nil then
        text = text .. " (" .. getText(warningKey) .. ")"
    end

    g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        text, nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
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

--- Иконка типа поставщика для строки списка.
local function storeIconName(kind)
    if kind == "palletBuying" then
        return "package_grey"
    elseif kind == "vehicleBuying" or kind == "vehicleSelling" then
        return "tractor_grey"
    end
    return "store_grey"
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
            local hovered = self.hoverId == "store_" .. i
            local focused = self.focusIndex == (i - firstIndex + 1)

            -- Состояния элемента: selected, pressed, hover, focused, normal.
            local r, g, b
            if selected then
                r, g, b = 0.17, 0.22, 0.13
            elseif self.pressedId == "store_" .. i then
                r, g, b = 0.20, 0.28, 0.12
            elseif hovered then
                r, g, b = 0.16, 0.20, 0.22
            else
                r, g, b = 0.13, 0.16, 0.17
            end

            -- Прямоугольная подложка без скруглений: не растягиваем спрайт.
            drawFilledRect(ui.listX, rowY, ui.listContentW, ui.rowH - 0.003, r, g, b, 1)
            if selected then
                drawFilledRect(ui.listX, rowY, 0.004, ui.rowH - 0.003, 0.72, 0.95, 0.29, 1)
            elseif focused then
                drawFilledRect(ui.listX + ui.listContentW - 0.004, rowY, 0.004, ui.rowH - 0.003,
                    0.72, 0.95, 0.29, 1)
            end

            local iconName = storeIconName(self.stores[i].kind)
            local iconSize = 0.022
            if textured then
                self:drawIconSquare(iconName, ui.listX + 0.008,
                    rowY + (ui.rowH - iconSize) * 0.5, iconSize)
            end
            local textX = ui.listX + 0.036

            if selected then
                setTextColor(0.72, 0.95, 0.29, 1)
            else
                setTextColor(1, 1, 1, 1)
            end
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
    local rowsShown = math.max(0, lastIndex - firstIndex + 1)
    local hasStore = #self.stores > 0
    local focusPickup = self.focusIndex == rowsShown + 1
    local focusDelivery = self.focusIndex == rowsShown + 2
    local focusCall = self.focusIndex == rowsShown + 3

    -- Две одинаковые карточки в одну строку с симметричным зазором.
    local function drawCard(x, selected, hovered, pressed, focused, enabled)
        local r, g, b
        if not enabled then
            r, g, b = 0.10, 0.11, 0.12
        elseif selected then
            r, g, b = 0.17, 0.22, 0.13
        elseif pressed then
            r, g, b = 0.20, 0.28, 0.12
        elseif hovered then
            r, g, b = 0.16, 0.20, 0.22
        else
            r, g, b = 0.13, 0.16, 0.17
        end
        drawFilledRect(x, ui.fulfillmentY, ui.cardW, ui.cardH, r, g, b, 1)

        if selected then
            drawFilledRect(x, ui.fulfillmentY, 0.004, ui.cardH, 0.72, 0.95, 0.29, 1)
        elseif focused and enabled then
            drawFilledRect(x + ui.cardW - 0.004, ui.fulfillmentY, 0.004, ui.cardH, 0.72, 0.95, 0.29, 1)
        end
    end

    drawCard(ui.cardX, pickupSelected, self.hoverId == "pickup",
        self.pressedId == "pickup", focusPickup, hasStore)
    drawCard(ui.deliveryX, deliverySelected, self.hoverId == "delivery",
        self.pressedId == "delivery", focusDelivery, hasStore)

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
    local callEnabled = hasStore
    local callHovered = self.hoverId == "call"
    local callPressed = self.pressedId == "call"

    if textured then
        self:drawTexture("call_button_wide",
            ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH)
    else
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH,
            callEnabled and 0.72 or 0.35, callEnabled and 0.95 or 0.40,
            callEnabled and 0.29 or 0.20, 1)
    end

    -- Состояния кнопки: disabled, pressed, hover, focused.
    if not callEnabled then
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 0.06, 0.07, 0.08, 0.55)
    elseif callPressed then
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 0.10, 0.12, 0.13, 0.35)
    elseif callHovered then
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 1, 1, 1, 0.10)
    end

    if focusCall and callEnabled then
        drawFilledRect(ui.buttonX + ui.buttonW - 0.005, ui.buttonY, 0.005, ui.buttonH,
            0.72, 0.95, 0.29, 1)
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
            self:showDeliverySuccess(getText("FSP_DELIVERY_FALLBACK"))
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

    local playerPos = getPlayerPosition()
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

-------------------------------------------------------------------------------
-- Подтверждение покупки реальным созданием объекта (ТЗ §5)
-------------------------------------------------------------------------------

--- Регистрирует операцию загрузки объекта, запущенную внутри текущего заказа.
function FarmShopPhone:registerPendingLoad(loadData)
    if loadData == nil then
        return
    end
    self.pendingLoads = self.pendingLoads or {}
    if self.pendingLoads[loadData] ~= FarmShopPhone.orderToken then
        self.pendingLoads[loadData] = FarmShopPhone.orderToken
        self.pendingLoadCount = (self.pendingLoadCount or 0) + 1
    end
end

--- Отмечает завершение операции загрузки; возвращает true, если это был груз заказа.
function FarmShopPhone:unregisterPendingLoad(loadData)
    if self.pendingLoads == nil or loadData == nil then
        return false
    end
    if self.pendingLoads[loadData] == FarmShopPhone.orderToken then
        self.pendingLoads[loadData] = nil
        self.pendingLoadCount = math.max(0, (self.pendingLoadCount or 0) - 1)
        return true
    end
    return false
end

--- Можно ли завершать заказ: каталог был открыт модом и уже закрыт.
function FarmShopPhone:canSettleOrder()
    if self.orderSettled or not self.orderActive then
        return false
    end
    if not self.catalogOpenedByUs then
        return false
    end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then
        return false
    end
    return true
end

--- Вызывается после завершения каждой зарегистрированной загрузки.
function FarmShopPhone:onPendingLoadFinished()
    -- Неудача размещения и все загрузки завершены: безопасно завершаем заказ ошибкой.
    if self.deliveryFailure ~= nil and self.orderActive and not self.orderSettled
            and (self.pendingLoadCount or 0) <= 0 then
        self:settleDeliveryFailure()
        return
    end

    -- Покупка подтверждена, загрузок больше нет: завершаем заказ,
    -- но только после закрытия каталога (чтобы уведомления не шли поверх него).
    if FarmShopPhone.purchaseConfirmed and self.orderActive and not self.orderSettled
            and (self.pendingLoadCount or 0) <= 0 and self.deliveryFailure == nil
            and self:canSettleOrder() then
        self:finalizeOrderSuccess()
    end
end

--- true, если загрузка была запущена именно в рамках текущего заказа.
--- Устанавливает хуки на классы загрузки FS25: покупка подтверждается только
-- при фактическом создании объекта (VehicleLoadingData/PlaceableLoadingData),
-- а не по финансовому событию.
function FarmShopPhone:installPurchaseHooks()
    if self.purchaseHooksInstalled then
        return
    end
    self.purchaseHooksInstalled = true

    -- Транспорт и паллеты (паллеты тоже загружаются через VehicleLoadingData).
    if VehicleLoadingData ~= nil and VehicleLoadingData.load ~= nil
            and VehicleLoadingState ~= nil and VehicleLoadingState.OK ~= nil then
        local originalLoad = VehicleLoadingData.load
        local vehicleOkState = VehicleLoadingState.OK
        VehicleLoadingData.load = function(self, callback, callbackTarget, callbackArguments)
            -- Связываем операцию загрузки с заказом, активным на момент её старта.
            local belongsToOrder = false
            local loadToken = FarmShopPhone.orderToken
            if FarmShopPhone.orderActive and not FarmShopPhone.orderSettled then
                FarmShopPhone:registerPendingLoad(self)
                belongsToOrder = true
            end

            local wrapped = function(cbTarget, objects, loadingState, cbArgs)
                if belongsToOrder and loadToken == FarmShopPhone.orderToken
                        and loadingState == vehicleOkState and objects ~= nil and #objects > 0 then
                    local ok = pcall(FarmShopPhone.onOrderObjectsCreated, FarmShopPhone, objects)
                    if not ok then
                        print("[FarmShopPhone][Purchase] ERROR in object-creation handler")
                    end
                end
                if callback ~= nil then
                    callback(cbTarget, objects, loadingState, cbArgs)
                end
                if belongsToOrder then
                    FarmShopPhone:unregisterPendingLoad(self)
                    FarmShopPhone:onPendingLoadFinished()
                end
            end
            return originalLoad(self, wrapped, callbackTarget, callbackArguments)
        end
        print("[FarmShopPhone][Purchase] Hook installed: VehicleLoadingData.load")
    end

    -- Объекты (строения и производства).
    if PlaceableLoadingData ~= nil and PlaceableLoadingData.load ~= nil
            and PlaceableLoadingState ~= nil and PlaceableLoadingState.OK ~= nil then
        local originalLoad = PlaceableLoadingData.load
        local placeableOkState = PlaceableLoadingState.OK
        PlaceableLoadingData.load = function(self, callback, callbackTarget, callbackArguments)
            local belongsToOrder = false
            local loadToken = FarmShopPhone.orderToken
            if FarmShopPhone.orderActive and not FarmShopPhone.orderSettled then
                FarmShopPhone:registerPendingLoad(self)
                belongsToOrder = true
            end

            local wrapped = function(cbTarget, result, loadingState, cbArgs)
                if belongsToOrder and loadToken == FarmShopPhone.orderToken then
                    -- Движок может передать один объект или таблицу — приводим к списку.
                    local list = {}
                    if type(result) == "table" then
                        for _, item in ipairs(result) do
                            table.insert(list, item)
                        end
                        if #list == 0 and next(result) ~= nil then
                            table.insert(list, result)
                        end
                    elseif result ~= nil then
                        table.insert(list, result)
                    end

                    local okState = (loadingState == nil) or (loadingState == placeableOkState)
                    if okState and #list > 0 then
                        local ok = pcall(FarmShopPhone.onOrderObjectsCreated, FarmShopPhone, list)
                        if not ok then
                            print("[FarmShopPhone][Purchase] ERROR in object-creation handler")
                        end
                    end
                end
                if callback ~= nil then
                    callback(cbTarget, result, loadingState, cbArgs)
                end
                if belongsToOrder then
                    FarmShopPhone:unregisterPendingLoad(self)
                    FarmShopPhone:onPendingLoadFinished()
                end
            end
            return originalLoad(self, wrapped, callbackTarget, callbackArguments)
        end
        print("[FarmShopPhone][Purchase] Hook installed: PlaceableLoadingData.load")
    end

    -- Паллеты: неудача поиска места (только для спавнеров, чьи места подменял мод).
    if PalletSpawner ~= nil and PalletSpawner.onSpawnSearchFinished ~= nil and Utils ~= nil then
        PalletSpawner.onSpawnSearchFinished = Utils.appendedFunction(PalletSpawner.onSpawnSearchFinished, function(self, location)
            if location == nil and FarmShopPhone.patchedSpawners[self]
                    and FarmShopPhone.orderActive and not FarmShopPhone.orderSettled
                    and FarmShopPhone.fulfillment == "delivery" then
                -- Ошибка относится к паллетному спавнеру, подменённому для текущего
                -- заказа доставки. Посторонние вызовы состояние не меняют.
                FarmShopPhone:onDeliveryPlacementFailed("no_space")
            end
        end)
        print("[FarmShopPhone][Purchase] Hook installed: PalletSpawner placement failure")
    end
end

--- Вызывается при фактическом создании объектов в рамках активного заказа.
-- Не завершает заказ сразу: в одном открытом каталоге игрок может купить
-- несколько позиций, поэтому доказательства накапливаются до закрытия каталога.
function FarmShopPhone:onOrderObjectsCreated(objects)
    if not self.orderActive or self.orderSettled then
        return
    end

    local count = 0
    for _, object in ipairs(objects) do
        if object ~= nil then
            count = count + 1
        end
    end
    if count == 0 then
        return
    end

    self.evidenceObjects = self.evidenceObjects + count
    FarmShopPhone.purchaseConfirmed = true
    self:setOrderState(FarmShopPhone.ORDER_STATE.PURCHASE_PENDING)
    self:setOrderState(FarmShopPhone.ORDER_STATE.PURCHASE_CONFIRMED)

    print(string.format("[FarmShopPhone][Purchase] Purchase confirmed by object creation: %d object(s), order #%d",
        count, FarmShopPhone.orderToken))

    if self.fulfillment == "delivery" then
        FarmShopPhone.pendingDelivery = true
        -- Отложенный возврат мест спавна: ждание опустошения очереди паллет.
        self.restoreTimer = FarmShopPhone.RESTORE_DEBOUNCE_MS
    end
end

--- Завершает заказ после закрытия каталога.
-- Успех подтверждается только при завершении ВСЕХ загрузок заказа:
-- иначе часть товара могла ещё не появиться.
function FarmShopPhone:finalizeOrderSuccess()
    if self.orderSettled then
        return
    end

    -- Полная или частичная неудача размещения: успех не показываем, плату не списываем.
    if self.fulfillment == "delivery" and self.deliveryFailure ~= nil then
        if (self.pendingLoadCount or 0) > 0 then
            -- Дадим незавершённым загрузкам создать объекты, чтобы не потерять товар.
            print("[FarmShopPhone][Delivery] Размещение не удалось, но есть незавершённые загрузки — ожидание.")
            return
        end
        self:settleDeliveryFailure()
        return
    end

    if (self.pendingLoadCount or 0) > 0 then
        if (self.pendingWaitTimer or 0) <= 0 then
            self.pendingWaitTimer = 15000
            print("[FarmShopPhone][Order] Ожидание завершения загрузок объектов...")
        end
        return
    end

    self.orderSettled = true
    self.settleTimer = 0
    self.pendingWaitTimer = 0

    if self.fulfillment == "delivery" then
        -- Сначала погашаем прежнюю неоплаченную комиссию (если она была).
        local unpaidOk, unpaidResult = pcall(FarmShopPhone.chargeUnpaidFee, FarmShopPhone)
        if not unpaidOk then
            print("[FarmShopPhone][Delivery] Ошибка Lua при списании прежнего долга: " .. tostring(unpaidResult))
        end

        -- Результат списания платы проверяем явно.
        local okCall, charged, reason = pcall(FarmShopPhone.chargeDeliveryFee, FarmShopPhone)
        if not okCall then
            print("[FarmShopPhone][Delivery] Ошибка Lua при списании платы: " .. tostring(charged))
            self:notifyOrderResult("delivery", getText("FSP_DELIVERY_FEE_FAILED"))
        elseif charged == false then
            print("[FarmShopPhone][Delivery] WARNING: плата за доставку не списана (" .. tostring(reason) .. "); сумма сохранена как долг.")
            self:notifyOrderResult("delivery", getText("FSP_DELIVERY_FEE_FAILED"))
        else
            self:notifyOrderResult("delivery")
        end
        self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_COMPLETED)
    else
        self:restoreSpawnPlaces()
        self:setOrderState(FarmShopPhone.ORDER_STATE.COMPLETED)
        self:notifyOrderResult("pickup")
        FarmShopPhone.purchaseConfirmed = false
        FarmShopPhone.pendingDelivery = false
    end

    self.orderActive = false
    self.shopWasVisible = false
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
end

--- Страховочный таймаут ожидания загрузок: не дождались — не заявляем успешную доставку.
function FarmShopPhone:settleDeliveryInconclusive()
    if self.orderSettled or not FarmShopPhone.purchaseConfirmed then
        return
    end

    print("[FarmShopPhone][Delivery] Не удалось дождаться завершения загрузок — заказ закрыт как ошибочный.")
    self.deliveryFailure = self.deliveryFailure or "loads_timeout"
    self:settleDeliveryFailure()
end

--- Неудача размещения купленного товара.
function FarmShopPhone:onDeliveryPlacementFailed(reason)
    if not self.orderActive or self.orderSettled then
        return
    end

    self.deliveryFailure = reason
    print("[FarmShopPhone][Delivery] Placement failed: " .. tostring(reason))

    if FarmShopPhone.purchaseConfirmed then
        -- Частичная доставка: часть товара уже размещена, часть — нет.
        -- Окончательно решит finalizeOrderSuccess() при закрытии каталога.
        self.deliveryPartial = true
        self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_FAILED)
        print("[FarmShopPhone][Delivery] Частичная доставка: часть товара не размещена.")
        return
    end

    if (self.pendingLoadCount or 0) > 0 then
        -- Ещё есть запущенные асинхронные загрузки: они могут создать объекты.
        -- Даём им завершиться, чтобы не потерять товар; заказ завершим после этого.
        print("[FarmShopPhone][Delivery] Размещение не удалось, но есть незавершённые загрузки — ожидание.")
        self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_FAILED)
        return
    end

    self:settleDeliveryFailure()
end

--- Безопасное завершение заказа ошибкой размещения.
function FarmShopPhone:settleDeliveryFailure()
    if self.orderSettled or self.deliveryFailure == nil then
        return
    end

    self:setOrderState(FarmShopPhone.ORDER_STATE.DELIVERY_FAILED)
    self:notifyDeliveryError(self.deliveryPartial and "FSP_DELIVERY_PARTIAL" or "FSP_DELIVERY_FAILED")

    -- Повторную покупку не создаём, плату за доставку не списываем.
    self.restoreTimer = 0
    self:restoreSpawnPlaces()
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
    self.orderSettled = true
    self.orderActive = false
    if g_localPlayer ~= nil then
        g_localPlayer.isControlEnabled = true
    end
end

--- Обработчик финансовых событий: только учёт стоимости покупок для платы за доставку.
-- Факт покупки НЕ определяется по финансовому событию (ТЗ §5). В расчёт платы
-- включаются только известные типы покупок; посторонние списания отфильтровываются.
FarmShopPhone.PURCHASE_STAT_TYPES = {
    -- camelCase (как в StoreDeliveries) и snake_case — на случай иной формы события
    newVehiclesCost = true,
    new_vehicles_cost = true,
    vehicle_leasing_cost = true,
    purchase_pallets = true,
    purchase_seeds = true,
    purchase_fertilizer = true,
    purchase_saplings = true,
    vehicleLeasingCost = true,
    purchasePallets = true,
    purchaseSeeds = true,
    purchaseFertilizer = true,
    purchaseSaplings = true
}

function FarmShopPhone:handleFinanceStats(amount, statType)
    if not self.orderActive or self.orderSettled then
        return
    end
    if self.fulfillment ~= "delivery" then
        return
    end
    if amount == nil or amount >= 0 then
        return
    end
    local statKey = statType ~= nil and tostring(statType) or nil
    if statKey == nil or not FarmShopPhone.PURCHASE_STAT_TYPES[statKey] then
        print(string.format("[FarmShopPhone][Purchase] Списание не включено в плату за доставку (statType=%s)",
            tostring(statType)))
        return
    end

    -- Дубли одного события намеренно не отсекаются: две одинаковые покупки — это два товара.
    self.evidenceSpent = self.evidenceSpent + (-amount)
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        FarmShopPhone.deliveryFarmId = g_currentMission:getFarmId()
    end
    self:setOrderState(FarmShopPhone.ORDER_STATE.PURCHASE_PENDING)
end

--- Рассчитывает комиссию за доставку от суммы покупок.
function FarmShopPhone:computeDeliveryFee(total)
    local fee = math.floor((total or 0) * FarmShopPhone.deliveryRate + 0.5)
    if fee > FarmShopPhone.deliveryMaxCharge then
        fee = FarmShopPhone.deliveryMaxCharge
    end
    if fee < 1 then
        fee = 0
    end
    return fee
end

--- Списание с проверкой фактического результата по балансу фермы.
-- Отсутствие Lua-ошибки не доказывает списание. Если баланс не изменился сразу,
-- проверка откладывается на ~1 с (деньги могут обновляться асинхронно);
-- onUnconfirmed() вызывается только если списание так и не подтвердилось.
function FarmShopPhone:withChargeVerification(farmId, amount, chargeFn, onUnconfirmed)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    local balanceBefore = (farm ~= nil and farm.getBalance ~= nil) and farm:getBalance() or nil

    local okCall, err = pcall(chargeFn)
    if not okCall then
        return false, tostring(err)
    end

    if balanceBefore == nil then
        -- Проверить нечем (нет farmManager/getBalance) — считаем успехом.
        return true, nil
    end

    local okAfter, balanceAfter = pcall(function() return farm:getBalance() end)
    if okAfter and balanceAfter ~= balanceBefore then
        return true, nil
    end

    FarmShopPhone.chargeVerifyPending = {
        farm = farm,
        amount = amount,
        before = balanceBefore,
        remaining = 1000,
        onUnconfirmed = onUnconfirmed
    }
    print(string.format("[FarmShopPhone][Delivery] Списание %s не подтверждено сразу — отложенная проверка.",
        tostring(amount)))
    return true, "deferred"
end

--- Списывает накопленную плату за доставку (2.5% от суммы покупок).
-- Возвращает: charged(boolean), reason("charged" | "nothing_to_charge" | "not_confirmed" | "charge_error").
-- При ошибке списания сумма сохраняется в unpaidFee и будет списана позже.
function FarmShopPhone:chargeDeliveryFee()
    if not FarmShopPhone.purchaseConfirmed then
        FarmShopPhone:logValidation("delivery fee not charged: purchase not confirmed by object creation")
        return false, "not_confirmed"
    end

    local total = self.evidenceSpent or 0
    if total <= 0 then
        FarmShopPhone:logValidation("delivery fee not charged: no purchases recorded")
        return true, "nothing_to_charge"
    end

    local fee = self:computeDeliveryFee(total)
    if fee <= 0 then
        self.evidenceSpent = 0
        return true, "nothing_to_charge"
    end

    local farmId = FarmShopPhone.deliveryFarmId or (g_currentMission ~= nil and g_currentMission:getFarmId() or nil)
    if g_currentMission == nil or farmId == nil then
        FarmShopPhone.unpaidFee = (FarmShopPhone.unpaidFee or 0) + fee
        print("[FarmShopPhone][Delivery] WARNING: плата не списана (нет миссии/фермы), сумма сохранена как долг.")
        return false, "charge_error"
    end

    local chargedOk, chargeErr = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, function()
        FarmShopPhone.unpaidFee = (FarmShopPhone.unpaidFee or 0) + fee
        FarmShopPhone.unpaidFeeFarmId = FarmShopPhone.unpaidFeeFarmId or farmId
    end)
    if not chargedOk then
        FarmShopPhone.unpaidFee = (FarmShopPhone.unpaidFee or 0) + fee
        FarmShopPhone.unpaidFeeFarmId = FarmShopPhone.unpaidFeeFarmId or farmId
        print("[FarmShopPhone][Delivery] ERROR списания платы: " .. tostring(chargeErr) .. " — сумма сохранена как долг.")
        return false, "charge_error"
    end

    local text = string.format("%s: -%s", getText("FSP_DELIVERY_FEE"), g_i18n:formatMoney(fee, 0, false, true))
    if g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text, nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end

    print(string.format("[FarmShopPhone][Delivery] Delivery fee charged: %d (purchases %.2f)", fee, total))

    self.evidenceSpent = 0
    FarmShopPhone.deliveryTotalCharges = 0
    FarmShopPhone.deliveryFarmId = nil
    FarmShopPhone.purchaseConfirmed = false
    FarmShopPhone.pendingDelivery = false
    return true, "charged"
end

--- Пытается списать ранее неоплаченную комиссию (долг). Возвращает charged, reason.
function FarmShopPhone:chargeUnpaidFee()
    local fee = FarmShopPhone.unpaidFee or 0
    if fee <= 0 then
        return true, "none"
    end

    local farmId = FarmShopPhone.unpaidFeeFarmId
        or (g_currentMission ~= nil and g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or nil)
    if g_currentMission == nil or farmId == nil then
        return false, "no_mission"
    end

    local chargedOk, chargeErr = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, nil)
    if not chargedOk then
        print("[FarmShopPhone][Delivery] ERROR списания прежнего долга: " .. tostring(chargeErr))
        return false, "error"
    end

    print("[FarmShopPhone][Delivery] Ранее неоплаченная комиссия списана: " .. fee)
    FarmShopPhone.unpaidFee = 0
    FarmShopPhone.unpaidFeeFarmId = nil
    if g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format("%s: -%s", getText("FSP_DELIVERY_FEE"), g_i18n:formatMoney(fee, 0, false, true)),
            nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
    return true, "charged"
end

--- Плата за телефонный звонок (открытие магазина через телефон).
function FarmShopPhone:chargeCallFee()
    if self.callFeeCharged then
        return true, "already"
    end

    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    local fee = FarmShopPhone.CALL_FEE

    if g_currentMission == nil or farmId == nil then
        print("[FarmShopPhone][Order] Плата за звонок не списана: миссия/ферма недоступны.")
        return false, "no_mission"
    end

    local chargedOk, chargeErr = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, function()
        print("[FarmShopPhone][Order] WARNING: плата за звонок не подтверждена; повторная попытка при следующем вызове.")
    end)
    if not chargedOk then
        print("[FarmShopPhone][Order] ERROR списания платы за звонок: " .. tostring(chargeErr))
        return false, "error"
    end

    self.callFeeCharged = true
    print("[FarmShopPhone][Order] Плата за звонок списана: " .. fee)
    if g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format("%s: -%s", getText("FSP_CALL_FEE"), g_i18n:formatMoney(fee, 0, false, true)),
            nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
    return true, "charged"
end

--- Возвращает плату за звонок, если выбранный магазин открыть не удалось.
function FarmShopPhone:refundCallFee()
    if not self.callFeeCharged then
        return
    end

    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    local fee = FarmShopPhone.CALL_FEE

    if g_currentMission == nil or farmId == nil then
        self.callFeeCharged = false
        return
    end

    local okRefund, err = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(fee, farmId, MoneyType.OTHER)
    end, nil)
    if not okRefund then
        print("[FarmShopPhone][Order] WARNING: возврат платы за звонок не выполнен: " .. tostring(err))
        return
    end

    self.callFeeCharged = false
    print("[FarmShopPhone][Order] Плата за звонок возвращена: " .. fee)
end

--- Отложенный возврат мест спавна после появления объектов.
-- Не выполняется, пока каталог магазина открыт: игрок может докупить паллеты.
function FarmShopPhone:processRestoreTimer(dt)
    if self.restoreTimer > 0 then
        if self.orderActive and g_gui ~= nil and g_gui:getIsGuiVisible() then
            return
        end
        self.restoreTimer = self.restoreTimer - dt
        if self.restoreTimer <= 0 then
            self.restoreTimer = 0
            self:restoreSpawnPlaces()
        end
    end
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
        self:updatePhoneInput()
    end

    -- Ожидание завершения заказа: доказательство — реальное создание объекта,
    -- а не закрытие каталога и не фиксированный таймер.
    if self.orderActive and not self.orderSettled and g_gui ~= nil then
        if g_gui:getIsGuiVisible() then
            if self.catalogOpenedByUs then
                self.shopWasVisible = true
            end
        elseif self.shopWasVisible then
            if FarmShopPhone.purchaseConfirmed then
                self:finalizeOrderSuccess()
            elseif self.settleTimer <= 0 then
                print("[FarmShopPhone][Order] Catalog closed; waiting for purchase confirmation...")
                self.settleTimer = FarmShopPhone.SETTLE_TIMEOUT_MS
            end
        end
    end

    -- Отложенная проверка списания: если баланс не изменился мгновенно.
    local pendingCharge = FarmShopPhone.chargeVerifyPending
    if pendingCharge ~= nil then
        pendingCharge.remaining = pendingCharge.remaining - dt
        if pendingCharge.remaining <= 0 then
            local okBalance, balanceNow = pcall(function() return pendingCharge.farm:getBalance() end)
            if okBalance and balanceNow ~= pendingCharge.before then
                print(string.format("[FarmShopPhone][Delivery] Списание %s подтверждено при отложенной проверке.",
                    tostring(pendingCharge.amount)))
            else
                print(string.format("[FarmShopPhone][Delivery] WARNING: списание %s так и не подтвердилось.",
                    tostring(pendingCharge.amount)))
                if pendingCharge.onUnconfirmed ~= nil then
                    pcall(pendingCharge.onUnconfirmed)
                end
            end
            FarmShopPhone.chargeVerifyPending = nil
        end
    end

    if self.settleTimer > 0 and not self.orderSettled then
        self.settleTimer = self.settleTimer - dt
        if self.settleTimer <= 0 then
            self.settleTimer = 0
            if not FarmShopPhone.purchaseConfirmed then
                print("[FarmShopPhone][Order] No purchase confirmed: order cancelled.")
                self.restoreTimer = 0
                self:restoreSpawnPlaces()
                self:setOrderState(FarmShopPhone.ORDER_STATE.CANCELLED)
                self.orderSettled = true
                self.orderActive = false
                self.shopWasVisible = false
                if g_localPlayer ~= nil then
                    g_localPlayer.isControlEnabled = true
                end
            end
        end
    end

    -- Отложенный возврат мест спавна после появления объектов.
    self:processRestoreTimer(dt)

    -- Страховочный таймаут ожидания загрузок: не дождались — не заявляем успешную доставку.
    if self.pendingWaitTimer > 0 and not self.orderSettled and self:canSettleOrder() then
        self.pendingWaitTimer = self.pendingWaitTimer - dt
        if self.pendingWaitTimer <= 0 then
            self.pendingWaitTimer = 0
            self:settleDeliveryInconclusive()
        end
    end

    -- Периодическая проверка доступности выбранных магазинов (каждые 5 секунд)
    if self.storeAvailabilityTimer == nil then
        self.storeAvailabilityTimer = 0
    end
    self.storeAvailabilityTimer = self.storeAvailabilityTimer + dt
    if self.storeAvailabilityTimer > 5000 then  -- 5 seconds
        self.storeAvailabilityTimer = 0
        self:verifyStoreAvailability()
    end
end

function FarmShopPhone:draw()
    self:drawPhone()
end

addModEventListener(FarmShopPhone)

