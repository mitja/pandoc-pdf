-- Companion filter for pandoc-pdf.yaml: size table columns by their content.
--
-- Pandoc takes column widths from the *markdown source* — the number of dashes
-- in a pipe table's separator row. Those dashes describe the source file, not
-- the content, so `|--|--|--|` yields equally wide columns and a "RAM" column
-- gets as much room as one holding a paragraph. This filter throws the source
-- widths away and measures the cells instead:
--
--   * estimate the typeset width of every cell from its characters (per-class
--     widths fitted against XeLaTeX, see CHAR_EM below);
--   * if the table fits on one line, emit no widths at all, so LaTeX sizes the
--     columns naturally and the table stays compact;
--   * otherwise apply the rule the tabulary package uses: columns narrower than
--     their fair share keep their natural width, and the rest share what is left
--     in proportion to how much text they hold. That evens out row heights
--     rather than column widths, which is what makes a wide table readable;
--   * lift any column that share would leave too narrow to read back to a
--     readable width, as far as the page allows. Proportional shares alone let
--     one very long cell in one column starve a column of ordinary sentences;
--   * if the widest unbreakable words still do not fit — many columns, or cells
--     holding paths and identifiers — step down through \small and a tighter
--     \tabcolsep until they do, and allow line breaks inside long slug-like
--     words so that a column is never forced wider than the page.
--
-- Opt out for one table by giving it a `fixed-widths` class, or everywhere with
-- `table-autowidth: false` in the metadata.

-- Average advance width per character class, in em. Fitted by least squares
-- against XeLaTeX measurements of 50 real table cells set in Charter 11pt:
-- 1.9% mean error on the strings long enough to drive a column width. Any serif
-- text face is close enough; only the ratios between these matter.
local CHAR_EM = {
  space = 0.379,
  digit = 0.562,
  wide = 0.789, -- m w M W % & @
  upper = 0.619,
  narrow = 0.302, -- i l j t f r and thin punctuation
  other = 0.502,
  mono = 0.529, -- Menlo at Scale=MatchLowercase, measured
}

local NARROW = {}
for c in ("iljtfr.,;:!'|()[]{}-/"):gmatch(".") do NARROW[c] = true end
local WIDE = { m = true, w = true, M = true, W = true, ["%"] = true, ["&"] = true, ["@"] = true }

-- Characters a long word may be broken after, once we have inserted the
-- corresponding \allowbreak. TeX already breaks at explicit hyphens.
local BREAK_AFTER = { ["/"] = true, ["_"] = true }
local BREAK_MIN_CHARS = 12 -- shorter words are left alone

local OPT_OUT_CLASS = "fixed-widths"

local UNIT_PT = { pt = 1, bp = 1.00375, mm = 2.845276, cm = 28.45276, ["in"] = 72.27, pc = 12 }

local DEFAULT_LINE_WIDTH_PT = 426.8 -- A4 less the 30mm margins of pandoc-pdf.yaml
local DEFAULT_FONT_SIZE_PT = 11
local DEFAULT_TABCOLSEP_PT = 6.0 -- LaTeX default; pandoc reserves 2*(cols-1) of them
local MAX_FLOOR_EM = 8.0 -- longest word we hold room for; past that, let it hyphenate

-- Below roughly fifteen characters a column of prose stops reading as a column,
-- however fair its share of the page is by line count. A column whose content
-- has to wrap is lifted to this width when the budget can spare it, taking the
-- difference from the columns that have width to give.
local READABLE_EM = 8.0

-- Headroom on every measurement. The relative error of the estimate is largest
-- on short strings, where an extra fraction of an em costs almost nothing, so
-- the allowance is mostly a fixed pad and only slightly proportional.
local SLACK = 1.03
local PAD_EM = 0.3

