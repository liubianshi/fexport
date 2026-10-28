local function is_test_table(div)
  if next(div.content) == nil then return false end
  return div and div.content and div.content[1].t == "Table"
      and pandoc.utils.stringify(div):sub(-8, -1) == "testtest"
end

local function gen_new_div_from_test_table(div)
  local caption = div.content[1].caption.long
  local identifier = div.identifier
  return pandoc.Div(caption, pandoc.Attr(identifier))
end

function Div (div)
  if is_test_table(div) then
    return gen_new_div_from_test_table(div)
  end
end
