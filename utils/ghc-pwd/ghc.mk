
utils/ghc-pwd_USES_CABAL = YES
utils/ghc-pwd_PACKAGE    = ghc-pwd
utils/ghc-pwd_dist_PROG  = ghc-pwd$(exeext)

$(eval $(call build-prog,utils/ghc-pwd,dist,1))

