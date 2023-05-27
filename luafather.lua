local ltn12 = require("ltn12")
local cjson = require("cjson")

local unpack = table.unpack or unpack

local function request(self, method, chat_id, data)
  local http = require(self.http)
  local url = string.format(self.api, self.token, string.gsub(method, "_([^_]+)", function(word)
    return string.format("%s%s", string.upper(string.sub(word, 1, 1)), string.lower(string.sub(word, 2)))
  end))
  local body = cjson.encode(data)
  if chat_id and body.chat_id == nil then
    body.chat_id = chat_id
  end
  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = #body
  }
  if self.headers then
    for key, value in pairs(self.headers) do
      headers[key] = value
    end
  end
  local out = {}
  local source = ltn12.source.string(body)
  local sink = ltn12.sink.table(out)
  local _, status = http.request({
    sink = sink,
    source = source,
    url = url,
    headers = headers
  })
  local response = table.concat(out)
  pcall(function()
    response = cjson.decode(response)
  end)
  return response, status
end

local function trigger(self, keys)
  return setmetatable({}, {
    __call = function(_, ...)
      local value = select(1, ...)
      if keys.n == 1 and value == self then
        return request(self, keys[1], _, select(2, ...))
      end
      self.triggers[#self.triggers + 1] = {keys, value}
      return self.triggers[#self.triggers]
    end,
    __index = function(_, key)
      keys.n = keys.n + 1
      keys[keys.n] = key
      return trigger(self, keys)
    end
  })
end
  
local function match(values, keys, matches, current)
  if current > #keys then
    return values, unpack(matches, 1, matches.n)
  end
  local key = keys[current]
  current = current + 1
  if type(key) == "table" then
    local source = key
    key = function(options)
      if type(options) == "table" then
        for index, value in pairs(source) do
          local option = options[value]
          if option and type(index) == "number" then
            return option, value
          else
            option = options[index]
            if option == value then
              return option, index
            elseif type(value) == "table" then
              for current = 1, #value do
                if option == value[current] then
                  return option, index
                end
              end
            end
          end
        end
      end
    end
  end
  if type(key) == "function" then
    local value = (function(...)
      local total = select("#", ...)
      if total == 0 then
        return 
      end
      for index = 2, total do
        matches[matches.n + index - 1] = select(index, ...)
      end
      matches.n = matches.n + total - 1
      return ...
    end)(key(values, unpack(matches, 1, matches.n)))
    if value ~= nil then
      return match(value, keys, matches, current)
    end
  else
    if type(values) == "table" then
      local value = values[key]
      if value then
        return match(value, keys, matches, current)
      end
    end
  end
end

local function object(self, value, chat_id)
  return setmetatable({}, {
    __index = function(this, key)
      local index = rawget(value, key)
      if index then
        return index
      end
      return function(parent, ...)
        if parent == this then
          request(self, key, chat_id, select(2, ...))
          return parent
        end
      end    
    end,
    __call = function()
      return coroutine.yield()
    end
  })  
end

local function session(self, value, id)
  return setmetatable({}, {
    __call = function(_, ...)
      local chat_id, fn = ...
      if type(chat_id) == "function" then
        fn = chat_id
        chat_id = id
      end
      local session = self.sessions[tostring(chat_id)]
      local time = self.time()
      if session then
        local thread = session.thread
        local status = coroutine.status(thread)
        if status == "suspended" then
          session.time = time
          coroutine.resume(thread, object(self, value))
        elseif status == "dead" then
          session.time = 0
          self.sessions[session.id] = nil
          session = nil
        end
      end
      if not session then
        if self.cache > 0 and #self.sessions > self.cache then
          table.sort(self.sessions, function(left, right)
            return left.time < right.time
          end)
          self.sessions[table.remove(self.sessions, 1).id] = nil
        end
        session = {
          id = tostring(chat_id),
          thread = coroutine.create(fn),
          time = time
        }
        self.sessions[#self.sessions + 1] = session
        self.sessions[session.id] = session
        coroutine.resume(session.thread, object(self, value))
      end
    end,
    __index = value
  })
end

return function(...)
  local self = {}
  self.token, self.options = ...
  if type(self.token) == "table" then
    self.options = self.token
    self.token = self.options.token
  end
  assert(type(self.token) == "string", "bot token required") 
  self.options = self.options or {}
  self.time = self.options.time or (_G.ngx and ngx.time or os.time)
  self.cache = self.options.cache or 64
  self.http = self.options.http or (_G.ngx and "lapis.nginx.http" or "ssl.https")
  self.api = self.options.api or "https://api.telegram.org/bot%s/%s"
  self.headers = self.options.headers or {}
  self.triggers = {}
  self.sessions = {}
  return setmetatable(self, {
    __index = function(this, key)
      local index = rawget(this, key)
      if index then
        return index
      end
      return trigger(this, {key, n = 1})      
    end,
    __call = function(_, value)
      if type(value) == "function" then
        self.triggers[#self.triggers + 1] = {{n = 0}, value}
      elseif type(value) == "table" then
        for _, trigger in pairs(self.triggers) do
          local values
          if (function(...)
            if select("#", ...) > 0 then
              values = (function(...)
                return {n = select("#", ...), ...}
              end)(trigger[2](session(self, value, ...), ...))
              if values.n > 0 then
                return true
              end
            end
          end)(match(value, trigger[1], {n = 0}, 1)) then
            return unpack(values, 1, values.n)
          end
        end
      end
    end
  })
end
