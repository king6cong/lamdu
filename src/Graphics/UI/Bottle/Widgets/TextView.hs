{-# LANGUAGE NoImplicitPrelude, BangPatterns, RecordWildCards, TemplateHaskell, OverloadedStrings #-}
module Graphics.UI.Bottle.Widgets.TextView
    ( Font.Underline(..), Font.underlineColor, Font.underlineWidth
    , Style(..), styleColor, styleFont, styleUnderline, whiteText
    , color, font, underline
    , lineHeight
    , HasStyle(..)

    , make, makeWidget, makeLabel, makeFocusable
    , RenderedText(..), renderedTextSize
    , drawText
    , letterRects
    ) where

import qualified Control.Lens as Lens
import qualified Data.Text as Text
import           Data.Text.Encoding (encodeUtf8)
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import           Graphics.UI.Bottle.Animation (AnimId, Size)
import qualified Graphics.UI.Bottle.Animation as Anim
import           Graphics.UI.Bottle.Font (TextSize(..))
import qualified Graphics.UI.Bottle.Font as Font
import           Graphics.UI.Bottle.Rect (Rect(Rect))
import qualified Graphics.UI.Bottle.Rect as Rect
import           Graphics.UI.Bottle.View (View(..))
import qualified Graphics.UI.Bottle.View as View
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget

import           Lamdu.Prelude

data Style = Style
    { _styleColor :: Draw.Color
    , _styleFont :: Draw.Font
    , _styleUnderline :: Maybe Font.Underline
    }
Lens.makeLenses ''Style

class HasStyle env where style :: Lens' env Style
instance HasStyle Style where style = id

underline :: HasStyle env => Lens' env (Maybe Font.Underline)
underline = style . styleUnderline

font :: HasStyle env => Lens' env Draw.Font
font = style . styleFont

color :: HasStyle env => Lens' env Draw.Color
color = style . styleColor

whiteText :: Draw.Font -> Style
whiteText f =
    Style
    { _styleColor = Draw.Color 1 1 1 1
    , _styleFont = f
    , _styleUnderline = Nothing
    }

lineHeight :: Style -> Widget.R
lineHeight Style{..} = Font.height _styleFont

data RenderedText a = RenderedText
    { _renderedTextSize :: TextSize Size
    , renderedText :: a
    }
Lens.makeLenses ''RenderedText

fontRender :: Style -> Text -> RenderedText (Draw.Image ())
fontRender Style{..} str =
    Font.render _styleFont _styleColor _styleUnderline str
    & uncurry RenderedText

nestedFrame ::
    Show a =>
    Style ->
    (a, RenderedText (Draw.Image ())) -> RenderedText (AnimId -> Anim.Frame)
nestedFrame s (i, RenderedText size img) =
    RenderedText size draw
    where
        draw animId =
            Anim.sizedFrame (Anim.augmentId animId i) anchorSize img
        anchorSize = pure (lineHeight s)

-- | Returns at least one rect
letterRects :: Style -> Text -> [[Rect]]
letterRects Style{..} text =
    zipWith locateLineHeight (iterate (+ height) 0) textLines
    where
        -- splitOn returns at least one string:
        textLines = map makeLine $ Text.splitOn "\n" text
        locateLineHeight y = Lens.mapped . Rect.top +~ y
        height = Font.height _styleFont
        makeLine textLine =
            sizes
            <&> fmap (^. _1)
            -- scanl returns at least one element:
            & scanl (+) 0
            & zipWith makeLetterRect sizes
            where
                sizes =
                    Text.unpack textLine
                    <&> Font.textSize _styleFont . Text.singleton
                makeLetterRect size xpos =
                    Rect (Vector2 (advance xpos) 0) (bounding size)

drawText ::
    (MonadReader env m, HasStyle env) =>
    m (Text -> RenderedText (AnimId -> Anim.Frame))
drawText =
    do
        s <- Lens.view style
        pure $ \text -> nestedFrame s ("text" :: Text, fontRender s text)

make ::
    (MonadReader env m, HasStyle env) =>
    m (Text -> AnimId -> View)
make =
    do
        draw <- drawText
        pure $ \text animId ->
            let RenderedText textSize frame = draw text
            in View.make (bounding textSize) (frame animId)

makeWidget ::
    (MonadReader env m, HasStyle env) =>
    m (Text -> AnimId -> Widget a)
makeWidget = make <&> Lens.mapped . Lens.mapped %~ Widget.fromView

makeLabel ::
    (MonadReader env m, HasStyle env) =>
    m (Text -> AnimId -> View)
makeLabel = make <&> \mk text prefix -> mk text $ mappend prefix [encodeUtf8 text]

makeFocusable ::
    (MonadReader env m, Applicative f, Widget.HasCursor env, HasStyle env) =>
    m (Text -> Widget.Id -> Widget (f Widget.EventResult))
makeFocusable =
    do
        toFocusable <- Widget.makeFocusableView
        mkText <- make
        pure $ \text myId ->
            mkText text (Widget.toAnimId myId)
            & Widget.fromView & toFocusable myId
