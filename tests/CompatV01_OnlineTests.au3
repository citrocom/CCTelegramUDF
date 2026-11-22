; SPDX-License-Identifier: GPL-3.0-or-later
; Online test of compat\Telegram.au3: calls the functions of release v0.1 of xLinkOut/telegram-udf-autoit.
; Run it from a folder that contains CCTelegramUDF.au3, CCTelegramUDF_Methods.au3, the compat Telegram.au3 and
; include\JSON.au3 (+ BinaryCall.au3), e.g. copy this file next to Telegram.au3. Uses config.ini ([Telegram] Token/ChatId)
; next to this file or in tests\. The polling test at the end waits for you to send a message to the bot.
#AutoIt3Wrapper_Run_AU3Check=Y
Opt("MustDeclareVars", 1)

#include "Telegram.au3"

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

Global $bInit = _InitBot("123:invalid"), $iInitErr = @error
_Check($bInit = False And $iInitErr = $INVALID_TOKEN_ERROR, "_InitBot with invalid token fails like before")
_Check(_InitBot($g_sToken), "_InitBot")

Global $aMe = _GetMe()
_Check(IsArray($aMe) And UBound($aMe) = 3 And $aMe[1] <> "", "_GetMe returns [id, username, first_name] (@" & (IsArray($aMe) ? $aMe[1] : "") & ")")

Global $iMsg = _SendMsg($g_sChat, "v0.1 compat: Zeile 1" & $BOT_CRLF & "Zeile 2 & mehr #1 + 1 äöü")
_Check(IsInt($iMsg) And $iMsg > 0, "_SendMsg returns the message_id")
_Check(IsInt(_SendMsg($g_sChat, "<b>HTML</b> reply", "html", Default, $iMsg, True, True)), "_SendMsg with parse mode, reply, no preview, silent")
_Check(IsInt(_ForwardMessage($g_sChat, $g_sChat, $iMsg)), "_ForwardMessage returns the new message_id")

Global $aKeyboard[4] = ['Top Left', 'Top Right', '', 'Second Row']
_Check(IsInt(_SendMsg($g_sChat, "Keyboard", Default, _CreateKeyboard($aKeyboard, True, True))), "_CreateKeyboard")
Global $aInline[5] = ['Button 1', 'data_1', '', 'Button 2', 'data_2']
_Check(IsInt(_SendMsg($g_sChat, "Inline keyboard", Default, _CreateInlineKeyboard($aInline))), "_CreateInlineKeyboard")

Global $sMedia = @ScriptDir & "\tests\media\"
If Not FileExists($sMedia) Then $sMedia = @ScriptDir & "\media\"
Global $sPhotoId = _SendPhoto($g_sChat, $sMedia & "image1.png", "Foto & Caption", Default, $iMsg)
_Check(IsString($sPhotoId) And $sPhotoId <> "", "_SendPhoto (local, reply) returns a file_id")
_Check(IsString(_SendPhoto($g_sChat, $sPhotoId, "same photo by file_id")), "_SendPhoto by file_id")
Global $sDocId = _SendDocument($g_sChat, $sMedia & "document.txt", "Dokument")
_Check(IsString($sDocId) And $sDocId <> "", "_SendDocument returns a file_id")

Global $sPath = __GetFilePath($sDocId)
_Check($sPath <> "", "__GetFilePath")
Global $sFile = __DownloadFile($sPath)
_Check($sFile <> False And FileExists($sFile), "__DownloadFile")
If FileExists($sFile) Then FileDelete($sFile)

Global $aMedias[2] = [$sMedia & "image1.png", $sMedia & "image2.png"]
Global $aIds = _SendMediaGroup($g_sChat, $aMedias)
_Check(IsArray($aIds) And UBound($aIds) = 2 And $aIds[0] <> "", "_SendMediaGroup with array of files returns file_ids")
_Check(IsArray(_SendMediaGroup($g_sChat, '[{"type":"photo","media":"' & $sPhotoId & '"},{"type":"photo","media":"' & $sPhotoId & '"}]')), "_SendMediaGroup with JSON as before")

_Check(_SendLocation($g_sChat, 50.9833, 8.1, 60) = True, "_SendLocation (live)")
_Check(_EditMessageLiveLocation($g_sChat, 50.99, 8.11) = True, "_EditMessageLiveLocation (did not work in v0.1)")
_Check(_StopMessageLiveLocation($g_sChat) = True, "_StopMessageLiveLocation")
_Check(_SendVenue($g_sChat, 50.9833, 8.1, "Hilchenbach", "Marktplatz & Co") = True, "_SendVenue")
_Check(_SendContact($g_sChat, "+49 123 456", "Max", "Mustermann") = True, "_SendContact")
_Check(_SendChatAction($g_sChat, "typing") = True, "_SendChatAction")
_Check(_SendChatAction($g_sChat, "upload_audio") = True, "_SendChatAction with old action name")

Global $aChat = _GetChat($g_sChat)
_Check(IsArray($aChat) And UBound($aChat) = 4, "_GetChat returns [id, username, first_name, photo]")
Global $aPhotos = _GetUserProfilePhotos($g_sChat)
_Check(IsArray($aPhotos) Or @error = $OFFSET_GRATER_THAN_TOTAL, "_GetUserProfilePhotos")

Global $iDel = _SendMsg($g_sChat, "will be deleted")
_Check(_deleteMessage($g_sChat, $iDel) = True, "_deleteMessage")
_Check(StringInStr(__HttpGet($URL & "/getMe"), '"ok":true') > 0, "__HttpGet with a raw Bot API URL")

Global $vFail = _SendMsg("1", "invalid chat"), $iFailErr = @error
_Check($vFail = False And $iFailErr = 2, "API error -> False, @error 2 (" & _CCTelegram_LastErrorDescription() & ")")

ConsoleWrite(@CRLF & ">>> Send any text message to the bot now (polling test, Ctrl+Break to skip) ..." & @CRLF)
Global $msgData = _Polling()
_Check(IsArray($msgData) And $msgData[0] > 0, "_Polling returns $msgData (update " & $msgData[0] & ", text: " & (UBound($msgData) > 5 ? $msgData[5] : "") & ")")

ConsoleWrite(@CRLF & "Passed: " & $g_iPassed & "   Failed: " & $g_iFailed & @CRLF)
Exit $g_iFailed ? 1 : 0
