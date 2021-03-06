{-# LANGUAGE NoImplicitPrelude, RecordWildCards, OverloadedStrings #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Transaction (transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widget.Aligned as AlignedWidget
import qualified Graphics.UI.Bottle.Widget.TreeLayout as TreeLayout
import qualified Lamdu.Config as Config
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import           Lamdu.GUI.ExpressionEdit.HoleEdit.Info (HoleInfo(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.SearchArea as SearchArea
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.State as HoleState
import           Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds (WidgetIds(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.Wrapper as Wrapper
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import           Lamdu.GUI.Hover (addDarkBackground)
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.Names.Types (Name(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makeWrapper ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload -> HoleInfo m ->
    ExprGuiM m (Maybe (ExpressionGui m))
makeWrapper pl holeInfo =
    hiHole holeInfo ^. Sugar.holeMArg
    & Lens._Just %%~
        \holeArg ->
        do
            (wrapper, holePicker) <-
                Wrapper.make (hiIds holeInfo) holeArg
                & ExprGuiM.listenResultPicker
            exprEventMap <- ExprEventMap.make pl holePicker
            wrapper
                & TreeLayout.widget %~ Widget.weakerEvents exprEventMap
                & return

assignHoleCursor ::
    Monad m =>
    WidgetIds -> Maybe (Sugar.HoleArg m expr) -> ExprGuiM m a -> ExprGuiM m a
assignHoleCursor WidgetIds{..} Nothing =
    Widget.assignCursor hidHole hidOpen .
    Widget.assignCursor (WidgetIds.notDelegatingId hidHole) hidClosedSearchArea
assignHoleCursor WidgetIds{..} (Just _) =
    Widget.assignCursor hidHole hidWrapper .
    Widget.assignCursor (WidgetIds.notDelegatingId hidHole) hidWrapper

addSearchAreaBelow ::
    Monad m => WidgetIds ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f -> ExpressionGui f)
addSearchAreaBelow WidgetIds{..} =
    addDarkBackground (Widget.toAnimId hidOpen ++ ["searchArea", "DarkBg"])
    <&>
    \f wrapperGui searchAreaGui ->
    ExpressionGui.vboxTopFocal [wrapperGui, f searchAreaGui]

addWrapperAbove ::
    Monad m =>
    WidgetIds -> ExprGuiM m (ExpressionGui f -> ExpressionGui f -> ExpressionGui f)
addWrapperAbove _ids =
    return $
    \wrapperGui searchAreaGui ->
    ExpressionGui.vboxTopFocal
    [ wrapperGui
    , searchAreaGui
    ]

makeHoleWithWrapper ::
    Monad m =>
    ExpressionGui f -> ExpressionGui f -> Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui f)
makeHoleWithWrapper wrapperGui searchAreaGui pl =
    do
        unfocusedWrapperGui <-
            ExpressionGui.maybeAddAnnotationPl pl ?? wrapperGui
        isSelected <- Widget.isSubCursor ?? hidHole widgetIds
        let layout f =
                do
                    lay <- f widgetIds
                    return $ TreeLayout.render #
                        \layoutMode ->
                        (layoutMode & lay
                        (wrapperGui & TreeLayout.alignment . _1 .~ 0)
                        searchAreaGui ^. TreeLayout.render)
                        `AlignedWidget.hoverInPlaceOf`
                        (layoutMode
                        & unfocusedWrapperGui ^. TreeLayout.render
                        & AlignedWidget.alignment . _1 .~ 0)
        if ExpressionGui.egIsFocused wrapperGui
            then layout addSearchAreaBelow
            else if isSelected then
                     layout addWrapperAbove
                 else
                     return unfocusedWrapperGui
    where
        widgetIds = HoleWidgetIds.make (pl ^. Sugar.plEntityId)

make ::
    Monad m =>
    Sugar.Hole (Name m) m (ExprGuiT.SugarExpr m) ->
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m)
make hole pl =
    do
        stateProp <-
            HoleState.assocStateRef (hole ^. Sugar.holeActions . Sugar.holeUUID)
            ^. Transaction.mkProperty & transaction

        let holeInfo = HoleInfo
                { hiEntityId = pl ^. Sugar.plEntityId
                , hiState = stateProp
                , hiInferredType = pl ^. Sugar.plAnnotation . Sugar.aInferredType
                , hiHole = hole
                , hiIds = widgetIds
                , hiNearestHoles = pl ^. Sugar.plData . ExprGuiT.plNearestHoles
                }

        searchAreaGui <- SearchArea.makeStdWrapped pl holeInfo
        mWrapperGui <- makeWrapper pl holeInfo

        delKeys <- ExprGuiM.readConfig <&> Config.delKeys
        let deleteEventMap =
                hole ^. Sugar.holeActions . Sugar.holeMDelete
                & maybe mempty
                    ( Widget.keysEventMapMovesCursor delKeys
                        (E.Doc ["Edit", "Delete hole"])
                        . fmap WidgetIds.fromEntityId)

        case mWrapperGui of
            Just wrapperGui -> makeHoleWithWrapper wrapperGui searchAreaGui pl
            Nothing -> return searchAreaGui
            <&> TreeLayout.widget %~ Widget.weakerEvents deleteEventMap
    & assignHoleCursor widgetIds (hole ^. Sugar.holeMArg)
    where
        widgetIds = HoleWidgetIds.make (pl ^. Sugar.plEntityId)
