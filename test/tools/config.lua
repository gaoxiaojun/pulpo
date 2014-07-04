local ffi = require 'ffiex'
local gen = require 'pulpo.generics'

ffi.cdef [[
	typedef struct test_config {
		int n_iter;
		int n_client;
		int n_client_core;
		int n_server_core;
		bool finished;
	} test_config_t;
	typedef struct exec_state {
		int cnt;
		double start_time;
	} exec_state_t;
]]
gen.rwlock_ptr('exec_state_t')
-- print('ffi:cdef:test_config', debug.traceback())