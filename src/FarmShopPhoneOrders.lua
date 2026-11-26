-- FarmShopPhoneOrders.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
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
function FarmShopPhone:unregisterPendingLoad(loadData, loadToken)
    if self.pendingLoads == nil or loadData == nil then
        return false
    end
    local token = loadToken or FarmShopPhone.orderToken
    if self.pendingLoads[loadData] == token then
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
    if Utils == nil or Utils.overwrittenFunction == nil then
        print("[FarmShopPhone] WARNING: Utils.overwrittenFunction is unavailable; purchase confirmation is disabled.")
        return
    end
    self.purchaseHooksInstalled = true

    -- Транспорт и паллеты (паллеты тоже загружаются через VehicleLoadingData).
    if VehicleLoadingData ~= nil and VehicleLoadingData.load ~= nil
            and VehicleLoadingState ~= nil and VehicleLoadingState.OK ~= nil then
        local vehicleOkState = VehicleLoadingState.OK
        VehicleLoadingData.load = Utils.overwrittenFunction(VehicleLoadingData.load,
                function(loadData, superFunc, callback, callbackTarget, callbackArguments)
            -- Связываем операцию загрузки с заказом, активным на момент её старта.
            local belongsToOrder = false
            local loadToken = FarmShopPhone.orderToken
            if FarmShopPhone.orderActive and not FarmShopPhone.orderSettled then
                FarmShopPhone:registerPendingLoad(loadData)
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
                    pcall(callback, cbTarget, objects, loadingState, cbArgs)
                end
                if belongsToOrder then
                    FarmShopPhone:unregisterPendingLoad(loadData, loadToken)
                    FarmShopPhone:onPendingLoadFinished()
                end
            end
            return superFunc(loadData, wrapped, callbackTarget, callbackArguments)
        end)
        print("[FarmShopPhone][Purchase] Hook installed: VehicleLoadingData.load")
    end

    -- Объекты (строения и производства).
    if PlaceableLoadingData ~= nil and PlaceableLoadingData.load ~= nil
            and PlaceableLoadingState ~= nil and PlaceableLoadingState.OK ~= nil then
        local placeableOkState = PlaceableLoadingState.OK
        PlaceableLoadingData.load = Utils.overwrittenFunction(PlaceableLoadingData.load,
                function(loadData, superFunc, callback, callbackTarget, callbackArguments)
            local belongsToOrder = false
            local loadToken = FarmShopPhone.orderToken
            if FarmShopPhone.orderActive and not FarmShopPhone.orderSettled then
                FarmShopPhone:registerPendingLoad(loadData)
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
                    pcall(callback, cbTarget, result, loadingState, cbArgs)
                end
                if belongsToOrder then
                    FarmShopPhone:unregisterPendingLoad(loadData, loadToken)
                    FarmShopPhone:onPendingLoadFinished()
                end
            end
            return superFunc(loadData, wrapped, callbackTarget, callbackArguments)
        end)
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
        -- Результат списания платы проверяем явно.
        local okCall, charged, reason = pcall(FarmShopPhone.chargeDeliveryFee, FarmShopPhone)
        if not okCall then
            print("[FarmShopPhone][Delivery] Ошибка Lua при списании платы: " .. tostring(charged))
            self:notifyOrderResult("delivery", "FSP_DELIVERY_FEE_FAILED")
        elseif charged == false then
            print("[FarmShopPhone][Delivery] WARNING: плата за доставку не списана (" ..
                tostring(reason) .. "); повторного списания не будет.")
            self:notifyOrderResult("delivery", "FSP_DELIVERY_FEE_FAILED")
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
            local confirmed = false
            if okBalance then
                confirmed = math.abs((pendingCharge.before - balanceNow) - pendingCharge.amount) <= 0.01
            end
            if confirmed then
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

