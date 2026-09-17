local M = {}

--- The PR's line numbers, plus where the comment has drifted to in `buffer`
--- once the file has been edited underneath it.
---@param thread GhReviewThread
---@param buffer integer?
---@return string
local function location_line(thread, buffer)
    if not (thread.start_line and thread.end_line) then
        return "Lines: file-level comment"
    end

    local text = string.format(
        "Lines: %d-%d",
        thread.start_line,
        thread.end_line
    )

    if not (buffer and vim.api.nvim_buf_is_valid(buffer)) then
        return text
    end

    local start_line, end_line =
        require("git-review.annotations").current_range(buffer, thread)

    if start_line
        and (start_line ~= thread.start_line
            or end_line ~= thread.end_line)
    then
        text = text .. string.format(
            "  (now %d-%d)",
            start_line,
            end_line
        )
    end

    return text
end

--- Treesitter only injects a fenced block's language when the fence names
--- one, so an unlabelled suggestion renders flat. Assume it is written in the
--- language of the file under review. Returns nil when that cannot be worked
--- out, which just leaves the block unhighlighted.
---@param path string
---@return string?
local function fence_language(path)
    local filetype = vim.filetype.match({ filename = path })

    return filetype
        and vim.treesitter.language.get_lang(filetype)
        or nil
end

---@param thread GhReviewThread
---@param buffer integer? Source buffer the thread was opened from
---@return string[]
local function thread_lines(thread, buffer)
    local language = fence_language(thread.path)
    local lines = {
        thread.path,
        "",
        location_line(thread, buffer),
        "Status: " .. (thread.is_resolved and "resolved" or "unresolved"),
        "",
    }

    for index, comment in ipairs(thread.comments) do
        table.insert(
            lines,
            string.format("**%s**", comment.author)
        )
        table.insert(lines, "")

        -- Unindented: the body is markdown, and a leading indent turns fences
        -- and nested lists into something the parser reads differently.
        local in_fence = false

        for _, body_line in ipairs(
            vim.split(comment.body, "\n", { plain = true })
        ) do
            if not in_fence
                and language
                and body_line:match("^%s*```+%s*$")
            then
                -- The label is concealed along with the fence itself.
                body_line = body_line:gsub("%s+$", "") .. language
                in_fence = true
            elseif body_line:match("^%s*```") then
                in_fence = not in_fence
            end

            table.insert(lines, body_line)
        end

        if index < #thread.comments then
            table.insert(lines, "")
            table.insert(lines, string.rep("─", 40))
            table.insert(lines, "")
        end
    end

    local keys = {}

    if thread.viewer_can_reply then
        table.insert(keys, "r reply")
    end

    if thread.viewer_can_resolve then
        table.insert(
            keys,
            thread.is_resolved and "t unresolve" or "t resolve"
        )

        if thread.viewer_can_reply and not thread.is_resolved then
            table.insert(keys, "R reply + resolve")
        end
    end

    table.insert(keys, "q close")

    table.insert(lines, "")
    table.insert(lines, table.concat(keys, "  ·  "))

    return lines
end

--- Opens a scratch buffer for composing a comment body, in a split below
--- `anchor` so the thread stays visible and the usual window-movement keys
--- reach both. `on_submit` receives the trimmed text once the composer has
--- already closed itself.
---@param opts { title: string, on_submit: fun(body: string), anchor: integer }
local function open_composer(opts)
    local buffer = vim.api.nvim_create_buf(false, true)

    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "markdown"

    local window = vim.api.nvim_open_win(buffer, true, {
        split = "below",
        win = opts.anchor,
        height = math.min(10, math.floor(vim.o.lines / 3)),
    })

    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    vim.wo[window].winbar = string.format(
        "%s — <C-s> send · q cancel",
        opts.title
    )

    local function close()
        if vim.api.nvim_win_is_valid(window) then
            vim.api.nvim_win_close(window, true)
        end
    end

    local function submit()
        local body = vim.trim(
            table.concat(
                vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
                "\n"
            )
        )

        if body == "" then
            vim.notify(
                "Nothing to post",
                vim.log.levels.WARN
            )
            return
        end

        vim.cmd("stopinsert")
        close()

        opts.on_submit(body)
    end

    vim.keymap.set({ "n", "i" }, "<C-s>", submit, {
        buffer = buffer,
        silent = true,
    })

    -- Deliberately no <Esc> cancel: <Esc> is how you leave insert mode here,
    -- and a stray second press should not throw away a typed reply.
    vim.keymap.set("n", "q", close, {
        buffer = buffer,
        silent = true,
        nowait = true,
    })

    vim.cmd("startinsert")
end

local function refresh_annotations()
    local pull_request =
        require("git-review.state").get_pull_request()

    if pull_request then
        require("git-review.annotations")
            .apply_to_loaded_buffers(pull_request)
    end
end

--- The one review-comment split, reused so repeated opens do not stack up
--- new windows.
---@type integer?
local thread_window

