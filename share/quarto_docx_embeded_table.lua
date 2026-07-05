--- @diagnostic disable: undefined-global, unused-function, unused-local

local function debug(elem)
	quarto.log.output(elem)
end

local function get_elem(...)
	local args = { ... }
	local current = table.remove(args, 1)
	for _, key in ipairs(args) do
		if current[key] then
			current = current[key]
		else
			return nil
		end
	end
	return current
end

local function is_cjk_character(char)
	-- 获取字符的 Unicode 码点
	if not char then
		return
	end
	local code = utf8.codepoint(char)

	-- 检查并分类 CJK 字符
	if code >= 0x4E00 and code <= 0x9FFF then
		return true, "基本汉字 (CJK Unified Ideographs)"
	elseif code >= 0x3400 and code <= 0x4DBF then
		return true, "扩展汉字 A 区 (CJK Unified Ideographs Extension A)"
	elseif code >= 0x20000 and code <= 0x2A6DF then
		return true, "扩展汉字 B 区 (CJK Unified Ideographs Extension B)"
	elseif code >= 0x2A700 and code <= 0x2B73F then
		return true, "扩展汉字 C 区 (CJK Unified Ideographs Extension C)"
	elseif code >= 0x2B740 and code <= 0x2B81F then
		return true, "扩展汉字 D 区 (CJK Unified Ideographs Extension D)"
	elseif code >= 0x2B820 and code <= 0x2CEAF then
		return true, "扩展汉字 E 区 (CJK Unified Ideographs Extension E)"
	elseif code >= 0x2CEB0 and code <= 0x2EBEF then
		return true, "扩展汉字 F 区 (CJK Unified Ideographs Extension F)"
	elseif code >= 0x30000 and code <= 0x3134F then
		return true, "扩展汉字 G 区 (CJK Unified Ideographs Extension G)"
	elseif code >= 0xF900 and code <= 0xFAFF then
		return true, "兼容汉字 (CJK Compatibility Ideographs)"
	elseif code >= 0x2F00 and code <= 0x2FDF then
		return true, "汉字部首 (Kangxi Radicals)"
	elseif code >= 0x31C0 and code <= 0x31EF then
		return true, "汉字部件补充 (CJK Strokes)"
	elseif code >= 0x3100 and code <= 0x312F then
		return true, "注音符号 (Bopomofo)"
	elseif code >= 0x3040 and code <= 0x309F then
		return true, "平假名 (Hiragana)"
	elseif code >= 0x30A0 and code <= 0x30FF then
		return true, "片假名 (Katakana)"
	else
		return false, "非 CJK 字符"
	end
end

