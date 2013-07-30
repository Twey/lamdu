{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Data.Infer.Rule.Internal
  ( RuleRef
  , GetFieldPhase0(..), gf0GetFieldTag, gf0GetFieldType
  , GetFieldPhase1(..), gf1GetFieldRecordTypeFields, gf1GetFieldType
  , GetFieldPhase2(..), gf2Tag, gf2TagRef, gf2TypeRef, gf2MaybeMatchers
  , Rule(..), ruleTriggersIn, ruleContent
    , ruleRefs
  , RuleContent(..)
  , RuleMap(..), rmMap
    , new, verifyTagId
    , initialRuleMap
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad.Trans.State (StateT, runState)
import Control.MonadA (MonadA)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Lamdu.Data.Infer.RefTags (ExprRef, TagExpr, RuleRef, TagRule)
import qualified Control.Lens as Lens
import qualified Data.OpaqueRef as OR

data RuleMap def = RuleMap
  { _rmFresh :: OR.Fresh (TagRule def)
  , _rmMap :: OR.RefMap (TagRule def) (Rule def)
  }

-- We know of a GetField, waiting to know the record type:
data GetFieldPhase0 def = GetFieldPhase0
  { _gf0GetFieldTag :: ExprRef def
  , _gf0GetFieldType :: ExprRef def
  -- trigger on record type, no need for Ref
  }

-- We know of a GetField and the record type, waiting to know the
-- GetField tag:
data GetFieldPhase1 def = GetFieldPhase1
  { _gf1GetFieldRecordTypeFields :: [(ExprRef def, ExprRef def)]
  , _gf1GetFieldType :: ExprRef def
  -- trigger on getfield tag, no need for Ref
  }

-- We know of a GetField and the record type, waiting to know the
-- GetField tag (trigger on getfield tag):
data GetFieldPhase2 def = GetFieldPhase2
  { _gf2Tag :: Guid
  , _gf2TagRef :: ExprRef def
  , _gf2TypeRef :: ExprRef def
  , -- Maps Refs of tags to Refs of their field types
    _gf2MaybeMatchers :: OR.RefMap (TagExpr def) (ExprRef def)
  }

data Rule def = Rule
  { _ruleTriggersIn :: OR.RefSet (TagExpr def)
  , _ruleContent :: RuleContent def
  }

data RuleContent def
  = RuleVerifyTag
  | RuleGetFieldPhase0 (GetFieldPhase0 def)
  | RuleGetFieldPhase1 (GetFieldPhase1 def)
  | RuleGetFieldPhase2 (GetFieldPhase2 def)

Lens.makeLenses ''RuleMap
Lens.makeLenses ''GetFieldPhase0
Lens.makeLenses ''GetFieldPhase1
Lens.makeLenses ''GetFieldPhase2
Lens.makeLenses ''Rule

gf0Refs :: Lens.Traversal' (GetFieldPhase0 def) (ExprRef def)
gf0Refs f (GetFieldPhase0 tag typ) =
  GetFieldPhase0 <$> f tag <*> f typ

gf1Refs :: Lens.Traversal' (GetFieldPhase1 def) (ExprRef def)
gf1Refs f (GetFieldPhase1 rFields typ) =
  GetFieldPhase1 <$> (Lens.traverse . Lens.both) f rFields <*> f typ

gf2Refs :: Lens.Traversal' (GetFieldPhase2 def) (ExprRef def)
gf2Refs f (GetFieldPhase2 tag tagRef typeRef mMatchers) =
  GetFieldPhase2 tag <$> f tagRef <*> f typeRef <*>
  (mMatchers & OR.unsafeRefMapItems . Lens.both %%~ f)

ruleContentRefs :: Lens.Traversal' (RuleContent def) (ExprRef def)
ruleContentRefs _ RuleVerifyTag = pure RuleVerifyTag
ruleContentRefs f (RuleGetFieldPhase0 x) = RuleGetFieldPhase0 <$> gf0Refs f x
ruleContentRefs f (RuleGetFieldPhase1 x) = RuleGetFieldPhase1 <$> gf1Refs f x
ruleContentRefs f (RuleGetFieldPhase2 x) = RuleGetFieldPhase2 <$> gf2Refs f x

ruleRefs :: Lens.Traversal' (Rule def) (ExprRef def)
ruleRefs f (Rule triggers content) =
  Rule
  <$> OR.unsafeRefSetKeys f triggers
  <*> ruleContentRefs f content

new :: MonadA m => RuleContent def -> StateT (RuleMap def) m (RuleRef def)
new rule = do
  ruleId <- Lens.zoom rmFresh OR.freshRef
  rmMap . Lens.at ruleId .= Just (Rule mempty rule)
  return ruleId

verifyTagId :: RuleRef def
initialRuleMap :: RuleMap def
(verifyTagId, initialRuleMap) =
  runState (new RuleVerifyTag)
  RuleMap
  { _rmFresh = OR.initialFresh
  , _rmMap = mempty
  }
