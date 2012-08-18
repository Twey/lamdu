{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts, TemplateHaskell #-}
module Editor.Data.Typed
  ( StoredExpression(..)
  , Ref
  , RefMap
  ) where

import Control.Applicative ((<*>))
import Control.Arrow (first)
import Control.Lens ((%=), (.=), (^.))
import Control.Monad (guard, liftM, mapM_, when)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.State.Class (MonadState)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.Trans.State (runStateT)
import Data.IntMap (IntMap)
import Data.IntSet (IntSet)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Reader.Class as Reader
import qualified Control.Monad.State.Class as State
import qualified Data.IntMap as IntMap
import qualified Data.IntMap.Lens as IntMapLens
import qualified Data.IntSet as IntSet
import qualified Data.IntSet.Lens as IntSetLens
import qualified Data.Map as Map
import qualified Data.Store.Guid as Guid
import qualified Data.Traversable as Traversable
import qualified Editor.Data as Data
import qualified Editor.Data.Load as DataLoad

newtype Ref = Ref { unRef :: Int }
instance Show Ref where
  show = ('P' :) . show . unRef

data TypedValue = TypedValue
  { tvVal :: Ref
  , tvType :: Ref
  }
instance Show TypedValue where
  show (TypedValue v t) = concat [show v, ":", show t]

-- Initial Pass:
-- Get Definitions' types expand.
-- Use expression's structures except for Apply.
--   (because an Apply can result in something else
--    but for example an Int or Lambda stays the same)
-- Add SimpleType, Apply, LambdaOrPi, Union rules
-- Param types of Lambdas and Pis are of type Set
-- Pi result type is of type Set

-- When recursing on an expression, we remember the parent expression guids,
-- And we make sure not to add a sub-expression with a parent guid (that's a recursive structure).

-- SimpleType Rule:
-- Type of a Lambda is a Pi, with same param type
-- Type of a Pi is Set
-- Type of Set is Set
-- Type of Builtin is what's stored in it

-- Apply Rule:
--
-- Apply =
-- Func                        Arg
-- ----                        ---
-- FuncT = ParamT -> ResultT   ArgT
-- --------------------------------
-- ApplyT
--
-- ParamT <=> ArgT
-- Recurse-Subst ResultT ApplyT Arg
-- If Arg is Get Param:
--   ArgT <=> ResultT
-- Case Func of
--   Hole -> Do Nothing
--   \LParamT -> Body : BodyT:
--     LParamT <=> ParamT
--     BodyT <=> ResultT
--     Recurse-Subst Body Apply Arg
--   Other -> Copy (Func Arg) to Apply
--
-- Where Recurse-Subst PreSubst PostSubst Arg
--   Recurse over PreSubst and PostSubst together:
--     When PostSubst part is hole:
--       Replace it with structure from PreSubst and resume recursion
--     When PreSubst part refers to its param:
--       PostSubst part <=> Arg

data ApplyComponents = ApplyComponents
  { _acApply :: TypedValue
  , _acFunc :: TypedValue
  , _acArg :: TypedValue
  }

-- LambdaOrPi Rule:
-- Each of expr parts:
--   Part <=> Stored

data LambdaComponents = LambdaComponents
  { _lcParent :: Ref
  , _lcParamType :: Ref
  , _lcResult :: Ref
  }

-- Union rule (type of get param, but also for recursive type)

data Rule
  = RuleSimpleType TypedValue
  | RuleUnion Ref Ref
  | RuleLambdaStructure LambdaComponents
  | RulePiStructure LambdaComponents
  | RuleApply ApplyComponents

type Conflict = Data.PureGuidExpression

data RefData = RefData
  { _rExpression :: Data.PureGuidExpression
  , _rRules :: [Rule]
  , _rErrors :: [Conflict]
  }
LensTH.makeLenses ''RefData

hole :: Data.PureGuidExpression
hole = Data.pureGuidExpression (Guid.fromString "HoleyHole") Data.ExpressionHole

setExpr :: Data.PureGuidExpression
setExpr = Data.pureGuidExpression (Guid.fromString "SettySet") Data.ExpressionSet

emptyRefData :: RefData
emptyRefData = RefData
  { _rExpression = hole
  , _rRules = []
  , _rErrors = []
  }

type RefMap = IntMap RefData
data InferState = InferState
  { _sRefMap :: RefMap
  , _sTouchedRefs :: IntSet
  }
LensTH.makeLenses ''InferState

data StoredExpression m = StoredExpression
  { _eProp :: Data.ExpressionIRefProperty m
  , _eValue :: Data.Expression (StoredExpression m)
  , _eInferred :: TypedValue
  }
LensTH.makeLenses ''StoredExpression

instance Show (StoredExpression s) where
  show (StoredExpression prop value inferred) =
    unwords
    [ "("
    , show (Data.eipGuid prop), ":"
    , show value, "="
    , show inferred
    , ")"
    ]

toPureExpression ::
  Monad m => StoredExpression m -> Data.PureGuidExpression
toPureExpression expr =
  Data.pureGuidExpression
  (Data.eipGuid (expr ^. eProp)) .
  fmap toPureExpression $ expr ^. eValue

type T = Transaction ViewTag

-- Initial Pass:
-- Get Definitions expand to their types and values.
-- Use expression's structures except for Apply.
--   (because an Apply can result in something else
--    but for example an Int or Lambda stays the same)
-- Add SimpleType, Apply, LambdaOrPi, Union rules
-- Param types of Lambdas and Pis are of type Set
-- Pi result type is of type Set

type ExpressionTop = Data.Expression ()

makeExpressionTop :: Data.Expression a -> ExpressionTop
makeExpressionTop = fmap $ const ()

-- Map from params to their Param type,
-- also including the recursive ref to the definition.
-- (hence not just parameters)
type Scope = Map Data.VariableRef Ref

-- Initial expression for inferred value and type of a stored entity.
-- Types are returned only in cases of expanding definitions.
initialExprs ::
  Monad m =>
  Scope -> DataLoad.ExpressionEntity (T m) ->
  T m (Data.PureGuidExpression, Data.PureGuidExpression)
initialExprs scope entity =
  (liftM . first)
  (Data.pureGuidExpression (DataLoad.entityGuid entity)) $
  case exprStructure of
  Data.ExpressionApply _ -> return (Data.ExpressionHole, hole)
  Data.ExpressionGetVariable var@(Data.DefinitionRef ref)
    | not (Map.member var scope) ->
      liftM ((,) exprStructure) $ DataLoad.loadPureDefinitionType ref
  _ -> return (exprStructure, hole)
  where
    exprStructure = fmap (const hole) $ DataLoad.entityValue entity

intMapMod :: Functor f => Int -> (v -> f v) -> (IntMap v -> f (IntMap v))
intMapMod k =
  IntMapLens.at k .
  Lens.iso from Just
  where
    from = fromMaybe . error $ unwords ["intMapMod: key", show k, "not in map"]

refMapMod :: Functor f => Ref -> (RefData -> f RefData) -> (InferState -> f InferState)
refMapMod k = sRefMap . intMapMod (unRef k)

mergeExprs ::
  Data.PureGuidExpression ->
  Data.PureGuidExpression ->
  Maybe Data.PureGuidExpression
mergeExprs
  p0@(Data.PureGuidExpression (Data.GuidExpression _ e0))
  p1@(Data.PureGuidExpression (Data.GuidExpression _ e1)) =
  case (e0, e1) of
  (Data.ExpressionHole, _) -> Just p1
  (_, Data.ExpressionHole) -> Just p0
  -- TODO
  _ -> undefined

setRefExpr ::
  MonadState InferState m =>
  Data.PureGuidExpression -> Ref -> m ()
setRefExpr newExpr ref = do
  curExpr <- Lens.use $ refMapMod ref . rExpression
  case mergeExprs curExpr newExpr of
    Just mergedExpr ->
      when (mergedExpr /= curExpr) $ do
        sTouchedRefs . IntSetLens.contains (unRef ref) .= True
        refMapMod ref . rExpression .= mergedExpr
    Nothing -> refMapMod ref . rErrors %= (newExpr :)

addRules ::
  (MonadState InferState m, MonadReader Scope m) =>
  TypedValue -> Data.Expression TypedValue -> m ()
addRules typedVal expr = do
  refMapMod (tvVal typedVal) . rRules %= (RuleSimpleType typedVal :)
  case expr of
    Data.ExpressionPi lambda@(Data.Lambda _ resultType) ->
      onLambda RulePiStructure lambda
    Data.ExpressionLambda lambda ->
      onLambda RuleLambdaStructure lambda
    Data.ExpressionApply (Data.Apply func arg) ->
      addRuleToMany ([tvVal, tvType] <*> [typedVal, func, arg]) .
        RuleApply $ ApplyComponents typedVal func arg
    Data.ExpressionGetVariable var -> do
      mTypeRef <- Reader.asks $ Map.lookup var
      case mTypeRef of
        Nothing -> return ()
        Just ref ->
          refMapMod ref . rRules %= (RuleUnion ref (tvType typedVal) :)
    _ -> return ()
  where
    addRule rule ref =
      refMapMod ref . rRules %= (rule :)
    addRuleToMany refs rule = mapM_ (addRule rule) refs
    onLambda cons lambda@(Data.Lambda paramType result) =
      addRuleToMany [tvVal typedVal, tvVal paramType, tvVal result] .
      cons $ LambdaComponents (tvVal typedVal) (tvVal paramType) (tvVal result)

fromLoaded ::
  Monad m =>
  Maybe Data.DefinitionIRef ->
  DataLoad.ExpressionEntity (T m) -> T m (StoredExpression (T m), InferState)
fromLoaded mRecursiveIRef rootEntity =
  (`runStateT` InferState mempty mempty) .
  (`runReaderT` mempty) $ do
    rootTv <- createTypedVal
    Reader.local
      ( case mRecursiveIRef of
        Nothing -> id
        Just iref -> Map.insert (Data.DefinitionRef iref) (tvType rootTv)
      ) $
      processNode rootEntity rootTv
  where
    createTypedVal = do
      valRef <- createRef
      typeRef <- createRef
      return $ TypedValue valRef typeRef
    createRef = do
      key <- liftM IntMap.size $ Lens.use sRefMap
      sRefMap . IntMapLens.at key .= Just emptyRefData
      return $ Ref key
    transaction = lift . lift
    addTypedVal x =
      liftM ((,) x) createTypedVal
    processNode entity typedValue = do
      (initialVal, initialType) <- do
        scope <- Reader.ask
        transaction $ initialExprs scope entity
      setRefExpr initialVal $ tvVal typedValue
      setRefExpr initialType $ tvType typedValue
      withChildrenTvs <-
        Traversable.mapM addTypedVal $ DataLoad.entityValue entity
      addRules typedValue $ fmap snd withChildrenTvs
      let
        onLambda (Data.Lambda paramType@(_, paramTypeTv) result) = do
          setRefExpr setExpr $ tvType paramTypeTv
          paramTypeR <- uncurry processNode paramType
          let paramRef = Data.ParameterRef $ DataLoad.entityGuid entity
          resultR <-
            Reader.local (Map.insert paramRef (tvVal paramTypeTv)) $
            uncurry processNode result
          return $ Data.Lambda paramTypeR resultR
      expr <-
        case withChildrenTvs of
        Data.ExpressionLambda lambda ->
          liftM Data.ExpressionLambda $ onLambda lambda
        Data.ExpressionPi lambda@(Data.Lambda _ (_, resultTypeTv)) -> do
          setRefExpr setExpr $ tvType resultTypeTv
          liftM Data.ExpressionPi $ onLambda lambda
        _ ->
          Traversable.mapM (uncurry processNode) withChildrenTvs
      return $ StoredExpression (DataLoad.entityStored entity) expr typedValue
