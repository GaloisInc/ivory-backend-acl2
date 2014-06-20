-- | Compiling Ivory to ACL2.
module Ivory.Compile.ACL2
  ( compileModule
  , verifyModule
  , verifyModules
  , verifyTermination
  , verifyAssertions
  ) where

import Data.List
import System.Environment
import System.IO
import System.Process

import Mira
import qualified Mira.CLL as C
import Mira.Expr
import Mira.Verify

import qualified Ivory.Language.Syntax.AST as I
import Ivory.Language.Syntax.AST (Module (..), ExpOp (..))
import Ivory.Language.Syntax.Type
import qualified Ivory.Language.Syntax.Names as I

-- | Compiles a module to two different ACL2 representations: assembly and CPS.
compileModule :: Module -> IO String
compileModule m = do
  compile name $ cllProcs m
  return name
  where
  name = modName m

cllProcs :: Module -> [C.Proc]
cllProcs = map cllConvert . procs
  where
  procs :: I.Module -> [I.Proc]
  procs m = I.public (I.modProcs m) ++ I.private (I.modProcs m)
  

-- | Given a expected result, verifies a module.
verifyModule :: Bool -> Module -> IO Bool
verifyModule expected m = do
  putStr $ "Verifying termination of: " ++ name ++ " ... "
  hFlush stdout
  terminates <- verifyTermination m
  putStrLn $ if terminates then "pass" else "FAIL"
  hFlush stdout

  putStr $ "Verifying assertions of:  " ++ name ++ " ... "
  hFlush stdout
  f <- readFile $ modName m ++ "-rtl.lisp"
  exe <- savedACL2
  (_, result, _) <- readProcessWithExitCode exe [] f
  let pass = expected == (not $ any (isPrefixOf "ACL2 Error") $ lines result)
  putStrLn $ if pass then "pass" else "FAIL"
  writeFile (name ++ "_assertions.log") result
  hFlush stdout

  return $ terminates && pass
  where
  name = modName m

savedACL2 :: IO FilePath
savedACL2 = do
  env <- getEnvironment
  case lookup "ACL2_SOURCES" env of
    Nothing -> error "Environment variable ACL2_SOURCES not set."
    Just a -> return $ a ++ "/saved_acl2"

-- | Verifies a list of modules.
verifyModules :: [(Bool, Module)] -> IO Bool
verifyModules m = do
  pass <- sequence [ verifyModule a b | (a, b) <- m ]
  return $ and pass

-- | Verifies termination of a module.
verifyTermination :: Module -> IO Bool
verifyTermination m = do
  name <- compileModule m
  f <- readFile $ name ++ "-cps.lisp"
  exe <- savedACL2
  (_, result, _) <- readProcessWithExitCode exe [] f
  let terminates = not $ any (isPrefixOf "ACL2 Error") $ lines result
  writeFile (name ++ "_termination.log") result
  return terminates

verifyAssertions :: Module -> IO ()
verifyAssertions m = do
  r <- verifyProcs $ cllProcs m
  if r
    then putStrLn "pass"
    else putStrLn "fail"

cllConvert :: I.Proc -> C.Proc
cllConvert p = C.Proc (I.procSym p) (map (var . tValue) $ I.procArgs p) Nothing requires ensures body
  where
  body = map cllStmt (I.procBody p)
  requires :: [C.Expr]
  requires = map (cllExpr . cond . I.getRequire) $ I.procRequires p
  ensures :: [C.Expr -> C.Expr]
  ensures  = map (retval . cllExpr . cond . I.getEnsure ) $ I.procEnsures  p
  cond a = case a of
    I.CondBool a -> a
    I.CondDeref _ _ _ _ -> error $ "CondDeref not supported."
  retval :: C.Expr -> C.Expr -> C.Expr
  retval a ret = retval a
    where
    retval :: C.Expr -> C.Expr
    retval a = case a of
      C.Var "retval" -> ret
      C.Var a -> C.Var a
      C.Literal a -> C.Literal a
      C.Alloc -> C.Alloc
      C.Deref a -> C.Deref $ retval a
      C.Array a -> C.Array $ map retval a
      C.Struct a -> C.Struct [ (a, retval b) | (a, b) <- a ]
      C.ArrayIndex a b -> C.ArrayIndex (retval a) (retval b)
      C.StructIndex a b -> C.StructIndex (retval a) b
      C.Intrinsic a b -> C.Intrinsic a $ map retval b

