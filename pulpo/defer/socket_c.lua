local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local exception = require 'pulpo.exception'
local loader = require 'pulpo.loader'
local raise = exception.raise

local C = ffi.C
local _M = (require 'pulpo.package').module('pulpo.defer.socket_c')

local CDECLS = {
	"socket", "connect", "listen", "setsockopt", "bind", "accept", 
	"recv", "send", "recvfrom", "sendto", "close", "getaddrinfo", "freeaddrinfo", "inet_ntop", 
	"fcntl", "dup", "read", "write", "writev", "sendfile", 
	"getifaddrs", "freeifaddrs", "getsockname", "getpeername",
	"struct iovec", "pulpo_bytes_op_t", "pulpo_sockopt_t", "pulpo_addr_t", 
	"struct ifreq", "struct ip_mreq", 
}
local CHEADER = [[
	#include <sys/socket.h>
	#include <sys/uio.h>
	#include <sys/ioctl.h>
	%s
	#include <arpa/inet.h>
	#include <netdb.h>
	#include <unistd.h>
	#include <fcntl.h>
	#include <ifaddrs.h>
	#include <net/if.h>
	typedef union pulpo_bytes_op {
		unsigned char p[0];
		unsigned short s;
		unsigned int l;
		unsigned long long ll;
	} pulpo_bytes_op_t;
	typedef struct pulpo_sockopt {
		union {
			char p[sizeof(int)];
			int data;
		} rblen;
		union {
			char p[sizeof(int)];
			int data;
		} wblen;
		int timeout;
		bool blocking;
	} pulpo_sockopt_t;
	typedef struct pulpo_addr {
		union {
			struct sockaddr_in addr4;
			struct sockaddr_in6 addr6;
			struct sockaddr p[1];
		};
		socklen_t len[1];
	} pulpo_addr_t;
]]
if ffi.os == "Linux" then
	-- enum declaration required
	table.insert(CDECLS, "enum __socket_type")
	CHEADER = CHEADER:format("#include <sys/sendfile.h>")
elseif ffi.os == "OSX" then
	CHEADER = CHEADER:format("")
end
local ffi_state = loader.load("socket.lua", CDECLS, {
	"AF_INET", "AF_INET6", "AF_UNIX", 
	"SOCK_STREAM", 
	"SOCK_DGRAM", 
	"SOL_SOCKET", 
		"SO_REUSEADDR", 
		"SO_SNDTIMEO",
		"SO_RCVTIMEO",
		"SO_SNDBUF",
		"SO_RCVBUF",
	"F_GETFL",
	"F_SETFL", 
		"O_NONBLOCK",
	"IFNAMSIZ",
	"SIOCGIFADDR",
	"IPPROTO_IP", 
		"IP_MULTICAST_IF", 
		"IP_MULTICAST_TTL",
		"IP_ADD_MEMBERSHIP", 
	nice_to_have = {
		"SO_REUSEPORT",
	}, 
}, nil, CHEADER)

-- TODO : current 'inet_namebyhost' implementation assumes binary layout of sockaddr_in and sockaddr_in6, 
-- is same at first 4 byte (sa_family and sin_port) 
assert(ffi.offsetof('struct sockaddr_in', 'sin_family') == ffi.offsetof('struct sockaddr_in6', 'sin6_family'))
assert(ffi.offsetof('struct sockaddr_in', 'sin_port') == ffi.offsetof('struct sockaddr_in6', 'sin6_port'))

