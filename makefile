### MAIN VARIABLES
GW=./gradlew
ABC=../../scripts/abc.sh
ABC_CFG=../../scripts/.abc-config
JAVA_OPTS=" -Dabc.instrument.fields.operations -Dabc.taint.android.intents -Dabc.instrument.include=nz.org.cacophony.birdmonitor"

# Default
SED=/usr/bin/sed
UNAME := $(shell uname)
# Override if on Mac Os. Assume that you have installed Gnu SED (gsed)
ifeq ($(UNAME),Darwin)
SED := $(shell echo /usr/local/bin/gsed)
endif

ADB := $(shell $(ABC) show-config  ANDROID_ADB_EXE | sed -e "s|ANDROID_ADB_EXE=||")
# Create a list of expected test executions from tests.txt Those corresponds to the traces
ESPRESSO_TESTS := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.testlog|')
# Create the list of expected carved targets from tests.txt
ESPRESSO_TESTS_CARVED := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.carved|')
# Create the list of expected coverage targets from tests.txt. This points to the html file because make works with files
ESPRESSO_TESTS_COVERAGE := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|espresso-test-coverage-for-\1/html/index.html|')
# Create the list of carved tests to measure coverage. This points to the html file because make works with files
ifeq (,$(wildcard carved-tests.log))
$(info "carved-tests.log missing. We probably need to re-run make after computing it")
REQUIRE_RERUN=1
else
$(info "Configuring CARVED_TESTS_COVERAGE")
REQUIRE_RERUN=0
CARVED_TESTS_COVERAGE := $(shell cat carved-tests.log | grep ">" | grep "PASSED" | tr ">" " " | awk '{print $$1, $$2}' | tr " " "." | sed 's|\(.*\)|carved-test-coverage-for-\1/html/index.html|' | sort | uniq)
endif


.PHONY: clean-gradle clean-all carve-all run-espresso-tests trace-espresso-tests

show :
	$(info $(ADB))

clean-gradle :
	$(GW) clean

list-sed:
	@echo $(UNAME) -- $(SED)

# Debug Target
list-all-tests :
	@echo $(ESPRESSO_TESTS) | tr " " "\n"
	
list-tests : $(ESPRESSO_TESTS)
	@echo $? | tr " " "\n"

list-coverage-targets:
	@ echo $(ESPRESSO_TESTS_COVERAGE) | tr " " "\n"

list-coverage-carved-targets:
	@ echo $(CARVED_TESTS_COVERAGE) | tr " " "\n"

clean-all :
# Clean up apk-related targets
	$(RM) -v *.apk
# Clean up all the logs
	$(RM) -v *.log
# Clean up tracing
	$(RM) -v *.testlog
	$(RM) -rv traces
# Clean up carved tests
	$(RM) -rv app/src/carvedTest
	$(RM) -rv .carved-all
# Clean up Coverage
	$(RM) -rv espresso-tests-coverage
	$(RM) -rv unit-tests-coverage
	$(RM) -rv carved-tests-coverage
	$(RM) -rv espresso-test-coverage-for-*
	$(RM) -rv jacoco-espresso-coverage
	$(RM) -rv carved-test-coverage-for-*
	$(RM) -rv carved-coverage-for-selection.csv
# Selection using coverage
	$(RM) carved-tests.log
	$(RM) selected-carved-tests.csv
	$(RM) white-listed-tests.txt

# Build the various apks
app-original.apk : 
	export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) -PjacocoEnabled=false assembleDebug && \
	mv app/build/outputs/apk/debug/Bird-Monitor-1.9.1-debug.apk app-debug.apk && \
	$(ABC) sign-apk app-debug.apk && \
	mv -v app-debug.apk app-original.apk

app-instrumented.apk : app-original.apk
	export ABC_CONFIG=$(ABC_CFG) && \
	export JAVA_OPTS=$(JAVA_OPTS) && \
	$(ABC) instrument-apk app-original.apk && \
	mv -v ../../code/ABC/instrumentation/instrumented-apks/app-original.apk app-instrumented.apk

app-androidTest.apk :
	export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) assembleAndroidTest && \
	mv app/build/outputs/apk/androidTest/debug/Bird-Monitor-1.9.1-debug-androidTest.apk app-androidTest-unsigned.apk && \
	$(ABC) sign-apk app-androidTest-unsigned.apk && \
	mv -v app-androidTest-unsigned.apk app-androidTest.apk

# Utility
stop-emulator:
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators

