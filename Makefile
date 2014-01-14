PWD := $(shell pwd)
PRISTINE_RPM=$(PWD)/pristine/virt-v2v-0.8.9-2.el6.src.rpm
.PHONY: all clean rpm build version version_major version_minor

default: rpm

# Jenkins (or the user calling Make) can specify a BUILD_NUMBER to specify a unique
# and ever-increasing build number to facilitate unique, upgradeable RPM versions.
ifeq (${BUILD_NUMBER},)
  BUILD_NUMBER := 1
endif

MAJOR_REV=0
MINOR_REV=1
PATCH_REV=${BUILD_NUMBER}

build:
	rm -rf build
	install -d --mode=755 build
	install -d --mode=755 build/SOURCES
	install -d --mode=755 build/SPECS
	cp everrun/*.spec build/SPECS/;
	cp everrun/*.patch build/SOURCES/
	cd build; \
	rpm2cpio $(PRISTINE_RPM) | cpio -idmv;
	cd build; \
	mv *.patch SOURCES/; \
	mv *.exe SOURCES/; \
	mv *.gz SOURCES/; \
	rm *.spec

all: rpm

rpm:
	make build
	cd build; \
	mkdir -p BUILD RPMS BUILDROOT; \
	STRATUS_MAJOR=$(MAJOR_REV) STRATUS_MINOR=$(MINOR_REV) STRATUS_PATCH=$(PATCH_REV)\
		rpmbuild --define "_topdir `pwd`" -ba SPECS/virt-v2v.spec --target=x86_64
clean:
	rm -rf build

# Export the version pieces to the calling shell
version:
	@echo $(MAJOR_REV).$(MINOR_REV).$(PATCH_REV)

version_major:
	@echo $(MAJOR_REV)

version_minor:
	@echo $(MINOR_REV)
