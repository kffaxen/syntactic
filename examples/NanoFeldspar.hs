{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-missing-methods #-}

-- | A minimal Feldspar core language implementation. The intention of this module is to demonstrate
-- how to quickly make a language prototype using Syntactic.

module NanoFeldspar where



import Prelude hiding (max, min, not, (==), length, map, sum, zip, zipWith)
import qualified Prelude

import Data.Typeable

import Language.Syntactic hiding (fold, printExpr, showAST, drawAST, writeHtmlAST)
import qualified Language.Syntactic as Syntactic
import Language.Syntactic.Functional
import Language.Syntactic.Functional.Sharing
import Language.Syntactic.Functional.Tuple
import Language.Syntactic.Sugar.BindingT ()
import Language.Syntactic.Sugar.TupleT ()



--------------------------------------------------------------------------------
-- * Types
--------------------------------------------------------------------------------

-- | Convenient class alias
class    (Typeable a, Show a, Eq a, Ord a) => Type a
instance (Typeable a, Show a, Eq a, Ord a) => Type a

type Length = Int
type Index  = Int



--------------------------------------------------------------------------------
-- * Abstract syntax
--------------------------------------------------------------------------------

data Arithmetic sig
  where
    Add :: (Type a, Num a) => Arithmetic (a :-> a :-> Full a)
    Sub :: (Type a, Num a) => Arithmetic (a :-> a :-> Full a)
    Mul :: (Type a, Num a) => Arithmetic (a :-> a :-> Full a)

instance Symbol Arithmetic
  where
    symSig Add = signature
    symSig Sub = signature
    symSig Mul = signature

instance Render Arithmetic
  where
    renderSym Add = "(+)"
    renderSym Sub = "(-)"
    renderSym Mul = "(*)"
    renderArgs = renderArgsSmart

instance Equality   Arithmetic
instance StringTree Arithmetic

instance Eval Arithmetic
  where
    evalSym Add = (+)
    evalSym Sub = (-)
    evalSym Mul = (*)

instance EvalEnv Arithmetic env

data Parallel sig
  where
    Parallel :: Type a => Parallel (Length :-> (Index -> a) :-> Full [a])

instance Symbol Parallel
  where
    symSig Parallel = signature

instance Render Parallel
  where
    renderSym Parallel = "parallel"

instance Equality   Parallel
instance StringTree Parallel

instance Eval Parallel
  where
    evalSym Parallel = \len ixf -> Prelude.map ixf [0 .. len-1]

instance EvalEnv Parallel env

data ForLoop sig
  where
    ForLoop :: Type st => ForLoop (Length :-> st :-> (Index -> st -> st) :-> Full st)

instance Symbol ForLoop
  where
    symSig ForLoop = signature

instance Render ForLoop
  where
    renderSym ForLoop = "forLoop"

instance Equality   ForLoop
instance StringTree ForLoop

instance Eval ForLoop
  where
    evalSym ForLoop = \len init body -> foldl (flip body) init [0 .. len-1]

instance EvalEnv ForLoop env

type FeldDomain = Typed
    (   BindingT
    :+: Let
    :+: Tuple
    :+: Arithmetic
    :+: Parallel
    :+: ForLoop
    :+: Construct
    )
  -- `Construct` can be used to create arbitrary symbols from a name and an
  -- evaluation function. We could have used `Construct` for all symbols, but
  -- the problem with `Construct` is that it does not know about the arity or
  -- type of the construct it represents, so it's easy to make mistakes, e.g.
  -- when transforming expressions with `Construct` symbols.

newtype Data a = Data { unData :: ASTF FeldDomain a }

-- | Declaring 'Data' as syntactic sugar
instance Type a => Syntactic (Data a)
  where
    type Domain (Data a)   = FeldDomain
    type Internal (Data a) = a
    desugar = unData
    sugar   = Data

-- | Specialization of the 'Syntactic' class for the Feldspar domain
class    (Syntactic a, Domain a ~ FeldDomain, Type (Internal a)) => Syntax a
instance (Syntactic a, Domain a ~ FeldDomain, Type (Internal a)) => Syntax a

instance Type a => Show (Data a)
  where
    show = showExpr



--------------------------------------------------------------------------------
-- * "Backends"
--------------------------------------------------------------------------------

cmInterface :: CodeMotionInterface FeldDomain
cmInterface = defaultInterfaceT sharable (const True)
  where
    sharable :: ASTF FeldDomain a -> ASTF FeldDomain b -> Bool
    sharable (Sym _) _ = False
      -- Simple expressions not shared
    sharable (lam :$ _) _
        | Just _ <- prLam lam = False
      -- Lambdas not shared
    sharable _ (lam :$ _)
        | Just _ <- prLam lam = False
      -- Don't place let bindings over lambdas. This ensures that function
      -- arguments of higher-order constructs such as `Parallel` are always
      -- lambdas.
    sharable (sel :$ _) _
        | Just Sel1 <- prj sel = False
        | Just Sel2 <- prj sel = False
        | Just Sel3 <- prj sel = False
        | Just Sel4 <- prj sel = False
      -- Tuple selection not shared
    sharable (arrl :$ _ ) _
        | Just (Construct "arrLen" _) <- prj arrl = False
      -- Array length not shared
    sharable (gix :$ _ :$ _) _
        | Just (Construct "arrIx" _) <- prj gix = False
      -- Array indexing not shared
    sharable _ _ = True

-- | Show the expression
showExpr :: (Syntactic a, Domain a ~ FeldDomain) => a -> String
showExpr = render . codeMotion cmInterface . desugar

-- | Print the expression
printExpr :: (Syntactic a, Domain a ~ FeldDomain) => a -> IO ()
printExpr = putStrLn . showExpr

-- | Show the syntax tree using unicode art
showAST :: (Syntactic a, Domain a ~ FeldDomain) => a -> String
showAST = Syntactic.showAST . codeMotion cmInterface . desugar

-- | Draw the syntax tree on the terminal using unicode art
drawAST :: (Syntactic a, Domain a ~ FeldDomain) => a -> IO ()
drawAST = putStrLn . showAST

-- | Write the syntax tree to an HTML file with foldable nodes
writeHtmlAST :: (Syntactic a, Domain a ~ FeldDomain) => a -> IO ()
writeHtmlAST =
    Syntactic.writeHtmlAST "tree.html" . codeMotion cmInterface . desugar

-- | Evaluate an expression
eval :: (Syntactic a, Domain a ~ FeldDomain) => a -> Internal a
eval = evalClosed . desugar



--------------------------------------------------------------------------------
-- * Front end
--------------------------------------------------------------------------------

-- | Literal
value :: Syntax a => Internal a -> a
value a = sugar $ injT $ Construct (show a) a

false :: Data Bool
false = value False

true :: Data Bool
true = value True

-- | Force computation
force :: Syntax a => a -> a
force = resugar

instance (Type a, Num a) => Num (Data a)
  where
    fromInteger = value . fromInteger
    (+)         = sugarSymT Add
    (-)         = sugarSymT Sub
    (*)         = sugarSymT Mul

-- | Explicit sharing
share :: (Syntax a, Syntax b) => a -> (a -> b) -> b
share = sugarSymT Let

-- | Parallel array
parallel :: Type a => Data Length -> (Data Index -> Data a) -> Data [a]
parallel = sugarSymT Parallel

-- | For loop
forLoop :: Syntax st => Data Length -> st -> (Data Index -> st -> st) -> st
forLoop = sugarSymT ForLoop

-- | Conditional expression
(?) :: forall a . Syntax a => Data Bool -> (a,a) -> a
c ? (t,f) = sugarSymT sym c t f
  where
    sym :: Construct (Bool :-> Internal a :-> Internal a :-> Full (Internal a))
    sym = Construct "cond" (\c t f -> if c then t else f)

-- | Get the length of an array
arrLen :: Type a => Data [a] -> Data Length
arrLen = sugarSymT $ Construct "arrLen" Prelude.length

-- | Index into an array
arrIx :: Type a => Data [a] -> Data Index -> Data a
arrIx = sugarSymT $ Construct "arrIx" eval
  where
    eval as i
        | i >= len || i < 0 = error "arrIx: index out of bounds"
        | otherwise         = as !! i
      where
        len = Prelude.length as

not :: Data Bool -> Data Bool
not = sugarSymT $ Construct "not" Prelude.not

(==) :: Type a => Data a -> Data a -> Data Bool
(==) = sugarSymT $ Construct "(==)" (Prelude.==)

max :: Type a => Data a -> Data a -> Data a
max = sugarSymT $ Construct "max" Prelude.max

min :: Type a => Data a -> Data a -> Data a
min = sugarSymT $ Construct "min" Prelude.min



--------------------------------------------------------------------------------
-- * Vector library
--------------------------------------------------------------------------------

data Vector a
  where
    Indexed :: Data Length -> (Data Index -> a) -> Vector a

instance Syntax a => Syntactic (Vector a)
  where
    type Domain (Vector a)   = FeldDomain
    type Internal (Vector a) = [Internal a]
    desugar = desugar . freezeVector . map resugar
    sugar   = map resugar . thawVector . sugar

length :: Vector a -> Data Length
length (Indexed len _) = len

indexed :: Data Length -> (Data Index -> a) -> Vector a
indexed = Indexed

index :: Vector a -> Data Index -> a
index (Indexed _ ixf) = ixf

(!) :: Vector a -> Data Index -> a
Indexed _ ixf ! i = ixf i

infixl 9 !

freezeVector :: Type a => Vector (Data a) -> Data [a]
freezeVector vec = parallel (length vec) (index vec)

thawVector :: Type a => Data [a] -> Vector (Data a)
thawVector arr = Indexed (arrLen arr) (arrIx arr)

zip :: Vector a -> Vector b -> Vector (a,b)
zip a b = indexed (length a `min` length b) (\i -> (index a i, index b i))

unzip :: Vector (a,b) -> (Vector a, Vector b)
unzip ab = (indexed len (fst . index ab), indexed len (snd . index ab))
  where
    len = length ab

permute :: (Data Length -> Data Index -> Data Index) -> (Vector a -> Vector a)
permute perm vec = indexed len (index vec . perm len)
  where
    len = length vec

reverse :: Vector a -> Vector a
reverse = permute $ \len i -> len-i-1

(...) :: Data Index -> Data Index -> Vector (Data Index)
l ... h = indexed (h-l+1) (+l)

map :: (a -> b) -> Vector a -> Vector b
map f (Indexed len ixf) = Indexed len (f . ixf)

zipWith :: (a -> b -> c) -> Vector a -> Vector b -> Vector c
zipWith f a b = map (uncurry f) $ zip a b

fold :: Syntax b => (a -> b -> b) -> b -> Vector a -> b
fold f b (Indexed len ixf) = forLoop len b (\i st -> f (ixf i) st)

fold1 :: Syntax a => (a -> a -> a) -> Vector a -> a
fold1 f (Indexed len ixf) = forLoop len (ixf 0) (\i st -> f (ixf i) st)

sum :: (Num a, Syntax a) => Vector a -> a
sum = fold (+) 0

type Matrix a = Vector (Vector (Data a))

-- | Transpose of a matrix. Assumes that the number of rows is > 0.
transpose :: Type a => Matrix a -> Matrix a
transpose a = indexed (length (a!0)) $ \k -> indexed (length a) $ \l -> a ! l ! k



--------------------------------------------------------------------------------
-- * Examples
--------------------------------------------------------------------------------

-- | Fibonacci function
fib :: Data Int -> Data Int
fib n = fst $ forLoop n (0,1) $ \_ (a,b) -> (b,a+b)

-- | The span of a vector (difference between greatest and smallest element)
spanVec :: Vector (Data Int) -> Data Int
spanVec vec = hi-lo
  where
    (lo,hi) = fold (\a (l,h) -> (min a l, max a h)) (vec!0,vec!0) vec
  -- This demonstrates how tuples interplay with sharing. Tuples are essentially
  -- useless without sharing. This function would get two identical for loops if
  -- it wasn't for sharing.

-- | Scalar product
scProd :: Vector (Data Float) -> Vector (Data Float) -> Data Float
scProd a b = sum (zipWith (*) a b)

forEach = flip map

-- | Matrix multiplication
matMul :: Matrix Float -> Matrix Float -> Matrix Float
matMul a b = forEach a $ \a' ->
               forEach (transpose b) $ \b' ->
                 scProd a' b'

