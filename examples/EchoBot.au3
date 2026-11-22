; SPDX-License-Identifier: GPL-3.0-or-later
; CCTelegramUDF - example bot
;   /start     greeting + reply keyboard
;   /menu      inline keyboard (button clicks are answered)
;   /md        MarkdownV2 example
;   documents  are downloaded into the folder "downloads"
;   any text   is echoed back
; Put the token into examples\bot.ini:  [Telegram]  Token=123456:ABC...
#AutoIt3Wrapper_Run_AU3Check=Y
Opt("MustDeclareVars", 1)

#include "..\CCTelegramUDF.au3"

Global Const $g_sToken = IniRead(@ScriptDir & "\bot.ini", "Telegram", "Token", "")
If Not _CCTelegram_Init($g_sToken, True) Then
    MsgBox(16, "EchoBot", "Token missing or rejected: " & _CCTelegram_LastErrorDescription())
    Exit 1
EndIf
ConsoleWrite("Bot @" & _CCTelegram_Get(_CCTelegram_GetMe(), "username") & " is running - stop with Ctrl+Break / closing SciTE output" & @CRLF)

; continue where the last run stopped (updates already handled are not delivered twice)
_CCTelegram_SetOffset(Int(IniRead(@ScriptDir & "\bot.ini", "State", "Offset", 0)))

; register the commands so Telegram shows them in the "/" menu
Global $aCommands[3] = [_CCTelegram_Obj("command", "start", "description", "Begrüßung"), _
        _CCTelegram_Obj("command", "menu", "description", "Inline-Menü"), _
        _CCTelegram_Obj("command", "md", "description", "MarkdownV2-Beispiel")]
_CCTelegram_SetMyCommands($aCommands)

Global $aUpdates, $oUpdate
While 1
    $aUpdates = _CCTelegram_Poll(30, "message,callback_query")
    If @error Then
        ConsoleWrite("Poll error: " & _CCTelegram_LastErrorDescription() & " - retry in 5 s" & @CRLF)
        Sleep(5000)
        ContinueLoop
    EndIf
    For $i = 0 To UBound($aUpdates) - 1
        $oUpdate = $aUpdates[$i]
        Switch _CCTelegram_UpdateType($oUpdate)
            Case "message"
                _OnMessage(_CCTelegram_Get($oUpdate, "message"))
            Case "callback_query"
                _OnCallback(_CCTelegram_Get($oUpdate, "callback_query"))
        EndSwitch
    Next
    If UBound($aUpdates) > 0 Then IniWrite(@ScriptDir & "\bot.ini", "State", "Offset", _CCTelegram_GetOffset())
WEnd

Func _OnMessage($oMsg)
    Local $iChat = _CCTelegram_Get($oMsg, "chat.id")
    Local $sText = _CCTelegram_Get($oMsg, "text", "")
    Local $sName = _CCTelegram_Get($oMsg, "from.first_name", "")
    ConsoleWrite("[" & $iChat & "] " & $sName & ": " & $sText & @CRLF)

    If _CCTelegram_Get($oMsg, "document.file_id", "") <> "" Then
        _CCTelegram_SendChatAction($iChat, "upload_document")
        Local $sFile = _CCTelegram_DownloadFile(_CCTelegram_Get($oMsg, "document.file_id"), @ScriptDir & "\downloads\")
        If @error Then
            _CCTelegram_SendMessage($iChat, "Download fehlgeschlagen: " & _CCTelegram_LastErrorDescription())
        Else
            _CCTelegram_SendMessage($iChat, "Gespeichert: " & $sFile)
        EndIf
        Return
    EndIf

    Switch StringRegExpReplace($sText, "@\S+$", "") ; /menu@MyBot -> /menu
        Case "/start"
            Local $aKb[5] = ["/menu", "/md", "", "Hallo", "Tschüss"]
            _CCTelegram_SendMessage($iChat, "Hallo " & $sName & "! Schreib mir etwas, ich antworte als Echo.", _
                    _CCTelegram_Obj("reply_markup", _CCTelegram_ReplyKeyboard($aKb)))
        Case "/menu"
            Local $aInline[2][2]
            $aInline[0][0] = _CCTelegram_InlineButton("👍 Gut", "good")
            $aInline[0][1] = _CCTelegram_InlineButton("👎 Schlecht", "bad")
            $aInline[1][0] = _CCTelegram_UrlButton("Bot API", "https://core.telegram.org/bots/api")
            _CCTelegram_SendMessage($iChat, "Wie gefällt dir die UDF?", _CCTelegram_Obj("reply_markup", _CCTelegram_InlineKeyboard($aInline)))
        Case "/md"
            _CCTelegram_SendMessage($iChat, "*Fett*, _kursiv_ und " & _CCTelegram_EscapeMarkdownV2("Sonderzeichen: 1+1=2 (sicher)!"), _
                    _CCTelegram_Obj("parse_mode", "MarkdownV2"))
        Case ""
            _CCTelegram_SendMessage($iChat, "Das kann ich (noch) nicht als Echo zurückschicken.")
        Case Else
            _CCTelegram_SendMessage($iChat, $sText, _CCTelegram_Obj("reply_parameters", _CCTelegram_Obj("message_id", _CCTelegram_Get($oMsg, "message_id"))))
    EndSwitch
EndFunc   ;==>_OnMessage

Func _OnCallback($oCb)
    Local $sData = _CCTelegram_Get($oCb, "data", "")
    ; every callback query must be answered, otherwise the button keeps spinning
    _CCTelegram_AnswerCallbackQuery(_CCTelegram_Get($oCb, "id"), _CCTelegram_Obj("text", $sData = "good" ? "Danke! 😊" : "Schade - was fehlt?"))
    _CCTelegram_EditMessageText(_CCTelegram_Get($oCb, "message.chat.id"), _CCTelegram_Get($oCb, "message.message_id"), _
            _CCTelegram_Obj("text", "Deine Antwort: " & $sData))
EndFunc   ;==>_OnCallback
