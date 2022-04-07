### MAIN VARIABLES
GW=./gradlew --console plain
ABC=../../scripts/abc.sh
ABC_CFG=../../scripts/.abc-config
# -Dabc.make.android.lifecycle.events.explicit
# -Dabc.instrument.array.operations
# -Dabc.instrument.debug -Dabc.instrument.multithreaded"
JAVA_OPTS=" -Dabc.instrument.array.operations -Dabc.instrument.fields.operations -Dabc.taint.android.intents -Dabc.instrument.include=nz.org.cacophony.birdmonitor  -Dabc.instrument.multithreaded "

INSTRUMENTATION_OPTS=" \
--skip-class=nz.org.cacophony.birdmonitor.R \
--skip-class=nz.org.cacophony.birdmonitor.views.ManageRecordingsFragment \
--filter-package=java.io \
--filter-class=java.lang.StringBuilder \
"

CARVING_JAVA_OPTIONS=" \
-Dorg.slf4j.simpleLogger.defaultLogLevel=info \
"

CARVING_OPTIONS=""

SELECT_ONE_CARVING_OPTIONS=$(CARVING_OPTIONS)" \
--selection-strategy=SELECT_ONE \
"

SELECT_ALL_CARVING_OPTIONS=$(CARVING_OPTIONS)" \
--selection-strategy=SELECT_ALL \
"

SELECT_ACTIVITIES_ALL_CARVING_OPTIONS=$(CARVING_OPTIONS)" \
--selection-strategy=SELECT_ACTIVITIES_ALL \
"

SELECT_ACTIVITIES_ONE_CARVING_OPTIONS=$(CARVING_OPTIONS)" \
--selection-strategy=SELECT_ACTIVITIES_ONE \
"

# Default
SED=/usr/bin/sed
UNAME := $(shell uname)
# Override if on Mac Os. Assume that you have installed Gnu SED (gsed)
ifeq ($(UNAME),Darwin)
SED := $(shell echo /usr/local/bin/gsed)
endif

