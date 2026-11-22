#include-once
; SPDX-License-Identifier: GPL-3.0-or-later
#cs ===========================================================================================================================
    CCTelegramUDF - compatibility layer for xLinkOut/telegram-udf-autoit release v0.1 (_InitBot, _SendMsg, _Polling, ...)

    Author .......: Markus Debus, CITRO Computer
    Version ......: 1.0.0
    License ......: GPL-3.0-or-later with an additional attribution term (GPLv3 section 7(b)), see LICENSE.txt and NOTICE.txt

    Purpose
        Drop-in replacement for the Telegram.au3 of release v0.1 of xLinkOut/telegram-udf-autoit. All public functions,
        global variables and constants of that version exist here with the same names, parameters and return values
        (message_id, file_id, True/False, the $msgData array of _Polling ...), but every call is executed by
        CCTelegramUDF.au3. This file is an independent re-implementation of that public interface; no code of the
        original was copied.
        For scripts written for the 2024 rewrite (_Telegram_* functions) use compat\Telegram2024.au3 instead.
        A script can use only ONE of the two compatibility files.

    Installation
        1. Copy CCTelegramUDF.au3, CCTelegramUDF_Methods.au3 and this Telegram.au3 into the folder of the old Telegram.au3
           (overwrite the old Telegram.au3).
        2. Keep the old include\JSON.au3 (+ BinaryCall.au3): old scripts use Json_Get() etc., and CCTelegramUDF returns the
           same object model. include\WinHttp.au3 and WinHttpConstants.au3 are no longer needed.

    Differences to the original (all of them fixes)
        - Texts are transmitted correctly (& # + % umlauts emoji). %XX sequences in texts that the old UDF put into the URL
          (e.g. $BOT_CRLF) are still decoded like before; set $TG_COMPAT_URLDECODE = False to send texts literally.
          Captions of media were sent as form fields by the old UDF and are therefore sent literally, as before.
        - _Polling: long polling (answers immediately), no crash on network errors, group join/leave events, supergroup
          edits and unknown update types (they are skipped instead of crashing the script).
        - Group arrays of _Polling have 11 elements, so [10] (first name of the joined/left member) exists. In the old
          UDF writing [10] crashed the script.
        - _SendVideo returns the file_id of the video (old: animation), _SendVideoNote the one of the video note
          (old: document), _SendAnimation and _SendMediaGroup return file_ids at all (old: nothing).
        - $ReplyToMessage works for media (old: ignored).
        - _EditMessageLiveLocation/_StopMessageLiveLocation work: they use the last live location sent with _SendLocation
          ($LivePeriod) to that chat (the old functions had no message_id parameter and always failed).
        - _getChatMember/_setChatStickerSet got the missing optional parameter ($UserID / $StickerSetName); the
          _getChat... functions still print the answer to the console and now also return the result.
        - _SendChatAction maps the old action names record_audio/upload_audio to record_voice/upload_voice.
        - Errors: @error = 2 when Telegram rejects a call, 4 ($INVALID_JSON_RESPONSE) for network/answer problems; the
          Telegram error text is available via _CCTelegram_LastErrorDescription().
#ce ===========================================================================================================================

#include <Array.au3>
#include <String.au3>
#include "CCTelegramUDF.au3"
#include "include/JSON.au3"

#Region "Globals and constants of the original UDF"

Global $TOKEN = ""
Global $URL = "https://api.telegram.org/bot"
Global $OFFSET = 0

Const $BOT_CRLF = "%0D%0A"
Const $INVALID_TOKEN_ERROR = 1
Const $FILE_NOT_DOWNLOADED = 2
Const $OFFSET_GRATER_THAN_TOTAL = 3
Const $INVALID_JSON_RESPONSE = 4

; Compatibility switch: decode %XX sequences in texts like the old UDF effectively did (the server decoded its URL)
Global $TG_COMPAT_URLDECODE = True

; last live location (message_id) per chat, for _EditMessageLiveLocation/_StopMessageLiveLocation
Global $__g_oCCTelegramV01_LiveLocation = ObjCreate("Scripting.Dictionary")

#EndRegion "Globals and constants of the original UDF"

#Region "Endpoint functions"

; Returns the raw JSON answer of getUpdates (from $OFFSET) as string; 0 and @error on failure.
Func _GetUpdates()
    _CCTelegram_Call("getUpdates", _CCTelegram_Obj("offset", $OFFSET))
    If @error Then Return SetError(3, 0, 0)
    Return _CCTelegram_LastResponse()
EndFunc   ;==>_GetUpdates

; Returns [id, username, first_name] of the bot.
Func _GetMe()
    Local $oMe = _CCTelegram_GetMe()
    If @error Then Return __CCTelegramV01_Fail(@error)
    Local $aData[3] = [_CCTelegram_Get($oMe, "id", ""), _CCTelegram_Get($oMe, "username", ""), _CCTelegram_Get($oMe, "first_name", "")]
    Return $aData
EndFunc   ;==>_GetMe

; Returns the message_id, False on failure.
Func _SendMsg($ChatID, $Text, $ParseMode = Default, $ReplyMarkup = Default, $ReplyToMessage = '', $DisableWebPreview = False, $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, True)
    __CCTelegram_DictSet($oP, "text", __CCTelegramV01_Text($Text))
    __CCTelegramV01_ParseMode($oP, $ParseMode)
    If $DisableWebPreview = True Then __CCTelegram_DictSet($oP, "link_preview_options", _CCTelegram_Obj("is_disabled", True))
    Local $oMsg = _CCTelegram_Call("sendMessage", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return _CCTelegram_Get($oMsg, "message_id", "")
EndFunc   ;==>_SendMsg

; Returns the new message_id, False on failure.
Func _ForwardMessage($ChatID, $OriginalChatID, $MsgID, $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, Default, '', $DisableNotification, True)
    __CCTelegram_DictSet($oP, "from_chat_id", $OriginalChatID)
    __CCTelegram_DictSet($oP, "message_id", $MsgID)
    Local $oMsg = _CCTelegram_Call("forwardMessage", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return _CCTelegram_Get($oMsg, "message_id", "")
EndFunc   ;==>_ForwardMessage

; Media: $Photo etc. = local path, file_id or HTTP URL. Return the file_id, False on failure.
Func _SendPhoto($ChatID, $Photo, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendPhoto", "photo", $ChatID, $Photo, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendPhoto

Func _SendAudio($ChatID, $Audio, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendAudio", "audio", $ChatID, $Audio, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendAudio

Func _SendDocument($ChatID, $Document, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendDocument", "document", $ChatID, $Document, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendDocument

Func _SendVideo($ChatID, $Video, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendVideo", "video", $ChatID, $Video, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendVideo

Func _SendAnimation($ChatID, $Animation, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendAnimation", "animation", $ChatID, $Animation, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendAnimation

Func _SendVoice($ChatID, $Path, $Caption = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendVoice", "voice", $ChatID, $Path, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendVoice

Func _SendVideoNote($ChatID, $VideoNote, $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendVideoNote", "video_note", $ChatID, $VideoNote, '', $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendVideoNote

Func _SendSticker($ChatID, $Path, $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Return __CCTelegramV01_SendMedia("sendSticker", "sticker", $ChatID, $Path, '', $ReplyMarkup, $ReplyToMessage, $DisableNotification)
EndFunc   ;==>_SendSticker

; $Media: JSON array of InputMedia objects as in the Bot API (as before), or an AutoIt array of local paths / file_ids /
; URLs. Local paths inside the JSON ("media":"C:\\...") are uploaded. Returns an array with the file_ids of the sent media.
Func _SendMediaGroup($ChatID, $Media, $ReplyToMessage = '', $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, Default, $ReplyToMessage, $DisableNotification, False)
    Local $aGroup
    If IsArray($Media) Then
        Local $aTmp[UBound($Media)]
        For $i = 0 To UBound($Media) - 1
            $aTmp[$i] = _CCTelegram_InputMedia(__CCTelegramV01_MediaType($Media[$i]), $Media[$i])
            If @error Then Return SetError($INVALID_JSON_RESPONSE, 0, False)
        Next
        $aGroup = $aTmp
    Else
        $aGroup = _CCTelegram_JsonDecode($Media)
        If @error Or Not IsArray($aGroup) Then Return SetError($INVALID_JSON_RESPONSE, 0, False)
        Local $vItem
        For $i = 0 To UBound($aGroup) - 1
            $vItem = $aGroup[$i]
            If __CCTelegram_IsDict($vItem) Then
                If __CCTelegram_IsLocalFile(_CCTelegram_Get($vItem, "media", "")) Then __CCTelegram_DictSet($vItem, "media", _CCTelegram_File(_CCTelegram_Get($vItem, "media")))
                If __CCTelegram_IsLocalFile(_CCTelegram_Get($vItem, "thumbnail", "")) Then __CCTelegram_DictSet($vItem, "thumbnail", _CCTelegram_File(_CCTelegram_Get($vItem, "thumbnail")))
            EndIf
        Next
    EndIf
    __CCTelegram_DictSet($oP, "media", $aGroup)
    Local $aMsgs = _CCTelegram_Call("sendMediaGroup", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Local $aIds[UBound($aMsgs)]
    For $i = 0 To UBound($aMsgs) - 1
        $aIds[$i] = __CCTelegramV01_FileIdOfMessage($aMsgs[$i])
    Next
    Return $aIds
EndFunc   ;==>_SendMediaGroup

Func _SendLocation($ChatID, $Latitude, $Longitude, $LivePeriod = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, True)
    __CCTelegram_DictSet($oP, "latitude", Number($Latitude))
    __CCTelegram_DictSet($oP, "longitude", Number($Longitude))
    If Not __CCTelegramV01_Empty($LivePeriod) Then __CCTelegram_DictSet($oP, "live_period", Int($LivePeriod))
    Local $oMsg = _CCTelegram_Call("sendLocation", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    If Not __CCTelegramV01_Empty($LivePeriod) Then __CCTelegram_DictSet($__g_oCCTelegramV01_LiveLocation, String($ChatID), _CCTelegram_Get($oMsg, "message_id", 0))
    Return True
EndFunc   ;==>_SendLocation

; Edits the last live location sent with _SendLocation($ChatID, ..., $LivePeriod) to this chat.
Func _EditMessageLiveLocation($ChatID, $Latitude, $Longitude, $ReplyMarkup = Default)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, '', False, True)
    If Not __CCTelegramV01_LiveMessage($oP, $ChatID) Then Return SetError(2, 0, False)
    __CCTelegram_DictSet($oP, "latitude", Number($Latitude))
    __CCTelegram_DictSet($oP, "longitude", Number($Longitude))
    _CCTelegram_Call("editMessageLiveLocation", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_EditMessageLiveLocation

; Stops the last live location sent with _SendLocation($ChatID, ..., $LivePeriod) to this chat.
Func _StopMessageLiveLocation($ChatID, $ReplyMarkup = Default)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, '', False, True)
    If Not __CCTelegramV01_LiveMessage($oP, $ChatID) Then Return SetError(2, 0, False)
    _CCTelegram_Call("stopMessageLiveLocation", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    $__g_oCCTelegramV01_LiveLocation.Remove(String($ChatID))
    Return True
EndFunc   ;==>_StopMessageLiveLocation

; $Foursquare = foursquare_id
Func _SendVenue($ChatID, $Latitude, $Longitude, $Title, $Address, $Foursquare = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, True)
    __CCTelegram_DictSet($oP, "latitude", Number($Latitude))
    __CCTelegram_DictSet($oP, "longitude", Number($Longitude))
    __CCTelegram_DictSet($oP, "title", __CCTelegramV01_Text($Title))
    __CCTelegram_DictSet($oP, "address", __CCTelegramV01_Text($Address))
    If Not __CCTelegramV01_Empty($Foursquare) Then __CCTelegram_DictSet($oP, "foursquare_id", String($Foursquare))
    _CCTelegram_Call("sendVenue", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_SendVenue

Func _SendContact($ChatID, $Phone, $FirstName, $LastName = '', $ReplyMarkup = Default, $ReplyToMessage = '', $DisableNotification = False)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, True)
    __CCTelegram_DictSet($oP, "phone_number", __CCTelegramV01_Text($Phone))
    __CCTelegram_DictSet($oP, "first_name", __CCTelegramV01_Text($FirstName))
    If Not __CCTelegramV01_Empty($LastName) Then __CCTelegram_DictSet($oP, "last_name", __CCTelegramV01_Text($LastName))
    _CCTelegram_Call("sendContact", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_SendContact

Func _SendChatAction($ChatID, $Action)
    Local $sAction = StringLower(String($Action))
    If $sAction = "record_audio" Then $sAction = "record_voice"
    If $sAction = "upload_audio" Then $sAction = "upload_voice"
    _CCTelegram_Call("sendChatAction", _CCTelegram_Obj("chat_id", $ChatID, "action", $sAction))
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_SendChatAction

; Returns [count, file_id 1, file_id 2, ...] (largest size of each profile photo).
Func _GetUserProfilePhotos($ChatID, $Offset = '', $Limit = '')
    Local $oP = _CCTelegram_Obj("user_id", $ChatID)
    If Not __CCTelegramV01_Empty($Offset) Then __CCTelegram_DictSet($oP, "offset", Int($Offset))
    If Not __CCTelegramV01_Empty($Limit) Then __CCTelegram_DictSet($oP, "limit", Int($Limit))
    Local $oRes = _CCTelegram_Call("getUserProfilePhotos", $oP)
    If @error Then Return SetError(2, 0, False)
    Local $iTotal = _CCTelegram_Get($oRes, "total_count", 0)
    If Not __CCTelegramV01_Empty($Offset) And Int($Offset) >= $iTotal Then Return SetError($OFFSET_GRATER_THAN_TOTAL, 0, False)
    Local $aPhotos = _CCTelegram_Get($oRes, "photos", "")
    If Not IsArray($aPhotos) Then Return SetError(2, 0, False)
    Local $aRes[UBound($aPhotos) + 1], $aSizes
    $aRes[0] = UBound($aPhotos)
    For $i = 0 To UBound($aPhotos) - 1
        $aSizes = $aPhotos[$i]
        If IsArray($aSizes) And UBound($aSizes) > 0 Then $aRes[$i + 1] = _CCTelegram_Get($aSizes[UBound($aSizes) - 1], "file_id", "")
    Next
    Return $aRes
EndFunc   ;==>_GetUserProfilePhotos

; kickChatMember is called banChatMember today
Func _KickChatMember($ChatID, $UserID, $UntilDate = '')
    Local $oP = _CCTelegram_Obj("chat_id", $ChatID, "user_id", $UserID)
    If Not __CCTelegramV01_Empty($UntilDate) Then __CCTelegram_DictSet($oP, "until_date", Int($UntilDate))
    _CCTelegram_Call("banChatMember", $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_KickChatMember

Func _UnbanChatMember($ChatID, $UserID)
    _CCTelegram_Call("unbanChatMember", _CCTelegram_Obj("chat_id", $ChatID, "user_id", $UserID, "only_if_banned", True))
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>_UnbanChatMember

; Returns the invite link as string.
Func _ExportChatInviteLink($ChatID)
    Local $sLink = _CCTelegram_Call("exportChatInviteLink", _CCTelegram_Obj("chat_id", $ChatID))
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return $sLink
EndFunc   ;==>_ExportChatInviteLink

Func _SetChatPhoto($ChatID, $Path)
    Return __CCTelegramV01_Simple("setChatPhoto", _CCTelegram_Obj("chat_id", $ChatID, "photo", $Path))
EndFunc   ;==>_SetChatPhoto

Func _DeleteChatPhoto($ChatID)
    Return __CCTelegramV01_Simple("deleteChatPhoto", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_DeleteChatPhoto

Func _SetChatTitle($ChatID, $Title)
    Return __CCTelegramV01_Simple("setChatTitle", _CCTelegram_Obj("chat_id", $ChatID, "title", __CCTelegramV01_Text($Title)))
EndFunc   ;==>_SetChatTitle

Func _SetChatDescription($ChatID, $Description)
    Return __CCTelegramV01_Simple("setChatDescription", _CCTelegram_Obj("chat_id", $ChatID, "description", __CCTelegramV01_Text($Description)))
EndFunc   ;==>_SetChatDescription

Func _PinChatMessage($ChatID, $MsgID, $DisableNotification = False)
    Local $oP = _CCTelegram_Obj("chat_id", $ChatID, "message_id", $MsgID)
    If $DisableNotification = True Then __CCTelegram_DictSet($oP, "disable_notification", True)
    Return __CCTelegramV01_Simple("pinChatMessage", $oP)
EndFunc   ;==>_PinChatMessage

; Unpins the most recent pinned message
Func _UnpinChatMessage($ChatID)
    Return __CCTelegramV01_Simple("unpinChatMessage", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_UnpinChatMessage

Func _LeaveChat($ChatID)
    Return __CCTelegramV01_Simple("leaveChat", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_LeaveChat

; Returns [id, username, first_name, big_file_id of the chat photo].
Func _GetChat($ChatID)
    Local $oChat = _CCTelegram_Call("getChat", _CCTelegram_Obj("chat_id", $ChatID))
    If @error Then Return __CCTelegramV01_Fail(@error)
    Local $aData[4] = [_CCTelegram_Get($oChat, "id", ""), _CCTelegram_Get($oChat, "username", ""), _
            _CCTelegram_Get($oChat, "first_name", ""), _CCTelegram_Get($oChat, "photo.big_file_id", "")]
    Return $aData
EndFunc   ;==>_GetChat

; The following functions printed the raw answer to the console in the old UDF. They still do and now also return the
; result (array/object/number/True), False on failure.
Func _getChatAdministrators($ChatID)
    Return __CCTelegramV01_Print("getChatAdministrators", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_getChatAdministrators

Func _getChatMembersCount($ChatID)
    Return __CCTelegramV01_Print("getChatMemberCount", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_getChatMembersCount

; $UserID is new (the old function could not work without it)
Func _getChatMember($ChatID, $UserID = Default)
    Return __CCTelegramV01_Print("getChatMember", _CCTelegram_Obj("chat_id", $ChatID, "user_id", $UserID))
EndFunc   ;==>_getChatMember

; $StickerSetName is new (the old function could not work without it)
Func _setChatStickerSet($ChatID, $StickerSetName = Default)
    Return __CCTelegramV01_Print("setChatStickerSet", _CCTelegram_Obj("chat_id", $ChatID, "sticker_set_name", $StickerSetName))
EndFunc   ;==>_setChatStickerSet

Func _deleteChatStickerSet($ChatID)
    Return __CCTelegramV01_Print("deleteChatStickerSet", _CCTelegram_Obj("chat_id", $ChatID))
EndFunc   ;==>_deleteChatStickerSet

Func _answerCallbackQuery($CallbackID, $Text = '', $cbURL = '', $ShowAlert = False, $CacheTime = '')
    Local $oP = _CCTelegram_Obj("callback_query_id", String($CallbackID))
    If Not __CCTelegramV01_Empty($Text) Then __CCTelegram_DictSet($oP, "text", __CCTelegramV01_Text($Text))
    If Not __CCTelegramV01_Empty($cbURL) Then __CCTelegram_DictSet($oP, "url", String($cbURL))
    If $ShowAlert = True Then __CCTelegram_DictSet($oP, "show_alert", True)
    If Not __CCTelegramV01_Empty($CacheTime) Then __CCTelegram_DictSet($oP, "cache_time", Int($CacheTime))
    Return __CCTelegramV01_Simple("answerCallbackQuery", $oP)
EndFunc   ;==>_answerCallbackQuery

Func _deleteMessage($ChatID, $MsgID)
    Return __CCTelegramV01_Print("deleteMessage", _CCTelegram_Obj("chat_id", $ChatID, "message_id", $MsgID))
EndFunc   ;==>_deleteMessage

#EndRegion "Endpoint functions"

#Region "Extra functions"

; Sets the token and checks it with getMe. True on success, False and @error = $INVALID_TOKEN_ERROR otherwise.
Func _InitBot($Token)
    $TOKEN = String($Token)
    $URL = "https://api.telegram.org/bot" & $TOKEN
    $OFFSET = 0
    If Not _CCTelegram_Init($TOKEN, True) Then Return SetError($INVALID_TOKEN_ERROR, 0, False)
    Return True
EndFunc   ;==>_InitBot

; Waits for the next update and returns it as $msgData array (layout see __MsgDecode). One update per call, like before.
; Network errors are retried every second instead of crashing; unknown update types are skipped.
Func _Polling()
    Local $aUpd, $iErr, $aData
    While 1
        _CCTelegram_SetOffset($OFFSET)
        $aUpd = _CCTelegram_Poll(25, Default, 1)
        $iErr = @error
        If $iErr Then
            Sleep(1000)
            ContinueLoop
        EndIf
        If UBound($aUpd) = 0 Then ContinueLoop
        $OFFSET = _CCTelegram_Get($aUpd[0], "update_id", $OFFSET - 1) + 1
        $aData = __CCTelegramV01_Decode($aUpd[0])
        If IsArray($aData) Then Return $aData
    WEnd
EndFunc   ;==>_Polling

; $Keyboard: e.g. Local $Keyboard[4] = ['Top Left','Top Right','','Second Row'] ("" = new row). Returns JSON.
Func _CreateKeyboard(ByRef $Keyboard, $Resize = False, $OneTime = False)
    Local $oKb = _CCTelegram_ReplyKeyboard($Keyboard, ($Resize = True), ($OneTime = True))
    If @error Then Return SetError($INVALID_JSON_RESPONSE, 0, "")
    Return _CCTelegram_JsonEncode($oKb)
EndFunc   ;==>_CreateKeyboard

; $Keyboard: e.g. Local $InlineKeyboard[5] = ['Button1_Text','Button1_Data','','Button2_Text','Button2_Data']
; (text/data pairs, "" = new row). Returns JSON.
Func _CreateInlineKeyboard(ByRef $Keyboard)
    If Not IsArray($Keyboard) Then Return SetError($INVALID_JSON_RESPONSE, 0, "")
    Local $aFlat[UBound($Keyboard) + 1], $iN = 0, $vText = Default
    For $i = 0 To UBound($Keyboard) - 1
        If IsString($Keyboard[$i]) And $Keyboard[$i] = "" Then
            __CCTelegram_ArrayPush($aFlat, $iN, "")
            $vText = Default
        ElseIf IsKeyword($vText) Then
            $vText = String($Keyboard[$i])
        Else
            __CCTelegram_ArrayPush($aFlat, $iN, _CCTelegram_InlineButton($vText, String($Keyboard[$i])))
            $vText = Default
        EndIf
    Next
    ReDim $aFlat[$iN]
    Local $oKb = _CCTelegram_InlineKeyboard($aFlat)
    If @error Then Return SetError($INVALID_JSON_RESPONSE, 0, "")
    Return _CCTelegram_JsonEncode($oKb)
EndFunc   ;==>_CreateInlineKeyboard

#EndRegion "Extra functions"

#Region "Internal functions of the original (public names)"

; Returns the file_id from a sendXxx answer (decoded JSON of the whole answer, as in the old UDF).
Func __GetFileID(ByRef $Json, $type)
    Local $oMsg = _CCTelegram_Get($Json, "result", $Json)
    If IsArray($oMsg) Then ; media group
        Local $aIds[UBound($oMsg)]
        For $i = 0 To UBound($oMsg) - 1
            $aIds[$i] = __CCTelegramV01_FileIdOfMessage($oMsg[$i])
        Next
        Return $aIds
    EndIf
    If $type = "videonote" Then $type = "video_note"
    If $type = "photo" Then Return __CCTelegramV01_FileIdOfMessage($oMsg)
    Return _CCTelegram_Get($oMsg, $type & ".file_id", "")
EndFunc   ;==>__GetFileID

; Returns the path of a file on the Telegram server.
Func __GetFilePath($FileID)
    Local $oFile = _CCTelegram_Call("getFile", _CCTelegram_Obj("file_id", $FileID))
    If @error Then Return ""
    Return _CCTelegram_Get($oFile, "file_path", "")
EndFunc   ;==>__GetFilePath

; Downloads a file (path from __GetFilePath) into the working directory. Returns the file name, False on failure.
Func __DownloadFile($filePath)
    Local $sName = StringRegExpReplace(String($filePath), "^.*/", "")
    Local $iStatus = 0
    Local $bData = __CCTelegram_Http("GET", "https://api.telegram.org/file/bot" & $TOKEN & "/" & $filePath, Binary(""), "", 300000, $iStatus)
    If @error Or $iStatus <> 200 Then Return SetError($FILE_NOT_DOWNLOADED, 0, False)
    Local $hFile = FileOpen($sName, 2 + 16)
    If $hFile = -1 Then Return SetError($FILE_NOT_DOWNLOADED, 0, False)
    FileWrite($hFile, $bData)
    FileClose($hFile)
    Return $sName
EndFunc   ;==>__DownloadFile

; URL-encodes a string (now correct UTF-8 / RFC 3986).
Func __UrlEncode($string)
    Return _CCTelegram_UrlEncode($string)
EndFunc   ;==>__UrlEncode

; Decodes the first update of a getUpdates answer (JSON string) into the $msgData array.
;   private message / edited private or group message:
;       [0] update_id, [1] message_id, [2] user id, [3] username, [4] first name, [5] text
;   group/supergroup message (11 elements):
;       [0] update_id, [1] message_id, [2] user id, [3] username, [4] first name, [5] group id, [6] group name,
;       [7] text, or "left"/"new" with [8] id, [9] username, [10] first name of that member
;   callback query:  [0] update_id, [1] callback id, [2] user id, [3] username, [4] first name, [5] callback data
;   inline query:    [0] update_id, [1] inline query id, [2] user id, [3] username, [4] first name, [5] query
;   channel post / edited channel post (5 elements):
;       [0] update_id, [1] message_id, [2] chat id, [3] channel title, [4] text
; Returns "" for other update types.
Func __MsgDecode($Update)
    Local $oJson = _CCTelegram_JsonDecode($Update)
    If @error Then Return SetError($INVALID_JSON_RESPONSE, 0, "")
    Local $aRes = _CCTelegram_Get($oJson, "result", "")
    If Not IsArray($aRes) Or UBound($aRes) = 0 Then Return ""
    Return __CCTelegramV01_Decode($aRes[0])
EndFunc   ;==>__MsgDecode

; Raw GET/POST like the old UDF. For Bot API URLs ($URL & "/method?query") the call goes through CCTelegramUDF
; (query values are URL-decoded); other URLs are fetched directly. Returns the answer text, 0 and @error on failure.
Func __HttpGet($sURL, $sData = '')
    Return __CCTelegramV01_Raw("GET", $sURL, $sData)
EndFunc   ;==>__HttpGet

Func __HttpPost($sURL, $sData = '')
    Return __CCTelegramV01_Raw("POST", $sURL, $sData)
EndFunc   ;==>__HttpPost

#EndRegion "Internal functions of the original (public names)"

#Region "Helpers of the compatibility layer"

Func __CCTelegramV01_Empty($vValue)
    If IsKeyword($vValue) Then Return True
    If IsString($vValue) Then Return $vValue = ""
    If IsBool($vValue) Then Return Not $vValue
    Return False
EndFunc   ;==>__CCTelegramV01_Empty

Func __CCTelegramV01_Text($sText)
    If $TG_COMPAT_URLDECODE Then Return _CCTelegram_UrlDecode(String($sText))
    Return String($sText)
EndFunc   ;==>__CCTelegramV01_Text

Func __CCTelegramV01_ParseMode(ByRef $oP, $sParseMode)
    If IsKeyword($sParseMode) Or Not IsString($sParseMode) Then Return
    Switch StringLower($sParseMode)
        Case "markdown"
            __CCTelegram_DictSet($oP, "parse_mode", "Markdown")
        Case "markdownv2"
            __CCTelegram_DictSet($oP, "parse_mode", "MarkdownV2")
        Case "html"
            __CCTelegram_DictSet($oP, "parse_mode", "HTML")
    EndSwitch
EndFunc   ;==>__CCTelegramV01_ParseMode

; chat_id, reply_markup, reply_to_message_id -> reply_parameters, disable_notification.
; $bInUrl: the old UDF sent this call as URL query (reply_markup was URL-decoded by the server)
Func __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, $bInUrl)
    Local $oP = _CCTelegram_Obj("chat_id", $ChatID)
    If IsObj($ReplyMarkup) Then
        __CCTelegram_DictSet($oP, "reply_markup", $ReplyMarkup)
    ElseIf Not __CCTelegramV01_Empty($ReplyMarkup) Then
        __CCTelegram_DictSet($oP, "reply_markup", $bInUrl ? __CCTelegramV01_Text($ReplyMarkup) : String($ReplyMarkup))
    EndIf
    If Not __CCTelegramV01_Empty($ReplyToMessage) And $ReplyToMessage <> 0 Then
        __CCTelegram_DictSet($oP, "reply_parameters", _CCTelegram_Obj("message_id", Int($ReplyToMessage), "allow_sending_without_reply", True))
    EndIf
    If $DisableNotification = True Then __CCTelegram_DictSet($oP, "disable_notification", True)
    Return $oP
EndFunc   ;==>__CCTelegramV01_Common

Func __CCTelegramV01_SendMedia($sMethod, $sField, $ChatID, $vMedia, $Caption, $ReplyMarkup, $ReplyToMessage, $DisableNotification)
    Local $oP = __CCTelegramV01_Common($ChatID, $ReplyMarkup, $ReplyToMessage, $DisableNotification, False)
    __CCTelegram_DictSet($oP, $sField, $vMedia)
    If Not __CCTelegramV01_Empty($Caption) Then __CCTelegram_DictSet($oP, "caption", String($Caption))
    Local $oMsg = _CCTelegram_Call($sMethod, $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return __CCTelegramV01_FileIdOfMessage($oMsg)
EndFunc   ;==>__CCTelegramV01_SendMedia

; file_id of the media in a Message (largest size for photos)
Func __CCTelegramV01_FileIdOfMessage($oMsg)
    Local $aPhoto = _CCTelegram_Get($oMsg, "photo", "")
    If IsArray($aPhoto) And UBound($aPhoto) > 0 Then Return _CCTelegram_Get($aPhoto[UBound($aPhoto) - 1], "file_id", "")
    Local $aTypes[8] = ["video", "animation", "audio", "document", "voice", "video_note", "sticker", "live_photo"]
    Local $sId
    For $i = 0 To UBound($aTypes) - 1
        $sId = _CCTelegram_Get($oMsg, $aTypes[$i] & ".file_id", "")
        If $sId <> "" Then Return $sId
    Next
    Return ""
EndFunc   ;==>__CCTelegramV01_FileIdOfMessage

Func __CCTelegramV01_MediaType($vMedia)
    Switch StringLower(StringRegExpReplace(String($vMedia), "^.*\.", ""))
        Case "jpg", "jpeg", "png", "webp", "bmp"
            Return "photo"
        Case "mp4", "mov", "avi", "mkv", "webm", "m4v"
            Return "video"
        Case "mp3", "m4a", "flac", "wav", "ogg", "oga", "opus"
            Return "audio"
    EndSwitch
    Return "document"
EndFunc   ;==>__CCTelegramV01_MediaType

Func __CCTelegramV01_LiveMessage(ByRef $oP, $ChatID)
    If Not $__g_oCCTelegramV01_LiveLocation.Exists(String($ChatID)) Then Return False
    __CCTelegram_DictSet($oP, "message_id", $__g_oCCTelegramV01_LiveLocation.Item(String($ChatID)))
    Return True
EndFunc   ;==>__CCTelegramV01_LiveMessage

Func __CCTelegramV01_Simple($sMethod, $oP)
    _CCTelegram_Call($sMethod, $oP)
    If @error Then Return __CCTelegramV01_Fail(@error)
    Return True
EndFunc   ;==>__CCTelegramV01_Simple

Func __CCTelegramV01_Print($sMethod, $oP)
    Local $vRes = _CCTelegram_Call($sMethod, $oP), $iErr = @error
    ConsoleWrite(_CCTelegram_LastResponse())
    If $iErr Then Return __CCTelegramV01_Fail($iErr)
    Return $vRes
EndFunc   ;==>__CCTelegramV01_Print

Func __CCTelegramV01_Raw($sVerb, $sURL, $sData)
    Local $sUrlStr = String($sURL), $sQuery = String($sData)
    If StringLeft($sUrlStr, StringLen($URL) + 1) = $URL & "/" And $TOKEN <> "" Then
        Local $sRest = StringTrimLeft($sUrlStr, StringLen($URL) + 1)
        Local $iQ = StringInStr($sRest, "?", 1)
        Local $sMethod = $iQ ? StringLeft($sRest, $iQ - 1) : $sRest
        If $iQ Then $sQuery = StringTrimLeft($sRest, $iQ) & ($sQuery = "" ? "" : "&" & $sQuery)
        Local $oP = ObjCreate("Scripting.Dictionary"), $aPairs = StringSplit($sQuery, "&", 2), $iEq
        For $i = 0 To UBound($aPairs) - 1
            If $aPairs[$i] = "" Then ContinueLoop
            $iEq = StringInStr($aPairs[$i], "=", 1)
            If $iEq = 0 Then
                __CCTelegram_DictSet($oP, _CCTelegram_UrlDecode($aPairs[$i]), "")
            Else
                __CCTelegram_DictSet($oP, _CCTelegram_UrlDecode(StringLeft($aPairs[$i], $iEq - 1)), _CCTelegram_UrlDecode(StringTrimLeft($aPairs[$i], $iEq)))
            EndIf
        Next
        _CCTelegram_Call($sMethod, $oP)
        If @error = $CCTELEGRAM_ERR_TRANSPORT Then Return SetError(2, 0, 0)
        If _CCTelegram_LastHttpStatus() <> 200 Then Return SetError(3, 0, 0)
        Return SetError(0, 0, _CCTelegram_LastResponse())
    EndIf
    ; any other URL
    Local $iStatus = 0, $sFull = $sUrlStr
    If $sVerb = "GET" And $sQuery <> "" Then $sFull &= (StringInStr($sFull, "?") ? "&" : "?") & $sQuery
    Local $bBody = ($sVerb = "POST") ? StringToBinary($sQuery, 4) : Binary("")
    Local $bRes = __CCTelegram_Http($sVerb, $sFull, $bBody, ($sVerb = "POST") ? "application/x-www-form-urlencoded" : "", 60000, $iStatus)
    If @error Then Return SetError(2, 0, 0)
    If $iStatus <> 200 Then Return SetError(3, 0, 0)
    Return SetError(0, 0, BinaryToString($bRes, 4))
EndFunc   ;==>__CCTelegramV01_Raw

; Update object -> $msgData array (layout see __MsgDecode), "" for unknown types
Func __CCTelegramV01_Decode($oUpd)
    Local $iUpd = _CCTelegram_Get($oUpd, "update_id", "")
    Local $sType = _CCTelegram_UpdateType($oUpd)
    Local $o = _CCTelegram_Get($oUpd, $sType, "")
    Local $sChatType = _CCTelegram_Get($o, "chat.type", "")

    Switch $sType
        Case "message"
            If $sChatType = "private" Then
                Local $aPriv[10] = [$iUpd, _CCTelegram_Get($o, "message_id", ""), _CCTelegram_Get($o, "from.id", ""), _
                        _CCTelegram_Get($o, "from.username", ""), _CCTelegram_Get($o, "from.first_name", ""), _CCTelegram_Get($o, "text", "")]
                Return $aPriv
            ElseIf $sChatType = "group" Or $sChatType = "supergroup" Then
                Local $aGrp[11] = [$iUpd, _CCTelegram_Get($o, "message_id", ""), _CCTelegram_Get($o, "from.id", ""), _
                        _CCTelegram_Get($o, "from.username", ""), _CCTelegram_Get($o, "from.first_name", ""), _
                        _CCTelegram_Get($o, "chat.id", ""), _CCTelegram_Get($o, "chat.title", "")]
                Local $oMember = _CCTelegram_Get($o, "left_chat_member", "")
                If IsObj($oMember) Then
                    $aGrp[7] = "left"
                Else
                    $oMember = _CCTelegram_Get($o, "new_chat_members[0]", _CCTelegram_Get($o, "new_chat_member", ""))
                    If IsObj($oMember) Then $aGrp[7] = "new"
                EndIf
                If IsObj($oMember) Then
                    $aGrp[8] = _CCTelegram_Get($oMember, "id", "")
                    $aGrp[9] = _CCTelegram_Get($oMember, "username", "")
                    $aGrp[10] = _CCTelegram_Get($oMember, "first_name", "")
                Else
                    $aGrp[7] = _CCTelegram_Get($o, "text", "")
                EndIf
                Return $aGrp
            EndIf
        Case "edited_message"
            If $sChatType = "private" Or $sChatType = "group" Or $sChatType = "supergroup" Then
                Local $aEdit[10] = [$iUpd, _CCTelegram_Get($o, "message_id", ""), _CCTelegram_Get($o, "from.id", ""), _
                        _CCTelegram_Get($o, "from.username", ""), _CCTelegram_Get($o, "from.first_name", ""), _CCTelegram_Get($o, "text", "")]
                Return $aEdit
            EndIf
        Case "callback_query", "inline_query"
            Local $aQuery[10] = [$iUpd, _CCTelegram_Get($o, "id", ""), _CCTelegram_Get($o, "from.id", ""), _
                    _CCTelegram_Get($o, "from.username", ""), _CCTelegram_Get($o, "from.first_name", ""), _
                    _CCTelegram_Get($o, ($sType = "callback_query") ? "data" : "query", "")]
            Return $aQuery
        Case "channel_post", "edited_channel_post"
            Local $aChan[5] = [$iUpd, _CCTelegram_Get($o, "message_id", ""), _CCTelegram_Get($o, "chat.id", ""), _
                    _CCTelegram_Get($o, "chat.title", ""), _CCTelegram_Get($o, "text", "")]
            Return $aChan
    EndSwitch
    Return ""
EndFunc   ;==>__CCTelegramV01_Decode

; Maps a CCTelegramUDF error to the old values: 2 = Telegram rejected the call, 4 = network/answer problem. Returns False.
Func __CCTelegramV01_Fail($iCCTelegramError)
    Switch $iCCTelegramError
        Case $CCTELEGRAM_ERR_API
            Return SetError(2, _CCTelegram_LastErrorCode(), False)
        Case $CCTELEGRAM_ERR_NOINIT
            Return SetError($INVALID_TOKEN_ERROR, 0, False)
    EndSwitch
    Return SetError($INVALID_JSON_RESPONSE, $iCCTelegramError, False)
EndFunc   ;==>__CCTelegramV01_Fail

#EndRegion "Helpers of the compatibility layer"
