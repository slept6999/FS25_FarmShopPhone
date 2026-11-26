-- FarmShopPhoneFinance.lua — расчёт и проведение платежей.
-- Модуль использует общий объект FarmShopPhone, не создаёт своё состояние.
-- Загружается после src/FarmShopPhone.lua (там определены константы и состояние).

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
        remaining = 3000,  -- 3 секунды вместо 1
        onUnconfirmed = onUnconfirmed
    }
    print(string.format("[FarmShopPhone][Delivery] Списание %s не подтверждено сразу — отложенная проверка (3 с).",
        tostring(amount)))
    return true, "deferred"
end

--- Проверяет, может ли текущая ферма оплатить звонок.
function FarmShopPhone:canAffordCallFee()
    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    if g_currentMission == nil or farmId == nil then
        return false, "no_mission"
    end

    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm == nil or farm.getBalance == nil then
        return false, "balance_unavailable"
    end

    local okBalance, balance = pcall(farm.getBalance, farm)
    if not okBalance or balance == nil then
        return false, "balance_unavailable"
    end
    if balance < FarmShopPhone.CALL_FEE then
        return false, "insufficient_funds", balance
    end

    return true, nil, nil
end

local function notifyDeliveryFeeFailure()
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            FarmShopPhone:getText("FSP_DELIVERY_FEE_FAILED"), nil,
            GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
end

--- Списывает накопленную плату за доставку (2.5% от суммы покупок).
-- Возвращает: charged(boolean), reason("charged" | "nothing_to_charge" | "not_confirmed" | "charge_error").
-- Ошибка видна игроку и в журнале, но скрытых долгов и повторных списаний нет.
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
        print("[FarmShopPhone][Delivery] WARNING: плата не списана (нет миссии/фермы).")
        return false, "charge_error"
    end

    local chargedOk, chargeErr = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, function()
        print("[FarmShopPhone][Delivery] WARNING: плата за доставку не подтверждена; повторного списания не будет.")
        notifyDeliveryFeeFailure()
    end)
    if not chargedOk then
        print("[FarmShopPhone][Delivery] ERROR списания платы: " .. tostring(chargeErr))
        return false, "charge_error"
    end

    -- Note: if deferred, notification and cleanup will happen in deferred check
    if chargeErr == "deferred" then
        print(string.format("[FarmShopPhone][Delivery] Delivery fee %d pending verification (purchases %.2f)", fee, total))
        return true, "deferred"
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

    local canAfford, affordReason, balance = self:canAffordCallFee()
    if not canAfford then
        if affordReason == "insufficient_funds" then
            print(string.format("[FarmShopPhone][Order] Плата за звонок не списана: недостаточно средств (%.2f < %d).",
                balance or 0, fee))
        else
            print("[FarmShopPhone][Order] Плата за звонок не списана: миссия/ферма недоступны.")
        end
        return false, affordReason
    end

    local chargedOk, chargeErr = self:withChargeVerification(farmId, fee, function()
        g_currentMission:addMoney(-fee, farmId, MoneyType.OTHER)
    end, function()
        print("[FarmShopPhone][Order] WARNING: плата за звонок не подтверждена; повторного списания не будет.")
    end)
    if not chargedOk then
        print("[FarmShopPhone][Order] ERROR списания платы за звонок: " .. tostring(chargeErr))
        return false, "error"
    end

    -- Note: if deferred, notification and callFeeCharged will be set in deferred check
    if chargeErr == "deferred" then
        print("[FarmShopPhone][Order] Плата за звонок " .. fee .. " pending verification")
        return true, "deferred"
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


