-- Companion filter for pandoc-pdf.yaml: what the input file itself says about
-- the document.
--
-- Two things are derived from the path rather than the front matter, because
-- Hugo does not put either of them there:
--
--   * the language. An index.de.md is German, and without being told so LaTeX
--     hyphenates it as English -- "An-griffsvek-toren" where German would break
--     "An-griffs-vek-to-ren". Setting `lang` gets the right patterns loaded.
--   * the address the post will have once published, put in the footer so a
--     printed page says where it came from. Hugo builds it from the path below
--     content/, with the last segment replaced by the front matter's slug and
--     everything but the default language under its own prefix.
--
-- Anything that is not a post under content/ still gets a footer: there is no
-- URL to work out, so the output file name is used, as it was before.

local DEFAULT_LANGUAGE = "en" -- the one Hugo serves without a prefix

local function latex_escape(s)
  return (s:gsub("[\\{}$&#^_%%~]", {
    ["\\"] = "\\textbackslash{}", ["{"] = "\\{", ["}"] = "\\}", ["$"] = "\\$",
    ["&"] = "\\&", ["#"] = "\\#", ["^"] = "\\^{}", ["_"] = "\\_",
    ["%"] = "\\%", ["~"] = "\\~{}",
  }))
end

local function absolute(path)
  if path:sub(1, 1) == "/" then return path end
  return pandoc.system.get_working_directory() .. "/" .. path
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- index.de.md is German, index.md is the default language. The suffix has to be
-- exactly two letters to count, which is what a language code is: it keeps a
-- notes.old.md or a report.v2.md from being declared to be written in "old".
local function language_of(path)
  return path:match("%.(%a%a)%.md$") or DEFAULT_LANGUAGE
end

-- Hugo's baseURL, so the address in the footer cannot drift from the site's.
local function base_url(input, meta)
  local given = meta["site-url"]
  if given then return (pandoc.utils.stringify(given):gsub("/*$", "")) end

  local dir = input
  for _ = 1, 8 do
    dir = dir:match("^(.*)/[^/]*$")
    if not dir then break end
    local config = read_file(dir .. "/config/_default/hugo.toml")
    local url = config and config:match('baseURL%s*=%s*"([^"]+)"')
    if url then return (url:gsub("/*$", "")) end
  end
  return nil
end

-- content/posts/2026/01/a-post/index.de.md, slug "ein-post"
--   -> <base>/de/posts/2026/01/ein-post/
local function page_url(input, meta, language)
  local path = input:match("/content/(.*)$")
  if not path then return nil end

  local dirs = path:match("^(.*)/[^/]*$")
  if not dirs then return nil end

  local slug = meta["slug"] and pandoc.utils.stringify(meta["slug"])
  if slug and slug ~= "" then
    dirs = dirs:match("^(.*)/[^/]*$")
    dirs = dirs and (dirs .. "/" .. slug) or slug
  end

  local base = base_url(input, meta)
  if not base then return nil end
  local prefix = language ~= DEFAULT_LANGUAGE and ("/" .. language) or ""
  return base .. prefix .. "/" .. dirs .. "/"
end

function Pandoc(doc)
  if not FORMAT:match("latex") then return nil end

  local input = PANDOC_STATE.input_files[1]
  input = input and input ~= "" and absolute(input) or nil

  -- Only set the language when the document has not asked for one itself.
  if input and not doc.meta.lang then
    doc.meta.lang = pandoc.MetaString(language_of(input))
  end

  local footer = input and page_url(input, doc.meta, language_of(input))
  if not footer then
    local out = PANDOC_STATE.output_file
    footer = out and out:match("([^/\\]+)$") or nil
  end
  if footer then
    doc.blocks:insert(1, pandoc.RawBlock("latex",
      "\\renewcommand*{\\pdffooter}{" .. latex_escape(footer) .. "}"))
  end

  return doc
end
