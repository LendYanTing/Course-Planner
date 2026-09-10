# Release signing (Android)

`flutter build apk --release` / `appbundle` are signed with the key described by
`android/key.properties`. **That file is gitignored and must never be committed**
together with the keystore.

If `key.properties` is absent, the release build falls back to the debug key so
local builds still work — the resulting APK is only for testing and cannot be
uploaded to a store or used to update an installed release.

## 1. Create the keystore (once)

One line — works in **PowerShell, cmd and bash** alike (no line continuation to
get wrong):

```powershell
keytool -genkeypair -v -keystore "$env:USERPROFILE\keys\course-planner-upload.jks" -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

If you prefer a multi-line command, PowerShell continues lines with a backtick
(`` ` ``) — **not** a backslash, which is bash syntax and fails in PowerShell:

```powershell
keytool -genkeypair -v `
  -keystore "$env:USERPROFILE\keys\course-planner-upload.jks" `
  -storetype PKCS12 `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -alias upload
```

bash equivalent, for reference:

```bash
keytool -genkeypair -v \
  -keystore ~/keys/course-planner-upload.jks \
  -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

`keytool` then prompts for the passwords and the certificate fields:

| Field | What it is | Suggested value / notes |
| --- | --- | --- |
| Keystore password | Protects the `.jks` file | Long and random; **store it in a password manager** |
| `keyPassword` (Enter = same) | Protects the private key | Press Enter to reuse the keystore password |
| `CN` (名字与姓氏) | Common Name | Your name or the app name, e.g. `Course Planner` |
| `OU` (组织单位名称) | Organisational unit | Optional, e.g. `Dev` |
| `O` (组织名称) | Organisation | Your name / company, e.g. `Trysting` |
| `L` (城市或区域名称) | City | e.g. `Urumqi` |
| `ST` (省/市/自治区名称) | State/Province | e.g. `Xinjiang` |
| `C` (双字母国家/地区代码) | ISO country code | `CN` |

Only `CN` really shows up in the certificate; the rest are organisational. The
**password and the `.jks` file are the irreplaceable parts**: lose them and you
can never ship an update to an app installed from that key (the store will
reject a different signature).

For Play Store uploads Google now prefers **Play App Signing**: you upload an
"upload key" and Google manages the real signing key. Same steps — just treat
this keystore as the upload key.

## 2. Point the build at it

Create `android/key.properties` (copy `key.properties.example`):

```properties
storePassword=<keystore password>
keyPassword=<key password>
keyAlias=upload
storeFile=/absolute/path/to/course-planner-upload.jks
```

`storeFile` accepts an absolute path (forward slashes work on Windows) or a path
relative to `android/app/`. **It must point at the `.jks` you just created** — the
placeholder from the example file does not exist and the build will fail with a
keystore error.

## 3. Build

```bash
flutter build apk --release            # fat APK, all ABIs
flutter build apk --release --split-per-abi   # smaller per-ABI APKs
flutter build appbundle --release     # .aab for Play Store
```

Verify what actually signed it:

```bash
$ANDROID_HOME/build-tools/<ver>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

The `certificate DN` must be yours — if it says `CN=Android Debug`, the build
did not pick up `key.properties`.
