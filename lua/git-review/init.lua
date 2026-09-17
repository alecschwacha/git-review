local M = {}

local function get_loaded_pull_request()
    local pull_request =
        require("git-review.state").get_pull_request()

    if not pull_request then
        vim.notify(
            "Run :GhReviewLoad first",
            vim.log.levels.WARN
        )
    end

    return pull_request
end

local function load_current_pull_request()
    require("git-review.pr").fetch_current(
        function(err, pull_request)
            if err then
                vim.notify(err, vim.log.levels.ERROR)
                return
            end

            require("git-review.state").set_pull_request(
                pull_request
            )

            require("git-review.annotations")
                .apply_to_loaded_buffers(pull_request)

            vim.notify(
                string.format(
                    "Loaded PR #%d with %d review threads",
                    pull_request.number,
                    #pull_request.threads
                ),
                vim.log.levels.INFO
            )
        end
    )
end

function M.setup()
    require("git-review.annotations").setup()

    vim.api.nvim_create_user_command(
        "GhReviewLoad",
        load_current_pull_request,
        {
            desc = "Load review information for the current PR",
        }
    )

    vim.api.nvim_create_user_command(
        "GhReviewRecommendations",
        function()
            local pull_request = get_loaded_pull_request()

            if pull_request then
                require("git-review.picker").open(pull_request)
            end
        end,
        {
            desc = "Browse PR review recommendations",
        }
    )
end

return M
