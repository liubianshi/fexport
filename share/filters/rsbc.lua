local function is_space_before_author_in_text(str, spc, cite)
  return spc and spc.t == 'Space'
    and cite and cite.t == 'Cite'
    -- there must be only a single citation, and it must have
    -- mode 'AuthorInText'
    and #cite.citations == 1
    and cite.citations[1].mode == 'AuthorInText'
    and str and str.t == 'Str'
    and not str.text:find "[%a%d%p]"
end

function Inlines (inlines)
  -- Go from end to start to avoid problems with shifting indices.
  for i = #inlines-1, 1, -1 do
    if is_space_before_author_in_text(inlines[i-1], inlines[i], inlines[i+1]) then
        inlines:remove(i)
    end
  end
  return inlines
end
