
include $(TOP)/mk/cabal-flags.mk
include $(TOP)/mk/bindist.mk

# XXX We would like to turn this on, but Cabal generates paths files
#     that are not -Wall clean!
# SRC_HC_OPTS      += -Wall

ifeq "$(HOSTPLATFORM)" "i386-unknown-mingw32"
INSTALL_FLAGS =
else
ifeq "$(ENABLE_SHELL_WRAPPERS)" "YES"
INSTALL_FLAGS = --enable-shell-wrappers
else
INSTALL_FLAGS =
endif
endif

# Tell stage1 to make a dynamically-linked binary, but no wrapper.  We assume
# that in an installation the shared libs will be installed somewhere that
# the system can find them.
ifeq "$(BuildSharedLibs)" "YES"
DYN_FLAGS = --ghc-option=-dynamic --ghc-option=-dynload --ghc-option=deploy
endif

.PHONY: default all with-bootstrapping-compiler with-stage-1 clean distclean

default all: with-bootstrapping-compiler

with-bootstrapping-compiler:
	$(CABAL) configure --distpref dist-inplace          \
	                   $(INPLACE_DIRS_CONFIGURE_FLAGS)  \
	                   $(USE_BOOT_CONFIGURE_FLAGS)      \
	                   $(COMMON_CONFIGURE_FLAGS)        \
	                   $(EXTRA_INPLACE_CONFIGURE_FLAGS)
	$(CABAL) build     --distpref dist-inplace $(BUILD_FLAGS)
	$(CABAL) install   --distpref dist-inplace $(INSTALL_FLAGS)

with-stage-1:
	$(CABAL) configure --distpref dist-install         \
	                   $(INSTALL_DIRS_CONFIGURE_FLAGS) \
	                   $(USE_STAGE1_CONFIGURE_FLAGS)   \
	                   $(COMMON_CONFIGURE_FLAGS)       \
	                   $(EXTRA_STAGE1_CONFIGURE_FLAGS)
	$(CABAL) build     --distpref dist-install $(DYN_FLAGS) $(BUILD_FLAGS)

install:
	$(INSTALL_PACKAGE) install UNUSED UNUSED '$(DESTDIR)' '$(prefix)' \
	                   '$(prefix)' '$(bindir)' '$(libdir)'            \
                       '$(libexecdir)' '$(dynlibdir)' '$(datadir)'    \
                       '$(docdir)' '$(htmldir)' '$(haddockdir)'       \
	                   --distpref dist-install                        \
	                   $(INSTALL_FLAGS)

clean:
	-$(CABAL) clean --distpref dist-inplace
	-$(CABAL) clean --distpref dist-install
ifneq "$(EXTRA_CLEAN)" ""
	$(RM) -f $(EXTRA_CLEAN)
endif

distclean: clean
ifneq "$(EXTRA_DISTCLEAN)" ""
	$(RM) -f $(EXTRA_DISTCLEAN)
endif
