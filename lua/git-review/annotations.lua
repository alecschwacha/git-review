local M = {}

local namespace = vim.api.nvim_create_namespace(
    "git-review-annotations"
)

---@type table<integer, table<integer, GhReviewThread>>
local threads_by_extmark = {}

---@type table<integer, table<string, integer>>
local marks_by_thread = {}

--- Reads back where a mark has drifted to after the buffer was edited.
---@param buffer integer
---@param mark_id integer?
---@return integer? start_row, integer? end_row, boolean invalidated
local function tracked_rows(buffer, mark_id)
    if not mark_id then
        return nil, nil, false
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(
        buffer,
        namespace,
        mark_id,
        { details = true }
    )

    if not mark[1] then
        return nil, nil, false
    end

    local details = mark[3] or {}

    if details.invalid then
        return nil, nil, true
    end

    return mark[1], details.end_row or (mark[1] + 1), false
end

local function define_highlights()
    vim.api.nvim_set_hl(0, "GitReviewCommentSign", {
        default = true,
        link = "DiagnosticWarn",
    })
end

---@param buffer integer
---@param pull_request GhReviewPullRequest
function M.apply_to_buffer(buffer, pull_request)
    if not vim.api.nvim_buf_is_valid(buffer) then
        return
    end

    local buffer_name = vim.api.nvim_buf_get_name(buffer)

    if buffer_name == "" then
        return
    end

    local normalized_buffer_name = vim.fs.normalize(buffer_name)
    local line_count = vim.api.nvim_buf_line_count(buffer)

    local previous_marks = marks_by_thread[buffer] or {}

    marks_by_thread[buffer] = {}
    threads_by_extmark[buffer] = {}

    for _, thread in ipairs(pull_request.threads) do
        local thread_path = vim.fs.normalize(
            vim.fs.joinpath(
                pull_request.root,
                thread.path
            )
        )

        local has_current_location =
            thread.diff_side == "RIGHT"
            and not thread.is_outdated
            and type(thread.start_line) == "number"
            and type(thread.end_line) == "number"

        if normalized_buffer_name == thread_path
            and has_current_location
        then
            local existing = previous_marks[thread.id]

            -- Prefer where the mark has drifted to: Neovim has been shifting
            -- it as the file grew or shrank, and re-seeding from the PR's line
            -- numbers would throw that away.
            local start_row, end_row, invalidated =
                tracked_rows(buffer, existing)

            if not start_row and not invalidated then
                start_row = thread.start_line - 1
                end_row = math.min(thread.end_line, line_count)
            end

            if start_row and start_row < line_count then
                local mark_id = vim.api.nvim_buf_set_extmark(
                    buffer,
                    namespace,
                    start_row,
                    0,
                    {
                        id = existing,

                        end_row = math.min(end_row, line_count),
                        end_col = 0,

                        sign_text = not thread.is_resolved and "●" or nil,
                        sign_hl_group = not thread.is_resolved
                            and "GitReviewCommentSign"
                            or nil,

                        -- Drop the mark once every line it covered is gone,
                        -- rather than collapsing it onto a neighbour.
                        invalidate = true,

                        priority = 200,
                    }
                )

                marks_by_thread[buffer][thread.id] = mark_id
                threads_by_extmark[buffer][mark_id] = thread
            end
        end
    end

    -- Marks whose thread is gone from the PR data, or whose lines were
    -- deleted, are no longer re-placed above; clear them out.
    for thread_id, mark_id in pairs(previous_marks) do
        if not marks_by_thread[buffer][thread_id] then
            pcall(
                vim.api.nvim_buf_del_extmark,
                buffer,
                namespace,
                mark_id
            )
        end
    end

    vim.keymap.set("n", "<leader>ac", function()
        M.open_thread_under_cursor(buffer)
    end, {
        buffer = buffer,
        silent = true,
        desc = "Open review comment",
    })
end

--- Where a thread's comment sits in `buffer` right now, which drifts from the
--- PR's line numbers as the file is edited. Nil when the thread is untracked.
---@param buffer integer
---@param thread GhReviewThread
---@return integer? start_line, integer? end_line
function M.current_range(buffer, thread)
    local marks = marks_by_thread[buffer]

    local start_row, end_row = tracked_rows(
        buffer,
        marks and marks[thread.id]
    )

    if not start_row then
        return nil, nil
    end

    return start_row + 1, math.max(end_row, start_row + 1)
end

---@param buffer integer
---@return GhReviewThread[]
local function threads_under_cursor(buffer)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

    local marks = vim.api.nvim_buf_get_extmarks(
        buffer,
        namespace,
        { cursor_row, 0 },
        { cursor_row, -1 },
        {
            details = true,
            overlap = true,
        }
    )

    local threads = {}

    for _, mark in ipairs(marks) do
        local mark_id = mark[1]
        local thread = threads_by_extmark[buffer]
            and threads_by_extmark[buffer][mark_id]

        if thread then
            table.insert(threads, thread)
        end
    end

    return threads
end

---@param thread GhReviewThread
---@return string
local function thread_label(thread)
    local comment = thread.comments[1]
    local author = comment and comment.author or "unknown"
    local body = comment and comment.body or ""

    local first_line = body:match("([^\n]+)") or ""

    return string.format(
        "%s: %s",
        author,
        first_line
    )
end

---@param buffer integer
function M.open_thread_under_cursor(buffer)
    local threads = threads_under_cursor(buffer)

    if #threads == 0 then
        vim.notify(
            "No review comment under cursor",
            vim.log.levels.INFO
        )
        return
    end

    if #threads == 1 then
        require("git-review.ui").open_thread(threads[1], { buffer = buffer })
        return
    end

    vim.ui.select(threads, {
        prompt = "Select review thread",
        format_item = thread_label,
    }, function(thread)
        if thread then
            require("git-review.ui").open_thread(thread, { buffer = buffer })
        end
    end)
end

---@param pull_request GhReviewPullRequest
function M.apply_to_loaded_buffers(pull_request)
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buffer) then
            M.apply_to_buffer(buffer, pull_request)
        end
    end
end

function M.setup()
    define_highlights()

    local group = vim.api.nvim_create_augroup(
        "GitReviewAnnotations",
        { clear = true }
    )

    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,

        callback = function(event)
            local pull_request =
                require("git-review.state").get_pull_request()

            if pull_request then
                M.apply_to_buffer(event.buf, pull_request)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = group,

        callback = function(event)
            threads_by_extmark[event.buf] = nil
            marks_by_thread[event.buf] = nil
        end,
    })
end

return M
