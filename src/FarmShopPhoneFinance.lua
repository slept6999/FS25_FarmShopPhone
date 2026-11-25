-- FarmShopPhoneFinance.lua — расчёт и проведение платежей.
-- Модуль использует общий объект FarmShopPhone, не создаёт своё состояние.
-- Загружается после src/FarmShopPhone.lua (там определены константы и состояние).

local function getText(name)
    return g_i18n:getText(name)
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
    local expected = amount or 0
    if okAfter then
        local delta = balanceBefore - balanceAfter
        if math.abs(delta - expected) <= 0.01 then
            return true, nil
        end
        print(string.format("[FarmShopPhone][Delivery] Баланс изменился на %.2f, ожидалось списание %.2f — проверяем позже.",
            delta, expected))
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

    local text = string.format("%s: -%s", FarmShopPhone:getText("FSP_DELIVERY_FEE"), g_i18n:formatMoney(fee, 0, false, true))
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

    local chargedOk, reason = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, nil)
    if not chargedOk then
        print("[FarmShopPhone][Delivery] ERROR списания прежнего долга: " .. tostring(reason))
        return false, "error"
    end
    if reason == "deferred" then
        -- Баланс ещё не подтвердил списание: долг НЕ обнуляем, повторим при следующей проверке.
        print("[FarmShopPhone][Delivery] Списание прежнего долга отложено; сумма сохранена.")
        return true, "deferred"
    end

    print("[FarmShopPhone][Delivery] Ранее неоплаченная комиссия списана: " .. fee)
    FarmShopPhone.unpaidFee = 0
    FarmShopPhone.unpaidFeeFarmId = nil
    if g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format("%s: -%s", FarmShopPhone:getText("FSP_DELIVERY_FEE"), g_i18n:formatMoney(fee, 0, false, true)),
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

    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm ~= nil and farm.getBalance ~= nil then
        local balance = farm:getBalance()
        if balance < fee then
            print(string.format("[FarmShopPhone][Order] Плата за звонок не списана: недостаточно средств (%.2f < %d).", balance, fee))
            return false, "insufficient_funds"
        end
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
            string.format("%s: -%s", FarmShopPhone:getText("FSP_CALL_FEE"), g_i18n:formatMoney(fee, 0, false, true)),
            nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
    return true, "charged"
end


