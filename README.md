# CCTelegramUDF

A complete Telegram Bot API library for [AutoIt](https://www.autoitscript.com/). Send messages, photos, documents and
albums, build keyboards, receive messages with long polling and download files – with every method of the
[Telegram Bot API](https://core.telegram.org/bots/api) available as an AutoIt function.

CCTelegramUDF also replaces the popular
[xLinkOut/telegram-udf-autoit](https://github.com/xLinkOut/telegram-udf-autoit): two compatibility layers let existing
scripts – written for its release v0.1 or for its 2024 rewrite – run unchanged on the new library.

## Features

- **All 194 methods of Bot API 10.5** (November 2026), generated from the official documentation; a new API version is
  picked up by re-running one script
- **Correct transport**: requests are sent as UTF-8 JSON, so `&`, `#`, `+`, `%`, umlauts and emoji arrive unchanged
- **File uploads** from local paths, URLs or `file_id`s – also inside albums (media groups) and stickers
- **Robust**: one HTTP stack (WinHttp, built into Windows) with timeouts and proxy support; a lost connection returns
  an error instead of crashing the script
- **Real error information**: Telegram error code and description after every call, automatic retry on flood control
  (HTTP 429)
- **No dependencies, no machine code**: own JSON parser/encoder in pure AutoIt
- Helpers for long polling, inline and reply keyboards, file download, MarkdownV2/HTML escaping
- **Drop-in compatibility** for scripts written for xLinkOut/telegram-udf-autoit (v0.1 and 2024)

## Requirements

- AutoIt 3.3.14.0 or newer (3.3.16.1 recommended), Windows 7 or newer
- A bot token from [@BotFather](https://t.me/BotFather)
- Save scripts as **UTF-8 with BOM** (SciTE default) if they contain non-ASCII text

## Quick start

Copy `CCTelegramUDF.au3` and `CCTelegramUDF_Methods.au3` next to your script:

```autoit
#include "CCTelegramUDF.au3"

_CCTelegram_Init("123456:ABC-your-token", True)          ; True = check the token with getMe

Local $oMsg = _CCTelegram_SendMessage(123456789, "Hallo & willkommen! 🤖")
If @error Then ConsoleWrite("Error: " & _CCTelegram_LastErrorDescription() & @CRLF)

; receive messages (long polling) and answer them
While 1
    Local $aUpdates = _CCTelegram_Poll(30)
    If @error Then
        Sleep(5000) ; e.g. no internet - try again later
        ContinueLoop
    EndIf
    For $i = 0 To UBound($aUpdates) - 1
        If _CCTelegram_UpdateType($aUpdates[$i]) = "message" Then
            _CCTelegram_SendMessage(_CCTelegram_Get($aUpdates[$i], "message.chat.id"), _
                    "Echo: " & _CCTelegram_Get($aUpdates[$i], "message.text", ""))
        EndIf
    Next
WEnd
```

A complete example bot (commands, keyboards, button clicks, file download) is in
[examples/EchoBot.au3](examples/EchoBot.au3).

## Usage

### Calling convention

Every API method `methodName` is available as `_CCTelegram_MethodName(...)`:

- **Positional parameters**, in the order of the Telegram documentation: all *required* parameters, plus `chat_id`
  (if the method has one) and `message_id` (if the method has `chat_id` and `message_id`). Positional parameters that
  are optional in the API accept `Default`.
- **Last parameter `$vOpt`**: all other parameters, as a Dictionary built with `_CCTelegram_Obj(key, value, ...)` or as
  a JSON object string.

```autoit
_CCTelegram_SendMessage($iChat, "<b>fett</b>", _CCTelegram_Obj("parse_mode", "HTML", "disable_notification", True))
_CCTelegram_SendMessage($iChat, "*fett*", '{"parse_mode":"MarkdownV2"}')
_CCTelegram_EditMessageText($iChat, $iMessageId, _CCTelegram_Obj("text", "neuer Text"))
_CCTelegram_SendPoll($iChat, "Pizza?", _CCTelegram_Arr(_CCTelegram_Obj("text", "Ja"), _CCTelegram_Obj("text", "Nein")))
_CCTelegram_Call("anyNewerMethod", _CCTelegram_Obj("chat_id", $iChat))   ; methods newer than the generated file
```

Each function header in `CCTelegramUDF_Methods.au3` lists the positional and optional parameters with their types
and links to the official documentation.

### Files

A file parameter (`photo`, `document`, `audio`, `video`, `sticker`, `thumbnail`, …) accepts a local path (uploaded),
an HTTP URL or a `file_id`. Inside nested objects use `_CCTelegram_InputMedia()` or `_CCTelegram_File()`:

```autoit
_CCTelegram_SendPhoto($iChat, "C:\Bilder\foto.jpg", _CCTelegram_Obj("caption", "Upload"))

Local $aAlbum[2] = [_CCTelegram_InputMedia("photo", "C:\Bilder\a.jpg", _CCTelegram_Obj("caption", "Album")), _
                    _CCTelegram_InputMedia("photo", "C:\Bilder\b.jpg")]
_CCTelegram_SendMediaGroup($iChat, $aAlbum)

_CCTelegram_DownloadFile($sFileId, @ScriptDir & "\downloads\")   ; getFile + download
```

### Keyboards

```autoit
Local $aKb[2][2]
$aKb[0][0] = _CCTelegram_InlineButton("Ja", "yes")
$aKb[0][1] = _CCTelegram_InlineButton("Nein", "no")
$aKb[1][0] = _CCTelegram_UrlButton("Website", "https://example.com")
_CCTelegram_SendMessage($iChat, "Frage?", _CCTelegram_Obj("reply_markup", _CCTelegram_InlineKeyboard($aKb)))

; in the update loop: always answer button clicks, otherwise the button keeps spinning
_CCTelegram_AnswerCallbackQuery(_CCTelegram_Get($oCallback, "id"), _CCTelegram_Obj("text", "Danke"))
```

Rows can be given as a 2D array, as an array of row arrays, or as a 1D array with `""` as row separator.

### Return values and errors

On success a function returns the `result` of the Telegram answer – a Dictionary (object), an AutoIt array, a Boolean,
a number or a string. Read nested values with `_CCTelegram_Get($vResult, "chat.id")` or
`_CCTelegram_Get($vResult, "photo[0].file_id")`.

On failure it returns `Null` and sets `@error`:

| `@error` | Meaning | `@extended` |
|---|---|---|
| `$CCTELEGRAM_ERR_NOINIT` (1) | `_CCTelegram_Init` not called | – |
| `$CCTELEGRAM_ERR_INPUT` (2) | invalid parameter (e.g. broken JSON) | index of the parameter |
| `$CCTELEGRAM_ERR_TRANSPORT` (3) | network error (no connection, DNS, timeout, proxy, TLS) | COM error number |
| `$CCTELEGRAM_ERR_HTTP` (4) | HTTP error without a Telegram answer | HTTP status |
| `$CCTELEGRAM_ERR_JSON` (5) | answer is not valid JSON | HTTP status |
| `$CCTELEGRAM_ERR_API` (6) | Telegram rejected the call | Telegram error code |
| `$CCTELEGRAM_ERR_FILE` (7) | local file missing / not readable / not writable | – |

Details of the last call: `_CCTelegram_LastErrorCode()`, `_CCTelegram_LastErrorDescription()`,
`_CCTelegram_LastRetryAfter()`, `_CCTelegram_LastMigrateToChatId()`, `_CCTelegram_LastHttpStatus()`,
`_CCTelegram_LastResponse()`.

### Helpers

| Function | Purpose |
|---|---|
| `_CCTelegram_Init($sToken[, $bValidate[, $sApiBase]])` | token, optional check, optional local Bot API server |
| `_CCTelegram_SetProxy`, `_CCTelegram_SetTimeouts`, `_CCTelegram_SetRetry`, `_CCTelegram_SetDebug` | configuration |
| `_CCTelegram_Call($sMethod[, $vParams])` | any method by name |
| `_CCTelegram_Poll([$iTimeout[, $vAllowed[, $iLimit]]])` | long polling with automatic offset (`_CCTelegram_GetOffset` / `_CCTelegram_SetOffset`) |
| `_CCTelegram_UpdateType`, `_CCTelegram_Get` | evaluate updates and results |
| `_CCTelegram_Obj`, `_CCTelegram_Arr`, `_CCTelegram_File`, `_CCTelegram_InputMedia` | build parameters |
| `_CCTelegram_DownloadFile($sFileId, $sDest)` | download a received file |
| `_CCTelegram_InlineButton`, `_CCTelegram_UrlButton`, `_CCTelegram_InlineKeyboard`, `_CCTelegram_ReplyKeyboard`, `_CCTelegram_ReplyKeyboardRemove`, `_CCTelegram_ForceReply` | keyboards |
| `_CCTelegram_EscapeMarkdownV2`, `_CCTelegram_EscapeHtml` | escape user text for `parse_mode` |
| `_CCTelegram_UrlEncode`, `_CCTelegram_UrlDecode`, `_CCTelegram_JsonEncode`, `_CCTelegram_JsonDecode` | encoding |

## Migrating from xLinkOut/telegram-udf-autoit

The old UDF exists in two incompatible generations, and there is a compatibility layer for each. A script uses only one
of them.

| Old version | Typical calls | Compatibility file |
|---|---|---|
| release v0.1 (2017–2023) | `_InitBot`, `_SendMsg`, `_Polling`, `$msgData[5]` | [compat/Telegram.au3](compat/Telegram.au3) |
| 2024 rewrite | `_Telegram_Init`, `_Telegram_SendMessage`, `Json_Get(...)` | [compat/Telegram2024.au3](compat/Telegram2024.au3) |

1. Copy `CCTelegramUDF.au3`, `CCTelegramUDF_Methods.au3` and the matching compatibility file into the folder of your
   old `Telegram.au3`.
   - v0.1: overwrite the old `Telegram.au3` with `compat\Telegram.au3` – scripts stay unchanged.
   - 2024: change `#include "Telegram.au3"` to `#include "Telegram2024.au3"` (or rename the file to `Telegram.au3`).
2. Keep `include\JSON.au3` and `include\BinaryCall.au3` of the old UDF – old scripts use `Json_Get()`, and
   CCTelegramUDF returns the same object model. `WinHttp.au3`, `WinHttpConstants.au3` and `Base64.au3` are no longer
   needed.

Function names, parameters, global variables, constants and return values stay the same. Behaviour changes are bug
fixes of the old UDF: special characters arrive correctly, polling no longer crashes on network errors or group
events, media functions and albums work and return the right `file_id`s, keyboards produce valid JSON. `%XX`
sequences in texts (e.g. `$BOT_CRLF`) are still decoded as before; set `$TG_COMPAT_URLDECODE = False` to send texts
literally. The complete list of differences is in the header of each compatibility file. New code can use the
`_CCTelegram_*` functions in the same script.

## Updating to a new Bot API version

`CCTelegramUDF_Methods.au3` is generated from the machine-readable specification
[PaulSonOfLars/telegram-bot-api-spec](https://github.com/PaulSonOfLars/telegram-bot-api-spec):

```text
git clone --depth 1 https://github.com/PaulSonOfLars/telegram-bot-api-spec spec
python tools\gen_methods.py spec\api.json CCTelegramUDF_Methods.au3
```

Then run the offline tests. If Telegram makes a parameter required or optional, the positional parameters of that
function can change – check the diff of `CCTelegramUDF_Methods.au3`.

## Tests

| File | Purpose |
|---|---|
| `tests\CCTelegramUDF_OfflineTests.au3` | JSON, keyboards, encoding, parameter checks – no network, no token |
| `tests\CCTelegramUDF_OnlineTests.au3` | against a test bot (copy `tests\config.example.ini` to `config.ini` first) |
| `tests\CompatV01_OnlineTests.au3`, `tests\Compat2024_OnlineTests.au3` | the compatibility layers (see the header of the files) |

## Repository layout

| Path | Content |
|---|---|
| `CCTelegramUDF.au3` | the library – include only this file |
| `CCTelegramUDF_Methods.au3` | all Bot API methods (generated, included by `CCTelegramUDF.au3`) |
| `compat\` | compatibility layers for xLinkOut/telegram-udf-autoit |
| `examples\` | example bot |
| `tests\` | offline and online tests, test media |
| `tools\gen_methods.py` | generator for `CCTelegramUDF_Methods.au3` |

## Not included

- A webhook *server*: receiving updates via `setWebhook` needs a public HTTPS server; with AutoIt use
  `_CCTelegram_Poll`. The webhook methods themselves (`setWebhook`, `deleteWebhook`, `getWebhookInfo`) are available.
- Telegram Passport decryption and Mini App data validation.

## License

GPL-3.0-or-later with an additional attribution term according to section 7(b) of the GPLv3 – see
[LICENSE.txt](LICENSE.txt) and [NOTICE.txt](NOTICE.txt). In short: use, change and share it freely; keep the author
attribution "CCTelegramUDF by Markus Debus, CITRO Computer"; distribute changes under the same license.

The idea of an AutoIt Telegram UDF comes from
[xLinkOut/telegram-udf-autoit](https://github.com/xLinkOut/telegram-udf-autoit) by Luca (MIT License). The code of
this project is an independent, from-scratch implementation – no source code of that project was copied; the
compatibility layers re-implement its public interface. The method definitions are generated from
[PaulSonOfLars/telegram-bot-api-spec](https://github.com/PaulSonOfLars/telegram-bot-api-spec) (MIT License).
Telegram is a trademark of its owner; this project is not affiliated with Telegram.

Large parts of the code were developed together with Claude (Anthropic) as a coding assistant.
