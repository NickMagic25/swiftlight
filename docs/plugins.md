# Mac stream plugins

Swiftlight can run user-defined scripts when a Mac stream starts or ends. Plugins are configured in **Swiftlight → Settings → Plugins**. This feature is exclusive to macOS.

## Install and configure

1. Choose a local YAML file, enter its absolute path, or paste an HTTPS URL. A GitHub file page (`https://github.com/owner/repo/blob/ref/plugin.yaml`) also works. For a sandboxed build, use **Choose YAML File…** if typing a local path does not grant access.
2. Select **Import**. Swiftlight keeps a local copy; importing never executes scripts.
3. Fill in the fields supplied by the plugin and select **Save Configuration**. Password-style fields are stored in the login Keychain separately from the saved configuration.
4. Expand **Review YAML and Scripts**, inspect the source, and enable the plugin. Enable only code you trust: scripts receive your configured fields and the current computer/application identity.

Plugins are disabled when first imported or explicitly refreshed. They do not update automatically. **Refresh** reads the source again, replaces the cached copy and disables the plugin for another review. Local file edits also require a refresh. Changes made during a stream apply to the next stream; the current session keeps its original configuration for both start and end actions.

## Events and filters

| Event | When it runs |
| --- | --- |
| `stream.started` | Once, when the connection produces decoded output and enters the streaming state. This is not a physical display/scanout measurement. |
| `stream.ended` | Once, after an established stream's transport and decoder teardown finishes, including disconnect, failure, reconnect, sleep and normal app shutdown. |

An attempt that fails before streaming produces neither event. A force quit, crash or power loss cannot guarantee an end action. Scripts are asynchronous: they do not block stream connection or teardown, and a start script can still be running when the stream ends. Matching actions execute serially in installation order, then hook order; the old session's end is queued before a reconnected session's start.

Omit filters to match any computer/application. Add `host_id` to match a particular computer, and `app_id` or `app_name` to match a game. All supplied filters must match exactly, including name capitalization. Computer IDs are shown in Plugin settings. Application IDs are assigned by Sunshine/Apollo; use a name if you do not know its ID. Put several hooks in a plugin to describe several matches. Matching hooks each run once; overlapping hooks deliberately produce multiple actions.

## Write a plugin

See the ready-to-import [Home Assistant webhook example](examples/plugins/home_assistant.yaml) and [VirtualHere launch example](examples/plugins/virtual_here.yaml). Each file describes one plugin. Scripts are embedded in the YAML so the reviewed copy includes the executable code.

```yaml
schema_version: 1
id: game_scene
name: Game Scene
description: Activate a scene for one game on one computer.
fields:
  - id: start_url
    label: Start webhook URL
    type: secret
    required: true
hooks:
  - event: stream.started
    host_id: "replace-with-computer-id"
    app_name: "Your Game"
    runtime: bash
    timeout_seconds: 15
    script: |
      set -eu
      /usr/bin/curl --fail --silent --show-error --max-time 10 \
        --proto '=http,https' --request POST "$SWIFTLIGHT_FIELD_START_URL"
```

`id` and field IDs use lowercase letters, digits and underscores, beginning with a letter. `schema_version`, `id`, `name` and `hooks` are required. Plugin/field descriptions and `fields` are optional. Each hook requires `event`, `runtime` and `script`; `timeout_seconds` defaults to 30 and accepts 1–300. Filters are optional. Unknown keys, duplicate keys, YAML aliases/anchors and custom tags are rejected.

Fields use `id`, `label`, `type`, optional `description`, `required` (defaults to false) and `default`. Quote all defaults, including `"true"` and `"42"`.

| Type | Settings control | Value |
| --- | --- | --- |
| `string` | Text field | Text |
| `secret` | Secure text field | Text stored in Keychain; defaults are prohibited |
| `boolean` | Toggle | `true` or `false` |
| `integer` | Text field with validation | Decimal signed 64-bit integer |
| `choice` | Picker | One of the strings in a required `options` list |