local SOCK_STREAM, SOCK_DGRAM
if ffi.os == "OSX" then
SOCK_STREAM = ffi_state.defs.SOCK_STREAM
SOCK_DGRAM = ffi_state.defs.SOCK_DGRAM
elseif ffi.os == "Linux" then
SOCK_STREAM = ffi.cast('enum __socket_type', ffi_state.defs.SOCK_STREAM)
SOCK_DGRAM = ffi.cast('enum __socket_type', ffi_state.defs.SOCK_DGRAM)
end
local SOL_SOCKET = ffi_state.defs.SOL_SOCKET
local SO_REUSEADDR = ffi_state.defs.SO_REUSEADDR
local SO_REUSEPORT = ffi_state.defs.SO_REUSEPORT
local SO_SNDTIMEO = ffi_state.defs.SO_SNDTIMEO
local SO_RCVTIMEO = ffi_state.defs.SO_RCVTIMEO
local SO_SNDBUF = ffi_state.defs.SO_SNDBUF
local SO_RCVBUF = ffi_state.defs.SO_RCVBUF
local AF_INET = ffi_state.defs.AF_INET
local AF_UNIX = ffi_state.defs.AF_UNIX

local F_SETFL = ffi_state.defs.F_SETFL
local F_GETFL = ffi_state.defs.F_GETFL
local O_NONBLOCK = ffi_state.defs.O_NONBLOCK

local IPPROTO_IP = ffi_state.defs.IPPROTO_IP
local IP_MULTICAST_IF = ffi_state.defs.IP_MULTICAST_IF
local IP_MULTICAST_TTL = ffi_state.defs.IP_MULTICAST_TTL
local IP_ADD_MEMBERSHIP = ffi_state.defs.IP_ADD_MEMBERSHIP

local AI_NUMERICHOST = ffi_state.defs.AI_NUMERICHOST

local IFNAMSIZ = ffi_state.defs.IFNAMSIZ

local SIOCGIFADDR = ffi_state.defs.SIOCGIFADDR

-- TODO : support PDP_ENDIAN (but which architecture uses this endian?)
local LITTLE_ENDIAN
if ffi.os == "OSX" then
	-- should check __DARWIN_BYTE_ORDER intead of BYTE_ORDER
	ffi_state = loader.load("endian.lua", {}, {
		"__DARWIN_BYTE_ORDER", "__DARWIN_LITTLE_ENDIAN", "__DARWIN_BIG_ENDIAN", "__DARWIN_PDP_ENDIAN"
	}, nil, [[
		#include <sys/types.h>
	]])
	pulpo_assert(ffi_state.defs.__DARWIN_BYTE_ORDER ~= ffi_state.defs.__DARWIN_PDP_ENDIAN, "unsupported endian: PDP")
	LITTLE_ENDIAN = (ffi_state.defs.__DARWIN_BYTE_ORDER == ffi_state.defs.__DARWIN_LITTLE_ENDIAN)
elseif ffi.os == "Linux" then
	ffi_state = loader.load("endian.lua", {}, {
		"__BYTE_ORDER", "__LITTLE_ENDIAN", "__BIG_ENDIAN", "__PDP_ENDIAN"
	}, nil, [[
		#include <endian.h>
	]])
	pulpo_assert(ffi_state.defs.__BYTE_ORDER ~= ffi_state.defs.__PDP_ENDIAN, "unsupported endian: PDP")
	LITTLE_ENDIAN = (ffi_state.defs.__BYTE_ORDER == ffi_state.defs.__LITTLE_ENDIAN)
end


--> ctype pulpo_addr_t 
local addr_index = {}
local function addr_equal(a1, a2)
	if a1.len[0] ~= a2.len[0] then
		return false
	end
	return memory.cmp(a1.p, a2.p, a1.len[0])
end
local function addr_tostring(self)
	return _M.inet_namebyhost(self.p, true)
end
local addr_mt = {
	__index = addr_index,
	__tostring = addr_tostring,
	__eq = addr_equal,
}
function addr_index:set(addrstr, socktype)
	self.len[0] = _M.inet_hostbyname(addrstr, self.p, socktype)
end
function addr_index:init()
	self.len[0] = (ffi.sizeof('pulpo_addr_t') - ffi.sizeof('socklen_t'))