# Trace all depends on tracing all the tests
trace-all : $(ESPRESSO_TESTS)
# Run the emulator
	@echo "Tracing: $(shell echo $? | tr " " "\n")"
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	@echo "Done"

# Try to trace all tests
$(ESPRESSO_TESTS) : app-androidTest.apk app-instrumented.apk

	$(eval IR_RUNNING := $(shell export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator | wc -l))
	@if [ "$(IR_RUNNING)" == "0" ]; then \
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator; \
	fi

	$(eval FIRST_RUN := $(shell $(ADB) shell pm list packages | grep -c nz.org.cacophony.birdmonitor))
	@if [ "$(FIRST_RUN)" == "2" ]; then \
		echo "Resetting the data of the apk"; \
		$(ADB) shell pm clear nz.org.cacophony.birdmonitor; \
	else \
	 	echo "Installing instrumented apk" ;\
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-instrumented.apk; \
		echo "Installing test apk" ;\
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-androidTest.apk; \
	fi
#	Evalualte the current test name. Note that test names use #
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|__|\\\#|g' -e 's|.testlog||'))
	@echo "Tracing test $(TEST_NAME)"
#	Log directly to the expected file
	$(ADB) shell am instrument -w -e class $(TEST_NAME) nz.org.cacophony.birdmonitor.test/androidx.test.runner.AndroidJUnitRunner 2>&1 | tee $(@)
#	Copy the traces if the previous command succeded
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) copy-traces nz.org.cacophony.birdmonitor ./traces/$(TEST_NAME) force-clean

# Carving all requires to have all of them traced
# This will always run because it's a phony target
carve-all : .carved-all
	@echo "Carving All"
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	@echo "Done"

.carved-all : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) carve-all app-original.apk traces app/src/carvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# 	Make sure this file has a timestamp after the prerequiesing
	@sleep 1; echo "" > .carved-all


run-all-carved-tests : carvedTests.log
	@echo "Done"

carvedTests.log : .carved-all
	@echo "Done"
	@touch carvedTests.log

### ### ### ### ### ### ### 
### Coverage targets
### ### ### ### ### ### ### 

# Always run. 
coverage-espresso-tests : 
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator
	$(GW) -PjacocoEnabled=true -PcarvedTests=false clean jacocoGUITestCoverage
	mv -v app/build/reports/jacoco/jacocoGUITestCoverage espresso-test-coverage
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators

# Required to run each test on its own to compute the coverage report
$(ESPRESSO_TESTS_COVERAGE):
	
	$(eval IR_RUNNING := $(shell export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator | wc -l))
	@if [ "$(IR_RUNNING)" == "0" ]; then \
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator; \
	fi
	
# Starting and restarting the emulator is not robust
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|__|\\\#|g' -e 's|/html/index.html||' -e 's|espresso-test-coverage-for-||'))
	$(eval COVERAGE_FOLDER := $(shell echo "$(@)" | sed -e 's|/html/index.html||'))
# Ensure we clean up stuff before running each test
	$(eval FIRST_RUN := $(shell $(ADB) shell pm list packages | grep -c nz.org.cacophony.birdmonitor))
	@if [ "$(FIRST_RUN)" == "2" ]; then \
		echo "Resetting the data of the apk"; \
		$(ADB) shell pm clear nz.org.cacophony.birdmonitor; \
	fi
