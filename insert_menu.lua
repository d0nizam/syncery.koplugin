-- insert_menu.lua — position the Syncery entry inside the reader's Tools
-- tab, instead of letting it
-- fall to the bottom of the list.
--
-- KOReader builds each menu tab's order from a static table in
-- `ui/elements/*_menu_order`. A plugin entry whose key isn't listed there
-- is appended at the end of its sorting_hint section — which is why
-- "syncery" otherwise lands at the bottom of Tools. We splice the key in
-- at the desired spot at load time.
--
-- Syncery is NOT `is_doc_only` (see main.lua), so KOReader instantiates
-- it in both the READER and the FILE MANAGER. We therefore patch both
-- `reader_menu_order` and `filemanager_menu_order` so the entry appears
-- in Tools regardless of which context the user is in.
--
-- Target: between "Cloud storage(+)" (`cloudstorage`) and "Move to archive"
-- (`move_to_archive`). We anchor on the move_to_archive key and insert
-- BEFORE it, so Syncery sits just under Cloud storage. If the anchor is
-- not found (table reshaped upstream), we fall back to appending —
-- never erroring, never duplicating.

local KEY = "syncery"

local function splice(order)
    if type(order) ~= "table" or type(order.tools) ~= "table" then
        return
    end
    local tools = order.tools

    -- Guard against double-insertion (plugin reloaded, or already listed).
    for _, v in ipairs(tools) do
        if v == KEY then return end
    end

    -- Find the move_to_archive anchor and insert just before it, so
    -- Syncery falls between Cloud storage and Move to archive.
    local pos
    for index, value in ipairs(tools) do
        if value == "move_to_archive" then
            pos = index
            break
        end
    end

    if pos then
        table.insert(tools, pos, KEY)
    else
        -- Anchor missing (KOReader reshaped the table): append rather than
        -- guess a position. Still better than erroring at load.
        table.insert(tools, KEY)
    end
end

-- Patch both the reader and the file manager menus. Syncery is NOT
-- is_doc_only (see main.lua), so KOReader instantiates it in both
-- contexts and both tables need the key.
local ok_reader, reader_order = pcall(require, "ui/elements/reader_menu_order")
if ok_reader then splice(reader_order) end

local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
if ok_fm then splice(fm_order) end
