#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Pixel", "Screen"
CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

; Many games (Roblox included) only reliably react to input sent via "Event" mode - it uses
; the older mouse_event/keybd_event Windows APIs, which some games' raw/DirectInput handling
; accepts where the default SendInput mode is silently ignored (menu clicks can work while
; world/game clicks don't, since those often go through a different input path).
; NOTE: "Play" mode was tried first but failed to move the cursor at all on this system -
; Event mode still uses real cursor movement, so it's the safer choice here.
SendMode "Event"
SetMouseDelay 10
SetKeyDelay 20, 20

ConfigFile := A_ScriptDir "\config.ini"
LogFile := A_ScriptDir "\macro_log.txt"

Cfg(section, key, default) {
    global ConfigFile
    return IniRead(ConfigFile, section, key, default)
}

; Robust integer parser for user-entered numeric fields (coordinates, delays, wait times, ...).
; Accepts a comma as a decimal separator (e.g. German keyboards/locale produce "0,1" instead of
; "0.1") as well as a period, trims whitespace, and falls back to `def` for anything that still
; isn't a valid number - instead of crashing the whole macro with an Integer.Call type error.
SafeInt(val, def := 0) {
    s := Trim(String(val))
    if (s = "")
        return def
    s := StrReplace(s, ",", ".")
    if !IsNumber(s)
        return def
    return Integer(Round(Number(s)))
}

; Same as SafeInt but keeps fractional values (used for wait-after times, which support decimal
; seconds, e.g. "0.5" or - once the comma is normalized to a period - "0,5").
SafeNum(val, def := 0.0) {
    s := Trim(String(val))
    if (s = "")
        return def
    s := StrReplace(s, ",", ".")
    if !IsNumber(s)
        return def
    return Number(s)
}

JoinList(arr) {
    s := ""
    for v in arr
        s .= (s = "" ? "" : ",") v
    return s
}

; ============================================================
; PER-OPTION DAILY USAGE (Option Select challenge limits)
; ============================================================
; Each option's "used today" counter is stored alongside the date it was last touched, so it
; auto-resets the first time it's read/written on a new day - no separate midnight timer needed.
TodayStamp() {
    return FormatTime(, "yyyyMMdd")
}

; Returns option i's still-valid "used today" count for the given preset ini section (0 if the
; stored count belongs to an earlier day).
GetOptionUsedToday(section, i) {
    storedDate := Cfg(section, "Option" i "UsedDate", "")
    if (storedDate != TodayStamp())
        return 0
    return SafeInt(Cfg(section, "Option" i "UsedCount", "0"))
}

SetOptionUsedToday(section, i, count) {
    global ConfigFile
    IniWrite Max(0, count), ConfigFile, section, "Option" i "UsedCount"
    IniWrite TodayStamp(), ConfigFile, section, "Option" i "UsedDate"
}

; Bumps option i's "used today" count for `presetName` by one (called once an Option Select step
; actually commits to playing that option) and returns the new count.
IncrementOptionUsed(presetName, i) {
    section := "Preset_" presetName
    newCount := GetOptionUsedToday(section, i) + 1
    SetOptionUsedToday(section, i, newCount)
    return newCount
}

; Refreshes the Preset Settings tab's "Today's Challenge Usage" rows for `name` - option names/max
; mirrored from OptData (already loaded by the time this is called from LoadPreset/SavePresetToIni),
; used-today counts read fresh from ini (auto-resetting on a new day, see GetOptionUsedToday).
LoadUsageFields(name) {
    global OptData, UsageNameTexts, UsageUsedEdits, UsageMaxEdits
    section := "Preset_" name
    Loop 3 {
        i := A_Index
        opt := OptData[i]
        try UsageNameTexts[i].Text := opt.NameEdit.Value
        try UsageUsedEdits[i].Value := GetOptionUsedToday(section, i)
        try UsageMaxEdits[i].Value := SafeInt(opt.MaxEdit.Value, 0)
    }
}

; Persists a manual edit to one of the Preset Settings tab's "used today" fields immediately -
; these are daily counters, not "click Save to keep it" config, so they save on every change.
SaveUsageFieldClick(i, ctrl, *) {
    global CurrentPresetName, UsageUsedEdits
    section := "Preset_" CurrentPresetName
    SetOptionUsedToday(section, i, SafeInt(UsageUsedEdits[i].Value, 0))
}

; Persists a manual edit to one of the Preset Settings tab's daily-limit fields immediately, and
; mirrors it into OptData's MaxEdit (the same field shown in Edit Preset > Option > Max) so both
; stay in sync regardless of which one was just edited.
SaveUsageMaxFieldClick(i, ctrl, *) {
    global CurrentPresetName, ConfigFile, OptData
    val := Max(0, SafeInt(ctrl.Value, 0))
    OptData[i].MaxEdit.Value := val
    IniWrite val, ConfigFile, "Preset_" CurrentPresetName, "Option" i "MaxUses"
}

; ============================================================
; HOVER TOOLTIPS ("?" help icons)
; ============================================================
; Adds a small gray "?" icon at the given position and shows tipText as a tooltip
; while the mouse hovers over it. Returns the created Text control.
AddHelpIcon(guiObj, x, y, tipText) {
    global HoverTooltipMap
    icon := guiObj.AddText("x" x " y" y " w16 h16 Center Border", "?")
    icon.SetFont("s8 cGray Bold")
    HoverTooltipMap[icon.Hwnd] := tipText
    return icon
}

CheckHoverTooltips() {
    global HoverTooltipMap, LastHoverHwnd
    MouseGetPos(&mx, &my, , &ctrlHwnd, 2)
    if HoverTooltipMap.Has(ctrlHwnd) {
        if (ctrlHwnd != LastHoverHwnd) {
            ToolTip(HoverTooltipMap[ctrlHwnd], mx + 16, my + 16)
            LastHoverHwnd := ctrlHwnd
        }
    } else if (LastHoverHwnd != 0) {
        ToolTip()
        LastHoverHwnd := 0
    }
}
SetTimer(CheckHoverTooltips, 100)

; ============================================================
; GLOBAL STATE
; ============================================================
Running := false
Paused := false
CaptureTarget := ""      ; "active" while a position capture is in progress
CaptureXCtrl := ""
CaptureYCtrl := ""
OptData := []             ; 3 option objects
OptionSectionControls := [] ; every control in the "challenge options" section (EditGui), shown only while editing an "Option Select" step
PlaceData := []            ; up to 10 placement objects (coords per map + custom slot override)
GeneralSlotDdls := []       ; the 10 default tower-slot dropdowns (General tab, shared across maps)
PresetNames := []          ; names of all routine presets
CurrentPresetName := ""
CurrentScreenName := ""    ; which screen is currently shown in the step editor
PresetScreens := []        ; [{Name, Steps}, ...] for the running macro, built at StartMacro time
EditGuiVisible := false    ; whether the Edit Preset window is currently shown (set by Open/CloseEditGui)
RunningPresetName := ""    ; the preset actually being executed by the running macro (set at StartMacro time)
RunningScreenName := ""    ; the screen currently executing (set by MainLoop each iteration) - used to
                             ; keep the Edit Preset window's screen/step selection following along live
