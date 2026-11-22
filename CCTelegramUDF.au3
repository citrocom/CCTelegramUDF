#include-once
; SPDX-License-Identifier: GPL-3.0-or-later
#cs ===========================================================================================================================
    CCTelegramUDF - Telegram Bot API for AutoIt

    Author .......: Markus Debus, CITRO Computer
    Version ......: 1.0.1
    AutoIt .......: 3.3.14.0 or newer (3.3.16.1 recommended)
    License ......: GPL-3.0-or-later with an additional attribution term (GPLv3 section 7(b)), see LICENSE.txt and NOTICE.txt
    Telegram API .: https://core.telegram.org/bots/api

    About this project
        A complete, self-contained Telegram Bot API library for AutoIt. Every method of the Bot API is available as an
        AutoIt function (generated from the official documentation into CCTelegramUDF_Methods.au3), plus a set of helpers for
        keyboards, polling, file up- and download, text escaping and JSON handling.

        The idea of an AutoIt Telegram UDF was inspired by xLinkOut/telegram-udf-autoit (MIT). This library is a new,
        independent implementation; no code was taken over. compat\Telegram.au3 maps the public functions of that UDF
        onto this library so existing scripts keep working.

    Design
        - One HTTP stack: WinHttp.WinHttpRequest.5.1 (COM), with a local COM error handler (no script crash on network
          errors), configurable timeouts and proxy.
        - Requests are sent as UTF-8 JSON (no URL-encoding problems with &, #, +, %, umlauts or emoji). As soon as a
          local file is involved, the request is sent as multipart/form-data instead.
        - Own JSON parser/encoder in pure AutoIt (no machine code). JSON objects become Scripting.Dictionary objects,
          JSON arrays become AutoIt arrays - the same object model as Ward's Json.au3, so Json_Get() keeps working.
        - Telegram errors are not swallowed: error code, description and retry_after are available after every call.
          HTTP 429 (flood control) is retried automatically.

    Return values of the API functions
        Success: the "result" field of the Telegram response (Dictionary, array, Boolean, number or string).
                 @extended = HTTP status code.
        Failure: Null, @error = one of the $CCTELEGRAM_ERR_* constants, @extended = detail (Telegram error code, HTTP
                 status, COM error number). Details via _CCTelegram_LastErrorCode() / _CCTelegram_LastErrorDescription().

    AI assistance
        Large parts of this library were drafted together with Claude (Anthropic) and reviewed by the author.
#ce ===========================================================================================================================

#Region "Constants and globals"

Global Const $CCTELEGRAM_VERSION = "1.0.1"

; @error codes
Global Const $CCTELEGRAM_ERR_NOINIT = 1      ; _CCTelegram_Init() was not called (no token)
Global Const $CCTELEGRAM_ERR_INPUT = 2       ; invalid parameter (e.g. no JSON where JSON is required)
Global Const $CCTELEGRAM_ERR_TRANSPORT = 3   ; network/COM error (no connection, DNS, timeout, proxy, TLS)
Global Const $CCTELEGRAM_ERR_HTTP = 4        ; HTTP error without a valid Telegram JSON answer
Global Const $CCTELEGRAM_ERR_JSON = 5        ; answer could not be parsed
Global Const $CCTELEGRAM_ERR_API = 6         ; Telegram answered ok=false (see _CCTelegram_LastErrorCode/-Description)
Global Const $CCTELEGRAM_ERR_FILE = 7        ; local file not found / not readable / not writable

; Configuration
Global $__g_sCCTelegram_Token = ""
Global $__g_sCCTelegram_ApiBase = "https://api.telegram.org"
Global $__g_iCCTelegram_Offset = 0
Global $__g_sCCTelegram_Proxy = ""
Global $__g_sCCTelegram_ProxyBypass = ""
Global $__g_sCCTelegram_ProxyUser = ""
Global $__g_sCCTelegram_ProxyPass = ""
Global $__g_aCCTelegram_Timeouts[4] = [10000, 15000, 60000, 60000] ; resolve, connect, send, receive (ms)
Global $__g_iCCTelegram_MaxRetries = 3
Global $__g_iCCTelegram_MaxRetryWait = 60 ; seconds
Global $__g_bCCTelegram_Debug = False

; State of the last call
Global $__g_iCCTelegram_LastErrorCode = 0
Global $__g_sCCTelegram_LastErrorDesc = ""
Global $__g_iCCTelegram_LastRetryAfter = 0
Global $__g_vCCTelegram_LastMigrateTo = 0
Global $__g_iCCTelegram_LastHttpStatus = 0
Global $__g_sCCTelegram_LastResponse = ""

; COM error handler state
Global $__g_iCCTelegram_ComErrNumber = 0
Global $__g_sCCTelegram_ComErrDesc = ""

; Upload collector (used while a request is assembled)
Global $__g_bCCTelegram_Collect = False
Global $__g_iCCTelegram_UpCount = 0
Global $__g_aCCTelegram_UpName[8]
Global $__g_aCCTelegram_UpPath[8]

Global Const $__CCTELEGRAM_FILEMARK = "__cctelegram_file__"

#EndRegion "Constants and globals"

#Region "Initialisation and configuration"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Init
; Description ...: Sets the bot token (from @BotFather) and optionally checks it with getMe.
; Syntax ........: _CCTelegram_Init($sToken[, $bValidate = False[, $sApiBase = Default]])
; Parameters ....: $sToken    - bot token
;                  $bValidate - [optional] True = call getMe and fail if the token is not accepted
;                  $sApiBase  - [optional] base URL of the Bot API server (default https://api.telegram.org); for a local
;                               Bot API server e.g. "http://127.0.0.1:8081"
; Return values .: Success - True
;                  Failure - False, @error = $CCTELEGRAM_ERR_INPUT (empty token) or the error of getMe
; ===========================================================================================================================
Func _CCTelegram_Init($sToken, $bValidate = False, $sApiBase = Default)
    If Not IsString($sToken) Then $sToken = String($sToken)
    $sToken = StringStripWS($sToken, 3)
    If $sToken = "" Then Return SetError($CCTELEGRAM_ERR_INPUT, 1, False)
    $__g_sCCTelegram_Token = $sToken
    If IsString($sApiBase) And $sApiBase <> "" Then $__g_sCCTelegram_ApiBase = StringRegExpReplace($sApiBase, "/+$", "")
    $__g_iCCTelegram_Offset = 0
    If $bValidate Then
        Local $oMe = _CCTelegram_Call("getMe"), $iErr = @error, $iExt = @extended
        If $iErr Or Not __CCTelegram_IsDict($oMe) Then
            $__g_sCCTelegram_Token = ""
            Return SetError($iErr ? $iErr : $CCTELEGRAM_ERR_API, $iExt, False)
        EndIf
    EndIf
    Return True
EndFunc   ;==>_CCTelegram_Init

; Returns the token set by _CCTelegram_Init ("" if none).
Func _CCTelegram_GetToken()
    Return $__g_sCCTelegram_Token
EndFunc   ;==>_CCTelegram_GetToken

; Returns the version of this library.
Func _CCTelegram_Version()
    Return $CCTELEGRAM_VERSION
EndFunc   ;==>_CCTelegram_Version

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_SetProxy
; Description ...: Routes all requests through a proxy. Call without parameters to switch back to direct access.
; Syntax ........: _CCTelegram_SetProxy([$sProxy = ""[, $sBypass = ""[, $sUser = ""[, $sPassword = ""]]]])
; Parameters ....: $sProxy    - "host:port", e.g. "proxy.local:8080"; "" = no proxy (WinHTTP default: direct)
;                  $sBypass   - [optional] bypass list, e.g. "<local>;*.intern"
;                  $sUser     - [optional] proxy user name (Basic/NTLM)
;                  $sPassword - [optional] proxy password
; ===========================================================================================================================
Func _CCTelegram_SetProxy($sProxy = "", $sBypass = "", $sUser = "", $sPassword = "")
    $__g_sCCTelegram_Proxy = String($sProxy)
    $__g_sCCTelegram_ProxyBypass = String($sBypass)
    $__g_sCCTelegram_ProxyUser = String($sUser)
    $__g_sCCTelegram_ProxyPass = String($sPassword)
    Return True
EndFunc   ;==>_CCTelegram_SetProxy

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_SetTimeouts
; Description ...: Sets the WinHTTP timeouts in milliseconds. Default keeps the current value.
;                  For getUpdates with a "timeout" parameter (long polling) the receive timeout is raised automatically.
; ===========================================================================================================================
Func _CCTelegram_SetTimeouts($iResolve = Default, $iConnect = Default, $iSend = Default, $iReceive = Default)
    If IsKeyword($iResolve) <> 1 Then $__g_aCCTelegram_Timeouts[0] = Int($iResolve)
    If IsKeyword($iConnect) <> 1 Then $__g_aCCTelegram_Timeouts[1] = Int($iConnect)
    If IsKeyword($iSend) <> 1 Then $__g_aCCTelegram_Timeouts[2] = Int($iSend)
    If IsKeyword($iReceive) <> 1 Then $__g_aCCTelegram_Timeouts[3] = Int($iReceive)
    Return True
EndFunc   ;==>_CCTelegram_SetTimeouts

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_SetRetry
; Description ...: Configures the automatic retry on HTTP 429 (flood control).
; Parameters ....: $iMaxRetries - number of retries (0 = off)
;                  $iMaxWait    - [optional] maximum retry_after in seconds that is waited for; larger values fail at once
; ===========================================================================================================================
Func _CCTelegram_SetRetry($iMaxRetries = 3, $iMaxWait = 60)
    $__g_iCCTelegram_MaxRetries = Int($iMaxRetries)
    $__g_iCCTelegram_MaxRetryWait = Int($iMaxWait)
    Return True
EndFunc   ;==>_CCTelegram_SetRetry

; Switches debug output (ConsoleWrite of requests and responses; the token is never printed) on or off.
Func _CCTelegram_SetDebug($bOn = True)
    $__g_bCCTelegram_Debug = ($bOn = True)
    Return True
EndFunc   ;==>_CCTelegram_SetDebug

#EndRegion "Initialisation and configuration"

#Region "Error information of the last call"

; Telegram error code of the last call (e.g. 400, 403, 429), 0 if none.
Func _CCTelegram_LastErrorCode()
    Return $__g_iCCTelegram_LastErrorCode
EndFunc   ;==>_CCTelegram_LastErrorCode

; Error text of the last call (Telegram "description", or a description of the local/network error).
Func _CCTelegram_LastErrorDescription()
    Return $__g_sCCTelegram_LastErrorDesc
EndFunc   ;==>_CCTelegram_LastErrorDescription

; retry_after in seconds from the last error answer (flood control), 0 if none.
Func _CCTelegram_LastRetryAfter()
    Return $__g_iCCTelegram_LastRetryAfter
EndFunc   ;==>_CCTelegram_LastRetryAfter

; migrate_to_chat_id from the last error answer (group was upgraded to a supergroup), 0 if none.
Func _CCTelegram_LastMigrateToChatId()
    Return $__g_vCCTelegram_LastMigrateTo
EndFunc   ;==>_CCTelegram_LastMigrateToChatId

; HTTP status code of the last call, 0 if no answer was received.
Func _CCTelegram_LastHttpStatus()
    Return $__g_iCCTelegram_LastHttpStatus
EndFunc   ;==>_CCTelegram_LastHttpStatus

; Raw JSON text of the last answer.
Func _CCTelegram_LastResponse()
    Return $__g_sCCTelegram_LastResponse
EndFunc   ;==>_CCTelegram_LastResponse

Func __CCTelegram_ResetError()
    $__g_iCCTelegram_LastErrorCode = 0
    $__g_sCCTelegram_LastErrorDesc = ""
    $__g_iCCTelegram_LastRetryAfter = 0
    $__g_vCCTelegram_LastMigrateTo = 0
    $__g_iCCTelegram_LastHttpStatus = 0
    $__g_sCCTelegram_LastResponse = ""
EndFunc   ;==>__CCTelegram_ResetError

#EndRegion "Error information of the last call"

#Region "Generic call"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Call
; Description ...: Calls any Bot API method by name. Useful for methods newer than CCTelegramUDF_Methods.au3.
; Syntax ........: _CCTelegram_Call($sMethod[, $vParams = Default])
; Parameters ....: $sMethod - method name as in the API documentation, e.g. "sendMessage"
;                  $vParams - [optional] parameters as Dictionary (see _CCTelegram_Obj) or JSON string
; Return values .: see header of this file
; Remarks .......: For known methods, string values of object/array parameters (e.g. reply_markup) are parsed as JSON and
;                  existing local files in file parameters are uploaded. For unknown methods pass objects/arrays directly
;                  and use _CCTelegram_File() for uploads.
; ===========================================================================================================================
Func _CCTelegram_Call($sMethod, $vParams = Default)
    Local $oP = __CCTelegram_Params($vParams)
    If @error Then Return SetError($CCTELEGRAM_ERR_INPUT, 0, Null)
    Local $sJsonFields = "", $sFileFields = ""
    __CCTelegram_Meta($sMethod, $sJsonFields, $sFileFields)
    Local $vRes = __CCTelegram_Request($sMethod, $oP, $sJsonFields, $sFileFields)
    Return SetError(@error, @extended, $vRes)
EndFunc   ;==>_CCTelegram_Call

#EndRegion "Generic call"

#Region "Building parameters"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Obj
; Description ...: Creates a Dictionary (JSON object) from key/value pairs. Pairs whose value is Default are skipped.
;                  Use it for the optional parameters ($vOpt) of the API functions and for nested API objects.
; Syntax ........: _CCTelegram_Obj([$k1, $v1[, $k2, $v2 ...]])   (up to 16 pairs)
; Example .......: _CCTelegram_SendMessage($iChat, "Hi", _CCTelegram_Obj("parse_mode", "HTML", "disable_notification", True))
; ===========================================================================================================================
Func _CCTelegram_Obj($k1 = Default, $v1 = Default, $k2 = Default, $v2 = Default, $k3 = Default, $v3 = Default, $k4 = Default, $v4 = Default, _
        $k5 = Default, $v5 = Default, $k6 = Default, $v6 = Default, $k7 = Default, $v7 = Default, $k8 = Default, $v8 = Default, _
        $k9 = Default, $v9 = Default, $k10 = Default, $v10 = Default, $k11 = Default, $v11 = Default, $k12 = Default, $v12 = Default, _
        $k13 = Default, $v13 = Default, $k14 = Default, $v14 = Default, $k15 = Default, $v15 = Default, $k16 = Default, $v16 = Default)
    #forceref $k1, $v1, $k2, $v2, $k3, $v3, $k4, $v4, $k5, $v5, $k6, $v6, $k7, $v7, $k8, $v8
    #forceref $k9, $v9, $k10, $v10, $k11, $v11, $k12, $v12, $k13, $v13, $k14, $v14, $k15, $v15, $k16, $v16
    Local $oObj = ObjCreate("Scripting.Dictionary")
    Local $vKey, $vValue
    For $i = 1 To Int((@NumParams + 1) / 2)
        $vKey = Eval("k" & $i)
        $vValue = Eval("v" & $i)
        If IsKeyword($vKey) = 1 Or IsKeyword($vValue) = 1 Then ContinueLoop
        __CCTelegram_DictSet($oObj, String($vKey), $vValue)
    Next
    Return $oObj
EndFunc   ;==>_CCTelegram_Obj

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Arr
; Description ...: Creates a 1D array from the given values (up to 32). Default values are skipped.
; Example .......: _CCTelegram_Arr("message", "callback_query")
; ===========================================================================================================================
Func _CCTelegram_Arr($v1 = Default, $v2 = Default, $v3 = Default, $v4 = Default, $v5 = Default, $v6 = Default, $v7 = Default, $v8 = Default, _
        $v9 = Default, $v10 = Default, $v11 = Default, $v12 = Default, $v13 = Default, $v14 = Default, $v15 = Default, $v16 = Default, _
        $v17 = Default, $v18 = Default, $v19 = Default, $v20 = Default, $v21 = Default, $v22 = Default, $v23 = Default, $v24 = Default, _
        $v25 = Default, $v26 = Default, $v27 = Default, $v28 = Default, $v29 = Default, $v30 = Default, $v31 = Default, $v32 = Default)
    #forceref $v1, $v2, $v3, $v4, $v5, $v6, $v7, $v8, $v9, $v10, $v11, $v12, $v13, $v14, $v15, $v16
    #forceref $v17, $v18, $v19, $v20, $v21, $v22, $v23, $v24, $v25, $v26, $v27, $v28, $v29, $v30, $v31, $v32
    Local $aRes[32], $iN = 0, $vValue
    For $i = 1 To @NumParams
        $vValue = Eval("v" & $i)
        If IsKeyword($vValue) = 1 Then ContinueLoop
        $aRes[$iN] = $vValue
        $iN += 1
    Next
    ReDim $aRes[$iN]
    Return $aRes
EndFunc   ;==>_CCTelegram_Arr

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_File
; Description ...: Marks a local file for upload. Needed only inside nested objects (e.g. InputMedia, InputSticker);
;                  for direct file parameters (photo, document, ...) a plain path is enough.
; Return values .: Success - marker object, Failure - Null and @error = $CCTELEGRAM_ERR_FILE
; ===========================================================================================================================
Func _CCTelegram_File($sPath)
    If Not __CCTelegram_IsLocalFile($sPath) Then
        $__g_sCCTelegram_LastErrorDesc = "File not found: " & $sPath
        Return SetError($CCTELEGRAM_ERR_FILE, 0, Null)
    EndIf
    Local $oMark = ObjCreate("Scripting.Dictionary")
    $oMark.Add($__CCTELEGRAM_FILEMARK, $sPath)
    Return $oMark
EndFunc   ;==>_CCTelegram_File

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_InputMedia
; Description ...: Creates an InputMedia object for sendMediaGroup / editMessageMedia.
; Syntax ........: _CCTelegram_InputMedia($sType, $vMedia[, $vOpt = Default])
; Parameters ....: $sType  - "photo", "video", "animation", "audio", "document" or "live_photo"
;                  $vMedia - local path (uploaded), URL or file_id
;                  $vOpt   - [optional] further fields (caption, parse_mode, thumbnail, has_spoiler, ...)
; ===========================================================================================================================
Func _CCTelegram_InputMedia($sType, $vMedia, $vOpt = Default)
    Local $oMedia = __CCTelegram_Params($vOpt)
    If @error Then Return SetError($CCTELEGRAM_ERR_INPUT, 0, Null)
    __CCTelegram_DictSet($oMedia, "type", $sType)
    If __CCTelegram_IsLocalFile($vMedia) Then
        __CCTelegram_DictSet($oMedia, "media", _CCTelegram_File($vMedia))
    ElseIf __CCTelegram_LooksLikePath($vMedia) Then
        $__g_sCCTelegram_LastErrorDesc = "File not found: " & $vMedia
        Return SetError($CCTELEGRAM_ERR_FILE, 0, Null)
    Else
        __CCTelegram_DictSet($oMedia, "media", $vMedia)
    EndIf
    If $oMedia.Exists("thumbnail") Then
        Local $vThumb = $oMedia.Item("thumbnail")
        If __CCTelegram_IsLocalFile($vThumb) Then __CCTelegram_DictSet($oMedia, "thumbnail", _CCTelegram_File($vThumb))
    EndIf
    Return $oMedia
EndFunc   ;==>_CCTelegram_InputMedia

; Internal: options parameter (Default / Dictionary / JSON string) -> new Dictionary (the caller's object is not changed)
Func __CCTelegram_Params($vOpt)
    Local $oP = ObjCreate("Scripting.Dictionary")
    If IsKeyword($vOpt) Then Return $oP
    If IsString($vOpt) Then
        If StringStripWS($vOpt, 8) = "" Then Return $oP
        $vOpt = _CCTelegram_JsonDecode($vOpt)
        If @error Then
            $__g_sCCTelegram_LastErrorDesc = "Options are not valid JSON"
            Return SetError(1, 0, $oP)
        EndIf
    EndIf
    If Not __CCTelegram_IsDict($vOpt) Then
        $__g_sCCTelegram_LastErrorDesc = "Options must be a Dictionary (_CCTelegram_Obj) or a JSON object string"
        Return SetError(1, 0, $oP)
    EndIf
    Local $aKeys = $vOpt.Keys()
    For $i = 0 To UBound($aKeys) - 1
        $oP.Add($aKeys[$i], $vOpt.Item($aKeys[$i]))
    Next
    Return $oP
EndFunc   ;==>__CCTelegram_Params

; Internal: sets a parameter unless the value is Default
Func __CCTelegram_Set(ByRef $oP, $sKey, $vValue)
    If IsKeyword($vValue) = 1 Then Return
    __CCTelegram_DictSet($oP, $sKey, $vValue)
EndFunc   ;==>__CCTelegram_Set

Func __CCTelegram_DictSet(ByRef $oDict, $sKey, $vValue)
    If $oDict.Exists($sKey) Then $oDict.Remove($sKey)
    $oDict.Add($sKey, $vValue)
EndFunc   ;==>__CCTelegram_DictSet

Func __CCTelegram_IsDict($vData)
    Return IsObj($vData) And ObjName($vData) = "Dictionary"
EndFunc   ;==>__CCTelegram_IsDict

Func __CCTelegram_IsFileMarker($vData)
    Return __CCTelegram_IsDict($vData) And $vData.Exists($__CCTELEGRAM_FILEMARK)
EndFunc   ;==>__CCTelegram_IsFileMarker

Func __CCTelegram_IsLocalFile($vData)
    If Not IsString($vData) Or $vData = "" Then Return False
    If StringRegExp($vData, "^[A-Za-z][A-Za-z0-9+.\-]*://") Then Return False ; URL, attach://
    If Not FileExists($vData) Then Return False
    Return Not StringInStr(FileGetAttrib($vData), "D")
EndFunc   ;==>__CCTelegram_IsLocalFile

Func __CCTelegram_LooksLikePath($vData)
    If Not IsString($vData) Then Return False
    Return StringRegExp($vData, "^(?:[A-Za-z]:[\\/]|\\\\|\.{1,2}[\\/])") = 1
EndFunc   ;==>__CCTelegram_LooksLikePath

#EndRegion "Building parameters"

#Region "Reading results"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Get
; Description ...: Reads a value from a result by path. Object keys are separated by "." , array indexes by [n] or .n
; Syntax ........: _CCTelegram_Get($vData, $sPath[, $vDefault = Null])
; Example .......: _CCTelegram_Get($oUpdate, "message.chat.id")
;                  _CCTelegram_Get($oMessage, "photo[0].file_id")
; Return values .: Success - the value, Failure (path not present) - $vDefault and @error = 1
; ===========================================================================================================================
Func _CCTelegram_Get($vData, $sPath, $vDefault = Null)
    Local $aTok = StringRegExp($sPath, "[^.\[\]]+", 3)
    If @error Then Return $vData
    Local $vCur = $vData, $sTok
    For $i = 0 To UBound($aTok) - 1
        $sTok = $aTok[$i]
        If IsArray($vCur) Then
            If Not StringIsDigit($sTok) Then Return SetError(1, 0, $vDefault)
            If UBound($vCur, 0) <> 1 Or Int($sTok) >= UBound($vCur) Then Return SetError(1, 0, $vDefault)
            $vCur = $vCur[Int($sTok)]
        ElseIf __CCTelegram_IsDict($vCur) Then
            If Not $vCur.Exists($sTok) Then Return SetError(1, 0, $vDefault)
            $vCur = $vCur.Item($sTok)
        Else
            Return SetError(1, 0, $vDefault)
        EndIf
    Next
    Return $vCur
EndFunc   ;==>_CCTelegram_Get

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_UpdateType
; Description ...: Returns the kind of an Update object: "message", "edited_message", "callback_query", "channel_post", ...
; ===========================================================================================================================
Func _CCTelegram_UpdateType($oUpdate)
    If Not __CCTelegram_IsDict($oUpdate) Then Return SetError(1, 0, "")
    Local $aKeys = $oUpdate.Keys()
    For $i = 0 To UBound($aKeys) - 1
        If $aKeys[$i] <> "update_id" Then Return $aKeys[$i]
    Next
    Return SetError(1, 0, "")
EndFunc   ;==>_CCTelegram_UpdateType

#EndRegion "Reading results"

#Region "Receiving updates"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_Poll
; Description ...: Fetches new updates with long polling and confirms them automatically (offset).
;                  Blocks at most $iTimeout seconds; returns at once when updates arrive.
; Syntax ........: _CCTelegram_Poll([$iTimeout = 30[, $vAllowedUpdates = Default[, $iLimit = Default]]])
; Parameters ....: $iTimeout        - long polling timeout in seconds (0 = short polling, returns immediately)
;                  $vAllowedUpdates - [optional] array or comma separated string, e.g. "message,callback_query"
;                  $iLimit          - [optional] 1-100
; Return values .: Array of Update objects (may be empty). On error an empty array and @error/@extended are set, so a
;                  polling loop keeps running; check @error to wait before the next try.
; ===========================================================================================================================
Func _CCTelegram_Poll($iTimeout = 30, $vAllowedUpdates = Default, $iLimit = Default)
    Local $aEmpty[0]
    Local $oP = ObjCreate("Scripting.Dictionary")
    $oP.Add("offset", $__g_iCCTelegram_Offset)
    $oP.Add("timeout", Int($iTimeout))
    If IsKeyword($iLimit) <> 1 Then $oP.Add("limit", Int($iLimit))
    If IsString($vAllowedUpdates) And Not StringRegExp($vAllowedUpdates, "^\s*\[") Then
        Local $aAllowed = StringSplit(StringStripWS($vAllowedUpdates, 8), ",", 2)
        $oP.Add("allowed_updates", $aAllowed)
    ElseIf IsKeyword($vAllowedUpdates) <> 1 Then
        $oP.Add("allowed_updates", $vAllowedUpdates)
    EndIf
    Local $aUpd = __CCTelegram_Request("getUpdates", $oP, "|allowed_updates|", "")
    Local $iErr = @error, $iExt = @extended
    If $iErr Then Return SetError($iErr, $iExt, $aEmpty)
    If Not IsArray($aUpd) Then Return SetError($CCTELEGRAM_ERR_JSON, 0, $aEmpty)
    If UBound($aUpd) > 0 Then
        Local $iId = _CCTelegram_Get($aUpd[UBound($aUpd) - 1], "update_id", -1)
        If $iId >= 0 Then $__g_iCCTelegram_Offset = $iId + 1
    EndIf
    Return $aUpd
EndFunc   ;==>_CCTelegram_Poll

; Returns the offset (next expected update_id) used by _CCTelegram_Poll.
Func _CCTelegram_GetOffset()
    Return $__g_iCCTelegram_Offset
EndFunc   ;==>_CCTelegram_GetOffset

; Sets the offset used by _CCTelegram_Poll (e.g. restored from an INI file after a restart).
Func _CCTelegram_SetOffset($iOffset)
    $__g_iCCTelegram_Offset = $iOffset
    Return True
EndFunc   ;==>_CCTelegram_SetOffset

#EndRegion "Receiving updates"

#Region "Files"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_DownloadFile
; Description ...: Downloads a file sent to the bot (getFile + download). Bots can download files up to 20 MB from the
;                  public Bot API server.
; Syntax ........: _CCTelegram_DownloadFile($sFileId, $sDestination)
; Parameters ....: $sFileId      - file_id (e.g. from _CCTelegram_Get($oMsg, "document.file_id"))
;                  $sDestination - target file, or an existing folder / path ending with "\" (original file name is kept)
; Return values .: Success - full path of the written file, Failure - "" and @error set
; ===========================================================================================================================
Func _CCTelegram_DownloadFile($sFileId, $sDestination)
    Local $oFile = _CCTelegram_Call("getFile", _CCTelegram_Obj("file_id", $sFileId))
    Local $iErr = @error, $iExt = @extended
    If $iErr Then Return SetError($iErr, $iExt, "")
    Local $sFilePath = _CCTelegram_Get($oFile, "file_path", "")
    If $sFilePath = "" Then
        $__g_sCCTelegram_LastErrorDesc = "getFile returned no file_path"
        Return SetError($CCTELEGRAM_ERR_API, 0, "")
    EndIf
    If StringRegExp($sDestination, "[\\/]$") Or StringInStr(FileGetAttrib($sDestination), "D") Then
        $sDestination = StringRegExpReplace($sDestination, "[\\/]+$", "") & "\" & StringRegExpReplace($sFilePath, "^.*[\\/]", "")
    EndIf
    ; A local Bot API server in --local mode returns an absolute path on its own disk
    If FileExists($sFilePath) Then
        If Not FileCopy($sFilePath, $sDestination, 1 + 8) Then
            $__g_sCCTelegram_LastErrorDesc = "Cannot copy " & $sFilePath & " to " & $sDestination
            Return SetError($CCTELEGRAM_ERR_FILE, 0, "")
        EndIf
        Return $sDestination
    EndIf
    Local $iStatus = 0
    Local $sUrl = $__g_sCCTelegram_ApiBase & "/file/bot" & $__g_sCCTelegram_Token & "/" & $sFilePath
    Local $bData = __CCTelegram_Http("GET", $sUrl, Binary(""), "", 300000, $iStatus)
    If @error Then
        $__g_sCCTelegram_LastErrorDesc = "Download failed: " & $__g_sCCTelegram_ComErrDesc
        Return SetError($CCTELEGRAM_ERR_TRANSPORT, $__g_iCCTelegram_ComErrNumber, "")
    EndIf
    $__g_iCCTelegram_LastHttpStatus = $iStatus
    If $iStatus <> 200 Then
        $__g_sCCTelegram_LastErrorDesc = "Download failed with HTTP " & $iStatus
        Return SetError($CCTELEGRAM_ERR_HTTP, $iStatus, "")
    EndIf
    Local $hFile = FileOpen($sDestination, 2 + 8 + 16) ; overwrite + create folders + binary
    If $hFile = -1 Then
        $__g_sCCTelegram_LastErrorDesc = "Cannot write " & $sDestination
        Return SetError($CCTELEGRAM_ERR_FILE, 0, "")
    EndIf
    FileWrite($hFile, $bData)
    FileClose($hFile)
    Return $sDestination
EndFunc   ;==>_CCTelegram_DownloadFile

#EndRegion "Files"

#Region "Keyboards"

; Inline button with callback data (answer the click with _CCTelegram_AnswerCallbackQuery).
Func _CCTelegram_InlineButton($sText, $sCallbackData)
    Return _CCTelegram_Obj("text", String($sText), "callback_data", String($sCallbackData))
EndFunc   ;==>_CCTelegram_InlineButton

; Inline button that opens a URL.
Func _CCTelegram_UrlButton($sText, $sUrl)
    Return _CCTelegram_Obj("text", String($sText), "url", String($sUrl))
EndFunc   ;==>_CCTelegram_UrlButton

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_InlineKeyboard
; Description ...: Creates an InlineKeyboardMarkup object (for reply_markup).
; Syntax ........: _CCTelegram_InlineKeyboard($aRows)
; Parameters ....: $aRows - one of:
;                           - 2D array [row][column] of buttons
;                           - 1D array whose elements are rows (1D arrays of buttons)
;                           - 1D array of buttons where an empty string "" starts a new row
;                           A button is an object from _CCTelegram_InlineButton/_CCTelegram_UrlButton/_CCTelegram_Obj, or a string
;                           (then text = callback_data = string). Empty cells ("") are skipped.
; ===========================================================================================================================
Func _CCTelegram_InlineKeyboard($aRows)
    Local $aKb = __CCTelegram_Rows($aRows, True)
    If @error Then Return SetError($CCTELEGRAM_ERR_INPUT, 0, Null)
    Return _CCTelegram_Obj("inline_keyboard", $aKb)
EndFunc   ;==>_CCTelegram_InlineKeyboard

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_ReplyKeyboard
; Description ...: Creates a ReplyKeyboardMarkup object. $aRows like _CCTelegram_InlineKeyboard; strings become text buttons.
; Syntax ........: _CCTelegram_ReplyKeyboard($aRows[, $bResize = True[, $bOneTime = False[, $sPlaceholder = Default[, $bPersistent = Default]]]])
; ===========================================================================================================================
Func _CCTelegram_ReplyKeyboard($aRows, $bResize = True, $bOneTime = False, $sPlaceholder = Default, $bPersistent = Default)
    Local $aKb = __CCTelegram_Rows($aRows, False)
    If @error Then Return SetError($CCTELEGRAM_ERR_INPUT, 0, Null)
    Local $oKb = _CCTelegram_Obj("keyboard", $aKb, "resize_keyboard", ($bResize = True), "one_time_keyboard", ($bOneTime = True))
    If IsKeyword($sPlaceholder) <> 1 Then __CCTelegram_DictSet($oKb, "input_field_placeholder", String($sPlaceholder))
    If IsKeyword($bPersistent) <> 1 Then __CCTelegram_DictSet($oKb, "is_persistent", ($bPersistent = True))
    Return $oKb
EndFunc   ;==>_CCTelegram_ReplyKeyboard

; Removes a reply keyboard (ReplyKeyboardRemove).
Func _CCTelegram_ReplyKeyboardRemove($bSelective = Default)
    Local $oKb = _CCTelegram_Obj("remove_keyboard", True)
    If IsKeyword($bSelective) <> 1 Then __CCTelegram_DictSet($oKb, "selective", ($bSelective = True))
    Return $oKb
EndFunc   ;==>_CCTelegram_ReplyKeyboardRemove

; Forces a reply from the user (ForceReply).
Func _CCTelegram_ForceReply($sPlaceholder = Default, $bSelective = Default)
    Local $oKb = _CCTelegram_Obj("force_reply", True)
    If IsKeyword($sPlaceholder) <> 1 Then __CCTelegram_DictSet($oKb, "input_field_placeholder", String($sPlaceholder))
    If IsKeyword($bSelective) <> 1 Then __CCTelegram_DictSet($oKb, "selective", ($bSelective = True))
    Return $oKb
EndFunc   ;==>_CCTelegram_ForceReply

; Internal: normalises the supported row formats into an array of row arrays
Func __CCTelegram_Rows($aRows, $bInline)
    If Not IsArray($aRows) Then Return SetError(1, 0, Null)
    Local $aOut[8], $iOut = 0, $aCur[8], $iCur = 0, $vCell
    If UBound($aRows, 0) = 2 Then
        For $r = 0 To UBound($aRows, 1) - 1
            $iCur = 0
            For $c = 0 To UBound($aRows, 2) - 1
                $vCell = $aRows[$r][$c]
                If __CCTelegram_IsEmptyCell($vCell) Then ContinueLoop
                __CCTelegram_ArrayPush($aCur, $iCur, __CCTelegram_Button($vCell, $bInline))
            Next
            If $iCur > 0 Then __CCTelegram_ArrayPush($aOut, $iOut, __CCTelegram_ArrayCopy($aCur, $iCur))
        Next
    ElseIf UBound($aRows, 0) = 1 Then
        For $k = 0 To UBound($aRows) - 1
            $vCell = $aRows[$k]
            If IsArray($vCell) Then
                If $iCur > 0 Then
                    __CCTelegram_ArrayPush($aOut, $iOut, __CCTelegram_ArrayCopy($aCur, $iCur))
                    $iCur = 0
                EndIf
                For $c = 0 To UBound($vCell) - 1
                    If __CCTelegram_IsEmptyCell($vCell[$c]) Then ContinueLoop
                    __CCTelegram_ArrayPush($aCur, $iCur, __CCTelegram_Button($vCell[$c], $bInline))
                Next
                If $iCur > 0 Then __CCTelegram_ArrayPush($aOut, $iOut, __CCTelegram_ArrayCopy($aCur, $iCur))
                $iCur = 0
            ElseIf __CCTelegram_IsEmptyCell($vCell) Then
                If $iCur > 0 Then __CCTelegram_ArrayPush($aOut, $iOut, __CCTelegram_ArrayCopy($aCur, $iCur))
                $iCur = 0
            Else
                __CCTelegram_ArrayPush($aCur, $iCur, __CCTelegram_Button($vCell, $bInline))
            EndIf
        Next
        If $iCur > 0 Then __CCTelegram_ArrayPush($aOut, $iOut, __CCTelegram_ArrayCopy($aCur, $iCur))
    Else
        Return SetError(1, 0, Null)
    EndIf
    ReDim $aOut[$iOut]
    Return $aOut
EndFunc   ;==>__CCTelegram_Rows

Func __CCTelegram_Button($vCell, $bInline)
    If IsObj($vCell) Then Return $vCell
    If $bInline Then Return _CCTelegram_InlineButton(String($vCell), String($vCell))
    Return _CCTelegram_Obj("text", String($vCell))
EndFunc   ;==>__CCTelegram_Button

Func __CCTelegram_IsEmptyCell($vCell)
    If IsKeyword($vCell) Then Return True
    Return IsString($vCell) And $vCell = ""
EndFunc   ;==>__CCTelegram_IsEmptyCell

Func __CCTelegram_ArrayPush(ByRef $aArr, ByRef $iCount, $vValue)
    If $iCount >= UBound($aArr) Then ReDim $aArr[$iCount * 2 + 1]
    $aArr[$iCount] = $vValue
    $iCount += 1
EndFunc   ;==>__CCTelegram_ArrayPush

Func __CCTelegram_ArrayCopy(ByRef $aArr, $iCount)
    Local $aRes[$iCount]
    For $i = 0 To $iCount - 1
        $aRes[$i] = $aArr[$i]
    Next
    Return $aRes
EndFunc   ;==>__CCTelegram_ArrayCopy

#EndRegion "Keyboards"

#Region "Text helpers"

; Escapes all characters that have a meaning in MarkdownV2 (for parse_mode "MarkdownV2").
Func _CCTelegram_EscapeMarkdownV2($sText)
    Return StringRegExpReplace(String($sText), "([_*\[\]()~`>#+\-=|{}.!\\])", "\\$1")
EndFunc   ;==>_CCTelegram_EscapeMarkdownV2

; Escapes &, <, > and " for parse_mode "HTML".
Func _CCTelegram_EscapeHtml($sText)
    Local $s = StringReplace(String($sText), "&", "&amp;", 0, 1)
    $s = StringReplace($s, "<", "&lt;", 0, 1)
    $s = StringReplace($s, ">", "&gt;", 0, 1)
    Return StringReplace($s, '"', "&quot;", 0, 1)
EndFunc   ;==>_CCTelegram_EscapeHtml

; URL-encodes a string (UTF-8, RFC 3986 unreserved characters are kept).
Func _CCTelegram_UrlEncode($sText)
    Local $bData = StringToBinary(String($sText), 4)
    Local $sOut = "", $iByte
    For $i = 1 To BinaryLen($bData)
        $iByte = Dec(Hex(BinaryMid($bData, $i, 1)))
        If ($iByte >= 0x30 And $iByte <= 0x39) Or ($iByte >= 0x41 And $iByte <= 0x5A) Or ($iByte >= 0x61 And $iByte <= 0x7A) _
                Or $iByte = 0x2D Or $iByte = 0x2E Or $iByte = 0x5F Or $iByte = 0x7E Then
            $sOut &= Chr($iByte)
        Else
            $sOut &= "%" & Hex($iByte, 2)
        EndIf
    Next
    Return $sOut
EndFunc   ;==>_CCTelegram_UrlEncode

; Decodes %XX sequences (UTF-8). With $bPlusIsSpace = True, "+" becomes a space (form encoding).
Func _CCTelegram_UrlDecode($sText, $bPlusIsSpace = False)
    $sText = String($sText)
    If $bPlusIsSpace Then $sText = StringReplace($sText, "+", " ", 0, 1)
    If Not StringRegExp($sText, "%[0-9A-Fa-f]{2}") Then Return $sText
    Local $aParts = StringRegExp($sText, "(?:%[0-9A-Fa-f]{2})+|[^%]+|%", 3)
    Local $sOut = ""
    For $i = 0 To UBound($aParts) - 1
        If StringLen($aParts[$i]) >= 3 And StringLeft($aParts[$i], 1) = "%" Then
            $sOut &= BinaryToString(Binary("0x" & StringReplace($aParts[$i], "%", "", 0, 1)), 4)
        Else
            $sOut &= $aParts[$i]
        EndIf
    Next
    Return $sOut
EndFunc   ;==>_CCTelegram_UrlDecode

#EndRegion "Text helpers"

#Region "JSON"

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_JsonDecode
; Description ...: Parses JSON text. Objects -> Scripting.Dictionary, arrays -> 1D AutoIt arrays, true/false -> Boolean,
;                  null -> Null, numbers -> Int32/Int64/Double.
; Return values .: Success - the value, Failure - Null and @error = $CCTELEGRAM_ERR_JSON, @extended = position of the error
; ===========================================================================================================================
Func _CCTelegram_JsonDecode($sJson)
    $sJson = String($sJson)
    If StringLeft($sJson, 1) = ChrW(0xFEFF) Then $sJson = StringTrimLeft($sJson, 1)
    Local $iPos = 1
    Local $vRes = __CCTelegram_JsonParse($sJson, $iPos)
    If @error Then Return SetError($CCTELEGRAM_ERR_JSON, $iPos, Null)
    __CCTelegram_JsonSkipWs($sJson, $iPos)
    If $iPos <= StringLen($sJson) Then Return SetError($CCTELEGRAM_ERR_JSON, $iPos, Null)
    Return $vRes
EndFunc   ;==>_CCTelegram_JsonDecode

; #FUNCTION# ================================================================================================================
; Name ..........: _CCTelegram_JsonEncode
; Description ...: Converts a value into compact JSON. Dictionary -> object (Default items are skipped), 1D array -> array,
;                  2D array -> array of rows, Boolean -> true/false, Null/Default -> null, numbers, strings.
; Return values .: Success - JSON text, Failure - "" and @error = $CCTELEGRAM_ERR_INPUT (unsupported type)
; ===========================================================================================================================
Func _CCTelegram_JsonEncode($vData)
    Local $sRes = "", $sItem, $bFirst = True
    Select
        Case IsObj($vData)
            If ObjName($vData) <> "Dictionary" Then Return SetError($CCTELEGRAM_ERR_INPUT, 0, "")
            If $vData.Exists($__CCTELEGRAM_FILEMARK) Then
                Local $sPath = $vData.Item($__CCTELEGRAM_FILEMARK)
                If $__g_bCCTelegram_Collect Then Return __CCTelegram_JsonQuote("attach://" & __CCTelegram_AddUpload("", $sPath))
                Return __CCTelegram_JsonQuote($sPath)
            EndIf
            Local $aKeys = $vData.Keys(), $vItem
            $sRes = "{"
            For $i = 0 To UBound($aKeys) - 1
                $vItem = $vData.Item($aKeys[$i])
                If IsKeyword($vItem) = 1 Then ContinueLoop
                $sItem = _CCTelegram_JsonEncode($vItem)
                If @error Then Return SetError(@error, 0, "")
                $sRes &= ($bFirst ? "" : ",") & __CCTelegram_JsonQuote(String($aKeys[$i])) & ":" & $sItem
                $bFirst = False
            Next
            Return $sRes & "}"
        Case IsArray($vData)
            $sRes = "["
            If UBound($vData, 0) = 1 Then
                For $i = 0 To UBound($vData) - 1
                    $sItem = _CCTelegram_JsonEncode($vData[$i])
                    If @error Then Return SetError(@error, 0, "")
                    $sRes &= ($i ? "," : "") & $sItem
                Next
            ElseIf UBound($vData, 0) = 2 Then
                For $r = 0 To UBound($vData, 1) - 1
                    $sRes &= ($r ? ",[" : "[")
                    For $c = 0 To UBound($vData, 2) - 1
                        $sItem = _CCTelegram_JsonEncode($vData[$r][$c])
                        If @error Then Return SetError(@error, 0, "")
                        $sRes &= ($c ? "," : "") & $sItem
                    Next
                    $sRes &= "]"
                Next
            Else
                Return SetError($CCTELEGRAM_ERR_INPUT, 0, "")
            EndIf
            Return $sRes & "]"
        Case IsKeyword($vData)
            Return "null"
        Case IsBool($vData)
            Return $vData ? "true" : "false"
        Case IsInt($vData)
            Return String($vData)
        Case IsFloat($vData)
            Return StringReplace(String($vData), ",", ".", 0, 1)
        Case IsString($vData)
            Return __CCTelegram_JsonQuote($vData)
        Case IsBinary($vData)
            Return __CCTelegram_JsonQuote(BinaryToString($vData, 4))
        Case Else
            Return SetError($CCTELEGRAM_ERR_INPUT, 0, "")
    EndSelect
EndFunc   ;==>_CCTelegram_JsonEncode

Func __CCTelegram_JsonQuote($sText)
    Local $s = StringReplace($sText, "\", "\\", 0, 1)
    $s = StringReplace($s, '"', '\"', 0, 1)
    $s = StringReplace($s, @CR, "\r", 0, 1)
    $s = StringReplace($s, @LF, "\n", 0, 1)
    $s = StringReplace($s, @TAB, "\t", 0, 1)
    If StringRegExp($s, "[\x00-\x1F]") Then
        For $i = 0 To 31
            $s = StringReplace($s, Chr($i), "\u" & Hex($i, 4), 0, 1)
        Next
    EndIf
    Return '"' & $s & '"'
EndFunc   ;==>__CCTelegram_JsonQuote

Func __CCTelegram_JsonSkipWs(ByRef $sJson, ByRef $iPos)
    Local $aM = StringRegExp($sJson, "\G[ \t\r\n]+", 1, $iPos)
    If Not @error Then $iPos = @extended
    #forceref $aM
EndFunc   ;==>__CCTelegram_JsonSkipWs

Func __CCTelegram_JsonParse(ByRef $sJson, ByRef $iPos)
    __CCTelegram_JsonSkipWs($sJson, $iPos)
    Local $vRes, $aM
    Switch AscW(StringMid($sJson, $iPos, 1))
        Case 123 ; {
            $vRes = __CCTelegram_JsonParseObject($sJson, $iPos)
            Return SetError(@error, 0, $vRes)
        Case 91 ; [
            $vRes = __CCTelegram_JsonParseArray($sJson, $iPos)
            Return SetError(@error, 0, $vRes)
        Case 34 ; "
            $vRes = __CCTelegram_JsonParseString($sJson, $iPos)
            Return SetError(@error, 0, $vRes)
        Case 116 ; t
            If StringMid($sJson, $iPos, 4) == "true" Then
                $iPos += 4
                Return True
            EndIf
        Case 102 ; f
            If StringMid($sJson, $iPos, 5) == "false" Then
                $iPos += 5
                Return False
            EndIf
        Case 110 ; n
            If StringMid($sJson, $iPos, 4) == "null" Then
                $iPos += 4
                Return Null
            EndIf
        Case 45, 48 To 57 ; - 0-9
            $aM = StringRegExp($sJson, "\G(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+\-]?\d+)?)", 1, $iPos)
            If Not @error Then
                $iPos = @extended
                Return __CCTelegram_JsonNumber($aM[0])
            EndIf
    EndSwitch
    Return SetError(1, 0, Null)
EndFunc   ;==>__CCTelegram_JsonParse

; JSON number text -> Int32/Int64/Double (exponents are evaluated explicitly)
Func __CCTelegram_JsonNumber($sNumber)
    Local $iE = StringInStr($sNumber, "e")
    If $iE = 0 Then Return Number($sNumber)
    Return Number(StringLeft($sNumber, $iE - 1)) * (10 ^ Number(StringTrimLeft($sNumber, $iE)))
EndFunc   ;==>__CCTelegram_JsonNumber

Func __CCTelegram_JsonParseObject(ByRef $sJson, ByRef $iPos)
    Local $oObj = ObjCreate("Scripting.Dictionary"), $sKey, $vValue
    $iPos += 1
    __CCTelegram_JsonSkipWs($sJson, $iPos)
    If StringMid($sJson, $iPos, 1) = "}" Then
        $iPos += 1
        Return $oObj
    EndIf
    While 1
        __CCTelegram_JsonSkipWs($sJson, $iPos)
        If StringMid($sJson, $iPos, 1) <> '"' Then Return SetError(1, 0, Null)
        $sKey = __CCTelegram_JsonParseString($sJson, $iPos)
        If @error Then Return SetError(1, 0, Null)
        __CCTelegram_JsonSkipWs($sJson, $iPos)
        If StringMid($sJson, $iPos, 1) <> ":" Then Return SetError(1, 0, Null)
        $iPos += 1
        $vValue = __CCTelegram_JsonParse($sJson, $iPos)
        If @error Then Return SetError(1, 0, Null)
        If $oObj.Exists($sKey) Then $oObj.Remove($sKey)
        $oObj.Add($sKey, $vValue)
        __CCTelegram_JsonSkipWs($sJson, $iPos)
        Switch StringMid($sJson, $iPos, 1)
            Case ","
                $iPos += 1
            Case "}"
                $iPos += 1
                Return $oObj
            Case Else
                Return SetError(1, 0, Null)
        EndSwitch
    WEnd
EndFunc   ;==>__CCTelegram_JsonParseObject

Func __CCTelegram_JsonParseArray(ByRef $sJson, ByRef $iPos)
    Local $aArr[8], $iCount = 0, $vValue
    $iPos += 1
    __CCTelegram_JsonSkipWs($sJson, $iPos)
    If StringMid($sJson, $iPos, 1) = "]" Then
        $iPos += 1
        Local $aEmpty[0]
        Return $aEmpty
    EndIf
    While 1
        $vValue = __CCTelegram_JsonParse($sJson, $iPos)
        If @error Then Return SetError(1, 0, Null)
        __CCTelegram_ArrayPush($aArr, $iCount, $vValue)
        __CCTelegram_JsonSkipWs($sJson, $iPos)
        Switch StringMid($sJson, $iPos, 1)
            Case ","
                $iPos += 1
            Case "]"
                $iPos += 1
                ReDim $aArr[$iCount]
                Return $aArr
            Case Else
                Return SetError(1, 0, Null)
        EndSwitch
    WEnd
EndFunc   ;==>__CCTelegram_JsonParseArray

Func __CCTelegram_JsonParseString(ByRef $sJson, ByRef $iPos)
    ; "unrolled loop" with possessive quantifiers: no deep backtracking on long strings
    Local $aM = StringRegExp($sJson, '(?s)\G"([^"\\]*+(?:\\.[^"\\]*+)*+)"', 1, $iPos)
    If @error Then Return SetError(1, 0, "")
    $iPos = @extended
    Return __CCTelegram_JsonUnescape($aM[0])
EndFunc   ;==>__CCTelegram_JsonParseString

Func __CCTelegram_JsonUnescape($sText)
    If Not StringInStr($sText, "\", 1) Then Return $sText
    Local $sOut = "", $iStart = 1, $iFound
    While 1
        $iFound = StringInStr($sText, "\", 1, 1, $iStart)
        If $iFound = 0 Then ExitLoop
        $sOut &= StringMid($sText, $iStart, $iFound - $iStart)
        Switch AscW(StringMid($sText, $iFound + 1, 1))
            Case 110 ; n
                $sOut &= @LF
            Case 114 ; r
                $sOut &= @CR
            Case 116 ; t
                $sOut &= @TAB
            Case 98 ; b
                $sOut &= Chr(8)
            Case 102 ; f
                $sOut &= Chr(12)
            Case 117 ; u (surrogate pairs simply become two UTF-16 code units)
                $sOut &= ChrW(Dec(StringMid($sText, $iFound + 2, 4)))
                $iStart = $iFound + 6
                ContinueLoop
            Case Else ; " \ / and any other escaped character
                $sOut &= StringMid($sText, $iFound + 1, 1)
        EndSwitch
        $iStart = $iFound + 2
    WEnd
    Return $sOut & StringMid($sText, $iStart)
EndFunc   ;==>__CCTelegram_JsonUnescape

#EndRegion "JSON"

#Region "Request engine"

; Internal: sends one API request.
;   $sJsonFields - "|name|name|": parameters of object/array type; string values are parsed as JSON
;   $sFileFields - "|name|": parameters of type InputFile; existing local paths are uploaded
Func __CCTelegram_Request($sMethod, $oParams, $sJsonFields = "", $sFileFields = "")
    __CCTelegram_ResetError()
    If $__g_sCCTelegram_Token = "" Then
        $__g_sCCTelegram_LastErrorDesc = "_CCTelegram_Init() was not called"
        Return SetError($CCTELEGRAM_ERR_NOINIT, 0, Null)
    EndIf

    Local $iCount = $oParams.Count
    Local $aName[$iCount + 1], $aJson[$iCount + 1], $aForm[$iCount + 1], $iP = 0
    Local $aKeys = $oParams.Keys(), $sKey, $vVal

    $__g_iCCTelegram_UpCount = 0
    $__g_bCCTelegram_Collect = True
    For $i = 0 To $iCount - 1
        $sKey = $aKeys[$i]
        $vVal = $oParams.Item($sKey)
        If IsKeyword($vVal) = 1 Then ContinueLoop

        ; object/array parameter passed as JSON text
        If IsString($vVal) And StringInStr($sJsonFields, "|" & $sKey & "|", 1) Then
            If StringRegExp($vVal, "^\s*[\[{]") Then
                $vVal = _CCTelegram_JsonDecode($vVal)
                If @error Then
                    $__g_bCCTelegram_Collect = False
                    $__g_sCCTelegram_LastErrorDesc = "Parameter '" & $sKey & "' is not valid JSON"
                    Return SetError($CCTELEGRAM_ERR_INPUT, $i + 1, Null)
                EndIf
            EndIf
        EndIf

        ; direct file parameter
        If StringInStr($sFileFields, "|" & $sKey & "|", 1) Then
            If __CCTelegram_IsLocalFile($vVal) Then
                __CCTelegram_AddUpload($sKey, $vVal)
                ContinueLoop
            ElseIf __CCTelegram_IsFileMarker($vVal) Then
                __CCTelegram_AddUpload($sKey, $vVal.Item($__CCTELEGRAM_FILEMARK))
                ContinueLoop
            ElseIf __CCTelegram_LooksLikePath($vVal) Then
                $__g_bCCTelegram_Collect = False
                $__g_sCCTelegram_LastErrorDesc = "File not found: " & $vVal
                Return SetError($CCTELEGRAM_ERR_FILE, $i + 1, Null)
            EndIf
        EndIf

        $aName[$iP] = $sKey
        $aJson[$iP] = _CCTelegram_JsonEncode($vVal)
        If @error Then
            $__g_bCCTelegram_Collect = False
            $__g_sCCTelegram_LastErrorDesc = "Parameter '" & $sKey & "' has an unsupported type"
            Return SetError($CCTELEGRAM_ERR_INPUT, $i + 1, Null)
        EndIf
        If IsString($vVal) Then
            $aForm[$iP] = $vVal
        ElseIf IsBool($vVal) Then
            $aForm[$iP] = $vVal ? "true" : "false"
        Else
            $aForm[$iP] = $aJson[$iP]
        EndIf
        $iP += 1
    Next
    $__g_bCCTelegram_Collect = False

    ; build the body
    Local $bBody, $sContentType = ""
    If $__g_iCCTelegram_UpCount > 0 Then
        $bBody = __CCTelegram_Multipart($aName, $aForm, $iP, $sContentType)
        If @error Then Return SetError($CCTELEGRAM_ERR_FILE, 0, Null)
        If $__g_bCCTelegram_Debug Then ConsoleWrite("[CCTelegram] -> " & $sMethod & " (multipart, " & $__g_iCCTelegram_UpCount & " file(s), " & BinaryLen($bBody) & " bytes)" & @CRLF)
    Else
        Local $sBody = "{"
        For $i = 0 To $iP - 1
            $sBody &= ($i ? "," : "") & __CCTelegram_JsonQuote($aName[$i]) & ":" & $aJson[$i]
        Next
        $sBody &= "}"
        $bBody = StringToBinary($sBody, 4)
        $sContentType = "application/json; charset=utf-8"
        If $__g_bCCTelegram_Debug Then ConsoleWrite("[CCTelegram] -> " & $sMethod & " " & StringLeft($sBody, 1000) & @CRLF)
    EndIf

    ; long polling needs a longer receive timeout
    Local $iRecv = $__g_aCCTelegram_Timeouts[3]
    If $sMethod = "getUpdates" And $oParams.Exists("timeout") Then
        Local $iLong = Int($oParams.Item("timeout")) * 1000 + 15000
        If $iLong > $iRecv Then $iRecv = $iLong
    EndIf

    Local $sUrl = $__g_sCCTelegram_ApiBase & "/bot" & $__g_sCCTelegram_Token & "/" & $sMethod
    Local $iTry = 0, $iStatus, $bResp, $sResp, $oResp, $iErr
    While 1
        $iStatus = 0
        $bResp = __CCTelegram_Http("POST", $sUrl, $bBody, $sContentType, $iRecv, $iStatus)
        $iErr = @error
        If $iErr Then
            $__g_sCCTelegram_LastErrorDesc = "Transport error: " & $__g_sCCTelegram_ComErrDesc & " (0x" & Hex($__g_iCCTelegram_ComErrNumber, 8) & ")"
            If $__g_bCCTelegram_Debug Then ConsoleWrite("[CCTelegram] <- " & $__g_sCCTelegram_LastErrorDesc & @CRLF)
            Return SetError($CCTELEGRAM_ERR_TRANSPORT, $__g_iCCTelegram_ComErrNumber, Null)
        EndIf
        $__g_iCCTelegram_LastHttpStatus = $iStatus
        $sResp = BinaryToString($bResp, 4)
        $__g_sCCTelegram_LastResponse = $sResp
        If $__g_bCCTelegram_Debug Then ConsoleWrite("[CCTelegram] <- HTTP " & $iStatus & " " & StringLeft($sResp, 1000) & @CRLF)

        $oResp = _CCTelegram_JsonDecode($sResp)
        If @error Or Not __CCTelegram_IsDict($oResp) Then
            $__g_sCCTelegram_LastErrorDesc = "No valid JSON answer (HTTP " & $iStatus & ")"
            If $iStatus >= 200 And $iStatus < 300 Then Return SetError($CCTELEGRAM_ERR_JSON, $iStatus, Null)
            Return SetError($CCTELEGRAM_ERR_HTTP, $iStatus, Null)
        EndIf

        If _CCTelegram_Get($oResp, "ok", False) = True Then
            Local $vResult = _CCTelegram_Get($oResp, "result", Null)
            Return SetError(0, $iStatus, $vResult)
        EndIf

        $__g_iCCTelegram_LastErrorCode = Int(_CCTelegram_Get($oResp, "error_code", $iStatus))
        $__g_sCCTelegram_LastErrorDesc = String(_CCTelegram_Get($oResp, "description", "Unknown error"))
        $__g_iCCTelegram_LastRetryAfter = Int(_CCTelegram_Get($oResp, "parameters.retry_after", 0))
        $__g_vCCTelegram_LastMigrateTo = _CCTelegram_Get($oResp, "parameters.migrate_to_chat_id", 0)

        If $__g_iCCTelegram_LastErrorCode = 429 And $iTry < $__g_iCCTelegram_MaxRetries And $__g_iCCTelegram_LastRetryAfter > 0 _
                And $__g_iCCTelegram_LastRetryAfter <= $__g_iCCTelegram_MaxRetryWait Then
            $iTry += 1
            If $__g_bCCTelegram_Debug Then ConsoleWrite("[CCTelegram] flood control, retry " & $iTry & " in " & $__g_iCCTelegram_LastRetryAfter & " s" & @CRLF)
            Sleep($__g_iCCTelegram_LastRetryAfter * 1000 + 250)
            ContinueLoop
        EndIf
        Return SetError($CCTELEGRAM_ERR_API, $__g_iCCTelegram_LastErrorCode, Null)
    WEnd
EndFunc   ;==>__CCTelegram_Request

; Internal: registers a file for upload, returns the multipart field name
Func __CCTelegram_AddUpload($sName, $sPath)
    If $sName = "" Then $sName = "file" & ($__g_iCCTelegram_UpCount + 1)
    If $__g_iCCTelegram_UpCount >= UBound($__g_aCCTelegram_UpName) Then
        ReDim $__g_aCCTelegram_UpName[$__g_iCCTelegram_UpCount * 2]
        ReDim $__g_aCCTelegram_UpPath[$__g_iCCTelegram_UpCount * 2]
    EndIf
    $__g_aCCTelegram_UpName[$__g_iCCTelegram_UpCount] = $sName
    $__g_aCCTelegram_UpPath[$__g_iCCTelegram_UpCount] = $sPath
    $__g_iCCTelegram_UpCount += 1
    Return $sName
EndFunc   ;==>__CCTelegram_AddUpload

; Internal: builds a multipart/form-data body from the collected parameters and files
Func __CCTelegram_Multipart(ByRef $aName, ByRef $aForm, $iCount, ByRef $sContentType)
    Local $sBoundary = "----CCTelegramUDF" & Hex(Random(0, 2147483647, 1), 8) & Hex(Random(0, 2147483647, 1), 8)
    Local $bBody = Binary(""), $hFile, $bData, $sFileName
    $sContentType = "multipart/form-data; boundary=" & $sBoundary
    For $i = 0 To $iCount - 1
        $bBody = $bBody & StringToBinary("--" & $sBoundary & @CRLF & 'Content-Disposition: form-data; name="' & $aName[$i] & '"' & @CRLF & @CRLF & $aForm[$i] & @CRLF, 4)
    Next
    For $i = 0 To $__g_iCCTelegram_UpCount - 1
        $hFile = FileOpen($__g_aCCTelegram_UpPath[$i], 16)
        If $hFile = -1 Then
            $__g_sCCTelegram_LastErrorDesc = "Cannot read file: " & $__g_aCCTelegram_UpPath[$i]
            Return SetError(1, $i, Binary(""))
        EndIf
        $bData = FileRead($hFile)
        FileClose($hFile)
        If Not IsBinary($bData) Then $bData = Binary($bData)
        $sFileName = StringReplace(StringRegExpReplace($__g_aCCTelegram_UpPath[$i], "^.*[\\/]", ""), '"', "'", 0, 1)
        $bBody = $bBody & StringToBinary("--" & $sBoundary & @CRLF & 'Content-Disposition: form-data; name="' & $__g_aCCTelegram_UpName[$i] & '"; filename="' & $sFileName & '"' & @CRLF & _
                "Content-Type: " & __CCTelegram_MimeType($sFileName) & @CRLF & @CRLF, 4) & $bData & StringToBinary(@CRLF, 4)
    Next
    Return $bBody & StringToBinary("--" & $sBoundary & "--" & @CRLF, 4)
EndFunc   ;==>__CCTelegram_Multipart

Func __CCTelegram_MimeType($sFileName)
    Switch StringLower(StringRegExpReplace($sFileName, "^.*\.", ""))
        Case "jpg", "jpeg"
            Return "image/jpeg"
        Case "png"
            Return "image/png"
        Case "gif"
            Return "image/gif"
        Case "webp"
            Return "image/webp"
        Case "mp4"
            Return "video/mp4"
        Case "webm"
            Return "video/webm"
        Case "mov"
            Return "video/quicktime"
        Case "mp3"
            Return "audio/mpeg"
        Case "m4a"
            Return "audio/mp4"
        Case "ogg", "oga"
            Return "audio/ogg"
        Case "pdf"
            Return "application/pdf"
        Case "txt", "log"
            Return "text/plain"
        Case "tgs"
            Return "application/x-tgsticker"
    EndSwitch
    Return "application/octet-stream"
EndFunc   ;==>__CCTelegram_MimeType

; Internal: one HTTP request via WinHttpRequest with a local COM error handler.
; Returns the response body as Binary; @error <> 0 on transport errors (details in $__g_sCCTelegram_ComErrDesc).
Func __CCTelegram_Http($sVerb, $sUrl, $bBody, $sContentType, $iRecvTimeout, ByRef $iStatus)
    Local $oComErr = ObjEvent("AutoIt.Error", "__CCTelegram_ComError")
    #forceref $oComErr
    $__g_iCCTelegram_ComErrNumber = 0
    $__g_sCCTelegram_ComErrDesc = ""
    Local $oHttp = ObjCreate("WinHttp.WinHttpRequest.5.1")
    If @error Or Not IsObj($oHttp) Then
        $__g_sCCTelegram_ComErrDesc = "WinHttp.WinHttpRequest.5.1 not available"
        Return SetError(1, 0, Binary(""))
    EndIf
    $oHttp.SetTimeouts($__g_aCCTelegram_Timeouts[0], $__g_aCCTelegram_Timeouts[1], $__g_aCCTelegram_Timeouts[2], $iRecvTimeout)
    If $__g_sCCTelegram_Proxy <> "" Then
        If $__g_sCCTelegram_ProxyBypass <> "" Then
            $oHttp.SetProxy(2, $__g_sCCTelegram_Proxy, $__g_sCCTelegram_ProxyBypass)
        Else
            $oHttp.SetProxy(2, $__g_sCCTelegram_Proxy)
        EndIf
        If @error Then Return SetError(2, 0, Binary(""))
    EndIf
    $oHttp.Open($sVerb, $sUrl, False)
    If @error Then Return SetError(3, 0, Binary(""))
    If $__g_sCCTelegram_Proxy <> "" And $__g_sCCTelegram_ProxyUser <> "" Then $oHttp.SetCredentials($__g_sCCTelegram_ProxyUser, $__g_sCCTelegram_ProxyPass, 1)
    If $sContentType <> "" Then $oHttp.SetRequestHeader("Content-Type", $sContentType)
    $oHttp.SetRequestHeader("User-Agent", "CCTelegramUDF/" & $CCTELEGRAM_VERSION & " (AutoIt " & @AutoItVersion & ")")
    If IsBinary($bBody) And BinaryLen($bBody) > 0 Then
        $oHttp.Send($bBody)
    Else
        $oHttp.Send()
    EndIf
    If @error Then Return SetError(4, 0, Binary(""))
    $iStatus = $oHttp.Status
    Local $bResp = $oHttp.ResponseBody
    If @error Then Return SetError(5, 0, Binary(""))
    If Not IsBinary($bResp) Then $bResp = Binary($bResp)
    Return $bResp
EndFunc   ;==>__CCTelegram_Http

Func __CCTelegram_ComError($oError)
    $__g_iCCTelegram_ComErrNumber = $oError.number
    ; for WinHttp errors .windescription only says "exception occurred" (0x80020009); the real cause is in .description
    $__g_sCCTelegram_ComErrDesc = StringStripWS($oError.description, 3)
    If $__g_sCCTelegram_ComErrDesc = "" Then $__g_sCCTelegram_ComErrDesc = StringStripWS($oError.windescription, 3)
EndFunc   ;==>__CCTelegram_ComError

#EndRegion "Request engine"

; All Bot API methods (generated)
#include "CCTelegramUDF_Methods.au3"
