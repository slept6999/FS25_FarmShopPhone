-- FarmShopPhoneCore.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
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
    self.debugPlayerBefore = nil
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
    self.callPosition = FarmShopPhone:getPlayerPosition()
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
        FarmShopPhone:getText(key), nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
end

