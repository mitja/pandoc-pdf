# pandoc-pdf

A pandoc defaults file and four Lua filters that turn Markdown into an A4 PDF.

```sh
pandoc -d pandoc-pdf document.md -o document.pdf
```

[**example/showcase.pdf**](example/showcase.pdf) is what it produces: a document
that describes the theme and is set by it, so the tables, hairlines, code sizing
and diagrams on the page are the thing being described. Its source is
[example/showcase.md](example/showcase.md).

It fixes four things that plain pandoc does not do well.

**Table columns are sized by their content.** Pandoc takes column widths from
the number of dashes in a pipe table's separator row. Those dashes describe the
source file, not the content, so `|--|--|--|` produces equally wide columns
whatever is in them. A ten-column price table came out with every cell wrapped
and the last two headers printed on top of each other. The filter measures the
cells instead. Over 224 tables in a reference corpus this took overfull boxes
from 1904 to 614 and the page count from 508 to 382.

**Table rows are separated by a hairline.** Pandoc styles tables with booktabs,
which rules the head and the foot and leaves the body open. That reads well for
five rows and badly for twenty, and worst of all where rows wrap onto two lines
and nothing shows which lines belong together.

**Code blocks fit more on a line.** They were set at the body size, where Menlo
leaves room for 73 characters. 10% of the code lines in a real blog were longer
than that and ran off the page. At one step down, 89 characters fit.

