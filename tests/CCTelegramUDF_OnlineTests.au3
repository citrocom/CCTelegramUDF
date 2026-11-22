; SPDX-License-Identifier: GPL-3.0-or-later
; CCTelegramUDF - online tests against the real Bot API.
; Copy config.example.ini to config.ini, enter a test bot token and the chat id of a private test chat
; (send /start to the bot first). The tests send and delete a number of messages in that chat.
#AutoIt3Wrapper_Run_AU3Check=Y
#AutoIt3Wrapper_AU3Check_Parameters=-d -w 1 -w 2 -w 3 -w 4 -w 5 -w 6 -w 7
Opt("MustDeclareVars", 1)

#include "..\CCTelegramUDF.au3"

Global $g_iPassed = 0, $g_iFailed = 0
Global Const $g_sIni = @ScriptDir & "\config.ini"
Global Const $g_sToken = IniRead($g_sIni, "Telegram", "Token", "")
Global Const $g_vChat = IniRead($g_sIni, "Telegram", "ChatId", "")
If $g_sToken = "" Or $g_vChat = "" Then
    ConsoleWrite("Please create " & $g_sIni & " (see config.example.ini)" & @CRLF)
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

; _CCTelegram_SetDebug(True)

; --- init ----------------------------------------------------------------------------------------------------------------
_Check(_CCTelegram_Init($g_sToken, True), "init with validation")
Global $oMe = _CCTelegram_GetMe()
_Check(_CCTelegram_Get($oMe, "is_bot") = True, "getMe: is_bot (@" & _CCTelegram_Get($oMe, "username") & ")")

; --- text --------------------------------------------------------------------------------------------------------------
Global $sSpecial = "Sonderzeichen & # + % ?=; äöü ß € " & ChrW(0xD83E) & ChrW(0xDD16) & @CRLF & "zweite Zeile"
Global $oMsg = _CCTelegram_SendMessage($g_vChat, $sSpecial)
_Check(Not @error And StringReplace(_CCTelegram_Get($oMsg, "text"), @CR, "") == StringReplace($sSpecial, @CR, ""), "sendMessage keeps all special characters")
Global $iMsg = _CCTelegram_Get($oMsg, "message_id")

$oMsg = _CCTelegram_SendMessage($g_vChat, "<b>fett</b> " & _CCTelegram_EscapeHtml("<&>"), _CCTelegram_Obj("parse_mode", "HTML", "disable_notification", True))
_Check(Not @error And UBound(_CCTelegram_Get($oMsg, "entities")) = 1, "sendMessage with HTML entity")

$oMsg = _CCTelegram_SendMessage($g_vChat, _CCTelegram_EscapeMarkdownV2("Version 1.0 (Test) - ok!"), '{"parse_mode":"MarkdownV2"}')
_Check(Not @error, "options as JSON string + MarkdownV2 escaping")

; --- inline keyboard, edit, delete ---------------------------------------------------------------------------------------
Global $aKb[2][2]
$aKb[0][0] = _CCTelegram_InlineButton("Ja", "yes")
$aKb[0][1] = _CCTelegram_InlineButton("Nein", "no")
$aKb[1][0] = _CCTelegram_UrlButton("Telegram", "https://telegram.org")
$oMsg = _CCTelegram_SendMessage($g_vChat, "Inline keyboard", _CCTelegram_Obj("reply_markup", _CCTelegram_InlineKeyboard($aKb)))
_Check(Not @error And IsObj(_CCTelegram_Get($oMsg, "reply_markup")), "sendMessage with inline keyboard")
Global $iKbMsg = _CCTelegram_Get($oMsg, "message_id")
$oMsg = _CCTelegram_EditMessageText($g_vChat, $iKbMsg, _CCTelegram_Obj("text", "Inline keyboard (edited)"))
_Check(Not @error And _CCTelegram_Get($oMsg, "text") = "Inline keyboard (edited)", "editMessageText")
_Check(_CCTelegram_DeleteMessage($g_vChat, $iKbMsg) = True, "deleteMessage")