-- Ways to buy a crowded table more room, least intrusive first. `scale` is the
-- resulting font size relative to the body size.
local LADDER = {
  { cmd = nil, scale = 1.00, colsep = DEFAULT_TABCOLSEP_PT },
  { cmd = "\\small", scale = 0.91, colsep = DEFAULT_TABCOLSEP_PT },
  { cmd = "\\small", scale = 0.91, colsep = 4.0 },
  { cmd = "\\footnotesize", scale = 0.82, colsep = 4.0 },
}

local function char_width(c, mono)
  if mono then return CHAR_EM.mono end
  if c == " " then return CHAR_EM.space end
  if c >= "0" and c <= "9" then return CHAR_EM.digit end
  if WIDE[c] then return CHAR_EM.wide end
  if c >= "A" and c <= "Z" then return CHAR_EM.upper end
  if NARROW[c] then return CHAR_EM.narrow end
  return CHAR_EM.other
end

-- Accumulates the width of the longest line and of the longest unbreakable word.
local function new_ruler()
  local self = { line = 0, max_line = 0, word = 0, max_word = 0 }

  function self.break_word()
    if self.word > self.max_word then self.max_word = self.word end
    self.word = 0
  end

  function self.newline()
    self.break_word()
    if self.line > self.max_line then self.max_line = self.line end
    self.line = 0
  end

  function self.space()
    self.break_word()
    self.line = self.line + CHAR_EM.space
  end

  -- `breakable` mirrors the \allowbreak we insert into long words, so that the
  -- measured floor matches what LaTeX will actually be able to break.
  function self.add(s, mono, breakable)
    for _, cp in utf8.codes(s) do
      local c = utf8.char(cp)
      local w = char_width(c, mono)
      self.line = self.line + w
      if c == " " or c == "\t" then
        self.break_word()
      else
        self.word = self.word + w
        if breakable and BREAK_AFTER[c] then self.break_word() end
      end
    end
  end

  return self
end

local function is_long(text)
  return (utf8.len(text) or #text) >= BREAK_MIN_CHARS
end

local walk_blocks

local function walk_inlines(inlines, ruler)
  for _, il in ipairs(inlines) do
    local t = il.t
    if t == "Str" then
      ruler.add(il.text, false, is_long(il.text))
    elseif t == "Space" or t == "SoftBreak" then
      ruler.space()
    elseif t == "LineBreak" then
      ruler.newline()
    elseif t == "Code" then
      ruler.add(il.text, true, is_long(il.text))
    elseif t == "Math" then
      ruler.add(il.text, false, false)
    elseif t == "Note" then
      ruler.add("1", false, false) -- only the footnote mark is set in the cell
    elseif t == "Image" then
      walk_inlines(il.caption, ruler)
    elseif t ~= "RawInline" and il.content ~= nil then
      walk_inlines(il.content, ruler)
    end
  end
end

walk_blocks = function(blocks, ruler)
  for _, b in ipairs(blocks) do
    local t = b.t
    if t == "Para" or t == "Plain" or t == "Header" then
      ruler.newline()
      walk_inlines(b.content, ruler)
      ruler.newline()
    elseif t == "CodeBlock" then
      for line in (b.text .. "\n"):gmatch("([^\n]*)\n") do
        ruler.newline()
        ruler.add(line, true, false)
      end
      ruler.newline()
    elseif t == "LineBlock" then
      for _, line in ipairs(b.content) do
        ruler.newline()
        walk_inlines(line, ruler)
      end
      ruler.newline()
    elseif t == "BulletList" or t == "OrderedList" then
      for _, item in ipairs(b.content) do
        ruler.newline()
        walk_blocks(item, ruler)
      end
      ruler.newline()
    elseif t == "BlockQuote" or t == "Div" or t == "Figure" then
      walk_blocks(b.content, ruler)
    end
  end
end

-- Longest line and longest unbreakable word of a cell, in em.
local function measure(blocks)
  local ruler = new_ruler()
  walk_blocks(blocks, ruler)
  ruler.newline()
  return ruler.max_line, ruler.max_word
end

-- Let LaTeX break inside long slug-like words: `a/b` becomes `a/`, \allowbreak,
-- `b`. Splitting into several Str/Code inlines leaves the escaping to pandoc.
local function split_word(text, make)
  local parts, from = pandoc.Inlines({}), 1
  for at in text:gmatch("()[/_]") do
    parts:insert(make(text:sub(from, at)))
    parts:insert(pandoc.RawInline("latex", "\\allowbreak{}"))
    from = at + 1
  end
  if from <= #text then parts:insert(make(text:sub(from))) end
  return parts
end

-- Applied through pandoc's own walk, which already descends into nested lists.
local function add_break_points(inlines)
  local out = pandoc.Inlines({})
  for _, il in ipairs(inlines) do
    if (il.t == "Str" or il.t == "Code") and is_long(il.text) and il.text:find("[/_]") then
      local make = il.t == "Str" and pandoc.Str or function(s) return pandoc.Code(s, il.attr) end
      out:extend(split_word(il.text, make))
    else
      out:insert(il)
    end
  end
  return out
end

local function each_row(tbl, fn)
  for _, row in ipairs(tbl.head.rows) do fn(row) end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.head) do fn(row) end
    for _, row in ipairs(body.body) do fn(row) end
  end
  for _, row in ipairs(tbl.foot.rows) do fn(row) end