ADB := $(shell $(ABC) show-config  ANDROID_ADB_EXE | sed -e "s|ANDROID_ADB_EXE=||")
# Create a list of expected test executions from espresso_tests.txt Those corresponds to the traces
ESPRESSO_TESTS := $(shell cat espresso_tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.testlog|')
# Create the list of expected coverage targets from espresso_tests.txt
ESPRESSO_TESTS_COVERAGE := $(shell cat espresso_tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|espresso-test-coverage-for-\1/html/index.html|')
# Create the list of carved tests to measure coverage. This points to the html file because make works with files
ifeq (,$(wildcard carved-tests.log))
$(info "carved-tests.log missing. We probably need to re-run make after computing it")
REQUIRE_RERUN=1
else
REQUIRE_RERUN=0
CARVED_TESTS_COVERAGE := $(shell cat carved-tests.log | grep ">" | grep "PASSED" | tr ">" " " | awk '{print $$1, $$2}' | tr " " "." | sed 's|\(.*\)|carved-test-coverage-for-\1/html/index.html|' | sort | uniq)
endif

# TODO Ensure that CARVED_TESTS_COVERAGE contains more than one test?

# Global variable to check which apks are installed, if any
TRACING_APKS_INSTALLED := 0
COVERAGE_APKS_INSTALLED := 0

# Ensure that if the emulator is running, there will be NO APKs installed afterwards
define remove-apk-and-instrumented-tests
$(info INFO: Removing APK and instrumented tests)
$(shell IS_RUNNING=$$(export ABC_CONFIG=$(ABC_CFG) && $(ABC) list-running-emulators | wc -l | sed 's| ||g'); \
if [ "$$IS_RUNNING" == "0" ]; then \
        (>&2 echo "No need to remove anything from emulator. No emulator running!"); \
elif [ "$$IS_RUNNING" == "1" ]; then \
        APP_INSTALLED=$$($(ADB) shell pm list packages | grep -c "nz.org.cacophony.birdmonitor$$"); \
        INSTRUMENTATION_TESTS_INSTALLED=$$($(ADB) shell pm list packages | grep -c "nz.org.cacophony.birdmonitor.test$$"); \
        if [ "$$APP_INSTALLED" == "1" ]; then \
				(>&2 echo "Removing app"); \
                $(ADB) uninstall nz.org.cacophony.birdmonitor > /dev/null; \
        else \
                (>&2 echo "App not installed"); \
        fi; \
        if [ "$$INSTRUMENTATION_TESTS_INSTALLED" == "1" ]; then \
				(>&2 echo "Removing test app"); \
                $(ADB) uninstall nz.org.cacophony.birdmonitor.test > /dev/null; \
        else \
                (>&2 echo "Test app not installed"); \
        fi; \
else \
    (>&2 echo "Too many emulators running at the same time: $(IS_RUNNING)"); \
fi)
$(eval TRACING_APKS_INSTALLED := 0)
$(eval COVERAGE_APKS_INSTALLED := 0)
endef

# Ensures that app-instrumented.apk and app-androidTest.apk are installed. Optionally, starts the emulator
define ensure_tracing_apks
$(info INFO: Ensure tracing APKs are installed [$(TRACING_APKS_INSTALLED)].)
$(eval IS_RUNNING := $(shell export ABC_CONFIG=$(ABC_CFG) && $(ABC) list-running-emulators | wc -l))
$(info INFO: Emulator running [$(IS_RUNNING)])
$(shell if [ "$(IS_RUNNING)" == "0" ]; then \
	(>&2 echo "No Emulator is running. Start a fresh one"); \
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator; \
fi)
$(if $(filter $(IS_RUNNING),0),$(eval TRACING_APKS_INSTALLED := 0),)
$(if $(filter $(IS_RUNNING),1),$(if $(filter $(TRACING_APKS_INSTALLED),0), $(call remove-apk-and-instrumented-tests),),)
$(shell if [ "$(TRACING_APKS_INSTALLED)" == "0" ]; then \
	(>&2 echo "Installing instrumented apk"); \
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-instrumented.apk; \
	(>&2 echo "Installing test apk") ;\
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-androidTest.apk; \
else \
	(>&2 echo "Resetting the data of the apk"); \
	$(ADB) shell pm clear nz.org.cacophony.birdmonitor > /dev/null; \
	fi)
$(eval TRACING_APKS_INSTALLED := 1)
endef

# Ensures that app-original-for-coverage.apk app-androidTest-for-coverage.apk are installed. Optionally, starts the emulator
define ensure_coverage_apks
$(info INFO: Ensure coverage APKs are installed [$(COVERAGE_APKS_INSTALLED)].)
$(eval IS_RUNNING := $(shell export ABC_CONFIG=$(ABC_CFG) && $(ABC) list-running-emulators | wc -l))
$(info INFO: Emulator running [$(IS_RUNNING)])
$(shell if [ "$(IS_RUNNING)" == "0" ]; then \
	(>&2 echo "No Emulator is running. Start a fresh one"); \
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator; \
fi)
$(if $(filter $(IS_RUNNING),0),$(eval COVERAGE_APKS_INSTALLED := 0),)
$(if $(filter $(IS_RUNNING),1),$(if $(filter $(COVERAGE_APKS_INSTALLED),0), $(call remove-apk-and-instrumented-tests),),)
$(shell if [ "$(COVERAGE_APKS_INSTALLED)" == "0" ]; then \
	(>&2 echo "Installing coverage apk"); \
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-original-for-coverage.apk; \
	(>&2 echo "Installing test coverage apk") ;\
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-androidTest-for-coverage.apk; \
else \
	(>&2 echo "Resetting the data of the coverage apk"); \
	$(ADB) shell pm clear nz.org.cacophony.birdmonitor > /dev/null; \
fi)
$(eval COVERAGE_APKS_INSTALLED := 1)
endef

.PHONY: clean-gradle clean-all carve-all-select-one carve-all-select-all run-espresso-tests trace-espresso-tests

show :
	$(info $(ADB))

clean-gradle :
	$(info "skip gradle clean")
	$(GW) clean </dev/null

list-sed:
	@echo $(UNAME) -- $(SED)

# Debug Target
list-all-tests :
	@echo $(ESPRESSO_TESTS) | tr " " "\n"
	
list-tests : $(ESPRESSO_TESTS)
	@echo $? | tr " " "\n"

list-coverage-targets:
	@ echo $(ESPRESSO_TESTS_COVERAGE) | tr " " "\n"

# Clean up carved tests
clean-carved-tests :
	$(RM) -rv app/src/selectedCarvedTest
	$(RM) -rv app/src/allCarvedTest
	$(RM) -rv app/src/carvedTest
	$(RM) -rv .carved-all-*
	$(RM) -rv carving.log
	$(RM) -v carved-tests.log
	$(RM) -v selected-carved-tests.log
	$(RM) -v white-listed-tests.txt
	$(RM) -v carved-coverage-for-selection.csv
	$(RM) -v selected-carved-tests.csv
	$(RM) -v selected-carved-tests.done

clean-carved-coverage :
	$(RM) -rv carved-tests-coverage
	$(RM) -rv all-carved-tests-coverage
	$(RM) -rv selected-carved-tests-coverage
	$(RM) -rv carved-test-coverage-for-*

clean-espresso-coverage :
	$(RM) -rv espresso-tests-coverage
	$(RM) -rv espresso-test-coverage-for-*
	$(RM) -rv jacoco-espresso-coverage

clean-all : clean-carved-tests clean-carved-coverage clean-espresso-coverage
# Clean build files
	$(GW) clean </dev/null
# Clean up apk-related targets
	$(RM) -v *.apk
# Clean up all the logs
	$(RM) -v *.log
# Clean up tracing
	$(RM) -v *.testlog
	$(RM) -rv traces
# Clean up Coverage
	$(RM) -rv  unit-tests-coverage

# Build the various apks
app-original.apk : 
	@export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) -PjacocoEnabled=false assembleDebug </dev/null && \
	mv app/build/outputs/apk/debug/Bird-Monitor-1.9.1-debug.apk app-debug.apk && \
	$(ABC) sign-apk app-debug.apk && \
	mv -v app-debug.apk app-original.apk

app-instrumented.apk : app-original.apk
	@export ABC_CONFIG=$(ABC_CFG) && \
	export JAVA_OPTS=$(JAVA_OPTS) && \
	export INSTRUMENTATION_OPTS=$(INSTRUMENTATION_OPTS) && \
	INSTRUMENTED_APK=`$(ABC) instrument-apk app-original.apk` && \
	$(ABC) instrument-apk app-original.apk && \
	mv -v $${INSTRUMENTED_APK} app-instrumented.apk

app-androidTest.apk :
	@export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) assembleAndroidTest </dev/null && \
	mv app/build/outputs/apk/androidTest/debug/Bird-Monitor-1.9.1-debug-androidTest.apk app-androidTest-unsigned.apk && \
	$(ABC) sign-apk app-androidTest-unsigned.apk && \
	mv -v app-androidTest-unsigned.apk app-androidTest.apk