$oMsg = _CCTelegram_SendMessage($g_vChat, "Reply keyboard", _CCTelegram_Obj("reply_markup", '{"keyboard":[["A","B"],["C"]],"resize_keyboard":true}'))
_Check(Not @error, "reply_markup as JSON string")
_CCTelegram_SendMessage($g_vChat, "Keyboard removed", _CCTelegram_Obj("reply_markup", _CCTelegram_ReplyKeyboardRemove()))
_Check(Not @error, "ReplyKeyboardRemove")

$oMsg = _CCTelegram_SendMessage($g_vChat, "Antwort", _CCTelegram_Obj("reply_parameters", _CCTelegram_Obj("message_id", $iMsg)))
_Check(Not @error And _CCTelegram_Get($oMsg, "reply_to_message.message_id") = $iMsg, "reply_parameters")

; --- files -----------------------------------------------------------------------------------------------------------------
Global $sMedia = @ScriptDir & "\media\"
$oMsg = _CCTelegram_SendPhoto($g_vChat, $sMedia & "image1.png", _CCTelegram_Obj("caption", "Upload äöü & #1"))
_Check(Not @error And UBound(_CCTelegram_Get($oMsg, "photo")) > 0, "sendPhoto (local file, multipart)")
Global $aPhotos = _CCTelegram_Get($oMsg, "photo")
Global $sPhotoId = _CCTelegram_Get($aPhotos[UBound($aPhotos) - 1], "file_id")
$oMsg = _CCTelegram_SendPhoto($g_vChat, $sPhotoId, _CCTelegram_Obj("caption", "same photo via file_id"))
_Check(Not @error, "sendPhoto (file_id)")

$oMsg = _CCTelegram_SendDocument($g_vChat, $sMedia & "document.txt", _CCTelegram_Obj("caption", "Dokument"))
_Check(Not @error, "sendDocument")
Global $sDocId = _CCTelegram_Get($oMsg, "document.file_id")
Global $sDl = _CCTelegram_DownloadFile($sDocId, @TempDir & "\CCTelegramUDFTest\")
_Check(Not @error And FileRead($sDl) == FileRead($sMedia & "document.txt"), "downloadFile returns identical content")
DirRemove(@TempDir & "\CCTelegramUDFTest", 1)

Global $aGroup[3] = [_CCTelegram_InputMedia("photo", $sMedia & "image1.png", _CCTelegram_Obj("caption", "Album")), _
        _CCTelegram_InputMedia("photo", $sMedia & "image2.png"), _CCTelegram_InputMedia("photo", $sPhotoId)]
Global $aRes = _CCTelegram_SendMediaGroup($g_vChat, $aGroup)
_Check(Not @error And UBound($aRes) = 3, "sendMediaGroup (2 uploads + 1 file_id)")

_Check(_CCTelegram_SendChatAction($g_vChat, "typing") = True, "sendChatAction")

; --- generic call, polling ---------------------------------------------------------------------------------------------
Global $oChat = _CCTelegram_Call("getChat", _CCTelegram_Obj("chat_id", $g_vChat))
_Check(Not @error And _CCTelegram_Get($oChat, "id") <> "", "_CCTelegram_Call(getChat)")
Global $aUpd = _CCTelegram_Poll(0)
_Check(Not @error And IsArray($aUpd), "poll (short), " & UBound($aUpd) & " update(s)")

; --- errors --------------------------------------------------------------------------------------------------------------
_CCTelegram_SendMessage(1, "invalid chat")
_Check(@error = $CCTELEGRAM_ERR_API And _CCTelegram_LastErrorCode() = 400 And _CCTelegram_LastErrorDescription() <> "", "API error is reported (" & _CCTelegram_LastErrorDescription() & ")")
_CCTelegram_SetProxy("127.0.0.1:9")
_CCTelegram_SetTimeouts(Default, 3000)
_CCTelegram_GetMe()
_Check(@error = $CCTELEGRAM_ERR_TRANSPORT, "network error does not crash (" & _CCTelegram_LastErrorDescription() & ")")
_CCTelegram_SetProxy()
_Check(IsObj(_CCTelegram_GetMe()), "works again after the network error")

ConsoleWrite(@CRLF & "Passed: " & $g_iPassed & "   Failed: " & $g_iFailed & @CRLF)
Exit $g_iFailed ? 1 : 0