MapProfileNames := []      ; names of all map profiles (one per map)
CurrentMapProfileName := ""
OverlayGuis := []          ; the 4 gray overlay bar windows
OverlayVisible := false
LockedProcess := ""        ; exe name of the window currently locked into the opening
MarkerGui := ""             ; red dot marker shown during position capture
LastDetectedMap := ""       ; map name found by the most recent "Detect Map" step (map banner is often
                             ; only visible on the selection screen, not once you're already in the round)
LogGui := ""                 ; log panel window shown in the gray area right of the game window
LogEdit := ""                 ; the read-only multi-line Edit control inside LogGui
LogLines := []                ; recent log lines (capped), mirrored into LogEdit when it exists
StatsGui := ""                ; "Application Stats" panel shown below LogGui in the same gray area
StatsCycleText := ""           ; text controls inside StatsGui, one per stat row (see RenderStatsPanel)
StatsMapText := ""
StatsScreenText := ""
StatsStepText := ""
CurrentCycleCount := 0        ; cycles completed so far this run (mirrors MainLoop's local counter)
RunningStepDescription := ""  ; "Type (Label)" of the step currently executing, for the stats panel
HoverTooltipMap := Map()      ; Hwnd -> tooltip text, for "?" help icons
LastHoverHwnd := 0            ; Hwnd currently showing its tooltip (0 = none)
MapAdvStepsDoneThisCycle := false ; the map's Drag/Zoom Out actions run at most once per cycle,
                                   ; reset whenever a "Detect Map" step runs again (new round)
UsageNameTexts := []          ; Preset Settings tab: option name labels (mirror OptData's NameEdit)
UsageUsedEdits := []          ; Preset Settings tab: editable "used today" count per option
UsageMaxEdits := []           ; Preset Settings tab: editable daily limit per option (mirrors/writes OptData's MaxEdit)
DisconnectRestartPending := false ; set by CheckDisconnectTick when a disconnect was found; StartMacro loops back
                                   ; to the beginning of the current preset (once MainLoop returns) when this is true
DisconnectCheckBusy := false      ; guards against an overlapping disconnect OCR scan if one ever takes longer than the timer period
DisconnectLastCheckTick := 0      ; A_TickCount of the last disconnect OCR scan, used to honor the configurable check interval

; ============================================================
; BUILD GUI
; ============================================================
MyGui := Gui("+Resize", "Tower Defense Macro")
MyGui.SetFont("s10")

tab := MyGui.AddTab3("x10 y10 w800 h700", ["Preset Settings", "Map Placement", "General"])

; ---------------- TAB 1: PRESET SETTINGS (options + preset selector) ----------------
tab.UseTab(1)

; --- preset list (scrollable) + management ---
MyGui.AddText("x30 y65", "Presets:")
AddHelpIcon(MyGui, 90, 63, "Presets are step sequences (e.g. 'Challenges'). Select one below - its options, default map, and steps all belong to it.")
presetListBox := MyGui.AddListBox("x30 y85 w300 h100 VScroll")
presetListBox.OnEvent("Change", (*) => PresetListChanged())

MyGui.AddButton("x340 y85 w130", "New").OnEvent("Click", (*) => NewPresetClick())
MyGui.AddButton("x340 y117 w130", "Rename").OnEvent("Click", (*) => RenamePresetClick())
MyGui.AddButton("x340 y149 w130", "Delete").OnEvent("Click", (*) => DeletePresetClick())
MyGui.AddButton("x340 y181 w130", "Edit").OnEvent("Click", (*) => OpenEditGui())

; --- today's usage per challenge option: how many times each option has already been played
; today, against its daily limit. Both numbers are directly editable here (as well as the limit
; being editable in Edit Preset > Option > Max - the two stay in sync either way). Usage auto-
; increments as the macro plays an option and auto-resets on a new day; both fields can be
; corrected by hand at any time (e.g. if some runs happened outside the macro, or to change the
; limit without opening Edit Preset). ---
MyGui.AddGroupBox("x30 y225 w470 h150", "Today's Challenge Usage")
Loop 3 {
    i := A_Index
    rowY := 255 + (i - 1) * 35
    UsageNameTexts.Push(MyGui.AddText("x50 y" (rowY + 4) " w130", "Option " i))
    usedEdit := MyGui.AddEdit("x190 y" rowY " w45", "0")
    usedEdit.OnEvent("Change", SaveUsageFieldClick.Bind(i))
    UsageUsedEdits.Push(usedEdit)
    MyGui.AddText("x240 y" (rowY + 4) " w12", "/")
    maxEdit2 := MyGui.AddEdit("x255 y" rowY " w45", "0")
    maxEdit2.OnEvent("Change", SaveUsageMaxFieldClick.Bind(i))
    UsageMaxEdits.Push(maxEdit2)
    MyGui.AddText("x310 y" (rowY + 4) " w170", "today (0 = unlimited)")
}
AddHelpIcon(MyGui, 458, 233, "How many times each challenge option has already been played today, against its daily limit. Both numbers are directly editable here (the daily limit is also editable in 'Edit' > Option > Max - either one stays in sync with the other). 'Used' counts up automatically as the macro runs and resets automatically every day.")

; ---------------- TAB 2: PLACEMENT ----------------
tab.UseTab(2)
MyGui.AddText("x30 y50", "Map Profile:")
mapProfileDdl := MyGui.AddDropDownList("x110 y47 w180")
MyGui.AddButton("x300 y46 w70", "New").OnEvent("Click", (*) => NewMapProfileClick())
MyGui.AddButton("x375 y46 w70", "Rename").OnEvent("Click", (*) => RenameMapProfileClick())
MyGui.AddButton("x450 y46 w70", "Delete").OnEvent("Click", (*) => DeleteMapProfileClick())

MyGui.AddText("x30 y82", "Expected Map Text:")
mapExpectedTextEdit := MyGui.AddEdit("x160 y79 w300", "")
AddHelpIcon(MyGui, 465, 79, "The map name is read via OCR from the Map Text Region (set in the Detection (OCR) tab) and matched against this text.")

mapCustomTowersChk := MyGui.AddCheckBox("x30 y148 w260", "Use custom tower slots for this map")
customSlotLabels := []
customSlotDdls := []
Loop 10 {
    i := A_Index
    xBase := 300 + (i - 1) * 45
    lbl := MyGui.AddText("x" xBase " y148 w40 Center", i)
    ddl := MyGui.AddDropDownList("x" xBase " y165 w40", ["1","2","3","4","5","6"])
    ddl.Text := "1"
    customSlotLabels.Push(lbl)
    customSlotDdls.Push(ddl)
}

AddHelpIcon(MyGui, 30, 172, "When unchecked, the default slot sequence from the General tab is used for every map.")

MyGui.AddText("x30 y225", "Coordinates for this map's tower placements:")

placeYStart := 250
placeRowHeight := 30
Loop 10 {
    i := A_Index
    yBase := placeYStart + (i - 1) * placeRowHeight

    lbl := MyGui.AddText("x30 y" (yBase + 4) " w80", "Position " i ":")
    xLbl := MyGui.AddText("x200 y" (yBase + 4), "X:")
    xEdit := MyGui.AddEdit("x225 y" yBase " w60", Cfg("Placement" i, "X", "0"))
    yLbl := MyGui.AddText("x300 y" (yBase + 4), "Y:")
    yEdit := MyGui.AddEdit("x325 y" yBase " w60", Cfg("Placement" i, "Y", "0"))
    posBtn := MyGui.AddButton("x400 y" (yBase - 1) " w110", "Set Position")
    posBtn.OnEvent("Click", StartCapture.Bind(xEdit, yEdit))

    PlaceData.Push({Label: lbl, XLbl: xLbl, XEdit: xEdit, YLbl: yLbl, YEdit: yEdit, PosBtn: posBtn,
        CustomSlotDdl: customSlotDdls[i], CustomSlotLabel: customSlotLabels[i]})
}
mapCustomTowersChk.OnEvent("Click", (*) => UpdatePlacementVisibility())

; --- camera drag / zoom out actions for this map now live entirely in Advanced Settings as a
; step list (Drag / Zoom Out), since there can be zero, one, or several of them ---
MyGui.AddButton("x30 y665 w160", "Advanced Settings...").OnEvent("Click", (*) => OpenMapAdvancedGui())

; ---------------- TAB 3: TIMING ----------------
tab.UseTab(3)
MyGui.AddGroupBox("x30 y50 w750 h180", "Timing")
MyGui.AddText("x50 y115", "Extra wait after each full cycle (sec):")
roundWaitEdit := MyGui.AddEdit("x300 y112 w60", Cfg("General", "RoundWaitSeconds", "0"))

MyGui.AddText("x50 y150", "Click delay (ms):")
clickDelayEdit := MyGui.AddEdit("x300 y147 w60", Cfg("General", "ClickDelayMs", "300"))

MyGui.AddText("x420 y150", "Tower placement delay (ms):")
placeTowerDelayEdit := MyGui.AddEdit("x620 y147 w60", Cfg("General", "PlaceTowerDelayMs", "100"))
AddHelpIcon(MyGui, 690, 147, "Wait time (ms) between each action while placing a tower (hotkey -> cursor to position -> click) and between placing one tower and the next.")

MyGui.AddText("x50 y185", "Max cycles (0 = unlimited):")
maxRoundsEdit := MyGui.AddEdit("x300 y182 w60", Cfg("General", "MaxRounds", "0"))

MyGui.AddText("x50 y210", "Position marker size (px):")
markerSizeEdit := MyGui.AddEdit("x300 y207 w60", Cfg("General", "MarkerSize", "4"))

MyGui.AddGroupBox("x30 y240 w750 h145", "Tower Loadout (default slots for all maps)")
MyGui.AddText("x50 y265", "Number of placements:")
numPlaceDdl := MyGui.AddDropDownList("x260 y262 w60", ["1","2","3","4","5","6","7","8","9","10"])
numPlaceDdl.Text := "4"

MyGui.AddText("x50 y302", "Default slots (position 1 -> 10):")
Loop 10 {
    i := A_Index
    xBase := 260 + (i - 1) * 45
    ddl := MyGui.AddDropDownList("x" xBase " y299 w40", ["1","2","3","4","5","6"])
    ddl.Text := "1"
    GeneralSlotDdls.Push(ddl)
}

afterPlaceClickChk := MyGui.AddCheckBox("x50 y340 w230", "Click after each tower placed")
afterPlaceClickChk.Value := Integer(Cfg("General", "AfterPlaceClick", "0"))
MyGui.AddText("x290 y340", "X:")
afterPlaceXEdit := MyGui.AddEdit("x310 y337 w60", Cfg("General", "AfterPlaceClickX", "0"))
MyGui.AddText("x385 y340", "Y:")
afterPlaceYEdit := MyGui.AddEdit("x405 y337 w60", Cfg("General", "AfterPlaceClickY", "0"))
afterPlacePosBtn := MyGui.AddButton("x480 y336 w110", "Set Position")
afterPlacePosBtn.OnEvent("Click", StartCapture.Bind(afterPlaceXEdit, afterPlaceYEdit))
AddHelpIcon(MyGui, 600, 337, "After every single tower is placed, an extra click is made at this fixed position (e.g. to dismiss a popup or confirm placement) before moving on to the next tower.")

MyGui.AddGroupBox("x30 y395 w750 h140", "Game Window")
MyGui.AddText("x50 y420", "Process:")
gameProcessDdl := MyGui.AddDropDownList("x120 y417 w400")
MyGui.AddButton("x530 y416 w90", "Refresh").OnEvent("Click", (*) => RefreshProcessList())

MyGui.AddText("x50 y455", "Opening offset (x, y):")
holeXEdit := MyGui.AddEdit("x220 y452 w60", Cfg("General", "HoleX", "50"))
holeYEdit := MyGui.AddEdit("x285 y452 w60", Cfg("General", "HoleY", "50"))

MyGui.AddText("x50 y490", "Opening size (w, h):")
holeWEdit := MyGui.AddEdit("x220 y487 w60", Cfg("General", "HoleW", "1248"))
holeHEdit := MyGui.AddEdit("x285 y487 w60", Cfg("General", "HoleH", "702"))
AddHelpIcon(MyGui, 360, 487, "A gray fullscreen overlay opens with this rectangular opening cut out; the game window is moved into it.")

MyGui.AddGroupBox("x30 y545 w750 h165", "Disconnect Detection (Auto-Reconnect)")
disconnectEnabledChk := MyGui.AddCheckBox("x50 y570 w500", "Enable: auto-click Reconnect and restart the macro on disconnect")
disconnectEnabledChk.Value := Integer(Cfg("General", "DisconnectEnabled", "0"))
AddHelpIcon(MyGui, 758, 547, "Periodically scans the region below for the given text (e.g. a 'Reconnect' popup). When found, clicks the Reconnect Button position and restarts the currently selected preset from the beginning - as if F10 had been pressed again.")

MyGui.AddText("x50 y600", "Region1 X:")
disconnectX1Edit := MyGui.AddEdit("x125 y597 w55", Cfg("General", "DisconnectX1", "0"))
MyGui.AddText("x190 y600", "Y:")
disconnectY1Edit := MyGui.AddEdit("x210 y597 w55", Cfg("General", "DisconnectY1", "0"))
disconnectPos1Btn := MyGui.AddButton("x275 y596 w100", "Set Position")
disconnectPos1Btn.OnEvent("Click", StartCapture.Bind(disconnectX1Edit, disconnectY1Edit))
MyGui.AddText("x480 y600", "Expected Text:")
disconnectTextEdit := MyGui.AddEdit("x570 y597 w190", Cfg("General", "DisconnectText", ""))

MyGui.AddText("x50 y630", "Region2 X:")
disconnectX2Edit := MyGui.AddEdit("x125 y627 w55", Cfg("General", "DisconnectX2", "0"))
MyGui.AddText("x190 y630", "Y:")
disconnectY2Edit := MyGui.AddEdit("x210 y627 w55", Cfg("General", "DisconnectY2", "0"))
disconnectPos2Btn := MyGui.AddButton("x275 y626 w100", "Set Position")
disconnectPos2Btn.OnEvent("Click", StartCapture.Bind(disconnectX2Edit, disconnectY2Edit))

MyGui.AddText("x50 y660", "Reconnect X:")
disconnectReconnectXEdit := MyGui.AddEdit("x135 y657 w55", Cfg("General", "DisconnectReconnectX", "0"))
MyGui.AddText("x200 y660", "Y:")
disconnectReconnectYEdit := MyGui.AddEdit("x220 y657 w55", Cfg("General", "DisconnectReconnectY", "0"))
disconnectReconnectPosBtn := MyGui.AddButton("x285 y656 w100", "Set Position")
disconnectReconnectPosBtn.OnEvent("Click", StartCapture.Bind(disconnectReconnectXEdit, disconnectReconnectYEdit))
MyGui.AddText("x480 y660", "Check every (sec):")
disconnectIntervalEdit := MyGui.AddEdit("x610 y657 w50", Cfg("General", "DisconnectIntervalSec", "5"))

disconnectTestBtn := MyGui.AddButton("x50 y689 w100", "Test OCR")
disconnectTestBtn.OnEvent("Click", (*) => DisconnectTestOcrClick())
disconnectOcrResultText := MyGui.AddEdit("x160 y691 w600 h22 ReadOnly -WantReturn -E0x200", "OCR result will appear here.")

tab.UseTab()

; ---------------- STATUS & CONTROLS (always visible) ----------------
statusText := MyGui.AddText("x10 y720 w800 h20", "Ready.")
MyGui.AddText("x10 y745 w800 h20", "F8 = confirm position | F9 = Pause/Resume | F10 = Start | F7 = Placement Mode | Escape = Stop/Cancel/Close Overlay")

saveBtn := MyGui.AddButton("x500 y775 w90", "Save")
placementBtn := MyGui.AddButton("x600 y775 w120", "Placement Mode (F7)")
startBtn := MyGui.AddButton("x730 y775 w90", "Start (F10)")
saveBtn.OnEvent("Click", (*) => (SaveConfig(), LogMsg("Configuration saved.")))
placementBtn.OnEvent("Click", (*) => PlacementModeClick())
startBtn.OnEvent("Click", (*) => StartMacro())

MyGui.OnEvent("Close", (*) => (SaveConfig(), ExitApp()))
MyGui.OnEvent("Size", (*) => "")  ; prevents errors on resize

UpdatePlacementVisibility()
UpdateGeneralSlotVisibility()
numPlaceDdl.OnEvent("Change", (*) => (UpdatePlacementVisibility(), UpdateGeneralSlotVisibility()))

RefreshProcessList()

; ============================================================
; EDIT PRESET WINDOW (opened via the "Edit" button)
; ============================================================
; +Resize adds a resizable border AND a maximize button to the title bar, so this window can be
; dragged bigger or maximized when it feels cramped - see EditGuiSizeHandler below, which widens
; the step list to actually use the extra space instead of just leaving it blank.
EditGui := Gui("+Owner" MyGui.Hwnd " +Resize +MinSize860x700", "Edit Preset")
EditGui.SetFont("s10")
EditGui.OnEvent("Size", EditGuiSizeHandler)

editingLabel := EditGui.AddText("x20 y15 w550", "Editing: Challenges")

; --- import from another preset: either a whole screen (its full step list), or just a single
; step/component (with all its settings) picked from that screen. Handy for reusing e.g. a "Round
; End" screen, or just one popup-handling step, across multiple presets instead of rebuilding it
; by hand. ---
EditGui.AddGroupBox("x590 y5 w250 h160", "Import From Preset")
EditGui.AddText("x605 y28", "Preset:")
importPresetDdl := EditGui.AddDropDownList("x665 y25 w165")
importPresetDdl.OnEvent("Change", (*) => ImportPresetChanged())
EditGui.AddText("x605 y58", "Screen:")
importScreenDdl := EditGui.AddDropDownList("x665 y55 w165")
importScreenDdl.OnEvent("Change", (*) => ImportScreenChanged())
EditGui.AddText("x605 y88", "Component:")
importStepDdl := EditGui.AddDropDownList("x665 y85 w165")
importScreenBtn := EditGui.AddButton("x600 y120 w110 h28", "Import Screen")
importScreenBtn.OnEvent("Click", (*) => ImportScreenClick())
importStepBtn := EditGui.AddButton("x718 y120 w112 h28", "Import Step")
importStepBtn.OnEvent("Click", (*) => ImportStepClick())
AddHelpIcon(EditGui, 815, 7, "Pick a preset (and one of its screens) to import from - including the current preset itself, to duplicate one of its own screens/steps. 'Import Screen' imports the WHOLE screen's step list - either overwriting the screen currently open below (keeping its name) or added as a new screen. 'Import Step' instead adds just the single component picked below to the end of the screen currently open here, settings and all. Any 'On True/On False' jumps that point to screen names which don't exist in this preset will just fall through with a warning at runtime - rename them here afterward if needed.")

; --- screens: a preset is now a set of named screens, each with its own step list. Logic steps
; (Detect Map / Round End Detection / Ingame Detection) inside a screen can jump to any other
; screen on true/false; a screen that finishes without jumping falls through to the next screen
; in this list (wrapping back to the first after the last). ---
EditGui.AddText("x20 y45", "Screen:")
screenDdl := EditGui.AddDropDownList("x70 y42 w250")
screenDdl.OnEvent("Change", (*) => ScreenChanged())
AddHelpIcon(EditGui, 328, 44, "A screen is a named group of steps. When a screen finishes without a Logic step jumping elsewhere, execution falls through to the next screen in this list (wrapping back to the start after the last). By default the first screen is where each cycle starts and wraps back to - add a 'Start' component to any step list instead if you want a different screen to be the actual starting point.")

EditGui.AddButton("x20 y75 w95", "New Screen").OnEvent("Click", (*) => NewScreenClick())
EditGui.AddButton("x120 y75 w95", "Rename").OnEvent("Click", (*) => RenameScreenClick())
EditGui.AddButton("x220 y75 w95", "Delete").OnEvent("Click", (*) => DeleteScreenClick())
EditGui.AddButton("x320 y75 w95", "Move Up").OnEvent("Click", (*) => MoveScreenUpClick())
EditGui.AddButton("x420 y75 w95", "Move Down").OnEvent("Click", (*) => MoveScreenDownClick())

stepsLV := EditGui.AddListView("x20 y170 w750 h190 Grid", ["#", "Type", "Label", "X / Duration", "Y", "End X", "End Y", "Drag (ms)", "Once/Cycle", "On True", "On False", "Wait After (s)"])
stepsLV.ModifyCol(1, 28)
stepsLV.ModifyCol(2, 100)
stepsLV.ModifyCol(3, 95)
stepsLV.ModifyCol(4, 62)
stepsLV.ModifyCol(5, 52)
stepsLV.ModifyCol(6, 52)
stepsLV.ModifyCol(7, 52)
stepsLV.ModifyCol(8, 55)
stepsLV.ModifyCol(9, 62)
stepsLV.ModifyCol(10, 75)
stepsLV.ModifyCol(11, 75)
stepsLV.ModifyCol(12, 80)
stepsLV.OnEvent("Click", (*) => LoadEditorFromSelection())

EditGui.AddGroupBox("x20 y370 w750 h230", "Step Editor")
EditGui.AddText("x40 y395", "Type:")
stepTypeDdl := EditGui.AddDropDownList("x90 y392 w170", ["Start", "Option Select", "Button Click", "Press Start Button", "Restart Stage Button", "Camera Setup", "Place Towers", "Drag", "Zoom Out", "Wait", "Detect Map", "Round End Detection", "Ingame Detection", "Custom Detection"])
stepTypeDdl.Text := "Button Click"
stepLabelLbl := EditGui.AddText("x280 y395", "Label:")
stepLabelEdit := EditGui.AddEdit("x330 y392 w150", "")

stepXLabel := EditGui.AddText("x40 y430", "X:")
stepXEdit := EditGui.AddEdit("x95 y427 w60", "0")
stepYLabel := EditGui.AddText("x170 y430", "Y:")
stepYEdit := EditGui.AddEdit("x225 y427 w60", "0")
stepPosBtn := EditGui.AddButton("x300 y426 w110", "Set Position")
stepPosBtn.OnEvent("Click", StartCapture.Bind(stepXEdit, stepYEdit))
EditGui.AddText("x430 y430", "Wait After (s):")
stepSecEdit := EditGui.AddEdit("x530 y427 w60", "0")

; --- Drag's end point + duration, OR a Logic step's second region corner (relabeled dynamically) ---
dragEndXLabel := EditGui.AddText("x40 y465", "End X:")
dragEndXEdit := EditGui.AddEdit("x95 y462 w60", "0")
dragEndYLabel := EditGui.AddText("x170 y465", "End Y:")
dragEndYEdit := EditGui.AddEdit("x225 y462 w60", "0")
dragEndPosBtn := EditGui.AddButton("x300 y461 w110", "Set Position")
dragEndPosBtn.OnEvent("Click", StartCapture.Bind(dragEndXEdit, dragEndYEdit))
dragMsLabel := EditGui.AddText("x430 y465", "Drag (ms):")
dragMsEdit := EditGui.AddEdit("x520 y462 w60", "500")

; --- Logic steps only: test OCR against the region/text entered above ---
stepOcrTestBtn := EditGui.AddButton("x40 y500 w110", "Test OCR")
stepOcrTestBtn.OnEvent("Click", (*) => StepTestOcrClick())
stepOcrResultText := EditGui.AddEdit("x160 y502 w590 h22 ReadOnly -WantReturn -E0x200", "OCR result will appear here.")

; --- Where to jump when this step finishes: Logic steps get two branches (true/false, based on
; the OCR result); Mechanic steps get a single unconditional jump (reuses the same "On True"
; field/column - e.g. a plain Round End button that just always goes back to "Ingame" with no
; detection needed). ---
stepOnTrueLbl := EditGui.AddText("x40 y538", "On True ->")
stepOnTrueDdl := EditGui.AddDropDownList("x120 y535 w190")
stepOnFalseLbl := EditGui.AddText("x330 y538", "On False ->")
stepOnFalseDdl := EditGui.AddDropDownList("x415 y535 w190")
AddHelpIcon(EditGui, 615, 537, "Jump to another screen when this step finishes. Logic steps (Detect Map, Round End/Ingame/Custom Detection) can jump differently depending on whether the OCR text matched. Other steps just jump unconditionally using the 'On True' field - leave it on '(continue)' to keep running the rest of this screen normally. Pick '(Repeat)' to re-run this exact step again instead - waits for this step's own 'Wait After (s)' between attempts, so e.g. a detection step can keep rechecking itself until it matches.")

; --- once-per-cycle flag, applies to every step type ---
oncePerCycleChk := EditGui.AddCheckBox("x40 y570 w650", "Once per cycle (run only once, skip until the next Detect Map / new round)")
AddHelpIcon(EditGui, 700, 571, "When checked, this step only runs once and is then skipped on every repeat - until a 'Detect Map' step runs again (i.e. a new round starts). Useful for e.g. a Drag or Zoom Out step inside a repeating screen that shouldn't run every loop.")

EditGui.AddButton("x40 y610 w100", "Add Step").OnEvent("Click", (*) => AddStepClick())
EditGui.AddButton("x150 y610 w130", "Update Selected").OnEvent("Click", (*) => UpdateSelectedClick())
EditGui.AddButton("x290 y610 w130", "Remove Selected").OnEvent("Click", (*) => RemoveSelectedClick())
EditGui.AddButton("x430 y610 w90", "Move Up").OnEvent("Click", (*) => MoveUpClick())
EditGui.AddButton("x530 y610 w90", "Move Down").OnEvent("Click", (*) => MoveDownClick())
startFromStepBtn := EditGui.AddButton("x630 y610 w140", "Start Macro From This Step")
startFromStepBtn.OnEvent("Click", (*) => StartFromStepClick())
AddHelpIcon(EditGui, 775, 613, "Starts the macro beginning at the currently selected step, skipping everything before it on this screen. Later screens (via jumps/fallthrough) still run normally from their own start. While the macro runs, this window follows along - showing whichever screen/step is currently executing.")

; --- 3 challenge options, specific to this preset (only shown while editing an "Option Select" step) ---
optionSectionLabel := EditGui.AddText("x20 y650", "Challenge options for this preset (used by its 'Option Select' steps):")
OptionSectionControls.Push(optionSectionLabel)
optionBoxW := 235
optionGap := 15
optionYBase := 670
optionBoxH := 190
Loop 3 {
    i := A_Index
    xBase := 20 + (i - 1) * (optionBoxW + optionGap)

    optGroupBox := EditGui.AddGroupBox("x" xBase " y" optionYBase " w" optionBoxW " h" optionBoxH, "Option " i)

    optNameLbl := EditGui.AddText("x" (xBase + 10) " y" (optionYBase + 22), "Name:")
    nameEdit := EditGui.AddEdit("x" (xBase + 65) " y" (optionYBase + 19) " w" (optionBoxW - 75), "Option " i)

    optXLbl := EditGui.AddText("x" (xBase + 10) " y" (optionYBase + 52), "X:")
    xEdit := EditGui.AddEdit("x" (xBase + 30) " y" (optionYBase + 49) " w55", "0")
    optYLbl := EditGui.AddText("x" (xBase + 95) " y" (optionYBase + 52), "Y:")
    yEdit := EditGui.AddEdit("x" (xBase + 115) " y" (optionYBase + 49) " w55", "0")

    posBtn := EditGui.AddButton("x" (xBase + 10) " y" (optionYBase + 78) " w" (optionBoxW - 20), "Set Position")

    availChk := EditGui.AddCheckBox("x" (xBase + 10) " y" (optionYBase + 108) " w" (optionBoxW - 20), "Available at start")
    availChk.Value := 1

    optPrioLbl := EditGui.AddText("x" (xBase + 10) " y" (optionYBase + 136), "Priority:")
    prioDdl := EditGui.AddDropDownList("x" (xBase + 70) " y" (optionYBase + 133) " w60", ["1", "2", "3"])
    prioDdl.Text := String(i)

    ; Daily play limit for this option (0 = unlimited). Checked/enforced during "Option Select"
    ; (see RunSteps) and mirrored, with the actual count used today, on the Preset Settings tab.
    optMaxLbl := EditGui.AddText("x" (xBase + 140) " y" (optionYBase + 136), "Max:")
    maxEdit := EditGui.AddEdit("x" (xBase + 175) " y" (optionYBase + 133) " w45", "0")
    HoverTooltipMap[maxEdit.Hwnd] := "How many times this option may be played per day (0 = unlimited). Resets automatically every day. Once all 3 options are exhausted for today, the 'Fallback Screen' setting below takes over (including the 'Stop Macro' option)."

    ; Opens the shared Option Availability Check popup, pre-loaded for THIS option (i). Lets you
    ; configure an OCR region + expected text that verifies this option is actually playable
    ; in-game before the macro commits to it.
    availDetBtn := EditGui.AddButton("x" (xBase + 10) " y" (optionYBase + 166) " w" (optionBoxW - 20), "Availability Check...")
    availDetBtn.OnEvent("Click", OpenOptionAvailGui.Bind(i))

    posBtn.OnEvent("Click", StartCapture.Bind(xEdit, yEdit))

    OptData.Push({NameEdit: nameEdit, XEdit: xEdit, YEdit: yEdit, AvailChk: availChk, PrioDdl: prioDdl, MaxEdit: maxEdit,
        DetX: "0", DetY: "0", DetEndX: "0", DetEndY: "0", DetText: "", DetInvert: 0})
    for ctrl in [optGroupBox, optNameLbl, nameEdit, optXLbl, xEdit, optYLbl, yEdit, posBtn, availChk, optPrioLbl, prioDdl, optMaxLbl, maxEdit, availDetBtn]
        OptionSectionControls.Push(ctrl)
}

; --- Two DIFFERENT things "Option Select" needs when an option isn't available, which is why
; there are two separate controls here:
;  - Back Button: clicked to return from THAT ONE option's own details/preview screen once its
;    availability check comes back negative, so the next priority can still be tried.
;  - Fallback Screen: what to do if EVERY option turns out unavailable - jumps straight to a
;    different screen (e.g. a "Farming" screen) instead of clicking a fixed position. Leave it on
;    "(none)" to fall back to the old behavior of waiting 5s and rechecking instead. ---
EditGui.AddGroupBox("x20 y870 w800 h68", "Option Select: Back Button & Fallback Screen")
EditGui.AddText("x35 y897", "Back X:")
backXEdit := EditGui.AddEdit("x90 y894 w50", "0")
EditGui.AddText("x155 y897", "Back Y:")
backYEdit := EditGui.AddEdit("x210 y894 w50", "0")
backPosBtn := EditGui.AddButton("x280 y893 w100", "Set Position")
backPosBtn.OnEvent("Click", StartCapture.Bind(backXEdit, backYEdit))
EditGui.AddText("x410 y897", "Fallback Screen ->")
fallbackScreenDdl := EditGui.AddDropDownList("x520 y894 w250")
AddHelpIcon(EditGui, 795, 875, "Back Button: clicked to return to the mode-select screen after an option's Availability Check comes back negative, so the next priority can be tried. Fallback Screen: jumped to instead if every option turns out unavailable (including all 3 hitting their daily 'Max' limit) - leave it on '(none)' to fall back to the old behavior of waiting 5s and rechecking instead, or pick 'Stop Macro' to end the run cleanly once nothing is left to play today.")
for ctrl in [backXEdit, backYEdit, backPosBtn, fallbackScreenDdl]
    OptionSectionControls.Push(ctrl)

; --- default map fallback, specific to this preset ---
EditGui.AddText("x20 y955", "Default Map:")
defaultMapDdl := EditGui.AddDropDownList("x110 y952 w260")
AddHelpIcon(EditGui, 380, 953, "Used by 'Place Towers' if no 'Detect Map' step ran (or it found nothing) while this preset is running. Set to '(none)' to always require detection.")

EditGui.AddButton("x680 y992 w90", "Close").OnEvent("Click", (*) => CloseEditGui())
EditGui.OnEvent("Close", (*) => CloseEditGui())

stepTypeDdl.OnEvent("Change", (*) => StepTypeChangedByUser())

; ============================================================
; MAP ADVANCED SETTINGS WINDOW (Drag / Zoom Out action list, per map profile)
; ============================================================
MapAdvGui := Gui("+Owner" MyGui.Hwnd, "Map Advanced Settings")
MapAdvGui.SetFont("s10")

mapAdvLabel := MapAdvGui.AddText("x20 y15 w560", "Editing: shared default (all maps)")

mapCustomCameraChk := MapAdvGui.AddCheckBox("x20 y45 w580", "Use custom camera/zoom settings for this map (unchecked = use the shared default)")
mapCustomCameraChk.OnEvent("Click", OnMapCustomCameraToggled)
AddHelpIcon(MapAdvGui, 605, 46, "These actions run once (each) before towers are placed, right after the map is detected - not every time. They only repeat again after a new 'Detect Map' (i.e. a new round).")

mapAdvStepsLV := MapAdvGui.AddListView("x20 y75 w600 h150 Grid", ["#", "Type", "X / Ticks", "Y", "End X", "End Y", "Drag (ms)"])
mapAdvStepsLV.ModifyCol(1, 30)
mapAdvStepsLV.ModifyCol(2, 100)
mapAdvStepsLV.ModifyCol(3, 80)
mapAdvStepsLV.ModifyCol(4, 80)
mapAdvStepsLV.ModifyCol(5, 80)
mapAdvStepsLV.ModifyCol(6, 80)
mapAdvStepsLV.ModifyCol(7, 90)
mapAdvStepsLV.OnEvent("Click", (*) => MapAdvLoadEditorFromSelection())

MapAdvGui.AddGroupBox("x20 y235 w600 h175", "Step Editor")
MapAdvGui.AddText("x40 y260", "Type:")
mapAdvTypeDdl := MapAdvGui.AddDropDownList("x90 y257 w160", ["Drag", "Zoom Out"])
mapAdvTypeDdl.Text := "Drag"
mapAdvTypeDdl.OnEvent("Change", (*) => UpdateMapAdvEditorLabels())

mapAdvXLabel := MapAdvGui.AddText("x40 y295", "X:")
mapAdvXEdit := MapAdvGui.AddEdit("x65 y292 w60", "0")
mapAdvYLabel := MapAdvGui.AddText("x140 y295", "Y:")
mapAdvYEdit := MapAdvGui.AddEdit("x165 y292 w60", "0")
mapAdvPosBtn := MapAdvGui.AddButton("x240 y291 w110", "Set Position")
mapAdvPosBtn.OnEvent("Click", StartCapture.Bind(mapAdvXEdit, mapAdvYEdit))

mapAdvEndXLabel := MapAdvGui.AddText("x40 y330", "End X:")
mapAdvEndXEdit := MapAdvGui.AddEdit("x95 y327 w60", "0")
mapAdvEndYLabel := MapAdvGui.AddText("x170 y330", "End Y:")
mapAdvEndYEdit := MapAdvGui.AddEdit("x225 y327 w60", "0")
mapAdvEndPosBtn := MapAdvGui.AddButton("x300 y326 w110", "Set Position")
mapAdvEndPosBtn.OnEvent("Click", StartCapture.Bind(mapAdvEndXEdit, mapAdvEndYEdit))
mapAdvMsLabel := MapAdvGui.AddText("x430 y330", "Drag (ms):")
mapAdvMsEdit := MapAdvGui.AddEdit("x520 y327 w60", "500")

MapAdvGui.AddButton("x40 y375 w100", "Add Step").OnEvent("Click", (*) => MapAdvAddStepClick())
MapAdvGui.AddButton("x150 y375 w130", "Update Selected").OnEvent("Click", (*) => MapAdvUpdateSelectedClick())
MapAdvGui.AddButton("x290 y375 w130", "Remove Selected").OnEvent("Click", (*) => MapAdvRemoveSelectedClick())
MapAdvGui.AddButton("x430 y375 w90", "Move Up").OnEvent("Click", (*) => MapAdvMoveUpClick())
MapAdvGui.AddButton("x530 y375 w90", "Move Down").OnEvent("Click", (*) => MapAdvMoveDownClick())

MapAdvGui.AddButton("x530 y425 w90", "Close").OnEvent("Click", (*) => CloseMapAdvGui())
MapAdvGui.OnEvent("Close", (*) => CloseMapAdvGui())

; ============================================================
; OPTION AVAILABILITY CHECK WINDOW (per-option OCR detector for "Option Select")
; ============================================================
CurrentAvailOptionIndex := 0

OptionAvailGui := Gui("+Owner" MyGui.Hwnd, "Option Availability Check")
OptionAvailGui.SetFont("s10")

optAvailLabel := OptionAvailGui.AddText("x20 y15 w490", "Editing: Option 1 availability check")

optAvailXLbl := OptionAvailGui.AddText("x20 y52", "Region1 X:")
optAvailXEdit := OptionAvailGui.AddEdit("x100 y49 w60", "0")
optAvailYLbl := OptionAvailGui.AddText("x180 y52", "Region1 Y:")
optAvailYEdit := OptionAvailGui.AddEdit("x260 y49 w60", "0")
optAvailPosBtn := OptionAvailGui.AddButton("x340 y48 w110", "Set Position")
optAvailPosBtn.OnEvent("Click", StartCapture.Bind(optAvailXEdit, optAvailYEdit))

optAvailEndXLbl := OptionAvailGui.AddText("x20 y87", "Region2 X:")
optAvailEndXEdit := OptionAvailGui.AddEdit("x100 y84 w60", "0")
optAvailEndYLbl := OptionAvailGui.AddText("x180 y87", "Region2 Y:")
optAvailEndYEdit := OptionAvailGui.AddEdit("x260 y84 w60", "0")
optAvailEndPosBtn := OptionAvailGui.AddButton("x340 y83 w110", "Set Position")
optAvailEndPosBtn.OnEvent("Click", StartCapture.Bind(optAvailEndXEdit, optAvailEndYEdit))

optAvailTextLbl := OptionAvailGui.AddText("x20 y122", "Expected Text:")
optAvailTextEdit := OptionAvailGui.AddEdit("x120 y119 w330", "")

optAvailInvertChk := OptionAvailGui.AddCheckBox("x20 y152 w480", "Text found means UNAVAILABLE (instead of available)")
AddHelpIcon(OptionAvailGui, 505, 153, "Leave Expected Text empty to skip the detection entirely for this option - it'll be treated as available as soon as it's clicked (the old behavior). When set, after clicking the option this region is scanned and compared: normally, finding the text means the option IS available; check the box above if your game does it the other way around (e.g. the text only appears when the option is greyed out/locked).")

optAvailTestBtn := OptionAvailGui.AddButton("x20 y185 w110", "Test OCR")
optAvailTestBtn.OnEvent("Click", (*) => OptAvailTestOcrClick())
optAvailResultText := OptionAvailGui.AddEdit("x140 y187 w370 h22 ReadOnly -WantReturn -E0x200", "OCR result will appear here.")

; Convenience for the common case where every option shows the same "no attempts left" indicator
; in the same spot regardless of which one was clicked - no need to set up the same region/text
; 3 times by hand.
optAvailApplyAllBtn := OptionAvailGui.AddButton("x20 y222 w220", "Apply to All 3 Options")
optAvailApplyAllBtn.OnEvent("Click", (*) => OptAvailApplyToAllClick())
AddHelpIcon(OptionAvailGui, 245, 224, "Copies the region/text/invert settings currently shown above to all 3 options at once - handy when every option's availability shows up the same way in the same place, so you only have to set it up once.")

OptionAvailGui.AddButton("x420 y260 w90", "Close").OnEvent("Click", (*) => CloseOptionAvailGui())
OptionAvailGui.OnEvent("Close", (*) => CloseOptionAvailGui())

; ---------------- MAP PROFILE BOOTSTRAP ----------------
; (must run before preset bootstrap - LoadPreset() needs defaultMapDdl already populated)
InitMapProfiles()
mapProfileDdl.OnEvent("Change", (*) => MapProfileChanged())

; ---------------- PRESET BOOTSTRAP ----------------
InitPresets()
UpdateStepEditorLabels()

MyGui.Show("w820 h815")
CreateMarker()

OpenEditGui(*) {
    global CurrentPresetName, EditGui, editingLabel, EditGuiVisible
    LoadPreset(CurrentPresetName)
    editingLabel.Text := "Editing: " CurrentPresetName
    RefreshImportPresetDdl()
    EditGui.Show("w860 h1040")
    EditGuiVisible := true
}

CloseEditGui(*) {
    global CurrentPresetName, EditGui, EditGuiVisible
    SavePresetToIni(CurrentPresetName)
    EditGui.Hide()
    EditGuiVisible := false
}

; Fires whenever the Edit Preset window is resized or maximized/restored. Widens the step list
; (stepsLV) to fill the extra width instead of leaving it blank - that ListView packs 12 columns
; into a fixed width by default, which is the main thing that gets unreadably cramped. Everything
; else keeps its original position; resizing taller just gives you more blank margin below.
EditGuiSizeHandler(guiObj, minMax, width, height) {
    global stepsLV
    if (minMax = -1)  ; minimized - nothing to reflow
        return
    try stepsLV.Move(, , Max(750, width - 90), )
}

OpenMapAdvancedGui(*) {
    global CurrentMapProfileName, MapAdvGui, mapAdvLabel, mapCustomCameraChk
    LoadMapProfile(CurrentMapProfileName)
    mapAdvLabel.Text := mapCustomCameraChk.Value
        ? "Editing: custom settings for '" CurrentMapProfileName "'"
        : "Editing: shared default (all maps without 'custom' checked)"
    MapAdvGui.Show("w650 h500")
}

CloseMapAdvGui(*) {
    global CurrentMapProfileName, MapAdvGui
    SaveMapProfileToIni(CurrentMapProfileName)
    MapAdvGui.Hide()
}

; Opens the shared Option Availability Check popup pre-loaded with option `idx`'s (1-3) currently
; held detector settings. Bound per-option via .Bind(i) on each "Availability Check..." button.
OpenOptionAvailGui(idx, *) {
    global CurrentAvailOptionIndex, OptData, optAvailLabel, optAvailXEdit, optAvailYEdit
    global optAvailEndXEdit, optAvailEndYEdit, optAvailTextEdit, optAvailInvertChk, optAvailResultText, OptionAvailGui
    CurrentAvailOptionIndex := idx
    opt := OptData[idx]
    optAvailLabel.Text := "Editing: Option " idx " (" opt.NameEdit.Value ") availability check"
    optAvailXEdit.Value := opt.DetX
    optAvailYEdit.Value := opt.DetY
    optAvailEndXEdit.Value := opt.DetEndX
    optAvailEndYEdit.Value := opt.DetEndY
    optAvailTextEdit.Value := opt.DetText
    optAvailInvertChk.Value := opt.DetInvert
    optAvailResultText.Text := "OCR result will appear here."
    OptionAvailGui.Show("w530 h295")
}

; Flushes the popup's fields back onto the OptData entry it was opened for, then hides it. Actual
; ini persistence happens later via SavePresetToIni, same as every other option field.
CloseOptionAvailGui(*) {
    global CurrentAvailOptionIndex, OptData, optAvailXEdit, optAvailYEdit
    global optAvailEndXEdit, optAvailEndYEdit, optAvailTextEdit, optAvailInvertChk, OptionAvailGui
    if CurrentAvailOptionIndex {
        opt := OptData[CurrentAvailOptionIndex]
        opt.DetX := optAvailXEdit.Value
        opt.DetY := optAvailYEdit.Value
        opt.DetEndX := optAvailEndXEdit.Value
        opt.DetEndY := optAvailEndYEdit.Value
        opt.DetText := optAvailTextEdit.Value
        opt.DetInvert := optAvailInvertChk.Value
    }
    OptionAvailGui.Hide()
}

; Tests whatever's currently entered in the popup (not necessarily saved to OptData yet).
OptAvailTestOcrClick(*) {
    global optAvailXEdit, optAvailYEdit, optAvailEndXEdit, optAvailEndYEdit, optAvailTextEdit, optAvailResultText
    rect := {x: Min(SafeInt(optAvailXEdit.Value), SafeInt(optAvailEndXEdit.Value)),
        y: Min(SafeInt(optAvailYEdit.Value), SafeInt(optAvailEndYEdit.Value)),
        w: Abs(SafeInt(optAvailEndXEdit.Value) - SafeInt(optAvailXEdit.Value)),
        h: Abs(SafeInt(optAvailEndYEdit.Value) - SafeInt(optAvailYEdit.Value))}
    if (rect.w <= 0 || rect.h <= 0) {
        MsgBox "Set both Region1 and Region2 positions first."
        return
    }
    optAvailResultText.Text := "Reading..."
    text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h)
    if (text = "") {
        optAvailResultText.Text := "(no text recognized)"
        LogMsg("Option availability OCR test: (no text recognized)")
        return
    }
    expected := optAvailTextEdit.Value
    isMatch := (expected != "") && (InStr(text, expected) || TextContainsPartialMatch(text, expected, 6))
    optAvailResultText.Text := "Recognized: '" text "' -> " (isMatch ? "MATCH" : "no match")
    LogMsg("Option availability OCR test result: '" text "'")
}

; Copies the popup's currently-entered detector settings (region + expected text + invert) to ALL
; 3 options at once - the common case is every option showing the same "no attempts left"
; indicator in the same spot regardless of which one was clicked, so there's no need to set up
; the same region/text 3 separate times.
OptAvailApplyToAllClick(*) {
    global OptData, optAvailXEdit, optAvailYEdit, optAvailEndXEdit, optAvailEndYEdit, optAvailTextEdit, optAvailInvertChk
    for opt in OptData {
        opt.DetX := optAvailXEdit.Value
        opt.DetY := optAvailYEdit.Value
        opt.DetEndX := optAvailEndXEdit.Value
        opt.DetEndY := optAvailEndYEdit.Value
        opt.DetText := optAvailTextEdit.Value
        opt.DetInvert := optAvailInvertChk.Value
    }
    LogMsg("Availability Check settings applied to all 3 options.")
    MsgBox "Applied to all 3 options."
}

; ============================================================
; PLACEMENT ROW VISIBILITY
; ============================================================
UpdatePlacementVisibility(*) {
    global numPlaceDdl, PlaceData, mapCustomTowersChk
    n := Integer(numPlaceDdl.Text)
    customOn := mapCustomTowersChk.Value
    for i, row in PlaceData {
        vis := (i <= n)
        row.Label.Visible := vis
        row.XLbl.Visible := vis
        row.XEdit.Visible := vis
        row.YLbl.Visible := vis
        row.YEdit.Visible := vis
        row.PosBtn.Visible := vis
        row.CustomSlotDdl.Visible := vis && customOn
        row.CustomSlotLabel.Visible := vis && customOn
    }
}

UpdateGeneralSlotVisibility(*) {
    global numPlaceDdl, GeneralSlotDdls
    n := Integer(numPlaceDdl.Text)
    for i, ddl in GeneralSlotDdls
        ddl.Visible := (i <= n)
}

; ============================================================
; MAP PROFILE MANAGEMENT (placement coordinates, auto-detected per map)
; ============================================================
InitMapProfiles() {
    global ConfigFile, MapProfileNames, CurrentMapProfileName, mapProfileDdl, defaultMapDdl

    listStr := Cfg("MapProfiles", "List", "")

    ; One-time migration: earlier versions stored NumPlacements/slots per map profile.
    ; If General doesn't have them yet, lift them from whichever profile has them.
    if (Cfg("General", "NumPlacements", "") = "") {
        legacySource := ""
        if (listStr != "") {
            candidates := StrSplit(listStr, ",")
            for n in candidates {
                if (Cfg("MapProfile_" n, "NumPlacements", "") != "") {
                    legacySource := n
                    break
                }
            }
        }
        if (legacySource != "") {
            IniWrite Cfg("MapProfile_" legacySource, "NumPlacements", "4"), ConfigFile, "General", "NumPlacements"
            Loop 10 {
                i := A_Index
                IniWrite Cfg("MapProfile_" legacySource, "Placement" i "Slot", "1"), ConfigFile, "General", "Slot" i
            }
        } else {
            IniWrite "4", ConfigFile, "General", "NumPlacements"
            Loop 10 {
                i := A_Index
                IniWrite Cfg("Placement" i, "Slot", "1"), ConfigFile, "General", "Slot" i
            }
        }
    }

    if (listStr = "") {
        ; First run: migrate the old single placement config (if any) into a "Default" profile
        IniWrite "", ConfigFile, "MapProfile_Default", "ExpectedText"
        IniWrite 0, ConfigFile, "MapProfile_Default", "CustomTowers"
        Loop 10 {
            i := A_Index
            IniWrite Cfg("Placement" i, "X", "0"), ConfigFile, "MapProfile_Default", "Placement" i "X"
            IniWrite Cfg("Placement" i, "Y", "0"), ConfigFile, "MapProfile_Default", "Placement" i "Y"
        }
        IniWrite "Default", ConfigFile, "MapProfiles", "List"
        IniWrite "Default", ConfigFile, "MapProfiles", "Active"
        listStr := "Default"
    }

    MapProfileNames := StrSplit(listStr, ",")
    mapProfileDdl.Delete()
    mapProfileDdl.Add(MapProfileNames)

    active := Cfg("MapProfiles", "Active", MapProfileNames[1])
    found := false
    for n in MapProfileNames {
        if (n = active)
            found := true
    }
    if !found
        active := MapProfileNames[1]

    mapProfileDdl.Text := active
    CurrentMapProfileName := active
    LoadGeneralSlots()
    LoadMapProfile(CurrentMapProfileName)

    ; Populates defaultMapDdl's item list (its selected value is set per-preset by LoadPreset(),
    ; called later during preset bootstrap - which must run after this).
    RebuildDefaultMapDdl()
}

; Keeps the "Default Map" dropdown (Preset Settings tab) in sync with the current list of
; map profiles. Always offers "(none)" so detection can be required with no fallback.
RebuildDefaultMapDdl() {
    global defaultMapDdl, MapProfileNames
    current := defaultMapDdl.Text
    defaultMapDdl.Delete()
    defaultMapDdl.Add(["(none)"])
    defaultMapDdl.Add(MapProfileNames)
    found := false
    for n in MapProfileNames {
        if (n = current)
            found := true
    }
    defaultMapDdl.Text := found ? current : "(none)"
}

LoadGeneralSlots() {
    global numPlaceDdl, GeneralSlotDdls
    numPlaceDdl.Text := Cfg("General", "NumPlacements", "4")
    Loop 10 {
        i := A_Index
        GeneralSlotDdls[i].Text := Cfg("General", "Slot" i, "1")
    }
    UpdateGeneralSlotVisibility()
}

LoadMapProfile(name) {
    global PlaceData, mapExpectedTextEdit, mapCustomTowersChk, mapCustomCameraChk
    section := "MapProfile_" name
    mapExpectedTextEdit.Value := Cfg(section, "ExpectedText", "")
    mapCustomTowersChk.Value := Integer(Cfg(section, "CustomTowers", "0"))
    Loop 10 {
        i := A_Index
        row := PlaceData[i]
        row.XEdit.Value := Cfg(section, "Placement" i "X", "0")
        row.YEdit.Value := Cfg(section, "Placement" i "Y", "0")
        row.CustomSlotDdl.Text := Cfg(section, "CustomSlot" i, "1")
    }
    ; Map actions (Drag/Zoom Out) are shared ([General]) unless this map opts into its own copy.
    mapCustomCameraChk.Value := Integer(Cfg(section, "CustomCamera", "0"))
    LoadMapAdvStepsForProfile(name)
    UpdatePlacementVisibility()
}

; Loads the map-actions ListView (Advanced Settings) from whichever section is currently in
; effect for `name` - its own section if "custom" is checked, otherwise [General]. Does NOT touch
; mapCustomCameraChk itself, so it's safe to call right after the user toggles it.
LoadMapAdvStepsForProfile(name) {
    global mapCustomCameraChk
    section := "MapProfile_" name
    camSection := mapCustomCameraChk.Value ? section : "General"
    LoadMapAdvStepsLV(camSection)
}

OnMapCustomCameraToggled(*) {
    global CurrentMapProfileName
    LoadMapAdvStepsForProfile(CurrentMapProfileName)
}

SaveMapProfileToIni(name) {
    global PlaceData, mapExpectedTextEdit, mapCustomTowersChk, mapCustomCameraChk, ConfigFile
    section := "MapProfile_" name
    IniWrite mapExpectedTextEdit.Value, ConfigFile, section, "ExpectedText"
    IniWrite mapCustomTowersChk.Value, ConfigFile, section, "CustomTowers"
    Loop 10 {
        i := A_Index
        row := PlaceData[i]
        IniWrite row.CustomSlotDdl.Text, ConfigFile, section, "CustomSlot" i
        IniWrite row.XEdit.Value, ConfigFile, section, "Placement" i "X"
        IniWrite row.YEdit.Value, ConfigFile, section, "Placement" i "Y"
    }
    ; Map actions (Drag/Zoom Out) write to [General] (shared) unless "custom for this map" is
    ; checked - in that case they write to this map's own section instead.
    IniWrite mapCustomCameraChk.Value, ConfigFile, section, "CustomCamera"
    camSection := mapCustomCameraChk.Value ? section : "General"
    SaveMapAdvStepsFromLV(camSection)
}

RebuildMapProfileDdl() {
    global mapProfileDdl, MapProfileNames
    mapProfileDdl.Delete()
    mapProfileDdl.Add(MapProfileNames)
}

MapProfileChanged(*) {
    global CurrentMapProfileName, mapProfileDdl, ConfigFile
    if (CurrentMapProfileName != "")
        SaveMapProfileToIni(CurrentMapProfileName)
    CurrentMapProfileName := mapProfileDdl.Text
    LoadMapProfile(CurrentMapProfileName)
    IniWrite CurrentMapProfileName, ConfigFile, "MapProfiles", "Active"
}

NewMapProfileClick(*) {
    global CurrentMapProfileName, mapProfileDdl, MapProfileNames, ConfigFile, PlaceData, mapExpectedTextEdit, mapCustomTowersChk, mapCustomCameraChk
    ib := InputBox("Enter a name for the new map profile (e.g. the map name):", "New Map Profile")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    name := Trim(ib.Value)
    for n in MapProfileNames {
        if (n = name) {
            MsgBox "A map profile with this name already exists."
            return
        }
    }
    if (CurrentMapProfileName != "")
        SaveMapProfileToIni(CurrentMapProfileName)
    MapProfileNames.Push(name)
    mapProfileDdl.Add([name])
    mapProfileDdl.Text := name
    CurrentMapProfileName := name
    mapExpectedTextEdit.Value := name
    mapCustomTowersChk.Value := 0
    for row in PlaceData {
        row.CustomSlotDdl.Text := "1"
        row.XEdit.Value := "0"
        row.YEdit.Value := "0"
    }
    ; New maps start on the shared camera/zoom default (not their own custom copy).
    mapCustomCameraChk.Value := 0
    LoadMapAdvStepsForProfile(name)
    UpdatePlacementVisibility()
    SaveMapProfileToIni(name)
    IniWrite JoinList(MapProfileNames), ConfigFile, "MapProfiles", "List"
    IniWrite CurrentMapProfileName, ConfigFile, "MapProfiles", "Active"
    RebuildDefaultMapDdl()
    LogMsg("Map profile '" name "' created.")
}

RenameMapProfileClick(*) {
    global CurrentMapProfileName, mapProfileDdl, MapProfileNames, ConfigFile
    ib := InputBox("Rename map profile '" CurrentMapProfileName "' to:", "Rename Map Profile", , CurrentMapProfileName)
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    newName := Trim(ib.Value)
    if (newName = CurrentMapProfileName)
        return
    for n in MapProfileNames {
        if (n = newName) {
            MsgBox "A map profile with this name already exists."
            return
        }
    }
    SaveMapProfileToIni(newName)
    IniDelete ConfigFile, "MapProfile_" CurrentMapProfileName
    for idx, n in MapProfileNames {
        if (n = CurrentMapProfileName) {
            MapProfileNames[idx] := newName
            break
        }
    }
    RebuildMapProfileDdl()
    mapProfileDdl.Text := newName
    CurrentMapProfileName := newName
    IniWrite JoinList(MapProfileNames), ConfigFile, "MapProfiles", "List"
    IniWrite CurrentMapProfileName, ConfigFile, "MapProfiles", "Active"
    RebuildDefaultMapDdl()
    LogMsg("Map profile renamed to '" newName "'.")
}

DeleteMapProfileClick(*) {
    global CurrentMapProfileName, mapProfileDdl, MapProfileNames, ConfigFile
    if (MapProfileNames.Length <= 1) {
        MsgBox "At least one map profile must remain."
        return
    }
    res := MsgBox("Delete map profile '" CurrentMapProfileName "'?", "Confirm", "YesNo")
    if (res != "Yes")
        return
    IniDelete ConfigFile, "MapProfile_" CurrentMapProfileName
    newList := []
    for n in MapProfileNames {
        if (n != CurrentMapProfileName)
            newList.Push(n)
    }
    MapProfileNames := newList
    RebuildMapProfileDdl()
    CurrentMapProfileName := MapProfileNames[1]
    mapProfileDdl.Text := CurrentMapProfileName
    LoadMapProfile(CurrentMapProfileName)
    IniWrite JoinList(MapProfileNames), ConfigFile, "MapProfiles", "List"
    IniWrite CurrentMapProfileName, ConfigFile, "MapProfiles", "Active"
    RebuildDefaultMapDdl()
    LogMsg("Map profile deleted.")
}

; ============================================================
; MAP DETECTION VIA OCR (Windows.Media.Ocr, same engine as PowerToys Text Extractor)
; ============================================================
; Builds a {x,y,w,h} rect from a step's own Region1 (X,Y) / Region2 (EndX,EndY) fields - every
; Logic step (Detect Map / Round End Detection / Ingame Detection) carries its own region now,
; instead of there being one shared region per detection kind.
RectFromStep(step) {
    x1 := SafeInt(step.X), y1 := SafeInt(step.Y)
    x2 := SafeInt(step.EndX), y2 := SafeInt(step.EndY)
    return {x: Min(x1, x2), y: Min(y1, y2), w: Abs(x2 - x1), h: Abs(y2 - y1)}
}

; Captures the given screen region and runs it through Windows' built-in OCR engine
; via a small PowerShell helper script. Returns the recognized text (may be empty).
; outFileName defaults to the shared result file used by step/option OCR calls; pass a distinct
; name (as the disconnect-detection timer does) so a scan running on its own timer never races
; with an OCR call already in progress on the main thread over the same file.
RunOcrOnRegion(x, y, w, h, outFileName := "ocr_result.txt") {
    scriptPath := A_ScriptDir "\ocr_region.ps1"
    outFile := A_ScriptDir "\" outFileName
    try FileDelete outFile

    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' scriptPath '" -X ' x ' -Y ' y ' -Width ' w ' -Height ' h ' > "' outFile '" 2>&1'
    RunWait A_ComSpec ' /c "' cmd '"', , "Hide"

    text := ""
    try text := Trim(FileRead(outFile))
    return text
}

; Runs the step editor's own "Test OCR" button - tests whatever region/expected-text is currently
; entered for the selected Logic step (not necessarily saved yet).
StepTestOcrClick(*) {
    global stepTypeDdl, stepXEdit, stepYEdit, dragEndXEdit, dragEndYEdit, stepLabelEdit, stepOcrResultText, MapProfileNames
    rect := {x: Min(SafeInt(stepXEdit.Value), SafeInt(dragEndXEdit.Value)),
        y: Min(SafeInt(stepYEdit.Value), SafeInt(dragEndYEdit.Value)),
        w: Abs(SafeInt(dragEndXEdit.Value) - SafeInt(stepXEdit.Value)),
        h: Abs(SafeInt(dragEndYEdit.Value) - SafeInt(stepYEdit.Value))}
    if (rect.w <= 0 || rect.h <= 0) {
        MsgBox "Set both Region1 and Region2 positions first."
        return
    }
    stepOcrResultText.Text := "Reading..."
    text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h)
    if (text = "") {
        stepOcrResultText.Text := "(no text recognized)"
        LogMsg("Step OCR test result: (no text recognized)")
        return
    }
    if (stepTypeDdl.Text = "Detect Map") {
        matched := ""
        for name in MapProfileNames {
            expected := Cfg("MapProfile_" name, "ExpectedText", "")
            if (expected != "" && InStr(text, expected)) {
                matched := name
                break
            }
        }
        if (matched = "") {
            for name in MapProfileNames {
                expected := Cfg("MapProfile_" name, "ExpectedText", "")
                if (expected != "" && TextContainsPartialMatch(text, expected, 6)) {
                    matched := name
                    break
                }
            }
        }
        stepOcrResultText.Text := "Recognized: '" text "' -> map: " (matched != "" ? matched : "(none matched)")
    } else {
        expected := stepLabelEdit.Value
        isMatch := (expected != "") && (InStr(text, expected) || TextContainsPartialMatch(text, expected, 6))
        stepOcrResultText.Text := "Recognized: '" text "' -> " (isMatch ? "MATCH" : "no match")
    }
    LogMsg("Step OCR test result: '" text "'")
}

; Returns true if any run of `minLen` consecutive characters from `needle` appears
; somewhere in `haystack` (case-insensitive). This is more forgiving than a full
; substring match, since OCR output can include extra lines (e.g. a difficulty
; label or category above/below the actual map name) or misread a stray character
; such as an apostrophe.
TextContainsPartialMatch(haystack, needle, minLen := 4) {
    haystackLower := StrLower(haystack)
    needleLower := StrLower(Trim(needle))
    len := StrLen(needleLower)
    if (len = 0)
        return false
    if (len <= minLen)
        return InStr(haystackLower, needleLower) > 0
    Loop len - minLen + 1 {
        chunk := SubStr(needleLower, A_Index, minLen)
        if InStr(haystackLower, chunk)
            return true
    }
    return false
}

; Scans `rect` via OCR and matches the result against each map profile's expected text. Checks
; every profile for an exact (full) match first, and only falls back to a forgiving 6-character
; partial match (for OCR misreads/extra lines) if nothing matched exactly - this ordering matters,
; since two map names that happen to share a short substring (e.g. "Kings Tomb" / "Rose Kingdom"
; both contain "king") could otherwise be confused with each other. Reads profile data directly
; from the ini file so it works regardless of what's shown in the UI.
DetectMapProfileInRegion(rect, timeoutSec := 5) {
    global MapProfileNames
    if (rect.w <= 0 || rect.h <= 0) {
        LogMsg("WARNING: this Detect Map step's region is not set.")
        return ""
    }

    startTime := A_TickCount
    Loop {
        text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h)
        if (text != "") {
            for name in MapProfileNames {
                expected := Cfg("MapProfile_" name, "ExpectedText", "")
                if (expected != "" && InStr(text, expected))
                    return name
            }
            for name in MapProfileNames {
                expected := Cfg("MapProfile_" name, "ExpectedText", "")
                if (expected != "" && TextContainsPartialMatch(text, expected, 6))
                    return name
            }
        }
        if (A_TickCount - startTime > timeoutSec * 1000)
            return ""
        Sleep 300
    }
}

