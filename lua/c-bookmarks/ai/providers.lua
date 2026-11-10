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
---@field error? fun(stdout: string): string? the failure the CLI reported, if any
---@field models? string[]|fun(): string[] choices offered by the model picker

---Built-in providers in picker order.
M.names = { "claude", "codex", "opencode" }

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
  -- %b{} miscounts braces inside strings, so it goes last
  local patterns = { "^%s*({.*})%s*$", "```json%s*({.*})%s*```", "{.*}", "%b{}" }
  local first_error
  for _, pattern in ipairs(patterns) do
    local candidate = text:match(pattern)
    if candidate then
      local ok, value = pcall(vim.json.decode, candidate, { luanil = { object = true, array = true } })
      if ok and type(value) == "table" then return value end

      first_error = first_error or value
    end
  end

  if not first_error then return nil, "no JSON object in the reply" end

  return nil, "invalid JSON in the reply: " .. tostring(first_error)
end

---Copy of a schema with every property required.
---OpenAI strict mode rejects optional properties.
---@param schema table
---@return table
function M.strict_schema(schema)
  local copy = vim.deepcopy(schema)
  local function visit(node)
    if type(node) ~= "table" then return end
    if node.properties then
      node.required = vim.tbl_keys(node.properties)
      table.sort(node.required)
      for _, child in pairs(node.properties) do
        visit(child)
      end
    end

    visit(node.items)
  end

  visit(copy)
  return copy
end

---Decodes JSON Lines, skipping lines that are not objects.
---@param stdout string
---@return table[]
local function events_of(stdout)
  local events = {}
  for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(event) == "table" then events[#events + 1] = event end
  end

  return events
end

---Pulls the message out of an API error that arrives as JSON text.
---@param message any
---@return string
local function unwrap(message)
  message = tostring(message)
  local ok, inner = pcall(vim.json.decode, message)
  if ok and type(inner) == "table" and type(inner.error) == "table" and inner.error.message then
    return tostring(inner.error.message)
  end

  return message
end

---The first failure reported in JSON Lines events.
---@param stdout string
---@param failure fun(event: table): string?
---@return string?
local function first_failure(stdout, failure)
  for _, event in ipairs(events_of(stdout)) do
    local err = failure(event)
    if err then return err end
  end

  return nil
end

---Reads the last reply from JSON Lines events, or the reported failure.
---@param who string provider name for messages
---@param stdout string
---@param failure fun(event: table): string?
---@param text fun(event: table): string?
---@return string?, string? error
local function reply_of(who, stdout, failure, text)
  local events = events_of(stdout)
  if #events == 0 then return nil, "unreadable " .. who .. " output" end

  local reply
  for _, event in ipairs(events) do
    local err = failure(event)
    if err then return nil, err end

    reply = text(event) or reply
  end

  if reply and vim.trim(reply) ~= "" then return vim.trim(reply) end

  return nil, who .. " returned no result"
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
  error = function(stdout)
    local envelope, err = envelope_of(stdout)
    return not envelope and err ~= "unreadable claude output" and err or nil
  end,
}

---@param event table
---@return string?
local function codex_failure(event)
  if event.type == "turn.failed" then return unwrap(type(event.error) == "table" and event.error.message) end
  if event.type == "error" then return unwrap(event.message) end

  return nil
end

---@param event table
---@return string?
local function codex_text(event)
  local item = event.type == "item.completed" and event.item
  return type(item) == "table" and item.type == "agent_message" and item.text or nil
end

---@param stdout string
---@return string?, string? error
local function codex_reply(stdout) return reply_of("codex", stdout, codex_failure, codex_text) end

---@type CBookmarks.Provider
M.codex = {
  name = "codex",
  models = { "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark" },
  command = function(ctx)
    local cmd = { "codex", "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral" }
    if ctx.schema then
      -- codex only reads the schema from a file
      local path = vim.fn.tempname() .. ".json"
      vim.fn.writefile({ vim.json.encode(M.strict_schema(ctx.schema)) }, path)
      vim.list_extend(cmd, { "--output-schema", path })
    end

    if ctx.model then vim.list_extend(cmd, { "--model", ctx.model }) end

    vim.list_extend(cmd, ctx.extra_args or {})
    vim.list_extend(cmd, { "--", ctx.prompt })
    return cmd
  end,
  parse = function(stdout)
    local text, err = codex_reply(stdout)
    if not text then return nil, err end

    return M.extract_json(text)
  end,
  answer = codex_reply,
  error = function(stdout) return first_failure(stdout, codex_failure) end,
}

---@param event table
---@return string?
local function opencode_failure(event)
  if event.type ~= "error" then return nil end

  local err = type(event.error) == "table" and event.error or {}
  local data = type(err.data) == "table" and err.data or {}
  return unwrap(data.message or err.message or err.name or "opencode reported an error")
end

---@param event table
---@return string?
local function opencode_text(event)
  local part = event.type == "text" and event.part
  return type(part) == "table" and part.text or nil
end

---@param stdout string
---@return string?, string? error
local function opencode_reply(stdout) return reply_of("opencode", stdout, opencode_failure, opencode_text) end

---@type CBookmarks.Provider
M.opencode = {
  name = "opencode",
  models = function()
    local ok, result = pcall(function() return vim.system({ "opencode", "models" }, { text = true }):wait(10000) end)
    if not ok or result.code ~= 0 then return {} end

    return vim.split(vim.trim(result.stdout or ""), "\n", { plain = true, trimempty = true })
  end,
  command = function(ctx)
    local prompt = ctx.prompt
    if ctx.schema then
      -- opencode run has no schema flag
      prompt = prompt
        .. "\n\nReply with only a JSON object matching this JSON Schema, no prose around it:\n"
        .. vim.json.encode(ctx.schema)
    end

    -- the plan agent cannot edit files
    local cmd = { "opencode", "run", "--format", "json", "--agent", "plan" }
    if ctx.model then vim.list_extend(cmd, { "--model", ctx.model }) end

    vim.list_extend(cmd, ctx.extra_args or {})
    vim.list_extend(cmd, { "--", prompt })
    return cmd
  end,
  parse = function(stdout)
    local text, err = opencode_reply(stdout)
    if not text then return nil, err end

    return M.extract_json(text)
  end,
  answer = opencode_reply,
  error = function(stdout) return first_failure(stdout, opencode_failure) end,
}

---Why a run failed: the provider's own report, else stderr.
---@param provider CBookmarks.Provider
---@param result vim.SystemCompleted
---@return string
function M.failure(provider, result)
  local reported = provider.error and provider.error(result.stdout or "")
  if reported then return reported end

  return vim.trim((result.stderr ~= "" and result.stderr) or result.stdout or "")
end

---@param name string
---@param custom? table<string, CBookmarks.Provider>
---@return CBookmarks.Provider?
function M.get(name, custom) return (custom and custom[name]) or M[name] or nil end

return M
