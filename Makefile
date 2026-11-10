.PHONY: test fmt lint

test:
	nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

fmt:
	stylua lua plugin tests

lint:
	stylua --check lua plugin tests
