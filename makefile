### MAIN VARIABLES
GW="./gradlew"
ABC="../../scripts/abc.sh"
ABC_CFG="../../scripts/.abc-config"
JAVA_OPTS=" -Dabc.instrument.fields.operations -Dabc.taint.android.intents -Dabc.instrument.include=nz.org.cacophony.birdmonitor"

ADB := $(shell $(ABC) show-config  ANDROID_ADB_EXE | sed -e "s|ANDROID_ADB_EXE=||")

ESPRESSO_TESTS := $(shell cat tests.txt | sed '/^[[:space:]]*$$/d' | sed -e 's| |__|g' -e 's|^\(.*\)$$|\1.testlog|')


.PHONY: clean-gradle clean-all run-espresso-tests trace-espresso-tests

show :
	$(info $(ADB))

clean-gradle :
	$(GW) clean

list-all-tests :
	echo $(ESPRESSO_TESTS) | tr " " "\n"

clean-all :
	$(RM) -v *.apk
	$(RM) -v *.log
	$(RM) -v *.testlog
	$(RM) -rv .traced
	$(RM) -rv traces
	$(RM) -rv app/src/carvedTest
	$(RM) -rv espresso-tests-coverage unit-tests-coverage carved-test-coverage


app-original.apk :
	export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) -PjacocoEnabled=false assembleDebug && \
	mv app/build/outputs/apk/debug/Bird-Monitor-1.9.1-debug.apk app-debug.apk && \
	$(ABC) sign-apk app-debug.apk && \
	mv -v app-debug.apk app-original.apk

app-original-with-jacoco.apk :
	export ABC_CONFIG=$(ABC_CFG) && \
	$(GW) -PjacocoEnabled=true assembleDebug && \
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

running-emulator:
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) start-clean-emulator
	touch running-emulator

stop-emulator:
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	$(RM) running-emulator

espresso-tests.log : app-original.apk app-androidTest.apk running-emulator
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-original.apk
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-androidTest.apk
	$(ADB) shell am instrument -w -r nz.org.cacophony.birdmonitor.test/androidx.test.runner.AndroidJUnitRunner | tee espresso-tests.log
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	$(RM) running-emulator

# 	This is phony
#    It depends on all the espresso files listed in the tests.txt file
.traced : $(ESPRESSO_TESTS) app-androidTest.apk app-instrumented.apk running-emulator
	# Once execution of the dependent target is over we tear down the emulator
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) stop-all-emulators
	$(RM) running-emulator
	touch .traced

# Note: https://stackoverflow.com/questions/9052220/hash-inside-makefile-shell-call-causes-unexpected-behaviour
%.testlog: app-androidTest.apk app-instrumented.apk running-emulator
	$(eval FIRST_RUN := $(shell $(ADB) shell pm list packages | grep -c nz.org.cacophony.birdmonitor))
	@if [ "$(FIRST_RUN)" == "2" ]; then \
		echo "Resetting the data of the apk"; \
		$(ADB) shell pm clear nz.org.cacophony.birdmonitor; \
	else \
	 	echo "Installing the apk" ;\
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-instrumented.apk; \
		echo "Installing the test apk" ;\
		export ABC_CONFIG=$(ABC_CFG) && $(ABC) install-apk app-androidTest.apk; \
    fi
	
	$(eval TEST_NAME := $(shell echo "$(@)" | sed -e 's|__|\\\#|g' -e 's|.testlog||'))
	 echo "Tracing test $(TEST_NAME)"
	$(ADB) shell am instrument -w -e class $(TEST_NAME) nz.org.cacophony.birdmonitor.test/androidx.test.runner.AndroidJUnitRunner | tee $(@)
	export ABC_CONFIG=$(ABC_CFG) && $(ABC) copy-traces nz.org.cacophony.birdmonitor ./traces/$(TEST_NAME) force-clean

carve-all : .traced app-original.apk
	export ABC_CONFIG=$(ABC_CFG) && \
	$(ABC) carve-all app-original.apk traces app/src/carvedTest force-clean 2>&1 | tee carving.log

carve-cached-traces : app-original.apk
	export ABC_CONFIG=$(ABC_CFG) && \
		$(ABC) carve-all app-original.apk traces app/src/carvedTest force-clean 2>&1 | tee carving.log

# TODO We need to provide the shadows in some sort of generic way and avoid hardcoding them for each and every application, unless we can create them programmatically
copy-shadows :
	cp -v ./shadows/*.java app/src/carvedTest/nz/org/cacophony/birdmonitor

# DO WE NEED THE SAME APPROACH AS ESPRESSO TESTS?
run-all-carved-tests : app/src/carvedTest copy-shadows
	$(GW) clean testDebugUnitTest -PcarvedTests 2>&1 | tee carvedTests.log

### ### ### ### ### ### ###
### Coverage targets
### ### ### ### ### ### ###

coverage-espresso-tests :
	export ABC_CONFIG=$(ABC_CFG) && \
	abc start-clean-emulator && \
	$(GW) -PjacocoEnabled=true clean jacocoGUITestCoverage && \
	mkdir -p espresso-test-coverage && \
	cp -r app/build/reports/jacoco/jacocoGUITestCoverage espresso-test-coverage && \
	$(ABC) stop-all-emulators

coverage-unit-tests :
	$(GW) -PjacocoEnabled=true clean jacocoTestReport && \
	cp -r app/build/reports/jacoco/jacocoTestsReport unit-tests-coverage

coverage-carved-tests : copy-shadows
	$(GW) -PjacocoEnabled=true jacocoUnitTestCoverage -PcarvedTests --info && \
	mkdir -p carved-test-coverage && \
	cp -r app/build/carvedTest/coverage carved-test-coverage