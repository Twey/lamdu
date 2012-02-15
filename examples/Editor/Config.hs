{-# OPTIONS -fno-warn-missing-signatures #-}

module Editor.Config where

import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

mk = E.KeyEventType

noMods = mk E.noMods
ctrl = mk E.ctrl . E.charKey
alt = mk E.alt . E.charKey
ctrlAlt = mk (E.noMods {E.modCtrl = True, E.modAlt = True}) . E.charKey
-- altShift = mk E.noMods { E.modAlt = True, E.modShift = True } . E.charKey
k = noMods . E.charKey

-- pasteKeys         = [ctrl 'v']
-- cutKeys           = [ctrl 'x']

-- actionKeys        = [noMods E.KeyEnter]

quitKeys          = [ctrl 'q']
undoKeys          = [ctrl 'z']
redoKeys          = [ctrl 'y']
makeBranchKeys    = [ctrl 's']

-- moveToParentKeys  = [mk E.alt E.KeyLeft]

overlayDocKeys    = [noMods E.KeyF1, alt 'h']

addParamKeys      = [alt 'p']

delBranchKeys     = [alt 'o']

closePaneKeys     = [alt 'w']

relinkKeys        = [alt 'r']

pickResultKeys    = [noMods E.KeyEnter]
jumpToDefinitionKeys  = [noMods E.KeyEnter]
delKeys           = [noMods E.KeyBackspace, noMods E.KeyDel, mk E.alt E.KeyDel]
giveAsArgumentKeys = [k '[']
callWithArgumentKeys = [k ']']
addNextArgumentKeys = [E.KeyEventType E.noMods E.KeySpace]
debugModeKeys = [ctrlAlt 'd']

exprFocusDelegatorKeys = FocusDelegator.Keys {
  FocusDelegator.startDelegatingKey = mk E.shift E.KeyRight,
  FocusDelegator.stopDelegatingKey = mk E.shift E.KeyLeft
  }

newDefinitionKeys = [alt 'n']

builtinColor = Draw.Color 1 0.6 0.2 1
definitionColor = Draw.Color 1 1 1 1
parameterColor = Draw.Color 0.2 0.8 0.9 1

literalIntColor = Draw.Color 0 1 0 1

previousCursor = [mk E.alt E.KeyLeft]
