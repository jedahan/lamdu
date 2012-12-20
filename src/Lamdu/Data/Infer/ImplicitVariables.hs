{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TemplateHaskell #-}
module Lamdu.Data.Infer.ImplicitVariables
  ( addVariables, Payload(..)
  ) where

import Control.Applicative ((<$>))
import Control.Lens ((^.))
import Control.Monad.Trans.State (StateT, State, mapStateT)
import Control.Monad.Trans.State.Utils (toStateT)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..), getWord8, putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Functor.Identity (Identity(..))
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty)
import Data.Store.Guid (Guid)
import Data.Typeable (Typeable)
import Lamdu.Data.Infer.UntilConflict (inferAssertNoConflict)
import System.Random (RandomGen, random)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Store.Guid as Guid
import qualified Lamdu.Data as Data
import qualified Lamdu.Data.Infer as Infer

data Payload a = Stored a | AutoGen Guid
  deriving (Eq, Ord, Show, Functor, Typeable)
derive makeBinary ''Payload

isUnrestrictedHole :: Data.Expression def Infer.IsRestrictedPoly -> Bool
isUnrestrictedHole
  (Data.Expression
    (Data.ExpressionLeaf Data.Hole)
    Infer.UnrestrictedPoly) = True
isUnrestrictedHole _ = False

addVariablesGen ::
  (Ord def, RandomGen g) => g ->
  Data.Expression def (Infer.Inferred def, Payload a) ->
  State (Infer.Context def) (Data.Expression def (Infer.Inferred def, Payload a))
addVariablesGen gen expr =
  case unrestrictedHoles of
  [] -> return expr
  (hole : _) -> do
    paramTypeTypeRef <- Infer.createRefExpr
    let
      holePoint = Infer.iPoint . fst $ hole ^. Data.ePayload
      loaded =
        fromMaybe (error "Should not be loading defs when loading a mere getVar") $
        Infer.load loader Nothing getVar
    inferredGetVar <- inferAssertNoConflict loaded holePoint
    let
      dependsOnVars =
        Lens.notNullOf
        ( Data.ePayload . Lens._1
        . Lens.to Infer.iType . Lens.folding Data.subExpressions
        . Data.eValue . Data.expressionLeaf
        . Data.getVariable . Data.parameterRef
        ) inferredGetVar
    if dependsOnVars
      then return expr
      else do
        newRootNode <- Infer.newNodeWithScope mempty
        let
          paramTypeRef = Infer.tvType $ Infer.nRefs holePoint
          paramTypeNode =
            Infer.InferNode (Infer.TypedValue paramTypeRef paramTypeTypeRef) mempty
          paramTypeExpr =
            Data.Expression
            (Data.ExpressionLeaf Data.Hole)
            (paramTypeNode, AutoGen (Guid.augment "paramType" paramGuid))
          newRootLam = Data.makeLambda paramGuid paramTypeExpr $ Lens.over (Lens.mapped . Lens._1) Infer.iPoint expr
          newRootExpr = Data.Expression newRootLam (newRootNode, AutoGen (Guid.augment "root" paramGuid))
        unMaybe $ Infer.addRules actions [fst <$> newRootExpr]
        addVariablesGen newGen =<< State.gets (Infer.derefExpr newRootExpr)
  where
    loader = Infer.Loader $ const Nothing
    unrestrictedHoles =
      filter (isUnrestrictedHole . Infer.iValue . fst . Lens.view Data.ePayload) .
      reverse $ Data.subExpressions =<< Data.funcArguments expr
    getVar = Data.pureExpression $ Data.makeParameterRef paramGuid
    (paramGuid, newGen) = random gen

unMaybe :: StateT s Maybe b -> StateT s Identity b
unMaybe =
  mapStateT (Identity . fromMaybe (error "Infer error when adding implicit vars!"))

-- TODO: Infer.Utils
actions :: Infer.InferActions def Maybe
actions = Infer.InferActions $ const Nothing

addVariables ::
  (MonadA m, Ord def, RandomGen g) =>
  g ->
  Data.Expression def (Infer.Inferred def, a) ->
  StateT (Infer.Context def) m
  (Data.Expression def (Infer.Inferred def, Payload a))
addVariables gen =
  toStateT .
  addVariablesGen gen .
  Lens.over (Lens.mapped . Lens._2) Stored
