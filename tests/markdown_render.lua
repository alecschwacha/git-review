-- Run: nvim --headless -u NONE -c 'luafile tests/markdown_render.lua' -c 'qa!'
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require("git-review.ui")

local body = table.concat({
    "Use `vim.tbl_extend` here.",
    "",
    "```",
    "local x = 1",
    "```",
    "",
    "```python",
    "x = 1",
    "```",
}, "\n")

ui.open_thread({
    path = "lua/foo.lua",
    start_line = 3,
    end_line = 5,
    is_resolved = false,
    viewer_can_reply = true,
    viewer_can_resolve = true,
    comments = { { author = "someone", body = body } },
})

local window = vim.api.nvim_get_current_win()
local buffer = vim.api.nvim_win_get_buf(window)
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

assert(vim.wo[window].conceallevel == 2, "conceallevel not set")
assert(vim.wo[window].concealcursor == "nc", "concealcursor not set")

-- Body lines land unindented, so fences stay fences.
local code_row
for row, line in ipairs(lines) do
    if line == "Use `vim.tbl_extend` here." then
        code_row = row - 1
    end
    assert(not line:match("^  %S"), "body line is still indented: " .. line)
end
assert(code_row, "comment body missing from the buffer")
-- The unlabelled fence is tagged with the reviewed file's language so
-- treesitter injects it; its closing fence and labelled fences are untouched.
assert(
    vim.tbl_contains(lines, "```lua"),
    "unlabelled fence was not tagged with the file's language"
)
assert(
    vim.tbl_contains(lines, "```python"),
    "an explicit fence language was overwritten"
)
assert(
    vim.tbl_contains(lines, "```"),
    "closing fence was tagged as an opener"
)

-- The parser attached and its conceal queries cover the inline-code ticks.
assert(vim.treesitter.highlighter.active[buffer], "treesitter not started")

-- Headless never redraws, so the injected markdown_inline tree has to be
-- parsed by hand before its captures exist.
vim.treesitter.get_parser(buffer, "markdown"):parse(true)

local tick = lines[code_row + 1]:find("`") - 1
local concealed = false

for _, capture in ipairs(
    vim.treesitter.get_captures_at_pos(buffer, code_row, tick)
) do
    if capture.metadata.conceal == "" then
        concealed = true
    end
end

assert(concealed, "inline-code backtick is not concealed")

-- Both blocks highlight: the tagged one as lua, the explicit one as python.
local injected = {}

for lang in pairs(
    vim.treesitter.get_parser(buffer, "markdown"):children()
) do
    injected[lang] = true
end

assert(injected.lua, "unlabelled block did not get the file's language")
assert(injected.python or not vim.treesitter.language.add("python"),
    "explicit block language was lost")

-- A file with no known filetype leaves the fence alone rather than guessing.
ui.open_thread({
    path = "some/thing.zzzz",
    is_resolved = false,
    viewer_can_reply = false,
    viewer_can_resolve = false,
    comments = { { author = "someone", body = "```\nx\n```" } },
})

assert(
    vim.tbl_contains(
        vim.api.nvim_buf_get_lines(
            vim.api.nvim_get_current_buf(), 0, -1, false
        ),
        "```"
    ),
    "fence was tagged despite an unknown filetype"
)

print("ok")