local function first_char(str)
	if not str or #str == 0 then
		return
	end
	return string.sub(str, 1, utf8.offset(str, 2) and utf8.offset(str, 2) - 1 or #str)
end

local function last_char(str)
	if not str or #str == 0 then
		return
	end
	local length = utf8.len(str)
	if not length then
		return
	end
	local lastCharStart = utf8.offset(str, length)
	return string.sub(str, lastCharStart)
end

local function filter_para(para)
	local cs = para.content

	local braket_need_alt = false
	for k, v in ipairs(cs) do
		-- Remove SoftBreak if adjacent character is cjk
		if v.t == "SoftBreak" and cs[k - 1] and cs[k + 1] then
			local p = last_char(cs[k - 1].text)
			local n = first_char(cs[k + 1].text)
			if p and n and is_cjk_character(p) and is_cjk_character(n) then
				para.content[k] = pandoc.Str("")
			end
		end

		-- Replace the brackets after Chinese with Chinese brackets.
		-- Requires space between Chinese characters and brackets
		if
			k >= 3
			and first_char(v.text) == "("
			and (not v.text:find("^%(%d+%)"))
			and (cs[k - 1].t == "Space" or cs[k - 1].t == "SoftBreak")
			and is_cjk_character(last_char(cs[k - 2].text))
		then
			v.text = "（" .. v.text:sub(2, -1)
			if v.text:find("%)") then
				if v.text:find("%)") == #v.text and (cs[k + 1].t == "Space" or cs[k + 1].t == "SoftBreak") then
					para.content[k + 1] = pandoc.Str("")
				end
				v.text = v.text:gsub("%)%s*", "）", 1)
			else
				braket_need_alt = true
			end
			para.content[k].text = v.text
			para.content[k - 1] = pandoc.Str("")
		end

		if braket_need_alt and v.text then
			local pos = v.text:find("%)")
			if pos then
				if pos == #v.text and (cs[k + 1].t == "Space" or cs[k + 1].t == "SoftBreak") then
					para.content[k + 1] = pandoc.Str("")
				end
				para.content[k].text = v.text:gsub("%)%s*", "）", 1)
				braket_need_alt = false
			end
		end
	end

	return para
end

local function filter_table(div)
	local elem = get_elem(div, "bodies", 1, "body", 1, "cells", 1, "contents", 1, "content")
	if not elem then
		return
	end

	local img = get_elem(elem, 1, "content", 1)
	if img and img.t == "Image" then
		if img.caption == nil or #img.caption == 0 then
			local caption = get_elem(elem, 2, "content")
			table.remove(caption, 1)
			local fig_caption = {
				long = pandoc.Blocks({ pandoc.Plain(caption) }),
			}
			local fig = pandoc.Figure(img, fig_caption)
			return fig
		end
	end

	if elem and elem[2] and elem[2].t == "Table" then
		if (elem[2].caption.long == nil or #elem[2].caption.long == 0) and get_elem(elem, 1, "content") then
			local caption = elem[1].content
			table.remove(caption, 1)
			elem[2].caption.long = pandoc.Blocks({ pandoc.Plain(caption) })
			return elem[2]
		end
	end
end

local function filter_link(elem)
	-- add braket arround number, 1 => (1)
	-- need to set crossref.ref-hyperlink: true
	if get_elem(elem, "attr", "classes", 1) == "quarto-xref" then
		local label = get_elem(elem, "content", 1, "text") or ""
		if label:match("^[0-9]$") then
			label = "(" .. label .. ")"
			return pandoc.Str(label)
		end
	end
end

local function filter_citation(elem)
	local cite_mode = get_elem(elem, "citations", 1, "mode")
	if cite_mode == "NormalCitation" then
		-- 普通方式引用中文文献时 [@小明2029], 应该使用中文括号包裹
		local first_author = elem.content[1].text:sub(2, -1)
		if is_cjk_character(first_char(first_author)) then
			elem.content[1].text = "（" .. first_author
			elem.content[#elem.content].text = elem.content[#elem.content].text:gsub("%)$", "）")
		end
	end

	for i = #elem.content - 1, 2, -1 do
		local val = elem.content[i]
		if
			-- 参考文献是英文时，将 '等' 改为 'et.al'
			val.t == "Str"
			and (val.text == "等" or val.text == "等,")
			and elem.content[i - 1].t == "Space"
			and elem.content[i - 2]
			and elem.content[i - 2].t == "Str"
			and not is_cjk_character(last_char(elem.content[i - 2].text))
		then
			elem.content[i].text = "et al."
		end
		if
			-- 参考文献是中文时，将姓名和等之间的空格去掉
			val.t == "Space"
			and elem.content[i - 1]
			and elem.content[i - 1].t == "Str"
			and is_cjk_character(last_char(elem.content[i - 1].text))
			and elem.content[i + 1]
			and elem.content[i + 1].t == "Str"
			and is_cjk_character(first_char(elem.content[i + 1].text))
		then
			elem.content:remove(i)
		end
	end
	return elem
end

local function filter_div(elem)
	local content = get_elem(elem, "content", 1, "content")
	if get_elem(elem, "attr", "classes", 1) == "csl-entry" and content then
		-- 参考文献列表中，英文参考文献中作者列表中的「等」需要改为 「et al」
		for i = #content - 1, 3, -1 do
			local v = content[i]
			if
				v.t == "Str"
				and v.text == "等."
				and content[i - 1]
				and content[i - 1].t == "Space"
				and content[i - 2]
				and last_char(content[i - 2].text) == ","
			then
				if not is_cjk_character(last_char(content[i - 2].text:sub(1, -2))) then
					elem.content[1].content[i].text = "et al."
				end
			end
		end
	end
	return elem
end

local function filter_orderedlist(elem)
	-- 解决 '(1)' 被解释为列表标记的问题
	local content = next(get_elem(elem, "content", 1, "content") or {})
	if content then
		return elem
	end
	local delimiter = get_elem(elem, "listAttributes", "delimiter")
	local start = get_elem(elem, "listAttributes", "start")
	if delimiter and delimiter == "TwoParens" and start then
		return pandoc.Plain(string.format("(%s)", start))
	end
end

local function filter_math(elem)
	debug(elem)
end

return {
	{
		Link = filter_link,
		Para = filter_para,
		OrderedList = filter_orderedlist,
		Table = filter_table,
		Cite = filter_citation,
		Div = filter_div,
	},
}
