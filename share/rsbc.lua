-- rsbc.lua
-- 1. Removes spaces (and soft breaks) between CJK characters (including punctuation).
-- 2. Adds spaces between CJK Ideographs and Latin/Numbers.

local function is_cjk_generalized(text)
  -- Matches CJK Unified Ideographs + Punctuation + Kana
  -- Range approx U+3000 to U+9FFF
  -- UTF-8 bytes: E3 80 80 (U+3000) to E9 BF BF (U+9FFF)
  -- Byte 1: E3 to E9 (227 to 233)
  if not text then return false end
  return text:match("[\227-\233][\128-\191][\128-\191]")
end

local function is_cjk_ideograph(text)
  -- Matches CJK Unified Ideographs ONLY (approx 4E00-9FFF)
  -- Byte 1: E4 to E9 (228 to 233)
  if not text then return false end
  return text:match("[\228-\233][\128-\191][\128-\191]")
end

local function is_latin_digit(text)
  if not text then return false end
  return text:match("^[A-Za-z0-9]+$")
end

function Inlines(inlines)
  local new_inlines = {}
  
  -- Pass 1: Remove spaces between CJK (Generalized)
  for i, el in ipairs(inlines) do
    local handle_remove = false
    
    if el.t == 'Space' or el.t == 'SoftBreak' then
      local prev_el = new_inlines[#new_inlines] -- Element before space
      local next_el = inlines[i+1]              -- Element after space
      
      if prev_el and next_el and prev_el.t == 'Str' and next_el.t == 'Str' then
         local p_txt = prev_el.text
         local n_txt = next_el.text
         -- Check last char of prev and first char of next
         local p_char = p_txt:match("[\227-\233][\128-\191][\128-\191]$")
         local n_char = n_txt:match("^[\227-\233][\128-\191][\128-\191]")
         
         if p_char and n_char then
           handle_remove = true 
         end
      end
    end
    
    if not handle_remove then
      table.insert(new_inlines, el)
    end
  end
  
  -- Pass 2: Add spaces between CJK IDEOGRAPHS and Latin/Digit
  -- We process the list from Pass 1
  local res = {}
  for i, el in ipairs(new_inlines) do
    table.insert(res, el)
    local next_el = new_inlines[i+1]
    
    if el.t == 'Str' and next_el and next_el.t == 'Str' then
       local p_txt = el.text
       local n_txt = next_el.text
       
       -- Use Strict Ideograph check for Adding Spaces
       -- We do NOT want to add space after Punctuation (E3...)
       
       local p_end_cjk = p_txt:match("[\228-\233][\128-\191][\128-\191]$")
       local n_start_cjk = n_txt:match("^[\228-\233][\128-\191][\128-\191]")
       
       local p_end_lat = p_txt:match("[A-Za-z0-9]$")
       local n_start_lat = n_txt:match("^[A-Za-z0-9]")
       
       -- Case 1: CJK Ideograph + Latin
       if p_end_cjk and n_start_lat then
         table.insert(res, pandoc.Space())
       end
       
       -- Case 2: Latin + CJK Ideograph
       if p_end_lat and n_start_cjk then
         table.insert(res, pandoc.Space())
       end
    end
  end
  
  return res
end