; Runs the General tab's own "Test OCR" button - tests whatever region/expected-text is currently
; entered for Disconnect Detection (not necessarily saved yet).
DisconnectTestOcrClick(*) {
    global disconnectX1Edit, disconnectY1Edit, disconnectX2Edit, disconnectY2Edit, disconnectTextEdit, disconnectOcrResultText
    rect := {x: Min(SafeInt(disconnectX1Edit.Value), SafeInt(disconnectX2Edit.Value)),
        y: Min(SafeInt(disconnectY1Edit.Value), SafeInt(disconnectY2Edit.Value)),
        w: Abs(SafeInt(disconnectX2Edit.Value) - SafeInt(disconnectX1Edit.Value)),
        h: Abs(SafeInt(disconnectY2Edit.Value) - SafeInt(disconnectY1Edit.Value))}
    if (rect.w <= 0 || rect.h <= 0) {
        MsgBox "Set both Region1 and Region2 positions first."
        return
    }
    disconnectOcrResultText.Text := "Reading..."
    text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h, "ocr_result_disconnect.txt")
    if (text = "") {
        disconnectOcrResultText.Text := "(no text recognized)"
        LogMsg("Disconnect detection OCR test: (no text recognized)")
        return
    }
    expected := disconnectTextEdit.Value
    isMatch := (expected != "") && (InStr(text, expected) || TextContainsPartialMatch(text, expected, 6))
    disconnectOcrResultText.Text := "Recognized: '" text "' -> " (isMatch ? "MATCH" : "no match")
    LogMsg("Disconnect detection OCR test result: '" text "'")
}

