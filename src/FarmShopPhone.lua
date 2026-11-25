-------------------------------------------------------------------------------
-- FarmShopPhone — фермерский телефон для FS25 (Farm Shop Phone for FS25)
--
-- Version: 0.2.6.4
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
FarmShopPhone.pendingWaitTimer = 0      -- страховочный таймаут ожидания загрузок перед завершением заказа
FarmShopPhone.chargeVerifyPending = nil -- отложенная проверка списания (асинхронный баланс)
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

--- Расстояние, на которое переместился игрок (для диагностики телепорта).
local function playerMovedDistance(before)
    if before == nil then
        return -1
    end
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return -1
    end
    local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
    return math.sqrt((x - before[1]) ^ 2 + (y - before[2]) ^ 2 + (z - before[3]) ^ 2)
end

--- Возвращает текущие мировые координаты локального игрока (x, y, z).
-- @return таблица {x, y, z} или nil, если игрок недоступен.
local function getPlayerPosition()
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return nil
    end
    return {getWorldTranslation(g_localPlayer.rootNode)}
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

