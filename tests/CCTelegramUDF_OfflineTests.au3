; SPDX-License-Identifier: GPL-3.0-or-later
; CCTelegramUDF - offline tests (no network, no token needed). Run with F5 in SciTE; results go to the console.
#AutoIt3Wrapper_Run_AU3Check=Y
#AutoIt3Wrapper_AU3Check_Parameters=-d -w 1 -w 2 -w 3 -w 4 -w 5 -w 6 -w 7
Opt("MustDeclareVars", 1)

#include "..\CCTelegramUDF.au3"

Global $g_iPassed = 0, $g_iFailed = 0, $i

Func _Check($bCondition, $sName, $vInfo = "", $iLine = @ScriptLineNumber)
    If $bCondition Then
        $g_iPassed += 1
        ConsoleWrite("  ok   " & $sName & @CRLF)
    Else
        $g_iFailed += 1
        ConsoleWrite("! FAIL (" & $iLine & ") " & $sName & ($vInfo = "" ? "" : "  -> " & $vInfo) & @CRLF)
    EndIf
EndFunc   ;==>_Check

ConsoleWrite("CCTelegramUDF " & _CCTelegram_Version() & " / Bot API " & $CCTELEGRAM_API_VERSION & " (" & $CCTELEGRAM_API_METHODS & " methods)" & @CRLF)

; --- JSON decoding ---------------------------------------------------------------------------------------------------
ConsoleWrite("JSON decode" & @CRLF)
Global $v = _CCTelegram_JsonDecode('{"ok":true,"result":{"id":123456789012,"name":"Bot \"X\"","list":[1,-2.5,3e2,null,false,[],{}],"u":"\u00e4\ud83d\ude00","esc":"a\\b\/c\n"}}')
_Check(Not @error, "valid document parses")
_Check(_CCTelegram_Get($v, "ok") = True, "boolean true")
_Check(_CCTelegram_Get($v, "result.id") = 123456789012, "Int64 value", _CCTelegram_Get($v, "result.id"))
_Check(_CCTelegram_Get($v, "result.name") == 'Bot "X"', "escaped quotes")
_Check(_CCTelegram_Get($v, "result.list[1]") = -2.5, "negative float")
_Check(_CCTelegram_Get($v, "result.list[2]") = 300, "exponent")
_Check(IsKeyword(_CCTelegram_Get($v, "result.list[3]", "x")) = 2, "null -> Null")
_Check(_CCTelegram_Get($v, "result.list[4]") = False And IsBool(_CCTelegram_Get($v, "result.list[4]")), "boolean false")
_Check(IsArray(_CCTelegram_Get($v, "result.list[5]")) And UBound(_CCTelegram_Get($v, "result.list[5]")) = 0, "empty array")
Global $oEmpty = _CCTelegram_Get($v, "result.list[6]")
_Check(IsObj($oEmpty) And $oEmpty.Count = 0, "empty object")
_Check(_CCTelegram_Get($v, "result.u") == ChrW(0xE4) & ChrW(0xD83D) & ChrW(0xDE00), "\u escapes incl. surrogate pair")
_Check(_CCTelegram_Get($v, "result.esc") == "a\b/c" & @LF, "backslash, slash, newline")
_Check(_CCTelegram_Get($v, "result.missing", "default") = "default" And @error, "missing path returns default + @error")

_CCTelegram_JsonDecode('{"a":1,}')
_Check(@error = $CCTELEGRAM_ERR_JSON, "trailing comma is rejected")
_CCTelegram_JsonDecode('{"a":1} x')
_Check(@error = $CCTELEGRAM_ERR_JSON, "garbage after document is rejected")
_CCTelegram_JsonDecode('')
_Check(@error = $CCTELEGRAM_ERR_JSON, "empty input is rejected")

Global $sLong = ""
For $i = 1 To 2000
    $sLong &= 'Zeile ' & $i & ' mit \"Escape\" und \u00fc '
Next
$v = _CCTelegram_JsonDecode('"' & $sLong & '"')
_Check(Not @error And StringLen($v) = 58893, "long string with many escapes (" & StringLen($v) & " chars)")

