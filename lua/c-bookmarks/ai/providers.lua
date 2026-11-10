---Command-line AI providers for the explain and ask commands.
local M = {}

---@class CBookmarks.ExplainContext
---@field root string project root, also the subprocess cwd
---@field prompt string full prompt text
---@field model string? provider model id, nil for the provider default
---@field extra_args string[] appended before the prompt
---@field schema? table JSON Schema the reply must match; nil asks for text

---@class CBookmarks.Provider
---@field name string
---@field command fun(ctx: CBookmarks.ExplainContext): string[]
---@field parse fun(stdout: string): table?, string? the group object, else an error
---@field answer fun(stdout: string): string?, string? the reply text, else an error
---@field models? string[] choices offered by the model picker

---JSON Schema of the group a provider must return.
M.group_schema = {
  type = "object",
  additionalProperties = false,
  required = { "name", "bookmarks" },
  properties = {
    name = { type = "string" },
    bookmarks = {
      type = "array",
      minItems = 1,
      items = {
        type = "object",
        additionalProperties = false,
        required = { "path", "lnum", "end_lnum", "note" },
        properties = {
          name = { type = "string" },
          path = { type = "string" },
          lnum = { type = "integer", minimum = 1 },
          end_lnum = { type = "integer", minimum = 1 },
          note = { type = "string" },
          anchor = { type = "string" },
        },
      },
    },
  },
}

---Finds the JSON object in free text, fenced or bare.
---@param text string
---@return table?, string? error
function M.extract_json(text)
  local candidate = text:match "```json%s*(%b{})%s*```" or text:match "```%s*(%b{})%s*```" or text:match "(%b{})"
  if not candidate then return nil, "no JSON object in the reply" end

  local ok, value = pcall(vim.json.decode, candidate, { luanil = { object = true, array = true } })
  if not ok then return nil, "invalid JSON in the reply: " .. tostring(value) end

  return value
end

---Decodes a `claude --output-format json` envelope.
---@param stdout string
---@return table?, string? error
local function envelope_of(stdout)
  local ok, envelope = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
  if not ok or type(envelope) ~= "table" then return nil, "unreadable claude output" end
  if envelope.is_error then return nil, tostring(envelope.result or envelope.error or "claude reported an error") end

  return envelope
end

---@type CBookmarks.Provider
M.claude = {
  name = "claude",
  models = { "sonnet", "opus", "haiku", "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" },
  command = function(ctx)
    -- the prompt comes right after -p: later flags take variadic lists
    local cmd = { "claude", "-p", ctx.prompt, "--output-format", "json", "--allowedTools", "Read,Glob,Grep" }
    if ctx.schema then vim.list_extend(cmd, { "--json-schema", vim.json.encode(ctx.schema) }) end
    if ctx.model then vim.list_extend(cmd, { "--model", ctx.model }) end

    vim.list_extend(cmd, ctx.extra_args or {})
    return cmd
  end,
  parse = function(stdout)
    local envelope, err = envelope_of(stdout)
    if not envelope then return nil, err end
    if type(envelope.structured_output) == "table" then return envelope.structured_output end
    if type(envelope.result) == "string" then return M.extract_json(envelope.result) end

    return nil, "claude returned no result"
  end,
  answer = function(stdout)
    local envelope, err = envelope_of(stdout)
    if not envelope then return nil, err end
    if type(envelope.result) == "string" and vim.trim(envelope.result) ~= "" then return vim.trim(envelope.result) end

    return nil, "claude returned no result"
  end,
}

---@param name string
---@param custom? table<string, CBookmarks.Provider>
---@return CBookmarks.Provider?
function M.get(name, custom) return (custom and custom[name]) or M[name] or nil end

return M
