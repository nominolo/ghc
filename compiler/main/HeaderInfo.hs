-----------------------------------------------------------------------------
--
-- | Parsing the top of a Haskell source file to get its module name,
-- imports and options.
--
-- (c) Simon Marlow 2005
-- (c) Lemmih 2006
--
-----------------------------------------------------------------------------

module HeaderInfo ( getImports
                  , mkPrelImports -- used by the renamer too
                  , getOptionsFromFile, getOptions
                  , optionsErrorMsgs,
                    checkProcessArgsResult ) where

#include "HsVersions.h"

import RdrName
import HscTypes
import Parser		( parseHeader )
import Lexer
import FastString
import HsSyn
import Module
import PrelNames
import StringBuffer
import SrcLoc
import DynFlags
import ErrUtils
import Util
import Outputable
import Pretty           ()
import Maybes
import Bag		( emptyBag, listToBag, unitBag )
import MonadUtils
import Exception

import Control.Monad
import System.IO
import System.IO.Unsafe
import Data.List

------------------------------------------------------------------------------

-- | Parse the imports of a source file.
--
-- Throws a 'SourceError' if parsing fails.
getImports :: DynFlags
           -> StringBuffer -- ^ Parse this.
           -> FilePath     -- ^ Filename the buffer came from.  Used for
                           --   reporting parse error locations.
           -> FilePath     -- ^ The original source filename (used for locations
                           --   in the function result)
           -> IO ([Located (ImportDecl RdrName)], [Located (ImportDecl RdrName)], Located ModuleName)
              -- ^ The source imports, normal imports, and the module name.
getImports dflags buf filename source_filename = do
  let loc  = mkSrcLoc (mkFastString filename) 1 1
  case unP parseHeader (mkPState dflags buf loc) of
    PFailed span err -> parseError span err
    POk pst rdr_module -> do
      let _ms@(_warns, errs) = getMessages pst
      -- don't log warnings: they'll be reported when we parse the file
      -- for real.  See #2500.
          ms = (emptyBag, errs)
      -- logWarnings warns
      if errorsFound dflags ms
        then throwIO $ mkSrcErr errs
        else
	  case rdr_module of
	    L _ (HsModule mb_mod _ imps _ _ _) ->
	      let
                main_loc = mkSrcLoc (mkFastString source_filename) 1 1
		mod = mb_mod `orElse` L (srcLocSpan main_loc) mAIN_NAME
	        (src_idecls, ord_idecls) = partition (ideclSource.unLoc) imps

		     -- GHC.Prim doesn't exist physically, so don't go looking for it.
		ordinary_imps = filter ((/= moduleName gHC_PRIM) . unLoc . ideclName . unLoc) 
					ord_idecls

                implicit_prelude = xopt Opt_ImplicitPrelude dflags
                implicit_imports = mkPrelImports (unLoc mod) implicit_prelude imps
	      in
	      return (src_idecls, implicit_imports ++ ordinary_imps, mod)

mkPrelImports :: ModuleName -> Bool -> [LImportDecl RdrName]
              -> [LImportDecl RdrName]
-- Consruct the implicit declaration "import Prelude" (or not)
--
-- NB: opt_NoImplicitPrelude is slightly different to import Prelude ();
-- because the former doesn't even look at Prelude.hi for instance
-- declarations, whereas the latter does.
mkPrelImports this_mod implicit_prelude import_decls
  | this_mod == pRELUDE_NAME
   || explicit_prelude_import
   || not implicit_prelude
  = []
  | otherwise = [preludeImportDecl]
  where
      explicit_prelude_import
       = notNull [ () | L _ (ImportDecl mod Nothing _ _ _ _) <- import_decls,
	           unLoc mod == pRELUDE_NAME ]

      preludeImportDecl :: LImportDecl RdrName
      preludeImportDecl
        = L loc $
	  ImportDecl (L loc pRELUDE_NAME)
               Nothing {- no specific package -}
	       False {- Not a boot interface -}
	       False	{- Not qualified -}
	       Nothing	{- No "as" -}
	       Nothing	{- No import list -}

      loc = mkGeneralSrcSpan (fsLit "Implicit import declaration")

