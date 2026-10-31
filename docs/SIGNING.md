# Signing and notarizing Duette

This is the one-time setup that lets GitHub Actions build a Duette installer that a Mac opens without a warning. You do it once, without a Mac, from any Linux or Windows (WSL) terminal. It takes about 30 minutes, most of it clicking through Apple's websites.

Until the secrets exist, every build still works. The installer is just unsigned, and a Mac asks you to confirm before opening it.

## What you are making

Apple wants three things before a Mac opens an installer without complaining:

1. The app and the audio driver inside it are signed with a **Developer ID Application** certificate.
2. The installer itself is signed with a **Developer ID Installer** certificate.
3. Apple has scanned the installer and stamped it (notarization). This needs an **App Store Connect API key**.

You end up with seven values stored as GitHub repo secrets:

| Secret | What it is |
|---|---|
| `MACOS_CERT_APP_P12_BASE64` | The Application certificate and its private key, as a `.p12` file, base64 encoded |
| `MACOS_CERT_INSTALLER_P12_BASE64` | The same for the Installer certificate |
| `MACOS_CERT_PASSWORD` | The password you give both `.p12` files |
| `APPLE_TEAM_ID` | Your 10 character Apple team ID |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID of your team, shown next to the key |
| `ASC_KEY_P8_BASE64` | The API key file (`.p8`), base64 encoded |

## Before you start

- A paid Apple Developer Program membership. Only the **Account Holder** (the person who signed up) can create Developer ID certificates. If that is not you, ask them to do step 2 and send you the two `.cer` files.
- `openssl` (version 3 is best) and the GitHub CLI `gh` on your computer. Log in once with `gh auth login`.
- A folder to work in. Everything below happens there. It will hold private keys, so keep it out of the repo and delete it when you are done (see the end of this page).

## Step 1: make a private key and a certificate request

The private key never leaves your computer. Apple only sees the request, which contains the public half.

```sh
mkdir duette-signing && cd duette-signing
openssl req -new -newkey rsa:2048 -nodes \
  -keyout duette-signing.key -out duette-signing.csr \
  -subj "/emailAddress=you@example.com/CN=Your Name/C=NL"
```

Use your own email address, name and country code. This makes two files: `duette-signing.key` (secret) and `duette-signing.csr` (safe to upload).

## Step 2: get the two certificates from Apple

Do this twice, once for each certificate type, with the same `.csr` file.

1. Go to <https://developer.apple.com/account/resources/certificates/list> and sign in.
2. Click the blue **+** next to Certificates.
3. Under **Software**, pick **Developer ID Application** (first time) or **Developer ID Installer** (second time). Click Continue.
4. If it asks for a **Profile Type**, choose **G2 Sub-CA (Xcode 11.4.1 or later)**.
5. Upload `duette-signing.csr`, click Continue, then **Download**.

Rename the downloads so you can tell them apart:

```sh
mv ~/Downloads/developerID_application.cer application.cer
mv ~/Downloads/developerID_installer.cer installer.cer
```

If you only see "Developer ID Application" but not "Installer", you are not the Account Holder. Ask them.

## Step 3: turn each certificate into a `.p12` file

GitHub Actions needs the certificate and its private key together in one `.p12` file. Pick a password and keep it in a variable so it never shows up in your shell history:

```sh
read -rs P12_PASSWORD && export P12_PASSWORD
```

Type the password and press Enter (nothing is shown while you type). Then:

```sh
openssl x509 -inform DER -in application.cer -out application.pem
openssl x509 -inform DER -in installer.cer -out installer.pem

openssl pkcs12 -export -legacy \
  -inkey duette-signing.key -in application.pem \
  -name "Duette Developer ID Application" \
  -passout env:P12_PASSWORD -out application.p12

openssl pkcs12 -export -legacy \
  -inkey duette-signing.key -in installer.pem \
  -name "Duette Developer ID Installer" \
  -passout env:P12_PASSWORD -out installer.p12
```

The `-legacy` flag matters. OpenSSL 3 encrypts `.p12` files in a newer way by default, and the `security import` command on the Mac runner rejects that with a vague error. If your `openssl` says `unknown option -legacy`, you have an older OpenSSL or LibreSSL. Run the same commands without `-legacy`; their default already works.

Check that the files are good:

```sh
openssl pkcs12 -legacy -in application.p12 -nokeys -passin env:P12_PASSWORD | openssl x509 -noout -subject -enddate
openssl pkcs12 -legacy -in installer.p12 -nokeys -passin env:P12_PASSWORD | openssl x509 -noout -subject -enddate
```

You should see `Developer ID Application: Your Name (TEAMID)` and `Developer ID Installer: Your Name (TEAMID)`, and an end date about five years out. Again, drop `-legacy` here if your `openssl` does not know it.