Scripts receive fields as environment variables: field `start_url` becomes `SWIFTLIGHT_FIELD_START_URL`. Optional empty fields may be absent; handle that in your script. Fields are never substituted into script source. Quote shell variables and treat values as data in your plugin.

| Context variable | Value |
| --- | --- |
| `SWIFTLIGHT_EVENT` | `stream.started` or `stream.ended` |
| `SWIFTLIGHT_SESSION_ID` | Stable random ID shared by the session's two events |
| `SWIFTLIGHT_HOST_ID`, `SWIFTLIGHT_HOST_NAME` | Computer identity and display name |
| `SWIFTLIGHT_APP_ID`, `SWIFTLIGHT_APP_NAME` | Application identity and display name |
| `SWIFTLIGHT_END_REASON` | Empty at start; `disconnected`, `reconnect`, `network_lost`, `host_terminated`, `connection_failed`, `video_failed`, `sleep` or `shutdown` at end |

These values are given to the enabled plugin locally. They are not added to Swiftlight's stream diagnostic exports. Plugin stdout/stderr are discarded, and settings show safe completion/failure categories. A plugin can itself transmit or record the data it receives, so review its behavior before enabling it.

## Bash, Python and Swift

`runtime: bash` uses `/bin/bash`. `runtime: python` uses the **Python executable** path in settings; `runtime: swift` uses **Swift executable**. Swiftlight selects an available direct interpreter from the usual Xcode/Command Line Tools locations. Python and Swift are not bundled: install the runtime/toolchain you need and configure an absolute path accessible to the app. The `/usr/bin/python3` and `/usr/bin/swift` developer-tool shims cannot run inside App Sandbox and are rejected when enabling a plugin. Swift runs script source through the interpreter, so compilation counts toward the hook timeout.

For a standard Xcode installation, direct paths are `/Applications/Xcode.app/Contents/Developer/usr/bin/python3` and `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift`. Swiftlight locates the macOS SDK beside the selected Xcode toolchain or in Command Line Tools, and passes it directly to the compiler. A custom interpreter/toolchain must have accessible libraries and a discoverable macOS SDK. An executable that works in Terminal may still be restricted by App Sandbox; Homebrew Python was blocked in the signed sandbox probe recorded in the [validation notes](dev/plugins-validation-2026-10-04.md).

Python reads fields with `os.environ["SWIFTLIGHT_FIELD_START_URL"]`; Swift reads them with `ProcessInfo.processInfo.environment["SWIFTLIGHT_FIELD_START_URL"]` after `import Foundation`. The runner supplies a small environment and system `PATH`; use absolute paths for other executables. Its working directory is a disposable private temporary directory. It does not inherit your interactive shell configuration.

Swiftlight's primary Mac app uses App Sandbox. Plugin child processes inherit its restrictions; a script cannot grant itself additional file, USB, automation, administrator or service-control access. HTTPS/network actions can use the app's existing network entitlement, subject to the destination's authentication and network availability. Scripts cannot be used as a sandbox escape. See [Apple's child-process documentation](https://developer.apple.com/documentation/foundation/process).

The VirtualHere example requests that macOS launch an already installed server application. It does not install VirtualHere, approve USB permissions, validate server readiness or guarantee that the sandbox permits the application's operation. Those checks must be made on the actual Mac. Scripts are short-lived hooks: background descendants in the hook's process group are stopped when the hook exits or times out. For a persistent service, use a separately installed application/service and request that it start; do not background a server directly in a hook.

## Limits and failures

Swiftlight accepts at most 16 installed plugins, 32 fields and 16 hooks per plugin, 256 KiB per YAML file, and 64 KiB per script. Each field value is limited to 4 KiB; the combined configuration is limited to 64 KiB. The runner admits at most 64 queued/active actions. A full queue rejects that event's batch with a status message. A timed-out action stops its process group and later actions continue.

Normal app shutdown allows queued actions up to five seconds to finish, then cancels the remaining work. End actions should be brief and tolerate retries or missing events. Sleep can suspend execution before an action finishes. Plugin failures do not stop a stream. Check Plugin settings for results, and use independently tested scripts for actions whose success matters.