end

-- Natural width and minimum width of every column, in em.
local function column_metrics(tbl, ncols)
  local natural, floor = {}, {}
  for i = 1, ncols do natural[i], floor[i] = 0, 0 end

  each_row(tbl, function(row)
    local col = 1
    for _, cell in ipairs(row.cells) do
      local span = math.max(1, cell.col_span or 1)
      local line, word = measure(cell.contents)
      -- A spanning cell says nothing about a single column; share it out evenly.
      line, word = line / span, word / span
      for i = col, math.min(col + span - 1, ncols) do
        if line > natural[i] then natural[i] = line end
        if word > floor[i] then floor[i] = word end
      end
      col = col + span
    end
  end)

  for i = 1, ncols do
    natural[i] = natural[i] * SLACK + PAD_EM
    floor[i] = math.min(floor[i] * SLACK + PAD_EM, MAX_FLOOR_EM, natural[i])
  end
  return natural, floor
end

-- Splits `budget` em between the columns, as fractions of the text area.
local function allocate(natural, floor, budget)
  local ncols = #natural
  local width, pinned, npinned = {}, 0, 0

  -- What each column is worth being held at: never less than its widest word,
  -- and, for a column whose text wraps, a width still readable as a column.
  local wanted, needed = {}, 0
  for i = 1, ncols do
    wanted[i] = math.max(floor[i], math.min(READABLE_EM, natural[i]))
    needed = needed + floor[i]
  end

  -- Pin every column at a width it must not fall below: its natural width, when
  -- that is under the fair share, or else the width it is worth holding. What is
  -- left over is shared among the columns still free, in proportion to how much
  -- text they hold. Each pin shrinks that pool, which can bring a further column
  -- under the fair share or under its own minimum, so repeat until the set stops
  -- growing. Pinning rather than fixing up at the end matters: a column that is
  -- exactly as wide as its content has nothing left to give.
  repeat
    local rest = budget - pinned
    local flex = 0
    for i = 1, ncols do
      if not width[i] then flex = flex + natural[i] end
    end
    local fair = rest / (ncols - npinned)

    local pin = {}
    for i = 1, ncols do
      if not width[i] then
        if natural[i] <= fair then
          pin[i] = natural[i]
        elseif rest * natural[i] / flex < wanted[i] then
          -- Hold it at the readable width only while every other column can
          -- still be given its own widest word; otherwise settle for that word.
          local others = needed - floor[i]
          if wanted[i] + others <= rest then pin[i] = wanted[i] else pin[i] = floor[i] end
        end
      end
    end

    local changed = false
    for i, w in pairs(pin) do
      width[i], pinned, npinned, changed = w, pinned + w, npinned + 1, true
      needed = needed - floor[i]
    end
  until not changed or npinned == ncols

  local rest = math.max(budget - pinned, 0)
  local flex = 0
  for i = 1, ncols do
    if not width[i] then flex = flex + natural[i] end
  end

  local sum = 0
  for i = 1, ncols do
    width[i] = width[i] or math.max(rest * natural[i] / flex, floor[i])
    sum = sum + width[i]
  end

  -- Normalise onto the text area. Should the pins alone have overrun the
  -- budget, every column gives up the same share rather than one taking it all.
  for i = 1, ncols do width[i] = width[i] / sum end
  return width
