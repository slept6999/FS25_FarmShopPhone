-- FarmShopPhoneInput.lua — модуль FS25 Farm Shop Phone.
-- Использует общий объект FarmShopPhone, не создаёт своё состояние заказа.

local function getText(name)
    return g_i18n:getText(name)
end

local function inRect(x, y, rx, ry, w, h)
    return x >= rx and x <= rx + w and y >= ry and y <= ry + h
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
        if FarmShopPhone:inRect(x, y, r[1], r[2], r[3], r[4]) then
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
            and FarmShopPhone:inRect(mouseX, mouseY, ui.listX,
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