; One OCR scan of `rect`, compared against `expected` using the same exact-then-fuzzy match as
; map detection. Returns false if the region or expected text isn't configured.
IsTextDetectedInRegion(rect, expected) {
    if (expected = "" || rect.w <= 0 || rect.h <= 0)
        return false
    text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h)
    if (text = "")
        return false
    return InStr(text, expected) || TextContainsPartialMatch(text, expected, 6)
}

; Reads a map profile's placement rows directly from the ini file (for use at runtime).
GetMapProfilePlacements(name) {
    section := "MapProfile_" name
    n := Integer(Cfg("General", "NumPlacements", "4"))
    customTowers := Integer(Cfg(section, "CustomTowers", "0"))
    rows := []
    Loop n {
        i := A_Index
        slot := customTowers ? Cfg(section, "CustomSlot" i, "1") : Cfg("General", "Slot" i, "1")
        rows.Push({Slot: slot,
            X: Cfg(section, "Placement" i "X", "0"),
            Y: Cfg(section, "Placement" i "Y", "0")})
    }
    return rows
}

; Right-click-drags the camera from one point to another (e.g. to reset it to a fixed
; top-down angle) for maps that need it before towers are placed. Reads settings directly
; from ini so it works the same whether called from the running macro or tested manually.
; Shared right-click-drag primitive: moves to (startX,startY), holds right-click, drags in small
; interpolated steps to (endX,endY) over ~durMs, then releases. Used by both the per-map camera
; centering (Advanced Settings) and the standalone "Drag" step type.
DragRightClick(startX, startY, endX, endY, durMs) {
    MouseMove startX, startY, 0
    Sleep 50
    Click startX, startY, "Right", 1, "D"
    Sleep 50
    steps := Max(5, Integer(durMs / 20))
    Loop steps {
        f := A_Index / steps
        ix := Round(startX + (endX - startX) * f)
        iy := Round(startY + (endY - startY) * f)
        MouseMove ix, iy, 0
        Sleep 20
    }
    Sleep 50
    Click endX, endY, "Right", 1, "U"
}

ZoomOutTicks(ticks) {
    if (ticks > 0) {
        Click "WheelDown " ticks
        LogMsg("Zoomed out (" ticks " wheel ticks) for map setup.")
    }
}

; ============================================================
; MAP ADVANCED STEPS (Drag / Zoom Out actions, per map profile or shared [General])
; ============================================================

; Reads the ordered list of map actions for `section`. One-time migrates from the old single
; Center-Camera-drag + single Zoom-Out-ticks flags the first time a section is read, then persists
; the migrated list so this only happens once per section.
GetMapAdvSteps(section) {
    global ConfigFile
    if (Cfg(section, "AdvStepsMigrated", "0") != "1") {
        arr := []
        if (Integer(Cfg(section, "CenterCamera", "0"))) {
            arr.Push({Type: "Drag", X: Cfg(section, "CamStartX", "0"), Y: Cfg(section, "CamStartY", "0"),
                EndX: Cfg(section, "CamEndX", "0"), EndY: Cfg(section, "CamEndY", "0"), DragMs: Cfg(section, "CamDragMs", "500")})
        }
        if (Integer(Cfg(section, "ZoomOut", "0"))) {
            arr.Push({Type: "Zoom Out", X: Cfg(section, "ZoomTicks", "5"), Y: "0", EndX: "0", EndY: "0", DragMs: "500"})
        }
        SaveMapAdvStepsArr(section, arr)
        IniWrite 1, ConfigFile, section, "AdvStepsMigrated"
        return arr
    }
    n := Integer(Cfg(section, "AdvStepsCount", "0"))
    arr := []
    Loop n {
        i := A_Index
        arr.Push({Type: Cfg(section, "AdvStep" i "Type", "Drag"),
            X: Cfg(section, "AdvStep" i "X", "0"),
            Y: Cfg(section, "AdvStep" i "Y", "0"),
            EndX: Cfg(section, "AdvStep" i "EndX", "0"),
            EndY: Cfg(section, "AdvStep" i "EndY", "0"),
            DragMs: Cfg(section, "AdvStep" i "DragMs", "500")})
    }
    return arr
}

; Writes an array of {Type,X,Y,EndX,EndY,DragMs} objects to `section`.
SaveMapAdvStepsArr(section, arr) {
    global ConfigFile
    IniWrite arr.Length, ConfigFile, section, "AdvStepsCount"
    for i, s in arr {
        IniWrite s.Type, ConfigFile, section, "AdvStep" i "Type"
        IniWrite s.X, ConfigFile, section, "AdvStep" i "X"
        IniWrite s.Y, ConfigFile, section, "AdvStep" i "Y"
        IniWrite s.EndX, ConfigFile, section, "AdvStep" i "EndX"
        IniWrite s.EndY, ConfigFile, section, "AdvStep" i "EndY"
        IniWrite s.DragMs, ConfigFile, section, "AdvStep" i "DragMs"
    }
}

; Loads a section's map actions into mapAdvStepsLV (editor UI only).
LoadMapAdvStepsLV(section) {
    global mapAdvStepsLV
    mapAdvStepsLV.Delete()
    for i, s in GetMapAdvSteps(section)
        mapAdvStepsLV.Add("", i, s.Type, s.X, s.Y, s.EndX, s.EndY, s.DragMs)
}

; Saves whatever's currently in mapAdvStepsLV as `section`'s map actions.
SaveMapAdvStepsFromLV(section) {
    global mapAdvStepsLV
    arr := []
    n := mapAdvStepsLV.GetCount()
    Loop n {
        i := A_Index
        arr.Push({Type: mapAdvStepsLV.GetText(i, 2), X: mapAdvStepsLV.GetText(i, 3), Y: mapAdvStepsLV.GetText(i, 4),
            EndX: mapAdvStepsLV.GetText(i, 5), EndY: mapAdvStepsLV.GetText(i, 6), DragMs: mapAdvStepsLV.GetText(i, 7)})
    }
    SaveMapAdvStepsArr(section, arr)
}

; Shows/hides the Drag-only fields (End X/Y, Drag ms) and relabels X (Start X for Drag, Ticks for
; Zoom Out); Y and "Set Position" only make sense for Drag's start point.
UpdateMapAdvEditorLabels(*) {
    global mapAdvTypeDdl, mapAdvXLabel, mapAdvYLabel, mapAdvYEdit, mapAdvPosBtn
    global mapAdvEndXLabel, mapAdvEndXEdit, mapAdvEndYLabel, mapAdvEndYEdit, mapAdvEndPosBtn, mapAdvMsLabel, mapAdvMsEdit
    isDrag := (mapAdvTypeDdl.Text = "Drag")
    for ctrl in [mapAdvEndXLabel, mapAdvEndXEdit, mapAdvEndYLabel, mapAdvEndYEdit, mapAdvEndPosBtn, mapAdvMsLabel, mapAdvMsEdit]
        ctrl.Visible := isDrag
    mapAdvXLabel.Text := isDrag ? "Start X:" : "Ticks:"
    mapAdvYLabel.Visible := isDrag
    mapAdvYEdit.Visible := isDrag
    mapAdvPosBtn.Visible := isDrag
}

MapAdvLoadEditorFromSelection(*) {
    global mapAdvStepsLV, mapAdvTypeDdl, mapAdvXEdit, mapAdvYEdit, mapAdvEndXEdit, mapAdvEndYEdit, mapAdvMsEdit
    row := mapAdvStepsLV.GetNext(0, "Focused")
    if !row
        return
    mapAdvTypeDdl.Text := mapAdvStepsLV.GetText(row, 2)
    mapAdvXEdit.Value := mapAdvStepsLV.GetText(row, 3)
    mapAdvYEdit.Value := mapAdvStepsLV.GetText(row, 4)
    mapAdvEndXEdit.Value := mapAdvStepsLV.GetText(row, 5)
    mapAdvEndYEdit.Value := mapAdvStepsLV.GetText(row, 6)
    mapAdvMsEdit.Value := mapAdvStepsLV.GetText(row, 7)
    UpdateMapAdvEditorLabels()
}

MapAdvAddStepClick(*) {
    global mapAdvStepsLV, mapAdvTypeDdl, mapAdvXEdit, mapAdvYEdit, mapAdvEndXEdit, mapAdvEndYEdit, mapAdvMsEdit
    mapAdvStepsLV.Add("", mapAdvStepsLV.GetCount() + 1, mapAdvTypeDdl.Text, mapAdvXEdit.Value, mapAdvYEdit.Value,
        mapAdvEndXEdit.Value, mapAdvEndYEdit.Value, mapAdvMsEdit.Value)
}

MapAdvUpdateSelectedClick(*) {
    global mapAdvStepsLV, mapAdvTypeDdl, mapAdvXEdit, mapAdvYEdit, mapAdvEndXEdit, mapAdvEndYEdit, mapAdvMsEdit
    row := mapAdvStepsLV.GetNext(0, "Focused")
    if !row {
        LogMsg("No map action selected.")
        return
    }
    mapAdvStepsLV.Modify(row, "", row, mapAdvTypeDdl.Text, mapAdvXEdit.Value, mapAdvYEdit.Value,
        mapAdvEndXEdit.Value, mapAdvEndYEdit.Value, mapAdvMsEdit.Value)
}

MapAdvRemoveSelectedClick(*) {
    global mapAdvStepsLV
    row := mapAdvStepsLV.GetNext(0, "Focused")
    if !row
        return
    mapAdvStepsLV.Delete(row)
    n := mapAdvStepsLV.GetCount()
    Loop n
        mapAdvStepsLV.Modify(A_Index, "", A_Index)
}

MapAdvSwapRows(r1, r2) {
    global mapAdvStepsLV
    t1 := mapAdvStepsLV.GetText(r1, 2), x1 := mapAdvStepsLV.GetText(r1, 3), y1 := mapAdvStepsLV.GetText(r1, 4)
    ex1 := mapAdvStepsLV.GetText(r1, 5), ey1 := mapAdvStepsLV.GetText(r1, 6), dm1 := mapAdvStepsLV.GetText(r1, 7)
    t2 := mapAdvStepsLV.GetText(r2, 2), x2 := mapAdvStepsLV.GetText(r2, 3), y2 := mapAdvStepsLV.GetText(r2, 4)
    ex2 := mapAdvStepsLV.GetText(r2, 5), ey2 := mapAdvStepsLV.GetText(r2, 6), dm2 := mapAdvStepsLV.GetText(r2, 7)
    mapAdvStepsLV.Modify(r1, "", r1, t2, x2, y2, ex2, ey2, dm2)
    mapAdvStepsLV.Modify(r2, "", r2, t1, x1, y1, ex1, ey1, dm1)
}

MapAdvMoveUpClick(*) {
    global mapAdvStepsLV
    row := mapAdvStepsLV.GetNext(0, "Focused")
    if (!row || row = 1)
        return
    MapAdvSwapRows(row, row - 1)
    mapAdvStepsLV.Modify(row - 1, "Focus Select")
}

MapAdvMoveDownClick(*) {
    global mapAdvStepsLV
    row := mapAdvStepsLV.GetNext(0, "Focused")
    n := mapAdvStepsLV.GetCount()
    if (!row || row = n)
        return
    MapAdvSwapRows(row, row + 1)
    mapAdvStepsLV.Modify(row + 1, "Focus Select")
}

; ============================================================
; STEP EDITOR FIELD VISIBILITY (depends on step type)
; ============================================================
; "Logic" steps are the OCR-driven detection types - each has its own region + expected text and
; can jump to another screen on true/false. Everything else is a "Mechanic" step (an action).
IsLogicStepType(t) {
    return (t = "Detect Map" || t = "Round End Detection" || t = "Ingame Detection" || t = "Custom Detection")
}

UpdateStepEditorLabels(*) {
    global stepTypeDdl, stepXLabel, stepYLabel, stepXEdit, stepYEdit, stepPosBtn, stepLabelLbl, OptionSectionControls
    global dragEndXLabel, dragEndXEdit, dragEndYLabel, dragEndYEdit, dragEndPosBtn, dragMsLabel, dragMsEdit
    global stepOcrTestBtn, stepOcrResultText, stepOnTrueLbl, stepOnTrueDdl, stepOnFalseLbl, stepOnFalseDdl
    t := stepTypeDdl.Text
    isDrag := (t = "Drag")
    isLogic := IsLogicStepType(t)

    ; Challenge options are only relevant while working on an "Option Select" step.
    for ctrl in OptionSectionControls
        ctrl.Visible := (t = "Option Select")

    ; This row is Drag's end point + duration, OR (relabeled below) a Logic step's second region
    ; corner - the duration field only makes sense for Drag.
    for ctrl in [dragEndXLabel, dragEndXEdit, dragEndYLabel, dragEndYEdit, dragEndPosBtn]
        ctrl.Visible := (isDrag || isLogic)
    dragMsLabel.Visible := isDrag
    dragMsEdit.Visible := isDrag
    dragEndXLabel.Text := isLogic ? "Region2 X:" : "End X:"
    dragEndYLabel.Text := isLogic ? "Region2 Y:" : "End Y:"

    ; Logic-only: test the region/expected-text currently entered.
    for ctrl in [stepOcrTestBtn, stepOcrResultText]
        ctrl.Visible := isLogic

    ; Every step type can jump to another screen when it finishes. Logic steps get two branches
    ; (On True/On False, based on the OCR result); Mechanic steps get a single unconditional jump
    ; (reusing the same "On True" field/column - e.g. a plain Round End button that just always
    ; goes back to "Ingame" with no detection needed).
    stepOnTrueLbl.Visible := true
    stepOnTrueDdl.Visible := true
    stepOnTrueLbl.Text := isLogic ? "On True ->" : "Then Go To ->"
    stepOnFalseLbl.Visible := isLogic
    stepOnFalseDdl.Visible := isLogic

    ; The Label field doubles as the OCR "expected text" for Round End/Ingame/Custom Detection
    ; (Detect Map instead matches against every map profile's own expected text, so its Label is
    ; just an optional free description). "Custom Detection" is a freely-nameable version of the
    ; same check - use it for any extra popup/screen you need to detect and click through, without
    ; touching the built-in Map/Round End/Ingame detection logic.
    stepLabelLbl.Text := (t = "Round End Detection" || t = "Ingame Detection" || t = "Custom Detection") ? "Expected Text:" : "Label:"

    if (t = "Zoom Out") {
        stepXLabel.Text := "Ticks:"
        stepXLabel.Visible := true
        stepXEdit.Visible := true
        stepYLabel.Visible := false
        stepYEdit.Visible := false
        stepPosBtn.Visible := false
    } else if (t = "Button Click" || t = "Press Start Button" || t = "Restart Stage Button") {
        stepXLabel.Text := "X:"
        stepXLabel.Visible := true
        stepXEdit.Visible := true
        stepYLabel.Visible := true
        stepYEdit.Visible := true
        stepPosBtn.Visible := true
    } else if (t = "Drag") {
        stepXLabel.Text := "Start X:"
        stepXLabel.Visible := true
        stepXEdit.Visible := true
        stepYLabel.Visible := true
        stepYEdit.Visible := true
        stepPosBtn.Visible := true
    } else if isLogic {
        stepXLabel.Text := "Region1 X:"
        stepXLabel.Visible := true
        stepXEdit.Visible := true
        stepYLabel.Visible := true
        stepYEdit.Visible := true
        stepPosBtn.Visible := true
    } else {
        ; Start, Option Select, Camera Setup, Place Towers, Wait -> no coordinates needed here
        stepXLabel.Visible := false
        stepXEdit.Visible := false
        stepYLabel.Visible := false
        stepYEdit.Visible := false
        stepPosBtn.Visible := false
    }
    stepYLabel.Text := (t = "Drag") ? "Start Y:" : (isLogic ? "Region1 Y:" : "Y:")
}

; Runs only when the user manually picks a type from the dropdown (fresh authoring) - prefills
; sensible default coordinates for the named button steps. Not called when loading an existing
; step's saved data (LoadEditorFromSelection calls UpdateStepEditorLabels directly instead), so
; editing an existing step never clobbers its already-customized position.
StepTypeChangedByUser(*) {
    global stepTypeDdl, stepXEdit, stepYEdit
    t := stepTypeDdl.Text
    if (t = "Press Start Button") {
        stepXEdit.Value := "733"
        stepYEdit.Value := "555"
    } else if (t = "Restart Stage Button") {
        stepXEdit.Value := "400"
        stepYEdit.Value := "620"
    }
    UpdateStepEditorLabels()
}

; ============================================================
; POSITION CAPTURE (F8) - with a red dot marker that follows the mouse
; ============================================================
GetMarkerSize() {
    global markerSizeEdit
    size := SafeInt(markerSizeEdit.Value, 4)
    return (size < 1) ? 1 : size
}

CreateMarker() {
    global MarkerGui
    MarkerGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
    MarkerGui.BackColor := "FF0000"
    size := GetMarkerSize()
    MarkerGui.Show("x-100 y-100 w" size " h" size " NoActivate Hide")
}

UpdateMarkerPos() {
    global MarkerGui
    MouseGetPos &mx, &my
    size := GetMarkerSize()
    half := size // 2
    try MarkerGui.Move(mx - half, my - half, size, size)
}

HideMarker() {
    global MarkerGui
    try MarkerGui.Hide()
}

StartCapture(xCtrl, yCtrl, *) {
    global CaptureTarget, CaptureXCtrl, CaptureYCtrl, MyGui, MarkerGui
    CaptureXCtrl := xCtrl
    CaptureYCtrl := yCtrl
    CaptureTarget := "active"
    MyGui.Hide()
    try MarkerGui.Show("NoActivate")
    SetTimer UpdateMarkerPos, 30
    ToolTip "Move the mouse to the target position and press F8. Escape = Cancel."
}

F8:: {
    global CaptureTarget, CaptureXCtrl, CaptureYCtrl, MyGui, MarkerGui
    if (CaptureTarget != "active")
        return
    MouseGetPos &mx, &my
    CaptureXCtrl.Value := mx
    CaptureYCtrl.Value := my
    CaptureTarget := ""
    SetTimer UpdateMarkerPos, 0
    size := GetMarkerSize()
    half := size // 2
    try MarkerGui.Move(mx - half, my - half, size, size)
    SetTimer HideMarker, -2000
    ToolTip()
    MyGui.Show()
}

; ============================================================
; GAME WINDOW / PROCESS LIST
; ============================================================
RefreshProcessList(*) {
    global gameProcessDdl, ConfigFile
    list := []
    seen := Map()
    ownPID := ProcessExist()
    for hwnd in WinGetList() {
        try {
            pid := WinGetPID(hwnd)
            if (pid = ownPID)
                continue
            title := WinGetTitle(hwnd)
            if (title = "")
                continue
            proc := WinGetProcessName(hwnd)
            if (proc = "" || seen.Has(proc))
                continue
            seen[proc] := true
            list.Push(title " | " proc)
        }
    }
    gameProcessDdl.Delete()
    gameProcessDdl.Add(list)

    savedProc := Cfg("General", "GameProcess", "")
    if (savedProc != "") {
        for entry in list {
            parts := StrSplit(entry, " | ")
            if (parts.Length >= 2 && parts[2] = savedProc) {
                gameProcessDdl.Text := entry
                break
            }
        }
    }
}

GetSelectedGameProcess() {
    global gameProcessDdl
    t := gameProcessDdl.Text
    if (t = "")
        return ""
    parts := StrSplit(t, " | ")
    return parts.Length >= 2 ? parts[2] : ""
}

; ============================================================
; FULLSCREEN GRAY OVERLAY WITH A RECTANGULAR OPENING
; Built from 4 borderless always-on-top bars forming a frame around the opening,
; instead of punching an actual hole in one window (simpler and more reliable).
; ============================================================
GetHoleRect() {
    global holeXEdit, holeYEdit, holeWEdit, holeHEdit
    return {x: SafeInt(holeXEdit.Value), y: SafeInt(holeYEdit.Value),
        w: SafeInt(holeWEdit.Value), h: SafeInt(holeHEdit.Value)}
}