## the assembleAndroidTest task also builds the app if it starts from a clean build
app-original-for-coverage.apk app-androidTest-for-coverage.apk:
	@export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) -PjacocoEnabled=true clean assembleDebug assembleAndroidTest </dev/null && \
	mv app/build/outputs/apk/debug/Bird-Monitor-1.9.1-debug.apk app-original-for-coverage.apk  && \
	mv app/build/outputs/apk/androidTest/debug/Bird-Monitor-1.9.1-debug-androidTest.apk app-androidTest-for-coverage.apk

# Utility - TODO Maybe move this to function?
stop-emulator:
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators

# Trace all depends wraps all the tests to trace.
trace-all : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	@echo "Done"

$(ESPRESSO_TESTS) : app-instrumented.apk app-androidTest.apk
# We need to ensure that when we trace the right apks are installed. This call is idempotent.
	$(call ensure_tracing_apks)
#	Evaluate the current test name. Note that test names use #
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|__|\\\#|g' -e 's|.testlog||'))
	@echo "Tracing test $(TEST_NAME)"
#	Log directly to the expected file
	$(ADB) shell am instrument -w -e class $(TEST_NAME) nz.org.cacophony.birdmonitor.test/androidx.test.runner.AndroidJUnitRunner 2>&1 | tee $(@)
#	Copy the traces if the previous command succeded
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) copy-traces nz.org.cacophony.birdmonitor ./traces/$(TEST_NAME) force-clean

# This will always run because it's a PHONY target
carve-all-select-all : .carved-all-select-all
	@echo "Done"

carve-all-select-one : .carved-all-select-one
	@echo "Done"

carve-all-select-activities-one : .carved-all-select-activities-one
	@echo "Done"

carve-all-select-activities-all : .carved-all-select-activities-all
	@echo "Done"

# This requires to have all the tests traced. Note we create the app/src/allCarvedTest folder !
.carved-all-select-all : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && \
	export CARVING_OPTIONS=$(SELECT_ALL_CARVING_OPTIONS) && \
	export CARVING_JAVA_OPTIONS=$(CARVING_JAVA_OPTIONS) && \
	$(ABC) carve-all app-original.apk traces app/src/allCarvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# Make sure this file has the right timestamp - probably touch will work the same
	@sleep 1; echo "" > .carved-all-select-all
	@sleep 1; echo "" > .carved-all

