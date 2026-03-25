--[[--
Integrated highlight / note compose bar (koplugin).

Replaces ReaderHighlight:onShowHighlightMenu with a single ButtonDialog where the user
sets color, style, optional note, selection boundaries, can open the classic action grid,
then confirms with a checkmark.

Also replaces showHighlightNoteOrDialog so tapping a saved highlight (with or without a
note) opens the same compose panel.
--]]--

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local Device = require("device")
local ffiUtil = require("ffi/util")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Size = require("ui/size")

local ReaderHighlight = require("apps/reader/modules/readerhighlight")

local Screen = Device.screen

-- Single-glyph style row (no translated words); matches highlight drawer keys.
local STYLE_COMPACT_GLYPH = {
    lighten = "░",
    underscore = "▁",
    strikeout = "─",
    invert = "◐",
}

local HighlightComposePlugin = WidgetContainer:extend{
    name = "highlightcompose",
    is_doc_only = true,
}

local orig_onShowHighlightMenu
local orig_showHighlightNoteOrDialog

local function boundariesEnabled(rh)
    return rh.selected_text and not rh.selected_text.text_edited
end

local function currentDrawer(rh)
    return rh.selected_text.drawer or rh.view.highlight.saved_drawer
end

local function currentColor(rh)
    return rh.selected_text.color or rh.view.highlight.saved_color
end

local function colorChoiceEnabled(rh)
    return currentDrawer(rh) ~= "invert"
end