CreateOverlay() {
    global OverlayGuis, OverlayVisible, LogGui, LogEdit, LogLines, StatsGui
    global StatsCycleText, StatsMapText, StatsScreenText, StatsStepText
    if OverlayVisible
        return
    hole := GetHoleRect()
    screenW := A_ScreenWidth
    screenH := A_ScreenHeight

    bars := [
        {x: 0, y: 0, w: screenW, h: hole.y},                                          ; top
        {x: 0, y: hole.y + hole.h, w: screenW, h: screenH - (hole.y + hole.h)},        ; bottom
        {x: 0, y: hole.y, w: hole.x, h: hole.h},                                       ; left
        {x: hole.x + hole.w, y: hole.y, w: screenW - (hole.x + hole.w), h: hole.h}     ; right
    ]

    for b in bars {
        if (b.w <= 0 || b.h <= 0)
            continue
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
        g.BackColor := "3C3C3C"
        g.Show("x" b.x " y" b.y " w" b.w " h" b.h " NoActivate")
        OverlayGuis.Push(g)
    }

    ; Log panel: a black console filling the gray area to the right of the game window, if there's
    ; enough room there - inset 50px from the hole's right edge AND the screen's right edge, so the
    ; gray margin on the right matches the gray margin already visible on the left.
    rightW := screenW - (hole.x + hole.w)
    sideGap := 50
    panelX := hole.x + hole.w + sideGap
    panelW := rightW - sideGap * 2
    if (rightW > 2 * sideGap + 80 && panelW > 80) {
        margin := 10
        LogGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
        LogGui.BackColor := "000000"
        LogGui.SetFont("s9 cWhite", "Consolas")
        LogEdit := LogGui.AddEdit("x" margin " y" margin " w" (panelW - margin * 2) " h" (hole.h - margin * 2)
            . " ReadOnly VScroll Background000000 cWhite")
        LogGui.Show("x" panelX " y" hole.y " w" panelW " h" hole.h " NoActivate")
        ; Seed the panel with whatever's already in the log so far, instead of starting blank.
        RenderLogPanel()
    } else {
        LogGui := ""
        LogEdit := ""
        panelX := hole.x + hole.w
        panelW := 0
    }

    ; Application Stats panel: a wide black bar BELOW the game window and log panel, spanning from
    ; the game window's left edge to the log panel's right edge, placed in the bottom gray bar.
    statsAreaY := hole.y + hole.h
    statsAreaH := screenH - statsAreaY
    if (statsAreaH > 80) {
        statsMargin := 10
        statsGapTop := 20
        statsGapBottom := 50   ; distance from the panel's bottom edge to the screen's bottom edge
        statsX := hole.x
        statsW := (panelX + panelW) - hole.x
        statsH := Max(80, statsAreaH - statsGapTop - statsGapBottom)
        statsY := statsAreaY + statsGapTop

        StatsGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
        StatsGui.BackColor := "000000"

        StatsGui.SetFont("s13 cWhite Bold", "Segoe UI")
        StatsGui.AddText("x" statsMargin " y" statsMargin " w" (statsW - statsMargin * 2 - 80) " h26", "Application Stats")
        StatsGui.SetFont("s9 cBlack Norm", "Segoe UI")
        statsCopyBtn := StatsGui.AddButton("x" (statsW - statsMargin - 70) " y" statsMargin " w70 h22", "Copy")
        statsCopyBtn.OnEvent("Click", (*) => CopyStatsClick())

        ; Four evenly spaced columns across the full width - label on top, big value underneath.
        colW := Integer((statsW - statsMargin * 2) / 4)
        labels := ["Cycle Count", "Current Map", "Current Screen", "Current Step"]
        colTexts := []
        rowY := statsMargin + 44
        loop 4 {
            colX := statsMargin + (A_Index - 1) * colW
            StatsGui.SetFont("s9 cWhite Norm", "Segoe UI")
            StatsGui.AddText("x" colX " y" rowY " w" (colW - 10) " h16", labels[A_Index])
            StatsGui.SetFont("s14 cWhite Bold", "Segoe UI")
            valTxt := StatsGui.AddText("x" colX " y" (rowY + 20) " w" (colW - 10) " h26", "-")
            colTexts.Push(valTxt)
        }
        StatsCycleText := colTexts[1]
        StatsMapText := colTexts[2]
        StatsScreenText := colTexts[3]
        StatsStepText := colTexts[4]

        StatsGui.Show("x" statsX " y" statsY " w" statsW " h" statsH " NoActivate")
        RenderStatsPanel()
    } else {
        StatsGui := ""
        StatsCycleText := ""
        StatsMapText := ""
        StatsScreenText := ""
        StatsStepText := ""
    }

    OverlayVisible := true
    LogMsg("Overlay opened.")
}

CloseOverlay(*) {
    global OverlayGuis, OverlayVisible, LockedProcess, LogGui, LogEdit, StatsGui
    global StatsCycleText, StatsMapText, StatsScreenText, StatsStepText
    SetTimer EnforceWindowLock, 0
    LockedProcess := ""
    for g in OverlayGuis {
        try g.Destroy()
    }
    OverlayGuis := []
    if (LogGui != "") {
        try LogGui.Destroy()
    }
    LogGui := ""
    LogEdit := ""
    if (StatsGui != "") {
        try StatsGui.Destroy()
    }
    StatsGui := ""
    StatsCycleText := ""
    StatsMapText := ""
    StatsScreenText := ""
    StatsStepText := ""
    OverlayVisible := false
    LogMsg("Overlay closed. Window lock released.")
}

; Removes the Windows 11 rounded-corner effect on a window so it fills the
; opening flush, with no background peeking through at the corners.
DisableRoundedCorners(hwnd) {
    DWMWA_WINDOW_CORNER_PREFERENCE := 33
    DWMWCP_DONOTROUND := 1
    pref := DWMWCP_DONOTROUND
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", DWMWA_WINDOW_CORNER_PREFERENCE, "Int*", pref, "Int", 4)
}

; Windows reserves an invisible resize border around most windows that is not part of
; the rect WinMove positions, but does shift the visible edge inward by a few pixels.
; This measures that gap via DWM's "extended frame bounds" so we can compensate for it.
GetVisibleFrameGaps(hwnd, &leftGap, &topGap, &rightGap, &bottomGap) {
    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    rect := Buffer(16, 0)
    result := DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", rect, "UInt", 16)
    if (result != 0) {
        leftGap := 0, topGap := 0, rightGap := 0, bottomGap := 0
        return
    }
    fl := NumGet(rect, 0, "Int")
    ft := NumGet(rect, 4, "Int")
    fr := NumGet(rect, 8, "Int")
    fb := NumGet(rect, 12, "Int")
    leftGap := fl - wx
    topGap := ft - wy
    rightGap := (wx + ww) - fr
    bottomGap := (wy + wh) - fb
}

; Moves a window so its VISIBLE edges land exactly on the target rect, correcting for
; the invisible border gap measured above.
MoveWindowToVisibleRect(hwnd, targetX, targetY, targetW, targetH) {
    WinMove targetX, targetY, targetW, targetH, "ahk_id " hwnd
    Sleep 50
    GetVisibleFrameGaps(hwnd, &lg, &tg, &rg, &bg)
    correctedX := targetX - lg
    correctedY := targetY - tg
    correctedW := targetW + lg + rg
    correctedH := targetH + tg + bg
    WinMove correctedX, correctedY, correctedW, correctedH, "ahk_id " hwnd
}

; Continuously snaps the game window back into the opening if it gets dragged or resized.
EnforceWindowLock() {
    global LockedProcess
    if (LockedProcess = "")
        return
    winCrit := "ahk_exe " LockedProcess
    hwnd := WinExist(winCrit)
    if !hwnd
        return
    hole := GetHoleRect()
    try {
        GetVisibleFrameGaps(hwnd, &lg, &tg, &rg, &bg)
        targetX := hole.x - lg
        targetY := hole.y - tg
        targetW := hole.w + lg + rg
        targetH := hole.h + tg + bg
        WinGetPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
        if (cx != targetX || cy != targetY || cw != targetW || ch != targetH)
            WinMove targetX, targetY, targetW, targetH, "ahk_id " hwnd
    }
}

; Brings the locked game window back to the foreground. Needed after shelling out to
; PowerShell for OCR, since that can steal keyboard/window focus (even hidden) and cause
; Send (inventory hotkeys) to go to the wrong window while Click still visually works.
ReactivateGameWindow() {
    global LockedProcess
    if (LockedProcess = "")
        return
    winCrit := "ahk_exe " LockedProcess
    if WinExist(winCrit)
        WinActivate winCrit
}

; ============================================================
; DISCONNECT DETECTION (AUTO-RECONNECT)
; ============================================================
; Runs on its own timer the whole time the macro is running, independently of whatever step is
; currently executing. Once every configured interval, scans the configured region for the
; configured "disconnected" text; if found, clicks the Reconnect Button position and asks
; StartMacro() to restart the current preset from the beginning (via DisconnectRestartPending) -
; the same way Escape already stops the run asynchronously mid-step, just auto-resuming afterward
; instead of staying stopped. Uses its own OCR output file (ocr_result_disconnect.txt) so a scan
; firing here never races with a step's own OCR call (e.g. Round End Detection) that might be in
; progress on the main thread at the same moment.
CheckDisconnectTick() {
    global Running, disconnectEnabledChk, disconnectX1Edit, disconnectY1Edit, disconnectX2Edit, disconnectY2Edit
    global disconnectTextEdit, disconnectReconnectXEdit, disconnectReconnectYEdit, disconnectIntervalEdit
    global DisconnectCheckBusy, DisconnectLastCheckTick, DisconnectRestartPending

    if (!Running || DisconnectCheckBusy || !disconnectEnabledChk.Value)
        return

    intervalMs := Max(1000, SafeInt(disconnectIntervalEdit.Value, 5) * 1000)
    if (A_TickCount - DisconnectLastCheckTick < intervalMs)
        return
    DisconnectLastCheckTick := A_TickCount

    expected := disconnectTextEdit.Value
    rect := {x: Min(SafeInt(disconnectX1Edit.Value), SafeInt(disconnectX2Edit.Value)),
        y: Min(SafeInt(disconnectY1Edit.Value), SafeInt(disconnectY2Edit.Value)),
        w: Abs(SafeInt(disconnectX2Edit.Value) - SafeInt(disconnectX1Edit.Value)),
        h: Abs(SafeInt(disconnectY2Edit.Value) - SafeInt(disconnectY1Edit.Value))}
    if (expected = "" || rect.w <= 0 || rect.h <= 0)
        return

    DisconnectCheckBusy := true
    text := RunOcrOnRegion(rect.x, rect.y, rect.w, rect.h, "ocr_result_disconnect.txt")
    if (text = "" || !(InStr(text, expected) || TextContainsPartialMatch(text, expected, 6))) {
        DisconnectCheckBusy := false
        return
    }

    ReactivateGameWindow()
    LogMsg("Disconnect detected ('" text "') - clicking Reconnect and restarting the macro from the beginning.")
    Click SafeInt(disconnectReconnectXEdit.Value), SafeInt(disconnectReconnectYEdit.Value)
    Running := false
    DisconnectRestartPending := true
    DisconnectCheckBusy := false
}
SetTimer(CheckDisconnectTick, 500)

; Ensures the overlay is showing, then moves the game window into the opening
; and locks it there so it can't be dragged or resized out of place by accident.
ForceGameWindow() {
    global LockedProcess
    proc := GetSelectedGameProcess()
    if (proc = "")
        return true  ; no process selected -> feature not in use, not an error

    winCrit := "ahk_exe " proc
    if !WinExist(winCrit) {
        LogMsg("WARNING: game window not found (" proc ").")
        return false
    }

    CreateOverlay()
    hole := GetHoleRect()

    try WinRestore winCrit
    WinActivate winCrit
    Sleep 200
    hwnd := WinExist(winCrit)
    if hwnd {
        DisableRoundedCorners(hwnd)
        MoveWindowToVisibleRect(hwnd, hole.x, hole.y, hole.w, hole.h)
    }

    LockedProcess := proc
    SetTimer EnforceWindowLock, 500

    LogMsg("Game window positioned and locked (" proc "), " hole.w "x" hole.h " at (" hole.x ", " hole.y ").")
    return true
}

PlacementModeClick(*) {
    ClearLog()
    ok := ForceGameWindow()
    if ok
        LogMsg("Placement Mode: window positioned. Use the Set Position buttons to record coordinates.")
    else
        LogMsg("Placement Mode: could not position the game window.")
}

F7::PlacementModeClick()

; ============================================================
; PAUSE / STOP
; ============================================================
F9:: {
    global Paused
    Paused := !Paused
    LogMsg(Paused ? "Paused." : "Resumed.")
}

Escape:: {
    global CaptureTarget, Running, MyGui, OverlayVisible, MarkerGui
    if (CaptureTarget = "active") {
        CaptureTarget := ""
        SetTimer UpdateMarkerPos, 0
        try MarkerGui.Hide()
        ToolTip()
        MyGui.Show()
        LogMsg("Position capture cancelled.")
        return
    }
    if OverlayVisible
        CloseOverlay()
    if Running {
        Running := false
        LogMsg("EMERGENCY STOP: macro stopped.")
    }
}

F10::StartMacro()

; ============================================================
; LOGGING
; ============================================================
; Clears the in-memory/on-screen log (not the log FILE, which stays a full history across runs) -
; called whenever a fresh run starts (macro or Placement Mode) so the panel only shows this run.
ClearLog() {
    global LogLines
    LogLines := []
    RenderLogPanel()
}

LogMsg(text) {
    global LogFile, statusText, LogLines
    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := timestamp " - " text
    try FileAppend line "`n", LogFile
    try statusText.Text := text

    ; Keep only the most recent lines so memory/display don't grow unbounded over a long run.
    LogLines.Push(line)
    maxLines := 200
    while (LogLines.Length > maxLines)
        LogLines.RemoveAt(1)

    RenderLogPanel()
}

; Updates the most recent log line IN PLACE instead of appending a new one, and does NOT write
; to the log file. Used for live-ticking status (e.g. a countdown while waiting) so it doesn't
; spam the log with one line per tick - only the final LogMsg() call after the wait is permanent.
LogMsgReplace(text) {
    global statusText, LogLines
    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := timestamp " - " text
    try statusText.Text := text

    if (LogLines.Length = 0)
        LogLines.Push(line)
    else
        LogLines[LogLines.Length] := line

    RenderLogPanel()
}

RenderLogPanel() {
    global LogEdit, LogLines
    if (LogEdit = "")
        return
    try {
        display := ""
        for l in LogLines
            display .= l "`n"
        LogEdit.Value := display
        ; scroll to bottom (WM_VSCROLL / SB_BOTTOM)
        PostMessage 0x0115, 7, 0, , "ahk_id " LogEdit.Hwnd
    }
}

; Puts the Application Stats panel's current values on the clipboard - same rationale as needed
; anywhere in this NOACTIVATE overlay (see CreateOverlay): its controls can't get real keyboard
; focus, so click-to-select + Ctrl+C doesn't work reliably; a button click does.
CopyStatsClick(*) {
    global CurrentCycleCount, LastDetectedMap, RunningScreenName, RunningStepDescription
    text := "Cycle Count: " CurrentCycleCount "`n"
        . "Current Map: " (LastDetectedMap != "" ? LastDetectedMap : "(none)") "`n"
        . "Current Screen: " (RunningScreenName != "" ? RunningScreenName : "-") "`n"
        . "Current Step: " (RunningStepDescription != "" ? RunningStepDescription : "-")
    A_Clipboard := text
    ToolTip("Stats copied to clipboard.")
    SetTimer((*) => ToolTip(), -1500)
}

; Refreshes the "Application Stats" panel below the log with the current run's live state.
; Safe to call even when the overlay/panel doesn't exist (e.g. before the macro is started).
RenderStatsPanel() {
    global StatsCycleText, StatsMapText, StatsScreenText, StatsStepText
    global CurrentCycleCount, LastDetectedMap, RunningScreenName, RunningStepDescription
    if (StatsCycleText = "")
        return
    try StatsCycleText.Text := CurrentCycleCount
    try StatsMapText.Text := (LastDetectedMap != "" ? LastDetectedMap : "(none)")
    try StatsScreenText.Text := (RunningScreenName != "" ? RunningScreenName : "-")
    try StatsStepText.Text := (RunningStepDescription != "" ? RunningStepDescription : "-")
}

; ============================================================
; SAVE CONFIGURATION
; ============================================================
SaveConfig(*) {
    global ConfigFile
    global roundWaitEdit, clickDelayEdit, placeTowerDelayEdit, maxRoundsEdit
    global CurrentPresetName, PresetNames
    global CurrentMapProfileName, MapProfileNames
    global holeXEdit, holeYEdit, holeWEdit, holeHEdit
    global markerSizeEdit
    global numPlaceDdl, GeneralSlotDdls
    global afterPlaceClickChk, afterPlaceXEdit, afterPlaceYEdit
    global disconnectEnabledChk, disconnectX1Edit, disconnectY1Edit, disconnectX2Edit, disconnectY2Edit
    global disconnectTextEdit, disconnectReconnectXEdit, disconnectReconnectYEdit, disconnectIntervalEdit

    IniWrite roundWaitEdit.Value, ConfigFile, "General", "RoundWaitSeconds"
    IniWrite clickDelayEdit.Value, ConfigFile, "General", "ClickDelayMs"
    IniWrite placeTowerDelayEdit.Value, ConfigFile, "General", "PlaceTowerDelayMs"
    IniWrite afterPlaceClickChk.Value, ConfigFile, "General", "AfterPlaceClick"
    IniWrite afterPlaceXEdit.Value, ConfigFile, "General", "AfterPlaceClickX"
    IniWrite afterPlaceYEdit.Value, ConfigFile, "General", "AfterPlaceClickY"
    IniWrite maxRoundsEdit.Value, ConfigFile, "General", "MaxRounds"
    IniWrite markerSizeEdit.Value, ConfigFile, "General", "MarkerSize"
    IniWrite numPlaceDdl.Text, ConfigFile, "General", "NumPlacements"
    for i, ddl in GeneralSlotDdls
        IniWrite ddl.Text, ConfigFile, "General", "Slot" i
    IniWrite GetSelectedGameProcess(), ConfigFile, "General", "GameProcess"
    IniWrite holeXEdit.Value, ConfigFile, "General", "HoleX"
    IniWrite holeYEdit.Value, ConfigFile, "General", "HoleY"
    IniWrite holeWEdit.Value, ConfigFile, "General", "HoleW"
    IniWrite holeHEdit.Value, ConfigFile, "General", "HoleH"

    IniWrite disconnectEnabledChk.Value, ConfigFile, "General", "DisconnectEnabled"
    IniWrite disconnectX1Edit.Value, ConfigFile, "General", "DisconnectX1"
    IniWrite disconnectY1Edit.Value, ConfigFile, "General", "DisconnectY1"
    IniWrite disconnectX2Edit.Value, ConfigFile, "General", "DisconnectX2"
    IniWrite disconnectY2Edit.Value, ConfigFile, "General", "DisconnectY2"
    IniWrite disconnectTextEdit.Value, ConfigFile, "General", "DisconnectText"
    IniWrite disconnectReconnectXEdit.Value, ConfigFile, "General", "DisconnectReconnectX"
    IniWrite disconnectReconnectYEdit.Value, ConfigFile, "General", "DisconnectReconnectY"
    IniWrite disconnectIntervalEdit.Value, ConfigFile, "General", "DisconnectIntervalSec"

    ; Challenge options and the default-map fallback are saved per-preset inside
    ; SavePresetToIni() below (they live in [Preset_<name>], not [General]).
    if (CurrentPresetName != "")
        SavePresetToIni(CurrentPresetName)
    IniWrite JoinList(PresetNames), ConfigFile, "Presets", "List"
    IniWrite CurrentPresetName, ConfigFile, "Presets", "Active"

    if (CurrentMapProfileName != "")
        SaveMapProfileToIni(CurrentMapProfileName)
    IniWrite JoinList(MapProfileNames), ConfigFile, "MapProfiles", "List"
    IniWrite CurrentMapProfileName, ConfigFile, "MapProfiles", "Active"
}

; ============================================================
; PRESET MANAGEMENT
; ============================================================
; Reads a preset's ordered list of screen names.
GetPresetScreenNames(name) {
    section := "Preset_" name
    n := Integer(Cfg(section, "ScreenCount", "0"))
    arr := []
    Loop n
        arr.Push(Cfg(section, "Screen" A_Index "Name", "Screen " A_Index))
    return arr
}

; Position (1-based) of `screenName` in `name`'s screen list, or 0 if not found.
ScreenIndexByName(name, screenName) {
    for i, n in GetPresetScreenNames(name) {
        if (n = screenName)
            return i
    }
    return 0
}

; Reads one screen's steps by index (used by both the editor and the running macro).
BuildScreenStepsFromIni(name, screenIdx) {
    section := "Preset_" name
    n := Integer(Cfg(section, "Screen" screenIdx "StepCount", "0"))
    arr := []
    Loop n {
        i := A_Index
        arr.Push({Type: Cfg(section, "Screen" screenIdx "Step" i "Type", "Button Click"),
            Label: Cfg(section, "Screen" screenIdx "Step" i "Label", ""),
            X: Cfg(section, "Screen" screenIdx "Step" i "X", "0"),
            Y: Cfg(section, "Screen" screenIdx "Step" i "Y", "0"),
            EndX: Cfg(section, "Screen" screenIdx "Step" i "EndX", "0"),
            EndY: Cfg(section, "Screen" screenIdx "Step" i "EndY", "0"),
            DragMs: Cfg(section, "Screen" screenIdx "Step" i "DragMs", "500"),
            OncePerCycle: Integer(Cfg(section, "Screen" screenIdx "Step" i "OncePerCycle", "0")),
            AlreadyDone: false,
            Seconds: Cfg(section, "Screen" screenIdx "Step" i "Seconds", "0"),
            OnTrueScreen: Cfg(section, "Screen" screenIdx "Step" i "OnTrueScreen", "(continue)"),
            OnFalseScreen: Cfg(section, "Screen" screenIdx "Step" i "OnFalseScreen", "(continue)")})
    }
    return arr
}

BuildScreenStepsFromIniByName(name, screenName) {
    idx := ScreenIndexByName(name, screenName)
    if !idx
        return []
    return BuildScreenStepsFromIni(name, idx)
}

; Writes one screen's full data (name + steps) at the given index. Used for saves, reordering,
; and rebuilding after a delete.
WriteScreenSteps(name, idx, screenName, steps) {
    global ConfigFile
    section := "Preset_" name
    IniWrite screenName, ConfigFile, section, "Screen" idx "Name"
    IniWrite steps.Length, ConfigFile, section, "Screen" idx "StepCount"
    for j, st in steps {
        IniWrite st.Type, ConfigFile, section, "Screen" idx "Step" j "Type"
        IniWrite st.Label, ConfigFile, section, "Screen" idx "Step" j "Label"
        IniWrite st.X, ConfigFile, section, "Screen" idx "Step" j "X"
        IniWrite st.Y, ConfigFile, section, "Screen" idx "Step" j "Y"
        IniWrite st.EndX, ConfigFile, section, "Screen" idx "Step" j "EndX"
        IniWrite st.EndY, ConfigFile, section, "Screen" idx "Step" j "EndY"
        IniWrite st.DragMs, ConfigFile, section, "Screen" idx "Step" j "DragMs"
        IniWrite (st.OncePerCycle ? 1 : 0), ConfigFile, section, "Screen" idx "Step" j "OncePerCycle"
        IniWrite st.OnTrueScreen, ConfigFile, section, "Screen" idx "Step" j "OnTrueScreen"
        IniWrite st.OnFalseScreen, ConfigFile, section, "Screen" idx "Step" j "OnFalseScreen"
        IniWrite st.Seconds, ConfigFile, section, "Screen" idx "Step" j "Seconds"
    }
}

; Loads a preset's screen list into screenDdl and shows the first screen's steps. Seeds a single
; empty "Screen 1" if the preset somehow has none yet.
LoadPresetScreens(name) {
    global screenDdl, CurrentScreenName, ConfigFile
    names := GetPresetScreenNames(name)
    if (names.Length = 0) {
        names := ["Screen 1"]
        IniWrite 1, ConfigFile, "Preset_" name, "ScreenCount"
        IniWrite "Screen 1", ConfigFile, "Preset_" name, "Screen1Name"
        IniWrite 0, ConfigFile, "Preset_" name, "Screen1StepCount"
    }
    screenDdl.Delete()
    screenDdl.Add(names)
    CurrentScreenName := names[1]
    screenDdl.Text := CurrentScreenName
    LoadScreenSteps(name, CurrentScreenName)
}