end
function addr_index:dump()
	io.write('buffer:len:')
	io.write(self.len[0])
	io.write(' ')
	if self.len[0] > 0 then
		for i=0,self.len[0]-1 do
			io.write((':%02x'):format((ffi.cast('unsigned char *', self.p))[i]))
		end
	end
	io.write('\n')
end
ffi.metatype('pulpo_addr_t', addr_mt)


--> exception
exception.define('syscall', {
	message = function (t)
		return ('%s fails(%d) on %s'):format(t.args[1], t.args[3] or ffi.errno(), tostring(t.args[2]))
	end,
})
exception.define('pipe', {
	message = function (t)
		return ('remote peer closed')
	end,
})

-- returns true if litten endian arch, otherwise big endian. 
-- now this framework does not support pdp endian.
function _M.little_endian()
	return LITTLE_ENDIAN
end

--> htons/htonl/ntohs/ntohl 
--- borrow from http://svn.fonosfera.org/fon-ng/trunk/luci/libs/core/luasrc/ip.lua

--- Convert given short value to network byte order on little endian hosts
-- @param x	Unsigned integer value between 0x0000 and 0xFFFF
-- @return	Byte-swapped value
-- @see		htonl
-- @see		ntohs
function _M.htons(x)
	if LITTLE_ENDIAN then
		return bit.bor(
			bit.rshift( x, 8 ),
			bit.band( bit.lshift( x, 8 ), 0xFF00 )
		)
	else
		return x
	end
end

--- Convert given long value to network byte order on little endian hosts
-- @param x	Unsigned integer value between 0x00000000 and 0xFFFFFFFF
-- @return	Byte-swapped value
-- @see		htons
-- @see		ntohl
function _M.htonl(x)
	if LITTLE_ENDIAN then
		return bit.bor(
			bit.lshift( _M.htons( bit.band( x, 0xFFFF ) ), 16 ),
			_M.htons( bit.rshift( x, 16 ) )
		)
	else
		return x
	end
end

--- Convert given short value to host byte order on little endian hosts
-- @class	function
-- @name	ntohs
-- @param x	Unsigned integer value between 0x0000 and 0xFFFF
-- @return	Byte-swapped value
-- @see		htonl
-- @see		ntohs
_M.ntohs = _M.htons

--- Convert given short value to host byte order on little endian hosts
-- @class	function
-- @name	ntohl
-- @param x	Unsigned integer value between 0x00000000 and 0xFFFFFFFF
-- @return	Byte-swapped value
-- @see		htons
-- @see		ntohl
_M.ntohl = _M.htonl

--> misc network function
--> may seems functions not to be reentrant, but actually when luact runs with multithread mode, 
--> independent state is assigned to each thread. so its actually reentrant and thread safe.
local addrinfo_buffer = ffi.new('struct addrinfo * [1]')
local hint_buffer = ffi.new('struct addrinfo[1]')
function _M.inet_hostbyname(addr, addrp, socktype)
	-- print(addr, addrp, socktype, debug.traceback())
	local s,e,host,port = addr:find('([%w%.%_]+):([0-9]+)')
	if not s then 
		return -1
	end
	local sa = ffi.cast('struct sockaddr*', addrp)
	local ab, af, protocol, r
	socktype = socktype or SOCK_STREAM
	hint_buffer[0].ai_socktype = tonumber(socktype)
	if C.getaddrinfo(host, port, hint_buffer, addrinfo_buffer) < 0 then
		return -2
	end
	-- TODO : is it almost ok to use first entry of addrinfo?
	-- create socket and try to bind/connect seems costly for checking
	if addrinfo_buffer[0] ~= ffi.NULL then
		ab = addrinfo_buffer[0]
		af = ab.ai_family
		protocol = ab.ai_protocol
		r = ab.ai_addrlen
		ffi.copy(addrp, ab.ai_addr, r)
		-- TODO : cache addrinfo_buffer[0] with addr as key
		C.freeaddrinfo(addrinfo_buffer[0])
		addrinfo_buffer[0] = ffi.NULL
	end
	return r, af, socktype, protocol