--- Prefer below/above the highlight (like "follow selection" mode) even when the global
--- highlight popup position is "center", so the bar does not cover the selected text and
--- boundary nudge buttons stay meaningful. Falls back to stock anchor when needed.
local function composeDialogAnchor(rh, dialog, index)
    local position = G_reader_settings:readSetting("highlight_dialog_position", "center")
    if position == "gesture" or position == "top" or position == "bottom" then
        return rh:_getDialogAnchor(dialog, index)
    end
    local db = dialog:getContentSize()
    if not db or not db.w or not db.h then
        return nil
    end
    local boxes = index and rh:getHighlightVisibleBoxes(index)
        or (rh.selected_text and (rh.selected_text.sboxes or rh.selected_text.pboxes))
    if boxes == nil then
        return nil
    end
    local padding = Size.padding.small
    local anchor_x = math.floor((rh.screen_w - db.w) / 2)
    local box0, box1 = boxes[1], boxes[#boxes]
    if box0.y > box1.y then
        box0, box1 = box1, box0
    end
    if rh.ui.paging then
        local page = index and rh.ui.annotation.annotations[index].pos0.page or rh.selected_text.pos0.page
        box0 = rh.view:pageToScreenTransform(page, box0)
        box1 = rh.view:pageToScreenTransform(page, box1)
        if box0 == nil or box1 == nil then
            return nil
        end
    end
    local y0 = box0.y
    local y1 = box1.y + box1.h
    local dialog_box_h = db.h + 2 * padding
    local anchor_y, prefers_pop_down
    if y1 + dialog_box_h <= rh.screen_h then
        anchor_y = y1 + padding
        prefers_pop_down = true
    elseif dialog_box_h <= y0 then
        anchor_y = y0 - padding
    else
        return nil
    end
    return { x = anchor_x, y = anchor_y, h = 0, w = 0 }, prefers_pop_down
end

--- Adjust live selection edges (same logic as editing a saved highlight).
local function updatePendingBounds(rh, side, direction, move_by_char)
    if not rh.selected_text then
        return
    end
    local ok
    if rh.ui.rolling then
        ok = rh:updateHighlightRolling(rh.selected_text, side, direction, move_by_char)
        if ok then
            rh.ui.document:getTextFromXPointers(rh.selected_text.pos0, rh.selected_text.pos1, true)
        end
    else
        ok = rh:updateHighlightPaging(rh.selected_text, side, direction)
        if ok then
            local page = rh.selected_text.pos0.page
            local boxes = rh.ui.document:getPageBoxesFromPositions(page, rh.selected_text.pos0, rh.selected_text.pos1)
            if boxes then
                rh.view.highlight.temp[page] = boxes
            end
        end
    end
    if ok then
        UIManager:setDirty(rh.dialog, "ui")
    end
end

local function showLegacyHighlightMenu(rh, index)
    local highlight_buttons = {{}}
    local columns = 2
    for idx, fn_button in ffiUtil.orderedPairs(rh._highlight_buttons) do
        local button = fn_button(rh, index)
        if not button.show_in_highlight_dialog_func or button.show_in_highlight_dialog_func() then
            if #highlight_buttons[#highlight_buttons] >= columns then
                table.insert(highlight_buttons, {})
            end
            table.insert(highlight_buttons[#highlight_buttons], button)
            logger.dbg("ReaderHighlight", idx .. ": line " .. #highlight_buttons .. ", col " .. #highlight_buttons[#highlight_buttons])
        end
    end
    rh.highlight_dialog = ButtonDialog:new{
        buttons = highlight_buttons,
        anchor = function()
            return rh:_getDialogAnchor(rh.highlight_dialog, index)
        end,
        tap_close_callback = function()
            if rh.hold_pos then
                rh:clear()
            end
        end,
    }
    UIManager:show(rh.highlight_dialog, "[ui]")
end

--- Persist compose changes to an already-saved highlight (not saveHighlight).
local function applyComposeToSavedHighlight(rh, index, pending_note)
    local item = rh.ui.annotation.annotations[index]
    local sel = rh.selected_text
    local item_before = util.tableDeepCopy(item)
    local type_before = rh.ui.bookmark.getBookmarkType(item)

    item.drawer = sel.drawer or rh.view.highlight.saved_drawer
    item.color = sel.color or rh.view.highlight.saved_color
    item.note = (pending_note and pending_note ~= "") and pending_note or nil

    item.pos0 = sel.pos0
    item.pos1 = sel.pos1
    if sel.text then
        item.text = util.cleanupSelectedText(sel.text)
    end
    item.pboxes = sel.pboxes
    item.ext = sel.ext

    if sel.page ~= nil then
        item.page = sel.page
    end
    if sel.chapter ~= nil then
        item.chapter = sel.chapter
    end
    if sel.pageno ~= nil then
        item.pageno = sel.pageno
    end

    if rh.document.is_pdf and rh.highlight_write_into_pdf and item_before.drawer then
        rh:writePdfAnnotation("delete", item_before)
    end
    if rh.document.is_pdf and rh.highlight_write_into_pdf and item.drawer then
        rh:writePdfAnnotation("save", item)
        rh:writePdfAnnotation("content", item, item.note or "")
    end

    local type_after = rh.ui.bookmark.getBookmarkType(item)
    if type_before ~= type_after then
        if type_before == "highlight" then
            rh.ui:handleEvent(Event:new("AnnotationsModified",
                { item, nb_highlights_added = -1, nb_notes_added = 1 }))
        else
            rh.ui:handleEvent(Event:new("AnnotationsModified",
                { item, nb_highlights_added = 1, nb_notes_added = -1 }))
        end
    else
        rh.ui:handleEvent(Event:new("AnnotationsModified", { item }))
    end
    rh.view.footer:maybeUpdateFooter()
    if rh.view.highlight.note_mark then
        UIManager:setDirty(rh.dialog, "ui")
    end
end

local function refreshButtonCheckmarks(dlg, button_ids)
    if not dlg then
        return
    end
    for _, id in ipairs(button_ids) do
        local b = dlg:getButtonById(id)
        if b and b.checked_func and b.label_widget then
            b.label_widget:setText(b:getDisplayText())
            b:refresh()
        end
    end
end

local function buildComposeDialog(rh, index)
    local move_by_char = false
    local pending_note = rh.selected_text.note
    local compose_dialog
    local color_button_ids = {}
    local style_button_ids = {}

    local function closeCompose()
        UIManager:close(compose_dialog)
        if rh.highlight_dialog == compose_dialog then
            rh.highlight_dialog = nil
        end
    end

    local function applyStyleToDefaults(drawer)
        rh.view.highlight.saved_drawer = drawer
    end

    local function applyColorToDefaults(color)
        rh.view.highlight.saved_color = color
    end

    local function openNoteEditor()
        local note_dialog
        local note_opts = {
            title = _("Note"),
            input = pending_note or "",
            input_hint = _("Optional note"),
            allow_newline = true,
            add_scroll_buttons = true,
            use_available_height = true,
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(note_dialog, "flashui")
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            pending_note = note_dialog:getInputText()
                            rh.selected_text.note = pending_note ~= "" and pending_note or nil
                            UIManager:close(note_dialog)
                        end,
                    },
                },
            },
        }
        if index then
            note_opts.description = "   " .. rh.ui.bookmark:_getDialogHeader(rh.ui.annotation.annotations[index])
        end
        note_dialog = InputDialog:new(note_opts)
        UIManager:show(note_dialog)
        note_dialog:onShowKeyboard()
    end

    local buttons = {}
    local color_list = rh.highlight_colors
    local bg_colors = rh:getHighlightColorList()
    -- Short vertical strips; color row is the thinnest (wide horizontal bar).
    local color_strip_h = Screen:scaleBySize(20)
    local mid_row_h = Screen:scaleBySize(26)
    local action_row_h = Screen:scaleBySize(28)

    -- One row: color swatches only (no labels); checkmark shows selection.
    -- (Do not set width on every button in a row — ButtonTable divides by unspecified count.)
    local color_row = {}
    for j = 1, #color_list do
        local _, key = unpack(color_list[j])
        local btn_id = "hlc_" .. key
        table.insert(color_button_ids, btn_id)
        table.insert(color_row, {
            id = btn_id,
            text = " ",
            align = "center",
            font_size = 12,
            height = color_strip_h,
            background = bg_colors[j],
            checked_func = function()
                return currentColor(rh) == key
            end,
            enabled_func = function()
                return colorChoiceEnabled(rh)
            end,
            callback = function()
                rh.selected_text.color = key
                applyColorToDefaults(key)
                refreshButtonCheckmarks(compose_dialog, color_button_ids)
            end,
        })
    end
    table.insert(buttons, color_row)

    -- Styles + note (one row): compact glyphs and pencil.
    local style_row = {}
    for _, pair in ipairs(ReaderHighlight.getHighlightStyles()) do
        local _, key = unpack(pair)
        local btn_id = "hls_" .. key
        table.insert(style_button_ids, btn_id)
        table.insert(style_row, {
            id = btn_id,
            text = STYLE_COMPACT_GLYPH[key] or "·",
            align = "center",
            font_size = 20,
            height = mid_row_h,
            checked_func = function()
                return currentDrawer(rh) == key
            end,
            callback = function()
                rh.selected_text.drawer = key
                applyStyleToDefaults(key)
                refreshButtonCheckmarks(compose_dialog, style_button_ids)
                refreshButtonCheckmarks(compose_dialog, color_button_ids)
                for _, id in ipairs(color_button_ids) do
                    local b = compose_dialog:getButtonById(id)
                    if b then
                        b:enableDisable(colorChoiceEnabled(rh))
                        b:refresh()
                    end
                end
            end,
        })
    end
    table.insert(style_row, {
        text = "\u{F040}",
        align = "center",
        font_size = 20,
        height = mid_row_h,
        callback = openNoteEditor,
    })
    table.insert(buttons, style_row)

    -- Selection boundary controls (same glyphs as stock edit-highlight dialog)
    local change_boundaries_enabled = boundariesEnabled(rh)
    local start_prev, start_next, end_prev, end_next = "◁▒▒", "▷☓▒", "▒☓◁", "▒▒▷"
    if BD.mirroredUILayout() then
        start_prev, start_next = start_next, start_prev
        end_prev, end_next = end_next, end_prev
    end
    table.insert(buttons, {
        {
            text = start_prev,
            align = "center",
            font_size = 18,
            height = action_row_h,
            enabled = change_boundaries_enabled,
            callback = function()
                updatePendingBounds(rh, 0, -1, move_by_char)
            end,
            hold_callback = function()
                move_by_char = not move_by_char
                updatePendingBounds(rh, 0, -1, true)
            end,
        },
        {
            text = start_next,
            align = "center",
            font_size = 18,
            height = action_row_h,
            enabled = change_boundaries_enabled,
            callback = function()
                updatePendingBounds(rh, 0, 1, move_by_char)
            end,
            hold_callback = function()
                move_by_char = not move_by_char
                updatePendingBounds(rh, 0, 1, true)
            end,
        },
        {
            text = end_prev,
            align = "center",
            font_size = 18,
            height = action_row_h,
            enabled = change_boundaries_enabled,
            callback = function()
                updatePendingBounds(rh, 1, -1, move_by_char)
            end,
            hold_callback = function()
                move_by_char = not move_by_char
                updatePendingBounds(rh, 1, -1, true)
            end,
        },
        {
            text = end_next,
            align = "center",
            font_size = 18,
            height = action_row_h,
            enabled = change_boundaries_enabled,
            callback = function()
                updatePendingBounds(rh, 1, 1, move_by_char)
            end,
            hold_callback = function()
                move_by_char = not move_by_char
                updatePendingBounds(rh, 1, 1, true)
            end,
        },
    })

    -- Trash (delete saved highlight or discard new selection), then select / more / confirm
    table.insert(buttons, {
        {
            text = "\u{F48E}", -- trash can (same glyph as stock highlight editor)
            align = "center",
            font_size = 20,
            height = action_row_h,
            callback = function()
                closeCompose()
                if index then
                    rh:deleteHighlight(index)
                    rh.selected_text = nil
                else
                    rh:onClose()
                end
            end,
        },
        {
            text = index and _("Extend") or _("Select"),
            align = "center",
            font_size = 17,
            height = action_row_h,
            enabled = not (index and rh.ui.annotation.annotations[index].text_edited),
            callback = function()
                closeCompose()
                rh:startSelection(index)
                if not Device:isTouchDevice() then
                    rh:onStartHighlightIndicator()
                end
            end,
        },
        {
            text = "…",
            align = "center",
            font_size = 20,
            height = action_row_h,
            callback = function()
                closeCompose()
                showLegacyHighlightMenu(rh, index)
            end,
        },
        {
            text = "\u{2713}",
            align = "center",
            font_size = 20,
            height = action_row_h,
            callback = function()
                rh.selected_text.drawer = currentDrawer(rh)
                rh.selected_text.color = currentColor(rh)
                if pending_note and pending_note ~= "" then
                    rh.selected_text.note = pending_note
                else
                    rh.selected_text.note = nil
                end
                applyStyleToDefaults(currentDrawer(rh))
                applyColorToDefaults(currentColor(rh))
                closeCompose()
                if index then
                    applyComposeToSavedHighlight(rh, index, pending_note)
                    rh.selected_text = nil
                    UIManager:setDirty(rh.dialog, "ui")
                else
                    rh:saveHighlight(true)
                    rh:onClose()
                end
            end,
        },
    })

    compose_dialog = ButtonDialog:new{
        title = nil,
        buttons = buttons,
        colorful = true,
        width_factor = 0.94,
        shrink_unneeded_width = false,
        rows_per_page = { 5, 6, 7, 8 },
        anchor = function()
            return composeDialogAnchor(rh, compose_dialog, index)
        end,
        tap_close_callback = function()
            if rh.hold_pos then
                rh:clear()
            end
        end,
    }
    return compose_dialog
end

local function onShowHighlightMenuPatched(rh, index)
    if G_reader_settings:isTrue("highlight_compose_menu_disabled") then
        return orig_onShowHighlightMenu(rh, index)
    end
    if not rh.selected_text then
        return orig_onShowHighlightMenu(rh, index)
    end
    if rh.highlight_dialog then
        UIManager:close(rh.highlight_dialog)
        rh.highlight_dialog = nil
    end
    rh.highlight_dialog = buildComposeDialog(rh, index)
    UIManager:show(rh.highlight_dialog, "[ui]")
    return true
end

local function showHighlightNoteOrDialogPatched(rh, index)
    if G_reader_settings:isTrue("highlight_compose_menu_disabled") then
        return orig_showHighlightNoteOrDialog(rh, index)
    end
    rh.selected_text = util.tableDeepCopy(rh.ui.annotation.annotations[index])
    if rh.highlight_dialog then
        UIManager:close(rh.highlight_dialog)
        rh.highlight_dialog = nil
    end
    rh.highlight_dialog = buildComposeDialog(rh, index)
    UIManager:show(rh.highlight_dialog, "[ui]")
    return true
end

function HighlightComposePlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function HighlightComposePlugin:addToMainMenu(menu_items)
    menu_items.highlight_compose_menu = {
        text = _("Integrated highlight & note bar"),
        sorting_hint = "more_tools",
        checked_func = function()
            return not G_reader_settings:isTrue("highlight_compose_menu_disabled")
        end,
        callback = function()
            G_reader_settings:saveSetting("highlight_compose_menu_disabled",
                not G_reader_settings:isTrue("highlight_compose_menu_disabled"))
        end,
    }
end

-- Patch class methods once; applies to every ReaderHighlight instance.
if not ReaderHighlight.__highlight_compose_patched then
    ReaderHighlight.__highlight_compose_patched = true
    orig_onShowHighlightMenu = ReaderHighlight.onShowHighlightMenu
    ReaderHighlight.onShowHighlightMenu = onShowHighlightMenuPatched
    orig_showHighlightNoteOrDialog = ReaderHighlight.showHighlightNoteOrDialog
    ReaderHighlight.showHighlightNoteOrDialog = function(self, index)
        return showHighlightNoteOrDialogPatched(self, index)
    end
end

return HighlightComposePlugin
