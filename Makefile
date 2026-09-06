.DEFAULT_GOAL := help

RUN_SCRIPT := ./script/build_and_run.sh

.PHONY: help run build install install-dev package-dev uninstall-dev reset-dev verify logs telemetry debug

help:
	@printf "DictaFlow local commands:\n"
	@printf "  make run            Build, install to /Applications, and launch DictaFlow Dev\n"
	@printf "  make build          Build and install DictaFlow Dev without launching\n"
	@printf "  make install        Alias for make build\n"
	@printf "  make install-dev    Build and install DictaFlow Dev\n"
	@printf "  make package-dev    Build DictaFlow Dev and create a local DMG\n"
	@printf "  make uninstall-dev  Remove only DictaFlow Dev from /Applications\n"
	@printf "  make reset-dev      Reset Dev onboarding and macOS permissions\n"
	@printf "  make verify         Build, install, verify signing, and launch\n"
	@printf "  make logs           Build, install, launch, and stream process logs\n"
	@printf "  make telemetry      Build, install, launch, and stream subsystem logs\n"
	@printf "  make debug          Build, install, then start lldb for the installed app\n"

run:
	$(RUN_SCRIPT)

build:
	$(RUN_SCRIPT) --no-launch

install: build

install-dev:
	$(RUN_SCRIPT) --install-dev

package-dev:
	$(RUN_SCRIPT) --package-dev

uninstall-dev:
	$(RUN_SCRIPT) --uninstall-dev

reset-dev:
	$(RUN_SCRIPT) --reset-dev

verify:
	$(RUN_SCRIPT) --verify

logs:
	$(RUN_SCRIPT) --logs

telemetry:
	$(RUN_SCRIPT) --telemetry

debug:
	$(RUN_SCRIPT) --debug