.carved-all-select-one : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && \
	export CARVING_OPTIONS=$(SELECT_ONE_CARVING_OPTIONS) && \
	export CARVING_JAVA_OPTIONS=$(CARVING_JAVA_OPTIONS) && \
	$(ABC) carve-all app-original.apk traces app/src/allCarvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# Make sure this file has the right timestamp - probably touch will work the same
	@sleep 1; echo "" > .carved-all-select-one
	@sleep 1; echo "" > .carved-all
	
.carved-all-select-activities-all : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && \
	export CARVING_OPTIONS=$(SELECT_ACTIVITIES_ALL_CARVING_OPTIONS) && \
	$(ABC) carve-all app-original.apk traces app/src/allCarvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# Make sure this file has the right timestamp - probably touch will work the same
	@sleep 1; echo "" > .carved-all-select-activities-all
	@sleep 1; echo "" > .carved-all

.carved-all-select-activities-one : $(ESPRESSO_TESTS)
	@export ABC_CONFIG=$(ABC_CFG) && \
	export CARVING_OPTIONS=$(SELECT_ACTIVITIES_ONE_CARVING_OPTIONS) && \
	$(ABC) carve-all app-original.apk traces app/src/allCarvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# Make sure this file has the right timestamp - probably touch will work the same
	@sleep 1; echo "" > .carved-all-select-activities-one
	@sleep 1; echo "" > .carved-all

### ### ### ### ### ### ###
### Coverage targets
### ### ### ### ### ### ### 

coverage-espresso-tests : espresso-tests-coverage/html/index.html
	@echo "Done"

# We need to ensure the coverage apks because if the emulator is already running the target does not redeploy them
espresso-tests-coverage/html/index.html : app-original-for-coverage.apk app-androidTest-for-coverage.apk
# Ensure the right apk are installed and optionally start the emulator. Clean up the data if necessary.
	$(call ensure_coverage_apks)
	$(GW) -PjacocoEnabled=true -PcarvedTests=false clean jacocoGUITestCoverage 2>&1 </dev/null | tee espresso-tests-coverage.log
	$(RM) -r espresso-tests-coverage
	mv -v app/build/reports/jacoco/jacocoGUITestCoverage espresso-tests-coverage || echo "(Error: espresso-tests-coverage not found)"
# This might not even be necessary
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators

coverage-for-each-espresso-test : $(ESPRESSO_TESTS_COVERAGE)
# This might not even be necessary
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	@echo "Done"

$(ESPRESSO_TESTS_COVERAGE): app-original-for-coverage.apk app-androidTest-for-coverage.apk
# Ensure the right apk are installed and optionally start the emulator. Clean up the data if necessary.
	$(call ensure_coverage_apks)
# Tack test/folder
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|__|\\\#|g' -e 's|/html/index.html||' -e 's|espresso-test-coverage-for-||'))
	$(eval COVERAGE_FOLDER := $(shell echo "$(@)" | sed -e 's|/html/index.html||'))
# Execute the gradle target
	@echo "Running Test $(TEST_NAME)"
	$(GW) -PjacocoEnabled=true -PcarvedTests=false -Pandroid.testInstrumentationRunnerArguments.class=$(TEST_NAME) jacocoGUITestCoverage </dev/null
	mv -v app/build/reports/jacoco/jacocoGUITestCoverage $(COVERAGE_FOLDER)
