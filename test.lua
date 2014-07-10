local dir = io.popen('ls test')
local term = require 'pulpo.terminal'

while true do
	local file = dir:read()
	if not file then break end
	file = ('test/' .. file)
	if file:find('%.lua$') then
		term.resetcolor(); print('test: '..file..' ==========================================')
		local ok, r = pcall(os.execute, arg[-1].." test/tools/launch.lua "..file)
		if ok and r then
			if r ~= 0 then
				term.red(); print('test fails:' .. file .. '|' .. r)
				term.resetcolor(); os.exit(-1)
			else
				term.cyan(); print('test: '..file..' OK')
			end
		else
			term.red(); print('execute test fails:' .. file .. '|' .. tostring(r))
			term.resetcolor(); os.exit(-2)
		end
	else
		term.yellow(); print('not test:' .. file .. ' ==========================================')
	end
end
term.cyan(); print('test finished')
term.resetcolor()