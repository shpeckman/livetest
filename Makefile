# livetest - live-testing harness for GUI apps
.POSIX:

CRYSTAL = crystal

spec:
	$(CRYSTAL) spec

docs:
	$(CRYSTAL) docs src/livetest.cr src/livetest/worker.cr

clean:
	rm -rf lib shard.lock docs

.PHONY: spec docs clean
