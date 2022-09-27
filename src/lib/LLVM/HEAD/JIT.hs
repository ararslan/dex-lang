-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

-- NOTE: Use LLVM.JIT instead of this version-specific module!
module LLVM.HEAD.JIT where

import Control.Monad
import Control.Exception
import Foreign.Ptr
import Data.IORef
import Data.String
import Data.List (sortBy)
import qualified Data.Map.Strict as M
import System.IO
import System.IO.Temp
import qualified Data.ByteString.Char8 as C8BS
import qualified Data.ByteString.Short as SBS
import qualified Data.ByteString       as BS

import qualified LLVM.OrcJIT as OrcJIT
import qualified LLVM.Internal.OrcJIT as OrcJIT
import qualified LLVM.Target as T

import qualified LLVM.AST
import qualified LLVM.AST.Global as LLVM.AST
import qualified LLVM.AST.Constant as C
import qualified LLVM.Module as LLVM
import qualified LLVM.Context as LLVM

data JIT =
    JIT { session      :: OrcJIT.ExecutionSession
        , objectLayer  :: OrcJIT.RTDyldObjectLinkingLayer
        , compileLayer :: OrcJIT.IRCompileLayer
        , nextDylibId  :: IORef Int
        }


type ExplicitLinkMap = M.Map String (Ptr ()) 

-- XXX: The target machine cannot be destroyed before JIT is destroyed
createJIT :: T.TargetMachine -> IO JIT
createJIT tm = do
  session      <- OrcJIT.createExecutionSession
  objectLayer  <- OrcJIT.createRTDyldObjectLinkingLayer session
  compileLayer <- OrcJIT.createIRCompileLayer session objectLayer tm
  nextDylibId  <- newIORef 0
  return JIT{..}

destroyJIT :: JIT -> IO ()
destroyJIT JIT{..} =
  OrcJIT.disposeExecutionSession session

withJIT :: T.TargetMachine -> (JIT -> IO a) -> IO a
withJIT tm = bracket (createJIT tm) destroyJIT

data NativeModule =
  NativeModule { moduleJIT      :: JIT
               , moduleDylib    :: OrcJIT.JITDylib
               , moduleDtors    :: [FunPtr (IO ())]
               }

type CompilationPipeline = LLVM.Module -> IO ()
type ObjectFileContents = BS.ByteString

-- TODO: This leaks resources if we fail halfway
compileModule :: JIT -> ExplicitLinkMap -> LLVM.AST.Module
              -> CompilationPipeline -> IO NativeModule
compileModule moduleJIT@JIT{..} linkMap ast compilationPipeline = do
  tsModule <- LLVM.withContext \c ->
    LLVM.withModuleFromAST c ast \m -> do
      compilationPipeline m
      OrcJIT.cloneAsThreadSafeModule m
  moduleDylib <- newDylib moduleJIT
  withExplicitLinkMap compileLayer moduleDylib linkMap do
    OrcJIT.addDynamicLibrarySearchGeneratorForCurrentProcess compileLayer moduleDylib
    OrcJIT.addModule tsModule moduleDylib compileLayer
    moduleDtors <- forM dtorNames \dtorName -> do
      Right (OrcJIT.JITSymbol dtorAddr _) <-
        OrcJIT.lookupSymbol session compileLayer moduleDylib $ fromString dtorName
      return $ castPtrToFunPtr $ wordPtrToPtr dtorAddr
    return NativeModule{..}
  where
    -- Unfortunately the JIT layers we use here don't handle the destructors properly,
    -- so we have to find and call them ourselves.
    dtorNames = do
      let dtorStructs = flip foldMap (LLVM.AST.moduleDefinitions ast) \case
            LLVM.AST.GlobalDefinition
              LLVM.AST.GlobalVariable{
                name="llvm.global_dtors",
                initializer=Just (C.Array _ elems)} -> elems
            _ -> []
      -- Sort in the order of decreasing priority!
      fmap snd $ sortBy (flip compare) $ flip fmap dtorStructs $