end
function _M.inet_namebyhost(addrp, withport, dst, len)
	if not dst then
		dst = ffi.new('char[256]')
		len = 256
	end
	local sa = ffi.cast('struct sockaddr_in*', addrp)
	local sin_addr_p = (ffi.cast('char *', addrp) + ffi.offsetof('struct sockaddr_in', 'sin_addr'))
	local p = C.inet_ntop(sa.sin_family, sin_addr_p, dst, len)
	if p == ffi.NULL then
		exception.raise('invalid', 'addr data', ffi.errno(), sa.sin_family)
	else
		return ffi.string(dst)..(withport and (":"..tostring(_M.ntohs(sa.sin_port))) or "")
	end
end
local sockaddr_buf_work = ffi.new('pulpo_addr_t[1]')
function _M.inet_peerbyfd(fd, dst, len)
	if not dst then
		dst = ffi.cast('struct sockaddr*', sockaddr_buf_work)
		len = ffi.sizeof('pulpo_addr_t')
	end
	sockaddr_buf_work.len[0] = len
	if (C.getpeername(fd, sa, sockaddr_buf_work.len) ~= 0) and (sockaddr_buf_work.len[0] < len) then
		return nil
	end
	return sa
end
function _M.inet_namebyfd(fd, dst, len)
	if not dst then
		dst = ffi.cast('struct sockaddr*', sockaddr_buf_work)
		len = ffi.sizeof('pulpo_addr_t')
	end
	sockaddr_buf_work.len[0] = len
	if (C.getsockname(fd, sa, sockaddr_buf_work.len) ~= 0) and (sockaddr_buf_work.len[0] < len) then
		return nil
	end
	return sa
end
local sockaddr_buf = ffi.new('struct sockaddr_in[1]')
function _M.numeric_ipv4_addr_from_sockaddr(sa)
	return _M.htonl(ffi.cast('struct sockaddr_in*', sa).sin_addr.s_addr)
end
function _M.numeric_ipv4_addr_by_host(host)
	if _M.inet_hostbyname(host, sockaddr_buf) >= 0 then
		return _M.htonl(ffi.cast('struct sockaddr_in*', sockaddr_buf).sin_addr.s_addr)
	else
		exception.raise('invalid', 'address', host)
	end
end
function _M.host_by_numeric_ipv4_addr(addr)
	local sa = ffi.cast('struct sockaddr_in*', sockaddr_buf)
	sa.sin_addr.s_addr = addr
	sa.sin_family = AF_INET
	return _M.inet_namebyhost(sockaddr_buf, false)
end

if ffi.os == "OSX" then
_M.DEFAULT_IFNAME = "en0"
elseif ffi.os == "Linux" then
_M.DEFAULT_IFNAME = "eth0"
else
raise("invalid", "os", ffi.os)
end

function _M.getifaddr(ifname_filters, address_family)
	local ppifa = ffi.new('struct ifaddrs *[1]')
	if 0 ~= C.getifaddrs(ppifa) then
		error('fail to get ifaddr list:'..ffi.errno())
	end
	local pifa
	local addr,mask
	if not ifname_filters then
		if ffi.os == "OSX" then
			ifname_filters = {"en0", "lo0"}
		elseif ffi.os == "Linux" then
			ifname_filters = {"eth0", "lo"}
		else
			raise("invalid", "os", ffi.os)
		end
	end 
	for _,ifname_filter in ipairs(ifname_filters) do
		pifa = ppifa[0]
		if type(ifname_filter) == 'string' then
			while pifa ~= ffi.NULL do
				-- print('check', ffi.string(pifa.ifa_name), pifa.ifa_addr.sa_family)
				if ffi.string(pifa.ifa_name) == ifname_filter then
					if (not address_family) or (pifa.ifa_addr.sa_family == address_family) then
						break
					end
				end
				pifa = pifa.ifa_next
			end
		elseif type(ifname_filter) == 'function' then
			while pifa ~= ffi.NULL do
				if ifname_filter(pifa) then
					break
				end
				pifa = pifa.ifa_next
			end
		end
		if pifa ~= ffi.NULL then
			break
		end
	end
	if pifa == ffi.NULL then
		C.freeifaddrs(ppifa[0])
		raise("not_found", "interface:", ifname)
	end
	addr,mask = pifa.ifa_addr, pifa.ifa_netmask
	C.freeifaddrs(ppifa[0])
	return addr, mask
