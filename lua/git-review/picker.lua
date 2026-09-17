local M = {}

---@param thread GhReviewThread
---@return string
local function first_comment_line(thread)
    local comment = thread.comments[1]

    if not comment then
        return "No comment body"
    end

    return comment.body:match("([^\n]+)") or ""
end

---@param thread GhReviewThread
---@return string
local function thread_location(thread)
    if thread.end_line then
        return string.format(
            "%s:%d",
            thread.path,
            thread.end_line
        )
    end

    return thread.path
end

---@param pull_request GhReviewPullRequest
---@param thread GhReviewThread
local function jump_to_thread(pull_request, thread)
    if thread.is_outdated
        or thread.diff_side ~= "RIGHT"
        or not thread.end_line
    then
        vim.notify(
            "This comment does not have a current source location",
            vim.log.levels.WARN
        )

        require("git-review.ui").open_thread(thread)
        return
    end

    local filename = vim.fs.joinpath(
        pull_request.root,
        thread.path
    )

    if vim.fn.filereadable(filename) == 0 then
        vim.notify(
            "File is not in the working tree: " .. thread.path,
            vim.log.levels.WARN
        )

        require("git-review.ui").open_thread(thread)
        return
    end

    vim.cmd("edit " .. vim.fn.fnameescape(filename))

    local buffer = vim.api.nvim_get_current_buf()

    require("git-review.annotations").apply_to_buffer(
        buffer,
        pull_request
    )

    -- The comment's line comes from the PR head, which can sit past the end of
    -- the file as it stands locally; clamp so the jump cannot throw.
    local line_count = vim.api.nvim_buf_line_count(buffer)

    if thread.end_line > line_count then
        vim.notify(
            string.format(
                "Comment is on line %d but %s has %d lines locally",
                thread.end_line,
                thread.path,
                line_count
            ),
            vim.log.levels.WARN
        )
    end

    vim.api.nvim_win_set_cursor(
        0,
        { math.min(thread.end_line, line_count), 0 }
    )

    vim.cmd("normal! zz")
end

---@param thread GhReviewThread
local function entry_maker(thread)
    local comment = thread.comments[1]
    local author = comment and comment.author or "unknown"
    local location = thread_location(thread)
    local summary = first_comment_line(thread)
    local status = thread.is_resolved and "✓" or "●"

    return {
        value = thread,

        display = string.format(
            "%s %-18s %-40s %s",
            status,
            author,
            location,
            summary
        ),

        ordinal = table.concat({
            author,
            location,
            summary,
        }, " "),
    }
end

---@param show_resolved boolean
---@return string
local function prompt_title(show_resolved)
    if show_resolved then
        return "PR Review Recommendations  ·  <C-g> hide resolved"
    end

    return "PR Review Recommendations (unresolved)  ·  <C-g> show all"
end

---@param pull_request GhReviewPullRequest
function M.open(pull_request)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local previewers = require("telescope.previewers")
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local config = require("telescope.config").values

    local show_resolved = true

    local function make_finder()
        local threads = pull_request.threads

        if not show_resolved then
            threads = vim.tbl_filter(function(thread)
                return not thread.is_resolved
            end, threads)
        end

        return finders.new_table({
            results = threads,
            entry_maker = entry_maker,
        })
    end

    pickers.new({}, {
        prompt_title = prompt_title(show_resolved),

        finder = make_finder(),

        sorter = config.generic_sorter({}),

        previewer = previewers.new_buffer_previewer({
            define_preview = function(self, entry)
                local thread = entry.value

                local lines = {
                    "Location: " .. thread_location(thread),
                    "Status: "
                    .. (thread.is_resolved and "resolved" or "unresolved"),
                    "",
                }

                for _, comment in ipairs(thread.comments) do
                    table.insert(lines, comment.author .. ":")

                    for _, body_line in ipairs(
                        vim.split(comment.body, "\n", { plain = true })
                    ) do
                        table.insert(lines, "  " .. body_line)
                    end

                    table.insert(lines, "")
                end

                vim.api.nvim_buf_set_lines(
                    self.state.bufnr,
                    0,
                    -1,
                    false,
                    lines
                )

                vim.bo[self.state.bufnr].filetype = "markdown"
            end,
        }),

        attach_mappings = function(prompt_buffer, map)
            map({ "i", "n" }, "<C-g>", function()
                show_resolved = not show_resolved

                local picker =
                    action_state.get_current_picker(prompt_buffer)

                picker:refresh(
                    make_finder(),
                    { reset_prompt = false }
                )

                if picker.change_prompt_title then
                    picker:change_prompt_title(
                        prompt_title(show_resolved)
                    )
                end
            end, { desc = "Toggle resolved review threads" })

            actions.select_default:replace(function()
                local entry = action_state.get_selected_entry()

                actions.close(prompt_buffer)

                if entry then
                    jump_to_thread(
                        pull_request,
                        entry.value
                    )
                end
            end)

            return true
        end,
    }):find()
end

return M
