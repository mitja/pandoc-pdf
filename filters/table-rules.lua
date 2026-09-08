-- Companion filter for pandoc-pdf.yaml: a hairline between table rows.
--
-- Pandoc styles tables with booktabs, which rules the head and the foot but
-- deliberately leaves the body open. That reads well for a handful of rows and
-- badly for twenty, where the eye loses the line it is on.
--
-- There is no option for this and no rule-every-row package in BasicTeX, but
-- pandoc writes each row as `cell & cell \\`, and TeX accepts \noalign material
-- immediately after that. So the rule travels as raw LaTeX at the very front of
-- each row's first cell, where it lands between the rows rather than inside one.
-- \rowrule itself is defined in the header-includes of pandoc-pdf.yaml, which
-- also loads the colortbl package it needs.
--
-- Switch it off with `table-row-rules: false` in the metadata.

local RULE = "\\rowrule "

local function rule_inline()
  return pandoc.RawInline("latex", RULE)
end

-- Pandoc wraps a cell in a minipage as soon as it holds anything richer than
-- paragraphs — a list, say. Raw LaTeX in such a cell would end up inside the
-- minipage, where \noalign is an error rather than a rule, so those rows are
-- left unruled. Cells written as pipe tables are always a single Plain, so this
-- only gives way for grid and HTML tables that put a list in the first column.
local function takes_raw(cell)
  for _, block in ipairs(cell.contents) do
    if block.t ~= "Plain" and block.t ~= "Para" then return false end
  end
  return true
end

local function mark_row(row)
  local cell = row.cells[1]
  if not cell or not takes_raw(cell) then return end

  local blocks = cell.contents
  local first = blocks[1]
  if first then
    -- Into the leading paragraph, so the rule is the row's first material.
    first.content:insert(1, rule_inline())
    blocks[1] = first
  else
    blocks:insert(1, pandoc.Plain({ rule_inline() })) -- an empty cell
  end
  cell.contents = blocks
end

local function rule_table(tbl)
  -- Every row but the first: the head already sits above that one on a \midrule.
  local first = true
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      if first then first = false else mark_row(row) end
    end
  end
  return tbl
end

function Pandoc(doc)
  if not FORMAT:match("latex") then return nil end
  if doc.meta["table-row-rules"] == false then return nil end

  return doc:walk({ Table = rule_table })
end
