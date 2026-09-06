.PHONY: bootstrap install check check-llama check-interactive bench compare lint
bootstrap:          ## fresh machine -> working claude-local; flags via ARGS='--gpu cpu --dry-run'
	./bootstrap.sh $(ARGS)
install:            ## symlink into ~/.local/bin and ~/.claude-local
	./install.sh
lint:               ## syntax-check every script
	bash -n bootstrap.sh bin/claude-local bin/llama-server-run config/backend-ollama.sh config/backend-llamaserver.sh config/statusline.sh bench/run.sh test/smoke.sh install.sh
	python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" config/picker.py config/proxy.py bench/compare.py test/interactive.py
	@echo lint ok
check: lint         ## lint + one non-interactive turn through launcher and proxy (needs the model server)
	test/smoke.sh
check-llama: lint   ## same, against llama-server.service (port from ~/.claude-local/env)
	CLAUDE_LOCAL_BACKEND=llamaserver test/smoke.sh
check-interactive:  ## full pty-driven session (picker, statusline, Ctrl-C, post-exit menu)
	python3 test/interactive.py
bench:              ## run the benchmark under LABEL (default: adhoc); extra claude flags via FLAGS
	cd bench && CLAUDE_LOCAL_BACKEND=$${BACKEND:-ollama} ./run.sh --label $${LABEL:-adhoc} -- --append-system-prompt-file $(CURDIR)/config/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash,Read,Edit,Write,Grep,Glob $(FLAGS)
compare:            ## summarise benchmark results
	bench/compare.py