# TODO debugAndroidTest folder might probably have some other name based on gradle config
	mv -v app/build/outputs/code_coverage/debugAndroidTest/connected/*coverage.ec $(COVERAGE_FOLDER)/$(TEST_NAME).ec

coverage-unit-tests : unit-tests-coverage/html/index.html
	@echo "Done"

unit-tests-coverage/html/index.html :
	$(GW) -PjacocoEnabled=true -PcarvedTests=false clean jacocoUnitTestCoverage 2>&1 </dev/null | tee unit-tests-coverage.log
	$(RM) -r unit-tests-coverage
	mv -v app/build/reports/jacoco/jacocoUnitTestCoverage unit-tests-coverage

# Phony target
coverage-carved-tests : all-carved-tests-coverage/html/index.html selected-carved-tests-coverage/html/index.html
	@echo "Done"

# Actual target
all-carved-tests-coverage/html/index.html : carved-tests.log
	@echo "Done"

# This is required because we need it to run each carved test in isolation
carved-tests.log : .carved-all
	$(RM) -r app/src/carvedTest
	cp -r app/src/allCarvedTest app/src/carvedTest
	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage 2>&1 </dev/null | tee carved-tests.log
	$(RM) -r all-carved-tests-coverage
	mv -v build/carvedTest/coverage all-carved-tests-coverage || echo "(Error: all-carved-tests-coverage not found)"

# This is required because we need it to run each carved test in isolation
selected-carved-tests-coverage/html/index.html : selected-carved-tests.done
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
# Ensure we are using the right carved tests by creating a link to the folder.
	$(RM) -r app/src/carvedTest
	cp -r app/src/selectedCarvedTest app/src/carvedTest
	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage 2>&1 </dev/null | tee selected-carved-tests.log
	$(RM) -r selected-carved-tests-coverage
	mv -v build/carvedTest/coverage selected-carved-tests-coverage || echo "(Error: selected-carved-tests-coverage not found)"

$(CARVED_TESTS_COVERAGE): carved-tests.log
# Ensure we use all the carvedTests here
	$(RM) -r app/src/carvedTest
	cp -r app/src/allCarvedTest app/src/carvedTest
# Extract the test name from the target folder
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|/html/index.html||' -e 's|carved-test-coverage-for-||'))
	$(eval COVERAGE_FOLDER := $(shell echo "$(@)" | sed -e 's|/html/index.html||'))
# Clean up the coverage folder (this should not be necessary)
	$(RM) -rv $(COVERAGE_FOLDER)
# Run the single unit test and collect coverage
	$(GW) -PjacocoEnabled=true -PcarvedTests=true -PcarvedTestsFilter=$(TEST_NAME) clean jacocoUnitTestCoverage </dev/null
# Copy the coverage folder in the expected place
	mv -v ./build/carvedTest/coverage $(COVERAGE_FOLDER) || echo "(Error: ./build/carvedTest/coverage not found)"

coverage-for-each-carved-test : carved-tests.log $(CARVED_TESTS_COVERAGE)
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	@echo "Done"

#
# TODO Alessio: Not robust. This requires the RIGHT naming convention when generating the tests!
# This file is the one we need to compare the coverage of selected tests and select them
#
carved-coverage-for-selection.csv : carved-tests.log $(CARVED_TESTS_COVERAGE)
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
	@for COV in $(CARVED_TESTS_COVERAGE); do \
		echo "Processing $$COV"; \
		TEST_NAME=`echo "$$COV" | $(SED) -e 's|/html/index.html||' -e 's|carved-test-coverage-for-||'`; \
		METHOD_UNDER_TEST=`echo "$$COV" | $(SED) -e 's|.*\.test_\(.*\)|\1|' | tr "_" " "| awk '{$$NF=""; print $$0}' | sed -e 's/[ \t]*$$//' | tr " " "."`; \
		COV_HASH=`cat $$COV | tr ">" "\n" | $(SED) '1,/.*tfoot.*/d' | $(SED) '/.*<\/tfoot*/,$$d' | tr "\n" ">" | md5sum | cut -f1 -d" "`; \
		echo "$$TEST_NAME, $METHOD_UNDER_TEST, $$COV_HASH" >> carved-coverage-for-selection.csv; \
	done


####################
#	SELECTION TARGETS
####################

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
		echo "app/src/selectedCarvedTest/$${TEST_PACKAGE//.//}/$$TEST_CLASS.java"; \
	done< <(cat selected-carved-tests.csv | \
		tr "," " " | \
		awk '{print $$1}' | \
		$(SED) 's|\(.*\)\.test_\(.*\)|\1 \2|' | \
		$(SED) 's|\(.*\)\.\(.*\) \(.*\)|\1 \2 \3|') > white-listed-tests.txt

delete-duplicated-carved-tests : selected-carved-tests.done
	@Done

selected-carved-tests.done : carved-tests.log white-listed-tests.txt
ifeq ($(REQUIRE_RERUN), 1)
	$(error "$(REQUIRE_RERUN) We need to restart make to ensure the right preconditions are there");
endif
# Ensure we clean up any other result
	@ $(RM) -r app/src/selectedCarvedTest; \
	cp -rv app/src/allCarvedTest app/src/selectedCarvedTest; \
	for TEST in $$(find app/src/selectedCarvedTest -iname "Test*.java"); do \
		if [[ $$(grep -c $$TEST white-listed-tests.txt) -eq 1 ]]; then \
			echo "Keep $TEST"; \
		else \
			$(RM) -v $$TEST $$TEST.removed ; \
		fi; \
	done; \
	touch selected-carved-tests.done