end

local opts_work_buffer = memory.alloc_fill_typed('pulpo_sockopt_t')
function _M.table2sockopt(opts, alloc)
	local buf
	if (not opts) or (opts == ffi.NULL) then
		ffi.fill(opts_work_buffer, ffi.sizeof('pulpo_sockopt_t'))
		return opts_work_buffer		
	elseif type(opts) == "cdata" then
		buf = opts
		ffi.fill(buf, ffi.sizeof('pulpo_sockopt_t'))
	elseif alloc then
		buf = memory.alloc_fill_typed('pulpo_sockopt_t')
	else
		buf = opts_work_buffer
		ffi.fill(opts_work_buffer, ffi.sizeof('pulpo_sockopt_t'))
	end
	for _,prop in ipairs({"blocking", "timeout"}) do
		buf[prop] = opts[prop] or 0
	end
	for _,prop in ipairs({"rblen", "wblen"}) do
		buf[prop].data = opts[prop] or 0 
	end
	return buf
end
function _M.setsockopt(fd, opts)
	opts = _M.table2sockopt(opts)
	if not opts.blocking then
		local f = C.fcntl(fd, F_GETFL, 0) 
		if f < 0 then
			logger.error("fcntl fail (get flag) errno=", ffi.errno())
			return -6
		end
		-- fcntl declaration is int fcntl(int, int, ...), 
		-- that means third argument type is vararg, which less converted than usual ffi function call 
		-- (eg. lua-number to double to int), so you need to convert to int by yourself
		if C.fcntl(fd, F_SETFL, ffi.new('int', bit.bor(f, O_NONBLOCK))) < 0 then
			logger.error("fcntl fail (set nonblock) errno=", ffi.errno())
			return -1
		end
		-- print('fd = ' .. fd, 'set as non block('..C.fcntl(fd, F_GETFL)..')')
	end
	if opts.timeout and (opts.timeout > 0) then
		local timeout = util.sec2timeval(tonumber(opts.timeout))
		if C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, timeout, ffi.sizeof('struct timeval')) < 0 then
			logger.error("setsockopt (sndtimeo) errno=", ffi.errno());
			return -2
		end
		if C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, timeout, ffi.sizeof('struct timeval')) < 0 then
			logger.error("setsockopt (rcvtimeo) errno=", ffi.errno());
			return -3
		end
	end
	if opts.wblen and (opts.wblen.data > 0) then
		logger.info(fd, "set wblen to", tonumber(opts.wblen));
		if C.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, opts.wblen.p, ffi.sizeof(opts.wblen.p)) < 0 then
			logger.error("setsockopt (sndbuf) errno=", errno);
			return -4
		end
	end
	if opts.rblen and (opts.rblen.data > 0) then
		logger.info(fd, "set rblen to", tonumber(opts.wblen));
		if C.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, opts.rblen.p, ffi.sizeof(opts.rblen.p)) < 0 then
			logger.error("setsockopt (rcvbuf) errno=", errno);
			return -5
		end
	end
	return 0
end