## Step 4: find your team ID

On <https://developer.apple.com/account>, open **Membership details**. The **Team ID** is 10 letters and digits, the same ones in brackets in the certificate names above.

## Step 5: make an App Store Connect API key

This is what lets the build submit the installer to Apple for notarization without your Apple ID password.

1. Go to <https://appstoreconnect.apple.com/access/integrations/api> (Users and Access, then the **Integrations** tab, then **App Store Connect API**, then **Team Keys**).
2. Click **+** (or **Generate API Key**). Name it `Duette notarization`. Access: **Developer**. Click Generate.
3. Write down the **Issuer ID** (a long ID at the top of the page) and the **Key ID** (in the key's row).
4. Click **Download API Key**. You can download it **only once**. You get a file like `AuthKey_ABC123DEF4.p8`. Put it in your working folder.

If Apple asks you to accept a new agreement first, accept it on <https://developer.apple.com/account> and try again. Notarization stays blocked until the latest agreement is accepted.

## Step 6: store everything as GitHub secrets

These commands send the values straight from your computer to GitHub, which stores them encrypted. Nobody can read them back, not even you. Replace the example values.

```sh
REPO=Roboroads/Duette

base64 -w0 application.p12 | gh secret set MACOS_CERT_APP_P12_BASE64 --repo "$REPO"
base64 -w0 installer.p12   | gh secret set MACOS_CERT_INSTALLER_P12_BASE64 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"

gh secret set APPLE_TEAM_ID --repo "$REPO" --body "ABCDE12345"
gh secret set ASC_KEY_ID    --repo "$REPO" --body "ABC123DEF4"
gh secret set ASC_ISSUER_ID --repo "$REPO" --body "12345678-aaaa-bbbb-cccc-1234567890ab"
base64 -w0 AuthKey_ABC123DEF4.p8 | gh secret set ASC_KEY_P8_BASE64 --repo "$REPO"
```

On a Mac, `base64 -w0 file` becomes `base64 -i file`.

Check that all seven are there:

```sh
gh secret list --repo "$REPO"
```

You can also set them in the browser: the repo's **Settings**, **Secrets and variables**, **Actions**, **New repository secret**. For the two `.p12` secrets and the `.p8` secret, paste the output of `base64 -w0 <file>`.

## Step 7: check that it works

You do not have to wait for a real release. This runs the signing and notarization on a stand-in app and driver:

```sh
gh workflow run packaging.yml --repo "$REPO" --ref main
gh run watch --repo "$REPO"
```

Open the **signing check** job. A good run shows these lines:

- `Signing with Developer ID Application identity ...`
- `"status": "Accepted"` from the notary service
- `source=Notarized Developer ID` from `spctl`
- `notarized=true`

The first notarization from a new account can sit at `In Progress` for a long time (sometimes an hour or more). Later ones usually take a few minutes.

Once the real app and driver exist, a test build on your own branch does the same with the real thing. See [RELEASING.md](RELEASING.md).

## When something goes wrong

| What you see | What it means |
|---|---|
| `MAC verification failed during PKCS12 import` or `wrong password` | The `.p12` was made without `-legacy` on OpenSSL 3, or `MACOS_CERT_PASSWORD` is not the password you typed in step 3. Redo step 3 and step 6. |
| `no 'Developer ID Application' identity found after the import` | The `.p12` has the wrong certificate in it, or `APPLE_TEAM_ID` does not match the team in the certificate name. |
| `unable to build chain to self-signed root` | The Apple intermediate certificate is missing on the runner. Download "Developer ID - G2" from <https://www.apple.com/certificateauthority/> and add it to the `.p12` with `-certfile`. |
| Notarization status `Invalid` | Open the log printed above it. The usual causes: a file inside was not signed with the Developer ID certificate, the hardened runtime was off, or the signature has no secure timestamp. |
| `HTTP status code: 401` from `notarytool` | `ASC_KEY_ID`, `ASC_ISSUER_ID` or the `.p8` do not belong together, or the key lacks access. Make a new key in step 5. |
| `Unable to authenticate` or an agreement error | Accept the latest Apple Developer Program License Agreement on developer.apple.com. |
| `Can't open "Duette-x.y.z.pkg" because Apple cannot check it` on the Mac | The pkg is not notarized. The release notes of a test build say whether it was signed and notarized. |

## Clean up

The certificates are valid for about five years, then you repeat this page. If you want to skip steps 1 to 3 next time, keep `duette-signing.key` and the two `.p12` files in a password manager. Never commit any of these files.

When all seven secrets are set and the check passed, delete the working folder:

```sh
cd .. && rm -rf duette-signing
```