cllStmts :: [I.Stmt] -> [C.Stmt]
cllStmts = map cllStmt

cllStmt :: I.Stmt -> C.Stmt
cllStmt a = case a of
  I.IfTE           a b c -> C.If (cllExpr a) (cllStmts b) (cllStmts c)
  I.Return         a     -> C.Return $ Just $ cllExpr $ tValue a
  I.ReturnVoid           -> C.Return Nothing
  I.Assert         a     -> C.Assert $ cllExpr a
  I.CompilerAssert a     -> C.Assert $ cllExpr a
  I.Assume         a     -> C.Assume $ cllExpr a
  I.Local          _ a b -> C.Let (var a) $ cllInit b
  I.AllocRef       _ a b -> C.Block [C.Let (var a) Alloc, C.Store (C.Var $ var a) (C.Var $ var b)]
  I.Deref          _ a b -> C.Let   (var a) $ Deref $ cllExpr b
  I.Store          _ a b -> C.Store (cllExpr a) (cllExpr b)

  I.Call   _ Nothing  fun args  -> C.Call Nothing        (var fun) $ map (cllExpr . tValue) args
  I.Call   _ (Just r) fun args  -> C.Call (Just $ var r) (var fun) $ map (cllExpr . tValue) args
  I.Loop i init incr' body      -> C.Loop (var i) (cllExpr init) incr (cllExpr to) (cllStmts body)
    where
    (incr, to) = case incr' of
      I.IncrTo a -> (True, a)
      I.DecrTo a -> (False, a)

  I.Comment _     -> C.Null
  I.RefCopy _ _ _ -> error $ "Unsupported Ivory statement: " ++ show a
  I.Forever _     -> error $ "Unsupported Ivory statement: " ++ show a
  I.Break         -> error $ "Unsupported Ivory statement: " ++ show a
  I.Assign  _ _ _ -> error $ "Unsupported Ivory statement: " ++ show a

cllInit :: I.Init -> C.Expr
cllInit a = case a of
  I.InitZero      -> Literal $ LitInteger 0
  I.InitExpr  _ b -> cllExpr b
  I.InitArray a   -> Array $ map cllInit a
  I.InitStruct a  -> Struct [ (n, cllInit v) | (n, v) <- a ]

cllExpr :: I.Expr -> C.Expr
cllExpr a = case a of
  I.ExpSym a -> Var a
  I.ExpVar a -> Var $ var a
  I.ExpLit a -> Literal $ lit a
  I.ExpOp op args -> Intrinsic (cllIntrinsic op) $ map cllExpr args
  I.ExpIndex _ a _ b -> ArrayIndex  (Deref $ cllExpr a) (cllExpr b)
  I.ExpLabel _ a b   -> StructIndex (Deref $ cllExpr a) b
  I.ExpToIx a _ -> cllExpr a   -- Is it ok to ignore the maximum bound?
  I.ExpSafeCast _ a -> cllExpr a
  _ -> Literal $ LitInteger 0
  --error $ "Unsupported Ivory expression: " ++ show a

cllIntrinsic :: ExpOp -> Intrinsic
cllIntrinsic op = case op of
  ExpEq   _        -> Eq
  ExpNeq  _        -> Neq
  ExpCond          -> Cond  
  ExpGt   False _  -> Gt
  ExpGt   True  _  -> Ge
  ExpLt   False _  -> Lt
  ExpLt   True  _  -> Le
  ExpNot           -> Not   
  ExpAnd           -> And   
  ExpOr            -> Or    
  ExpMul           -> Mul   
  ExpMod           -> Mod   
  ExpAdd           -> Add   
  ExpSub           -> Sub   
  ExpNegate        -> Negate
  ExpAbs           -> Abs   
  ExpSignum        -> Signum
  a                -> error $ "Unsupported Ivory intrinsic: " ++ show a

lit :: I.Literal -> Literal
lit a = case a of
  I.LitInteger a -> LitInteger a
  I.LitFloat   a -> LitFloat   a
  I.LitDouble  a -> LitDouble  a
  I.LitChar    a -> LitChar    a
  I.LitBool    a -> LitBool    a
  I.LitNull      -> LitNull     
  I.LitString  a -> LitString  a


class GetVar a where var :: a -> Var

instance GetVar I.Var where
  var a = case a of
    I.VarName     a -> a
    I.VarInternal a -> a
    I.VarLitName  a -> a

instance GetVar I.Name where
  var a = case a of
    I.NameSym a -> a
    I.NameVar a -> var a
