.PHONY: all generate-types examples test test-unit test-integration clean

BUILD_FLAGS := -vet -strict-style -o:none
TEST_FLAGS := -define:ODIN_TEST_SHORT_LOGS=true -define:ODIN_TEST_LOG_LEVEL=error

all: generate-types examples

generate-types: submodules
	@$(MAKE) -C pkgs/ojson build-generator
	@$(MAKE) --no-print-directory $(patsubst src/providers/%,generate-types/%,$(wildcard src/providers/*))

generate-types/%:
	@pkgs/ojson/bin/generate -r src/providers/$* -o src/providers/$*/ojson.gen.odin -p $*

examples: generate-types
	@$(MAKE) --no-print-directory $(patsubst example/%,examples/%,$(sort $(shell find example -name 'main.odin' | xargs -L1 dirname)))

examples/%:
	@mkdir -p bin
	odin build example/$* -out:bin/$(subst /,-,$*) $(BUILD_FLAGS)

test: test-unit test-integration

test-unit: generate-types
	@$(MAKE) --no-print-directory -j $(patsubst ./%,test-unit/%,$(sort $(shell find . -name '*_test.odin' -not -path './pkgs/*' -not -path './src/integration_test/*' | xargs -L1 dirname)))

test-unit/%:
	@mkdir -p bin/$*
	@odin test ./$* -out:bin/$*/$(notdir $*) $(BUILD_FLAGS) $(TEST_FLAGS)

test-integration: generate-types
	@mkdir -p bin
	@odin test ./src/integration_test -out:bin/integration_test $(BUILD_FLAGS) $(TEST_FLAGS)

submodules:
	@git submodule update --init --recursive

clean:
	@rm -rf bin/
	@rm -f src/providers/*/ojson.gen.odin
	@echo "cleaned"
