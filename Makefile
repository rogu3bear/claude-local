.PHONY: bootstrap install check check-interactive bench compare lint
bootstrap:          ## fresh machine -> working claude-local (deps, ollama, service, model, symlinks, smoke)
	./bootstrap.sh
install:            ## symlink into ~/.local/bin and ~/.claude-local
	./install.sh
lint:               ## syntax-check every script
	bash -n bootstrap.sh bin/claude-local config/backend-ollama.sh config/backend-llamaserver.sh config/statusline.sh bench/run.sh test/smoke.sh install.sh
	python3 -m py_compile config/picker.py config/proxy.py bench/compare.py test/interactive.py
	@echo lint ok
check: lint         ## lint + one non-interactive turn through launcher and proxy (needs the model server)
	test/smoke.sh
check-interactive:  ## full pty-driven session (picker, statusline, Ctrl-C, post-exit menu)
	python3 test/interactive.py
bench:              ## run the benchmark under LABEL (default: adhoc); extra claude flags via FLAGS
	cd bench && ./run.sh --label $${LABEL:-adhoc} -- --append-system-prompt-file $(CURDIR)/config/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 $(FLAGS)
compare:            ## summarise benchmark results
	bench/compare.py
