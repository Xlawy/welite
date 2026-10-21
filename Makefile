.PHONY: test check package
test:
	python3 scripts/test_welite.py
check:
	python3 scripts/test_welite.py check
	bash scripts/check_lua_namespace.sh
package:
	bash scripts/package_release.sh
