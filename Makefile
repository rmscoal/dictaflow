.DEFAULT_GOAL := help

RUN_SCRIPT := ./script/build_and_run.sh

.PHONY: help run build install verify logs telemetry debug

help:
	@printf "DictaFlow local commands:\n"
	@printf "  make run        Build, install to /Applications, and launch DictaFlow Dev\n"
	@printf "  make build      Build and install without launching\n"
	@printf "  make install    Alias for make build\n"
	@printf "  make verify     Build, install, verify signing, and launch\n"
	@printf "  make logs       Build, install, launch, and stream process logs\n"
	@printf "  make telemetry  Build, install, launch, and stream subsystem logs\n"
	@printf "  make debug      Build, install, then start lldb for the installed app\n"

run:
	$(RUN_SCRIPT)

build:
	$(RUN_SCRIPT) --no-launch

install: build

verify:
	$(RUN_SCRIPT) --verify

logs:
	$(RUN_SCRIPT) --logs

telemetry:
	$(RUN_SCRIPT) --telemetry

debug:
	$(RUN_SCRIPT) --debug
