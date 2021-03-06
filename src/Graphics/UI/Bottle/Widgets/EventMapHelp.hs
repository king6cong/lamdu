{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, DeriveFunctor #-}
module Graphics.UI.Bottle.Widgets.EventMapHelp
    ( makeView
    , IsHelpShown(..)
    , makeToggledHelpAdder
    , Config(..), defaultConfig
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.IO.Class (MonadIO(..))
import           Data.Function (on)
import           Data.IORef (newIORef, readIORef, modifyIORef)
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Tuple as Tuple
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import           Graphics.UI.Bottle.Animation (AnimId, R)
import qualified Graphics.UI.Bottle.Animation as Anim
import           Graphics.UI.Bottle.EventMap (EventMap)
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.MetaKey (MetaKey(..), toModKey, noMods)
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import qualified Graphics.UI.Bottle.ModKey as ModKey
import           Graphics.UI.Bottle.View (View(..))
import qualified Graphics.UI.Bottle.View as View
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.GridView as GridView
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer
import qualified Graphics.UI.Bottle.Widgets.TextView as TextView
import qualified Graphics.UI.GLFW as GLFW

import           Lamdu.Prelude

data Config = Config
    { configStyle :: TextView.Style
    , configInputDocColor :: Draw.Color
    , configBGColor :: Draw.Color
    , configOverlayDocKeys :: [MetaKey]
    , configTint :: Draw.Color
    }

defaultConfig :: Draw.Font -> Config
defaultConfig font =
    Config
    { configStyle =
        TextView.Style
        { TextView._styleColor = Draw.Color 1 1 1 1
        , TextView._styleFont = font
        , TextView._styleUnderline = Nothing
        }
    , configInputDocColor = Draw.Color 0.1 0.7 0.7 1
    , configBGColor = Draw.Color 0.2 0.15 0.1 0.5
    , configOverlayDocKeys = [MetaKey noMods GLFW.Key'F1]
    , configTint = Draw.Color 1 1 1 0.8
    }

data Tree n l = Leaf l | Branch n [Tree n l]
    deriving (Eq, Ord, Show, Functor)

bitraverseTree :: Applicative f => (n0 -> f n1) -> (l0 -> f l1) -> Tree n0 l0 -> f (Tree n1 l1)
bitraverseTree _ onLeaf (Leaf l) = Leaf <$> onLeaf l
bitraverseTree onNode onLeaf (Branch n ts) = Branch <$> onNode n <*> traverse (bitraverseTree onNode onLeaf) ts

treeNodes :: Lens.Traversal (Tree n0 l) (Tree n1 l) n0 n1
treeNodes = (`bitraverseTree` pure)

groupTree :: Eq node => [([node], leaf)] -> [Tree node leaf]
groupTree = foldr step []
    where
        step ([], l) rest = Leaf l : rest
        step (at:as, l) b =
            case b of
                Branch bt bs : rest
                    | at == bt -> Branch bt (step (as, l) bs) : rest
                _ -> Branch at (step (as, l) []) : b

-- We also rely on Map.toList returning a sorted list
groupInputDocs :: [([E.Subtitle], E.InputDoc)] -> [([E.Subtitle], [E.InputDoc])]
groupInputDocs = Map.toList . Map.fromListWith (++) . (Lens.traversed . _2 %~) (:[])

addAnimIds :: (Show a, Show b) => AnimId -> Tree a b -> Tree (AnimId, a) (AnimId, b)
addAnimIds animId (Leaf b) = Leaf (animId ++ ["leaf"], b)
addAnimIds animId (Branch a cs) =
    Branch (tAnimId, a) $ map (addAnimIds tAnimId) cs
    where
        tAnimId = Anim.augmentId animId a

makeShortcutKeyView ::
    Config -> (AnimId, [E.InputDoc]) -> View
makeShortcutKeyView config (animId, inputDocs) =
    inputDocs
    <&> flip (TextView.makeLabel style) animId . mappend " "
    & GridView.verticalAlign 1
    where
        style =
            configStyle config
            & TextView.styleColor .~ configInputDocColor config

makeTextViews ::
    Config -> AnimId ->
    Tree E.Subtitle [E.InputDoc] ->
    Tree View View
makeTextViews config =
    fmap
    ( (treeNodes %~ uncurry (flip (TextView.makeLabel (configStyle config))))
    . fmap (makeShortcutKeyView config)
    ) . addAnimIds

columns :: R -> (a -> R) -> [a] -> [[a]]
columns maxHeight itemHeight =
    combine . foldr step (0, [], [])
    where
        combine (_, curColumn, doneColumns) = curColumn : doneColumns
        step new (curColumnHeight, curColumn, doneColumns)
            | newHeight + curColumnHeight > maxHeight =
                (newHeight, [new], curColumn : doneColumns)
            | otherwise =
                (newHeight + curColumnHeight, new : curColumn, doneColumns)
            where
                newHeight = itemHeight new

makeView :: Vector2 R -> EventMap a -> Config -> AnimId -> View
makeView size eventMap config animId =
    eventMap ^.. E.emDocs . Lens.withIndex
    <&> (_1 %~ (^. E.docStrs)) . Tuple.swap
    & groupInputDocs & groupTree
    <&> makeTextViews config animId
    & makeTreeView config size

makeTooltip :: Config -> [ModKey] -> AnimId -> View
makeTooltip config helpKeys animId =
    GridView.horizontalAlign 0
    [ TextView.makeLabel (configStyle config) "Show help" animId
    , makeShortcutKeyView config
        (animId ++ ["HelpKeys"], map ModKey.pretty helpKeys)
    ]

indent :: R -> View -> View
indent width x =
    GridView.horizontalAlign 0 [Spacer.makeHorizontal width, x]

makeTreeView :: Config -> Vector2 R -> [Tree View View] -> View
makeTreeView config size =
    GridView.horizontalAlign 1 .
    List.intersperse (Spacer.makeHorizontal indentWidth) .
    fmap (GridView.make . map toRow) .
    columns (size ^. _2) pairHeight .
    handleResult . go
    where
        toRow (titleView, docView) =
            [(0, titleView), (GridView.Alignment (Vector2 1 0), docView)]
        pairHeight (titleView, docView) = (max `on` (^. View.height)) titleView docView
        handleResult (pairs, []) = pairs
        handleResult _ = error "Leafs at root of tree!"
        go = mconcat . map fromTree
        fromTree (Leaf inputDocsView) = ([], [inputDocsView])
        fromTree (Branch titleView trees) =
            ( (titleView, GridView.verticalAlign 1 inputDocs) :
                (Lens.traversed . _1 %~ indent indentWidth) titles
            , [] )
            where
                (titles, inputDocs) = go trees
        indentWidth =
            configStyle config ^. TextView.styleFont & Draw.fontHeight

addToBottomRight :: View -> Widget.Size -> Widget f -> Widget f
addToBottomRight (View eventMapSize eventMapLayers) size =
    Widget.view . View.animLayers . View.layers <>~ docLayers ^. View.layers
    where
        docLayers =
            eventMapLayers
            & View.layers . traverse %~ Anim.translate (size - eventMapSize)

data IsHelpShown = HelpShown | HelpNotShown
    deriving (Eq, Ord, Read, Show)

toggle :: IsHelpShown -> IsHelpShown
toggle HelpShown = HelpNotShown
toggle HelpNotShown = HelpShown

makeToggledHelpAdder ::
    MonadIO m =>
    IsHelpShown ->
    IO
    (Config -> Widget.Size ->
     Widget (m Widget.EventResult) ->
     IO (Widget (m Widget.EventResult)))
makeToggledHelpAdder startValue =
    do
        showingHelpVar <- newIORef startValue
        return $ \config size widget ->
            do
                unless (Widget.isFocused widget) (fail "adding help to non-focused root widget!")
                showingHelp <- readIORef showingHelpVar & liftIO
                let (helpView, docStr) =
                        case showingHelp of
                        HelpShown ->
                            ( makeView size (widget ^. Widget.eventMap) config
                              animId
                            , "Hide"
                            )
                        HelpNotShown ->
                            ( makeTooltip config (configOverlayDocKeys config <&> toModKey) animId
                            , "Show"
                            )
                let toggleEventMap =
                        Widget.keysEventMap (configOverlayDocKeys config)
                        (E.Doc ["Help", "Key Bindings", docStr]) $
                        liftIO $ modifyIORef showingHelpVar toggle
                let bgHelpView =
                        helpView
                        & View.backgroundColor animId (configBGColor config)
                        & View.tint (configTint config)
                return . addToBottomRight bgHelpView size $
                    Widget.strongerEvents toggleEventMap widget
    where
        animId = ["help box"]