#if MIN_VERSION_llvm_hs(15,0,0)
        \(C.Struct _ _ [C.Int _ n, C.GlobalReference (LLVM.AST.Name dname), _]) ->
#else
        \(C.Struct _ _ [C.Int _ n, C.GlobalReference _ (LLVM.AST.Name dname), _]) ->
#endif
          (n, C8BS.unpack $ SBS.fromShort dname)
{-# SCC compileModule #-}

foreign import ccall "dynamic"
  callDtor :: FunPtr (IO ()) -> IO ()

loadNativeModule :: JIT -> ExplicitLinkMap -> ObjectFileContents -> IO NativeModule
loadNativeModule moduleJIT linkingMap objFileContents = do
  moduleDylib <- newDylib moduleJIT
  let cl = compileLayer moduleJIT
  withExplicitLinkMap cl moduleDylib linkingMap do
    OrcJIT.addDynamicLibrarySearchGeneratorForCurrentProcess cl moduleDylib
    let moduleDtors = [] -- TODO(dougalm): handle destructors (with help from Adam)
    loadObjectFile moduleJIT moduleDylib objFileContents
    return NativeModule{..}

withExplicitLinkMap :: OrcJIT.IRCompileLayer -> OrcJIT.JITDylib -> ExplicitLinkMap -> IO a -> IO a
withExplicitLinkMap l dylib linkMap cont = do
  let (linkedNames, linkedPtrs) = unzip $ M.toList linkMap
  let flags = OrcJIT.defaultJITSymbolFlags { OrcJIT.jitSymbolAbsolute = True }
  let ptrSymbols = [OrcJIT.JITSymbol (ptrToWordPtr ptr) flags | ptr <- linkedPtrs]
  withMangledSymbols l (map fromString linkedNames) \linkedNames' -> do
    OrcJIT.defineAbsoluteSymbols dylib $ zip linkedNames' ptrSymbols
    cont

withMangledSymbols :: OrcJIT.IRLayer l => l -> [SBS.ShortByteString] -> ([OrcJIT.MangledSymbol] -> IO a) -> IO a
withMangledSymbols _ [] cont = cont []
withMangledSymbols l (s:ss) cont =
  OrcJIT.withMangledSymbol l s \ms ->
    withMangledSymbols l ss \mss -> cont (ms:mss)

-- TODO: This might not release everything if it fails halfway
unloadNativeModule :: NativeModule -> IO ()
unloadNativeModule NativeModule{..} = do
  -- TODO: Clear the dylib
  forM_ moduleDtors callDtor
{-# SCC unloadNativeModule #-}

withNativeModule :: JIT -> ExplicitLinkMap -> LLVM.AST.Module -> CompilationPipeline -> (NativeModule -> IO a) -> IO a
withNativeModule jit linkMap m p = bracket (compileModule jit linkMap m p) unloadNativeModule

getFunctionPtr :: NativeModule -> String -> IO (FunPtr a)
getFunctionPtr NativeModule{..} funcName = do
  let JIT{..} = moduleJIT
  OrcJIT.lookupSymbol session compileLayer moduleDylib (fromString funcName) >>= \case
    Right (OrcJIT.JITSymbol funcAddr _) ->
      return $ castPtrToFunPtr $ wordPtrToPtr funcAddr
    Left _ -> error $ "Couldn't find function: " ++ funcName

newDylib :: JIT -> IO OrcJIT.JITDylib
newDylib jit = do
  let ref = nextDylibId jit
  dylibId <- readIORef ref <* modifyIORef' ref (+1)
  let name = fromString $ "module" ++ show dylibId
  OrcJIT.createJITDylib (session jit) name

loadObjectFile :: JIT -> OrcJIT.JITDylib -> ObjectFileContents -> IO ()
loadObjectFile jit dylib objFileContents = do
  withSystemTempFile "objfile.o" \path h -> do
    BS.hPut h objFileContents
    hFlush h
    OrcJIT.addObjectFile (objectLayer jit) dylib path
{-# SCC loadObjectFile #-}