---@param thread GhReviewThread
---@param opts { buffer: integer? }? Source buffer, for the live location
function M.open_thread(thread, opts)
    local source_buffer = opts and opts.buffer
    local buffer = vim.api.nvim_create_buf(false, true)

    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "markdown"

    local lines = thread_lines(thread, source_buffer)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false

    local window = thread_window

    if window and vim.api.nvim_win_is_valid(window) then
        vim.api.nvim_win_set_buf(window, buffer)
        vim.api.nvim_set_current_win(window)
    else
        window = vim.api.nvim_open_win(buffer, true, {
            split = "right",
            win = -1,
            width = math.min(
                90,
                math.max(40, math.floor(vim.o.columns / 3))
            ),
        })

        thread_window = window
    end

    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    vim.wo[window].winbar = "Review Comment"

    -- Render the markdown rather than showing its punctuation: treesitter's
    -- bundled queries conceal the `` ` ``, `*` and link syntax.
    vim.wo[window].conceallevel = 2
    vim.wo[window].concealcursor = "nc"

    pcall(vim.treesitter.start, buffer, "markdown")

    local function render()
        if not vim.api.nvim_buf_is_valid(buffer) then
            return
        end

        local updated = thread_lines(thread, source_buffer)

        vim.bo[buffer].modifiable = true
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, updated)
        vim.bo[buffer].modifiable = false

    end

    local function close()
        if vim.api.nvim_win_is_valid(window) then
            vim.api.nvim_win_close(window, true)
        end
    end

    ---@param resolved boolean
    ---@param callback fun()?
    local function set_resolved(resolved, callback)
        if not thread.viewer_can_resolve then
            vim.notify(
                "You cannot resolve this thread",
                vim.log.levels.WARN
            )
            return
        end

        require("git-review.pr").set_thread_resolved(
            thread,
            resolved,
            function(err)
                if err then
                    vim.notify(err, vim.log.levels.ERROR)
                    return
                end

                vim.notify(
                    resolved
                    and "Thread resolved"
                    or "Thread unresolved",
                    vim.log.levels.INFO
                )

                render()
                refresh_annotations()

                if callback then
                    callback()
                end
            end
        )
    end

    ---@param then_resolve boolean
    local function reply(then_resolve)
        if not thread.viewer_can_reply then
            vim.notify(
                "You cannot reply to this thread",
                vim.log.levels.WARN
            )
            return
        end

        open_composer({
            title = then_resolve and "Reply + resolve" or "Reply",
            anchor = window,

            on_submit = function(body)
                require("git-review.pr").reply_to_thread(
                    thread,
                    body,
                    function(err)
                        if err then
                            vim.notify(err, vim.log.levels.ERROR)
                            return
                        end

                        vim.notify(
                            "Reply posted",
                            vim.log.levels.INFO
                        )

                        render()

                        if then_resolve then
                            set_resolved(true)
                        end
                    end
                )
            end,
        })
    end

    vim.keymap.set("n", "r", function()
        reply(false)
    end, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "Reply to review thread",
    })

    vim.keymap.set("n", "R", function()
        reply(true)
    end, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "Reply to review thread and resolve it",
    })

    vim.keymap.set("n", "t", function()
        set_resolved(not thread.is_resolved)
    end, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "Toggle review thread resolution",
    })

    -- No <Esc> close: this is a persistent split now, and <Esc> is what you
    -- press to cancel anything else.
    vim.keymap.set("n", "q", close, {
        buffer = buffer,
        silent = true,
        nowait = true,
    })
end

---@param pull_request GhReviewPullRequest
---@return string[]
local function render_pull_request(pull_request)
    local lines = {
        string.format("Pull Request #%d", pull_request.number),
        "",
        "Title:    " .. pull_request.title,
        "Decision: " .. (pull_request.review_decision or "NONE"),
        "",
    }

    local thread = pull_request.threads[1]

    if not thread then
        table.insert(lines, "No review comments found")
    else
        local location = thread.path

        if thread.start_line and thread.end_line then
            if thread.start_line == thread.end_line then
                location = string.format(
                    "%s:%d",
                    thread.path,
                    thread.end_line
                )
            else
                location = string.format(
                    "%s:%d-%d",
                    thread.path,
                    thread.start_line,
                    thread.end_line
                )
            end
        end

        table.insert(lines, "First review comment")
        table.insert(lines, "")
        table.insert(lines, "Location: " .. location)
        table.insert(
            lines,
            "Status:   "
            .. (thread.is_resolved and "resolved" or "unresolved")
        )

        local comment = thread.comments[1]

        if comment then
            table.insert(lines, "Author:   " .. comment.author)
            table.insert(lines, "")
            table.insert(lines, "Comment:")

            local body_lines = vim.split(
                comment.body,
                "\n",
                { plain = true }
            )

            for _, body_line in ipairs(body_lines) do
                table.insert(lines, "  " .. body_line)
            end
        else
            table.insert(lines, "")
            table.insert(lines, "Thread contains no comments")
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Press q or <Esc> to close")

    return lines
end

---@param pull_request GhReviewPullRequest
function M.open_pull_request(pull_request)
    local lines = render_pull_request(pull_request)

    local width = math.min(90, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 4)

    local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local buffer = vim.api.nvim_create_buf(false, true)

    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "gh-review"

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false

    local window = vim.api.nvim_open_win(buffer, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = " GitHub Review ",
        title_pos = "center",
        width = width,
        height = height,
        row = row,
        col = col,
    })

    vim.wo[window].cursorline = true
    vim.wo[window].wrap = false

    local function close()
        if vim.api.nvim_win_is_valid(window) then
            vim.api.nvim_win_close(window, true)
        end
    end

    vim.keymap.set("n", "q", close, {
        buffer = buffer,
        silent = true,
        nowait = true,
    })

    vim.keymap.set("n", "<Esc>", close, {
        buffer = buffer,
        silent = true,
        nowait = true,
    })
end

return M
