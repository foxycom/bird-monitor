### MAIN VARIABLES
GW=./gradlew
ABC=../../scripts/abc.sh
ABC_CFG=../../scripts/.abc-config
JAVA_OPTS=" -Dabc.instrument.fields.operations -Dabc.taint.android.intents -Dabc.instrument.include=nz.org.cacophony.birdmonitor"

ADB := $(shell $(ABC) show-config  ANDROID_ADB_EXE | sed -e "s|ANDROID_ADB_EXE=||")
# Create a list of expected test executions from tests.txt Those corresponds to the traces
ESPRESSO_TESTS := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.testlog|')
# Create the list of expected carved targets from tests.txt
ESPRESSO_TESTS_CARVED := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.carved|')
# Create the list of expected coverage targets from tests.txt
ESPRESSO_TESTS_COVERAGE := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|espresso-test-coverage-for-\1/html/index.html|')


.PHONY: clean-gradle clean-all carve-all run-espresso-tests trace-espresso-tests

show :
	$(info $(ADB))

clean-gradle :
	$(GW) clean

# Debug Target
list-all-tests :
	@echo $(ESPRESSO_TESTS) | tr " " "\n"
	

list-tests : $(ESPRESSO_TESTS)
	@echo $? | tr " " "\n"

list-coverage-targets:
	@ echo $(ESPRESSO_TESTS_COVERAGE) | tr " " "\n"
	
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
	$(RM) -rv espresso-tests-coverage unit-tests-coverage carved-test-coverage
	$(RM) -rv espresso-test-coverage-for-*

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
	@echo "Requiement $?"
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) carve-all app-original.apk traces app/src/carvedTest force-clean 2>&1 | tee carving.log
	@export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
# 	Make sure this file has a timestamp after the prerequiesing
	@sleep 1; echo "" > .carved-all


run-all-carved-tests : carvedTests.log
	@echo "Done"

carvedTests.log : .carved-all
	@echo "Done"
	@touch carvedTests.log
# $(GW) -PjacocoEnabled=false clean testDebugUnitTest -PcarvedTests 2>&1 | tee carvedTests.log

# # This run whatever tests is in the carvedTest folder -  UNSAFE
# # Does not ensures carved tests are there but always run
# run-all-existing-carved-tests :
# 	$(GW) -PjacocoEnabled=false clean testDebugUnitTest -PcarvedTests 2>&1 | tee carvedTests.log

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
	
# Phony  target
coverage-for-each-espresso-test :  $(ESPRESSO_TESTS_COVERAGE)
	@echo "Processing: $(shell echo $? | tr " " "\n")"
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	@echo "Done"


# Run existing unit tests (not carved ones)
coverage-unit-tests :
	$(GW) -PjacocoEnabled=true -PcarvedTests=false clean jacocoUnitTestCoverage
	$(RM) -r unit-tests-coverage
	mv -v app/build/reports/jacoco/jacocoUnitTestCoverage unit-tests-coverage

# UPDATE THIS WITH TO CHECK THE RIGHT FILES .covered or index.html.  --info
coverage-carved-tests : .carved-all
	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage
	$(RM) -r carved-test-coverage
	mv -v build/carvedTest/coverage carved-test-coverage

coverage-existing-carved-tests :
	$(GW) -PjacocoEnabled=true -PcarvedTests=true clean jacocoUnitTestCoverage
	$(RM) -r  carved-test-coverage
	mv -v build/carvedTest/coverage carved-test-coverage
