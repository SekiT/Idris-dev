{-# LANGUAGE LambdaCase, PatternGuards, ViewPatterns #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
module Idris.ElabTerm where

import Idris.AbsSyntax
import Idris.AbsSyntaxTree
import Idris.DSL
import Idris.Delaborate
import Idris.Error
import Idris.ProofSearch
import Idris.Output (pshow)

import Idris.Core.CaseTree (SC, SC'(STerm))
import Idris.Core.Elaborate hiding (Tactic(..))
import Idris.Core.TT
import Idris.Core.Evaluate
import Idris.Core.Unify
import Idris.Core.Typecheck (check, recheck)
import Idris.ErrReverse (errReverse)
import Idris.ElabQuasiquote (extractUnquotes)
import Idris.Elab.Utils
import Idris.Reflection
import qualified Util.Pretty as U

import Control.Applicative ((<$>))
import Control.Monad
import Control.Monad.State.Strict
import Data.List
import qualified Data.Map as M
import Data.Maybe (mapMaybe, fromMaybe)
import qualified Data.Set as S
import qualified Data.Text as T

import Debug.Trace

data ElabMode = ETyDecl | ELHS | ERHS
  deriving Eq


data ElabResult =
  ElabResult { resultTerm :: Term -- ^ The term resulting from elaboration
             , resultMetavars :: [(Name, (Int, Maybe Name, Type))]
               -- ^ Information about new metavariables
             , resultCaseDecls :: [PDecl]
               -- ^ Deferred declarations as the meaning of case blocks
             , resultContext :: Context
               -- ^ The potentially extended context from new definitions
             , resultTyDecls :: [RDeclInstructions]
               -- ^ Meta-info about the new type declarations
             }

processTacticDecls :: [RDeclInstructions] -> Idris ()
processTacticDecls info =
  forM_ info $ \case
    RTyDeclInstrs n fc impls ty ->
      do logLvl 3 $ "Declaration from tactics: " ++ show n ++ " : " ++ show ty
         logLvl 3 $ "  It has impls " ++ show impls
         updateIState $ \i -> i { idris_implicits =
                                    addDef n impls (idris_implicits i) }
         addIBC (IBCImp n)
         ds <- checkDef fc (\_ e -> e) [(n, (-1, Nothing, ty))]
         addIBC (IBCDef n)
         let ds' = map (\(n, (i, top, t)) -> (n, (i, top, t, True))) ds
         addDeferred ds'

-- Using the elaborator, convert a term in raw syntax to a fully
-- elaborated, typechecked term.
--
-- If building a pattern match, we convert undeclared variables from
-- holes to pattern bindings.

-- Also find deferred names in the term and their types

build :: IState -> ElabInfo -> ElabMode -> FnOpts -> Name -> PTerm ->
         ElabD ElabResult
build ist info emode opts fn tm
    = do elab ist info emode opts fn tm
         let tmIn = tm
         let inf = case lookupCtxt fn (idris_tyinfodata ist) of
                        [TIPartial] -> True
                        _ -> False

         when (not pattern) $ solveAutos ist fn True

         hs <- get_holes
         ivs <- get_instances
         ptm <- get_term
         -- Resolve remaining type classes. Two passes - first to get the
         -- default Num instances, second to clean up the rest
         when (not pattern) $
              mapM_ (\n -> when (n `elem` hs) $
                             do focus n
                                g <- goal
                                try (resolveTC True False 7 g fn ist)
                                    (movelast n)) ivs
         ivs <- get_instances
         hs <- get_holes
         when (not pattern) $
              mapM_ (\n -> when (n `elem` hs) $
                             do focus n
                                g <- goal
                                ptm <- get_term
                                resolveTC True True 7 g fn ist) ivs
         tm <- get_term
         ctxt <- get_context
         probs <- get_probs
         u <- getUnifyLog
         hs <- get_holes

         when (not pattern) $
           traceWhen u ("Remaining holes:\n" ++ show hs ++ "\n" ++
                        "Remaining problems:\n" ++ qshow probs) $
             do unify_all; matchProblems True; unifyProblems

         probs <- get_probs
         case probs of
            [] -> return ()
            ((_,_,_,_,e,_,_):es) -> traceWhen u ("Final problems:\n" ++ show probs) $
                                     if inf then return ()
                                            else lift (Error e)

         when tydecl (do mkPat
                         update_term liftPats
                         update_term orderPats)
         EState is _ impls <- getAux
         tt <- get_term
         let (tm, ds) = runState (collectDeferred (Just fn) tt) []
         log <- getLog
         ctxt <- get_context
         if (log /= "") then trace log $ return (ElabResult tm ds is ctxt impls)
            else return (ElabResult tm ds is ctxt impls)
  where pattern = emode == ELHS
        tydecl = emode == ETyDecl

        mkPat = do hs <- get_holes
                   tm <- get_term
                   case hs of
                      (h: hs) -> do patvar h; mkPat
                      [] -> return ()

-- Build a term autogenerated as a typeclass method definition
-- (Separate, so we don't go overboard resolving things that we don't
-- know about yet on the LHS of a pattern def)

buildTC :: IState -> ElabInfo -> ElabMode -> FnOpts -> Name -> PTerm ->
         ElabD ElabResult
buildTC ist info emode opts fn tm
    = do -- set name supply to begin after highest index in tm
         let ns = allNamesIn tm
         let tmIn = tm
         let inf = case lookupCtxt fn (idris_tyinfodata ist) of
                        [TIPartial] -> True
                        _ -> False
         initNextNameFrom ns
         elab ist info emode opts fn tm
         probs <- get_probs
         tm <- get_term
         case probs of
            [] -> return ()
            ((_,_,_,_,e,_,_):es) -> if inf then return ()
                                           else lift (Error e)
         dots <- get_dotterm
         -- 'dots' are the PHidden things which have not been solved by
         -- unification
         when (not (null dots)) $
            lift (Error (CantMatch (getInferTerm tm)))
         EState is _ impls <- getAux
         tt <- get_term
         let (tm, ds) = runState (collectDeferred (Just fn) tt) []
         log <- getLog
         ctxt <- get_context
         if (log /= "") then trace log $ return (ElabResult tm ds is ctxt impls)
            else return (ElabResult tm ds is ctxt impls)
  where pattern = emode == ELHS

-- return whether arguments of the given constructor name can be 
-- matched on. If they're polymorphic, no, unless the type has beed made
-- concrete by the time we get around to elaborating the argument.
getUnmatchable :: Context -> Name -> [Bool]
getUnmatchable ctxt n | isDConName n ctxt && n /= inferCon
   = case lookupTyExact n ctxt of
          Nothing -> []
          Just ty -> checkArgs [] [] ty
  where checkArgs :: [Name] -> [[Name]] -> Type -> [Bool]
        checkArgs env ns (Bind n (Pi _ t _) sc) 
            = let env' = case t of
                              TType _ -> n : env
                              _ -> env in
                  checkArgs env' (intersect env (refsIn t) : ns) 
                            (instantiate (P Bound n t) sc)
        checkArgs env ns t
            = map (not . null) (reverse ns)

getUnmatchable ctxt n = []

data ElabCtxt = ElabCtxt { e_inarg :: Bool,
                           e_isfn :: Bool, -- ^ Function part of application
                           e_guarded :: Bool, 
                           e_intype :: Bool,
                           e_qq :: Bool,
                           e_nomatching :: Bool -- ^ can't pattern match
                         }

initElabCtxt = ElabCtxt False False False False False False

goal_polymorphic :: ElabD Bool
goal_polymorphic =
   do ty <- goal
      case ty of
           P _ n _ -> do env <- get_env
                         case lookup n env of
                              Nothing -> return False
                              _ -> return True
           _ -> return False

-- | Returns the set of declarations we need to add to complete the
-- definition (most likely case blocks to elaborate) as well as
-- declarations resulting from user tactic scripts (%runTactics)
elab :: IState -> ElabInfo -> ElabMode -> FnOpts -> Name -> PTerm ->
        ElabD ()
elab ist info emode opts fn tm
    = do let loglvl = opt_logLevel (idris_options ist)
         when (loglvl > 5) $ unifyLog True
         compute -- expand type synonyms, etc
         let fc = maybe "(unknown)"
         elabE initElabCtxt (elabFC info) tm -- (in argument, guarded, in type, in qquote)
         est <- getAux
         sequence_ (delayed_elab est)
         end_unify
         ptm <- get_term
         when pattern -- convert remaining holes to pattern vars
              (do update_term orderPats
                  unify_all
                  matchProblems False -- only the ones we matched earlier
                  unifyProblems
                  mkPat)
  where
    pattern = emode == ELHS
    bindfree = emode == ETyDecl || emode == ELHS

    tcgen = Dictionary `elem` opts
    reflection = Reflection `elem` opts

    isph arg = case getTm arg of
        Placeholder -> (True, priority arg)
        tm -> (False, priority arg)

    toElab ina arg = case getTm arg of
        Placeholder -> Nothing
        v -> Just (priority arg, elabE ina (elabFC info) v)

    toElab' ina arg = case getTm arg of
        Placeholder -> Nothing
        v -> Just (elabE ina (elabFC info) v)

    mkPat = do hs <- get_holes
               tm <- get_term
               case hs of
                  (h: hs) -> do patvar h; mkPat
                  [] -> return ()

    -- | elabE elaborates an expression, possibly wrapping implicit coercions
    -- and forces/delays.  If you make a recursive call in elab', it is
    -- normally correct to call elabE - the ones that don't are desugarings
    -- typically
    elabE :: ElabCtxt -> Maybe FC -> PTerm -> ElabD ()
    elabE ina fc' t =
     --do g <- goal
        --trace ("Elaborating " ++ show t ++ " : " ++ show g) $
     do solved <- get_recents
        as <- get_autos
        -- If any of the autos use variables which have recently been solved,
        -- have another go at solving them now.
        mapM_ (\(a, ns) -> if any (\n -> n `elem` solved) ns
                              then solveAuto ist fn False a
                              else return ()) as
     
        itm <- if not pattern then insertImpLam ina t else return t
        ct <- insertCoerce ina itm
        t' <- insertLazy ct
        g <- goal
        tm <- get_term
        ps <- get_probs
        hs <- get_holes

        --trace ("Elaborating " ++ show t' ++ " in " ++ show g
        --         ++ "\n" ++ show tm
        --         ++ "\nholes " ++ show hs
        --         ++ "\nproblems " ++ show ps
        --         ++ "\n-----------\n") $
        --trace ("ELAB " ++ show t') $
        let fc = fileFC "Force"
        env <- get_env
        handleError (forceErr t' env)
            (elab' ina fc' t')
            (elab' ina fc' (PApp fc (PRef fc (sUN "Force"))
                             [pimp (sUN "t") Placeholder True,
                              pimp (sUN "a") Placeholder True,
                              pexp ct])) True

    forceErr orig env (CantUnify _ (t,_) (t',_) _ _ _)
       | (P _ (UN ht) _, _) <- unApply (normalise (tt_ctxt ist) env t),
            ht == txt "Lazy'" = notDelay orig
    forceErr orig env (CantUnify _ (t,_) (t',_) _ _ _)
       | (P _ (UN ht) _, _) <- unApply (normalise (tt_ctxt ist) env t'),
            ht == txt "Lazy'" = notDelay orig
    forceErr orig env (InfiniteUnify _ t _)
       | (P _ (UN ht) _, _) <- unApply (normalise (tt_ctxt ist) env t),
            ht == txt "Lazy'" = notDelay orig
    forceErr orig env (Elaborating _ _ t) = forceErr orig env t
    forceErr orig env (ElaboratingArg _ _ _ t) = forceErr orig env t
    forceErr orig env (At _ t) = forceErr orig env t
    forceErr orig env t = False

    notDelay t@(PApp _ (PRef _ (UN l)) _) | l == txt "Delay" = False
    notDelay _ = True

    local f = do e <- get_env
                 return (f `elem` map fst e)

    -- | Is a constant a type?
    constType :: Const -> Bool
    constType (AType _) = True
    constType StrType = True
    constType VoidType = True
    constType _ = False

    -- "guarded" means immediately under a constructor, to help find patvars

    elab' :: ElabCtxt  -- ^ (in an argument, guarded, in a type, in a quasiquote)
          -> Maybe FC -- ^ The closest FC in the syntax tree, if applicable
          -> PTerm -- ^ The term to elaborate
          -> ElabD ()
    elab' ina fc (PNoImplicits t) = elab' ina fc t -- skip elabE step
    elab' ina fc PType           = do apply RType []; solve
    elab' ina fc (PUniverse u)   = do apply (RUType u) []; solve
--  elab' (_,_,inty) (PConstant c)
--     | constType c && pattern && not reflection && not inty
--       = lift $ tfail (Msg "Typecase is not allowed")
    elab' ina fc tm@(PConstant c) 
         | pattern && not reflection && not (e_qq ina) && not (e_intype ina)
           && isTypeConst c
              = lift $ tfail $ Msg ("No explicit types on left hand side: " ++ show tm)
         | pattern && not reflection && not (e_qq ina) && e_nomatching ina
              = lift $ tfail $ Msg ("Attempting concrete match on polymorphic argument: " ++ show tm)
         | otherwise = do apply (RConstant c) []; solve
    elab' ina fc (PQuote r)     = do fill r; solve
    elab' ina _ (PTrue fc _)   =
       do hnf_compute
          g <- goal
          case g of
            TType _ -> elab' ina (Just fc) (PRef fc unitTy)
            UType _ -> elab' ina (Just fc) (PRef fc unitTy)
            _ -> elab' ina (Just fc) (PRef fc unitCon)
    elab' ina fc (PResolveTC (FC "HACK" _ _)) -- for chasing parent classes
       = do g <- goal; resolveTC False False 5 g fn ist
    elab' ina fc (PResolveTC fc')
        = do c <- getNameFrom (sMN 0 "class")
             instanceArg c
    elab' ina _ (PRefl fc t)
        = elab' ina (Just fc) (PApp fc (PRef fc eqCon) [pimp (sMN 0 "A") Placeholder True,
                                                   pimp (sMN 0 "x") t False])
    elab' ina _ (PEq fc Placeholder Placeholder l r)
       = try (do tyn <- getNameFrom (sMN 0 "aqty")
                 claim tyn RType
                 movelast tyn
                 elab' ina (Just fc) (PApp fc (PRef fc eqTy)
                              [pimp (sUN "A") (PRef fc tyn) True,
                               pimp (sUN "B") (PRef fc tyn) False,
                               pexp l, pexp r]))
             (do atyn <- getNameFrom (sMN 0 "aqty")
                 btyn <- getNameFrom (sMN 0 "bqty")
                 claim atyn RType
                 movelast atyn
                 claim btyn RType
                 movelast btyn
                 elab' ina (Just fc) (PApp fc (PRef fc eqTy)
                   [pimp (sUN "A") (PRef fc atyn) True,
                    pimp (sUN "B") (PRef fc btyn) False,
                    pexp l, pexp r]))

    elab' ina _ (PEq fc lt rt l r) = elab' ina (Just fc) (PApp fc (PRef fc eqTy)
                                       [pimp (sUN "A") lt True,
                                        pimp (sUN "B") rt False,
                                        pexp l, pexp r])
    elab' ina _ (PPair fc _ l r)
        = do hnf_compute
             g <- goal
             let (tc, _) = unApply g
             case g of
                TType _ -> elab' ina (Just fc) (PApp fc (PRef fc pairTy)
                                                      [pexp l,pexp r])
                UType _ -> elab' ina (Just fc) (PApp fc (PRef fc upairTy)
                                                      [pexp l,pexp r])
                _ -> case tc of
                        P _ n _ | n == upairTy 
                          -> elab' ina (Just fc) (PApp fc (PRef fc upairCon)
                                                [pimp (sUN "A") Placeholder False,
                                                 pimp (sUN "B") Placeholder False,
                                                 pexp l, pexp r])
                        _ -> elab' ina (Just fc) (PApp fc (PRef fc pairCon)
                                                [pimp (sUN "A") Placeholder False,
                                                 pimp (sUN "B") Placeholder False,
                                                 pexp l, pexp r])
--                         _ -> try' (elab' ina (Just fc) (PApp fc (PRef fc pairCon)
--                                                 [pimp (sUN "A") Placeholder False,
--                                                  pimp (sUN "B") Placeholder False,
--                                                  pexp l, pexp r]))
--                                   (elab' ina (Just fc) (PApp fc (PRef fc upairCon)
--                                                 [pimp (sUN "A") Placeholder False,
--                                                  pimp (sUN "B") Placeholder False,
--                                                  pexp l, pexp r]))
--                                   True

    elab' ina _ (PDPair fc p l@(PRef _ n) t r)
            = case t of
                Placeholder ->
                   do hnf_compute
                      g <- goal
                      case g of
                         TType _ -> asType
                         _ -> asValue
                _ -> asType
         where asType = elab' ina (Just fc) (PApp fc (PRef fc sigmaTy)
                                        [pexp t,
                                         pexp (PLam fc n Placeholder r)])
               asValue = elab' ina (Just fc) (PApp fc (PRef fc existsCon)
                                         [pimp (sMN 0 "a") t False,
                                          pimp (sMN 0 "P") Placeholder True,
                                          pexp l, pexp r])
    elab' ina _ (PDPair fc p l t r) = elab' ina (Just fc) (PApp fc (PRef fc existsCon)
                                              [pimp (sMN 0 "a") t False,
                                               pimp (sMN 0 "P") Placeholder True,
                                               pexp l, pexp r])
    elab' ina fc (PAlternative True as)
        = do hnf_compute
             ty <- goal
             ctxt <- get_context
             let (tc, _) = unApply ty
             env <- get_env
             let as' = pruneByType (map fst env) tc ctxt as
