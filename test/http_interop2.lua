-- interop with other http server (google)
local pulpo = require 'pulpo.init'

pulpo.initialize({
	datadir = '/tmp/pulpo'
})

pulpo.run({
	n_core = 1,
	exclusive = true,
}, function ()
	local pulpo = require 'pulpo.init'
	local tentacle = require 'pulpo.tentacle'
	local ffi = require 'ffiex.init'
	local http = pulpo.evloop.io.http

	-- interop with other http client application
	tentacle(function ()
		local msg = 'hello world'
		local s = http.connect('www.google.com:80')
		s:write({
			"GET", "/",
		})
		local resp = s:read()
		local status, headers, b, blen = resp:payload()
		if headers:getstr("Server") == "gws" then
			assert(status == 200)
			assert(headers:getstr("Alternate-Protocol"):match('quic'))
		else
			assert(status == 302)
			assert(headers:getstr("Server"):match("^GFE"))
			assert(headers:getstr("Location"):match("^http://www.google%.co%.jp/%?"))
		end
		resp:fin()
		print('graceful stop')
		pulpo.stop()
	end)
	return true
end)

return true
