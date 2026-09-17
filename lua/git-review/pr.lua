local M = {}

---@generic T
---@param value T
---@return T?
local function nullable(value)
    if value == vim.NIL then
        return nil
    end

    return value
end

local REVIEW_QUERY = [[
query ReviewData(
  $owner: String!
  $repo: String!
  $number: Int!
  $cursor: String
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewDecision

      latestOpinionatedReviews(first: 100) {
        nodes {
          id
          state
          body
          submittedAt
          url

          author {
            login
          }
        }
      }

      reviewThreads(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }

        nodes {
          id
          path
          line
          startLine
          originalLine
          originalStartLine
          diffSide
          subjectType
          isResolved
          isOutdated
          viewerCanReply
          viewerCanResolve

          # ponytail: a single thread past 100 replies still truncates;
          # paginate here too if that ever shows up in practice.
          comments(first: 100) {
            nodes {
              id
              body
              createdAt
              url

              author {
                login
              }

              pullRequestReview {
                id
              }
            }
          }
        }
      }
    }
  }
}
]]

---@class GhReviewComment
---@field id string
---@field author string
---@field body string
---@field created_at string
---@field url string
---@field review_id string?
---@field suggestions string[]

---@class GhReviewThread
---@field id string
---@field path string
---@field start_line integer?
---@field end_line integer?
---@field original_start_line integer?
---@field original_end_line integer?
---@field diff_side "LEFT"|"RIGHT"
---@field subject_type "FILE"|"LINE"
---@field is_resolved boolean
---@field is_outdated boolean
---@field viewer_can_reply boolean
---@field viewer_can_resolve boolean
---@field comments GhReviewComment[]

---@class GhChangeRequest
---@field id string
---@field author string
---@field body string
---@field submitted_at string?
---@field url string

---@class GhReviewPullRequest
---@field number integer
---@field title string
---@field url string
---@field owner string
---@field repository string
---@field head_branch string
---@field head_oid string
---@field root string
---@field review_decision string?
---@field has_changes_requested boolean
---@field change_requests GhChangeRequest[]
---@field threads GhReviewThread[]

---@param actor table?
---@return string
local function actor_login(actor)
    if type(actor) == "table" and type(actor.login) == "string" then
        return actor.login
    end

    return "[deleted]"
end

---@param body string
---@return string[]
local function extract_suggestions(body)
    local suggestions = {}

    for suggestion in body:gmatch("```suggestion[^\n]*\n(.-)\n```") do
        table.insert(suggestions, suggestion)
    end

    return suggestions
end

---@param node table
---@return GhReviewComment
local function normalize_comment(node)
    local review = nullable(node.pullRequestReview)
    return {
        id = node.id,
        author = actor_login(node.author),
        body = node.body,
        created_at = node.createdAt,
        url = node.url,
        review_id = review and review.id or nil,
        suggestions = extract_suggestions(node.body),
    }
end

---@param node table
---@return GhReviewThread
local function normalize_thread(node)
    local comments = {}

    for _, comment in ipairs(node.comments.nodes or {}) do
        table.insert(comments, normalize_comment(comment))
    end

    local line = nullable(node.line)
    local start_line = nullable(node.startLine)

    local original_line = nullable(node.originalLine)
    local original_start_line = nullable(node.originalStartLine)

    return {
        id = node.id,
        path = node.path,

        start_line = start_line or line,
        end_line = line,

        original_start_line = original_start_line or original_line,
        original_end_line = original_line,

        diff_side = node.diffSide,
        subject_type = node.subjectType,

        is_resolved = node.isResolved,
        is_outdated = node.isOutdated,

        viewer_can_reply = node.viewerCanReply,
        viewer_can_resolve = node.viewerCanResolve,

        comments = comments,
    }
end

---@param node table
---@return GhChangeRequest
local function normalize_change_request(node)
    return {
        id = node.id,
        author = actor_login(node.author),
        body = node.body,
        submitted_at = node.submittedAt,
        url = node.url,
    }
end

---@param args string[]
---@param root string
---@param callback fun(err: string?, response: table?)
local function run_json(args, root, callback)
    vim.system(args, {
        cwd = root,
        text = true,
    }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            local message = result.stderr ~= ""
                and vim.trim(result.stderr)
                or "GitHub command failed"

            callback(message, nil)
            return
        end

        local ok, response = pcall(vim.json.decode, result.stdout)

        if not ok then
            callback("Could not decode GitHub response", nil)
            return
        end

        callback(nil, response)
    end))
end

local REPLY_MUTATION = [[
mutation ReplyToReviewThread($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: $threadId
    body: $body
  }) {
    comment {
      id
      body
      createdAt
      url

      author {
        login
      }

      pullRequestReview {
        id
      }
    }
  }
}
]]

local RESOLVE_MUTATION = [[
mutation ResolveReviewThread($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread {
      isResolved
      isOutdated
      viewerCanReply
      viewerCanResolve
    }
  }
}
]]

local UNRESOLVE_MUTATION = [[
mutation UnresolveReviewThread($threadId: ID!) {
  unresolveReviewThread(input: { threadId: $threadId }) {
    thread {
      isResolved
      isOutdated
      viewerCanReply
      viewerCanResolve
    }
  }
}
]]

