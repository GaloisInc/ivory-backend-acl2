-- | Compiling Ivory to ACL2.
module Ivory.Compile.ACL2
  ( compileModule
  , verifyModule
  , verifyModules
  ) where

import Data.List
import System.IO
import System.Process

import Ivory.Compile.ACL2.ACL2 (Expr)
import Ivory.Compile.ACL2.ACL2Convert
import Ivory.Compile.ACL2.ACL2Convert2
import Ivory.Compile.ACL2.CPS (explicitStack)
import Ivory.Compile.ACL2.CPSConvert
import Ivory.Compile.ACL2.RTLConvert
import qualified Ivory.Language.Syntax.AST as I
import Ivory.Language.Syntax.AST (Module (..))

-- | Compiles a module to two different ACL2 representations: assembly and CPS.
compileModule :: Module -> (String, [Expr], [Expr])
compileModule m = (name, acl21, acl22)
  where
  cps1  = map cpsConvertProc $ procs m 
  cps2  = map explicitStack cps1
  rtl   = rtlConvert        cps2
  acl21 = acl2Convert       rtl 
  acl22 = acl2Convert2      cps2
  name = modName m
  procs :: I.Module -> [I.Proc]
  procs m = I.public (I.modProcs m) ++ I.private (I.modProcs m)

-- | Given a expected result, verifies a module.
verifyModule :: Bool -> Module -> IO Bool
verifyModule expected m = do
  writeFile (name ++ ".lisp") acl2CPS

  putStr $ "Verifying termination of: " ++ name ++ " ... "
  hFlush stdout
  (_, result, _) <- readProcessWithExitCode "acl2" [] acl2CPS
  let terminates = not $ any (isPrefixOf "ACL2 Error") $ lines result
  putStrLn $ if terminates then "pass" else "FAIL"
  writeFile (name ++ "_termination.log") result
  hFlush stdout

  putStr $ "Verifying assertions of:  " ++ name ++ " ... "
  hFlush stdout
  (_, result, _) <- readProcessWithExitCode "acl2" [] acl2Asm
  let pass = expected == (not $ any (isPrefixOf "ACL2 Error") $ lines result)
  putStrLn $ if pass then "pass" else "FAIL"
  writeFile (name ++ "_assertions.log") result
  hFlush stdout

  return $ terminates && pass

  where
  (name, acl2Asm', acl2CPS') = compileModule m
  acl2Asm = unlines $ map show acl2Asm'
  acl2CPS = unlines $ map show acl2CPS'

-- | Verifies a list of modules.
verifyModules :: [(Bool, Module)] -> IO Bool
verifyModules m = do
  pass <- sequence [ verifyModule a b | (a, b) <- m ]
  return $ and pass

