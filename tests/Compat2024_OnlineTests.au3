; SPDX-License-Identifier: GPL-3.0-or-later
; Online test of compat\Telegram2024.au3: calls the functions of the 2024 rewrite of xLinkOut/telegram-udf-autoit.
; Run it from a folder that contains CCTelegramUDF.au3, CCTelegramUDF_Methods.au3, Telegram2024.au3 and include\JSON.au3
; (the layout of the old UDF), e.g. copy this file next to Telegram2024.au3. Uses tests\config.ini of CCTelegramUDF.
#AutoIt3Wrapper_Run_AU3Check=Y
Opt("MustDeclareVars", 1)

#include "Telegram2024.au3"

Global $g_iPassed = 0, $g_iFailed = 0
Global $g_sIni = @ScriptDir & "\config.ini"
If Not FileExists($g_sIni) Then $g_sIni = @ScriptDir & "\tests\config.ini"
Global Const $g_sToken = IniRead($g_sIni, "Telegram", "Token", "")
Global Const $g_sChat = IniRead($g_sIni, "Telegram", "ChatId", "")
If $g_sToken = "" Or $g_sChat = "" Then
    ConsoleWrite("config.ini with [Telegram] Token/ChatId not found" & @CRLF)
    Exit 2
EndIf

Func _Check($bCondition, $sName, $iLine = @ScriptLineNumber)
    If $bCondition Then
        $g_iPassed += 1
        ConsoleWrite("  ok   " & $sName & @CRLF)
    Else
        $g_iFailed += 1
        ConsoleWrite("! FAIL (" & $iLine & ") " & $sName & "  -> " & _CCTelegram_LastErrorDescription() & @CRLF)
    EndIf
EndFunc   ;==>_Check

Global $bInit = _Telegram_Init(""), $iInitErr = @error
_Check($bInit = False And $iInitErr = $TG_ERR_INIT, "init with empty token fails like before")
_Check(_Telegram_Init($g_sToken, True), "init with validation")

Global $oMe = _Telegram_GetMe()
_Check(Json_Get($oMe, "[is_bot]") = True, "getMe + Json_Get of the old JSON UDF")

Global $oMsg = _Telegram_SendMessage($g_sChat, "Compat: Zeile 1" & $BOT_CRLF & "Zeile 2 & mehr #1 + 1")
_Check(IsInt(Json_Get($oMsg, "[message_id]")), "sendMessage with $BOT_CRLF and special characters")
_Check(StringInStr(Json_Get($oMsg, "[text]"), "& mehr #1 + 1") > 0, "text arrives completely")

Global $aKeyboard[4] = ['Top Left', 'Top Right', '', 'Second Row']
_Check(IsObj(_Telegram_SendMessage($g_sChat, "Compat keyboard", Null, _Telegram_CreateKeyboard($aKeyboard, True, True))), "_Telegram_CreateKeyboard")
Global $aInline[5] = ['Button 1', 'data_1', '', 'Button 2', 'data_2']
_Check(IsObj(_Telegram_SendMessage($g_sChat, "Compat inline", Null, _Telegram_CreateInlineKeyboard($aInline))), "_Telegram_CreateInlineKeyboard")

Global $iId = Json_Get($oMsg, "[message_id]")
_Check(IsObj(_Telegram_SendMessage($g_sChat, "Reply", "HTML", Null, $iId, True, True)), "reply + disable preview + silent")
_Check(IsObj(_Telegram_ForwardMessage($g_sChat, $g_sChat, $iId)), "forwardMessage")

Global $sMedia = @ScriptDir & "\tests\media\"
If Not FileExists($sMedia) Then $sMedia = @ScriptDir & "\media\"
_Check(IsObj(_Telegram_SendPhoto($g_sChat, $sMedia & "image1.png", "Foto & Caption")), "sendPhoto (local)")
_Check(IsObj(_Telegram_SendDocument($g_sChat, $sMedia & "document.txt", "Dokument", "", "", $iId)), "sendDocument with reply")
Global $aMedias[2] = [$sMedia & "image1.png", $sMedia & "image2.png"]
_Check(IsArray(_Telegram_SendMediaGroup($g_sChat, $aMedias)), "sendMediaGroup (was broken in the original)")

_Check(IsObj(_Telegram_SendLocation($g_sChat, 50.9833, 8.1)), "sendLocation")
_Check(IsObj(_Telegram_SendVenue($g_sChat, 50.9833, 8.1, "Hilchenbach", "Marktplatz & Co")), "sendVenue")
_Check(IsObj(_Telegram_SendContact($g_sChat, "+49 123 456", "Max", "Mustermann")), "sendContact")
_Check(_Telegram_SendChatAction($g_sChat, "typing") = True, "sendChatAction")
Global $vAction = _Telegram_SendChatAction($g_sChat, "type"), $iActionErr = @error
_Check(IsKeyword($vAction) = 2 And $iActionErr = $TG_ERR_BAD_INPUT, "invalid chat action rejected")
_Check(IsObj(_Telegram_GetChat($g_sChat)), "getChat")

Global $oDel = _Telegram_SendMessage($g_sChat, "will be deleted")
_Check(_Telegram_DeleteMessage($g_sChat, Json_Get($oDel, "[message_id]")) = True, "deleteMessage")

Global $oRaw = _Telegram_API_Call($URL, "/sendMessage", "POST", "chat_id=" & $g_sChat & "&text=" & _Telegram_UrlEncode("API_Call & Co"))
_Check(IsObj($oRaw), "_Telegram_API_Call with query string")

_Check(IsArray(_Telegram_GetUpdates()), "getUpdates")

_Telegram_SendMessage("1", "invalid chat")
_Check(@error = $TG_ERR_API_CALL, "API error mapped to $TG_ERR_API_CALL (" & _CCTelegram_LastErrorDescription() & ")")

ConsoleWrite(@CRLF & "Passed: " & $g_iPassed & "   Failed: " & $g_iFailed & @CRLF)
Exit $g_iFailed ? 1 : 0