function _M.set_reuse_addr(fd, reuse)
	reuse = ffi.new('int[1]', {reuse and 1 or 0})
	if C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, reuse, ffi.sizeof(reuse)) < 0 then
		return false
	end
	if _M.port_reusable() then
		if C.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, reuse, ffi.sizeof(reuse)) < 0 then
			return false
		end
	end
	return true
end

function _M.port_reusable()
	return SO_REUSEPORT
end

function _M.stream(addrstr, opts, addr)
	local r, af = _M.inet_hostbyname(addrstr, addr.p, SOCK_STREAM)
	if r <= 0 then
		logger.error('invalid address:', addr)
		return nil
	end
	addr.len[0] = r
	local fd = C.socket(af, SOCK_STREAM, 0)
	if fd < 0 then
		logger.error('fail to create socket:', ffi.errno())
		return nil
	end
	if _M.setsockopt(fd, opts) < 0 then
		logger.error('fail to set socket options:', ffi.errno())
		C.close(fd)
		return nil
	end
	return fd
end

function _M.datagram(addrstr, opts, addr)
	local r, af = _M.inet_hostbyname(addrstr, addr.p, SOCK_DGRAM)
	if r <= 0 then
		logger.error('invalid address:', addr)
		return nil
	end
	addr.len[0] = r
	local fd = C.socket(af, SOCK_DGRAM, 0)
	if fd < 0 then
		logger.error('fail to create socket:', ffi.errno())
		return nil
	end
	if _M.setsockopt(fd, opts) < 0 then
		logger.error('fail to set socket options:', ffi.errno())
		C.close(fd)
		return nil
	end
	return fd
end

local intval_worker = memory.alloc_typed('pulpo_bytes_op_t')
function _M.setup_multicast(fd, mcast_addrstr, opts, addr)
	local ifr = ffi.new('struct ifreq[1]')
	local mreq = memory.managed_alloc_typed('struct ip_mreq[1]')
	ffi.fill(mreq, ffi.sizeof('struct ip_mreq'))
	-- get information about specified interface 
	ifr[0].ifr_addr.sa_family = addr.p.sa_family
	ffi.copy(ifr[0].ifr_name, opts.ifname or _M.DEFAULT_IFNAME, IFNAMSIZ-1)
	if -1 == C.ioctl(fd, SIOCGIFADDR, ifr) then
		raise("syscall", "ioctl")
	end
	-- set multicast interface data to descriptor
	local sa_p = ffi.cast('char *', ifr) + ffi.offsetof('struct ifreq', 'ifr_addr')
	if C.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, sa_p, ffi.sizeof('struct sockaddr_in')) == -1 then
		raise("syscall", "setsockopt:IP_MULTICAST_IF")
	end
	-- join multicast membership and set ttl
	local a = ffi.new('struct in_addr[1]')
	local sa = ffi.cast('struct sockaddr_in*', sa_p)
	if 0 == inet_aton(mcast_addrstr, a) then
		raise("syscall", "inet_aton", addr)
	end
	mreq[0].imr_multiaddr.s_addr = a.s_addr
	mreq[0].imr_interface.s_addr = sa.sin_addr.s_addr
	if C.setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, mreq, sizeof(mreq)) == -1 then
		raise("syscall", "setsockopt:IP_ADD_MEMBERSHIP")
	end
	intval_worker.l = opts.ttl or 5
	if C.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, intval_worker.p, ffi.sizeof('int')) == -1 then
		raise("syscall", "setsockopt:IP_MULTICAST_TTL")
	end
	return fd
end

function _M.unix_domain(opts)
	local fd = C.socket(AF_UNIX, opts and opts.socktype or SOCK_STREAM, 0)
	if fd < 0 then
		logger.error('fail to create socket:', ffi.errno())
		return nil
	end
	if _M.setsockopt(fd, opts) < 0 then
		logger.error('fail to set socket options:', ffi.errno())
		C.close(fd)
		return nil
	end
	return fd
end

function _M.dup(sock)
	return C.dup(sock)
end

return _M