end

local function budget_em(cfg, ncols, level)
  local gutters = 2 * (ncols - 1) * level.colsep
  return (cfg.line_width - gutters) / (cfg.font_size * level.scale)
end

local function size_table(tbl, cfg)
  if tbl.attr and tbl.attr.classes:includes(OPT_OUT_CLASS) then return nil end

  local ncols = #tbl.colspecs
  if ncols == 0 then return nil end

  local natural, floor = column_metrics(tbl, ncols)
  local total, min_total = 0, 0
  for i = 1, ncols do
    total = total + natural[i]
    min_total = min_total + floor[i]
  end

  -- Full size if the table already fits; otherwise the first step of the ladder
  -- on which the widest words do have room, so columns are not squeezed below
  -- what their content can physically occupy.
  local level = LADDER[1]
  if total > budget_em(cfg, ncols, level) then
    for _, candidate in ipairs(LADDER) do
      level = candidate
      if min_total <= budget_em(cfg, ncols, candidate) then break end
    end
  end

  local budget = budget_em(cfg, ncols, level)
  local widths
  if total > budget then widths = allocate(natural, floor, budget) end

  local colspecs = {}
  for i, spec in ipairs(tbl.colspecs) do
    -- A one-element pair is ColWidthDefault: let LaTeX size the column itself,
    -- which keeps a table that already fits from being stretched across the page.
    colspecs[i] = widths and { spec[1], widths[i] } or { spec[1] }
  end
  tbl.colspecs = colspecs

  each_row(tbl, function(row)
    for _, cell in ipairs(row.cells) do
      cell.contents = cell.contents:walk({ Inlines = add_break_points })
    end
  end)

  if level == LADDER[1] then return tbl end

  local opening = "\\begingroup" .. (level.cmd or "")
  if level.colsep ~= DEFAULT_TABCOLSEP_PT then
    opening = opening .. string.format("\\setlength{\\tabcolsep}{%gpt}", level.colsep)
  end
  return {
    pandoc.RawBlock("latex", opening),
    tbl,
    pandoc.RawBlock("latex", "\\endgroup"),
  }
end

local function to_pt(value)
  if value == nil then return nil end
  local num, unit = pandoc.utils.stringify(value):match("^%s*(%-?%d*%.?%d+)%s*(%a*)%s*$")
  if not num then return nil end
  local factor = unit == "" and 1 or UNIT_PT[unit:lower()]
  return factor and tonumber(num) * factor or nil
end

function Pandoc(doc)
  if not FORMAT:match("latex") then return nil end
  if doc.meta["table-autowidth"] == false then return nil end

  local cfg = {
    line_width = to_pt(doc.meta["table-line-width"]) or DEFAULT_LINE_WIDTH_PT,
    font_size = to_pt(doc.meta["table-font-size"]) or DEFAULT_FONT_SIZE_PT,
  }

  -- Pipe tables cannot carry attributes of their own, so the opt-out is written
  -- as a fenced div around the table. Move the class onto the tables inside it.
  doc = doc:walk({
    Div = function(div)
      if not div.classes:includes(OPT_OUT_CLASS) then return nil end
      return div:walk({
        Table = function(tbl)
          tbl.attr.classes:insert(OPT_OUT_CLASS)
          return tbl
        end,
      })
    end,
  })

  return doc:walk({ Table = function(tbl) return size_table(tbl, cfg) end })
end
