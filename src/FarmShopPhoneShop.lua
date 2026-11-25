-- FarmShopPhoneShop.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
end

local function callMethodSafe(object, methodName)
    if object == nil or object[methodName] == nil then
        return false
    end
    local ok, err = pcall(object[methodName], object)
    if not ok then
        print(string.format("[FarmShopPhone] Failed %s(): %s", methodName, tostring(err)))
        return false
    end
    return true
end

local function playerMovedDistance(before)
    if before == nil or g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return -1
    end
    local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
    return math.sqrt((x - before[1]) ^ 2 + (y - before[2]) ^ 2 + (z - before[3]) ^ 2)
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
                -- Штатный ShopMenu напрямую, без ванильной телепортации игрока к точке
                -- (подтверждено игровым тестом: каталог наполняется, позиция не меняется).
                if g_gui == nil or ShopMenu == nil then
                    print("[FarmShopPhone][UI] ShopMenu недоступен.")
                    return false
                end
                local okNav, errNav = pcall(function()
                    g_gui:changeScreen(nil, ShopMenu)
                end)
                if not okNav then
                    print("[FarmShopPhone][UI] changeScreen(ShopMenu) failed: " .. tostring(errNav))
                    return false
                end
                print("[FarmShopPhone][UI] ShopMenu открыт без телепорта.")
                return true
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

    local dbgSpec = store.placeable ~= nil and store.placeable.spec_vehicleBuyingStation or nil
    print(string.format("[FarmShopPhone][UI] Open requested: storeName=%s storeKind=%s storeMode=%s shopTrigger=%s vehicleBuyingStation=%s",
        tostring(store.name), tostring(store.kind), tostring(store.openMode),
        store.triggerObject ~= nil and "yes" or "no",
        dbgSpec ~= nil and "yes" or "no"))

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
            if not ok or result ~= true then
                print("[FarmShopPhone][Delivery] Pallet spawn patch failed: " .. tostring(ok and result or "error"))
                self:restorePalletSpawnPlaces()
                self:abortOrder("delivery spawn override failed")
                return false
            end
            applied = true
        elseif not applied then
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

    -- Запоминаем позицию игрока до открытия (диагностика телепортации).
    self.debugPlayerBefore = nil
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        self.debugPlayerBefore = {getWorldTranslation(g_localPlayer.rootNode)}
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
        local moved = FarmShopPhone:playerMovedDistance(self.debugPlayerBefore)
        print(string.format("[FarmShopPhone][UI] Store interface could not be opened: name=%s kind=%s mode=%s placeable=%s trigger=%s reason=open_interface_failed playerDistance=%.1f playerTeleported=%s",
            tostring(store.name), tostring(store.kind), tostring(store.openMode),
            store.placeable ~= nil and "yes" or "no", store.triggerObject ~= nil and "yes" or "no",
            moved, tostring(moved > 1.0)))
        -- Плата за звонок НЕ списывается: точку открыть не удалось («трубку не сняли»).
        self:notifyOrderResult("delivery", FarmShopPhone:getText("FSP_STORE_OPEN_FAILED"))
        self:abortOrder("shop_interface_unavailable")
        return false
    end

    local moved = FarmShopPhone:playerMovedDistance(self.debugPlayerBefore)
    print(string.format("[FarmShopPhone][UI] Store interface opened: name=%s kind=%s mode=%s placeable=%s playerDistance=%.1f playerTeleported=%s",
        tostring(store.name), tostring(store.kind), tostring(store.openMode),
        store.placeable ~= nil and "yes" or "no", moved, tostring(moved > 1.0)))

    -- Телефонный звонок состоялся: точка открыта успешно — только теперь списываем плату.
    local feeOk, feeCharged, feeReason = pcall(FarmShopPhone.chargeCallFee, FarmShopPhone)
    if not feeOk or feeCharged == false then
        print("[FarmShopPhone][Order] Плата за звонок не списана: " .. tostring(feeOk and feeReason or feeCharged))
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