---@param query string
---@param variables table<string, string>
---@param callback fun(err: string?, data: table?)
local function run_graphql(query, variables, callback)
    local args = { "gh", "api", "graphql", "-f", "query=" .. query }

    for name, value in pairs(variables) do
        table.insert(args, "-f")
        table.insert(args, name .. "=" .. value)
    end

    local pull_request =
        require("git-review.state").get_pull_request()

    local root = pull_request and pull_request.root
        or vim.fn.getcwd()

    run_json(args, root, function(err, response)
        if err then
            callback(err, nil)
            return
        end

        local errors = response.errors

        if type(errors) == "table" and errors[1] then
            callback(
                errors[1].message or "GitHub returned an error",
                nil
            )
            return
        end

        callback(nil, response.data)
    end)
end

--- Posts a reply to an existing review thread. On success the new comment is
--- appended to `thread.comments` in place, so callers holding the thread from
--- `git-review.state` see it immediately.
---@param thread GhReviewThread
---@param body string
---@param callback fun(err: string?, comment: GhReviewComment?)
function M.reply_to_thread(thread, body, callback)
    run_graphql(REPLY_MUTATION, {
        threadId = thread.id,
        body = body,
    }, function(err, data)
        if err then
            callback(err, nil)
            return
        end

        local node = data
            and data.addPullRequestReviewThreadReply
            and data.addPullRequestReviewThreadReply.comment

        if not node then
            callback("GitHub did not return the posted reply", nil)
            return
        end

        local comment = normalize_comment(node)

        table.insert(thread.comments, comment)

        callback(nil, comment)
    end)
end

--- Resolves or unresolves a review thread, updating `thread` in place.
---@param thread GhReviewThread
---@param resolved boolean
---@param callback fun(err: string?)
function M.set_thread_resolved(thread, resolved, callback)
    local mutation = resolved
        and RESOLVE_MUTATION
        or UNRESOLVE_MUTATION

    local field = resolved
        and "resolveReviewThread"
        or "unresolveReviewThread"

    run_graphql(mutation, {
        threadId = thread.id,
    }, function(err, data)
        if err then
            callback(err)
            return
        end

        local node = data
            and data[field]
            and data[field].thread

        if not node then
            callback("GitHub did not return the updated thread")
            return
        end

        thread.is_resolved = node.isResolved
        thread.is_outdated = node.isOutdated
        thread.viewer_can_reply = node.viewerCanReply
        thread.viewer_can_resolve = node.viewerCanResolve

        callback(nil)
    end)
end

---@param url string
---@return string?, string?
local function repository_from_url(url)
    return url:match("^https?://[^/]+/([^/]+)/([^/]+)/pull/%d+")
end

---@param metadata table
---@param root string
---@param callback fun(err: string?, pull_request: GhReviewPullRequest?)
local function fetch_review_data(metadata, root, callback)
    local owner, repository = repository_from_url(metadata.url)

    if not owner or not repository then
        callback("Could not determine repository from PR URL", nil)
        return
    end

    local threads = {}

    --- Walks `reviewThreads` a page at a time so nothing is silently dropped
    --- on a PR with more than 100 threads. The review data outside
    --- `reviewThreads` is identical on every page, so only the last one is
    --- used.
    ---@param cursor string?
    local function fetch_page(cursor)
        local args = {
            "gh",
            "api",
            "graphql",
            "-f",
            "query=" .. REVIEW_QUERY,
            "-F",
            "owner=" .. owner,
            "-F",
            "repo=" .. repository,
            "-F",
            "number=" .. metadata.number,
        }

        if cursor then
            vim.list_extend(args, { "-f", "cursor=" .. cursor })
        end

        run_json(args, root, function(err, response)
            if err then
                callback(err, nil)
                return
            end

            local raw_pull_request =
                response.data
                and response.data.repository
                and response.data.repository.pullRequest

            if not raw_pull_request then
                callback("Pull-request review data was not returned", nil)
                return
            end

            for _, thread in ipairs(
                raw_pull_request.reviewThreads.nodes or {}
            ) do
                table.insert(threads, normalize_thread(thread))
            end

            local page_info = raw_pull_request.reviewThreads.pageInfo

            if page_info and page_info.hasNextPage then
                fetch_page(nullable(page_info.endCursor))
                return
            end

            local change_requests = {}

            for _, review in ipairs(
                raw_pull_request.latestOpinionatedReviews.nodes or {}
            ) do
                if review.state == "CHANGES_REQUESTED" then
                    table.insert(
                        change_requests,
                        normalize_change_request(review)
                    )
                end
            end

            local review_decision = nullable(raw_pull_request.reviewDecision)

            ---@type GhReviewPullRequest
            local pull_request = {
                number = metadata.number,
                title = metadata.title,
                url = metadata.url,
                owner = owner,
                repository = repository,
                head_branch = metadata.headRefName,
                head_oid = metadata.headRefOid,
                root = root,

                review_decision = review_decision,

                has_changes_requested = review_decision == "CHANGES_REQUESTED" or #change_requests > 0,

                change_requests = change_requests,
                threads = threads,
            }

            callback(nil, pull_request)
        end)
    end

    fetch_page(nil)
end

---@param callback fun(err: string?, pull_request: GhReviewPullRequest?)
function M.fetch_current(callback)
    local root = vim.fs.root(0, ".git")

    if not root then
        callback("Current buffer is not inside a Git repository", nil)
        return
    end

    run_json({
        "gh",
        "pr",
        "view",
        "--json",
        "number,title,url,headRefName,headRefOid",
    }, root, function(err, metadata)
        if err then
            callback(err, nil)
            return
        end

        fetch_review_data(metadata, root, callback)
    end)
end

return M
