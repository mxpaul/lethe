local M = {}

local log = require('log')
local spacer = require("spacer")

local function init()
	spacer.create_space('message',
		{ -- Spaces
			{name = 'ident',   type = 'str'},      -- 1
			{name = 'message', type = 'str'},      -- 2
			{name = 'created', type = 'unsigned'}, -- 3
			{name = 'expires', type = 'unsigned'}, -- 4
		},
		{ -- Indices
			{name = 'primary', type = 'hash', parts = {'ident'}},
			{name = 'expires', type = 'tree', parts = {'expires'}},
		}
	)
	math.randomseed(os.time())
end

function M.add_msg(self, message)
	local ident = self:random_id()
	local t = {ident, message, os.time(), os.time()+86400*3}
	local space = box.space.message
	log.info("IDENT: %s",ident)
	space:insert(t)
	return ident
end

function M.get_msg(self, ident)
	-- log.info("ENTER get_msg")
	local space = box.space.message
	local key = {ident}
	local res = space:select(key)
	-- log.info('after select: %s type(res)=%s %d', ident, type(res), #res)
	if #res == 0 then
		return nil
	end
	local t = res[1]
	local expires = t[4]
	if expires < os.time() then
		return nil
	end
	local message = t[2]
	space:delete(key)
	return message
end

function M.random_id(self)
  local random_number
  local random_string
  random_string = ""
  for x = 1,20,1 do
    random_number = math.random(65, 90)
    random_string = random_string .. string.char(random_number)
  end
  return random_string
end

function M.list_expired_messages(self, limit)
	limit = limit or 100
	local space = box.space.message
	local index = space.index.expires
	local expiredMessages = {}
	local i = 1
	for _, t in index:pairs({os.time()}, {iterator = box.index.LT}) do
		if i > limit then break end
		table.insert(expiredMessages, t[1])
		i = i + 1
	end
	return expiredMessages
end

function M.drop_expired_messages(self, limit)
	limit = limit or 100
	local space = box.space.message
	local droplist = self:list_expired_messages(limit)
	for _, id in pairs(droplist) do
		log.info('delete expired message ' .. id)
		space:delete({id})	
	end
end


init()

return M
