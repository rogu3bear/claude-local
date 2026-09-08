.PHONY: bootstrap install check check-llama check-checkpoint check-idle check-interactive bench bench-shipped compare lint
# The launcher's default --tools list, read from the one place it is defined.
SHIPPED_TOOLS = $(shell sed -n 's/^TOOLS="$${CLAUDE_LOCAL_TOOLS-\(.*\)}"$$/\1/p' bin/claude-local)
bootstrap:          ## fresh machine -> working claude-local; flags via ARGS='--gpu cpu --dry-run'
	./bootstrap.sh $(ARGS)
install:            ## symlink into ~/.local/bin and ~/.claude-local
	./install.sh
lint:               ## syntax-check every script
	bash -n bootstrap.sh bin/claude-local bin/llama-server-run bin/llama-models-ini config/backend-ollama.sh config/backend-llamaserver.sh config/statusline.sh bench/run.sh test/smoke.sh test/checkpoint.sh test/idle-unload.sh install.sh
	python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" config/picker.py config/proxy.py config/mcp-websearch.py config/hook-urlguard.py bench/compare.py test/interactive.py
	@echo lint ok
check: lint         ## lint + one non-interactive turn through launcher and proxy (needs the model server)
	test/smoke.sh
check-llama: lint   ## same, against llama-server.service (port from ~/.claude-local/env)
	CLAUDE_LOCAL_BACKEND=llamaserver test/smoke.sh
check-checkpoint:   ## proxy checkpoint + resume: kills one idle llama-server model instance and expects a warm retry
	test/checkpoint.sh
check-idle:         ## proxy idle unload: loads a throwaway preset, expects it checkpointed and unloaded while idle
	test/idle-unload.sh
check-interactive:  ## full pty-driven session (picker, statusline, Ctrl-C, post-exit menu)
	python3 test/interactive.py
bench:              ## run the benchmark under LABEL (default: adhoc); extra claude flags via FLAGS
	cd bench && CLAUDE_LOCAL_BACKEND=$${BACKEND:-ollama} ./run.sh --label $${LABEL:-adhoc} -- --append-system-prompt-file $(CURDIR)/config/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash,Read,Edit,Write,Grep,Glob $(FLAGS)
bench-shipped:      ## benchmark what claude-local ships: default tool list, web search MCP, online (LABEL default "shipped")
	cd bench && CLAUDE_LOCAL_BACKEND=$${BACKEND:-llamaserver} ./run.sh --label $${LABEL:-shipped} --notes "shipped defaults: tools=$(SHIPPED_TOOLS) + websearch MCP, online" -- --append-system-prompt-file $(CURDIR)/config/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools $(SHIPPED_TOOLS) --mcp-config '{"mcpServers":{"websearch":{"type":"stdio","command":"python3","args":["$(CURDIR)/config/mcp-websearch.py"]}}}' $(FLAGS)
compare:            ## summarise benchmark results
	bench/compare.py
