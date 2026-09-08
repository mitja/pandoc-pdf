-- Renders ```mermaid blocks as diagrams.
--
-- Pandoc has no idea what mermaid is and sets the block as source code. This
-- turns each one into a vector diagram instead, without adding a toolchain:
-- headless Chrome draws it with a copy of mermaid.min.js found on disk, and
-- rsvg-convert turns the SVG into a PDF that XeLaTeX can embed.
--
-- Two things have to be corrected on the way out of the browser. Mermaid sets
-- labels as HTML in a <foreignObject>, which librsvg cannot draw and which would
-- leave every shape empty, so the diagram is rendered with htmlLabels off. And
-- the SVG it produces carries width="100%" with the real size only in the
-- viewBox, which librsvg renders at a default size, so the width and height are
-- written back onto the root element.
--
-- Diagrams are cached by the hash of their source, so a rebuild only pays for
-- the blocks that actually changed. If Chrome, the library or rsvg-convert are
-- missing, the block is left as source code and a warning is printed -- the
-- document still builds.
--
-- Switch it off with `mermaid: false` in the metadata.

local CACHE = (os.getenv("TMPDIR") or "/tmp/") .. "pandoc-mermaid/"

local CHROMES = {
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "google-chrome",
  "chromium",
}

-- Mermaid's own defaults, minus the HTML labels librsvg cannot draw.
local MERMAID_CONFIG = [[{
  startOnLoad: false, theme: 'neutral', htmlLabels: false,
  flowchart: { htmlLabels: false }, er: { htmlLabels: false },
  gantt: { axisFormat: '%m-%d' },
  fontFamily: 'Helvetica, Arial, sans-serif'
}]]

local function absolute(path)
  if path:sub(1, 1) == "/" then return path end
  return pandoc.system.get_working_directory() .. "/" .. path
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function on_path(cmd)
  return os.execute("command -v " .. string.format("%q", cmd) .. " >/dev/null 2>&1")
end

local function find_chrome(override)
  if override then return exists(override) and override or nil end
  for _, c in ipairs(CHROMES) do
    if c:sub(1, 1) == "/" then
      if exists(c) then return c end
    elseif on_path(c) then
      return c
    end
  end
  return nil
end

-- Where to look for mermaid.min.js, in order: a vendor copy kept beside the
-- filters, then upwards from the document for a Hugo theme's copy or an npm
-- install. `mermaid-library` in the metadata overrides all of it.
-- Places a copy of mermaid.min.js is looked for, in order: a vendor directory
-- beside the filters, then upwards from the document for a vendor directory, an
-- npm install, a Hugo theme's copy, or a site's static files. Setting
-- `mermaid-library` in the metadata skips all of it.
local function candidates_in(dir)
  local list = {
    dir .. "/vendor/mermaid.min.js",
    dir .. "/node_modules/mermaid/dist/mermaid.min.js",
    dir .. "/static/js/mermaid.min.js",
  }
  -- Hugo puts it under a theme, whose name is not known in advance.
  local themes = dir .. "/themes"
  local ok, entries = pcall(pandoc.system.list_directory, themes)
  if ok and entries then
    for _, name in ipairs(entries) do
      list[#list + 1] = themes .. "/" .. name .. "/assets/lib/mermaid/mermaid.min.js"
    end
  end
  return list
end

local function find_library(start)
  local own = absolute(PANDOC_SCRIPT_FILE or "."):match("^(.*)/[^/]*$")
  if own and exists(own .. "/../vendor/mermaid.min.js") then
    return own .. "/../vendor/mermaid.min.js"
  end

  local dir = start
  for _ = 1, 10 do
    dir = dir:match("^(.*)/[^/]*$")
    if not dir or dir == "" then break end
    for _, candidate in ipairs(candidates_in(dir)) do
      if exists(candidate) then return candidate end
    end
  end
  return nil
end

local function write_file(path, text)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(text)
  f:close()
  return true
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function page(library, source)
  -- json.encode gives a JS string literal; </ is broken up so that a diagram
  -- containing </script> cannot close the tag it is written into.
  local literal = pandoc.json.encode(source):gsub("</", "<\\/")
  return table.concat({
    '<!doctype html><html><head><meta charset="utf-8">',
    '<style>body{margin:0;background:#fff}</style>',
    '<script src="file://', library, '"></script></head><body><div id="d"></div>',
    '<script>const src=', literal, ';',
    '(async()=>{try{mermaid.initialize(', MERMAID_CONFIG, ');',
    'const r=await mermaid.render("m",src);',
    'document.body.innerHTML=r.svg;document.title="OK";}',
    'catch(e){document.title="ERR "+(e&&e.message||e);}})();',
    '</script></body></html>',
  })
end

-- librsvg needs a real size on the root and needs to be told to keep the spaces
-- between the tspans mermaid splits each label into.
local function fix_svg(svg)
  local head_end = svg:find(">", 1, true)
  if not head_end then return nil end
  local head = svg:sub(1, head_end)

  local w, h = head:match('viewBox="[%d%.%-+eE]+%s+[%d%.%-+eE]+%s+([%d%.%-+eE]+)%s+([%d%.%-+eE]+)"')
  if not w then return nil end

  -- Diagrams that place an icon reference it with xlink:href, but the browser
  -- does not always serialise the namespace that goes with it.
  if svg:find("xlink:", 1, true) and not head:find("xmlns:xlink", 1, true) then
    head = head:sub(1, -2) .. ' xmlns:xlink="http://www.w3.org/1999/xlink">'
  end

  head = head:gsub('%s+width="[^"]*"', ""):gsub('%s+height="[^"]*"', "")
  head = head:gsub('max%-width:[^;"]*;?', "")
  head = head:sub(1, -2) .. string.format(' width="%spx" height="%spx">', w, h)

  local body = svg:sub(head_end + 1)

  -- Mermaid wraps a label as <switch><foreignObject>HTML</foreignObject><text>
  -- the same label</text></switch>. librsvg takes the foreignObject branch,
  -- cannot draw it, and never reaches the text that was put there for exactly
  -- this case, so the label disappears. Dropping the foreignObject uncovers it.
  body = body:gsub("<foreignObject.-</foreignObject>", "")

  body = body:gsub("<text ", '<text xml:space="preserve" '):gsub("<text>", '<text xml:space="preserve">')

  -- Mermaid escapes a label once for HTML and puts the result in the SVG text
  -- too, where the browser's serialiser escapes it again, so <<satisfies>>
  -- arrives as &amp;lt;&amp;lt;satisfies&amp;gt;&amp;gt; and would be set
  -- literally. Only the five entities XML defines are unwrapped, plus numeric
  -- ones: turning anything else back into a bare & would break the parse.
  for _, entity in ipairs({ "lt", "gt", "quot", "apos" }) do
    body = body:gsub("&amp;" .. entity .. ";", "&" .. entity .. ";")
  end
  body = body:gsub("&amp;(#%d+);", "&%1;")
  body = body:gsub("&amp;amp;", "&amp;")

  -- Edge labels sit on a rect that punches the line out from behind them. It is
  -- given no fill, which in SVG means black, and mermaid gets away with it
  -- because the rect belongs to the same branch the browser never draws. Now
  -- that the branch is the one being drawn, it has to be painted.
  body = body:gsub('<rect%s[^>]*>', function(tag)
    if not (tag:find('class="[^"]*background') or tag:find('class="[^"]*labelBkg')) then
      return tag
    end
    if tag:find('style="', 1, true) then
      return (tag:gsub('style="', 'style="fill:#fff;', 1))
    end
    return tag:sub(1, -2) .. ' style="fill:#fff">'
  end)

  -- Those uncovered labels carry the same task-type-N / section-type-N class as
  -- the box behind them, and the class sets the box's pale fill -- which on the
  -- text means near-white on near-white. The browser never showed it, having
  -- drawn the HTML label instead. An inline style outranks the stylesheet.
  body = body:gsub("<text%s[^>]*>", function(tag)
    if not (tag:find('class="[^"]*task%-type%-%d') or tag:find('class="[^"]*section%-type%-%d')) then
      return tag
    end
    if tag:find('style="', 1, true) then
      return (tag:gsub('style="', 'style="fill:#333;', 1))
    end
    return tag:sub(1, -2) .. ' style="fill:#333">'
  end)

  return head .. body
end

local warned = {}
local function warn_once(message)
  if warned[message] then return end
  warned[message] = true
  io.stderr:write("[pandoc-mermaid] " .. message .. "\n")
end

local function render(source, cfg)
  -- The config belongs in the key: change it and every diagram must be redrawn.
  local key = pandoc.utils.sha1(source .. cfg.library .. MERMAID_CONFIG)
  local pdf = CACHE .. key .. ".pdf"
  if exists(pdf) then return pdf end

  local html = CACHE .. key .. ".html"
  if not write_file(html, page(cfg.library, source)) then
    warn_once("cannot write to " .. CACHE)
    return nil
  end

  -- No --user-data-dir: pointing Chrome at a profile of its own makes it hang
  -- here rather than render, so it runs against the default one, which it opens
  -- read-only in headless mode. `timeout` is a guard for the same reason -- a
  -- wedged browser must not be able to hang the build.
  local dom = CACHE .. key .. ".dom"
  local command = string.format(
    "%s%q --headless --disable-gpu --no-sandbox --no-first-run --no-default-browser-check "
      .. "--disable-extensions --disable-background-networking --disable-sync "
      .. "--virtual-time-budget=15000 --dump-dom %q > %q 2>/dev/null",
    cfg.timeout, cfg.chrome, "file://" .. html, dom)
  os.execute(command)

  local rendered = read_file(dom)
  if not rendered then
    warn_once("Chrome produced no output; leaving diagrams as code")
    return nil
  end

  local message = rendered:match("<title>ERR ([^<]*)</title>")
  if message then
    warn_once("mermaid could not parse a diagram: " .. message)
    return nil
  end

  -- Greedy on purpose: an architecture diagram nests <svg> icons inside itself,
  -- and stopping at the first </svg> would cut the document in half. The body
  -- holds nothing but the diagram, so the last </svg> is the right one.
  local from, to = rendered:find("<svg.*</svg>")
  if not from then
    warn_once("no diagram came back from Chrome; leaving diagrams as code")
    return nil
  end

  local svg = fix_svg(rendered:sub(from, to))
  if not svg then
    warn_once("the diagram had no usable viewBox")
    return nil
  end

  local svg_path = CACHE .. key .. ".svg"
  if not write_file(svg_path, svg) then return nil end
  os.execute(string.format("rsvg-convert -f pdf -o %q %q 2>/dev/null", pdf, svg_path))

  if not exists(pdf) then
    warn_once("rsvg-convert could not turn the diagram into a PDF")
    return nil
  end
  return pdf
end

local function block(code, cfg)
  if not code.classes:includes("mermaid") then return nil end

  local pdf = render(code.text, cfg)
  if not pdf then return nil end -- leave the source visible rather than lose it

  return {
    pandoc.RawBlock("latex", "\\begin{center}"),
    pandoc.Para({ pandoc.Image({}, pdf, "", pandoc.Attr("", { "mermaid" })) }),
    pandoc.RawBlock("latex", "\\end{center}"),
  }
end

function Pandoc(doc)
  if not FORMAT:match("latex") then return nil end
  if doc.meta["mermaid"] == false then return nil end

  local has = false
  doc:walk({ CodeBlock = function(c) has = has or c.classes:includes("mermaid") end })
  if not has then return nil end

  local input = PANDOC_STATE.input_files[1]
  input = absolute(input and input ~= "" and input or "x")

  local library = doc.meta["mermaid-library"]
  library = library and absolute(pandoc.utils.stringify(library)) or find_library(input)
  if not library or not exists(library) then
    warn_once("no mermaid.min.js found; see the README on where it is looked for")
    return nil
  end

  local chrome_meta = doc.meta["mermaid-chrome"]
  local chrome = find_chrome(chrome_meta and pandoc.utils.stringify(chrome_meta))
  if not chrome then
    warn_once("no Chrome or Chromium found to draw the diagrams")
    return nil
  end
  if not on_path("rsvg-convert") then
    warn_once("rsvg-convert not installed (brew install librsvg)")
    return nil
  end

  pandoc.system.make_directory(CACHE, true)
  local cfg = {
    library = library,
    chrome = chrome,
    timeout = on_path("timeout") and "timeout 60 " or "",
  }
  return doc:walk({ CodeBlock = function(c) return block(c, cfg) end })
end
