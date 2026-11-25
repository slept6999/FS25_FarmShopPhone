-- FarmShopPhoneUI.lua — модуль интерфейса FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone.

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
        "call_button_wide", "call_button_red", "package_grey", "store_grey", "tractor_grey", "store_lime", "truck_lime", "check_lime"
    
    }

    local loaded = true
    for _, name in ipairs(names) do
        -- Сначала пробуем сжатый DDS (нет предупреждений о размере), затем PNG как запасной вариант.
        local ok, overlay = pcall(function()
            return Overlay.new(dir .. name .. ".dds", 0, 0, 0.1, 0.1)
        end)
        if not (ok and overlay ~= nil and overlay.overlayId ~= 0) then
            ok, overlay = pcall(function()
                return Overlay.new(dir .. name .. ".png", 0, 0, 0.1, 0.1)
            end)
        end
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
        return FarmShopPhone:getText(reason)
    end
    return reason or ""
end

--- Показывает уведомление об ошибке доставки.
function FarmShopPhone:showDeliveryError(reason)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        local text = FarmShopPhone:getText("FSP_DELIVERY_UNSAFE") .. " " .. localizeReason(reason)
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            text, nil, GuiSoundPlayer.SOUND_SAMPLES.ERROR)
    end
end

--- Показывает уведомление об успешном выборе/размещении доставки.
function FarmShopPhone:showDeliverySuccess(key)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        local text = FarmShopPhone:getText(key)
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
        text = FarmShopPhone:getText("FSP_DELIVERY_DONE")
    else
        text = string.format(FarmShopPhone:getText("FSP_ORDER_PICKUP_DONE"), self.orderStoreName or "")
    end

    if warningKey ~= nil then
        text = text .. " (" .. FarmShopPhone:getText(warningKey) .. ")"
    end

    g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        text, nil, GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
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
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_TITLE"),
        ui.innerX, ui.headerY + 0.036, ui.innerW, 0.036, 0.021, 0.72, 0.95, 0.29, 1)
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_SUBTITLE"),
        ui.innerX, ui.headerY + 0.004, ui.innerW, 0.03, 0.013, 0.62, 0.62, 0.62, 1)

    -- Заголовок списка поставщиков — по центру панели.
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_SHOPS"),
        ui.innerX, ui.listTop + 0.002, ui.innerW, 0.026, 0.016, 0.72, 0.95, 0.29, 1)

    local firstIndex = self.storeScrollOffset
    local lastIndex = math.min(#self.stores, firstIndex + ui.rows - 1)
    local y = ui.listTop

    if #self.stores == 0 then
        setTextColor(0.94, 0.73, 0.29, 1)
        renderText(ui.listX + 0.012, y - 0.022, 0.015, FarmShopPhone:getText("FSP_NO_STORES"))
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
            -- Все иконки теперь в DDS 64x64 с одинаковым масштабом глифа.
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
            local name = FarmShopPhone:limitUtf8(self.stores[i].name, 28)
            renderText(textX, rowY + 0.0195, 0.015, name)
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
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_FULFILLMENT"),
        ui.innerX, ui.fulfillmentY + ui.cardH + 0.008, ui.innerW, 0.026, 0.016,
        0.72, 0.95, 0.29, 1)

    local pickupSelected = self.fulfillment == "pickup"
    local deliverySelected = self.fulfillment == "delivery"
    local rowsShown = math.max(0, lastIndex - firstIndex + 1)
    local hasStore = #self.stores > 0
    local focusPickup = self.focusIndex == rowsShown + 1
    local focusDelivery = self.focusIndex == rowsShown + 2

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
    local textY = ui.fulfillmentY + ui.cardH * 0.5 + 0.005

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)

    if pickupSelected then
        setTextColor(0.72, 0.95, 0.29, 1)
    else
        setTextColor(1, 1, 1, 1)
    end
    renderText(textX, textY, 0.011, FarmShopPhone:getText("FSP_UI_PICKUP_TINY"))

    if deliverySelected then
        setTextColor(0.72, 0.95, 0.29, 1)
    else
        setTextColor(1, 1, 1, 1)
    end
    renderText(deliveryTextX, textY, 0.011, FarmShopPhone:getText("FSP_UI_DELIVERY_TINY"))

    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextColor(1, 1, 1, 1)

    -- Главная кнопка.
    -- Кнопка вызова: широкая зелёная плашка с тёмной трубкой по центру.
    local callEnabled = hasStore
    local callHovered = self.hoverId == "call"
    local callPressed = self.pressedId == "call"

    -- При нажатии «трубка» краснеет — как активный звонок в реальном телефоне.
    local callActive = callPressed and callEnabled
    if textured then
        self:drawTexture(callActive and "call_button_red" or "call_button_wide",
            ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH)
    else
        if callActive then
            drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 0.95, 0.30, 0.25, 1)
        else
            drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH,
                callEnabled and 0.72 or 0.35, callEnabled and 0.95 or 0.40,
                callEnabled and 0.29 or 0.20, 1)
        end
    end

    -- Состояния кнопки: disabled, hover, focused (pressed уже отрисован красным).
    if not callEnabled then
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 0.06, 0.07, 0.08, 0.55)
    elseif callHovered and not callActive then
        drawFilledRect(ui.buttonX, ui.buttonY, ui.buttonW, ui.buttonH, 1, 1, 1, 0.10)
    end

    -- Нижняя подсказка.
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_HINT_1"),
        ui.innerX, ui.footerY + 0.062, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_HINT_2"),
        ui.innerX, ui.footerY + 0.038, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_HINT_3"),
        ui.innerX, ui.footerY + 0.014, ui.innerW, 0.022, 0.011, 0.62, 0.62, 0.62, 1)
    self:drawCenteredText(FarmShopPhone:getText("FSP_UI_FEE"),
        ui.innerX, ui.contentY + 0.016, ui.innerW, 0.02, 0.01, 0.94, 0.73, 0.29, 1)
end

