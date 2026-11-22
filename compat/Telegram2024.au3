#include-once
; SPDX-License-Identifier: GPL-3.0-or-later
#cs ===========================================================================================================================
    CCTelegramUDF - compatibility layer for xLinkOut/telegram-udf-autoit, 2024 rewrite (_Telegram_* functions)

    Author .......: Markus Debus, CITRO Computer
    Version ......: 1.0.0
    License ......: GPL-3.0-or-later with an additional attribution term (GPLv3 section 7(b)), see LICENSE.txt and NOTICE.txt

    Purpose
        Replacement for the Telegram.au3 of the 2024 rewrite (master branch) of xLinkOut/telegram-udf-autoit.
        For scripts written for release v0.1 (_InitBot, _SendMsg, _Polling ...) use compat\Telegram.au3 instead.
        A script can use only ONE of the two compatibility files. All public functions, global variables
        and error constants of that UDF exist here with the same names, parameters and return values, but every call is
        executed by CCTelegramUDF.au3. Existing scripts keep working without changes and get the fixes of CCTelegramUDF for free.
        This file is an independent re-implementation of that public interface; no code of the original was copied.

    Installation
        1. Copy CCTelegramUDF.au3, CCTelegramUDF_Methods.au3 and this Telegram2024.au3 into the folder of the old
           Telegram.au3 and change #include "Telegram.au3" to #include "Telegram2024.au3" in your scripts
           (or rename this file to Telegram.au3 and overwrite the old one).
        2. Keep the old include\JSON.au3 (+ BinaryCall.au3) - scripts written for the old UDF use Json_Get() etc.
           CCTelegramUDF returns exactly the object model of that JSON UDF (Scripting.Dictionary + AutoIt arrays).
           include\WinHttp.au3, WinHttpConstants.au3 and Base64.au3 are no longer needed.

    Differences to the original (all of them fixes)
        - Texts, captions etc. are transmitted correctly (& # + % umlauts emoji). %XX sequences in texts (e.g. $BOT_CRLF)
          are still decoded like before; set $TG_COMPAT_URLDECODE = False to send texts literally.
        - _Telegram_SendAudio/-VideoNote/-MediaGroup pass their parameters correctly; media can be local files, URLs or
          file_ids; _Telegram_SendMediaGroup works with an array of paths/URLs/file_ids.
        - Network errors no longer crash the script; _Telegram_Polling waits $iSleep ms after an error and retries.
        - _Telegram_Polling uses long polling (answers immediately instead of once per second).
        - _Telegram_CreateKeyboard/-InlineKeyboard produce valid JSON for any text (quotes, backslashes, empty rows).
        - _Telegram_UrlEncode encodes correctly (UTF-8, RFC 3986).
        - Telegram error texts are available via _CCTelegram_LastErrorDescription() (new UDF).
#ce ===========================================================================================================================

#include "CCTelegramUDF.au3"
#include "include\JSON.au3"

#Region "Globals and constants of the original UDF"

Global $URL = ""
Global $TOKEN = ""
Global $OFFSET = 0

Const $BASE_URL = "https://api.telegram.org/bot"
Const $BOT_CRLF = "%0D%0A"

; Initialization errors
Const $TG_ERR_INIT = 1 ;@error
Const $TG_ERR_INIT_MISSING_TOKEN = 1 ;@extended
Const $TG_ERR_INIT_INVALID_TOKEN = 2 ;@extended

; Telegram API Call errors
Const $TG_ERR_API_CALL = 2 ;@error
Const $TG_ERR_API_CALL_OPEN = 1 ;@extended
Const $TG_ERR_API_CALL_SEND = 2 ;@extended
Const $TG_ERR_API_CALL_HTTP_NOT_SUCCESS = 3 ;@extended
Const $TG_ERR_API_CALL_NOT_DECODED = 4 ;@extended
Const $TG_ERR_API_CALL_INVALID_JSON = 5 ;@extended
Const $TG_ERR_API_CALL_NOT_SUCCESS = 6 ;@extended

; Missing or invalid input errors
Const $TG_ERR_BAD_INPUT = 3 ;@error

; Compatibility switch: decode %XX sequences in texts like the old UDF effectively did (the server decoded its URL)
Global $TG_COMPAT_URLDECODE = True

#EndRegion "Globals and constants of the original UDF"

#Region "Initialisation"

Func _Telegram_Init($sToken, $bValidate = False)
    If __CCTelegramCompat_Empty($sToken) Then Return SetError($TG_ERR_INIT, $TG_ERR_INIT_MISSING_TOKEN, False)
    $TOKEN = String($sToken)
    $URL = $BASE_URL & $TOKEN
    $OFFSET = 0
    _CCTelegram_Init($TOKEN, $bValidate)
    If @error Then
        If $bValidate Then Return SetError($TG_ERR_INIT, $TG_ERR_INIT_INVALID_TOKEN, False)
        Return SetError($TG_ERR_INIT, $TG_ERR_INIT_MISSING_TOKEN, False)
    EndIf
    Return True
EndFunc   ;==>_Telegram_Init

#EndRegion "Initialisation"

#Region "API implementation"

Func _Telegram_GetMe()
    Local $oRes = _CCTelegram_GetMe()
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_GetMe

Func _Telegram_GetUpdates($bUpdateOffset = True)
    Local $aRes = _CCTelegram_GetUpdates(_CCTelegram_Obj("offset", $OFFSET))
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    If $bUpdateOffset And IsArray($aRes) And UBound($aRes) > 0 Then
        $OFFSET = _CCTelegram_Get($aRes[UBound($aRes) - 1], "update_id", $OFFSET - 1) + 1
        _CCTelegram_SetOffset($OFFSET)
    EndIf
    Return $aRes
EndFunc   ;==>_Telegram_GetUpdates

Func _Telegram_LogOut()
    _CCTelegram_LogOut()
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return True
EndFunc   ;==>_Telegram_LogOut

Func _Telegram_Close()
    _CCTelegram_Close()
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return True
EndFunc   ;==>_Telegram_Close

Func _Telegram_SendMessage($sChatId, $sText, $sParseMode = Null, $sReplyMarkup = Null, $iReplyToMessage = Null, $bDisableWebPreview = False, $bDisableNotification = False)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sText) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    If Not __CCTelegramCompat_ParseModeOk($sParseMode) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oOpt = __CCTelegramCompat_CommonOpt($sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    If $bDisableWebPreview = True Then __CCTelegram_DictSet($oOpt, "link_preview_options", _CCTelegram_Obj("is_disabled", True))
    Local $oRes = _CCTelegram_SendMessage($sChatId, __CCTelegramCompat_Text($sText), $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_SendMessage

Func _Telegram_ForwardMessage($sChatId, $sFromChatId, $iMessageId, $bDisableNotification = False)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sFromChatId) Or __CCTelegramCompat_Empty($iMessageId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oOpt = __CCTelegramCompat_CommonOpt(Null, Null, Null, $bDisableNotification)
    Local $oRes = _CCTelegram_ForwardMessage($sChatId, $sFromChatId, $iMessageId, $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_ForwardMessage

Func _Telegram_SendPhoto($sChatId, $sPhoto, $sCaption = "", $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $sPhoto, "photo", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendPhoto

Func _Telegram_SendAudio($sChatId, $sAudio, $sCaption = '', $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $sAudio, "audio", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendAudio

Func _Telegram_SendDocument($sChatId, $Document, $sCaption = '', $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $Document, "document", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendDocument

Func _Telegram_SendVideo($sChatId, $Video, $sCaption = '', $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $Video, "video", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendVideo

Func _Telegram_SendAnimation($sChatId, $Animation, $sCaption = '', $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $Animation, "animation", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendAnimation

Func _Telegram_SendVoice($sChatId, $Path, $sCaption = '', $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $Path, "voice", $sCaption, $sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendVoice

; Video notes have no caption; $sParseMode is accepted for compatibility and ignored.
Func _Telegram_SendVideoNote($sChatId, $VideoNote, $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    #forceref $sParseMode
    Local $oRes = _Telegram_SendMedia($sChatId, $VideoNote, "video_note", "", "", $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendVideoNote

; $aMedias: array of local paths, URLs or file_ids (photos/videos, or only documents, or only audios).
; A single string is accepted as well. Returns the array of sent messages.
Func _Telegram_SendMediaGroup($sChatId, $aMedias, $bDisableNotification = False)
    Local $oRes = _Telegram_SendMedia($sChatId, $aMedias, "media_group", "", "", "", Null, $bDisableNotification)
    Return SetError(@error, @extended, $oRes)
EndFunc   ;==>_Telegram_SendMediaGroup

Func _Telegram_SendLocation($sChatId, $fLatitude, $fLongitude, $fHorizontalAccuracy = Null, $iLivePeriod = Null, $iProximityAlertRadius = Null, $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_EmptyCoord($fLatitude) Or __CCTelegramCompat_EmptyCoord($fLongitude) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oOpt = __CCTelegramCompat_CommonOpt(Null, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    If Not __CCTelegramCompat_Empty($fHorizontalAccuracy) Then __CCTelegram_DictSet($oOpt, "horizontal_accuracy", Number($fHorizontalAccuracy))
    If Not __CCTelegramCompat_Empty($iLivePeriod) Then __CCTelegram_DictSet($oOpt, "live_period", Int($iLivePeriod))
    If Not __CCTelegramCompat_Empty($iProximityAlertRadius) Then __CCTelegram_DictSet($oOpt, "proximity_alert_radius", Int($iProximityAlertRadius))
    Local $oRes = _CCTelegram_SendLocation($sChatId, Number($fLatitude), Number($fLongitude), $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_SendLocation

Func _Telegram_SendVenue($sChatId, $fLatitude, $fLongitude, $sTitle, $sAddress, $sFoursquareId = "", $sFoursquareType = "", $sGooglePlaceId = "", $sGooglePlaceType = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_EmptyCoord($fLatitude) Or __CCTelegramCompat_EmptyCoord($fLongitude) Or __CCTelegramCompat_Empty($sTitle) Or __CCTelegramCompat_Empty($sAddress) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oOpt = __CCTelegramCompat_CommonOpt(Null, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    If Not __CCTelegramCompat_Empty($sFoursquareId) Then __CCTelegram_DictSet($oOpt, "foursquare_id", String($sFoursquareId))
    If Not __CCTelegramCompat_Empty($sFoursquareType) Then __CCTelegram_DictSet($oOpt, "foursquare_type", String($sFoursquareType))
    If Not __CCTelegramCompat_Empty($sGooglePlaceId) Then __CCTelegram_DictSet($oOpt, "google_place_id", String($sGooglePlaceId))
    If Not __CCTelegramCompat_Empty($sGooglePlaceType) Then __CCTelegram_DictSet($oOpt, "google_place_type", String($sGooglePlaceType))
    Local $oRes = _CCTelegram_SendVenue($sChatId, Number($fLatitude), Number($fLongitude), __CCTelegramCompat_Text($sTitle), __CCTelegramCompat_Text($sAddress), $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_SendVenue

Func _Telegram_SendContact($sChatId, $sPhoneNumber, $sFirstName, $sLastName = "", $vCard = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sPhoneNumber) Or __CCTelegramCompat_Empty($sFirstName) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oOpt = __CCTelegramCompat_CommonOpt(Null, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    If Not __CCTelegramCompat_Empty($sLastName) Then __CCTelegram_DictSet($oOpt, "last_name", __CCTelegramCompat_Text($sLastName))
    If Not __CCTelegramCompat_Empty($vCard) Then __CCTelegram_DictSet($oOpt, "vcard", __CCTelegramCompat_Text($vCard))
    Local $oRes = _CCTelegram_SendContact($sChatId, String($sPhoneNumber), __CCTelegramCompat_Text($sFirstName), $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_SendContact

Func _Telegram_SendChatAction($sChatId, $sAction)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sAction) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    If Not StringRegExp($sAction, "^(typing|upload_photo|record_video|upload_video|record_voice|upload_voice|upload_document|choose_sticker|find_location|record_video_note|upload_video_note)$") Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $vRes = _CCTelegram_SendChatAction($sChatId, $sAction)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $vRes
EndFunc   ;==>_Telegram_SendChatAction

Func _Telegram_LeaveChat($sChatId)
    If __CCTelegramCompat_Empty($sChatId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $vRes = _CCTelegram_LeaveChat($sChatId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $vRes
EndFunc   ;==>_Telegram_LeaveChat

Func _Telegram_GetChat($sChatId)
    If __CCTelegramCompat_Empty($sChatId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oRes = _CCTelegram_GetChat($sChatId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_GetChat

Func _Telegram_GetChatAdministrators($sChatId)
    If __CCTelegramCompat_Empty($sChatId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $aRes = _CCTelegram_GetChatAdministrators($sChatId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $aRes
EndFunc   ;==>_Telegram_GetChatAdministrators

Func _Telegram_GetChatMemberCount($sChatId)
    If __CCTelegramCompat_Empty($sChatId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $iRes = _CCTelegram_GetChatMemberCount($sChatId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $iRes
EndFunc   ;==>_Telegram_GetChatMemberCount

Func _Telegram_GetChatMember($sChatId, $sUserId)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sUserId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oRes = _CCTelegram_GetChatMember($sChatId, $sUserId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $oRes
EndFunc   ;==>_Telegram_GetChatMember

Func _Telegram_DeleteMessage($sChatId, $iMessageId)
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($iMessageId) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $vRes = _CCTelegram_DeleteMessage($sChatId, $iMessageId)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $vRes
EndFunc   ;==>_Telegram_DeleteMessage

#EndRegion "API implementation"

#Region "Extra"

; Waits until at least one update arrives and returns the array of updates.
; Uses long polling; $iSleep is the pause after a network/API error before the next try.
Func _Telegram_Polling($iSleep = 1000)
    Local $aRes, $iErr
    While 1
        _CCTelegram_SetOffset($OFFSET)
        $aRes = _CCTelegram_Poll(25)
        $iErr = @error
        $OFFSET = _CCTelegram_GetOffset()
        If Not $iErr And UBound($aRes) > 0 Then Return $aRes
        If $iErr Then Sleep($iSleep)
    WEnd
EndFunc   ;==>_Telegram_Polling

; $Keyboard: e.g. Local $Keyboard[4] = ['Top Left','Top Right','','Second Row'] ("" = new row). Returns the markup as JSON.
Func _Telegram_CreateKeyboard(ByRef $Keyboard, $Resize = False, $OneTime = False)
    Local $oKb = _CCTelegram_ReplyKeyboard($Keyboard, ($Resize = True), ($OneTime = True))
    If @error Then Return SetError($TG_ERR_BAD_INPUT, 0, "")
    Return _CCTelegram_JsonEncode($oKb)
EndFunc   ;==>_Telegram_CreateKeyboard

; $Keyboard: e.g. Local $InlineKeyboard[5] = ['Button1_Text','Button1_Data','','Button2_Text','Button2_Data']
; (text/data pairs, "" = new row). Returns the markup as JSON.
Func _Telegram_CreateInlineKeyboard(ByRef $Keyboard)
    If Not IsArray($Keyboard) Then Return SetError($TG_ERR_BAD_INPUT, 0, "")
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
    If @error Then Return SetError($TG_ERR_BAD_INPUT, 0, "")
    Return _CCTelegram_JsonEncode($oKb)
EndFunc   ;==>_Telegram_CreateInlineKeyboard

#EndRegion "Extra"

#Region "Internal functions of the original (public names)"

; Returns the common parameters as URL query string (values are URL-encoded now).
Func _Telegram_BuildCommonParams($sChatId = Null, $sParseMode = Null, $sReplyMarkup = Null, $iReplyToMessage = Null, $bDisableNotification = Null, $bDisableWebPreview = Null)
    Local $sParams = ""
    If Not __CCTelegramCompat_Empty($sChatId) Then $sParams &= "&chat_id=" & _CCTelegram_UrlEncode($sChatId)
    If Not __CCTelegramCompat_Empty($sParseMode) Then $sParams &= "&parse_mode=" & _CCTelegram_UrlEncode($sParseMode)
    If Not __CCTelegramCompat_Empty($sReplyMarkup) Then $sParams &= "&reply_markup=" & _CCTelegram_UrlEncode($sReplyMarkup)
    If Not __CCTelegramCompat_Empty($iReplyToMessage) Then $sParams &= "&reply_to_message_id=" & _CCTelegram_UrlEncode($iReplyToMessage)
    If Not __CCTelegramCompat_Empty($bDisableNotification) Then $sParams &= "&disable_notification=" & _CCTelegram_UrlEncode($bDisableNotification)
    If Not __CCTelegramCompat_Empty($bDisableWebPreview) Then $sParams &= "&disable_web_page_preview=" & _CCTelegram_UrlEncode($bDisableWebPreview)
    Return StringTrimLeft($sParams, 1)
EndFunc   ;==>_Telegram_BuildCommonParams

Func _Telegram_UrlEncode($string)
    Return _CCTelegram_UrlEncode($string)
EndFunc   ;==>_Telegram_UrlEncode

; Generic call as in the original: $sPath = "/methodName", $sParams = URL query string ("a=1&b=2").
; $sURL and $sMethod are accepted for compatibility; the request always goes to the configured bot.
Func _Telegram_API_Call($sURL, $sPath = "", $sMethod = "GET", $sParams = "", $vBody = Null, $bValidate = True)
    #forceref $sURL, $sMethod, $bValidate
    Local $sApiMethod = StringRegExpReplace(String($sPath), "^[/\s]+|[\s]+$", "")
    If $sApiMethod = "" Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    Local $oP = ObjCreate("Scripting.Dictionary")
    __CCTelegramCompat_ParseQuery($oP, $sParams)
    If IsString($vBody) Then __CCTelegramCompat_ParseQuery($oP, $vBody)
    Local $vRes = _CCTelegram_Call($sApiMethod, $oP)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $vRes
EndFunc   ;==>_Telegram_API_Call

; $sMediaType: photo, audio, document, video, animation, voice, video_note, media_group
Func _Telegram_SendMedia($sChatId, $vMedia, $sMediaType, $sCaption = "", $sParseMode = "", $sReplyMarkup = "", $iReplyToMessage = Null, $bDisableNotification = False, $bValidate = True)
    #forceref $bValidate
    If __CCTelegramCompat_Empty($sChatId) Or __CCTelegramCompat_Empty($sMediaType) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    If Not IsArray($vMedia) And __CCTelegramCompat_Empty($vMedia) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    If Not __CCTelegramCompat_ParseModeOk($sParseMode) Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
    $sMediaType = StringLower($sMediaType)
    Local $oOpt = __CCTelegramCompat_CommonOpt($sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Local $vRes

    If $sMediaType = "media_group" Or $sMediaType = "mediagroup" Then
        Local $aList = $vMedia
        If Not IsArray($aList) Then $aList = StringSplit(String($vMedia), "|", 2)
        Local $aGroup[UBound($aList)], $oItem
        For $i = 0 To UBound($aList) - 1
            $oItem = _CCTelegram_InputMedia(__CCTelegramCompat_MediaType($aList[$i]), $aList[$i])
            If @error Then Return SetError($TG_ERR_BAD_INPUT, 0, Null)
            $aGroup[$i] = $oItem
        Next
        If $oOpt.Exists("parse_mode") Then $oOpt.Remove("parse_mode")
        If $oOpt.Exists("reply_markup") Then $oOpt.Remove("reply_markup") ; not supported by sendMediaGroup
        $vRes = _CCTelegram_SendMediaGroup($sChatId, $aGroup, $oOpt)
        If @error Then Return __CCTelegramCompat_Fail(@error, Null)
        Return $vRes
    EndIf

    Local $sApiMethod = "send" & StringReplace(StringUpper(StringLeft($sMediaType, 1)) & StringTrimLeft($sMediaType, 1), "_note", "Note")
    If Not __CCTelegramCompat_Empty($sCaption) And $sMediaType <> "video_note" Then __CCTelegram_DictSet($oOpt, "caption", __CCTelegramCompat_Text($sCaption))
    If $sMediaType = "video_note" And $oOpt.Exists("parse_mode") Then $oOpt.Remove("parse_mode")
    __CCTelegram_DictSet($oOpt, $sMediaType, $vMedia)
    __CCTelegram_DictSet($oOpt, "chat_id", $sChatId)
    $vRes = _CCTelegram_Call($sApiMethod, $oOpt)
    If @error Then Return __CCTelegramCompat_Fail(@error, Null)
    Return $vRes
EndFunc   ;==>_Telegram_SendMedia

#EndRegion "Internal functions of the original (public names)"

#Region "Helpers of the compatibility layer"

; Null, Default, "" and 0 count as "not set" (as in the original, where 0 = "" and 0 = Null are true)
Func __CCTelegramCompat_Empty($vValue)
    If IsKeyword($vValue) Then Return True
    If IsString($vValue) Then Return $vValue = ""
    If IsNumber($vValue) Then Return $vValue = 0
    If IsBool($vValue) Then Return Not $vValue
    Return False
EndFunc   ;==>__CCTelegramCompat_Empty

; Coordinates: 0 is a valid value (equator / prime meridian)
Func __CCTelegramCompat_EmptyCoord($vValue)
    If IsKeyword($vValue) Then Return True
    Return IsString($vValue) And StringStripWS($vValue, 8) = ""
EndFunc   ;==>__CCTelegramCompat_EmptyCoord

Func __CCTelegramCompat_ParseModeOk($sParseMode)
    If __CCTelegramCompat_Empty($sParseMode) Then Return True
    Return StringRegExp($sParseMode, "^(?i)(MarkdownV2|Markdown|HTML)$") = 1
EndFunc   ;==>__CCTelegramCompat_ParseModeOk

Func __CCTelegramCompat_Text($sText)
    If $TG_COMPAT_URLDECODE Then Return _CCTelegram_UrlDecode(String($sText))
    Return String($sText)
EndFunc   ;==>__CCTelegramCompat_Text

; parse_mode, reply_markup (JSON string or object), reply_to_message_id -> reply_parameters, disable_notification
Func __CCTelegramCompat_CommonOpt($sParseMode, $sReplyMarkup, $iReplyToMessage, $bDisableNotification)
    Local $oOpt = ObjCreate("Scripting.Dictionary")
    If Not __CCTelegramCompat_Empty($sParseMode) Then $oOpt.Add("parse_mode", String($sParseMode))
    If IsObj($sReplyMarkup) Then
        $oOpt.Add("reply_markup", $sReplyMarkup)
    ElseIf Not __CCTelegramCompat_Empty($sReplyMarkup) Then
        $oOpt.Add("reply_markup", __CCTelegramCompat_Text($sReplyMarkup))
    EndIf
    If Not __CCTelegramCompat_Empty($iReplyToMessage) Then $oOpt.Add("reply_parameters", _CCTelegram_Obj("message_id", Int($iReplyToMessage), "allow_sending_without_reply", True))
    If $bDisableNotification = True Then $oOpt.Add("disable_notification", True)
    Return $oOpt
EndFunc   ;==>__CCTelegramCompat_CommonOpt

Func __CCTelegramCompat_MediaType($vMedia)
    Switch StringLower(StringRegExpReplace(String($vMedia), "^.*\.", ""))
        Case "jpg", "jpeg", "png", "webp", "bmp"
            Return "photo"
        Case "mp4", "mov", "avi", "mkv", "webm", "m4v"
            Return "video"
        Case "mp3", "m4a", "flac", "wav", "ogg", "oga", "opus"
            Return "audio"
    EndSwitch
    Return "document"
EndFunc   ;==>__CCTelegramCompat_MediaType

Func __CCTelegramCompat_ParseQuery(ByRef $oP, $sQuery)
    Local $aPairs = StringSplit(String($sQuery), "&", 2), $iEq, $sKey
    For $i = 0 To UBound($aPairs) - 1
        If $aPairs[$i] = "" Then ContinueLoop
        $iEq = StringInStr($aPairs[$i], "=", 1)
        If $iEq = 0 Then
            __CCTelegram_DictSet($oP, _CCTelegram_UrlDecode($aPairs[$i]), "")
        Else
            $sKey = _CCTelegram_UrlDecode(StringLeft($aPairs[$i], $iEq - 1))
            __CCTelegram_DictSet($oP, $sKey, _CCTelegram_UrlDecode(StringTrimLeft($aPairs[$i], $iEq)))
        EndIf
    Next
EndFunc   ;==>__CCTelegramCompat_ParseQuery

; Maps a CCTelegramUDF error to the @error/@extended values of the original UDF and returns $vReturn.
Func __CCTelegramCompat_Fail($iCCTelegramError, $vReturn)
    Local $iError = $TG_ERR_API_CALL, $iExtended = $TG_ERR_API_CALL_SEND
    Switch $iCCTelegramError
        Case $CCTELEGRAM_ERR_INPUT, $CCTELEGRAM_ERR_FILE
            $iError = $TG_ERR_BAD_INPUT
            $iExtended = 0
        Case $CCTELEGRAM_ERR_NOINIT
            $iExtended = $TG_ERR_API_CALL_OPEN
        Case $CCTELEGRAM_ERR_TRANSPORT
            $iExtended = $TG_ERR_API_CALL_SEND
        Case $CCTELEGRAM_ERR_HTTP
            $iExtended = $TG_ERR_API_CALL_HTTP_NOT_SUCCESS
        Case $CCTELEGRAM_ERR_JSON
            $iExtended = $TG_ERR_API_CALL_NOT_DECODED
        Case $CCTELEGRAM_ERR_API
            ; the original reported Telegram errors with HTTP status <> 2xx as "HTTP not success"
            If _CCTelegram_LastHttpStatus() < 200 Or _CCTelegram_LastHttpStatus() > 299 Then
                $iExtended = $TG_ERR_API_CALL_HTTP_NOT_SUCCESS
            Else
                $iExtended = $TG_ERR_API_CALL_NOT_SUCCESS
            EndIf
    EndSwitch
    Return SetError($iError, $iExtended, $vReturn)
EndFunc   ;==>__CCTelegramCompat_Fail

#EndRegion "Helpers of the compatibility layer"