; Repopulates screenDdl's item list (e.g. after a screen is added/renamed/removed/reordered)
; without touching stepsLV.
RefreshScreenDdlItems(name, selectName) {
    global screenDdl
    screenDdl.Delete()
    screenDdl.Add(GetPresetScreenNames(name))
    screenDdl.Text := selectName
}

; Loads one screen's steps into stepsLV (editor UI only), and refreshes the On True/On False
; jump-target dropdowns to match this preset's current screen list.
LoadScreenSteps(name, screenName) {
    global stepsLV
    stepsLV.Delete()
    for i, s in BuildScreenStepsFromIniByName(name, screenName)
        stepsLV.Add("", i, s.Type, s.Label, s.X, s.Y, s.EndX, s.EndY, s.DragMs, (s.OncePerCycle ? "Yes" : "No"), s.OnTrueScreen, s.OnFalseScreen, s.Seconds)
    RefreshJumpTargetDdls(name)
}

; Saves whatever's currently in stepsLV as the given screen's steps.
SaveScreenToIni(name, screenName) {
    global stepsLV, ConfigFile
    idx := ScreenIndexByName(name, screenName)
    if !idx
        return
    section := "Preset_" name
    n := stepsLV.GetCount()
    IniWrite n, ConfigFile, section, "Screen" idx "StepCount"
    Loop n {
        i := A_Index
        IniWrite stepsLV.GetText(i, 2), ConfigFile, section, "Screen" idx "Step" i "Type"
        IniWrite stepsLV.GetText(i, 3), ConfigFile, section, "Screen" idx "Step" i "Label"
        IniWrite stepsLV.GetText(i, 4), ConfigFile, section, "Screen" idx "Step" i "X"
        IniWrite stepsLV.GetText(i, 5), ConfigFile, section, "Screen" idx "Step" i "Y"
        IniWrite stepsLV.GetText(i, 6), ConfigFile, section, "Screen" idx "Step" i "EndX"
        IniWrite stepsLV.GetText(i, 7), ConfigFile, section, "Screen" idx "Step" i "EndY"
        IniWrite stepsLV.GetText(i, 8), ConfigFile, section, "Screen" idx "Step" i "DragMs"
        IniWrite (stepsLV.GetText(i, 9) = "Yes" ? 1 : 0), ConfigFile, section, "Screen" idx "Step" i "OncePerCycle"
        IniWrite stepsLV.GetText(i, 10), ConfigFile, section, "Screen" idx "Step" i "OnTrueScreen"
        IniWrite stepsLV.GetText(i, 11), ConfigFile, section, "Screen" idx "Step" i "OnFalseScreen"
        IniWrite stepsLV.GetText(i, 12), ConfigFile, section, "Screen" idx "Step" i "Seconds"
    }
}

; Repopulates the step editor's On True/On False dropdowns (plus the Option Select Fallback
; Screen dropdown) with every screen name in `name`'s preset, preserving each one's current
; selection where still valid. Called whenever the screen list changes (add/rename/delete/move)
; and every time the visible screen switches, so it must NOT clobber a not-yet-saved selection.
RefreshJumpTargetDdls(name) {
    global stepOnTrueDdl, stepOnFalseDdl, fallbackScreenDdl
    ; "(Repeat)" is a pseudo-screen, not an actual one - handled specially in RunSteps instead of
    ; being resolved as a screen jump: it re-runs this exact step again (honoring its own "Wait
    ; After" as the pause between attempts) instead of moving to the next step or another screen.
    items := ["(continue)", "(Repeat)"]
    for n in GetPresetScreenNames(name)
        items.Push(n)
    curTrue := stepOnTrueDdl.Text
    curFalse := stepOnFalseDdl.Text
    stepOnTrueDdl.Delete()
    stepOnTrueDdl.Add(items)
    stepOnFalseDdl.Delete()
    stepOnFalseDdl.Add(items)
    stepOnTrueDdl.Text := (curTrue != "") ? curTrue : "(continue)"
    stepOnFalseDdl.Text := (curFalse != "") ? curFalse : "(continue)"

    ; "(Stop Macro)" is a pseudo-screen, not an actual one - handled specially in RunSteps'
    ; "Option Select" case instead of being resolved as a jump target.
    fbItems := ["(none)", "(Stop Macro)"]
    for n in GetPresetScreenNames(name)
        fbItems.Push(n)
    curFallback := fallbackScreenDdl.Text
    fallbackScreenDdl.Delete()
    fallbackScreenDdl.Add(fbItems)
    fallbackScreenDdl.Text := (curFallback != "") ? curFallback : "(none)"
}

; Switches which screen's steps are shown in stepsLV, saving the screen being left first.
ScreenChanged(*) {
    global CurrentPresetName, CurrentScreenName, screenDdl
    SaveScreenToIni(CurrentPresetName, CurrentScreenName)
    CurrentScreenName := screenDdl.Text
    LoadScreenSteps(CurrentPresetName, CurrentScreenName)
}

NewScreenClick(*) {
    global CurrentPresetName, CurrentScreenName, screenDdl, ConfigFile
    ib := InputBox("Enter a name for the new screen:", "New Screen")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    newName := Trim(ib.Value)
    names := GetPresetScreenNames(CurrentPresetName)
    for n in names {
        if (n = newName) {
            MsgBox "A screen with this name already exists in this preset."
            return
        }
    }
    SaveScreenToIni(CurrentPresetName, CurrentScreenName)
    section := "Preset_" CurrentPresetName
    newIdx := names.Length + 1
    IniWrite newIdx, ConfigFile, section, "ScreenCount"
    IniWrite newName, ConfigFile, section, "Screen" newIdx "Name"
    IniWrite 0, ConfigFile, section, "Screen" newIdx "StepCount"
    CurrentScreenName := newName
    RefreshScreenDdlItems(CurrentPresetName, newName)
    LoadScreenSteps(CurrentPresetName, newName)
    LogMsg("Screen '" newName "' created.")
}

RenameScreenClick(*) {
    global CurrentPresetName, CurrentScreenName, ConfigFile, fallbackScreenDdl
    ib := InputBox("Rename screen '" CurrentScreenName "' to:", "Rename Screen", , CurrentScreenName)
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    newName := Trim(ib.Value)
    if (newName = CurrentScreenName)
        return
    names := GetPresetScreenNames(CurrentPresetName)
    for n in names {
        if (n = newName) {
            MsgBox "A screen with this name already exists in this preset."
            return
        }
    }
    SaveScreenToIni(CurrentPresetName, CurrentScreenName)
    idx := ScreenIndexByName(CurrentPresetName, CurrentScreenName)
    if !idx
        return
    section := "Preset_" CurrentPresetName
    IniWrite newName, ConfigFile, section, "Screen" idx "Name"
    RenameJumpTargetsEverywhere(CurrentPresetName, CurrentScreenName, newName)
    ; The Option Select "Fallback Screen" dropdown is preset-level, not per-step, so it isn't
    ; covered by RenameJumpTargetsEverywhere above - fix it up here too (both the live control,
    ; in case it's showing an unsaved change, and ini in case it isn't).
    if (fallbackScreenDdl.Text = CurrentScreenName)
        fallbackScreenDdl.Text := newName
    if (Cfg(section, "FallbackScreen", "(none)") = CurrentScreenName)
        IniWrite newName, ConfigFile, section, "FallbackScreen"
    oldName := CurrentScreenName
    CurrentScreenName := newName
    RefreshScreenDdlItems(CurrentPresetName, newName)
    LoadScreenSteps(CurrentPresetName, newName)
    LogMsg("Screen '" oldName "' renamed to '" newName "'.")
}

; Sweeps every screen's steps in this preset and updates any On True/On False value equal to
; `oldName` to `newName`, so a rename doesn't silently break existing jumps.
RenameJumpTargetsEverywhere(name, oldName, newName) {
    global ConfigFile
    section := "Preset_" name
    screenCount := Integer(Cfg(section, "ScreenCount", "0"))
    Loop screenCount {
        si := A_Index
        stepCount := Integer(Cfg(section, "Screen" si "StepCount", "0"))
        Loop stepCount {
            sj := A_Index
            if (Cfg(section, "Screen" si "Step" sj "OnTrueScreen", "(continue)") = oldName)
                IniWrite newName, ConfigFile, section, "Screen" si "Step" sj "OnTrueScreen"
            if (Cfg(section, "Screen" si "Step" sj "OnFalseScreen", "(continue)") = oldName)
                IniWrite newName, ConfigFile, section, "Screen" si "Step" sj "OnFalseScreen"
        }
    }
}

DeleteScreenClick(*) {
    global CurrentPresetName, CurrentScreenName, ConfigFile, fallbackScreenDdl
    names := GetPresetScreenNames(CurrentPresetName)
    if (names.Length <= 1) {
        MsgBox "At least one screen must remain."
        return
    }
    res := MsgBox("Delete screen '" CurrentScreenName "'? Any On True/On False jumps pointing to it will fall back to '(continue)'.", "Confirm", "YesNo")
    if (res != "Yes")
        return
    idx := ScreenIndexByName(CurrentPresetName, CurrentScreenName)
    if !idx
        return

    ; Capture every remaining screen's data (clearing jump targets that pointed at the one being
    ; removed) before touching the ini file.
    remaining := []
    for i, n in names {
        if (i = idx)
            continue
        steps := BuildScreenStepsFromIni(CurrentPresetName, i)
        for st in steps {
            if (st.OnTrueScreen = CurrentScreenName)
                st.OnTrueScreen := "(continue)"
            if (st.OnFalseScreen = CurrentScreenName)
                st.OnFalseScreen := "(continue)"
        }
        remaining.Push({Name: n, Steps: steps})
    }

    ; Preserve every non-Screen* key (Options, DefaultMap, ...), then rebuild Screen* keys from
    ; `remaining` with compacted indices.
    section := "Preset_" CurrentPresetName
    content := IniRead(ConfigFile, section, , "")
    keep := []
    for line in StrSplit(content, "`n", "`r") {
        if (line = "")
            continue
        eqPos := InStr(line, "=")
        if !eqPos
            continue
        key := SubStr(line, 1, eqPos - 1)
        if !InStr(key, "Screen") {
            ; The Option Select "Fallback Screen" setting is preset-level, not per-step - if it
            ; pointed at the screen being deleted, reset it to "(none)" instead of carrying a
            ; dangling reference forward.
            val := SubStr(line, eqPos + 1)
            if (key = "FallbackScreen" && val = CurrentScreenName)
                val := "(none)"
            keep.Push({Key: key, Val: val})
        }
    }
    IniDelete ConfigFile, section
    for kv in keep
        IniWrite kv.Val, ConfigFile, section, kv.Key
    IniWrite remaining.Length, ConfigFile, section, "ScreenCount"
    for i, scr in remaining
        WriteScreenSteps(CurrentPresetName, i, scr.Name, scr.Steps)

    if (fallbackScreenDdl.Text = CurrentScreenName)
        fallbackScreenDdl.Text := "(none)"

    CurrentScreenName := remaining[1].Name
    RefreshScreenDdlItems(CurrentPresetName, CurrentScreenName)
    LoadScreenSteps(CurrentPresetName, CurrentScreenName)
    LogMsg("Screen deleted.")
}

; Swaps the entire step lists (and names) stored at screen indices i1/i2 within a preset. Jump
; targets are stored by NAME, not index, so they keep pointing at the right screen automatically.
SwapScreens(name, i1, i2) {
    section := "Preset_" name
    screenNameAt1 := Cfg(section, "Screen" i1 "Name", "Screen " i1)
    screenNameAt2 := Cfg(section, "Screen" i2 "Name", "Screen " i2)
    steps1 := BuildScreenStepsFromIni(name, i1)
    steps2 := BuildScreenStepsFromIni(name, i2)
    WriteScreenSteps(name, i1, screenNameAt2, steps2)
    WriteScreenSteps(name, i2, screenNameAt1, steps1)
}

MoveScreenUpClick(*) {
    global CurrentPresetName, CurrentScreenName
    SaveScreenToIni(CurrentPresetName, CurrentScreenName)
    idx := ScreenIndexByName(CurrentPresetName, CurrentScreenName)
    if (!idx || idx = 1)
        return
    SwapScreens(CurrentPresetName, idx, idx - 1)
    RefreshScreenDdlItems(CurrentPresetName, CurrentScreenName)
}

MoveScreenDownClick(*) {
    global CurrentPresetName, CurrentScreenName
    SaveScreenToIni(CurrentPresetName, CurrentScreenName)
    names := GetPresetScreenNames(CurrentPresetName)
    idx := ScreenIndexByName(CurrentPresetName, CurrentScreenName)
    if (!idx || idx = names.Length)
        return
    SwapScreens(CurrentPresetName, idx, idx + 1)
    RefreshScreenDdlItems(CurrentPresetName, CurrentScreenName)
}

; ============================================================
; IMPORT A SCREEN (OR JUST A SINGLE STEP) FROM ANOTHER PRESET - OR THE SAME ONE, TO DUPLICATE
; ============================================================
; Repopulates the preset dropdown with every preset, INCLUDING the one currently being edited -
; picking the current preset here lets you duplicate one of its own screens/steps instead of only
; pulling from elsewhere. Defaults to the current preset selected, since duplicating within it is
; the more common case; switch to another preset to import from there instead.
RefreshImportPresetDdl() {
    global importPresetDdl, PresetNames, CurrentPresetName
    importPresetDdl.Delete()
    importPresetDdl.Add(PresetNames)
    importPresetDdl.Text := CurrentPresetName
    ImportPresetChanged()
}

; If `srcPreset` is the preset currently open in the editor, flushes whatever's shown in stepsLV
; for the currently open screen to ini first - so duplicating within the same preset picks up
; in-progress edits instead of stale saved data.
FlushIfCurrentPreset(srcPreset) {
    global CurrentPresetName, CurrentScreenName
    if (srcPreset = CurrentPresetName)
        SaveScreenToIni(CurrentPresetName, CurrentScreenName)
}

; Repopulates the screen dropdown with whichever preset is currently selected in importPresetDdl.
ImportPresetChanged(*) {
    global importPresetDdl, importScreenDdl
    importScreenDdl.Delete()
    src := importPresetDdl.Text
    if (src != "") {
        importScreenDdl.Add(GetPresetScreenNames(src))
        importScreenDdl.Choose(1)
    }
    ImportScreenChanged()
}

; Global holding the actual step objects currently listed in importStepDdl, parallel to its items
; (so ImportStepClick can pull the full settings back out via the selected index, not just text).
ImportStepDdlSteps := []

; Repopulates the component/step dropdown with every step of whichever screen is selected in
; importScreenDdl, labelled "#: Type (Label)" for easy identification.
ImportScreenChanged(*) {
    global importPresetDdl, importScreenDdl, importStepDdl, ImportStepDdlSteps
    importStepDdl.Delete()
    ImportStepDdlSteps := []
    src := importPresetDdl.Text
    screenName := importScreenDdl.Text
    if (src = "" || screenName = "")
        return
    FlushIfCurrentPreset(src)
    items := []
    for i, st in BuildScreenStepsFromIniByName(src, screenName) {
        desc := (st.Label != "") ? st.Type " (" st.Label ")" : st.Type
        items.Push(i ": " desc)
        ImportStepDdlSteps.Push(st)
    }
    importStepDdl.Add(items)
    if (items.Length > 0)
        importStepDdl.Choose(1)
}

; Finds a screen name in `name`'s preset that doesn't collide with an existing one, appending
; " (2)", " (3)", ... to `desired` as needed.
UniqueScreenName(name, desired) {
    existing := GetPresetScreenNames(name)
    candidate := desired
    n := 2
    Loop {
        collides := false
        for e in existing {
            if (e = candidate) {
                collides := true
                break
            }
        }
        if !collides
            return candidate
        candidate := desired " (" n ")"
        n += 1
    }
}

; Small popup asking whether an import should overwrite the currently open screen or be added as
; a brand new one. Blocks (via WinWaitClose) until the user picks one or cancels/closes it.
; Returns "overwrite", "new", or "" if cancelled.
ShowImportChoiceGui(srcPreset, srcScreen, destScreen) {
    global EditGui
    result := ""
    g := Gui("+Owner" EditGui.Hwnd, "Import Screen")
    g.SetFont("s10")
    g.AddText("x20 y15 w360", "Import '" srcScreen "' from preset '" srcPreset "' - how?")
    g.AddText("x20 y40 w360 h40", "'Overwrite' replaces the steps of the currently open screen ('" destScreen "'), keeping its name. 'Add as New' creates a separate screen instead.")
    btnOverwrite := g.AddButton("x20 y90 w170 h28", "Overwrite '" destScreen "'")
    btnNew := g.AddButton("x210 y90 w170 h28", "Add As New Screen")
    btnCancel := g.AddButton("x140 y128 w110", "Cancel")
    btnOverwrite.OnEvent("Click", (*) => (result := "overwrite", g.Destroy()))
    btnNew.OnEvent("Click", (*) => (result := "new", g.Destroy()))
    btnCancel.OnEvent("Click", (*) => (result := "", g.Destroy()))
    g.OnEvent("Close", (*) => (result := "", g.Destroy()))
    g.Show("w400 h170")
    WinWaitClose("ahk_id " g.Hwnd)
    return result
}

; Imports the screen picked in importPresetDdl/importScreenDdl into the currently open preset,
; either overwriting the screen currently shown in stepsLV (keeping its name) or adding the
; import as a separate new screen alongside it.
ImportScreenClick(*) {
    global importPresetDdl, importScreenDdl, CurrentPresetName, CurrentScreenName, ConfigFile
    srcPreset := importPresetDdl.Text
    srcScreen := importScreenDdl.Text
    if (srcPreset = "" || srcScreen = "") {
        MsgBox "Pick a preset and one of its screens to import first."
        return
    }
    choice := ShowImportChoiceGui(srcPreset, srcScreen, CurrentScreenName)
    if (choice = "")
        return
    FlushIfCurrentPreset(srcPreset)
    steps := BuildScreenStepsFromIniByName(srcPreset, srcScreen)

    if (choice = "overwrite") {
        idx := ScreenIndexByName(CurrentPresetName, CurrentScreenName)
        if !idx
            return
        WriteScreenSteps(CurrentPresetName, idx, CurrentScreenName, steps)
        LoadScreenSteps(CurrentPresetName, CurrentScreenName)
        LogMsg("Screen '" CurrentScreenName "' overwritten with '" srcPreset "' > '" srcScreen "' (" steps.Length " step(s)).")
    } else {
        ; Flush whatever's currently shown for the open screen first, so it isn't lost.
        SaveScreenToIni(CurrentPresetName, CurrentScreenName)
        newName := UniqueScreenName(CurrentPresetName, srcScreen)
        section := "Preset_" CurrentPresetName
        newIdx := GetPresetScreenNames(CurrentPresetName).Length + 1
        IniWrite newIdx, ConfigFile, section, "ScreenCount"
        WriteScreenSteps(CurrentPresetName, newIdx, newName, steps)
        CurrentScreenName := newName
        RefreshScreenDdlItems(CurrentPresetName, newName)
        LoadScreenSteps(CurrentPresetName, newName)
        LogMsg("Added new screen '" newName "' imported from '" srcPreset "' > '" srcScreen "' (" steps.Length " step(s)).")
    }
}

; Imports just the single component/step picked in importStepDdl (full settings included) by
; appending it to the end of the screen currently open in stepsLV - use Move Up/Down afterward to
; reposition it. Unlike "Import Screen", this never touches any other step already in the screen.
ImportStepClick(*) {
    global importPresetDdl, importScreenDdl, importStepDdl, stepsLV, CurrentScreenName
    srcPreset := importPresetDdl.Text
    srcScreen := importScreenDdl.Text
    idx := importStepDdl.Value
    if (srcPreset = "" || srcScreen = "" || !idx) {
        MsgBox "Pick a preset, screen, and component to import first."
        return
    }
    ; Re-reads fresh from ini (rather than the cached dropdown list) so duplicating within the
    ; same preset always picks up whatever was most recently edited on the source screen.
    FlushIfCurrentPreset(srcPreset)
    steps := BuildScreenStepsFromIniByName(srcPreset, srcScreen)
    if (idx > steps.Length) {
        MsgBox "That component no longer exists in the selected screen - refresh the dropdowns and try again."
        return
    }
    st := steps[idx]
    stepsLV.Add("", stepsLV.GetCount() + 1, st.Type, st.Label, st.X, st.Y, st.EndX, st.EndY, st.DragMs,
        (st.OncePerCycle ? "Yes" : "No"), st.OnTrueScreen, st.OnFalseScreen, st.Seconds)
    LogMsg("Imported step '" st.Type "' from '" srcPreset "' > '" srcScreen "' into screen '" CurrentScreenName "'.")
}

; Copies every key of one ini section to another (used by Rename, since a preset section can
; hold data for every screen plus options/default-map - safer than reconstructing key-by-key).
CopyIniSection(file, oldSection, newSection) {
    content := IniRead(file, oldSection, , "")
    if (content = "")
        return
    for line in StrSplit(content, "`n", "`r") {
        if (line = "")
            continue
        eqPos := InStr(line, "=")
        if !eqPos
            continue
        key := SubStr(line, 1, eqPos - 1)
        val := SubStr(line, eqPos + 1)
        IniWrite val, file, newSection, key
    }
}

; Reads one legacy phase's steps (old flat "BeforeCount"/"BeforeStep{i}..." format, no
; OnTrue/OnFalseScreen yet) - only used during the one-time migration to Screens below.
MigrateLegacyPhaseSteps(psection, prefix) {
    n := Integer(Cfg(psection, prefix "Count", "0"))
    arr := []
    Loop n {
        i := A_Index
        arr.Push({Type: Cfg(psection, prefix "Step" i "Type", "Button Click"),
            Label: Cfg(psection, prefix "Step" i "Label", ""),
            X: Cfg(psection, prefix "Step" i "X", "0"),
            Y: Cfg(psection, prefix "Step" i "Y", "0"),
            EndX: Cfg(psection, prefix "Step" i "EndX", "0"),
            EndY: Cfg(psection, prefix "Step" i "EndY", "0"),
            DragMs: Cfg(psection, prefix "Step" i "DragMs", "500"),
            OncePerCycle: Integer(Cfg(psection, prefix "Step" i "OncePerCycle", "0")),
            Seconds: Cfg(psection, prefix "Step" i "Seconds", "0"),
            OnTrueScreen: "(continue)",
            OnFalseScreen: "(continue)"})
    }
    return arr
}