# Execute the gradle target
	@echo "Running Test $(TEST_NAME)"
	$(GW) -PjacocoEnabled=true -PcarvedTests=false -Pandroid.testInstrumentationRunnerArguments.class=$(TEST_NAME) jacocoGUITestCoverage
	mv -v app/build/reports/jacoco/jacocoGUITestCoverage $(COVERAGE_FOLDER)
	mv -v app/build/outputs/code_coverage/debugAndroidTest/connected/*coverage.ec $(COVERAGE_FOLDER)/$(TEST_NAME).ec
	
# Phony  target
coverage-for-each-espresso-test :  $(ESPRESSO_TESTS_COVERAGE)
	@echo "Processing: $(shell echo $? | tr " " "\n")"
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	mkdir -p jacoco-espresso-coverage
	find espresso-test-coverage-* -type f -name "*.ec" -exec cp '{}' jacoco-espresso-coverage/ ';'
	@echo "Done"


# Run existing unit tests (not carved ones)
coverage-unit-tests :
	$(GW) -PjacocoEnabled=true -PcarvedTests=false clean jacocoUnitTestCoverage
	$(RM) -r unit-tests-coverage
	mv -v app/build/reports/jacoco/jacocoUnitTestCoverage unit-tests-coverage

# UPDATE THIS WITH TO CHECK THE RIGHT FILES .covered or index.html.  --info
coverage-carved-tests : carved-tests.log
	@echo "Done"

carved-tests.log : .carved-all
	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage 2>&1 | tee carved-tests.log
	$(RM) -r carved-tests-coverage
	mv -v build/carvedTest/coverage carved-tests-coverage

$(CARVED_TESTS_COVERAGE): carved-tests.log
# Extract the test name from the target folder
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|/html/index.html||' -e 's|carved-test-coverage-for-||'))
	$(eval COVERAGE_FOLDER := $(shell echo "$(@)" | sed -e 's|/html/index.html||'))
# Clean up the coverage folder (this should not be necessary)
	$(RM) -rv $(COVERAGE_FOLDER)
# Run the single unit test and collect coverage
	$(GW) -PjacocoEnabled=true -PcarvedTests=true -PcarvedTestsFilter=$(TEST_NAME) clean jacocoUnitTestCoverage
# Copy the coverage folder in the expected place
	mv -v ./build/carvedTest/coverage $(COVERAGE_FOLDER)

coverage-for-each-carved-test : carved-tests.log $(CARVED_TESTS_COVERAGE)
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	@echo "Done"

#
# TODO Alessio: This is broken, cannot split correctly stuff, This requires the right naming convention. Provided by
# !268
#
carved-coverage-for-selection.csv : carved-tests.log $(CARVED_TESTS_COVERAGE)
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif

	@for COV in $(CARVED_TESTS_COVERAGE); do \
		echo "Processing $COV"; \
		TEST_NAME=`echo "$$COV" | $(SED) -e 's|/html/index.html||' -e 's|carved-test-coverage-for-||'`; \
		METHOD_UNDER_TEST=`echo "$$COV" | $(SED) -e 's|.*\.test_\(.*\)|\1|' | tr "_" " "| awk '{$$NF=""; print $$0}' | sed -e 's/[ \t]*$$//' | tr " " "."`; \
		COV_HASH=`cat $$COV | tr ">" "\n" | $(SED) '1,/.*tfoot.*/d' | $(SED) '/.*<\/tfoot*/,$$d' | tr "\n" ">" | md5sum | cut -f1 -d" "`; \
		echo "$$TEST_NAME, $$METHOD_UNDER_TEST, $$COV_HASH" >> carved-coverage-for-selection.csv; \
	done

# Select the first test among those what match the combination method under test + hash coverage
selected-carved-tests.csv : SHELL := /bin/bash
selected-carved-tests.csv : carved-tests.log carved-coverage-for-selection.csv
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	@while read -r TOKEN; do \
		grep "$$TOKEN" carved-coverage-for-selection.csv | head -1 ; \
	done< <(cat carved-coverage-for-selection.csv  | awk '{print $$2, $$3}' | sort | uniq) > selected-carved-tests.csv

# FOR THE MOMENT WE ASSUME A SINGLE TEST METHOD FOR EACH TEST. OTHERWISE, WE NEED TO UPDATE AND RECOMPILE THE CARVED TESTS
white-listed-tests.txt : SHELL := /bin/bash
white-listed-tests.txt : carved-tests.log selected-carved-tests.csv
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	@while read TEST_PACKAGE TEST_CLASS METHOD_UNDER_TEST; do \
		echo "app/src/carvedTest/$${TEST_PACKAGE//.//}/$$TEST_CLASS.java"; \
	done< <(cat selected-carved-tests.csv | \
		tr "," " " | \
		awk '{print $$1}' | \
		$(SED) 's|\(.*\)\.test_\(.*\)|\1 \2|' | \
		$(SED) 's|\(.*\)\.\(.*\) \(.*\)|\1 \2 \3|') > white-listed-tests.txt

delete-duplicated-carved-tests : carved-tests.log white-listed-tests.txt
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	for TEST in $$(find app/src/carvedTest -iname "Test*.java"); do \
		if [[ $$(grep -c $$TEST white-listed-tests.txt) -eq 1 ]]; then \
			echo "Keep $$TEST"; \
		else \
			mv -v $$TEST $$TEST.removed ; \
		fi; \
	done

# coverage-existing-carved-tests :
# 	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage
# 	$(RM) -r  carved-tests-coverage
# 	mv -v build/carvedTest/coverage carved-tests-coverage