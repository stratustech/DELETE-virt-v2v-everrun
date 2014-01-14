PWD := $(shell pwd)
PRISTINE_RPM=$(PWD)/pristine/virt-v2v-0.8.9-2.el6.src.rpm
.PHONY: all clean rpm build

default: rpm

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
	rpmbuild --define "_topdir `pwd`" -ba SPECS/virt-v2v.spec --target=x86_64
clean:
	rm -rf build
