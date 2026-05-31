---@diagnostic disable: undefined-global

local function smart_next()
	local current_chapter = mp.get_property_number("chapter")
	local chapter_count = mp.get_property_number("chapter-list/count")

	mp.osd_message("chapter: " .. tostring(current_chapter) .. " / count: " .. tostring(chapter_count), 3)

	if current_chapter == nil or chapter_count == nil or chapter_count == 0 or current_chapter >= chapter_count - 1 then
		mp.commandv("playlist-next", "force")
	else
		mp.commandv("add", "chapter", "1")
	end
end

local function smart_prev()
	local current_chapter = mp.get_property_number("chapter")
	local chapter_count = mp.get_property_number("chapter-list/count")

	mp.osd_message("chapter: " .. tostring(current_chapter) .. " / count: " .. tostring(chapter_count), 3)

	if current_chapter == nil or chapter_count == nil or chapter_count == 0 or current_chapter <= 0 then
		mp.commandv("playlist-prev", "force")
	else
		mp.commandv("add", "chapter", "-1")
	end
end

mp.add_key_binding(nil, "smart-next", smart_next)
mp.add_key_binding(nil, "smart-prev", smart_prev)
