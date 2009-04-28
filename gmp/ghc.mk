# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------


# Compile GMP only if we don't have it already
#
# We use GMP's own configuration stuff, because it's all rather hairy
# and not worth re-implementing in our Makefile framework.

ifeq "$(findstring dyn, $(GhcRTSWays))" "dyn"
BUILD_SHARED=yes
else
BUILD_SHARED=no
endif

# In a bindist, we don't want to know whether /this/ machine has gmp,
# but whether the machine the bindist was built on had gmp.
ifeq "$(BINDIST)" "YES"
ifeq "$(wildcard gmp/libgmp.a)" ""
HaveLibGmp = YES
HaveFrameworkGMP = YES
else
HaveLibGmp = NO
HaveFrameworkGMP = NO
endif
endif

ifneq "$(HaveLibGmp)" "YES"
ifneq "$(HaveFrameworkGMP)" "YES"

INSTALL_LIBS += gmp/libgmp.a

$(eval $(call all-target,gmp_dynamic,gmp/libgmp.a))

ifeq "$(BUILD_SHARED)" "yes"
$(eval $(call all-target,gmp_dynamic,gmp/libgmp.dll.a gmp/libgmp-3.dll))
endif

endif
endif

PLATFORM := $(shell echo $(HOSTPLATFORM) | sed 's/i[567]86/i486/g')

# 2007-09-26
#     set -o igncr 
# is not a valid command on non-Cygwin-systems.
# Let it fail silently instead of aborting the build.
#
# 2007-07-05
# We do
#     set -o igncr; export SHELLOPTS
# here as otherwise checking the size of limbs
# makes the build fall over on Cygwin. See the thread
# http://www.cygwin.com/ml/cygwin/2006-12/msg00011.html
# for more details.

# 2007-07-05
# Passing
#     as_ln_s='cp -p'
# isn't sufficient to stop cygwin using symlinks the mingw gcc can't
# follow, as it isn't used consistently. Instead we put an ln.bat in
# path that always fails.

# We use a tarball like gmp-4.2.4-nodoc.tar.bz2, which is
# gmp-4.2.4.tar.bz2 repacked without the doc/ directory contents.
# That's because the doc/ directory contents are under the GFDL,
# which causes problems for Debian.

GMP_TARBALL := $(wildcard gmp/tarball/gmp*.tar.bz2)
GMP_DIR := $(patsubst gmp/tarball/%-nodoc.tar.bz2,%,$(GMP_TARBALL))

# XXX INSTALL_HEADERS += gmp.h

gmp/libgmp.a:
	$(RM) -rf $(GMP_DIR) gmp/gmpbuild
	cd gmp && $(TAR) -jxf ../$(GMP_TARBALL)
	mv gmp/$(GMP_DIR) gmp/gmpbuild
	chmod +x gmp/ln
	cd gmp; (set -o igncr 2>/dev/null) && set -o igncr; export SHELLOPTS; \
	    PATH=`pwd`:$$PATH; \
	    export PATH; \
	    cd gmpbuild && \
	    CC=$(WhatGccIsCalled) $(SHELL) configure \
	          --enable-shared=no --host=$(PLATFORM) --build=$(PLATFORM)
	$(MAKE) -C gmp/gmpbuild MAKEFLAGS=
	$(CP) gmp/gmpbuild/.libs/libgmp.a gmp/
	$(RANLIB) gmp/libgmp.a

$(eval $(call clean-target,gmp,,\
  gmp/libgmp.a gmp/gmpbuild gmp/$(GMP_DIR)))

# XXX TODO:
#stamp.gmp.shared:
#	$(RM) -rf $(GMP_DIR) gmpbuild-shared
#	$(TAR) -zxf $(GMP_TARBALL)
#	mv $(GMP_DIR) gmpbuild-shared
#	chmod +x ln
#	(set -o igncr 2>/dev/null) && set -o igncr; export SHELLOPTS; \
#	    PATH=`pwd`:$$PATH; \
#	    export PATH; \
#	    cd gmpbuild-shared && \
#	    CC=$(WhatGccIsCalled) $(SHELL) configure \
#	          --enable-shared=yes --disable-static --host=$(PLATFORM) --build=$(PLATFORM)
#	touch $@
#
#gmp.h: stamp.gmp.static
#	$(CP) gmpbuild/gmp.h .
#
#libgmp.a: stamp.gmp.static
#
#libgmp-3.dll: stamp.gmp.shared
#	$(MAKE) -C gmpbuild-shared MAKEFLAGS=
#	$(CP) gmpbuild-shared/.libs/libgmp-3.dll .
#
#libgmp.dll.a: libgmp-3.dll
#	$(CP) gmpbuild-shared/.libs/libgmp.dll.a .

## GMP takes a long time to build, but changes rarely.  Hence we don't
## bother cleaning it before validating, because that adds a
## significant overhead to validation.
#ifeq "$(Validating)" "NO"
#clean distclean maintainer-clean ::
#	$(RM) -f stamp.gmp.static stamp.gmp.shared
#	$(RM) -rf gmpbuild
#	$(RM) -rf gmpbuild-shared
#endif