--              trace (-- show tc ++ " " ++ show as ++ "\n ==> " ++ 
--                     show (length as') ++ "\n" ++
--                     showSep ", " (map showTmImpls as') ++ "\nEND") $
             tryAll (zip (map (elab' ina fc) as') (map showHd as'))
        where showHd (PApp _ (PRef _ n) _) = n
              showHd (PRef _ n) = n
              showHd (PApp _ h _) = showHd h
              showHd x = NErased -- We probably should do something better than this here
    elab' ina fc (PAlternative False as)
        = trySeq as
        where -- if none work, take the error from the first
              trySeq (x : xs) = let e1 = elab' ina fc x in
                                    try' e1 (trySeq' e1 xs) True
              trySeq [] = fail "Nothing to try in sequence"
              trySeq' deferr [] = proofFail deferr
              trySeq' deferr (x : xs)
                  = try' (do elab' ina fc x
                             solveAutos ist fn False) (trySeq' deferr xs) True
    elab' ina _ (PPatvar fc n) | bindfree = do patvar n; update_term liftPats
--    elab' (_, _, inty) (PRef fc f)
--       | isTConName f (tt_ctxt ist) && pattern && not reflection && not inty
--          = lift $ tfail (Msg "Typecase is not allowed")
    elab' ec _ tm@(PRef fc n)
      | pattern && not reflection && not (e_qq ec) && not (e_intype ec)
            && isTConName n (tt_ctxt ist)
              = lift $ tfail $ Msg ("No explicit types on left hand side: " ++ show tm)
      | pattern && not reflection && not (e_qq ec) && e_nomatching ec
              = lift $ tfail $ Msg ("Attempting concrete match on polymorphic argument: " ++ show tm)
      | (pattern || (bindfree && bindable n)) && not (inparamBlock n) && not (e_qq ec)
        = do let ina = e_inarg ec
                 guarded = e_guarded ec
                 inty = e_intype ec
             ctxt <- get_context
             let defined = case lookupTy n ctxt of
                               [] -> False
                               _ -> True
           -- this is to stop us resolve type classes recursively
             -- trace (show (n, guarded)) $
             if (tcname n && ina) then erun fc $ do patvar n; update_term liftPats
               else if (defined && not guarded)
                       then do apply (Var n) []; solve
                       else try (do apply (Var n) []; solve)
                                (do patvar n; update_term liftPats)
      where inparamBlock n = case lookupCtxtName n (inblock info) of
                                [] -> False
                                _ -> True
            bindable (NS _ _) = False
            bindable (UN xs) = True
            bindable n = implicitable n
    elab' ina _ f@(PInferRef fc n) = elab' ina (Just fc) (PApp fc f [])
    elab' ina fc' tm@(PRef fc n) 
          | pattern && not reflection && not (e_qq ina) && not (e_intype ina)
            && isTConName n (tt_ctxt ist)
              = lift $ tfail $ Msg ("No explicit types on left hand side: " ++ show tm)
          | pattern && not reflection && not (e_qq ina) && e_nomatching ina
              = lift $ tfail $ Msg ("Attempting concrete match on polymorphic argument: " ++ show tm)
          | otherwise = 
               do fty <- get_type (Var n) -- check for implicits
                  ctxt <- get_context
                  env <- get_env 
                  let a' = insertScopedImps fc (normalise ctxt env fty) []
                  if null a'
                     then erun fc $ do apply (Var n) []; solve
                     else elab' ina fc' (PApp fc tm [])
    elab' ina _ (PLam _ _ _ PImpossible) = lift . tfail . Msg $ "Only pattern-matching lambdas can be impossible"
    elab' ina _ (PLam fc n Placeholder sc)
          = do -- if n is a type constructor name, this makes no sense...
               ctxt <- get_context
               when (isTConName n ctxt) $
                    lift $ tfail (Msg $ "Can't use type constructor " ++ show n ++ " here")
               checkPiGoal n
               attack; intro (Just n);
               -- trace ("------ intro " ++ show n ++ " ---- \n" ++ show ptm)
               elabE (ina { e_inarg = True } ) (Just fc) sc; solve
    elab' ec _ (PLam fc n ty sc)
          = do tyn <- getNameFrom (sMN 0 "lamty")
               -- if n is a type constructor name, this makes no sense...
               ctxt <- get_context
               when (isTConName n ctxt) $
                    lift $ tfail (Msg $ "Can't use type constructor " ++ show n ++ " here")
               checkPiGoal n
               claim tyn RType
               explicit tyn
               attack
               ptm <- get_term
               hs <- get_holes
               introTy (Var tyn) (Just n)
               focus tyn
               
               elabE (ec { e_inarg = True, e_intype = True }) (Just fc) ty
               elabE (ec { e_inarg = True }) (Just fc) sc
               solve
    elab' ina fc (PPi p n Placeholder sc)
          = do attack; arg n (is_scoped p) (sMN 0 "ty") 
               elabE (ina { e_inarg = True, e_intype = True }) fc sc
               solve
    elab' ina fc (PPi p n ty sc)
          = do attack; tyn <- getNameFrom (sMN 0 "ty")
               claim tyn RType
               n' <- case n of
                        MN _ _ -> unique_hole n
                        _ -> return n
               forall n' (is_scoped p) (Var tyn)
               focus tyn
               let ec' = ina { e_inarg = True, e_intype = True }
               elabE ec' fc ty
               elabE ec' fc sc
               solve
    elab' ina _ (PLet fc n ty val sc)
          = do attack
               ivs <- get_instances
               tyn <- getNameFrom (sMN 0 "letty")
               claim tyn RType
               valn <- getNameFrom (sMN 0 "letval")
               claim valn (Var tyn)
               explicit valn
               letbind n (Var tyn) (Var valn)
               case ty of
                   Placeholder -> return ()
                   _ -> do focus tyn
                           explicit tyn
                           elabE (ina { e_inarg = True, e_intype = True }) 
                                 (Just fc) ty
               focus valn
               elabE (ina { e_inarg = True, e_intype = True }) 
                     (Just fc) val
               ivs' <- get_instances
               env <- get_env
               elabE (ina { e_inarg = True }) (Just fc) sc
               when (not pattern) $
                   mapM_ (\n -> do focus n
                                   g <- goal
                                   hs <- get_holes
                                   if all (\n -> n == tyn || not (n `elem` hs)) (freeNames g)
                                    then try (resolveTC True False 7 g fn ist)
                                             (movelast n)
                                    else movelast n)
                         (ivs' \\ ivs)
               -- HACK: If the name leaks into its type, it may leak out of
               -- scope outside, so substitute in the outer scope.
               expandLet n (case lookup n env of
                                 Just (Let t v) -> v
                                 other -> error ("Value not a let binding: " ++ show other))
               solve
    elab' ina _ (PGoal fc r n sc) = do
         rty <- goal
         attack
         tyn <- getNameFrom (sMN 0 "letty")
         claim tyn RType
         valn <- getNameFrom (sMN 0 "letval")
         claim valn (Var tyn)
         letbind n (Var tyn) (Var valn)
         focus valn
         elabE (ina { e_inarg = True, e_intype = True }) (Just fc) (PApp fc r [pexp (delab ist rty)])
         env <- get_env
         computeLet n
         elabE (ina { e_inarg = True }) (Just fc) sc
         solve
--          elab' ina fc (PLet n Placeholder
--              (PApp fc r [pexp (delab ist rty)]) sc)
    elab' ina _ tm@(PApp fc (PInferRef _ f) args) = do
         rty <- goal
         ds <- get_deferred
         ctxt <- get_context
         -- make a function type a -> b -> c -> ... -> rty for the
         -- new function name
         env <- get_env
         argTys <- claimArgTys env args
         fn <- getNameFrom (sMN 0 "inf_fn")
         let fty = fnTy argTys rty
--             trace (show (ptm, map fst argTys)) $ focus fn
            -- build and defer the function application
         attack; deferType (mkN f) fty (map fst argTys); solve
         -- elaborate the arguments, to unify their types. They all have to
         -- be explicit.
         mapM_ elabIArg (zip argTys args)
       where claimArgTys env [] = return []
             claimArgTys env (arg : xs) | Just n <- localVar env (getTm arg)
                                  = do nty <- get_type (Var n)
                                       ans <- claimArgTys env xs
                                       return ((n, (False, forget nty)) : ans)
             claimArgTys env (_ : xs)
                                  = do an <- getNameFrom (sMN 0 "inf_argTy")
                                       aval <- getNameFrom (sMN 0 "inf_arg")
                                       claim an RType
                                       claim aval (Var an)
                                       ans <- claimArgTys env xs
                                       return ((aval, (True, (Var an))) : ans)
             fnTy [] ret  = forget ret
             fnTy ((x, (_, xt)) : xs) ret = RBind x (Pi Nothing xt RType) (fnTy xs ret)

             localVar env (PRef _ x)
                           = case lookup x env of
                                  Just _ -> Just x
                                  _ -> Nothing
             localVar env _ = Nothing

             elabIArg ((n, (True, ty)), def) =
               do focus n; elabE ina (Just fc) (getTm def)
             elabIArg _ = return () -- already done, just a name

             mkN n@(NS _ _) = n
             mkN n@(SN _) = n
             mkN n = case namespace info of
                        Just xs@(_:_) -> sNS n xs
                        _ -> n

    elab' ina _ (PMatchApp fc fn)
       = do (fn', imps) <- case lookupCtxtName fn (idris_implicits ist) of
                             [(n, args)] -> return (n, map (const True) args)
                             _ -> lift $ tfail (NoSuchVariable fn)
            ns <- match_apply (Var fn') (map (\x -> (x,0)) imps)
            solve
    -- if f is local, just do a simple_app
    -- FIXME: Anyone feel like refactoring this mess? - EB
    elab' ina topfc tm@(PApp fc (PRef _ f) args_in)
      | pattern && not reflection && not (e_qq ina) && e_nomatching ina
              = lift $ tfail $ Msg ("Attempting concrete match on polymorphic argument: " ++ show tm)
      | otherwise = implicitApp $
         do env <- get_env
            ty <- goal
            fty <- get_type (Var f)
            ctxt <- get_context
            let args = insertScopedImps fc (normalise ctxt env fty) args_in
            let unmatchableArgs = if pattern 
                                     then getUnmatchable (tt_ctxt ist) f
                                     else []
--             trace ("BEFORE " ++ show f ++ ": " ++ show ty) $ 
            when (pattern && not reflection && not (e_qq ina) && not (e_intype ina)
                          && isTConName f (tt_ctxt ist)) $
              lift $ tfail $ Msg ("No explicit types on left hand side: " ++ show tm)
            if (f `elem` map fst env && length args == 1 && length args_in == 1)
               then -- simple app, as below
                    do simple_app False 
                                  (elabE (ina { e_isfn = True }) (Just fc) (PRef fc f))
                                  (elabE (ina { e_inarg = True }) (Just fc) (getTm (head args)))
                                  (show tm)
                       solve
                       return []
               else
                 do ivs <- get_instances
                    ps <- get_probs
                    -- HACK: we shouldn't resolve type classes if we're defining an instance
                    -- function or default definition.
                    let isinf = f == inferCon || tcname f
                    -- if f is a type class, we need to know its arguments so that
                    -- we can unify with them
                    case lookupCtxt f (idris_classes ist) of
                        [] -> return ()
                        _ -> do mapM_ setInjective (map getTm args)
                                -- maybe more things are solvable now
                                unifyProblems
                    let guarded = isConName f ctxt
--                    trace ("args is " ++ show args) $ return ()
                    ns <- apply (Var f) (map isph args)
--                    trace ("ns is " ++ show ns) $ return ()
                    -- mark any type class arguments as injective
                    mapM_ checkIfInjective (map snd ns)
                    unifyProblems -- try again with the new information,
                                  -- to help with disambiguation
                    -- Sort so that the implicit tactics and alternatives go last
                    let (ns', eargs) = unzip $
                             sortBy cmpArg (zip ns args)
                    ulog <- getUnifyLog
                    elabArgs ist (ina { e_inarg = e_inarg ina || not isinf }) 
                           [] fc False f 
                             (zip ns' (unmatchableArgs ++ repeat False))
                             (f == sUN "Force")
                             (map (\x -> getTm x) eargs) -- TODO: remove this False arg
                    imp <- if (e_isfn ina) then
                              do guess <- get_guess
                                 gty <- get_type (forget guess)
                                 env <- get_env
                                 let ty_n = normalise ctxt env gty
                                 return $ getReqImps ty_n
                              else return []
                    -- Now we find out how many implicits we needed at the
                    -- end of the application by looking at the goal again
                    -- - Have another go, but this time add the
                    -- implicits (can't think of a better way than this...)
                    case imp of
                         rs@(_:_) | not pattern -> return rs -- quit, try again
                         _ -> do solve
                                 hs <- get_holes
                                 ivs' <- get_instances
                                 -- Attempt to resolve any type classes which have 'complete' types,
                                 -- i.e. no holes in them
                                 when (not pattern || (e_inarg ina && not tcgen && 
                                                      not (e_guarded ina))) $
                                    mapM_ (\n -> do focus n
                                                    g <- goal
                                                    env <- get_env
                                                    hs <- get_holes
                                                    if all (\n -> not (n `elem` hs)) (freeNames g)
                                                     then try (resolveTC False False 7 g fn ist)
                                                              (movelast n)
                                                     else movelast n)
                                          (ivs' \\ ivs)
                                 return []
      where 
            -- Run the elaborator, which returns how many implicit
            -- args were needed, then run it again with those args. We need
            -- this because we have to elaborate the whole application to
            -- find out whether any computations have caused more implicits
            -- to be needed.
            implicitApp :: ElabD [ImplicitInfo] -> ElabD ()
            implicitApp elab 
              | pattern = do elab; return ()
              | otherwise
                = do s <- get
                     imps <- elab
                     case imps of
                          [] -> return ()
                          es -> do put s
                                   elab' ina topfc (PAppImpl tm es)
    
            getReqImps (Bind x (Pi (Just i) ty _) sc)
                 = i : getReqImps sc
            getReqImps _ = []

            -- normal < alternatives < lambdas < rewrites < tactic < default tactic
            -- reason for lambdas after alternatives is that having
            -- the alternative resolved can help with typechecking the lambda
            -- or the rewrite. Rewrites/tactics need as much information
            -- as possible about the type.
            -- FIXME: Better would be to allow alternative resolution to be
            -- retried after more information is in.
            cmpArg (_, x) (_, y)
                | constraint x && not (constraint y) = LT
                | constraint y && not (constraint x) = GT
                | otherwise
                   = compare (conDepth 0 (getTm x) + priority x + alt x)
                             (conDepth 0 (getTm y) + priority y + alt y)
                where alt t = case getTm t of
                                   PAlternative False _ -> 5
                                   PAlternative True _ -> 2
                                   PTactics _ -> 150
                                   PLam _ _ _ _ -> 3
                                   PRewrite _ _ _ _ -> 4
                                   PResolveTC _ -> 0
                                   PHidden _ -> 150
                                   _ -> 1

            constraint (PConstraint _ _ _ _) = True
            constraint _ = False

            -- Score a point for every level where there is a non-constructor
            -- function (so higher score --> done later), and lots of points
            -- if there is a PHidden since this should be unifiable.
            -- Only relevant when on lhs
            conDepth d t | not pattern = 0
            conDepth d (PRef _ f) | isConName f (tt_ctxt ist) = 0
                                  | otherwise = max (100 - d) 1
            conDepth d (PApp _ f as)
               = conDepth d f + sum (map (conDepth (d+1)) (map getTm as))
            conDepth d (PPatvar _ _) = 0
            conDepth d (PAlternative _ as) = maximum (map (conDepth d) as)
            conDepth d (PHidden _) = 150
            conDepth d Placeholder = 0
            conDepth d (PResolveTC _) = 0
            conDepth d t = max (100 - d) 1

            checkIfInjective n = do
                env <- get_env
                case lookup n env of
                     Nothing -> return ()
                     Just b ->
                       case unApply (binderTy b) of
                            (P _ c _, args) ->
                                case lookupCtxtExact c (idris_classes ist) of
                                   Nothing -> return ()
                                   Just ci -> -- type class, set as injective
                                        do mapM_ setinjArg (getDets 0 (class_determiners ci) args)
                                        -- maybe we can solve more things now...
                                           ulog <- getUnifyLog
                                           probs <- get_probs
                                           traceWhen ulog ("Injective now " ++ show args ++ "\n" ++ qshow probs) $
                                             unifyProblems
                                           probs <- get_probs
                                           traceWhen ulog (qshow probs) $ return ()
                            _ -> return ()

            setinjArg (P _ n _) = setinj n
            setinjArg _ = return ()

            getDets i ds [] = []
            getDets i ds (a : as) | i `elem` ds = a : getDets (i + 1) ds as
                                  | otherwise = getDets (i + 1) ds as

            tacTm (PTactics _) = True
            tacTm (PProof _) = True
            tacTm _ = False

            setInjective (PRef _ n) = setinj n
            setInjective (PApp _ (PRef _ n) _) = setinj n
            setInjective _ = return ()

    elab' ina _ tm@(PApp fc f [arg]) = 
            erun fc $
             do simple_app (not $ headRef f)
                           (elabE (ina { e_isfn = True }) (Just fc) f) 
                           (elabE (ina { e_inarg = True }) (Just fc) (getTm arg))
                                (show tm)
                solve
        where headRef (PRef _ _) = True
              headRef (PApp _ f _) = headRef f
              headRef _ = False

    elab' ina fc (PAppImpl f es) = do appImpl (reverse es) -- not that we look... 
                                      solve
        where appImpl [] = elab' (ina { e_isfn = False }) fc f -- e_isfn not set, so no recursive expansion of implicits
              appImpl (e : es) = simple_app False
                                            (appImpl es)
                                            (elab' ina fc Placeholder)
                                            (show f)
    elab' ina fc Placeholder 
        = do (h : hs) <- get_holes
             movelast h
    elab' ina fc (PMetavar n) =
          do ptm <- get_term
             -- When building the metavar application, leave out the unique
             -- names which have been used elsewhere in the term, since we
             -- won't be able to use them in the resulting application.
             let unique_used = getUniqueUsed (tt_ctxt ist) ptm
             let n' = mkN n
             attack
             defer unique_used n'
             solve
        where mkN n@(NS _ _) = n
              mkN n = case namespace info of
                        Just xs@(_:_) -> sNS n xs
                        _ -> n
    elab' ina fc (PProof ts) = do compute; mapM_ (runTac True ist (elabFC info) fn) ts
    elab' ina fc (PTactics ts)
        | not pattern = do mapM_ (runTac False ist fc fn) ts
        | otherwise = elab' ina fc Placeholder
    elab' ina fc (PElabError e) = lift $ tfail e
    elab' ina _ (PRewrite fc r sc newg)
        = do attack
             tyn <- getNameFrom (sMN 0 "rty")
             claim tyn RType
             valn <- getNameFrom (sMN 0 "rval")
             claim valn (Var tyn)
             letn <- getNameFrom (sMN 0 "_rewrite_rule")
             letbind letn (Var tyn) (Var valn)
             focus valn
             elab' ina (Just fc) r
             compute
             g <- goal
             rewrite (Var letn)
             g' <- goal
             when (g == g') $ lift $ tfail (NoRewriting g)
             case newg of
                 Nothing -> elab' ina (Just fc) sc
                 Just t -> doEquiv t sc
             solve
        where doEquiv t sc =
                do attack
                   tyn <- getNameFrom (sMN 0 "ety")
                   claim tyn RType
                   valn <- getNameFrom (sMN 0 "eqval")
                   claim valn (Var tyn)
                   letn <- getNameFrom (sMN 0 "equiv_val")
                   letbind letn (Var tyn) (Var valn)
                   focus tyn
                   elab' ina (Just fc) t
                   focus valn
                   elab' ina (Just fc) sc
                   elab' ina (Just fc) (PRef fc letn)
                   solve
    elab' ina _ c@(PCase fc scr opts)
        = do attack
             tyn <- getNameFrom (sMN 0 "scty")
             claim tyn RType
             valn <- getNameFrom (sMN 0 "scval")
             scvn <- getNameFrom (sMN 0 "scvar")
             claim valn (Var tyn)
             letbind scvn (Var tyn) (Var valn)
             focus valn
             elabE (ina { e_inarg = True }) (Just fc) scr
             -- Solve any remaining implicits - we need to solve as many
             -- as possible before making the 'case' type
             unifyProblems
             matchProblems True
             args <- get_env
             envU <- mapM (getKind args) args
             let namesUsedInRHS = nub $ scvn : concatMap (\(_,rhs) -> allNamesIn rhs) opts

             -- Drop the unique arguments used in the term already
             -- and in the scrutinee (since it's
             -- not valid to use them again anyway) 
             --
             -- Also drop unique arguments which don't appear explicitly
             -- in either case branch so they don't count as used
             -- unnecessarily (can only do this for unique things, since we
             -- assume they don't appear implicitly in types)
             ptm <- get_term
             let inOpts = (filter (/= scvn) (map fst args)) \\ (concatMap (\x -> allNamesIn (snd x)) opts)

             let argsDropped = filter (isUnique envU) 
                                   (nub $ allNamesIn scr ++ inApp ptm ++
                                    inOpts)

             let args' = filter (\(n, _) -> n `notElem` argsDropped) args

             cname <- unique_hole' True (mkCaseName fn)
             let cname' = mkN cname
--              elab' ina fc (PMetavar cname')
             attack; defer argsDropped cname'; solve

             -- if the scrutinee is one of the 'args' in env, we should
             -- inspect it directly, rather than adding it as a new argument
             let newdef = PClauses fc [] cname'
                             (caseBlock fc cname'
                                (map (isScr scr) (reverse args')) opts)
             -- elaborate case
             updateAux (\e -> e { case_decls = newdef : case_decls e } )
             -- if we haven't got the type yet, hopefully we'll get it later!
             movelast tyn
             solve
        where mkCaseName (NS n ns) = NS (mkCaseName n) ns
              mkCaseName n = SN (CaseN n)
--               mkCaseName (UN x) = UN (x ++ "_case")
--               mkCaseName (MN i x) = MN i (x ++ "_case")
              mkN n@(NS _ _) = n
              mkN n = case namespace info of
                        Just xs@(_:_) -> sNS n xs
                        _ -> n

              inApp (P _ n _) = [n]
              inApp (App f a) = inApp f ++ inApp a
              inApp (Bind n (Let _ v) sc) = inApp v ++ inApp sc
              inApp (Bind n (Guess _ v) sc) = inApp v ++ inApp sc
              inApp (Bind n b sc) = inApp sc
              inApp _ = []

              isUnique envk n = case lookup n envk of
                                     Just u -> u
                                     _ -> False

              getKind env (n, _)
                  = case lookup n env of
                         Nothing -> return (n, False) -- can't happen, actually...
                         Just b ->
                            do ty <- get_type (forget (binderTy b))
                               case ty of
                                    UType UniqueType -> return (n, True)
                                    UType AllTypes -> return (n, True)
                                    _ -> return (n, False)

              tcName tm | (P _ n _, _) <- unApply tm
                  = case lookupCtxt n (idris_classes ist) of
                         [_] -> True
                         _ -> False
              tcName _ = False

              usedIn ns (n, b)
                 = n `elem` ns
                     || any (\x -> x `elem` ns) (allTTNames (binderTy b))

    elab' ina fc (PUnifyLog t) = do unifyLog True
                                    elab' ina fc t
                                    unifyLog False
    elab' ina fc (PQuasiquote t goalt)
        = do -- First extract the unquoted subterms, replacing them with fresh
             -- names in the quasiquoted term. Claim their reflections to be
             -- an inferred type (to support polytypic quasiquotes).
             finalTy <- goal
             (t, unq) <- extractUnquotes 0 t
             let unquoteNames = map fst unq
             mapM_ (\uqn -> claim uqn (forget finalTy)) unquoteNames

             -- Save the old state - we need a fresh proof state to avoid
             -- capturing lexically available variables in the quoted term.
             ctxt <- get_context
             saveState
             updatePS (const .
                       newProof (sMN 0 "q") ctxt $
                       P Ref (reflm "TT") Erased)

             -- Re-add the unquotes, letting Idris infer the (fictional)
             -- types. Here, they represent the real type rather than the type
             -- of their reflection.
             mapM_ (\n -> do ty <- getNameFrom (sMN 0 "unqTy")
                             claim ty RType
                             movelast ty
                             claim n (Var ty)
                             movelast n)
                   unquoteNames

             -- Determine whether there's an explicit goal type, and act accordingly
             -- Establish holes for the type and value of the term to be
             -- quasiquoted
             qTy <- getNameFrom (sMN 0 "qquoteTy")
             claim qTy RType
             movelast qTy
             qTm <- getNameFrom (sMN 0 "qquoteTm")
             claim qTm (Var qTy)

             -- Let-bind the result of elaborating the contained term, so that
             -- the hole doesn't disappear
             nTm <- getNameFrom (sMN 0 "quotedTerm")
             letbind nTm (Var qTy) (Var qTm)

             -- Fill out the goal type, if relevant
             case goalt of
               Nothing  -> return ()
               Just gTy -> do focus qTy
                              elabE (ina { e_qq = True }) fc gTy

             -- Elaborate the quasiquoted term into the hole
             focus qTm
             elabE (ina { e_qq = True }) fc t
             end_unify

             -- We now have an elaborated term. Reflect it and solve the
             -- original goal in the original proof state.
             env <- get_env
             loadState
             let quoted = fmap (explicitNames . binderVal) $ lookup nTm env
                 isRaw = case unApply (normaliseAll ctxt env finalTy) of
                           (P _ n _, []) | n == reflm "Raw" -> True
                           _ -> False
             case quoted of
               Just q -> do ctxt <- get_context
                            (q', _, _) <- lift $ recheck ctxt [(uq, Lam Erased) | uq <- unquoteNames] (forget q) q
                            if pattern
                              then if isRaw
                                      then reflectRawQuotePattern unquoteNames (forget q')
                                      else reflectTTQuotePattern unquoteNames q'
                              else do if isRaw
                                        then -- we forget q' instead of using q to ensure rechecking
                                             fill $ reflectRawQuote unquoteNames (forget q')
                                        else fill $ reflectTTQuote unquoteNames q'
                                      solve

               Nothing -> lift . tfail . Msg $ "Broken elaboration of quasiquote"

             -- Finally fill in the terms or patterns from the unquotes. This
             -- happens last so that their holes still exist while elaborating
             -- the main quotation.
             mapM_ elabUnquote unq
      where elabUnquote (n, tm)
                = do focus n
                     elabE (ina { e_qq = False }) fc tm


    elab' ina fc (PUnquote t) = fail "Found unquote outside of quasiquote"
    elab' ina fc (PAs _ n t) = lift . tfail . Msg $ "@-pattern not allowed here"
    elab' ina fc (PHidden t) 
      | reflection = elab' ina fc t
      | otherwise
        = do (h : hs) <- get_holes
             -- Dotting a hole means that either the hole or any outer
             -- hole (a hole outside any occurrence of it) 
             -- must be solvable by unification as well as being filled
             -- in directly.
             -- Delay dotted things to the end, then when we elaborate them
             -- we can check the result against what was inferred
             movelast h
             delayElab $ do focus h
                            dotterm
                            elab' ina fc t
    elab' ina fc (PRunTactics fc' tm) =
      do attack
         n <- getNameFrom (sMN 0 "tacticScript")
         n' <- getNameFrom (sMN 0 "tacticExpr")
         let scriptTy = RApp (Var (sNS (sUN "Tactical") ["Tactical", "Reflection", "Language"])) (Var unitTy)
         claim n scriptTy
         movelast n
         letbind n' scriptTy (Var n)
         focus n
         elab' ina (Just fc') tm
         env <- get_env
         runTactical (maybe fc' id fc) env (P Bound n' Erased)
         EState _ _ todo <- getAux
         solve
    elab' ina fc x = fail $ "Unelaboratable syntactic form " ++ showTmImpls x

    delayElab t = updateAux (\e -> e { delayed_elab = delayed_elab e ++ [t] }) 

    isScr :: PTerm -> (Name, Binder Term) -> (Name, (Bool, Binder Term))
    isScr (PRef _ n) (n', b) = (n', (n == n', b))
    isScr _ (n', b) = (n', (False, b))

    caseBlock :: FC -> Name ->
                 [(Name, (Bool, Binder Term))] -> [(PTerm, PTerm)] -> [PClause]
    caseBlock fc n env opts
        = let args' = findScr env
              args = map mkarg (map getNmScr args') in
              map (mkClause args) opts

       where -- Find the variable we want as the scrutinee and mark it as
             -- 'True'. If the scrutinee is in the environment, match on that
             -- otherwise match on the new argument we're adding.
             findScr ((n, (True, t)) : xs)
                        = (n, (True, t)) : scrName n xs
             findScr [(n, (_, t))] = [(n, (True, t))]
             findScr (x : xs) = x : findScr xs
             -- [] can't happen since scrutinee is in the environment!
             findScr [] = error "The impossible happened - the scrutinee was not in the environment"

             -- To make sure top level pattern name remains in scope, put
             -- it at the end of the environment
             scrName n []  = []
             scrName n [(_, t)] = [(n, t)]
             scrName n (x : xs) = x : scrName n xs

             getNmScr (n, (s, _)) = (n, s)

             mkarg (n, s) = (PRef fc n, s)
             -- may be shadowed names in the new pattern - so replace the
             -- old ones with an _
             mkClause args (l, r)
                   = let args' = map (shadowed (allNamesIn l)) args
                         lhs = PApp (getFC fc l) (PRef (getFC fc l) n)
                                 (map (mkLHSarg l) args') in
                            PClause (getFC fc l) n lhs [] r []

             mkLHSarg l (tm, True) = pexp l
             mkLHSarg l (tm, False) = pexp tm

             shadowed new (PRef _ n, s) | n `elem` new = (Placeholder, s)
             shadowed new t = t

    getFC d (PApp fc _ _) = fc
    getFC d (PRef fc _) = fc
    getFC d (PAlternative _ (x:_)) = getFC d x
    getFC d x = d

    insertLazy :: PTerm -> ElabD PTerm
    insertLazy t@(PApp _ (PRef _ (UN l)) _) | l == txt "Delay" = return t
    insertLazy t@(PApp _ (PRef _ (UN l)) _) | l == txt "Force" = return t
    insertLazy (PCoerced t) = return t
    insertLazy t =
        do ty <- goal
           env <- get_env
           let (tyh, _) = unApply (normalise (tt_ctxt ist) env ty)
           let tries = if pattern then [t, mkDelay env t] else [mkDelay env t, t]
           case tyh of
                P _ (UN l) _ | l == txt "Lazy'"
                    -> return (PAlternative False tries)
                _ -> return t
      where
        mkDelay env (PAlternative b xs) = PAlternative b (map (mkDelay env) xs)
        mkDelay env t
            = let fc = fileFC "Delay" in
                  addImplBound ist (map fst env) (PApp fc (PRef fc (sUN "Delay"))
                                                 [pexp t])


    -- Don't put implicit coercions around applications which are marked
    -- as '%noImplicit', or around case blocks, otherwise we get exponential
    -- blowup especially where there are errors deep in large expressions.
    notImplicitable (PApp _ f _) = notImplicitable f
    -- TMP HACK no coercing on bind (make this configurable)
    notImplicitable (PRef _ n)
        | [opts] <- lookupCtxt n (idris_flags ist)
            = NoImplicit `elem` opts
    notImplicitable (PAlternative True as) = any notImplicitable as
    -- case is tricky enough without implicit coercions! If they are needed,
    -- they can go in the branches separately.
    notImplicitable (PCase _ _ _) = True
    notImplicitable _ = False

    insertScopedImps fc (Bind n (Pi im@(Just i) _ _) sc) xs
      | tcinstance i
          = pimp n (PResolveTC fc) True : insertScopedImps fc sc xs
      | otherwise
          = pimp n Placeholder True : insertScopedImps fc sc xs
    insertScopedImps fc (Bind n (Pi _ _ _) sc) (x : xs)
        = x : insertScopedImps fc sc xs
    insertScopedImps _ _ xs = xs

    insertImpLam ina t =
        do ty <- goal
           env <- get_env
           let ty' = normalise (tt_ctxt ist) env ty
           addLam ty' t
      where
        -- just one level at a time
        addLam (Bind n (Pi (Just _) _ _) sc) t =
                 do impn <- unique_hole (sMN 0 "imp")
                    if e_isfn ina -- apply to an implicit immediately
                       then return (PApp emptyFC
                                         (PLam emptyFC impn Placeholder t)
                                         [pexp Placeholder])
                       else return (PLam emptyFC impn Placeholder t)
        addLam _ t = return t

    insertCoerce ina t@(PCase _ _ _) = return t
    insertCoerce ina t | notImplicitable t = return t
    insertCoerce ina t =
        do ty <- goal
           -- Check for possible coercions to get to the goal
           -- and add them as 'alternatives'
           env <- get_env
           let ty' = normalise (tt_ctxt ist) env ty
           let cs = getCoercionsTo ist ty'
           let t' = case (t, cs) of
                         (PCoerced tm, _) -> tm
                         (_, []) -> t
                         (_, cs) -> PAlternative False [t ,
                                       PAlternative True (map (mkCoerce env t) cs)]
           return t'
       where
         mkCoerce env t n = let fc = maybe (fileFC "Coercion") id (highestFC t) in
                                addImplBound ist (map fst env)
                                  (PApp fc (PRef fc n) [pexp (PCoerced t)])

    -- | Elaborate the arguments to a function
    elabArgs :: IState -- ^ The current Idris state
             -> ElabCtxt -- ^ (in an argument, guarded, in a type, in a qquote)
             -> [Bool]
             -> FC -- ^ Source location
             -> Bool
             -> Name -- ^ Name of the function being applied
             -> [((Name, Name), Bool)] -- ^ (Argument Name, Hole Name, unmatchable)
             -> Bool -- ^ under a 'force'
             -> [PTerm] -- ^ argument
             -> ElabD ()
    elabArgs ist ina failed fc retry f [] force _ = return ()
    elabArgs ist ina failed fc r f (((argName, holeName), unm):ns) force (t : args)
        = do hs <- get_holes
             if holeName `elem` hs then 
                do focus holeName
                   case t of
                      Placeholder -> do movelast holeName
                                        elabArgs ist ina failed fc r f ns force args
                      _ -> elabArg t
                else elabArgs ist ina failed fc r f ns force args
      where elabArg t =
              do -- solveAutos ist fn False
                 now_elaborating fc f argName
                 wrapErr f argName $ do
                   hs <- get_holes
                   tm <- get_term
                   -- No coercing under an explicit Force (or it can Force/Delay
                   -- recursively!)
                   let elab = if force then elab' else elabE
                   failed' <- -- trace (show (n, t, hs, tm)) $
                              -- traceWhen (not (null cs)) (show ty ++ "\n" ++ showImp True t) $
                              do focus holeName;
                                 g <- goal
                                 -- Can't pattern match on polymorphic goals
                                 poly <- goal_polymorphic
                                 ulog <- getUnifyLog
                                 traceWhen ulog ("Elaborating argument " ++ show (argName, holeName, g)) $
                                  elab (ina { e_nomatching = unm && poly }) (Just fc) t
                                 return failed
                   done_elaborating_arg f argName
                   elabArgs ist ina failed fc r f ns force args
            wrapErr f argName action =
              do elabState <- get
                 while <- elaborating_app
                 let while' = map (\(x, y, z)-> (y, z)) while
                 (result, newState) <- case runStateT action elabState of
                                         OK (res, newState) -> return (res, newState)
                                         Error e -> do done_elaborating_arg f argName
                                                       lift (tfail (elaboratingArgErr while' e))
                 put newState
                 return result
    elabArgs _ _ _ _ _ _ (((arg, hole), _) : _) _ [] =
      fail $ "Can't elaborate these args: " ++ show arg ++ " " ++ show hole

-- For every alternative, look at the function at the head. Automatically resolve
-- any nested alternatives where that function is also at the head

pruneAlt :: [PTerm] -> [PTerm]
pruneAlt xs = map prune xs
  where
    prune (PApp fc1 (PRef fc2 f) as)
        = PApp fc1 (PRef fc2 f) (fmap (fmap (choose f)) as)
    prune t = t

    choose f (PAlternative a as)
        = let as' = fmap (choose f) as
              fs = filter (headIs f) as' in
              case fs of
                 [a] -> a
                 _ -> PAlternative a as'

    choose f (PApp fc f' as) = PApp fc (choose f f') (fmap (fmap (choose f)) as)
    choose f t = t

    headIs f (PApp _ (PRef _ f') _) = f == f'
    headIs f (PApp _ f' _) = headIs f f'
    headIs f _ = True -- keep if it's not an application

-- Rule out alternatives that don't return the same type as the head of the goal
-- (If there are none left as a result, do nothing)
pruneByType :: [Name] -> Term -> -- head of the goal
               Context -> [PTerm] -> [PTerm]
-- if an alternative has a locally bound name at the head, take it
pruneByType env t c as
   | Just a <- locallyBound as = [a]
  where
    locallyBound [] = Nothing
    locallyBound (t:ts)
       | Just n <- getName t,
         n `elem` env = Just t
       | otherwise = locallyBound ts
    getName (PRef _ n) = Just n
    getName (PApp _ f _) = getName f
    getName (PHidden t) = getName t
    getName _ = Nothing

pruneByType env (P _ n _) ctxt as
-- if the goal type is polymorphic, keep e
   | [] <- lookupTy n ctxt = as
   | otherwise
       = let asV = filter (headIs True n) as
             as' = filter (headIs False n) as in
             case as' of
               [] -> case asV of
                        [] -> as
                        _ -> asV
               _ -> as'
  where
    headIs var f (PApp _ (PRef _ f') _) = typeHead var f f'
    headIs var f (PApp _ f' _) = headIs var f f'
    headIs var f (PPi _ _ _ sc) = headIs var f sc
    headIs var f (PHidden t) = headIs var f t
    headIs _ _ _ = True -- keep if it's not an application

    typeHead var f f'
        = -- trace ("Trying " ++ show f' ++ " for " ++ show n) $
          case lookupTy f' ctxt of
               [ty] -> case unApply (getRetTy ty) of
                            (P _ ctyn _, _) | isConName ctyn ctxt -> ctyn == f
                            _ -> let ty' = normalise ctxt [] ty in
                                     case unApply (getRetTy ty') of
                                          (P _ ftyn _, _) -> ftyn == f
                                          (V _, _) -> var -- keep, variable
                                          _ -> False
               _ -> False

pruneByType _ t _ as = as

findInstances :: IState -> Term -> [Name]
findInstances ist t
    | (P _ n _, _) <- unApply t
        = case lookupCtxt n (idris_classes ist) of
            [CI _ _ _ _ _ ins _] -> filter accessible ins
            _ -> []
    | otherwise = []
  where accessible n = case lookupDefAccExact n False (tt_ctxt ist) of
                            Just (_, Hidden) -> False
                            _ -> True

-- Try again to solve auto implicits
solveAuto :: IState -> Name -> Bool -> Name -> ElabD ()
solveAuto ist fn ambigok n
           = do hs <- get_holes
                when (n `elem` hs) $ do
                  focus n
                  g <- goal
                  isg <- is_guess -- if it's a guess, we're working on it recursively, so stop
                  when (not isg) $
                    proofSearch' ist True ambigok 100 True Nothing fn []

solveAutos :: IState -> Name -> Bool -> ElabD ()
solveAutos ist fn ambigok
           = do autos <- get_autos
                mapM_ (solveAuto ist fn ambigok) (map fst autos)

trivial' ist
    = trivial (elab ist toplevel ERHS [] (sMN 0 "tac")) ist
proofSearch' ist rec ambigok depth prv top n hints
    = do unifyProblems
         proofSearch rec prv ambigok (not prv) depth
                     (elab ist toplevel ERHS [] (sMN 0 "tac")) top n hints ist

-- Resolve type classes. This will only pick up 'normal' instances, never
-- named instances (hence using 'tcname' to check it's a generated instance
-- name).
resolveTC :: Bool -- using default Int
             -> Bool -- allow metavariables in the goal 
             -> Int -- depth
             -> Term -- top level goal
             -> Name -- top level function name
             -> IState -> ElabD ()
resolveTC def mvok depth top fn ist
   = do hs <- get_holes
        resTC' [] def hs depth top fn ist

resTC' tcs def topholes 0 topg fn ist = fail $ "Can't resolve type class"
resTC' tcs def topholes 1 topg fn ist = try' (trivial' ist) (resolveTC def False 0 topg fn ist) True
resTC' tcs defaultOn topholes depth topg fn ist
  = do compute
       g <- goal
       let argsok = tcArgsOK g topholes
--        trace (show (g,hs,argsok,topholes)) $ 
       if not argsok -- && not mvok)
         then lift $ tfail $ CantResolve True topg
         else do
           ptm <- get_term
           ulog <- getUnifyLog
           hs <- get_holes
           traceWhen ulog ("Resolving class " ++ show g) $
            try' (trivial' ist)
                (do t <- goal
                    let (tc, ttypes) = unApply t
                    scopeOnly <- needsDefault t tc ttypes
                    let stk = elab_stack ist
                    let insts_in = findInstances ist t
                    let insts = if scopeOnly then filter chaser insts_in
                                    else insts_in
                    tm <- get_term
                    let depth' = if scopeOnly then 2 else depth
                    blunderbuss t depth' stk (stk ++ insts)) True
  where
    tcArgsOK ty hs | (P _ nc _, as) <- unApply ty, nc == numclass && defaultOn
       = True
    tcArgsOK ty hs -- if any arguments are metavariables, postpone
       = let (f, as) = unApply ty in
             case f of
                  P _ cn _ -> case lookupCtxtExact cn (idris_classes ist) of
                                   Just ci -> tcDetArgsOK 0 (class_determiners ci) hs as
                                   Nothing -> not $ any (isMeta hs) as
                  _ -> not $ any (isMeta hs) as

    tcDetArgsOK i ds hs (x : xs)
        | i `elem` ds = not (isMeta hs x) && tcDetArgsOK (i + 1) ds hs xs
        | otherwise = tcDetArgsOK (i + 1) ds hs xs
    tcDetArgsOK _ _ _ [] = True

    isMeta :: [Name] -> Term -> Bool
    isMeta ns (P _ n _) = n `elem` ns 
    isMeta _ _ = False

    notHole hs (P _ n _, c)
       | (P _ cn _, _) <- unApply c,
         n `elem` hs && isConName cn (tt_ctxt ist) = False
       | Constant _ <- c = not (n `elem` hs)
    notHole _ _ = True

    elabTC n | n /= fn && tcname n = (resolve n depth, show n)
             | otherwise = (fail "Can't resolve", show n)

    -- HACK! Rather than giving a special name, better to have some kind
    -- of flag in ClassInfo structure
    chaser (UN nm)
        | ('@':'@':_) <- str nm = True -- old way
    chaser (SN (ParentN _ _)) = True
    chaser (NS n _) = chaser n
    chaser _ = False

    numclass = sNS (sUN "Num") ["Classes","Prelude"]

    needsDefault t num@(P _ nc _) [P Bound a _] | nc == numclass && defaultOn
        = do focus a
             fill (RConstant (AType (ATInt ITBig))) -- default Integer
             solve
             return False
    needsDefault t f as
          | all boundVar as = return True -- fail $ "Can't resolve " ++ show t
    needsDefault t f a = return False -- trace (show t) $ return ()

    boundVar (P Bound _ _) = True
    boundVar _ = False

    blunderbuss t d stk [] = do -- c <- get_env
                            -- ps <- get_probs
                            lift $ tfail $ CantResolve False topg
    blunderbuss t d stk (n:ns)
        | n /= fn && (n `elem` stk || tcname n) 
              = tryCatch (resolve n d) 
                    (\e -> case e of
                             CantResolve True _ -> lift $ tfail e
                             _ -> blunderbuss t d stk ns) 
        | otherwise = blunderbuss t d stk ns

    resolve n depth
       | depth == 0 = fail $ "Can't resolve type class"
       | otherwise
           = do t <- goal
                let (tc, ttypes) = unApply t
--                 if (all boundVar ttypes) then resolveTC (depth - 1) fn insts ist
--                   else do
                   -- if there's a hole in the goal, don't even try
                let imps = case lookupCtxtName n (idris_implicits ist) of
                                [] -> []
                                [args] -> map isImp (snd args) -- won't be overloaded!
                                xs -> error "The impossible happened - overloading is not expected here!"
                ps <- get_probs
                tm <- get_term
                args <- map snd <$> try' (apply (Var n) imps)
                                         (match_apply (Var n) imps) True
                ps' <- get_probs
                when (length ps < length ps' || unrecoverable ps') $
                     fail "Can't apply type class"
--                 traceWhen (all boundVar ttypes) ("Progress: " ++ show t ++ " with " ++ show n) $
                mapM_ (\ (_,n) -> do focus n
                                     t' <- goal
                                     let (tc', ttype) = unApply t'
                                     let got = fst (unApply t)
                                     let depth' = if tc' `elem` tcs
                                                     then depth - 1 else depth
                                     resTC' (got : tcs) defaultOn topholes depth' topg fn ist)
                      (filter (\ (x, y) -> not x) (zip (map fst imps) args))
                -- if there's any arguments left, we've failed to resolve
                hs <- get_holes
                ulog <- getUnifyLog
                solve
                traceWhen ulog ("Got " ++ show n) $ return ()
       where isImp (PImp p _ _ _ _) = (True, p)
             isImp arg = (False, priority arg)

collectDeferred :: Maybe Name ->
                   Term -> State [(Name, (Int, Maybe Name, Type))] Term
collectDeferred top (Bind n (GHole i t) app) =
    do ds <- get
       t' <- collectDeferred top t
       when (not (n `elem` map fst ds)) $ put (ds ++ [(n, (i, top, t'))])
       collectDeferred top app
collectDeferred top (Bind n b t) = do b' <- cdb b
                                      t' <- collectDeferred top t
                                      return (Bind n b' t')
  where
    cdb (Let t v)   = liftM2 Let (collectDeferred top t) (collectDeferred top v)
    cdb (Guess t v) = liftM2 Guess (collectDeferred top t) (collectDeferred top v)
    cdb b           = do ty' <- collectDeferred top (binderTy b)
                         return (b { binderTy = ty' })
collectDeferred top (App f a) = liftM2 App (collectDeferred top f) (collectDeferred top a)
collectDeferred top t = return t

case_ :: Bool -> Bool -> IState -> Name -> PTerm -> ElabD ()
case_ ind autoSolve ist fn tm = do
  attack
  tyn <- getNameFrom (sMN 0 "ity")
  claim tyn RType
  valn <- getNameFrom (sMN 0 "ival")
  claim valn (Var tyn)
  letn <- getNameFrom (sMN 0 "irule")
  letbind letn (Var tyn) (Var valn)
  focus valn
  elab ist toplevel ERHS [] (sMN 0 "tac") tm
  env <- get_env
  let (Just binding) = lookup letn env
  let val = binderVal binding
  if ind then induction (forget val)
         else casetac (forget val)
  when autoSolve solveAll

tacN :: String -> Name
tacN str = sNS (sUN str) ["Tactical", "Reflection", "Language"]

runTactical :: FC -> Env -> Term -> ElabD ()
runTactical fc env tm = do tm' <- eval tm
                           runTacTm tm'
                           return ()
  where
    eval tm = do ctxt <- get_context
                 return $ normaliseAll ctxt env (finalise tm)

    returnUnit = fmap fst $ get_type_val (Var unitCon)

    defineFunction :: RFunDefn -> ElabD ()
    defineFunction (RDefineFun n clauses) =
      do ctxt <- get_context
         ty <- maybe (fail "no type decl") return $ lookupTyExact n ctxt
         let info = CaseInfo True True False -- TODO document and figure out
         clauses' <- forM clauses (\(RMkFunClause lhs rhs) ->
                                    do lhs' <- lift $ check ctxt [] lhs
                                       rhs' <- lift $ check ctxt [] rhs
                                       return (fst lhs', fst rhs'))
         trace (show clauses') $ return ()
         set_context $
           addCasedef n (const [])
                      info False (STerm Erased)
                      True False -- TODO what are these?
                      [] [] -- TODO argument types, inaccessible types
                      (map Right clauses')
                      (map (\(l,r) -> ([], l, r)) clauses')
                      (map (\(l,r) -> ([], l, r)) clauses')
                      (map (\(l,r) -> ([], l, r)) clauses')
                      (map (\(l,r) -> ([], l, r)) clauses')
                      ty
                      ctxt
         return ()

    -- | Do a step in the reflected elaborator monad. The input is the
    -- step, the output is the (reflected) term returned.
    runTacTm :: Term -> ElabD Term
    runTacTm (unApply -> tac@(P _ n _, args))
      | n == tacN "prim__Solve", [] <- args
      = do solve
           returnUnit
      | n == tacN "prim__Goal", [] <- args
      = do (h:_) <- get_holes
           t <- goal
           fmap fst . get_type_val $
             rawPair (Var (reflm "TTName"), Var (reflm "TT"))
                     (reflectName h,        reflect t)
      | n == tacN "prim__Holes", [] <- args
      = do hs <- get_holes
           fmap fst . get_type_val $
             mkList (Var $ reflm "TTName") (map reflectName hs)
      | n == tacN "prim__Guess", [] <- args
      = do ok <- is_guess
           if ok
              then do guess <- fmap forget get_guess
                      fmap fst . get_type_val $
                        RApp (RApp (Var (sNS (sUN "Just") ["Maybe", "Prelude"]))
                                   (Var (reflm "TT")))
                             guess
              else fmap fst . get_type_val $
                     RApp (Var (sNS (sUN "Nothing") ["Maybe", "Prelude"]))
                          (Var (reflm "TT"))
      | n == tacN "prim__SourceLocation", [] <- args
      = fmap fst . get_type_val $
          reflectFC fc
      | n == tacN "prim__Env", [] <- args
      = do env <- get_env
           fmap fst . get_type_val $ reflectEnv env
      | n == tacN "prim__Fail", [_a, errs] <- args
      = do errs' <- eval errs
           parts <- reifyReportParts errs'
           lift . tfail $ ReflectionError [parts] (Msg "")
      | n == tacN "prim__PureTactical", [_a, tm] <- args
      = return tm
      | n == tacN "prim__BindTactical", [_a, _b, first, andThen] <- args
      = do first' <- eval first
           res <- runTacTm first'
           next <- eval (App andThen res)
           runTacTm next
      | n == tacN "prim__Try", [_a, first, alt] <- args
      = do first' <- eval first
           alt' <- eval alt
           try' (runTacTm first') (runTacTm alt') True
      | n == tacN "prim__Fill", [raw] <- args
      = do raw' <- reifyRaw raw
           apply raw' []
           returnUnit
      | n == tacN "prim__Gensym", [hint] <- args
      = do hintStr <- eval hint
           case hintStr of
             Constant (Str h) -> do
               n <- getNameFrom (sMN 0 h)
               fmap fst $ get_type_val (reflectName n)
             _ -> fail "no hint"
      | n == tacN "prim__Claim", [n, ty] <- args
      = do n' <- reifyTTName n
           ty' <- reifyRaw ty
           claim n' ty'
           returnUnit
      | n == tacN "prim__Forget", [tt] <- args
      = do tt' <- reifyTT tt
           fmap fst . get_type_val $ reflect tt'
      | n == tacN "prim__Attack", [] <- args
      = do attack
           returnUnit
      | n == tacN "prim__Rewrite", [rule] <- args
      = do r <- reifyRaw rule
           rewrite r
           returnUnit
      | n == tacN "prim__Focus", [what] <- args
      = do n' <- reifyTTName what
           focus n'
           returnUnit
      | n == tacN "prim__Unfocus", [what] <- args
      = do n' <- reifyTTName what
           movelast n'
           returnUnit
      | n == tacN "prim__Intro", [mn] <- args
      = do n <- case fromTTMaybe mn of
                  Nothing -> return Nothing
                  Just name -> fmap Just $ reifyTTName name
           intro n
           returnUnit
      | n == tacN "prim__DeclareType", [decl] <- args
      = do (RDeclare n args res) <- reifyTyDecl decl
           ctxt <- get_context
           let mkPi arg res = RBind (argName arg)
                                    (Pi Nothing (argTy arg) (RUType AllTypes))
                                    res
               rty = foldr mkPi res args
           (checked, ty') <- lift $ check ctxt [] rty
           case normaliseAll ctxt [] (finalise ty') of
             TType _ -> lift . tfail . InternalMsg $
                          show checked ++ " is not a type: it's " ++ show ty'
             _       -> return ()
           case lookupDefExact n ctxt of
             Just _ -> lift . tfail . InternalMsg $
                         show n ++ " is already defined."
             Nothing -> return ()
           let decl = TyDecl Ref checked
               ctxt' = addCtxtDef n decl ctxt
           set_context ctxt'
           updateAux $ \e -> e { new_tyDecls = (RTyDeclInstrs n fc (map rArgToPArg args) checked) :
                                               new_tyDecls e }
           aux <- getAux
           returnUnit
      | n == tacN "prim__DefineFunction", [decl] <- args
      = do defn <- reifyFunDefn decl
           defineFunction defn
           returnUnit
      | n == tacN "prim__Debug", [ty, msg] <- args
      = do let msg' = fromTTMaybe msg
           case msg' of
             Nothing -> debugElaborator Nothing
             Just (Constant (Str m)) -> debugElaborator (Just m)
             Just x -> lift . tfail . InternalMsg $ "Can't reify message for debugging: " ++ show x
    runTacTm x = lift . tfail . InternalMsg $ "tactical is not implemented for " ++ show x

-- Running tactics directly
-- if a tactic adds unification problems, return an error

runTac :: Bool -> IState -> Maybe FC -> Name -> PTactic -> ElabD ()
runTac autoSolve ist perhapsFC fn tac
    = do env <- get_env
         g <- goal
         let tac' = fmap (addImplBound ist (map fst env)) tac
         if autoSolve
            then runT tac'
            else no_errors (runT tac')
                   (Just (CantSolveGoal g (map (\(n, b) -> (n, binderTy b)) env)))
  where
    runT (Intro []) = do g <- goal
                         attack; intro (bname g)
      where
        bname (Bind n _ _) = Just n
        bname _ = Nothing
    runT (Intro xs) = mapM_ (\x -> do attack; intro (Just x)) xs
    runT Intros = do g <- goal
                     attack; 
                     intro (bname g)
                     try' (runT Intros)
                          (return ()) True
      where
        bname (Bind n _ _) = Just n
        bname _ = Nothing
    runT (Exact tm) = do elab ist toplevel ERHS [] (sMN 0 "tac") tm
                         when autoSolve solveAll
    runT (MatchRefine fn)
        = do fnimps <-
               case lookupCtxtName fn (idris_implicits ist) of
                    [] -> do a <- envArgs fn
                             return [(fn, a)]
                    ns -> return (map (\ (n, a) -> (n, map (const True) a)) ns)
             let tacs = map (\ (fn', imps) ->
                                 (match_apply (Var fn') (map (\x -> (x, 0)) imps),
                                     fn')) fnimps
             tryAll tacs
             when autoSolve solveAll
       where envArgs n = do e <- get_env
                            case lookup n e of
                               Just t -> return $ map (const False)
                                                      (getArgTys (binderTy t))
                               _ -> return []
    runT (Refine fn [])
        = do fnimps <-
               case lookupCtxtName fn (idris_implicits ist) of
                    [] -> do a <- envArgs fn
                             return [(fn, a)]
                    ns -> return (map (\ (n, a) -> (n, map isImp a)) ns)
             let tacs = map (\ (fn', imps) ->
                                 (apply (Var fn') (map (\x -> (x, 0)) imps),
                                     fn')) fnimps
             tryAll tacs
             when autoSolve solveAll
       where isImp (PImp _ _ _ _ _) = True
             isImp _ = False
             envArgs n = do e <- get_env
                            case lookup n e of
                               Just t -> return $ map (const False)
                                                      (getArgTys (binderTy t))
                               _ -> return []
    runT (Refine fn imps) = do ns <- apply (Var fn) (map (\x -> (x,0)) imps)
                               when autoSolve solveAll
    runT DoUnify = do unify_all
                      when autoSolve solveAll
    runT (Claim n tm) = do tmHole <- getNameFrom (sMN 0 "newGoal")
                           claim tmHole RType
                           claim n (Var tmHole)
                           focus tmHole
                           elab ist toplevel ERHS [] (sMN 0 "tac") tm
                           focus n
    runT (Equiv tm) -- let bind tm, then
              = do attack
                   tyn <- getNameFrom (sMN 0 "ety")
                   claim tyn RType
                   valn <- getNameFrom (sMN 0 "eqval")
                   claim valn (Var tyn)
                   letn <- getNameFrom (sMN 0 "equiv_val")
                   letbind letn (Var tyn) (Var valn)
                   focus tyn
                   elab ist toplevel ERHS [] (sMN 0 "tac") tm
                   focus valn
                   when autoSolve solveAll
    runT (Rewrite tm) -- to elaborate tm, let bind it, then rewrite by that
              = do attack; -- (h:_) <- get_holes
                   tyn <- getNameFrom (sMN 0 "rty")
                   -- start_unify h
                   claim tyn RType
                   valn <- getNameFrom (sMN 0 "rval")
                   claim valn (Var tyn)
                   letn <- getNameFrom (sMN 0 "rewrite_rule")
                   letbind letn (Var tyn) (Var valn)
                   focus valn
                   elab ist toplevel ERHS [] (sMN 0 "tac") tm
                   rewrite (Var letn)
                   when autoSolve solveAll
    runT (Induction tm) -- let bind tm, similar to the others
              = case_ True autoSolve ist fn tm
    runT (CaseTac tm)
              = case_ False autoSolve ist fn tm
    runT (LetTac n tm)
              = do attack
                   tyn <- getNameFrom (sMN 0 "letty")
                   claim tyn RType
                   valn <- getNameFrom (sMN 0 "letval")
                   claim valn (Var tyn)
                   letn <- unique_hole n
                   letbind letn (Var tyn) (Var valn)
                   focus valn
                   elab ist toplevel ERHS [] (sMN 0 "tac") tm
                   when autoSolve solveAll
    runT (LetTacTy n ty tm)
              = do attack
                   tyn <- getNameFrom (sMN 0 "letty")
                   claim tyn RType
                   valn <- getNameFrom (sMN 0 "letval")
                   claim valn (Var tyn)
                   letn <- unique_hole n
                   letbind letn (Var tyn) (Var valn)
                   focus tyn
                   elab ist toplevel ERHS [] (sMN 0 "tac") ty
                   focus valn
                   elab ist toplevel ERHS [] (sMN 0 "tac") tm
                   when autoSolve solveAll
    runT Compute = compute
    runT Trivial = do trivial' ist; when autoSolve solveAll
    runT TCInstance = runT (Exact (PResolveTC emptyFC))
    runT (ProofSearch rec prover depth top hints)
         = do proofSearch' ist rec False depth prover top fn hints
              when autoSolve solveAll
    runT (Focus n) = focus n
    runT Unfocus = do hs <- get_holes
                      case hs of
                        []      -> return ()
                        (h : _) -> movelast h
    runT Solve = solve
    runT (Try l r) = do try' (runT l) (runT r) True
    runT (TSeq l r) = do runT l; runT r
    runT (ApplyTactic tm) = do tenv <- get_env -- store the environment
                               tgoal <- goal -- store the goal
                               attack -- let f : List (TTName, Binder TT) -> TT -> Tactic = tm in ...
                               script <- getNameFrom (sMN 0 "script")
                               claim script scriptTy
                               scriptvar <- getNameFrom (sMN 0 "scriptvar" )
                               letbind scriptvar scriptTy (Var script)
                               focus script
                               elab ist toplevel ERHS [] (sMN 0 "tac") tm
                               (script', _) <- get_type_val (Var scriptvar)
                               -- now that we have the script apply
                               -- it to the reflected goal and context
                               restac <- getNameFrom (sMN 0 "restac")
                               claim restac tacticTy
                               focus restac
                               fill (raw_apply (forget script')
                                               [reflectEnv tenv, reflect tgoal])
                               restac' <- get_guess
                               solve
                               -- normalise the result in order to
                               -- reify it
                               ctxt <- get_context
                               env <- get_env
                               let tactic = normalise ctxt env restac'
                               runReflected tactic
        where tacticTy = Var (reflm "Tactic")
              listTy = Var (sNS (sUN "List") ["List", "Prelude"])
              scriptTy = (RBind (sMN 0 "__pi_arg")
                                (Pi Nothing (RApp listTy envTupleType) RType)
                                    (RBind (sMN 1 "__pi_arg")
                                           (Pi Nothing (Var $ reflm "TT") RType) tacticTy))
    runT (ByReflection tm) -- run the reflection function 'tm' on the
                           -- goal, then apply the resulting reflected Tactic
        = do tgoal <- goal
             attack
             script <- getNameFrom (sMN 0 "script")
             claim script scriptTy
             scriptvar <- getNameFrom (sMN 0 "scriptvar" )
             letbind scriptvar scriptTy (Var script)
             focus script
             ptm <- get_term
             elab ist toplevel ERHS [] (sMN 0 "tac")
                  (PApp emptyFC tm [pexp (delabTy' ist [] tgoal True True)])
             (script', _) <- get_type_val (Var scriptvar)
             -- now that we have the script apply
             -- it to the reflected goal
             restac <- getNameFrom (sMN 0 "restac")
             claim restac tacticTy
             focus restac
             fill (forget script')
             restac' <- get_guess
             solve
             -- normalise the result in order to
             -- reify it
             ctxt <- get_context
             env <- get_env
             let tactic = normalise ctxt env restac'
             runReflected tactic
      where tacticTy = Var (reflm "Tactic")
            scriptTy = tacticTy

    runT (Reflect v) = do attack -- let x = reflect v in ...
                          tyn <- getNameFrom (sMN 0 "letty")
                          claim tyn RType
                          valn <- getNameFrom (sMN 0 "letval")
                          claim valn (Var tyn)
                          letn <- getNameFrom (sMN 0 "letvar")
                          letbind letn (Var tyn) (Var valn)
                          focus valn
                          elab ist toplevel ERHS [] (sMN 0 "tac") v
                          (value, _) <- get_type_val (Var letn)
                          ctxt <- get_context
                          env <- get_env
                          let value' = hnf ctxt env value
                          runTac autoSolve ist perhapsFC fn (Exact $ PQuote (reflect value'))
    runT (Fill v) = do attack -- let x = fill x in ...
                       tyn <- getNameFrom (sMN 0 "letty")
                       claim tyn RType
                       valn <- getNameFrom (sMN 0 "letval")
                       claim valn (Var tyn)
                       letn <- getNameFrom (sMN 0 "letvar")
                       letbind letn (Var tyn) (Var valn)
                       focus valn
                       elab ist toplevel ERHS [] (sMN 0 "tac") v
                       (value, _) <- get_type_val (Var letn)
                       ctxt <- get_context
                       env <- get_env
                       let value' = normalise ctxt env value
                       rawValue <- reifyRaw value'
                       runTac autoSolve ist perhapsFC fn (Exact $ PQuote rawValue)
    runT (GoalType n tac) = do g <- goal
                               case unApply g of
                                    (P _ n' _, _) ->
                                       if nsroot n' == sUN n
                                          then runT tac
                                          else fail "Wrong goal type"
                                    _ -> fail "Wrong goal type"
    runT ProofState = do g <- goal
                         return ()
    runT Skip = return ()
    runT (TFail err) = lift . tfail $ ReflectionError [err] (Msg "")
    runT SourceFC =
      case perhapsFC of
        Nothing -> lift . tfail $ Msg "There is no source location available."
        Just fc ->
          do fill $ reflectFC fc
             solve
    runT Qed = lift . tfail $ Msg "The qed command is only valid in the interactive prover"
    runT x = fail $ "Not implemented " ++ show x

    runReflected t = do t' <- reify ist t
                        runTac autoSolve ist perhapsFC fn t'

-- | Prefix a name with the "Language.Reflection" namespace
reflm :: String -> Name
reflm n = sNS (sUN n) ["Reflection", "Language"]


-- | Reify tactics from their reflected representation
reify :: IState -> Term -> ElabD PTactic
reify _ (P _ n _) | n == reflm "Intros" = return Intros
reify _ (P _ n _) | n == reflm "Trivial" = return Trivial
reify _ (P _ n _) | n == reflm "Instance" = return TCInstance
reify _ (P _ n _) | n == reflm "Solve" = return Solve
reify _ (P _ n _) | n == reflm "Compute" = return Compute
reify _ (P _ n _) | n == reflm "Skip" = return Skip
reify _ (P _ n _) | n == reflm "SourceFC" = return SourceFC
reify _ (P _ n _) | n == reflm "Unfocus" = return Unfocus
reify ist t@(App _ _)
          | (P _ f _, args) <- unApply t = reifyApp ist f args
reify _ t = fail ("Unknown tactic " ++ show t)

reifyApp :: IState -> Name -> [Term] -> ElabD PTactic
reifyApp ist t [l, r] | t == reflm "Try" = liftM2 Try (reify ist l) (reify ist r)
reifyApp _ t [Constant (I i)]
           | t == reflm "Search" = return (ProofSearch True True i Nothing [])
reifyApp _ t [x]
           | t == reflm "Refine" = do n <- reifyTTName x
                                      return $ Refine n []
reifyApp ist t [n, ty] | t == reflm "Claim" = do n' <- reifyTTName n
                                                 goal <- reifyTT ty
                                                 return $ Claim n' (delab ist goal)
reifyApp ist t [l, r] | t == reflm "Seq" = liftM2 TSeq (reify ist l) (reify ist r)
reifyApp ist t [Constant (Str n), x]
             | t == reflm "GoalType" = liftM (GoalType n) (reify ist x)
reifyApp _ t [n] | t == reflm "Intro" = liftM (Intro . (:[])) (reifyTTName n)
reifyApp ist t [t'] | t == reflm "Induction" = liftM (Induction . delab ist) (reifyTT t')
reifyApp ist t [t'] | t == reflm "Case" = liftM (Induction . delab ist) (reifyTT t')
reifyApp ist t [t']
             | t == reflm "ApplyTactic" = liftM (ApplyTactic . delab ist) (reifyTT t')
reifyApp ist t [t']
             | t == reflm "Reflect" = liftM (Reflect . delab ist) (reifyTT t')
reifyApp ist t [t']
             | t == reflm "ByReflection" = liftM (ByReflection . delab ist) (reifyTT t')
reifyApp _ t [t']
           | t == reflm "Fill" = liftM (Fill . PQuote) (reifyRaw t')
reifyApp ist t [t']
             | t == reflm "Exact" = liftM (Exact . delab ist) (reifyTT t')
reifyApp ist t [x]
             | t == reflm "Focus" = liftM Focus (reifyTTName x)
reifyApp ist t [t']
             | t == reflm "Rewrite" = liftM (Rewrite . delab ist) (reifyTT t')
reifyApp ist t [n, t']
             | t == reflm "LetTac" = do n'  <- reifyTTName n
                                        t'' <- reifyTT t'
                                        return $ LetTac n' (delab ist t')
reifyApp ist t [n, tt', t']
             | t == reflm "LetTacTy" = do n'   <- reifyTTName n
                                          tt'' <- reifyTT tt'
                                          t''  <- reifyTT t'
                                          return $ LetTacTy n' (delab ist tt'') (delab ist t'')
reifyApp ist t [errs]
             | t == reflm "Fail" = fmap TFail (reifyReportParts errs)
reifyApp _ f args = fail ("Unknown tactic " ++ show (f, args)) -- shouldn't happen

reifyReportParts :: Term -> ElabD [ErrorReportPart]
reifyReportParts errs =
  case unList errs of
    Nothing -> fail "Failed to reify errors"
    Just errs' ->
      let parts = mapM reifyReportPart errs' in
      case parts of
        Left err -> fail $ "Couldn't reify \"Fail\" tactic - " ++ show err
        Right errs'' ->
          return errs''

-- | Reify terms from their reflected representation
reifyTT :: Term -> ElabD Term
reifyTT t@(App _ _)
        | (P _ f _, args) <- unApply t = reifyTTApp f args
reifyTT t@(P _ n _)
        | n == reflm "Erased" = return $ Erased
reifyTT t@(P _ n _)
        | n == reflm "Impossible" = return $ Impossible
reifyTT t = fail ("Unknown reflection term: " ++ show t)

reifyTTApp :: Name -> [Term] -> ElabD Term
reifyTTApp t [nt, n, x]
           | t == reflm "P" = do nt' <- reifyTTNameType nt
                                 n'  <- reifyTTName n
                                 x'  <- reifyTT x
                                 return $ P nt' n' x'
reifyTTApp t [Constant (I i)]
           | t == reflm "V" = return $ V i
reifyTTApp t [n, b, x]
           | t == reflm "Bind" = do n' <- reifyTTName n
                                    b' <- reifyTTBinder reifyTT (reflm "TT") b
                                    x' <- reifyTT x
                                    return $ Bind n' b' x'
reifyTTApp t [f, x]
           | t == reflm "App" = do f' <- reifyTT f
                                   x' <- reifyTT x
                                   return $ App f' x'
reifyTTApp t [c]
           | t == reflm "TConst" = liftM Constant (reifyTTConst c)
reifyTTApp t [t', Constant (I i)]
           | t == reflm "Proj" = do t'' <- reifyTT t'
                                    return $ Proj t'' i
reifyTTApp t [tt]
           | t == reflm "TType" = liftM TType (reifyTTUExp tt)
reifyTTApp t args = fail ("Unknown reflection term: " ++ show (t, args))

-- | Reify raw terms from their reflected representation
reifyRaw :: Term -> ElabD Raw
reifyRaw t@(App _ _)
         | (P _ f _, args) <- unApply t = reifyRawApp f args
reifyRaw t@(P _ n _)
         | n == reflm "RType" = return $ RType
reifyRaw t = fail ("Unknown reflection raw term in reifyRaw: " ++ show t)

reifyRawApp :: Name -> [Term] -> ElabD Raw
reifyRawApp t [n]
            | t == reflm "Var" = liftM Var (reifyTTName n)
reifyRawApp t [n, b, x]
            | t == reflm "RBind" = do n' <- reifyTTName n
                                      b' <- reifyTTBinder reifyRaw (reflm "Raw") b
                                      x' <- reifyRaw x
                                      return $ RBind n' b' x'
reifyRawApp t [f, x]
            | t == reflm "RApp" = liftM2 RApp (reifyRaw f) (reifyRaw x)
reifyRawApp t [t']
            | t == reflm "RForce" = liftM RForce (reifyRaw t')
reifyRawApp t [c]
            | t == reflm "RConstant" = liftM RConstant (reifyTTConst c)
reifyRawApp t args = fail ("Unknown reflection raw term in reifyRawApp: " ++ show (t, args))

reifyTTName :: Term -> ElabD Name
reifyTTName t
            | (P _ f _, args) <- unApply t = reifyTTNameApp f args
reifyTTName t = fail ("Unknown reflection term name: " ++ show t)

reifyTTNameApp :: Name -> [Term] -> ElabD Name
reifyTTNameApp t [Constant (Str n)]
               | t == reflm "UN" = return $ sUN n
reifyTTNameApp t [n, ns]
               | t == reflm "NS" = do n'  <- reifyTTName n
                                      ns' <- reifyTTNamespace ns
                                      return $ sNS n' ns'
reifyTTNameApp t [Constant (I i), Constant (Str n)]
               | t == reflm "MN" = return $ sMN i n
reifyTTNameApp t []
               | t == reflm "NErased" = return NErased
reifyTTNameApp t args = fail ("Unknown reflection term name: " ++ show (t, args))

reifyTTNamespace :: Term -> ElabD [String]
reifyTTNamespace t@(App _ _)
  = case unApply t of
      (P _ f _, [Constant StrType])
           | f == sNS (sUN "Nil") ["List", "Prelude"] -> return []
      (P _ f _, [Constant StrType, Constant (Str n), ns])
           | f == sNS (sUN "::")  ["List", "Prelude"] -> liftM (n:) (reifyTTNamespace ns)
      _ -> fail ("Unknown reflection namespace arg: " ++ show t)
reifyTTNamespace t = fail ("Unknown reflection namespace arg: " ++ show t)

reifyTTNameType :: Term -> ElabD NameType
reifyTTNameType t@(P _ n _) | n == reflm "Bound" = return $ Bound
reifyTTNameType t@(P _ n _) | n == reflm "Ref" = return $ Ref
reifyTTNameType t@(App _ _)
  = case unApply t of
      (P _ f _, [Constant (I tag), Constant (I num)])
           | f == reflm "DCon" -> return $ DCon tag num False -- FIXME: Uniqueness!
           | f == reflm "TCon" -> return $ TCon tag num
      _ -> fail ("Unknown reflection name type: " ++ show t)
reifyTTNameType t = fail ("Unknown reflection name type: " ++ show t)

reifyTTBinder :: (Term -> ElabD a) -> Name -> Term -> ElabD (Binder a)
reifyTTBinder reificator binderType t@(App _ _)
  = case unApply t of
     (P _ f _, bt:args) | forget bt == Var binderType
       -> reifyTTBinderApp reificator f args
     _ -> fail ("Mismatching binder reflection: " ++ show t)
reifyTTBinder _ _ t = fail ("Unknown reflection binder: " ++ show t)

reifyTTBinderApp :: (Term -> ElabD a) -> Name -> [Term] -> ElabD (Binder a)
reifyTTBinderApp reif f [t]
                      | f == reflm "Lam" = liftM Lam (reif t)
reifyTTBinderApp reif f [t, k]
                      | f == reflm "Pi" = liftM2 (Pi Nothing) (reif t) (reif k)
reifyTTBinderApp reif f [x, y]
                      | f == reflm "Let" = liftM2 Let (reif x) (reif y)
reifyTTBinderApp reif f [x, y]
                      | f == reflm "NLet" = liftM2 NLet (reif x) (reif y)
reifyTTBinderApp reif f [t]
                      | f == reflm "Hole" = liftM Hole (reif t)
reifyTTBinderApp reif f [t]
                      | f == reflm "GHole" = liftM (GHole 0) (reif t)
reifyTTBinderApp reif f [x, y]
                      | f == reflm "Guess" = liftM2 Guess (reif x) (reif y)
reifyTTBinderApp reif f [t]
                      | f == reflm "PVar" = liftM PVar (reif t)
reifyTTBinderApp reif f [t]
                      | f == reflm "PVTy" = liftM PVTy (reif t)
reifyTTBinderApp _ f args = fail ("Unknown reflection binder: " ++ show (f, args))

reifyTTConst :: Term -> ElabD Const
reifyTTConst (P _ n _) | n == reflm "StrType"  = return $ StrType
reifyTTConst (P _ n _) | n == reflm "VoidType" = return $ VoidType
reifyTTConst (P _ n _) | n == reflm "Forgot"   = return $ Forgot
reifyTTConst t@(App _ _)
             | (P _ f _, [arg]) <- unApply t   = reifyTTConstApp f arg
reifyTTConst t = fail ("Unknown reflection constant: " ++ show t)

reifyTTConstApp :: Name -> Term -> ElabD Const
reifyTTConstApp f aty
                | f == reflm "AType" = fmap AType (reifyArithTy aty)
reifyTTConstApp f (Constant c@(I _))
                | f == reflm "I"   = return $ c
reifyTTConstApp f (Constant c@(BI _))
                | f == reflm "BI"  = return $ c
reifyTTConstApp f (Constant c@(Fl _))
                | f == reflm "Fl"  = return $ c
reifyTTConstApp f (Constant c@(I _))
                | f == reflm "Ch"  = return $ c
reifyTTConstApp f (Constant c@(Str _))
                | f == reflm "Str" = return $ c
reifyTTConstApp f (Constant c@(B8 _))
                | f == reflm "B8"  = return $ c
reifyTTConstApp f (Constant c@(B16 _))
                | f == reflm "B16" = return $ c
reifyTTConstApp f (Constant c@(B32 _))
                | f == reflm "B32" = return $ c
reifyTTConstApp f (Constant c@(B64 _))
                | f == reflm "B64" = return $ c
reifyTTConstApp f arg = fail ("Unknown reflection constant: " ++ show (f, arg))

reifyArithTy :: Term -> ElabD ArithTy
reifyArithTy (App (P _ n _) intTy) | n == reflm "ATInt"   = fmap ATInt (reifyIntTy intTy)
reifyArithTy (P _ n _)             | n == reflm "ATFloat" = return ATFloat
reifyArithTy x = fail ("Couldn't reify reflected ArithTy: " ++ show x)

reifyNativeTy :: Term -> ElabD NativeTy
reifyNativeTy (P _ n _) | n == reflm "IT8" = return IT8
reifyNativeTy (P _ n _) | n == reflm "IT8" = return IT8
reifyNativeTy (P _ n _) | n == reflm "IT8" = return IT8
reifyNativeTy (P _ n _) | n == reflm "IT8" = return IT8
reifyNativeTy x = fail $ "Couldn't reify reflected NativeTy " ++ show x

reifyIntTy :: Term -> ElabD IntTy
reifyIntTy (App (P _ n _) nt) | n == reflm "ITFixed" = fmap ITFixed (reifyNativeTy nt)
reifyIntTy (P _ n _) | n == reflm "ITNative" = return ITNative
reifyIntTy (P _ n _) | n == reflm "ITBig" = return ITBig
reifyIntTy (P _ n _) | n == reflm "ITChar" = return ITChar
reifyIntTy tm = fail $ "The term " ++ show tm ++ " is not a reflected IntTy"

reifyTTUExp :: Term -> ElabD UExp
reifyTTUExp t@(App _ _)
  = case unApply t of
      (P _ f _, [Constant (I i)]) | f == reflm "UVar" -> return $ UVar i
      (P _ f _, [Constant (I i)]) | f == reflm "UVal" -> return $ UVal i
      _ -> fail ("Unknown reflection type universe expression: " ++ show t)
reifyTTUExp t = fail ("Unknown reflection type universe expression: " ++ show t)

-- | Create a reflected call to a named function/constructor
reflCall :: String -> [Raw] -> Raw
reflCall funName args
  = raw_apply (Var (reflm funName)) args

-- | Lift a term into its Language.Reflection.TT representation
reflect :: Term -> Raw
reflect = reflectTTQuote []

-- | Lift a term into its Language.Reflection.Raw representation
reflectRaw :: Raw -> Raw
reflectRaw = reflectRawQuote []

claimTT :: Name -> ElabD Name
claimTT n = do n' <- getNameFrom n
               claim n' (Var (sNS (sUN "TT") ["Reflection", "Language"]))
               return n'

-- | Convert a reflected term to a more suitable form for pattern-matching.
-- In particular, the less-interesting bits are elaborated to _ patterns. This
-- happens to NameTypes, universe levels, names that are bound but not used,
-- and the type annotation field of the P constructor.
reflectTTQuotePattern :: [Name] -> Term -> ElabD ()
reflectTTQuotePattern unq (P _ n _)
  | n `elem` unq = -- the unquoted names have been claimed as TT already - just use them
    do fill (Var n) ; solve
  | otherwise =
    do tyannot <- claimTT (sMN 0 "pTyAnnot")
       movelast tyannot  -- use a _ pattern here
       nt <- getNameFrom (sMN 0 "nt")
       claim nt (Var (reflm "NameType"))
       movelast nt       -- use a _ pattern here
       n' <- getNameFrom (sMN 0 "n")
       claim n' (Var (reflm "TTName"))
       fill $ reflCall "P" [Var nt, Var n', Var tyannot]
       solve
       focus n'; reflectNameQuotePattern n
reflectTTQuotePattern unq (V n)
  = do fill $ reflCall "V" [RConstant (I n)]
       solve
reflectTTQuotePattern unq (Bind n b x)
  = do x' <- claimTT (sMN 0 "sc")
       movelast x'
       b' <- getNameFrom (sMN 0 "binder")
       claim b' (RApp (Var (sNS (sUN "Binder") ["Reflection", "Language"]))
                      (Var (sNS (sUN "TT") ["Reflection", "Language"])))
       if n `elem` freeNames x
         then do fill $ reflCall "Bind"
                                 [reflectName n,
                                  Var b',
                                  Var x']
                 solve
         else do any <- getNameFrom (sMN 0 "anyName")
                 claim any (Var (reflm "TTName"))
                 movelast any
                 fill $ reflCall "Bind"
                                 [Var any,
                                  Var b',
                                  Var x']
                 solve
       focus x'; reflectTTQuotePattern unq x
       focus b'; reflectBinderQuotePattern reflectTTQuotePattern unq b
reflectTTQuotePattern unq (App f x)
  = do f' <- claimTT (sMN 0 "f"); movelast f'
       x' <- claimTT (sMN 0 "x"); movelast x'
       fill $ reflCall "App" [Var f', Var x']
       solve
       focus f'; reflectTTQuotePattern unq f
       focus x'; reflectTTQuotePattern unq x
reflectTTQuotePattern unq (Constant c)
  = do fill $ reflCall "TConst" [reflectConstant c]
       solve
reflectTTQuotePattern unq (Proj t i)
  = do t' <- claimTT (sMN 0 "t"); movelast t'
       fill $ reflCall "Proj" [Var t', RConstant (I i)]
       solve
       focus t'; reflectTTQuotePattern unq t
reflectTTQuotePattern unq (Erased)
  = do erased <- claimTT (sMN 0 "erased")
       movelast erased
       fill $ (Var erased)
       solve
reflectTTQuotePattern unq (Impossible)
  = do fill $ Var (reflm "Impossible")
       solve
reflectTTQuotePattern unq (TType exp)
  = do ue <- getNameFrom (sMN 0 "uexp")
       claim ue (Var (sNS (sUN "TTUExp") ["Reflection", "Language"]))
       movelast ue
       fill $ reflCall "TType" [Var ue]
       solve
reflectTTQuotePattern unq (UType u)
  = do uH <- getNameFrom (sMN 0 "someUniv")
       claim uH (Var (reflm "Universe"))
       movelast uH
       fill $ reflCall "UType" [Var uH]
       solve
       focus uH
       fill (Var (reflm (case u of
                           NullType -> "NullType"
                           UniqueType -> "UniqueType"
                           AllTypes -> "AllTypes")))
       solve

reflectRawQuotePattern :: [Name] -> Raw -> ElabD ()
reflectRawQuotePattern unq (Var n)
  -- the unquoted names already have types, just use them
  | n `elem` unq = do fill (Var n); solve
  | otherwise = do fill (reflCall "Var" [reflectName n]); solve
reflectRawQuotePattern unq (RBind n b sc) =
  do scH <- getNameFrom (sMN 0 "sc")
     claim scH (Var (reflm "Raw"))
     movelast scH
     bH <- getNameFrom (sMN 0 "binder")
     claim bH (RApp (Var (reflm "Binder"))
                    (Var (reflm "Raw")))
     if n `elem` freeNamesR sc
        then do fill $ reflCall "RBind" [reflectName n,
                                         Var bH,
                                         Var scH]
                solve
        else do any <- getNameFrom (sMN 0 "anyName")
                claim any (Var (reflm "TTName"))
                movelast any
                fill $ reflCall "RBind" [Var any, Var bH, Var scH]
                solve
     focus scH; reflectRawQuotePattern unq sc
     focus bH; reflectBinderQuotePattern reflectRawQuotePattern unq b
  where freeNamesR (Var n) = [n]
        freeNamesR (RBind n (Let t v) body) = concat [freeNamesR v,
                                                      freeNamesR body \\ [n],
                                                      freeNamesR t]
        freeNamesR (RBind n b body) = freeNamesR (binderTy b) ++
                                      (freeNamesR body \\ [n])
        freeNamesR (RApp f x) = freeNamesR f ++ freeNamesR x
        freeNamesR RType = []
        freeNamesR (RUType _) = []
        freeNamesR (RForce r) = freeNamesR r
        freeNamesR (RConstant _) = []
reflectRawQuotePattern unq (RApp f x) =
  do fH <- getNameFrom (sMN 0 "f")
     claim fH (Var (reflm "Raw"))
     movelast fH
     xH <- getNameFrom (sMN 0 "x")
     claim xH (Var (reflm "Raw"))
     movelast xH
     fill $ reflCall "RApp" [Var fH, Var xH]
     solve
     focus fH; reflectRawQuotePattern unq f
     focus xH; reflectRawQuotePattern unq x
reflectRawQuotePattern unq RType =
  do fill (Var (reflm "RType"))
     solve
reflectRawQuotePattern unq (RUType univ) =
  do uH <- getNameFrom (sMN 0 "universe")
     claim uH (Var (reflm "Universe"))
     movelast uH
     fill $ reflCall "RUType" [Var uH]
     solve
     focus uH; fill (reflectUniverse univ); solve
reflectRawQuotePattern unq (RForce r) =
  do rH <- getNameFrom (sMN 0 "raw")
     claim rH (Var (reflm "Raw"))
     movelast rH
     fill $ reflCall "RForce" [Var rH]
     solve
     focus rH; reflectRawQuotePattern unq r
reflectRawQuotePattern unq (RConstant c) =
  do cH <- getNameFrom (sMN 0 "const")
     claim cH (Var (reflm "Constant"))
     movelast cH
     fill (reflCall "RConstant" [Var cH]); solve
     focus cH
     fill (reflectConstant c); solve

reflectBinderQuotePattern :: ([Name] -> a -> ElabD ()) -> [Name] -> Binder a -> ElabD ()
reflectBinderQuotePattern q unq (Lam t)
   = do t' <- claimTT (sMN 0 "ty"); movelast t'
        fill $ reflCall "Lam" [Var (reflm "TT"), Var t']
        solve
        focus t'; q unq t
reflectBinderQuotePattern q unq (Pi _ t k)
   = do t' <- claimTT (sMN 0 "ty") ; movelast t'
        k' <- claimTT (sMN 0 "k"); movelast k';
        fill $ reflCall "Pi" [Var (reflm "TT"), Var t', Var k']
        solve
        focus t'; q unq t
reflectBinderQuotePattern q unq (Let x y)
   = do x' <- claimTT (sMN 0 "ty"); movelast x';
        y' <- claimTT (sMN 0 "v"); movelast y';
        fill $ reflCall "Let" [Var (reflm "TT"), Var x', Var y']
        solve
        focus x'; q unq x
        focus y'; q unq y
reflectBinderQuotePattern q unq (NLet x y)
   = do x' <- claimTT (sMN 0 "ty"); movelast x'
        y' <- claimTT (sMN 0 "v"); movelast y'
        fill $ reflCall "NLet" [Var (reflm "TT"), Var x', Var y']
        solve
        focus x'; q unq x
        focus y'; q unq y
reflectBinderQuotePattern q unq (Hole t)
   = do t' <- claimTT (sMN 0 "ty"); movelast t'
        fill $ reflCall "Hole" [Var (reflm "TT"), Var t']
        solve
        focus t'; q unq t
reflectBinderQuotePattern q unq (GHole _ t)
   = do t' <- claimTT (sMN 0 "ty"); movelast t'
        fill $ reflCall "GHole" [Var (reflm "TT"), Var t']
        solve
        focus t'; q unq t
reflectBinderQuotePattern q unq (Guess x y)
   = do x' <- claimTT (sMN 0 "ty"); movelast x'
        y' <- claimTT (sMN 0 "v"); movelast y'
        fill $ reflCall "Guess" [Var (reflm "TT"), Var x', Var y']
        solve
        focus x'; q unq x
        focus y'; q unq y
reflectBinderQuotePattern q unq (PVar t)
   = do t' <- claimTT (sMN 0 "ty"); movelast t'
        fill $ reflCall "PVar" [Var (reflm "TT"), Var t']
        solve
        focus t'; q unq t
reflectBinderQuotePattern q unq (PVTy t)
   = do t' <- claimTT (sMN 0 "ty"); movelast t'
        fill $ reflCall "PVTy" [Var (reflm "TT"), Var t']
        solve
        focus t'; q unq t

reflectUniverse :: Universe -> Raw
reflectUniverse u =
  (Var (reflm (case u of
                 NullType -> "NullType"
                 UniqueType -> "UniqueType"
                 AllTypes -> "AllTypes")))

-- | Create a reflected TT term, but leave refs to the provided name intact
reflectTTQuote :: [Name] -> Term -> Raw
reflectTTQuote unq (P nt n t)
  | n `elem` unq = Var n
  | otherwise = reflCall "P" [reflectNameType nt, reflectName n, reflectTTQuote unq t]
reflectTTQuote unq (V n)
  = reflCall "V" [RConstant (I n)]
reflectTTQuote unq (Bind n b x)
  = reflCall "Bind" [reflectName n, reflectBinderQuote reflectTTQuote (reflm "TT") unq b, reflectTTQuote unq x]
reflectTTQuote unq (App f x)
  = reflCall "App" [reflectTTQuote unq f, reflectTTQuote unq x]
reflectTTQuote unq (Constant c)
  = reflCall "TConst" [reflectConstant c]
reflectTTQuote unq (Proj t i)
  = reflCall "Proj" [reflectTTQuote unq t, RConstant (I i)]
reflectTTQuote unq (Erased) = Var (reflm "Erased")
reflectTTQuote unq (Impossible) = Var (reflm "Impossible")
reflectTTQuote unq (TType exp) = reflCall "TType" [reflectUExp exp]
reflectTTQuote unq (UType u) = reflCall "UType" [reflectUniverse u]

reflectRawQuote :: [Name] -> Raw -> Raw
reflectRawQuote unq (Var n)
  | n `elem` unq = Var n
  | otherwise = reflCall "Var" [reflectName n]
reflectRawQuote unq (RBind n b r) =
  reflCall "RBind" [reflectName n, reflectBinderQuote reflectRawQuote (reflm "Raw") unq b, reflectRawQuote unq r]
reflectRawQuote unq (RApp f x) =
  reflCall "RApp" [reflectRawQuote unq f, reflectRawQuote unq x]
reflectRawQuote unq RType = Var (reflm "RType")
reflectRawQuote unq (RUType u) =
  reflCall "RUType" [reflectUniverse u]
reflectRawQuote unq (RForce r) = reflCall "RForce" [reflectRawQuote unq r]
reflectRawQuote unq (RConstant cst) = reflCall "RConstant" [reflectConstant cst]

reflectNameType :: NameType -> Raw
reflectNameType (Bound) = Var (reflm "Bound")
reflectNameType (Ref) = Var (reflm "Ref")
reflectNameType (DCon x y _)
  = reflCall "DCon" [RConstant (I x), RConstant (I y)] -- FIXME: Uniqueness!
reflectNameType (TCon x y)
  = reflCall "TCon" [RConstant (I x), RConstant (I y)]

reflectName :: Name -> Raw
reflectName (UN s)
  = reflCall "UN" [RConstant (Str (str s))]
reflectName (NS n ns)
  = reflCall "NS" [ reflectName n
                  , foldr (\ n s ->
                             raw_apply ( Var $ sNS (sUN "::") ["List", "Prelude"] )
                                       [ RConstant StrType, RConstant (Str n), s ])
                             ( raw_apply ( Var $ sNS (sUN "Nil") ["List", "Prelude"] )
                                         [ RConstant StrType ])
                             (map str ns)
                  ]
reflectName (MN i n)
  = reflCall "MN" [RConstant (I i), RConstant (Str (str n))]
reflectName (NErased) = Var (reflm "NErased")
reflectName n = Var (reflm "NErased") -- special name, not yet implemented

-- | Elaborate a name to a pattern.  This means that NS and UN will be intact.
-- MNs corresponding to will care about the string but not the number.  All
-- others become _.
reflectNameQuotePattern :: Name -> ElabD ()
reflectNameQuotePattern n@(UN s)
  = do fill $ reflectName n
       solve
reflectNameQuotePattern n@(NS _ _)
  = do fill $ reflectName n
       solve
reflectNameQuotePattern (MN _ n)
  = do i <- getNameFrom (sMN 0 "mnCounter")
       claim i (RConstant (AType (ATInt ITNative)))
       movelast i
       fill $ reflCall "MN" [Var i, RConstant (Str $ T.unpack n)]
       solve
reflectNameQuotePattern _ -- for all other names, match any
  = do nameHole <- getNameFrom (sMN 0 "name")
       claim nameHole (Var (reflm "TTName"))
       movelast nameHole
       fill (Var nameHole)
       solve

reflectBinder :: Binder Term -> Raw
reflectBinder = reflectBinderQuote reflectTTQuote (reflm "TT") []

reflectBinderQuote :: ([Name] -> a -> Raw) -> Name -> [Name] -> Binder a -> Raw
reflectBinderQuote q ty unq (Lam t)
   = reflCall "Lam" [Var ty, q unq t]
reflectBinderQuote q ty unq (Pi _ t k)
   = reflCall "Pi" [Var ty, q unq t, q unq k]
reflectBinderQuote q ty unq (Let x y)
   = reflCall "Let" [Var ty, q unq x, q unq y]
reflectBinderQuote q ty unq (NLet x y)
   = reflCall "NLet" [Var ty, q unq x, q unq y]
reflectBinderQuote q ty unq (Hole t)
   = reflCall "Hole" [Var ty, q unq t]
reflectBinderQuote q ty unq (GHole _ t)
   = reflCall "GHole" [Var ty, q unq t]
reflectBinderQuote q ty unq (Guess x y)
   = reflCall "Guess" [Var ty, q unq x, q unq y]
reflectBinderQuote q ty unq (PVar t)
   = reflCall "PVar" [Var ty, q unq t]
reflectBinderQuote q ty unq (PVTy t)
   = reflCall "PVTy" [Var ty, q unq t]

mkList :: Raw -> [Raw] -> Raw
mkList ty []      = RApp (Var (sNS (sUN "Nil") ["List", "Prelude"])) ty
mkList ty (x:xs) = RApp (RApp (RApp (Var (sNS (sUN "::") ["List", "Prelude"])) ty)
                              x)
                        (mkList ty xs)

reflectConstant :: Const -> Raw
reflectConstant c@(I  _) = reflCall "I"  [RConstant c]
reflectConstant c@(BI _) = reflCall "BI" [RConstant c]
reflectConstant c@(Fl _) = reflCall "Fl" [RConstant c]
reflectConstant c@(Ch _) = reflCall "Ch" [RConstant c]
reflectConstant c@(Str _) = reflCall "Str" [RConstant c]
reflectConstant c@(B8 _) = reflCall "B8" [RConstant c]
reflectConstant c@(B16 _) = reflCall "B16" [RConstant c]
reflectConstant c@(B32 _) = reflCall "B32" [RConstant c]
reflectConstant c@(B64 _) = reflCall "B64" [RConstant c]
reflectConstant (AType (ATInt ITNative)) = reflCall "AType" [reflCall "ATInt" [Var (reflm "ITNative")]]
reflectConstant (AType (ATInt ITBig)) = reflCall "AType" [reflCall "ATInt" [Var (reflm "ITBig")]]
reflectConstant (AType ATFloat) = reflCall "AType" [Var (reflm "ATFloat")]
reflectConstant (AType (ATInt ITChar)) = reflCall "AType" [reflCall "ATInt" [Var (reflm "ITChar")]]
reflectConstant StrType = Var (reflm "StrType")
reflectConstant (AType (ATInt (ITFixed IT8)))  = reflCall "AType" [reflCall "ATInt" [reflCall "ITFixed" [Var (reflm "IT8")]]]
reflectConstant (AType (ATInt (ITFixed IT16))) = reflCall "AType" [reflCall "ATInt" [reflCall "ITFixed" [Var (reflm "IT16")]]]
reflectConstant (AType (ATInt (ITFixed IT32))) = reflCall "AType" [reflCall "ATInt" [reflCall "ITFixed" [Var (reflm "IT32")]]]
reflectConstant (AType (ATInt (ITFixed IT64))) = reflCall "AType" [reflCall "ATInt" [reflCall "ITFixed" [Var (reflm "IT64")]]]
reflectConstant VoidType = Var (reflm "VoidType")
reflectConstant Forgot = Var (reflm "Forgot")
reflectConstant WorldType = Var (reflm "WorldType")
reflectConstant TheWorld = Var (reflm "TheWorld")

reflectUExp :: UExp -> Raw
reflectUExp (UVar i) = reflCall "UVar" [RConstant (I i)]
reflectUExp (UVal i) = reflCall "UVal" [RConstant (I i)]

-- | Reflect the environment of a proof into a List (TTName, Binder TT)
reflectEnv :: Env -> Raw
reflectEnv = foldr consToEnvList emptyEnvList
  where
    consToEnvList :: (Name, Binder Term) -> Raw -> Raw
    consToEnvList (n, b) l
      = raw_apply (Var (sNS (sUN "::") ["List", "Prelude"]))
                  [ envTupleType
                  , raw_apply (Var pairCon) [ (Var $ reflm "TTName")
                                            , (RApp (Var $ reflm "Binder")
                                                    (Var $ reflm "TT"))
                                            , reflectName n
                                            , reflectBinder b
                                            ]
                  , l
                  ]

    emptyEnvList :: Raw
    emptyEnvList = raw_apply (Var (sNS (sUN "Nil") ["List", "Prelude"]))
                             [envTupleType]

-- | Reflect an error into the internal datatype of Idris -- TODO
rawBool :: Bool -> Raw
rawBool True  = Var (sNS (sUN "True") ["Bool", "Prelude"])
rawBool False = Var (sNS (sUN "False") ["Bool", "Prelude"])

rawNil :: Raw -> Raw
rawNil ty = raw_apply (Var (sNS (sUN "Nil") ["List", "Prelude"])) [ty]

rawCons :: Raw -> Raw -> Raw -> Raw
rawCons ty hd tl = raw_apply (Var (sNS (sUN "::") ["List", "Prelude"])) [ty, hd, tl]

rawList :: Raw -> [Raw] -> Raw
rawList ty = foldr (rawCons ty) (rawNil ty)

rawPairTy :: Raw -> Raw -> Raw
rawPairTy t1 t2 = raw_apply (Var pairTy) [t1, t2]

rawPair :: (Raw, Raw) -> (Raw, Raw) -> Raw
rawPair (a, b) (x, y) = raw_apply (Var pairCon) [a, b, x, y]

reflectCtxt :: [(Name, Type)] -> Raw
reflectCtxt ctxt = rawList (rawPairTy  (Var $ reflm "TTName") (Var $ reflm "TT"))
                           (map (\ (n, t) -> (rawPair (Var $ reflm "TTName", Var $ reflm "TT")
                                                      (reflectName n, reflect t)))
                                ctxt)

reflectErr :: Err -> Raw
reflectErr (Msg msg) = raw_apply (Var $ reflErrName "Msg") [RConstant (Str msg)]
reflectErr (InternalMsg msg) = raw_apply (Var $ reflErrName "InternalMsg") [RConstant (Str msg)]
reflectErr (CantUnify b (t1,_) (t2,_) e ctxt i) =
  raw_apply (Var $ reflErrName "CantUnify")
            [ rawBool b
            , reflect t1
            , reflect t2
            , reflectErr e
            , reflectCtxt ctxt
            , RConstant (I i)]
reflectErr (InfiniteUnify n tm ctxt) =
  raw_apply (Var $ reflErrName "InfiniteUnify")
            [ reflectName n
            , reflect tm
            , reflectCtxt ctxt
            ]
reflectErr (CantConvert t t' ctxt) =
  raw_apply (Var $ reflErrName "CantConvert")
            [ reflect t
            , reflect t'
            , reflectCtxt ctxt
            ]
reflectErr (CantSolveGoal t ctxt) =
  raw_apply (Var $ reflErrName "CantSolveGoal")
            [ reflect t
            , reflectCtxt ctxt
            ]
reflectErr (UnifyScope n n' t ctxt) =
  raw_apply (Var $ reflErrName "UnifyScope")
            [ reflectName n
            , reflectName n'
            , reflect t
            , reflectCtxt ctxt
            ]
reflectErr (CantInferType str) =
  raw_apply (Var $ reflErrName "CantInferType") [RConstant (Str str)]
reflectErr (NonFunctionType t t') =
  raw_apply (Var $ reflErrName "NonFunctionType") [reflect t, reflect t']
reflectErr (NotEquality t t') =
  raw_apply (Var $ reflErrName "NotEquality") [reflect t, reflect t']
reflectErr (TooManyArguments n) = raw_apply (Var $ reflErrName "TooManyArguments") [reflectName n]
reflectErr (CantIntroduce t) = raw_apply (Var $ reflErrName "CantIntroduce") [reflect t]
reflectErr (NoSuchVariable n) = raw_apply (Var $ reflErrName "NoSuchVariable") [reflectName n]
reflectErr (WithFnType t) = raw_apply (Var $ reflErrName "WithFnType") [reflect t]
reflectErr (CantMatch t) = raw_apply (Var $ reflErrName "CantMatch") [reflect t]
reflectErr (NoTypeDecl n) = raw_apply (Var $ reflErrName "NoTypeDecl") [reflectName n]
reflectErr (NotInjective t1 t2 t3) =
  raw_apply (Var $ reflErrName "NotInjective")
            [ reflect t1
            , reflect t2
            , reflect t3
            ]
reflectErr (CantResolve _ t) = raw_apply (Var $ reflErrName "CantResolve") [reflect t]
reflectErr (InvalidTCArg n t) = raw_apply (Var $ reflErrName "InvalidTCArg") [reflectName n, reflect t]
reflectErr (CantResolveAlts ss) =
  raw_apply (Var $ reflErrName "CantResolveAlts")
            [rawList (Var $ reflm "TTName") (map reflectName ss)]
reflectErr (IncompleteTerm t) = raw_apply (Var $ reflErrName "IncompleteTerm") [reflect t]
reflectErr (NoEliminator str t) 
  = raw_apply (Var $ reflErrName "NoEliminator") [RConstant (Str str),
                                                  reflect t]
reflectErr UniverseError = Var $ reflErrName "UniverseError"
reflectErr ProgramLineComment = Var $ reflErrName "ProgramLineComment"
reflectErr (Inaccessible n) = raw_apply (Var $ reflErrName "Inaccessible") [reflectName n]
reflectErr (NonCollapsiblePostulate n) = raw_apply (Var $ reflErrName "NonCollabsiblePostulate") [reflectName n]
reflectErr (AlreadyDefined n) = raw_apply (Var $ reflErrName "AlreadyDefined") [reflectName n]
reflectErr (ProofSearchFail e) = raw_apply (Var $ reflErrName "ProofSearchFail") [reflectErr e]
reflectErr (NoRewriting tm) = raw_apply (Var $ reflErrName "NoRewriting") [reflect tm]
reflectErr (ProviderError str) =
  raw_apply (Var $ reflErrName "ProviderError") [RConstant (Str str)]
reflectErr (LoadingFailed str err) =
  raw_apply (Var $ reflErrName "LoadingFailed") [RConstant (Str str)]
reflectErr x = raw_apply (Var (sNS (sUN "Msg") ["Errors", "Reflection", "Language"])) [RConstant . Str $ "Default reflection: " ++ show x]

-- | Reflect a file context
reflectFC :: FC -> Raw
reflectFC fc = raw_apply (Var (reflm "FileLoc"))
                         [ RConstant (Str (fc_fname fc))
                         , raw_apply (Var pairCon) $
                             [intTy, intTy] ++
                             map (RConstant . I)
                                 [ fst (fc_start fc)
                                 , snd (fc_start fc)
                                 ]
                         , raw_apply (Var pairCon) $
                             [intTy, intTy] ++
                             map (RConstant . I)
                                 [ fst (fc_end fc)
                                 , snd (fc_end fc)
                                 ]
                         ]
  where intTy = RConstant (AType (ATInt ITNative))

elaboratingArgErr :: [(Name, Name)] -> Err -> Err
elaboratingArgErr [] err = err
elaboratingArgErr ((f,x):during) err = fromMaybe err (rewrite err)
  where rewrite (ElaboratingArg _ _ _ _) = Nothing
        rewrite (ProofSearchFail e) = fmap ProofSearchFail (rewrite e)
        rewrite (At fc e) = fmap (At fc) (rewrite e)
        rewrite err = Just (ElaboratingArg f x during err)


withErrorReflection :: Idris a -> Idris a
withErrorReflection x = idrisCatch x (\ e -> handle e >>= ierror)
    where handle :: Err -> Idris Err
          handle e@(ReflectionError _ _)  = do logLvl 3 "Skipping reflection of error reflection result"
                                               return e -- Don't do meta-reflection of errors
          handle e@(ReflectionFailed _ _) = do logLvl 3 "Skipping reflection of reflection failure"
                                               return e
          -- At and Elaborating are just plumbing - error reflection shouldn't rewrite them
          handle e@(At fc err) = do logLvl 3 "Reflecting body of At"
                                    err' <- handle err
                                    return (At fc err')
          handle e@(Elaborating what n err) = do logLvl 3 "Reflecting body of Elaborating"
                                                 err' <- handle err
                                                 return (Elaborating what n err')
          handle e@(ElaboratingArg f a prev err) = do logLvl 3 "Reflecting body of ElaboratingArg"
                                                      hs <- getFnHandlers f a
                                                      err' <- if null hs
                                                                 then handle err
                                                                 else applyHandlers err hs
                                                      return (ElaboratingArg f a prev err')
          -- ProofSearchFail is an internal detail - so don't expose it
          handle (ProofSearchFail e) = handle e
          -- TODO: argument-specific error handlers go here for ElaboratingArg
          handle e = do ist <- getIState
                        logLvl 2 "Starting error reflection"
                        let handlers = idris_errorhandlers ist
                        applyHandlers e handlers
          getFnHandlers :: Name -> Name -> Idris [Name]
          getFnHandlers f arg = do ist <- getIState
                                   let funHandlers = maybe M.empty id .
                                                     lookupCtxtExact f .
                                                     idris_function_errorhandlers $ ist
                                   return . maybe [] S.toList . M.lookup arg $ funHandlers


          applyHandlers e handlers =
                      do ist <- getIState
                         let err = fmap (errReverse ist) e
                         logLvl 3 $ "Using reflection handlers " ++
                                    concat (intersperse ", " (map show handlers))
                         let reports = map (\n -> RApp (Var n) (reflectErr err)) handlers

                         -- Typecheck error handlers - if this fails, then something else was wrong earlier!
                         handlers <- case mapM (check (tt_ctxt ist) []) reports of
                                       Error e -> ierror $ ReflectionFailed "Type error while constructing reflected error" e
                                       OK hs   -> return hs

                         -- Normalize error handler terms to produce the new messages
                         ctxt <- getContext
                         let results = map (normalise ctxt []) (map fst handlers)
                         logLvl 3 $ "New error message info: " ++ concat (intersperse " and " (map show results))

                         -- For each handler term output, either discard it if it is Nothing or reify it the Haskell equivalent
                         let errorpartsTT = mapMaybe unList (mapMaybe fromTTMaybe results)
                         errorparts <- case mapM (mapM reifyReportPart) errorpartsTT of
                                         Left err -> ierror err
                                         Right ok -> return ok
                         return $ case errorparts of
                                    []    -> e
                                    parts -> ReflectionError errorparts e

fromTTMaybe :: Term -> Maybe Term -- WARNING: Assumes the term has type Maybe a
fromTTMaybe (App (App (P (DCon _ _ _) (NS (UN just) _) _) ty) tm)
  | just == txt "Just" = Just tm
fromTTMaybe x          = Nothing

reflErrName :: String -> Name
reflErrName n = sNS (sUN n) ["Errors", "Reflection", "Language"]

-- | Attempt to reify a report part from TT to the internal
-- representation. Not in Idris or ElabD monads because it should be usable
-- from either.
reifyReportPart :: Term -> Either Err ErrorReportPart
reifyReportPart (App (P (DCon _ _ _) n _) (Constant (Str msg))) | n == reflm "TextPart" =
    Right (TextPart msg)
reifyReportPart (App (P (DCon _ _ _) n _) ttn)
  | n == reflm "NamePart" =
    case runElab initEState (reifyTTName ttn) (initElaborator NErased initContext Erased) of
      Error e -> Left . InternalMsg $
       "could not reify name term " ++
       show ttn ++
       " when reflecting an error:" ++ show e
      OK (n', _)-> Right $ NamePart n'
reifyReportPart (App (P (DCon _ _ _) n _) tm)
  | n == reflm "TermPart" =
  case runElab initEState (reifyTT tm) (initElaborator NErased initContext Erased) of
    Error e -> Left . InternalMsg $
      "could not reify reflected term " ++
      show tm ++
      " when reflecting an error:" ++ show e
    OK (tm', _) -> Right $ TermPart tm'
reifyReportPart (App (P (DCon _ _ _) n _) tm)
  | n == reflm "SubReport" =
  case unList tm of
    Just xs -> do subParts <- mapM reifyReportPart xs
                  Right (SubReport subParts)
    Nothing -> Left . InternalMsg $ "could not reify subreport " ++ show tm
reifyReportPart x = Left . InternalMsg $ "could not reify " ++ show x

reifyTyDecl :: Term -> ElabD RTyDecl
reifyTyDecl (App (App (App (P (DCon _ _ _) n _) tyN) args) ret)
  | n == tacN "Declare" =
  do tyN'  <- reifyTTName tyN
     args' <- case unList args of
                Nothing -> fail $ "Couldn't reify " ++ show args ++ " as an arglist."
                Just xs -> mapM reifyRArg xs
     ret'  <- reifyRaw ret
     return $ RDeclare tyN' args' ret'
  where reifyRArg :: Term -> ElabD RArg
        reifyRArg (App (App (P (DCon _ _ _) n _) argN) argTy)
          | n == tacN "Explicit"   = liftM2 RExplicit
                                            (reifyTTName argN)
                                            (reifyRaw argTy)
          | n == tacN "Implicit"   = liftM2 RImplicit
                                            (reifyTTName argN)
                                            (reifyRaw argTy)                               | n == tacN "Constraint" = liftM2 RConstraint
                                            (reifyTTName argN)
                                            (reifyRaw argTy)
        reifyRArg aTm = fail $ "Couldn't reify " ++ show aTm ++ " as an RArg."
reifyTyDecl tm = fail $ "Couldn't reify " ++ show tm ++ " as a type declaration."

reifyFunDefn :: Term -> ElabD RFunDefn
reifyFunDefn (App (App (P _ n _) fnN) clauses)
  | n == tacN "DefineFun" =
  do fnN' <- reifyTTName fnN
     clauses' <- case unList clauses of
                   Nothing -> fail $ "Couldn't reify " ++ show clauses ++ " as a clause list"
                   Just cs -> mapM reifyC cs
     return $ RDefineFun fnN' clauses'
  where reifyC :: Term -> ElabD RFunClause
        reifyC (App (App (P (DCon _ _ _) n _) lhs) rhs)
          | n == tacN "MkFunClause" = liftM2 RMkFunClause
                                             (reifyRaw lhs)
                                             (reifyRaw rhs)
        reifyC tm = fail $ "Couldn't reify " ++ show tm ++ " as a clause."
reifyFunDefn tm = fail $ "Couldn't reify " ++ show tm ++ " as a function declaration."

envTupleType :: Raw
envTupleType
  = raw_apply (Var pairTy) [ (Var $ reflm "TTName")
                           , (RApp (Var $ reflm "Binder") (Var $ reflm "TT"))
                           ]

solveAll = try (do solve; solveAll) (return ())