parseError :: SrcSpan -> Message -> IO a
parseError span err = throwOneError $ mkPlainErrMsg span err

--------------------------------------------------------------
-- Get options
--------------------------------------------------------------

-- | Parse OPTIONS and LANGUAGE pragmas of the source file.
--
-- Throws a 'SourceError' if flag parsing fails (including unsupported flags.)
getOptionsFromFile :: DynFlags
                   -> FilePath            -- ^ Input file
                   -> IO [Located String] -- ^ Parsed options, if any.
getOptionsFromFile dflags filename
    = Exception.bracket
	      (openBinaryFile filename ReadMode)
              (hClose)
              (\handle -> do
                  opts <- fmap getOptions' $ lazyGetToks dflags filename handle
                  seqList opts $ return opts)

blockSize :: Int
-- blockSize = 17 -- for testing :-)
blockSize = 1024

lazyGetToks :: DynFlags -> FilePath -> Handle -> IO [Located Token]
lazyGetToks dflags filename handle = do
  buf <- hGetStringBufferBlock handle blockSize
  unsafeInterleaveIO $ lazyLexBuf handle (pragState dflags buf loc) False
 where
  loc  = mkSrcLoc (mkFastString filename) 1 1

  lazyLexBuf :: Handle -> PState -> Bool -> IO [Located Token]
  lazyLexBuf handle state eof = do
    case unP (lexer return) state of
      POk state' t -> do
        -- pprTrace "lazyLexBuf" (text (show (buffer state'))) (return ())
        if atEnd (buffer state') && not eof
           -- if this token reached the end of the buffer, and we haven't
           -- necessarily read up to the end of the file, then the token might
           -- be truncated, so read some more of the file and lex it again.
           then getMore handle state
           else case t of
                  L _ ITeof -> return [t]
                  _other    -> do rest <- lazyLexBuf handle state' eof
                                  return (t : rest)
      _ | not eof   -> getMore handle state
        | otherwise -> return [L (last_loc state) ITeof]
                         -- parser assumes an ITeof sentinel at the end

  getMore :: Handle -> PState -> IO [Located Token]
  getMore handle state = do
     -- pprTrace "getMore" (text (show (buffer state))) (return ())
     nextbuf <- hGetStringBufferBlock handle blockSize
     if (len nextbuf == 0) then lazyLexBuf handle state True else do
     newbuf <- appendStringBuffers (buffer state) nextbuf
     unsafeInterleaveIO $ lazyLexBuf handle state{buffer=newbuf} False


getToks :: DynFlags -> FilePath -> StringBuffer -> [Located Token]
getToks dflags filename buf = lexAll (pragState dflags buf loc)
 where
  loc  = mkSrcLoc (mkFastString filename) 1 1

  lexAll state = case unP (lexer return) state of
                   POk _      t@(L _ ITeof) -> [t]
                   POk state' t -> t : lexAll state'
                   _ -> [L (last_loc state) ITeof]


-- | Parse OPTIONS and LANGUAGE pragmas of the source file.
--
-- Throws a 'SourceError' if flag parsing fails (including unsupported flags.)
getOptions :: DynFlags
           -> StringBuffer -- ^ Input Buffer
           -> FilePath     -- ^ Source filename.  Used for location info.
           -> [Located String] -- ^ Parsed options.
getOptions dflags buf filename
    = getOptions' (getToks dflags filename buf)

-- The token parser is written manually because Happy can't
-- return a partial result when it encounters a lexer error.
-- We want to extract options before the buffer is passed through
-- CPP, so we can't use the same trick as 'getImports'.
getOptions' :: [Located Token]      -- Input buffer
            -> [Located String]     -- Options.
getOptions' toks
    = parseToks toks
    where 
          getToken (L _loc tok) = tok
          getLoc (L loc _tok) = loc

          parseToks (open:close:xs)
              | IToptions_prag str <- getToken open
              , ITclose_prag       <- getToken close
              = map (L (getLoc open)) (words str) ++
                parseToks xs
          parseToks (open:close:xs)
              | ITinclude_prag str <- getToken open
              , ITclose_prag       <- getToken close
              = map (L (getLoc open)) ["-#include",removeSpaces str] ++
                parseToks xs
          parseToks (open:close:xs)
              | ITdocOptions str <- getToken open
              , ITclose_prag     <- getToken close
              = map (L (getLoc open)) ["-haddock-opts", removeSpaces str]
                ++ parseToks xs
          parseToks (open:xs)
              | ITdocOptionsOld str <- getToken open
              = map (L (getLoc open)) ["-haddock-opts", removeSpaces str]
                ++ parseToks xs
          parseToks (open:xs)
              | ITlanguage_prag <- getToken open
              = parseLanguage xs
          parseToks (x:xs)
              | ITdocCommentNext _ <- getToken x
              = parseToks xs
          parseToks _ = []
          parseLanguage (L loc (ITconid fs):rest)
              = checkExtension (L loc fs) :
                case rest of
                  (L _loc ITcomma):more -> parseLanguage more
                  (L _loc ITclose_prag):more -> parseToks more
                  (L loc _):_ -> languagePragParseError loc
                  [] -> panic "getOptions'.parseLanguage(1) went past eof token"
          parseLanguage (tok:_)
              = languagePragParseError (getLoc tok)
          parseLanguage []
              = panic "getOptions'.parseLanguage(2) went past eof token"

-----------------------------------------------------------------------------

-- | Complain about non-dynamic flags in OPTIONS pragmas.
--
-- Throws a 'SourceError' if the input list is non-empty claiming that the
-- input flags are unknown.
checkProcessArgsResult :: MonadIO m => [Located String] -> m ()
checkProcessArgsResult flags
  = when (notNull flags) $
      liftIO $ throwIO $ mkSrcErr $ listToBag $ map mkMsg flags
    where mkMsg (L loc flag)
              = mkPlainErrMsg loc $
                  (text "unknown flag in  {-# OPTIONS_GHC #-} pragma:" <+>
                   text flag)

-----------------------------------------------------------------------------

checkExtension :: Located FastString -> Located String
checkExtension (L l ext)
-- Checks if a given extension is valid, and if so returns
-- its corresponding flag. Otherwise it throws an exception.
 =  let ext' = unpackFS ext in
    if ext' `elem` supportedLanguagesAndExtensions
    then L l ("-X"++ext')
    else unsupportedExtnError l ext'

languagePragParseError :: SrcSpan -> a
languagePragParseError loc =
  throw $ mkSrcErr $ unitBag $
     (mkPlainErrMsg loc $
       vcat [ text "Cannot parse LANGUAGE pragma"
            , text "Expecting comma-separated list of language options,"
            , text "each starting with a capital letter"
            , nest 2 (text "E.g. {-# LANGUAGE RecordPuns, Generics #-}") ])

unsupportedExtnError :: SrcSpan -> String -> a
unsupportedExtnError loc unsup =
  throw $ mkSrcErr $ unitBag $
    mkPlainErrMsg loc $
        text "Unsupported extension: " <> text unsup $$
        if null suggestions then empty else text "Perhaps you meant" <+> quotedListWithOr (map text suggestions)
  where
     suggestions = fuzzyMatch unsup supportedLanguagesAndExtensions


optionsErrorMsgs :: [String] -> [Located String] -> FilePath -> Messages
optionsErrorMsgs unhandled_flags flags_lines _filename
  = (emptyBag, listToBag (map mkMsg unhandled_flags_lines))
  where	unhandled_flags_lines = [ L l f | f <- unhandled_flags, 
					  L l f' <- flags_lines, f == f' ]
        mkMsg (L flagSpan flag) = 
            ErrUtils.mkPlainErrMsg flagSpan $
                    text "unknown flag in  {-# OPTIONS_GHC #-} pragma:" <+> text flag

