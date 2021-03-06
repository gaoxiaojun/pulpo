local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'

local NCLIENTS = 1000
local NITER = 100
local opts = {
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	datadir = '/tmp/pulpo'
}
thread.initialize(opts)
poller.initialize(opts)

local socket = require 'pulpo.socket'

local ADDR = "127.0.0.1:8888"
local a, b = ffi.new('pulpo_addr_t'), ffi.new('pulpo_addr_t')
a:set(ADDR)
assert(tostring(a) == ADDR)
b:set(ADDR)
assert(a == b)

return true