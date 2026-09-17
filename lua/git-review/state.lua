local M = {}

---@type GhReviewPullRequest?
local current_pull_request = nil

---@param pull_request GhReviewPullRequest
function M.set_pull_request(pull_request)
    current_pull_request = pull_request
end

---@return GhReviewPullRequest?
function M.get_pull_request()
    return current_pull_request
end

function M.clear()
    current_pull_request = nil
end

return M
