{-# LANGUAGE ViewPatterns, PatternGuards, FlexibleContexts #-}

{-
    Find and match:

    mapM, foldM, forM, replicateM, sequence, zipWithM
    not at the last line of a do statement, or to the left of >>

    Use let x = y instead of x <- return y, unless x is contained
    within y, or bound more than once in that do block.

<TEST>
yes = do mapM print a; return b -- mapM_ print a
yes = do _ <- mapM print a; return b -- mapM_ print a
no = mapM print a
no = do foo ; mapM print a
yes = do (bar+foo) -- (bar+foo)
no = do bar ; foo
yes = do bar; a <- foo; return a -- do bar; foo
no = do bar; a <- foo; return b
yes = do x <- bar; x -- do join bar
no = do x <- bar; x; x
yes = do x <- bar; return (f x) -- do f <$> bar
yes = do x <- bar; return $ f x -- do f <$> bar
yes = do x <- bar; pure $ f x -- do f <$> bar
yes = do x <- bar; return $ f (g x) -- do f . g <$> bar
yes = do x <- bar; return (f $ g x) -- do f . g <$> bar
yes = do x <- bar $ baz; return (f $ g x)
no = do x <- bar; return (f x x)
{-# LANGUAGE RecursiveDo #-}; no = mdo hook <- mkTrigger pat (act >> rmHook hook) ; return hook
yes = do x <- return y; foo x -- @Suggestion do let x = y; foo x
yes = do x <- return $ y + z; foo x -- do let x = y + z; foo x
no = do x <- return x; foo x
no = do x <- return y; x <- return y; foo x
yes = do forM files $ \x -> return (); return () -- forM_ files $ \x -> return ()
yes = do if a then forM x y else sequence z q; return () -- if a then forM_ x y else sequence_ z q
yes = do case a of {_ -> forM x y; x:xs -> forM x xs}; return () -- case a of _ -> forM_ x y ; x:xs -> forM_ x xs
foldM_ f a xs = foldM f a xs >> return ()
folder f a xs = foldM f a xs >> return () -- foldM_ f a xs
folder f a xs = foldM f a xs >>= \_ -> return () -- foldM_ f a xs
yes = mapM async ds >>= mapM wait >> return () -- mapM async ds >>= mapM_ wait
main = "wait" ~> do f a $ sleep 10
main = f $ do g a $ sleep 10 -- g a $ sleep 10
main = do f a $ sleep 10 -- f a $ sleep 10
main = do foo x; return 3; bar z -- do foo x; bar z
</TEST>
-}


module Hint.Monad(monadHint) where

import Control.Applicative
import Data.Tuple.Extra
import Data.Maybe
import Data.List
import Hint.Type
import Refact.Types
import qualified Refact.Types as R
import Prelude


badFuncs = ["mapM","foldM","forM","replicateM","sequence","zipWithM","traverse","for","sequenceA"]


monadHint :: DeclHint
monadHint _ _ d = concatMap (monadExp d) $ universeParentExp d

monadExp :: Decl_ -> (Maybe (Int, Exp_), Exp_) -> [Idea]
monadExp decl (parent, x) = case x of
        (view -> App2 op x1 x2) | op ~= ">>" -> f x1
        (view -> App2 op x1 (view -> LamConst1 _)) | op ~= ">>=" -> f x1
        Do an [Qualifier _ y] -> [warn "Redundant do" x y [Replace Expr (toSS x) [("y", toSS y)] "y"] | not $ doOperator parent y]
        Do an xs ->
            monadSteps (Do an) xs ++
            [suggest "Use let" x (Do an y) rs | Just (y, rs) <- [monadLet xs]] ++
            concat [f x | Qualifier _ x <- init xs] ++
            concat [f x | Generator _ (PWildCard _) x <- init xs]
        _ -> []
    where
        f x = [warn ("Use " ++ name) x y r  | Just (name,y, r) <- [monadNoResult x], fromNamed decl /= name]

-- Sometimes people write a * do a + b, to avoid brackets
doOperator (Just (1, InfixApp _ _ op _)) InfixApp{} | not $ isDol op = True
doOperator _ _ = False

middle :: (b -> d) -> (a, b, c) -> (a, d, c)
middle f (a,b,c) = (a, f b, c)


-- see through Paren and down if/case etc
-- return the name to use in the hint, and the revised expression
monadNoResult :: Exp_ -> Maybe (String,Exp_, [Refactoring R.SrcSpan])
monadNoResult (Paren l x) = middle (Paren l) <$> monadNoResult x
monadNoResult (App l x y) = middle (\x -> App l x y) <$> monadNoResult x
monadNoResult (InfixApp l x op y)
    | isDol op = middle (\x -> InfixApp l x op y) <$> monadNoResult x
    | op ~= ">>=" = middle (InfixApp l x op) <$> monadNoResult y
monadNoResult (replaceBranches -> (bs@(_:_), gen)) | all isJust res
    = Just ("Use simple functions", gen $ map (\(Just (a,b,c)) -> b) res, rs)
    where res = map monadNoResult bs
          rs  = concatMap (\(Just (a,b,c)) -> c) res
monadNoResult x | x2:_ <- filter (x ~=) badFuncs = let x3 = x2 ++ "_" in  Just (x3, toNamed x3, [Replace Expr (toSS x) [] x3])
monadNoResult _ = Nothing


monadStep :: ([Stmt S] -> Exp_) -> [Stmt S] -> [Idea]

-- do return x; $2 ==> do $2
monadStep wrap o@(Qualifier _ (fromRet -> Just _):x:xs) =
    [warn "Redundant return" (wrap o) (wrap $ x:xs) [Delete Stmt (toSS (head o))]]

-- do a <- $1; return a ==> do $1
monadStep wrap o@[g@(Generator _ (PVar _ p) x), q@(Qualifier _ (fromRet -> Just (Var _ v)))]
    | fromNamed v == fromNamed p
    = [warn "Redundant return" (wrap o) (wrap [Qualifier an x]) $
            [Replace Stmt (toSS g) [("x", toSS x)] "x", Delete Stmt (toSS q)]]

-- do x <- $1; x; $2  ==> do join $1; $2
monadStep wrap o@(g@(Generator _ (view -> PVar_ p) x):q@(Qualifier _ (view -> Var_ v)):xs)
    | p == v && v `notElem` varss xs
    = [warn "Use join" (wrap o) (wrap $ Qualifier an (rebracket1 $ App an (toNamed "join") x):xs) r]
    where r = [Replace Stmt (toSS g) [("x", toSS x)] "join x", Delete Stmt (toSS q)]

-- do x <- $1; return $ f $ g x ==> f . g <$> x
monadStep wrap
    o@[g@(Generator _ (view -> PVar_ u) x)
      ,q@(Qualifier _ (fromApplies -> (ret:f:fs, view -> Var_ v)))]
        | isReturn ret, notDol x, u == v, length fs < 3, all isSimple (f:fs), v `notElem` vars (f:fs)
        = [warn "Use <$>" (wrap o) (wrap [Qualifier an (InfixApp an (foldl' (flip (InfixApp an) (toNamed ".")) f fs) (toNamed "<$>") x)])
            [Replace Stmt (toSS g) (("x", toSS x):zip vs (toSS <$> f:fs)) (intercalate " . " (take (length fs + 1) vs) ++ " <$> x"), Delete Stmt (toSS q)]]
    where
        isSimple (fromApps -> xs) = all isAtom (x:xs)
        vs = ('f':) . show <$> [0..]
        notDol (InfixApp _ _ op _) = not $ isDol op
        notDol _ = True

monadStep _ _ = []

-- Suggest removing a return
monadSteps :: ([Stmt S] -> Exp_) -> [Stmt S] -> [Idea]
monadSteps wrap (x:xs) = monadStep wrap (x:xs) ++ monadSteps (wrap . (x :)) xs
monadSteps _ _ = []


-- | do ...; x <- return y; ... ==> do ...; let x = y; ...
monadLet :: [Stmt S] -> Maybe ([Stmt S], [Refactoring R.SrcSpan])
monadLet xs = if null rs then Nothing else Just (ys, rs)
    where
        (ys, catMaybes -> rs) = unzip $ map mkLet xs
        vs = concatMap pvars [p | Generator _ p _ <- xs]
        mkLet g@(Generator _ v@(view -> PVar_ p) (fromRet -> Just y))
            | p `notElem` vars y, p `notElem` delete p vs
            = (template (toNamed p) y, Just refact)
         where
            refact = Replace Stmt (toSS g) [("lhs", toSS v), ("rhs", toSS y)]
                      (prettyPrint $ template (toNamed "lhs") (toNamed "rhs"))
        mkLet x = (x, Nothing)
        template lhs rhs = LetStmt an $ BDecls an [PatBind an lhs (UnGuardedRhs an rhs) Nothing]


fromApplies :: Exp_ -> ([Exp_], Exp_)
fromApplies (App _ f x) = first (f:) $ fromApplies (fromParen x)
fromApplies (InfixApp _ f (isDol -> True) x) = first (f:) $ fromApplies x
fromApplies x = ([], x)


-- | Match @return x@ to @Just x@.
fromRet :: Exp_ -> Maybe Exp_
fromRet (Paren _ x) = fromRet x
fromRet (InfixApp _ x y z) | opExp y ~= "$" = fromRet $ App an x z
fromRet (App _ x y) | isReturn x = Just y
fromRet _ = Nothing