InitPresets() {
    global ConfigFile, PresetNames, CurrentPresetName, presetListBox

    presetListStr := Cfg("Presets", "List", "")
    if (presetListStr = "") {
        ; First run: create a default "Challenges" preset with 3 screens (Before Map Detection ->
        ; Ingame -> Round End -> back to Before), the same routine the old fixed 3-phase system
        ; used to build automatically, just expressed as explicit screen jumps now.
        IniWrite 3, ConfigFile, "Preset_Challenges", "ScreenCount"

        IniWrite "Before Map Detection", ConfigFile, "Preset_Challenges", "Screen1Name"
        IniWrite 4, ConfigFile, "Preset_Challenges", "Screen1StepCount"
        IniWrite "Option Select", ConfigFile, "Preset_Challenges", "Screen1Step1Type"
        IniWrite "Select Option", ConfigFile, "Preset_Challenges", "Screen1Step1Label"
        IniWrite "Button Click", ConfigFile, "Preset_Challenges", "Screen1Step2Type"
        IniWrite "Button 1", ConfigFile, "Preset_Challenges", "Screen1Step2Label"
        IniWrite "Detect Map", ConfigFile, "Preset_Challenges", "Screen1Step3Type"
        IniWrite "Detect Map", ConfigFile, "Preset_Challenges", "Screen1Step3Label"
        IniWrite "Ingame", ConfigFile, "Preset_Challenges", "Screen1Step3OnTrueScreen"
        IniWrite "Ingame", ConfigFile, "Preset_Challenges", "Screen1Step3OnFalseScreen"
        IniWrite "Button Click", ConfigFile, "Preset_Challenges", "Screen1Step4Type"
        IniWrite "Button 2", ConfigFile, "Preset_Challenges", "Screen1Step4Label"

        IniWrite "Ingame", ConfigFile, "Preset_Challenges", "Screen2Name"
        IniWrite 2, ConfigFile, "Preset_Challenges", "Screen2StepCount"
        IniWrite "Place Towers", ConfigFile, "Preset_Challenges", "Screen2Step1Type"
        IniWrite "Place Towers", ConfigFile, "Preset_Challenges", "Screen2Step1Label"
        IniWrite "Round End Detection", ConfigFile, "Preset_Challenges", "Screen2Step2Type"
        IniWrite "Victory", ConfigFile, "Preset_Challenges", "Screen2Step2Label"
        IniWrite "Round End", ConfigFile, "Preset_Challenges", "Screen2Step2OnTrueScreen"
        IniWrite "Ingame", ConfigFile, "Preset_Challenges", "Screen2Step2OnFalseScreen"

        IniWrite "Round End", ConfigFile, "Preset_Challenges", "Screen3Name"
        IniWrite 2, ConfigFile, "Preset_Challenges", "Screen3StepCount"
        IniWrite "Button Click", ConfigFile, "Preset_Challenges", "Screen3Step1Type"
        IniWrite "Button 3", ConfigFile, "Preset_Challenges", "Screen3Step1Label"
        IniWrite "Button Click", ConfigFile, "Preset_Challenges", "Screen3Step2Type"
        IniWrite "Button 4", ConfigFile, "Preset_Challenges", "Screen3Step2Label"

        IniWrite "Challenges", ConfigFile, "Presets", "List"
        IniWrite "Challenges", ConfigFile, "Presets", "Active"
        presetListStr := "Challenges"
    }

    PresetNames := StrSplit(presetListStr, ",")

    for n in PresetNames {
        psection := "Preset_" n

        ; One-time migration: challenge options and the default-map fallback used to be global
        ; ([Option1]/[Option2]/[Option3] and [General] DefaultMap). Seed each preset that doesn't
        ; have its own copy yet from those old global values, so existing setups keep working.
        if (Cfg(psection, "Option1Name", "") = "") {
            Loop 3 {
                i := A_Index
                IniWrite Cfg("Option" i, "Name", "Option " i), ConfigFile, psection, "Option" i "Name"
                IniWrite Cfg("Option" i, "X", "0"), ConfigFile, psection, "Option" i "X"
                IniWrite Cfg("Option" i, "Y", "0"), ConfigFile, psection, "Option" i "Y"
                IniWrite Cfg("Option" i, "AvailableAtStart", "1"), ConfigFile, psection, "Option" i "Available"
                IniWrite Cfg("Option" i, "Priority", String(i)), ConfigFile, psection, "Option" i "Priority"
            }
            IniWrite Cfg("General", "DefaultMap", "(none)"), ConfigFile, psection, "DefaultMap"
        }

        ; One-time migration: presets used to have a single flat step list ("StepCount"/
        ; "Step{i}..."). If a preset still only has that (no phase data yet), move its whole
        ; step list into the "Before" phase as-is - it'll be picked up by the phase->Screens
        ; migration right below.
        oldStepCount := Cfg(psection, "StepCount", "")
        hasPhaseData := (Cfg(psection, "BeforeCount", "") != "" || Cfg(psection, "IngameCount", "") != "" || Cfg(psection, "RoundEndCount", "") != "")
        hasScreenData := (Cfg(psection, "ScreenCount", "") != "")
        if (oldStepCount != "" && !hasPhaseData && !hasScreenData) {
            IniWrite oldStepCount, ConfigFile, psection, "BeforeCount"
            Loop Integer(oldStepCount) {
                i := A_Index
                IniWrite Cfg(psection, "Step" i "Type", "Button Click"), ConfigFile, psection, "BeforeStep" i "Type"
                IniWrite Cfg(psection, "Step" i "Label", ""), ConfigFile, psection, "BeforeStep" i "Label"
                IniWrite Cfg(psection, "Step" i "X", "0"), ConfigFile, psection, "BeforeStep" i "X"
                IniWrite Cfg(psection, "Step" i "Y", "0"), ConfigFile, psection, "BeforeStep" i "Y"
                IniWrite Cfg(psection, "Step" i "Seconds", "0"), ConfigFile, psection, "BeforeStep" i "Seconds"
            }
            hasPhaseData := true
        }

        ; One-time migration: the old fixed 3-phase system (Before Map Detection / Ingame / Round
        ; End, chained via "AfterRoundEnd", with ONE shared OCR region per detection kind) is
        ; replaced by a flexible list of named Screens, each ending in explicit True/False jumps
        ; and each Logic step carrying its own OCR region. Convert any preset that still has old
        ; phase data but no Screen data yet.
        if (hasPhaseData && !hasScreenData) {
            beforeSteps := MigrateLegacyPhaseSteps(psection, "Before")
            ingameSteps := MigrateLegacyPhaseSteps(psection, "Ingame")
            roundEndSteps := MigrateLegacyPhaseSteps(psection, "RoundEnd")

            ; Detect Map (in Before) used the old global Map Text Detection region; give it that
            ; region and an unconditional continue to Ingame (matching the old automatic
            ; Before -> Ingame flow).
            for st in beforeSteps {
                if (st.Type = "Detect Map") {
                    st.X := Cfg("General", "RegionX1", "0")
                    st.Y := Cfg("General", "RegionY1", "0")
                    st.EndX := Cfg("General", "RegionX2", "0")
                    st.EndY := Cfg("General", "RegionY2", "0")
                    st.OnTrueScreen := "Ingame"
                    st.OnFalseScreen := "Ingame"
                }
            }
            ; Round End Detection (in Ingame, by convention the LAST step) used the old global
            ; Round End region/text; give it that region/text and reproduce the old
            ; repeat-until-true loop via explicit jumps.
            if (ingameSteps.Length > 0 && ingameSteps[ingameSteps.Length].Type = "Round End Detection") {
                last := ingameSteps[ingameSteps.Length]
                last.X := Cfg("General", "RoundEndX1", "0")
                last.Y := Cfg("General", "RoundEndY1", "0")
                last.EndX := Cfg("General", "RoundEndX2", "0")
                last.EndY := Cfg("General", "RoundEndY2", "0")
                last.Label := Cfg("General", "RoundEndText", "")
                last.OnTrueScreen := "Round End"
                last.OnFalseScreen := "Ingame"
            }

            ; Screen order determines the default fallthrough when a screen ends without an
            ; explicit jump - reproduce the old "AfterRoundEnd" dropdown by placing that target
            ; right after Round End in the list.
            afterRoundEnd := Cfg(psection, "AfterRoundEnd", "Before Map Detection")
            screens := (afterRoundEnd = "Ingame")
                ? [{Name: "Before Map Detection", Steps: beforeSteps}, {Name: "Round End", Steps: roundEndSteps}, {Name: "Ingame", Steps: ingameSteps}]
                : [{Name: "Before Map Detection", Steps: beforeSteps}, {Name: "Ingame", Steps: ingameSteps}, {Name: "Round End", Steps: roundEndSteps}]

            IniWrite screens.Length, ConfigFile, psection, "ScreenCount"
            for i, scr in screens
                WriteScreenSteps(n, i, scr.Name, scr.Steps)
        }
    }

    presetListBox.Delete()
    presetListBox.Add(PresetNames)

    activeName := Cfg("Presets", "Active", PresetNames[1])
    activeIdx := 1
    found := false
    for idx, n in PresetNames {
        if (n = activeName) {
            found := true
            activeIdx := idx
        }
    }
    if !found {
        activeIdx := 1
        activeName := PresetNames[1]
    }

    presetListBox.Choose(activeIdx)
    CurrentPresetName := activeName
    LoadPreset(CurrentPresetName)
}

LoadPreset(name) {
    global OptData, defaultMapDdl, backXEdit, backYEdit, fallbackScreenDdl
    LoadPresetScreens(name)

    section := "Preset_" name
    Loop 3 {
        i := A_Index
        opt := OptData[i]
        opt.NameEdit.Value := Cfg(section, "Option" i "Name", "Option " i)
        opt.XEdit.Value := Cfg(section, "Option" i "X", "0")
        opt.YEdit.Value := Cfg(section, "Option" i "Y", "0")
        opt.AvailChk.Value := Integer(Cfg(section, "Option" i "Available", "1"))
        opt.PrioDdl.Text := Cfg(section, "Option" i "Priority", String(i))
        opt.MaxEdit.Value := Cfg(section, "Option" i "MaxUses", "0")
        opt.DetX := Cfg(section, "Option" i "DetX", "0")
        opt.DetY := Cfg(section, "Option" i "DetY", "0")
        opt.DetEndX := Cfg(section, "Option" i "DetEndX", "0")
        opt.DetEndY := Cfg(section, "Option" i "DetEndY", "0")
        opt.DetText := Cfg(section, "Option" i "DetText", "")
        opt.DetInvert := Integer(Cfg(section, "Option" i "DetInvert", "0"))
    }
    defaultMapDdl.Text := Cfg(section, "DefaultMap", "(none)")
    backXEdit.Value := Cfg(section, "BackX", "0")
    backYEdit.Value := Cfg(section, "BackY", "0")
    ; This preset's screen list was just (re)loaded above via LoadPresetScreens, so
    ; fallbackScreenDdl's items already match - just set the selection to what was saved.
    fallbackScreenDdl.Text := Cfg(section, "FallbackScreen", "(none)")
    LoadUsageFields(name)
}

SavePresetToIni(name) {
    global ConfigFile, OptData, defaultMapDdl, CurrentScreenName, backXEdit, backYEdit, fallbackScreenDdl
    SaveScreenToIni(name, CurrentScreenName)

    section := "Preset_" name
    Loop 3 {
        i := A_Index
        opt := OptData[i]
        IniWrite opt.NameEdit.Value, ConfigFile, section, "Option" i "Name"
        IniWrite opt.XEdit.Value, ConfigFile, section, "Option" i "X"
        IniWrite opt.YEdit.Value, ConfigFile, section, "Option" i "Y"
        IniWrite opt.AvailChk.Value, ConfigFile, section, "Option" i "Available"
        IniWrite opt.PrioDdl.Text, ConfigFile, section, "Option" i "Priority"
        IniWrite opt.MaxEdit.Value, ConfigFile, section, "Option" i "MaxUses"
        IniWrite opt.DetX, ConfigFile, section, "Option" i "DetX"
        IniWrite opt.DetY, ConfigFile, section, "Option" i "DetY"
        IniWrite opt.DetEndX, ConfigFile, section, "Option" i "DetEndX"
        IniWrite opt.DetEndY, ConfigFile, section, "Option" i "DetEndY"
        IniWrite opt.DetText, ConfigFile, section, "Option" i "DetText"
        IniWrite opt.DetInvert, ConfigFile, section, "Option" i "DetInvert"
    }
    IniWrite defaultMapDdl.Text, ConfigFile, section, "DefaultMap"
    IniWrite backXEdit.Value, ConfigFile, section, "BackX"
    IniWrite backYEdit.Value, ConfigFile, section, "BackY"
    IniWrite fallbackScreenDdl.Text, ConfigFile, section, "FallbackScreen"
    ; Refresh the Preset Settings tab's usage fields in case Max was just edited.
    LoadUsageFields(name)
}

RebuildPresetListBox() {
    global presetListBox, PresetNames
    presetListBox.Delete()
    presetListBox.Add(PresetNames)
}

RenumberListView() {
    global stepsLV
    n := stepsLV.GetCount()
    Loop n
        stepsLV.Modify(A_Index, "", A_Index)
}

PresetListChanged(*) {
    global CurrentPresetName, presetListBox, ConfigFile
    if (CurrentPresetName != "")
        SavePresetToIni(CurrentPresetName)
    CurrentPresetName := presetListBox.Text
    LoadPreset(CurrentPresetName)
    IniWrite CurrentPresetName, ConfigFile, "Presets", "Active"
}

NewPresetClick(*) {
    global CurrentPresetName, presetListBox, PresetNames, ConfigFile, stepsLV, OptData, defaultMapDdl, CurrentScreenName, screenDdl
    global backXEdit, backYEdit, fallbackScreenDdl
    ib := InputBox("Enter a name for the new preset:", "New Preset")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    name := Trim(ib.Value)
    for n in PresetNames {
        if (n = name) {
            MsgBox "A preset with this name already exists."
            return
        }
    }
    if (CurrentPresetName != "")
        SavePresetToIni(CurrentPresetName)
    PresetNames.Push(name)
    presetListBox.Add([name])
    presetListBox.Choose(PresetNames.Length)
    CurrentPresetName := name
    Loop 3 {
        i := A_Index
        opt := OptData[i]
        opt.NameEdit.Value := "Option " i
        opt.XEdit.Value := "0"
        opt.YEdit.Value := "0"
        opt.AvailChk.Value := 1
        opt.PrioDdl.Text := String(i)
        opt.MaxEdit.Value := "0"
        opt.DetX := "0"
        opt.DetY := "0"
        opt.DetEndX := "0"
        opt.DetEndY := "0"
        opt.DetText := ""
        opt.DetInvert := 0
    }
    defaultMapDdl.Text := "(none)"
    backXEdit.Value := "0"
    backYEdit.Value := "0"
    fallbackScreenDdl.Text := "(none)"
    IniWrite 1, ConfigFile, "Preset_" name, "ScreenCount"
    IniWrite "Screen 1", ConfigFile, "Preset_" name, "Screen1Name"
    IniWrite 0, ConfigFile, "Preset_" name, "Screen1StepCount"
    CurrentScreenName := "Screen 1"
    screenDdl.Delete()
    screenDdl.Add(["Screen 1"])
    screenDdl.Text := "Screen 1"
    stepsLV.Delete()
    RefreshJumpTargetDdls(name)
    SavePresetToIni(name)
    IniWrite JoinList(PresetNames), ConfigFile, "Presets", "List"
    IniWrite CurrentPresetName, ConfigFile, "Presets", "Active"
    try editingLabel.Text := "Editing: " CurrentPresetName
    LogMsg("Preset '" name "' created.")
}

RenamePresetClick(*) {
    global CurrentPresetName, presetListBox, PresetNames, ConfigFile
    ib := InputBox("Rename preset '" CurrentPresetName "' to:", "Rename Preset", , CurrentPresetName)
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    newName := Trim(ib.Value)
    if (newName = CurrentPresetName)
        return
    for n in PresetNames {
        if (n = newName) {
            MsgBox "A preset with this name already exists."
            return
        }
    }
    ; Flush the currently-displayed screen to the OLD section first, then copy the whole section
    ; (all screens + options + default map) over - not just whichever screen happens to be shown.
    SavePresetToIni(CurrentPresetName)
    CopyIniSection(ConfigFile, "Preset_" CurrentPresetName, "Preset_" newName)
    IniDelete ConfigFile, "Preset_" CurrentPresetName
    newIdx := 1
    for idx, n in PresetNames {
        if (n = CurrentPresetName) {
            PresetNames[idx] := newName
            newIdx := idx
            break
        }
    }
    RebuildPresetListBox()
    presetListBox.Choose(newIdx)
    CurrentPresetName := newName
    IniWrite JoinList(PresetNames), ConfigFile, "Presets", "List"
    IniWrite CurrentPresetName, ConfigFile, "Presets", "Active"
    try editingLabel.Text := "Editing: " CurrentPresetName
    LogMsg("Preset renamed to '" newName "'.")
}

DeletePresetClick(*) {
    global CurrentPresetName, presetListBox, PresetNames, ConfigFile, stepsLV
    if (PresetNames.Length <= 1) {
        MsgBox "At least one preset must remain."
        return
    }
    res := MsgBox("Delete preset '" CurrentPresetName "'?", "Confirm", "YesNo")
    if (res != "Yes")
        return
    IniDelete ConfigFile, "Preset_" CurrentPresetName
    newList := []
    for n in PresetNames {
        if (n != CurrentPresetName)
            newList.Push(n)
    }
    PresetNames := newList
    RebuildPresetListBox()
    CurrentPresetName := PresetNames[1]
    presetListBox.Choose(1)
    LoadPreset(CurrentPresetName)
    IniWrite JoinList(PresetNames), ConfigFile, "Presets", "List"
    IniWrite CurrentPresetName, ConfigFile, "Presets", "Active"
    try editingLabel.Text := "Editing: " CurrentPresetName
    LogMsg("Preset deleted.")
}

; ============================================================
; STEP EDITOR
; ============================================================
LoadEditorFromSelection(*) {
    global stepsLV, stepTypeDdl, stepLabelEdit, stepXEdit, stepYEdit, stepSecEdit
    global dragEndXEdit, dragEndYEdit, dragMsEdit, oncePerCycleChk, stepOnTrueDdl, stepOnFalseDdl
    row := stepsLV.GetNext(0, "Focused")
    if !row
        return
    stepTypeDdl.Text := stepsLV.GetText(row, 2)
    stepLabelEdit.Value := stepsLV.GetText(row, 3)
    stepXEdit.Value := stepsLV.GetText(row, 4)
    stepYEdit.Value := stepsLV.GetText(row, 5)
    dragEndXEdit.Value := stepsLV.GetText(row, 6)
    dragEndYEdit.Value := stepsLV.GetText(row, 7)
    dragMsEdit.Value := stepsLV.GetText(row, 8)
    oncePerCycleChk.Value := (stepsLV.GetText(row, 9) = "Yes") ? 1 : 0
    stepOnTrueDdl.Text := stepsLV.GetText(row, 10)
    stepOnFalseDdl.Text := stepsLV.GetText(row, 11)
    stepSecEdit.Value := stepsLV.GetText(row, 12)
    UpdateStepEditorLabels()
}

AddStepClick(*) {
    global stepsLV, stepTypeDdl, stepLabelEdit, stepXEdit, stepYEdit, stepSecEdit
    global dragEndXEdit, dragEndYEdit, dragMsEdit, oncePerCycleChk, stepOnTrueDdl, stepOnFalseDdl
    onTrue := stepOnTrueDdl.Text
    onFalse := IsLogicStepType(stepTypeDdl.Text) ? stepOnFalseDdl.Text : "(continue)"
    stepsLV.Add("", stepsLV.GetCount() + 1, stepTypeDdl.Text, stepLabelEdit.Value, stepXEdit.Value, stepYEdit.Value,
        dragEndXEdit.Value, dragEndYEdit.Value, dragMsEdit.Value, (oncePerCycleChk.Value ? "Yes" : "No"), onTrue, onFalse, stepSecEdit.Value)
}

UpdateSelectedClick(*) {
    global stepsLV, stepTypeDdl, stepLabelEdit, stepXEdit, stepYEdit, stepSecEdit
    global dragEndXEdit, dragEndYEdit, dragMsEdit, oncePerCycleChk, stepOnTrueDdl, stepOnFalseDdl
    row := stepsLV.GetNext(0, "Focused")
    if !row {
        LogMsg("No step selected.")
        return
    }
    onTrue := stepOnTrueDdl.Text
    onFalse := IsLogicStepType(stepTypeDdl.Text) ? stepOnFalseDdl.Text : "(continue)"
    stepsLV.Modify(row, "", row, stepTypeDdl.Text, stepLabelEdit.Value, stepXEdit.Value, stepYEdit.Value,
        dragEndXEdit.Value, dragEndYEdit.Value, dragMsEdit.Value, (oncePerCycleChk.Value ? "Yes" : "No"), onTrue, onFalse, stepSecEdit.Value)
}

RemoveSelectedClick(*) {
    global stepsLV
    row := stepsLV.GetNext(0, "Focused")
    if !row
        return
    stepsLV.Delete(row)
    RenumberListView()
}

SwapRows(r1, r2) {
    global stepsLV
    t1 := stepsLV.GetText(r1, 2), l1 := stepsLV.GetText(r1, 3), x1 := stepsLV.GetText(r1, 4), y1 := stepsLV.GetText(r1, 5)
    ex1 := stepsLV.GetText(r1, 6), ey1 := stepsLV.GetText(r1, 7), dm1 := stepsLV.GetText(r1, 8), o1 := stepsLV.GetText(r1, 9)
    ot1 := stepsLV.GetText(r1, 10), of1 := stepsLV.GetText(r1, 11), s1 := stepsLV.GetText(r1, 12)
    t2 := stepsLV.GetText(r2, 2), l2 := stepsLV.GetText(r2, 3), x2 := stepsLV.GetText(r2, 4), y2 := stepsLV.GetText(r2, 5)
    ex2 := stepsLV.GetText(r2, 6), ey2 := stepsLV.GetText(r2, 7), dm2 := stepsLV.GetText(r2, 8), o2 := stepsLV.GetText(r2, 9)
    ot2 := stepsLV.GetText(r2, 10), of2 := stepsLV.GetText(r2, 11), s2 := stepsLV.GetText(r2, 12)
    stepsLV.Modify(r1, "", r1, t2, l2, x2, y2, ex2, ey2, dm2, o2, ot2, of2, s2)
    stepsLV.Modify(r2, "", r2, t1, l1, x1, y1, ex1, ey1, dm1, o1, ot1, of1, s1)
}

MoveUpClick(*) {
    global stepsLV
    row := stepsLV.GetNext(0, "Focused")
    if (!row || row = 1)
        return
    SwapRows(row, row - 1)
    stepsLV.Modify(row - 1, "Focus Select")
}

MoveDownClick(*) {
    global stepsLV
    row := stepsLV.GetNext(0, "Focused")
    n := stepsLV.GetCount()
    if (!row || row = n)
        return
    SwapRows(row, row + 1)
    stepsLV.Modify(row + 1, "Focus Select")
}

SavePresetClick(*) {
    global CurrentPresetName
    SavePresetToIni(CurrentPresetName)
    LogMsg("Preset '" CurrentPresetName "' saved.")
}

; Starts the macro beginning at the currently selected step on the currently open screen -
; skipping everything before it on this screen (later screens, reached via jumps/fallthrough,
; still run normally from their own start). Flushes the visible preset to ini first, so the
; running macro sees exactly what's shown here right now, unsaved edits included.
StartFromStepClick(*) {
    global stepsLV, CurrentPresetName, CurrentScreenName
    row := stepsLV.GetNext(0, "Focused")
    if !row {
        MsgBox "Select a step first."
        return
    }
    SavePresetToIni(CurrentPresetName)
    StartMacro(CurrentScreenName, row)
}