; --- JSON encoding ---------------------------------------------------------------------------------------------------
ConsoleWrite("JSON encode" & @CRLF)
Global $aRow[2] = [1, "zwei"]
Global $o = _CCTelegram_Obj("text", 'Tab' & @TAB & 'Quote"Back\' & @CRLF & "äö", "n", 42, "f", 1.5, "b", True, "z", Null, "skip", Default, "arr", $aRow)
_Check(_CCTelegram_JsonEncode($o) == '{"text":"Tab\tQuote\"Back\\\r\näö","n":42,"f":1.5,"b":true,"z":null,"arr":[1,"zwei"]}', "object with all types", _CCTelegram_JsonEncode($o))
Global $a2D[2][2] = [["a", "b"], ["c", "d"]]
_Check(_CCTelegram_JsonEncode($a2D) == '[["a","b"],["c","d"]]', "2D array -> rows")
_Check(_CCTelegram_JsonEncode(Chr(1)) == '"\u0001"', "control character")
Global $vBack = _CCTelegram_JsonDecode(_CCTelegram_JsonEncode($o))
_Check(_CCTelegram_Get($vBack, "text") == _CCTelegram_Get($o, "text"), "round trip of a difficult string")

; --- Keyboards ---------------------------------------------------------------------------------------------------------
ConsoleWrite("Keyboards" & @CRLF)
Global $aKb1[4] = ["Top Left", "Top Right", "", 'Second "Row"']
_Check(_CCTelegram_JsonEncode(_CCTelegram_ReplyKeyboard($aKb1, True, True)) == '{"keyboard":[[{"text":"Top Left"},{"text":"Top Right"}],[{"text":"Second \"Row\""}]],"resize_keyboard":true,"one_time_keyboard":true}', _
        "reply keyboard from 1D array with separator", _CCTelegram_JsonEncode(_CCTelegram_ReplyKeyboard($aKb1, True, True)))
Global $aKb2[5] = ["", "A", "", "", "B"]
_Check(_CCTelegram_JsonEncode(_CCTelegram_ReplyKeyboard($aKb2, False, False)) == '{"keyboard":[[{"text":"A"}],[{"text":"B"}]],"resize_keyboard":false,"one_time_keyboard":false}', "empty rows are skipped")
Global $aKb3[2][2]
$aKb3[0][0] = _CCTelegram_InlineButton("Ja", "yes")
$aKb3[0][1] = _CCTelegram_InlineButton("Nein", "no")
$aKb3[1][0] = _CCTelegram_UrlButton("Website", "https://example.com")
_Check(_CCTelegram_JsonEncode(_CCTelegram_InlineKeyboard($aKb3)) == '{"inline_keyboard":[[{"text":"Ja","callback_data":"yes"},{"text":"Nein","callback_data":"no"}],[{"text":"Website","url":"https://example.com"}]]}', _
        "inline keyboard from 2D array, empty cell skipped")
Global $aRow1[2] = ["1", "2"], $aRow2[1] = ["3"], $aRows[2] = [$aRow1, $aRow2]
_Check(_CCTelegram_JsonEncode(_CCTelegram_ReplyKeyboard($aRows)) == '{"keyboard":[[{"text":"1"},{"text":"2"}],[{"text":"3"}]],"resize_keyboard":true,"one_time_keyboard":false}', "array of row arrays")

; --- Text helpers ------------------------------------------------------------------------------------------------------
ConsoleWrite("Text helpers" & @CRLF)
_Check(_CCTelegram_EscapeMarkdownV2("1+1=2. (a_b) [x]!") == "1\+1\=2\. \(a\_b\) \[x\]\!", "MarkdownV2 escaping", _CCTelegram_EscapeMarkdownV2("1+1=2. (a_b) [x]!"))
_Check(_CCTelegram_EscapeHtml('<b>"A&B"</b>') == "&lt;b&gt;&quot;A&amp;B&quot;&lt;/b&gt;", "HTML escaping")
_Check(_CCTelegram_UrlEncode("a b&ä~") == "a%20b%26%C3%A4~", "URL encode UTF-8", _CCTelegram_UrlEncode("a b&ä~"))
_Check(_CCTelegram_UrlDecode("a%20b%26%C3%A4%0D%0A100%") == "a b&ä" & @CRLF & "100%", "URL decode UTF-8 and lone %")
_Check(_CCTelegram_UrlDecode(_CCTelegram_UrlEncode("Emoji " & ChrW(0xD83D) & ChrW(0xDE00))) == "Emoji " & ChrW(0xD83D) & ChrW(0xDE00), "URL round trip with emoji")

; --- Parameters and errors without network -----------------------------------------------------------------------------
ConsoleWrite("Parameters" & @CRLF)
_CCTelegram_SendMessage(1, "x")
_Check(@error = $CCTELEGRAM_ERR_NOINIT, "call without _CCTelegram_Init -> $CCTELEGRAM_ERR_NOINIT")
_CCTelegram_Init("123:ABC") ; dummy token, no network call
_CCTelegram_SendMessage(1, "x", "{not json")
_Check(@error = $CCTELEGRAM_ERR_INPUT, "invalid options JSON -> $CCTELEGRAM_ERR_INPUT")
_CCTelegram_SendMessage(1, "x", _CCTelegram_Obj("reply_markup", "{broken"))
_Check(@error = $CCTELEGRAM_ERR_INPUT, "invalid reply_markup JSON -> $CCTELEGRAM_ERR_INPUT")
_CCTelegram_SendPhoto(1, "C:\does\not\exist.png")
_Check(@error = $CCTELEGRAM_ERR_FILE, "missing local file -> $CCTELEGRAM_ERR_FILE")
_CCTelegram_InputMedia("photo", ".\nope.jpg")
_Check(@error = $CCTELEGRAM_ERR_FILE, "InputMedia with missing file -> $CCTELEGRAM_ERR_FILE")
Global $oUpd = _CCTelegram_JsonDecode('{"update_id":5,"callback_query":{"id":"1","data":"yes"}}')
_Check(_CCTelegram_UpdateType($oUpd) = "callback_query", "_CCTelegram_UpdateType")

ConsoleWrite(@CRLF & "Passed: " & $g_iPassed & "   Failed: " & $g_iFailed & @CRLF)
Exit $g_iFailed ? 1 : 0