**Mermaid diagrams are drawn.** A ` ```mermaid ` block is normally set as source
code. All 22 of mermaid's diagram types are drawn into the page instead, using
headless Chrome and `rsvg-convert`. There is no Node toolchain and no
mermaid-cli.

## Requirements

- **pandoc** 3.x
- **XeLaTeX**, with `koma-script`, `booktabs`, `colortbl`, `scrlayer-scrpage`
  and `ulem`. BasicTeX has all of these.
- **rsvg-convert** and **Chrome**, for mermaid diagrams only. Everything else
  works without them, and a document with diagrams still builds: the block is
  left as source code and a warning is printed. On macOS,
  `brew install librsvg`.

`soul` is not required. Pandoc loads it for `~~strikeout~~`, `==highlight==` and
underline, and BasicTeX does not ship it, so the theme drops pandoc's own
`\usepackage{soul}` and loads it only if it is installed, falling back to `ulem`.

## Install

```sh
git clone <this repository> pandoc-pdf
cd pandoc-pdf
./install.sh
```

The installer links the defaults files into pandoc's data directory, so
`pandoc -d pandoc-pdf` works from any directory. It links rather than copies, so
pulling the repository updates what pandoc uses. The filters stay in the
repository: pandoc resolves `${.}` in a defaults file through the symlink to the
real file, and finds `../filters` from there.

Without installing, name the file directly:

```sh
pandoc -d /path/to/pandoc-pdf/defaults/pandoc-pdf.yaml document.md -o document.pdf
```

For mermaid, the filter needs a copy of `mermaid.min.js`. It looks for one
beside the filters in `vendor/`, and then upwards from the document for
`vendor/`, `node_modules/mermaid/dist/`, a Hugo theme under
`themes/*/assets/lib/mermaid/`, or `static/js/`. A Hugo site with a theme that
ships mermaid already has one. Otherwise:

```sh
./fetch-mermaid.sh
```

## Fonts

The base defaults file sets no fonts, so it works with whatever the TeX
installation provides. For the fonts it was designed around, all of which ship
with macOS, add a second defaults file:

```sh
pandoc -d pandoc-pdf -d fonts-macos document.md -o document.pdf
```

That sets Charter for text, Seravek for headings and Menlo for code. Any other
serif and monospace pair works. Two numbers shift when you change them: the
per-character widths in `table-autowidth.lua` were fitted against Charter, and
the 89-column figure for code blocks comes from Menlo.

Put fonts in their own defaults file rather than in the base. A second `-d` file
replaces `header-includes` instead of adding to it, so a font file that sets
`header-includes` would drop everything the base defines.

## What the filters do

### table-autowidth.lua

Estimates the typeset width of every cell from its characters, using
per-character widths fitted by least squares against XeLaTeX measurements of 50
real table cells: 1.9% mean error on the strings long enough to drive a column
width.

A table that already fits keeps its natural width. The rest are split the way
the `tabulary` package splits them: columns narrower than their fair share are
held at their natural width, and what is left is shared among the wide columns
in proportion to how much text each holds. That evens out row heights rather
than column widths.

A column of prose is then lifted back to a readable width if the page can spare
it. Without that, one very long cell in one column starves a column of ordinary
sentences: in one table a 700-character cell took 55% of the page and left the
`state` column 12 characters wide.

If the widest unbreakable words still do not fit, the table steps down through
`\small` and a tighter `\tabcolsep`, and long paths gain break points after `/`
and `_`. About 10% of tables in the reference corpus need any of that.

Turn it off for one table with a `fixed-widths` class on a fenced div, or
everywhere with `table-autowidth: false` in the metadata.

### table-rules.lua

booktabs has no option for a rule between every row, and the packages that do
(`tabularray`, `nicematrix`) are not in BasicTeX. Pandoc writes each row as
`cell & cell \\`, and TeX accepts `\noalign` material straight after that, so the
rule travels as raw LaTeX at the front of each row's first cell.

Rows whose first cell holds more than paragraphs are left unruled: pandoc wraps
those in a `minipage`, where `\noalign` is an error. Cells written as pipe tables
are always a single paragraph, so this does not come up in practice — none of
1620 body rows across two repositories hit it.

Turn it off with `table-row-rules: false` in the metadata.

### mermaid.lua

Headless Chrome renders the diagram with `mermaid.min.js`, and `rsvg-convert`
turns the SVG into a PDF that XeLaTeX embeds. Diagrams are cached by the hash of
their source, so a rebuild costs about two seconds for each block that changed
and nothing for the rest.

Four things have to be corrected between the browser and the converter:

- Mermaid writes each label twice, as HTML in a `<foreignObject>` and as plain
  SVG text, and offers the pair inside an SVG `<switch>`. librsvg takes the
  foreignObject, cannot draw it, and never reaches the text put there for this
  case. The foreignObject is dropped.
- Those uncovered labels carry the same class as the box behind them, and the
  class sets that box's pale fill. They are given an inline fill.
- The rect behind an edge label has no fill, which in SVG means black. It is
  painted.
- A label escaped once for HTML is escaped again by the browser's serialiser, so
  `<<satisfies>>` arrives as `&amp;lt;&amp;lt;satisfies&amp;gt;&amp;gt;`. Only
  the entities XML defines are unwrapped; turning anything else back into a bare
  `&` would break the parse.

Chrome runs without `--user-data-dir`. Pointing it at a profile of its own makes
it hang rather than render, whatever flags accompany it. It runs under `timeout`
so a stuck browser cannot hang a build.

All 22 diagram types draw. Three carry a caveat, none of which is a fault in the
drawing: `erDiagram` sets relationship labels pale and `gitGraph` sets commit
hashes rotated, both as mermaid does in a browser, and `packet-beta` is 1026pt
wide so it prints at 42%.

Turn it off with `mermaid: false` in the metadata. Point it at a specific
library with `mermaid-library`.

### source-info.lua

Sets two things the document does not usually carry.

**The language, from the file name.** An `index.de.md` is German, and without
being told, LaTeX hyphenates it as English: `An-griffsvek-toren` where German
breaks `An-griffs-vek-to-ren`, `Geschwindigkeits-be-gren-zung` where it breaks
`Ge-schwin-dig-keits-be-gren-zung`. Fewer and worse break points make looser
lines. The suffix must be exactly two letters, so a `notes.old.md` is not taken
to be written in "old".

**The footer.** It says where the page came from. For a file inside a Hugo site
that is the address the page has once published: the `baseURL` from
`config/_default/hugo.toml`, the language prefix, and the path below `content/`
with the last segment replaced by the front matter `slug`. Checked against a
built site, 74 of 75 posts matched exactly; the one that did not is a draft Hugo
never builds, and its address was still right. For anything else the footer is
the output file name.

The address is long enough that it takes the line on its own. The longest post
URL measured 385pt of a 427pt line, which leaves no room for an author beside it.

## Options

All of these go in the document's front matter, or in the `metadata:` block of a
defaults file.

| Key | Effect |
|-----|--------|
| `table-line-width` | Width of the text area. Change it with `geometry`. |
| `table-font-size` | Body size. Change it with `fontsize`. |
| `table-autowidth: false` | Leave pandoc's column widths alone. |
| `table-row-rules: false` | No hairline between rows. |
| `mermaid: false` | Leave mermaid blocks as source code. |
| `mermaid-library` | Path to `mermaid.min.js`. |
| `site-url` | Base address for the footer, instead of reading Hugo's config. |

To change the page size or margins, edit `geometry` in the defaults file and set
`table-line-width` to match. The two are separate because pandoc passes
`geometry` to the template and the filter cannot read it.

## Repository layout

```
defaults/pandoc-pdf.yaml    the theme: layout, tables, code, footer
defaults/fonts-macos.yaml   Charter, Seravek, Menlo
filters/source-info.lua     language and footer
filters/table-autowidth.lua column widths from cell content
filters/table-rules.lua     hairline between rows
filters/mermaid.lua         diagrams
example/showcase.md         a document about the theme, set by the theme
example/showcase.pdf        the same document rendered, checked in so it can be read here
install.sh                  links the defaults into pandoc's data directory
fetch-mermaid.sh            downloads mermaid.min.js into vendor/
```

## License

MIT, see `LICENSE`.

Pandoc itself is GPL-2.0-or-later. Nothing here contains pandoc code: the
defaults file and the filters are input pandoc reads, the same as a document or
a template, which is why pandoc's own collection of Lua filters is MIT too.
`fetch-mermaid.sh` downloads mermaid, which is MIT, and is not redistributed
here.

## Known limits

- A diagram wider than the text block is scaled to fit, and its labels shrink
  with it. A seven-node `flowchart LR` comes out 1314pt wide and is scaled to
  32%, leaving the text at about 5px. `flowchart TD` prints at full size.
- Code lines longer than the column still run off the page. fancyvrb cannot wrap
  them without `fvextra`, which BasicTeX omits.
- The column-width estimate is a model of typeset width, not a measurement, so a
  table can be a fraction of a point off. Sub-point overhangs land inside
  `\tabcolsep` and are invisible.
- Embedding an `.svg` image makes pandoc load the `svg` package, which is not in
  BasicTeX and needs Inkscape.