; ============================================================
; MACRO START
; ============================================================
; Reads every screen of a preset straight from ini, in list order, as an array of {Name, Steps}.
BuildAllScreensFromIni(name) {
    screens := []
    for i, screenName in GetPresetScreenNames(name)
        screens.Push({Name: screenName, Steps: BuildScreenStepsFromIni(name, i)})
    return screens
}

; startScreen/startStep let "Start Macro From This Step" begin execution partway into a specific
; screen instead of at the preset's normal start point; leave both at their defaults for a normal
; F10/Start-button run.
StartMacro(startScreen := "", startStep := 0) {
    global Running, CurrentPresetName, PresetScreens, MapAdvStepsDoneThisCycle, RunningPresetName
    global DisconnectRestartPending, DisconnectLastCheckTick
    if Running {
        LogMsg("Already running.")
        return
    }
    ClearLog()

    ; Loops back to the top when Disconnect Detection (General tab) fired during the previous
    ; pass - restarting the current preset from its normal start point, same as pressing F10
    ; again, but automatic. A plain run (no disconnect) just executes this loop body once.
    curStartScreen := startScreen
    curStartStep := startStep
    isAutoRestart := false
    Loop {
        SaveConfig()
        MapAdvStepsDoneThisCycle := false

        if !ForceGameWindow() {
            MsgBox "Could not find/position the game window. Check the selected process in the Timing tab, or click Refresh."
            return
        }

        ; Read every screen straight from ini (not from whichever screen happens to be displayed in
        ; the editor right now) - SaveConfig() above just flushed the visible one, so this is current.
        PresetScreens := BuildAllScreensFromIni(CurrentPresetName)
        RunningPresetName := CurrentPresetName

        totalSteps := 0
        for scr in PresetScreens
            totalSteps += scr.Steps.Length
        if (PresetScreens.Length = 0 || totalSteps = 0) {
            MsgBox "The active preset has no steps in any screen. Add steps in Preset Settings > Edit first."
            return
        }

        startScreenIdx := 0
        if (curStartScreen != "") {
            for i, scr in PresetScreens {
                if (scr.Name = curStartScreen) {
                    startScreenIdx := i
                    break
                }
            }
            if !startScreenIdx
                LogMsg("WARNING: could not find screen '" curStartScreen "' to start from - using the normal start screen instead.")
        }

        Running := true
        DisconnectLastCheckTick := A_TickCount
        if isAutoRestart
            LogMsg("Auto-reconnect: macro restarted from the beginning using preset '" CurrentPresetName "'.")
        else if startScreenIdx
            LogMsg("Macro started using preset '" CurrentPresetName "', beginning at screen '" curStartScreen "' step " curStartStep ".")
        else
            LogMsg("Macro started using preset '" CurrentPresetName "'.")
        MainLoop(startScreenIdx, startScreenIdx ? Max(1, curStartStep) : 1)

        if !DisconnectRestartPending
            break
        DisconnectRestartPending := false
        curStartScreen := ""
        curStartStep := 0
        isAutoRestart := true
    }
}

; ============================================================
; MAIN LOOP
; Walks the preset's Screens in list order. Each screen's Logic steps can jump execution straight
; to another screen (by name) via On True/On False; if a screen finishes without any jump firing,
; execution falls through to the next screen in the list, wrapping back to the first screen after
; the last. A "cycle" is considered complete every time execution returns to the first screen.
; ============================================================
; Finds which screen contains a "Start" component (if any) - that's where each cycle begins, and
; where the "cycle complete" bookkeeping (wait/save/max-rounds) fires when execution returns to
; it. Falls back to the first screen in the list if no "Start" component exists anywhere (the
; original always-start-at-the-top behavior), and warns if more than one was found.
FindStartScreenIndex(screens) {
    found := 0
    count := 0
    for i, scr in screens {
        for st in scr.Steps {
            if (st.Type = "Start") {
                count += 1
                if !found
                    found := i
            }
        }
    }
    if (count > 1)
        LogMsg("WARNING: multiple 'Start' components found - using the first one, on screen '" screens[found].Name "'.")
    return found ? found : 1
}

; startScreenIdx/startStepIdx: if startScreenIdx is nonzero, the FIRST screen executed is that one
; (starting partway in, at startStepIdx) instead of the preset's normal start screen - used by
; "Start Macro From This Step". Cycle-complete bookkeeping and wraparound always target the
; preset's real start screen (FindStartScreenIndex), regardless of where execution began, so an
; ad-hoc start doesn't disturb normal max-rounds/cycle-wait behavior once the macro catches up to
; the normal flow.
MainLoop(startScreenIdx := 0, startStepIdx := 1) {
    global Running, Paused, PresetScreens, roundWaitEdit, maxRoundsEdit, RunningScreenName, CurrentCycleCount

    trueStartIdx := FindStartScreenIndex(PresetScreens)
    screenIdx := startScreenIdx ? startScreenIdx : trueStartIdx
    cycleCount := 0
    CurrentCycleCount := 0
    firstIteration := true
    while Running {
        if Paused {
            Sleep 200
            continue
        }

        scr := PresetScreens[screenIdx]
        RunningScreenName := scr.Name
        stepStart := firstIteration ? startStepIdx : 1
        firstIteration := false
        jumpTarget := RunSteps(scr.Steps, stepStart)
        if !Running
            break

        if (jumpTarget != "") {
            nextIdx := 0
            for i, s in PresetScreens {
                if (s.Name = jumpTarget) {
                    nextIdx := i
                    break
                }
            }
            if !nextIdx {
                LogMsg("WARNING: jump target screen '" jumpTarget "' not found - falling through instead.")
                nextIdx := (screenIdx = PresetScreens.Length) ? trueStartIdx : screenIdx + 1
            } else {
                LogMsg("Screen '" scr.Name "' -> jumping to '" jumpTarget "'.")
            }
        } else {
            nextIdx := (screenIdx = PresetScreens.Length) ? trueStartIdx : screenIdx + 1
        }
        screenIdx := nextIdx

        if (screenIdx = trueStartIdx) {
            cycleCount += 1
            CurrentCycleCount := cycleCount
            RenderStatsPanel()
            LogMsg("--- Cycle " cycleCount " complete ---")

            extraWait := SafeNum(roundWaitEdit.Value)
            if (extraWait > 0) {
                waited := 0
                while (waited < extraWait && Running) {
                    remaining := Round(Max(0, extraWait - waited), 2)
                    LogMsgReplace("Waiting " Format("{:.2f}", remaining) "s before next cycle...")
                    Sleep 10
                    waited += 0.01
                }
                LogMsg("Cycle wait complete.")
            }

            SaveConfig()

            maxR := SafeInt(maxRoundsEdit.Value)
            if (maxR > 0 && cycleCount >= maxR) {
                LogMsg("Max cycles (" maxR ") reached. Stopping.")
                Running := false
                break
            }
        }
    }
    LogMsg("Macro stopped. Ready to restart with F10.")
}

; "Once per cycle" steps skip themselves once done, until the next "Detect Map" step runs (i.e. a
; new round has started) resets every step's AlreadyDone flag back to false.
ResetOncePerCycleFlags() {
    global PresetScreens
    for scr in PresetScreens
        for st in scr.Steps
            st.AlreadyDone := false
}

; If the Edit Preset window is currently open (and showing the preset that's actually running),
; keeps it following along with the macro - switches it to whichever screen is about to execute
; and highlights/scrolls to that step. This is a "follow" view: switching screens flushes whatever
; was shown for the previous one to ini first (so nothing typed is lost), then reloads the new
; screen fresh from ini, discarding any not-yet-saved edits made to IT in the meantime.
SyncEditGuiToRunningStep(screenName, stepIdx) {
    global EditGuiVisible, RunningPresetName, CurrentPresetName, CurrentScreenName, screenDdl, stepsLV
    if (screenName = "" || !EditGuiVisible || RunningPresetName != CurrentPresetName)
        return
    if (CurrentScreenName != screenName) {
        SaveScreenToIni(CurrentPresetName, CurrentScreenName)
        CurrentScreenName := screenName
        screenDdl.Text := screenName
        LoadScreenSteps(CurrentPresetName, screenName)
    }
    try stepsLV.Modify(stepIdx, "Select Focus Vis")
}

; Resolves which map to act on: the map detected via "Detect Map" this cycle, or the preset's
; configured Default Map if none was detected (or detection hasn't run yet).
ResolveMapName() {
    global LastDetectedMap, CurrentPresetName
    mapName := LastDetectedMap
    if (mapName = "") {
        defaultMap := Cfg("Preset_" CurrentPresetName, "DefaultMap", "(none)")
        if (defaultMap != "" && defaultMap != "(none)") {
            mapName := defaultMap
            LogMsg("No map detected via 'Detect Map' - using configured Default Map: " mapName)
        }
    }
    return mapName
}

; Runs a map's Drag/Zoom Out actions (Map Advanced Settings) once per cycle, then marks it done so
; neither an explicit "Camera Setup" step nor the automatic trigger inside "Place Towers" repeats
; it - whichever of the two runs first for this cycle "wins", the other becomes a no-op. Uses the
; map's own custom camera/zoom steps if it has them enabled, otherwise the shared [General] ones.
RunMapAdvStepsForMap(mapName, clickDelay) {
    global Running, MapAdvStepsDoneThisCycle
    if MapAdvStepsDoneThisCycle {
        LogMsg("Camera setup: already done this cycle - skipping.")
        return
    }
    mapSection := "MapProfile_" mapName
    useCustom := SafeInt(Cfg(mapSection, "CustomCamera", "0"))
    camSection := useCustom ? mapSection : "General"
    advSteps := GetMapAdvSteps(camSection)
    LogMsg("Camera setup for '" mapName "': using " (useCustom ? "its own custom" : "the shared [General]") " actions (" advSteps.Length " configured).")
    if (advSteps.Length = 0)
        LogMsg("WARNING: no Drag/Zoom Out actions configured " (useCustom ? "for '" mapName "'" : "in the shared default") " - nothing to run. Add some via Map Placement > Advanced Settings.")
    for advStep in advSteps {
        if !Running
            return
        if (advStep.Type = "Drag") {
            DragRightClick(SafeInt(advStep.X), SafeInt(advStep.Y), SafeInt(advStep.EndX), SafeInt(advStep.EndY), SafeInt(advStep.DragMs))
            LogMsg("Map action: dragged (" advStep.X ", " advStep.Y ") -> (" advStep.EndX ", " advStep.EndY ") over " advStep.DragMs "ms.")
        } else if (advStep.Type = "Zoom Out") {
            ZoomOutTicks(SafeInt(advStep.X))
        }
        Sleep clickDelay
    }
    MapAdvStepsDoneThisCycle := true
}

; Resolves which screen a Logic step should jump to given its OCR result: true -> OnTrueScreen,
; false -> OnFalseScreen. "(continue)" (or blank) means "don't jump, keep running this screen".
LogicJumpTarget(step, result) {
    target := result ? step.OnTrueScreen : step.OnFalseScreen
    return (target = "" || target = "(continue)") ? "" : target
}

; Runs one screen's steps in order. Returns the name of the screen to jump to next (set by a
; Logic step's On True/On False result), or "" if the screen ran to the end without any jump
; firing - meaning the caller should fall through to the next screen in list order.
; startAt (1-based) lets the caller begin partway into `steps`, skipping everything before it -
; used by "Start Macro From This Step" for the very first screen it runs; every other call uses
; the default of 1 (run the whole screen from the top), same as before.
RunSteps(steps, startAt := 1) {
    global Running, Paused, OptData, clickDelayEdit, placeTowerDelayEdit, LastDetectedMap, CurrentPresetName, MapAdvStepsDoneThisCycle
    global afterPlaceClickChk, afterPlaceXEdit, afterPlaceYEdit, RunningScreenName
    global backXEdit, backYEdit, fallbackScreenDdl
    global RunningStepDescription
    global UsageUsedEdits
    clickDelay := SafeInt(clickDelayEdit.Value)
    placeTowerDelay := SafeInt(placeTowerDelayEdit.Value)

    ; Index-based (rather than a plain for-in) so a step whose On True/On False resolves to
    ; "(Repeat)" can redo itself by simply not advancing stepIdx, instead of moving on to the
    ; next step - see the "(Repeat)" handling near the bottom of this loop.
    stepIdx := 1
    while (stepIdx <= steps.Length) {
        step := steps[stepIdx]
        if (stepIdx < startAt) {
            stepIdx += 1
            continue
        }
        if !Running
            return ""
        while Paused {
            Sleep 200
            if !Running
                return ""
        }

        if (step.OncePerCycle && step.AlreadyDone) {
            stepIdx += 1
            continue
        }

        SyncEditGuiToRunningStep(RunningScreenName, stepIdx)
        RunningStepDescription := step.Type . (step.Label != "" ? " (" step.Label ")" : "")
        RenderStatsPanel()

        stepJumpTarget := ""

        switch step.Type {
            case "Start":
                ; Marker only - identifies which screen this preset's cycle starts on (see
                ; FindStartScreenIndex). No action here.

            case "Option Select":
                ; Try each option in priority order: click it, then (if an Availability Check is
                ; configured for it) verify it's actually playable right now via OCR - if not,
                ; click Back and move on to the next priority. Every option is re-checked fresh
                ; like this on every single pass (no cooldown/skip-ahead) - only "Available at
                ; start" unchecked, or its daily "Max" limit already reached, skips one without
                ; clicking it. If NONE end up available, jump straight to the Fallback Screen
                ; instead - or, if that's set to "(Stop Macro)", stop the run outright (both of
                ; which stay in effect every cycle for the rest of the day once every option's
                ; daily limit is exhausted, since none of them can become available again until
                ; the counters reset tomorrow). With no Fallback Screen configured, falls back to
                ; the old wait-5s-and-recheck loop.
                fbScreen := fallbackScreenDdl.Text
                stopOnExhausted := (fbScreen = "(Stop Macro)")
                hasFallback := (!stopOnExhausted && fbScreen != "" && fbScreen != "(none)")
                usageSection := "Preset_" CurrentPresetName

                order := []
                for oi, o in OptData
                    order.Push({Idx: oi, Prio: SafeInt(o.PrioDdl.Text, oi)})
                Loop order.Length - 1 {
                    outer := A_Index
                    Loop order.Length - outer {
                        j := A_Index
                        if (order[j].Prio > order[j + 1].Prio) {
                            tmp := order[j]
                            order[j] := order[j + 1]
                            order[j + 1] := tmp
                        }
                    }
                }

                picked := false
                while (!picked && Running) {
                    for entry in order {
                        opt := OptData[entry.Idx]
                        if !opt.AvailChk.Value
                            continue
                        maxUses := SafeInt(opt.MaxEdit.Value, 0)
                        usedToday := GetOptionUsedToday(usageSection, entry.Idx)
                        if (maxUses > 0 && usedToday >= maxUses) {
                            LogMsg("Option " entry.Idx " (" opt.NameEdit.Value ") daily limit reached (" usedToday "/" maxUses ") - skipping.")
                            continue
                        }
                        Click SafeInt(opt.XEdit.Value), SafeInt(opt.YEdit.Value)
                        Sleep clickDelay
                        LogMsg("Option " entry.Idx " (" opt.NameEdit.Value ") clicked, checking availability...")
                        if (opt.DetText != "") {
                            detRect := {x: Min(SafeInt(opt.DetX), SafeInt(opt.DetEndX)), y: Min(SafeInt(opt.DetY), SafeInt(opt.DetEndY)),
                                w: Abs(SafeInt(opt.DetEndX) - SafeInt(opt.DetX)), h: Abs(SafeInt(opt.DetEndY) - SafeInt(opt.DetY))}
                            found := IsTextDetectedInRegion(detRect, opt.DetText)
                            available := opt.DetInvert ? !found : found
                            ReactivateGameWindow()
                            if !available {
                                LogMsg("Option " entry.Idx " (" opt.NameEdit.Value ") not available - going back.")
                                Click SafeInt(backXEdit.Value), SafeInt(backYEdit.Value)
                                Sleep clickDelay
                                continue
                            }
                        }
                        picked := true
                        newUsed := IncrementOptionUsed(CurrentPresetName, entry.Idx)
                        try UsageUsedEdits[entry.Idx].Value := newUsed
                        LogMsg("Option " entry.Idx " (" opt.NameEdit.Value ") available - playing. (" newUsed "/" (maxUses > 0 ? maxUses : "unlimited") " today)")
                        break
                    }
                    if picked
                        break
                    if stopOnExhausted {
                        LogMsg("No option available (daily limits reached) - stopping the macro.")
                        Running := false
                        break
                    }
                    if hasFallback {
                        LogMsg("No option available - switching to Fallback Screen '" fbScreen "'.")
                        stepJumpTarget := fbScreen
                        break
                    }
                    LogMsg("No option available, waiting 5s...")
                    Sleep 5000
                }
                if !Running
                    return ""

            case "Button Click", "Press Start Button", "Restart Stage Button":
                Click SafeInt(step.X), SafeInt(step.Y)
                Sleep clickDelay
                LogMsg("Clicked '" step.Label "' at (" step.X ", " step.Y ")")

            case "Detect Map":
                ; Reached the map detection screen again - a new round is starting, so any
                ; "Once per cycle" steps (and the map's Drag/Zoom Out actions) are allowed to run
                ; once more.
                ResetOncePerCycleFlags()
                MapAdvStepsDoneThisCycle := false
                ; Run this step WHILE the map name banner is still visible (e.g. right after
                ; Option Select, before the button clicks that enter the round) - the banner is
                ; usually gone once you're already in-game, so detecting later won't work.
                LogMsg("Detecting map...")
                LastDetectedMap := DetectMapProfileInRegion(RectFromStep(step), 5)
                ; The OCR helper shells out to PowerShell, which can steal window focus even when
                ; hidden. Reactivate the game window so subsequent Send/Click still land correctly.
                ReactivateGameWindow()
                mapDetected := (LastDetectedMap != "")
                if !mapDetected
                    LogMsg("WARNING: no map detected (OCR text did not match any map profile).")
                else
                    LogMsg("Map detected: " LastDetectedMap)
                RenderStatsPanel()
                stepJumpTarget := LogicJumpTarget(step, mapDetected)

            case "Camera Setup":
                ; Explicitly runs this map's Drag/Zoom Out actions (Map Advanced Settings) once
                ; per cycle - put this as the first step of a screen (e.g. "Ingame") if you need
                ; the camera positioned/zoomed out BEFORE anything else happens on that screen,
                ; rather than waiting for a "Place Towers" step to trigger it implicitly.
                LogMsg("Camera Setup step running (last detected map: '" LastDetectedMap "')...")
                mapName := ResolveMapName()
                if (mapName = "") {
                    LogMsg("WARNING: no map detected and no Default Map configured. Skipping camera setup.")
                } else {
                    ReactivateGameWindow()
                    RunMapAdvStepsForMap(mapName, clickDelay)
                }

            case "Place Towers":
                mapName := ResolveMapName()
                if (mapName = "") {
                    LogMsg("WARNING: no map detected and no Default Map configured. Skipping tower placement.")
                } else {
                    ReactivateGameWindow()
                    ; Map actions (Drag/Zoom Out) come from [General] (shared) unless this map has
                    ; its own custom copy (set via the "custom camera/zoom" checkbox on that map).
                    ; Only runs once per cycle - a no-op here if a "Camera Setup" step already ran
                    ; it earlier on this screen, or reset again once a "Detect Map" step runs.
                    RunMapAdvStepsForMap(mapName, clickDelay)
                    placements := GetMapProfilePlacements(mapName)

                    LogMsg("Placing towers for map: " mapName)
                    for row in placements {
                        if !Running
                            return ""
                        Send row.Slot
                        Sleep placeTowerDelay
                        ; Same click method as "Button Click" / "Press Start Button" / "Restart Stage Button".
                        Click SafeInt(row.X), SafeInt(row.Y)
                        Sleep placeTowerDelay
                        LogMsg("Slot " row.Slot " placed at (" row.X ", " row.Y ") [" mapName "]")
                        if afterPlaceClickChk.Value {
                            Click SafeInt(afterPlaceXEdit.Value), SafeInt(afterPlaceYEdit.Value)
                            Sleep placeTowerDelay
                            LogMsg("After-place click at (" afterPlaceXEdit.Value ", " afterPlaceYEdit.Value ")")
                        }
                    }
                }

            case "Round End Detection", "Ingame Detection", "Custom Detection":
                what := (step.Type = "Round End Detection") ? "round end" : (step.Type = "Ingame Detection") ? "ingame state" : "'" step.Label "'"
                LogMsg("Checking for " what "...")
                detectResult := IsTextDetectedInRegion(RectFromStep(step), step.Label)
                ReactivateGameWindow()
                if detectResult
                    LogMsg(step.Type ": text matched.")
                else
                    LogMsg(step.Type ": text not matched.")
                stepJumpTarget := LogicJumpTarget(step, detectResult)

            case "Drag":
                dStartX := SafeInt(step.X)
                dStartY := SafeInt(step.Y)
                dEndX := SafeInt(step.EndX)
                dEndY := SafeInt(step.EndY)
                dDurMs := SafeInt(step.DragMs)
                DragRightClick(dStartX, dStartY, dEndX, dEndY, dDurMs)
                LogMsg("Dragged '" step.Label "': (" dStartX ", " dStartY ") -> (" dEndX ", " dEndY ") over " dDurMs "ms.")

            case "Zoom Out":
                ticks := SafeInt(step.X)
                if (ticks > 0) {
                    Click "WheelDown " ticks
                    LogMsg("Zoomed out (" ticks " wheel ticks).")
                }

            case "Wait":
                ; no action here; the "Wait After" value below performs the delay
        }

        ; Mechanic steps (everything except Detect Map / Round End Detection / Ingame Detection)
        ; have no OCR result to branch on, so their "On True" field is just an unconditional jump
        ; instead - e.g. a plain Round End button that always goes straight back to "Ingame".
        ; Skipped if stepJumpTarget is already set (e.g. "Option Select" jumping to its Fallback
        ; Screen because nothing was available) - that more specific jump takes priority.
        if (!IsLogicStepType(step.Type) && stepJumpTarget = "" && step.OnTrueScreen != "" && step.OnTrueScreen != "(continue)")
            stepJumpTarget := step.OnTrueScreen

        if step.OncePerCycle
            step.AlreadyDone := true

        extraWait := SafeNum(step.Seconds)
        if (extraWait > 0) {
            waited := 0
            while (waited < extraWait && Running) {
                remaining := Round(Max(0, extraWait - waited), 2)
                LogMsgReplace("Waiting " Format("{:.2f}", remaining) "s after '" step.Type "'...")
                Sleep 10
                waited += 0.01
            }
            LogMsg("Waited " extraWait "s after '" step.Type "'.")
        }

        ; "(Repeat)" re-runs this exact step again - stepIdx is deliberately left unchanged - rather
        ; than being returned up to MainLoop as if it were a real screen name to jump to.
        if (stepJumpTarget = "(Repeat)")
            continue

        if (stepJumpTarget != "" && Running)
            return stepJumpTarget

        stepIdx += 1
    }
    return ""
}
