local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

-- Moves chat history between game versions (Retail, Forever, Classic...).
-- A game version cannot read another one's saved data, so history travels as
-- one pasteable text: serialised, compressed and base64 encoded. Importing
-- merges into what is already there and never duplicates a message.
--
-- Text never goes through loadstring: it is read by a small parser that only
-- builds plain strings, numbers, booleans and tables.
local HistoryTransfer = {}

local PREFIX = "SUSURRUS1"
local FORMAT_VERSION = 1

-- Only chats that belong to the whole account travel. Guild, party, raid and
-- channel chats are tied to one character and stay where they are.
local SYNC_KEY_PREFIXES = { "bnet::", "wow::", "bnconv::", "community::" }

-- Runtime state that is meaningless on another game version.
local SKIPPED_CONVERSATION_FIELDS = {
  unreadCount = true,
  unreadActivityCount = true,
  activeStatus = true,
  draft = true,
}

local MAX_DEPTH = 8
local MAX_PLAIN_BYTES = 6000000
local FALLBACK_MESSAGES_PER_CHAT = 50

local function isSyncKey(key)
  if type(key) ~= "string" then
    return false
  end
  for _, prefix in ipairs(SYNC_KEY_PREFIXES) do
    if string.sub(key, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- Serialise ------------------------------------------------------------------

local function serializeValue(value, out, depth)
  local kind = type(value)
  if kind == "string" then
    out[#out + 1] = "s" .. #value .. ":" .. value
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      out[#out + 1] = "Z"
    elseif value == math.floor(value) and math.abs(value) < 1e15 then
      out[#out + 1] = "n" .. string.format("%d", value) .. ";"
    else
      out[#out + 1] = "n" .. string.format("%.17g", value) .. ";"
    end
  elseif kind == "boolean" then
    out[#out + 1] = value and "T" or "F"
  elseif kind == "table" and depth <= MAX_DEPTH then
    out[#out + 1] = "{"
    for key, item in pairs(value) do
      local keyKind = type(key)
      local itemKind = type(item)
      if (keyKind == "string" or keyKind == "number") and (itemKind == "string" or itemKind == "number" or itemKind == "boolean" or itemKind == "table") then
        serializeValue(key, out, depth + 1)
        serializeValue(item, out, depth + 1)
      end
    end
    out[#out + 1] = "}"
  else
    out[#out + 1] = "Z"
  end
end

local function serialize(value)
  local out = {}
  serializeValue(value, out, 1)
  return table.concat(out)
end

local function parseValue(text, position, depth)
  if depth > MAX_DEPTH + 2 then
    error("too deep")
  end
  local kind = string.sub(text, position, position)
  if kind == "s" then
    local colon = string.find(text, ":", position + 1, true)
    if colon == nil or colon - position > 10 then
      error("bad string")
    end
    local length = tonumber(string.sub(text, position + 1, colon - 1))
    if length == nil or length < 0 or length ~= math.floor(length) then
      error("bad string length")
    end
    local finish = colon + length
    if finish > #text then
      error("truncated")
    end
    return string.sub(text, colon + 1, finish), finish + 1
  elseif kind == "n" then
    local semicolon = string.find(text, ";", position + 1, true)
    if semicolon == nil or semicolon - position > 30 then
      error("bad number")
    end
    local number = tonumber(string.sub(text, position + 1, semicolon - 1))
    if number == nil then
      error("bad number")
    end
    return number, semicolon + 1
  elseif kind == "T" then
    return true, position + 1
  elseif kind == "F" then
    return false, position + 1
  elseif kind == "Z" then
    return nil, position + 1
  elseif kind == "{" then
    local result = {}
    position = position + 1
    while true do
      if string.sub(text, position, position) == "}" then
        return result, position + 1
      end
      if position > #text then
        error("unterminated table")
      end
      local key
      key, position = parseValue(text, position, depth + 1)
      local keyKind = type(key)
      if keyKind ~= "string" and keyKind ~= "number" then
        error("bad key")
      end
      local item
      item, position = parseValue(text, position, depth + 1)
      result[key] = item
    end
  end
  error("unexpected data")
end

local function deserialize(text)
  local ok, value, position = pcall(parseValue, text, 1, 1)
  if not ok or type(value) ~= "table" or position ~= #text + 1 then
    return nil
  end
  return value
end

-- Compression (LZW, 12 bit codes) ---------------------------------------------

local CLEAR_CODE = 4095
local DICT_LIMIT = 4095

local function lzwCompress(input)
  local codes = {}
  local dict = {}
  local nextCode = 256
  local current = ""
  for index = 1, #input do
    local char = string.sub(input, index, index)
    local joined = current .. char
    if current == "" or dict[joined] ~= nil then
      current = joined
    else
      codes[#codes + 1] = (#current == 1) and string.byte(current) or dict[current]
      if nextCode < DICT_LIMIT then
        dict[joined] = nextCode
        nextCode = nextCode + 1
      else
        codes[#codes + 1] = CLEAR_CODE
        dict = {}
        nextCode = 256
      end
      current = char
    end
  end
  if current ~= "" then
    codes[#codes + 1] = (#current == 1) and string.byte(current) or dict[current]
  end
  return codes
end

local function lzwDecompress(codes)
  local dict = {}
  local nextCode = 256
  local previous = nil
  local out = {}
  for _, code in ipairs(codes) do
    if code == CLEAR_CODE then
      dict = {}
      nextCode = 256
      previous = nil
    else
      local entry
      if code < 256 then
        entry = string.char(code)
      elseif dict[code] ~= nil then
        entry = dict[code]
      elseif code == nextCode and previous ~= nil then
        entry = previous .. string.sub(previous, 1, 1)
      else
        return nil
      end
      out[#out + 1] = entry
      if previous ~= nil and nextCode < DICT_LIMIT then
        dict[nextCode] = previous .. string.sub(entry, 1, 1)
        nextCode = nextCode + 1
      end
      previous = entry
    end
  end
  return table.concat(out)
end

-- Two 12 bit codes fit in three bytes.
local function packCodes(codes)
  local bytes = {}
  for index = 1, #codes, 2 do
    local first = codes[index]
    local second = codes[index + 1]
    if second == nil then
      bytes[#bytes + 1] = string.char(math.floor(first / 16), (first % 16) * 16)
    else
      bytes[#bytes + 1] = string.char(math.floor(first / 16), (first % 16) * 16 + math.floor(second / 256), second % 256)
    end
  end
  return table.concat(bytes)
end

local function unpackCodes(bytes, count)
  local codes = {}
  local position = 1
  while #codes < count do
    local b1, b2, b3 = string.byte(bytes, position, position + 2)
    if b1 == nil or b2 == nil then
      return nil
    end
    codes[#codes + 1] = b1 * 16 + math.floor(b2 / 16)
    if #codes < count then
      if b3 == nil then
        return nil
      end
      codes[#codes + 1] = (b2 % 16) * 256 + b3
    end
    position = position + 3
  end
  return codes
end

-- Base64 ----------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENCODE = {}
local DECODE = {}
for index = 1, #ALPHABET do
  local char = string.sub(ALPHABET, index, index)
  ENCODE[index - 1] = char
  DECODE[char] = index - 1
end

local function base64Encode(bytes)
  local out = {}
  for index = 1, #bytes, 3 do
    local b1, b2, b3 = string.byte(bytes, index, index + 2)
    local value = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    local c1 = math.floor(value / 262144)
    local c2 = math.floor(value / 4096) % 64
    local c3 = math.floor(value / 64) % 64
    local c4 = value % 64
    out[#out + 1] = ENCODE[c1] .. ENCODE[c2] .. (b2 and ENCODE[c3] or "=") .. (b3 and ENCODE[c4] or "=")
  end
  return table.concat(out)
end

local function base64Decode(text)
  local out = {}
  local group = {}
  for index = 1, #text do
    local char = string.sub(text, index, index)
    local value = DECODE[char]
    if value ~= nil then
      group[#group + 1] = value
      if #group == 4 then
        local combined = group[1] * 262144 + group[2] * 4096 + group[3] * 64 + group[4]
        out[#out + 1] = string.char(math.floor(combined / 65536), math.floor(combined / 256) % 256, combined % 256)
        group = {}
      end
    elseif char == "=" then
      break
    elseif not string.find(char, "%s") then
      return nil
    end
  end
  if #group == 2 then
    local combined = group[1] * 262144 + group[2] * 4096
    out[#out + 1] = string.char(math.floor(combined / 65536))
  elseif #group == 3 then
    local combined = group[1] * 262144 + group[2] * 4096 + group[3] * 64
    out[#out + 1] = string.char(math.floor(combined / 65536), math.floor(combined / 256) % 256)
  elseif #group == 1 then
    return nil
  end
  return table.concat(out)
end

local function checksum(text)
  local low, high = 1, 0
  for index = 1, #text do
    low = (low + string.byte(text, index)) % 65521
    high = (high + low) % 65521
  end
  return high * 65536 + low
end

-- Export ----------------------------------------------------------------------

local function currentTime()
  if type(_G.time) == "function" then
    return _G.time()
  end
  return os.time()
end

local function exportableMessages(conversation, limit)
  local messages = {}
  for _, message in ipairs(conversation.messages or {}) do
    if type(message) == "table" and message.delivery ~= "queued" then
      messages[#messages + 1] = message
    end
  end
  if limit and #messages > limit then
    local trimmed = {}
    for index = #messages - limit + 1, #messages do
      trimmed[#trimmed + 1] = messages[index]
    end
    messages = trimmed
  end
  return messages
end

local function buildPayload(accountState, limit)
  local conversations = {}
  local count = 0
  for key, conversation in pairs(accountState.conversations or {}) do
    if isSyncKey(key) and type(conversation) == "table" then
      local messages = exportableMessages(conversation, limit)
      if #messages > 0 then
        local copy = {}
        for field, value in pairs(conversation) do
          if not SKIPPED_CONVERSATION_FIELDS[field] and field ~= "messages" then
            copy[field] = value
          end
        end
        copy.messages = messages
        conversations[key] = copy
        count = count + 1
      end
    end
  end
  return conversations, count
end

-- Returns the export text and the number of chats in it, plus true when a very
-- large history had to be cut to the newest lines of each chat. On failure it
-- returns nil and a reason ("empty" or "failed").
function HistoryTransfer.Export(accountState, options)
  options = options or {}
  if type(accountState) ~= "table" then
    return nil, "failed"
  end

  local conversations, count = buildPayload(accountState, nil)
  if count == 0 then
    return nil, "empty"
  end

  local payload = {
    v = FORMAT_VERSION,
    game = options.game,
    addon = options.addonVersion,
    at = currentTime(),
    conversations = conversations,
  }

  local ok, plain = pcall(serialize, payload)
  if not ok then
    return nil, "failed"
  end

  -- Very large histories keep only the newest lines of each chat so the
  -- text stays small enough to paste.
  local trimmed = false
  if #plain > MAX_PLAIN_BYTES then
    trimmed = true
    payload.conversations = buildPayload(accountState, FALLBACK_MESSAGES_PER_CHAT)
    ok, plain = pcall(serialize, payload)
    if not ok then
      return nil, "failed"
    end
  end

  local codes = lzwCompress(plain)
  local packed = packCodes(codes)
  return PREFIX .. ":" .. #codes .. ":" .. checksum(plain) .. ":" .. base64Encode(packed), count, trimmed
end

-- Import ----------------------------------------------------------------------

local function decodeText(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = string.gsub(text, "^%s+", "")
  local header, codeCount, expectedSum, body = string.match(trimmed, "^(%u+%d):(%d+):(%d+):(.*)$")
  if header ~= PREFIX then
    return nil
  end
  local bytes = base64Decode(body)
  if bytes == nil then
    return nil
  end
  local codes = unpackCodes(bytes, tonumber(codeCount))
  if codes == nil then
    return nil
  end
  local plain = lzwDecompress(codes)
  if plain == nil or checksum(plain) ~= tonumber(expectedSum) then
    return nil
  end
  local payload = deserialize(plain)
  if type(payload) ~= "table" or payload.v ~= FORMAT_VERSION or type(payload.conversations) ~= "table" then
    return nil
  end
  return payload
end

-- What makes two lines the same message even when each game version gave
-- it a different line id.
local function signature(message)
  return table.concat({
    tostring(math.floor(tonumber(message.sentAt) or 0)),
    tostring(message.direction or ""),
    tostring(message.kind or ""),
    tostring(message.playerName or ""),
    tostring(message.text or ""),
  }, "\31")
end

local function getMerge()
  return ns.ConversationMerge or require("Susurrus.Model.ConversationMerge")
end

local function mergeConversation(conversations, key, incoming, settings, now, stats)
  local existing = conversations[key]
  local seen = {}
  local usedIDs = {}
  if type(existing) == "table" then
    for _, message in ipairs(existing.messages or {}) do
      if type(message) == "table" then
        seen[signature(message)] = true
        if message.id ~= nil then
          usedIDs[message.id] = true
        end
      end
    end
  end

  local maxAge = tonumber(settings.messageMaxAge)
  local fresh = {}
  for _, message in ipairs(type(incoming.messages) == "table" and incoming.messages or {}) do
    if type(message) == "table" and type(message.sentAt) == "number" and message.delivery ~= "queued" then
      local sig = signature(message)
      if seen[sig] then
        stats.duplicates = stats.duplicates + 1
      elseif maxAge and now - message.sentAt > maxAge then
        stats.expired = stats.expired + 1
      else
        seen[sig] = true
        if message.id ~= nil and usedIDs[message.id] then
          message.id = "sync:" .. tostring(message.id)
        end
        fresh[#fresh + 1] = message
      end
    end
  end
  if #fresh == 0 then
    return
  end
  table.sort(fresh, function(left, right)
    return left.sentAt < right.sentAt
  end)

  local record = {}
  for field, value in pairs(incoming) do
    if not SKIPPED_CONVERSATION_FIELDS[field] and field ~= "messages" then
      record[field] = value
    end
  end
  record.messages = fresh
  record.unreadCount = 0
  record.unreadActivityCount = 0
  record.conversationKey = key

  local tempKey = "__sync__" .. key
  conversations[tempKey] = record
  getMerge().Rekey(conversations, tempKey, key, tonumber(settings.maxMessagesPerConversation) or 200)

  stats.added = stats.added + #fresh
  stats.conversations = stats.conversations + 1
end

-- Merges pasted export text into accountState. Returns true and a stats table
-- ({ added, duplicates, expired, conversations }), or false and a reason
-- ("invalid" when the text is not a Susurrus export).
function HistoryTransfer.Import(accountState, text, options)
  options = options or {}
  if type(accountState) ~= "table" then
    return false, "invalid"
  end
  local payload = decodeText(text)
  if payload == nil then
    return false, "invalid"
  end

  accountState.conversations = accountState.conversations or {}
  local settings = accountState.settings or {}
  local now = options.now or currentTime()
  local stats = { added = 0, duplicates = 0, expired = 0, conversations = 0 }

  local keys = {}
  for key in pairs(payload.conversations) do
    if isSyncKey(key) and type(payload.conversations[key]) == "table" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    mergeConversation(accountState.conversations, key, payload.conversations[key], settings, now, stats)
  end
  return true, stats
end

HistoryTransfer._internal = {
  serialize = serialize,
  deserialize = deserialize,
  lzwCompress = lzwCompress,
  lzwDecompress = lzwDecompress,
  base64Encode = base64Encode,
  base64Decode = base64Decode,
  packCodes = packCodes,
  unpackCodes = unpackCodes,
}

ns.HistoryTransfer = HistoryTransfer
return HistoryTransfer
