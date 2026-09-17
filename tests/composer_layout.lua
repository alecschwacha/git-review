-- Run: nvim --headless -u NONE -c 'luafile tests/composer_layout.lua' -c 'qa!'
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require("git-review.ui")

local thread = {
    path = "lua/foo.lua",
    start_line = 3,
    end_line = 5,
    is_resolved = false,
    viewer_can_reply = true,
    viewer_can_resolve = true,
    comments = { { author = "someone", body = "hello\nworld" } },
}

local code_window = vim.api.nvim_get_current_win()

ui.open_thread(thread)

local thread_window = vim.api.nvim_get_current_win()
assert(thread_window ~= code_window, "thread window did not open")
assert(
    vim.api.nvim_win_get_config(thread_window).relative == "",
    "thread window is still a float"
)

-- Opening a second thread reuses the same split instead of stacking.
ui.open_thread(thread)
assert(
    vim.api.nvim_get_current_win() == thread_window,
    "second open did not reuse the split"
)

vim.api.nvim_feedkeys("r", "x", false)
vim.cmd("stopinsert")

local composer = vim.api.nvim_get_current_win()
assert(composer ~= thread_window, "composer did not open")
assert(
    vim.api.nvim_win_get_config(composer).relative == "",
    "composer is still a float"
)

-- Same column, directly under the thread split.
local trow, tcol = unpack(vim.api.nvim_win_get_position(thread_window))
local crow, ccol = unpack(vim.api.nvim_win_get_position(composer))
assert(ccol == tcol, "composer is not aligned with the thread split")
assert(crow > trow, "composer is not below the thread split")

-- Plain window movement reaches every pane, no plugin-side mappings.
vim.cmd("wincmd k")
assert(
    vim.api.nvim_get_current_win() == thread_window,
    "wincmd k did not reach the review comment"
)

vim.cmd("wincmd h")
assert(
    vim.api.nvim_get_current_win() == code_window,
    "wincmd h did not reach the code window"
)

vim.cmd("wincmd l")
vim.cmd("wincmd j")
assert(
    vim.api.nvim_get_current_win() == composer,
    "wincmd j did not reach the composer"
)

-- q closes the composer and leaves the review comment standing.
vim.api.nvim_feedkeys("q", "x", false)
assert(not vim.api.nvim_win_is_valid(composer), "composer stayed open")
assert(
    vim.api.nvim_win_is_valid(thread_window),
    "closing the composer took the review comment with it"
)

print("ok")
