local ffi = require 'ffiex.init'
local pulpo = require 'pulpo.init'
local tentacle = pulpo.tentacle
local gen = require 'pulpo.generics'
local memory = require 'pulpo.memory'
-- local tcp = require 'pulpo.io.tcp'

local C = ffi.C

require 'test.tools.config'

local loop = pulpo.evloop
local tcp = loop.io.tcp
local config = pulpo.util.getarg('test_config_t*', ...) --pulpo.shared_memory('config')
local concurrency = math.floor(config.n_client / config.n_client_core)
local finished = pulpo.shared_memory('finished', function ()
	local t = gen.rwlock_ptr('exec_state_t')
	local p = memory.alloc_typed(t)
	p:init(function (data) 
		data.cnt = 0 
		data.start_time = os.clock()
	end)
	return t, p
end)

local client_msg = ("hello,luact poll"):rep(16)
for i=0,concurrency - 1,1 do
	tentacle(function ()
		local s = tcp.connect('127.0.0.1:'..tostring(config.port))
-- logger.info("start tentacle", s:fd())
		io.stdout:write("-"); io.stdout:flush()
		local ptr,len = ffi.new('char[256]')
		local i = 0
		while i < config.n_iter do
			-- print('write start:', s:fd())
			s:write(client_msg, #client_msg)
			-- print('write end:', s:fd())
			len = s:read(ptr, 256) --> malloc'ed char[?]
			if len <= 0 then
				logger.info('closed', s:fd())
				break
			end
			local msg = ffi.string(ptr,len)
			pulpo_assert(msg == client_msg, "illegal packet received:"..msg)
			i = i + 1
		end
		local cnt = finished:write(function (data)
			io.stdout:write("+"); io.stdout:flush()
			data.cnt = data.cnt + 1
			return data.cnt
		end)
		if cnt >= config.n_client then
			io.stdout:write("\n")
			logger.info('test takes', os.clock() - finished.data.start_time, 'sec')
			pulpo.stop()
			config.finished = true
		end
	end)
end
