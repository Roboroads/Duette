# Signing and notarizing Duette

This is the one-time setup that lets GitHub Actions build a Duette installer that a Mac opens without a warning. You do it once, without a Mac, from any Linux or Windows (WSL) terminal. It takes about 30 minutes, most of it clicking through Apple's websites.

Until the secrets exist, every build still works. The installer is just unsigned, and a Mac asks you to confirm before opening it.

## Which path are you on?

- **Path A: you already have a `.p12` file** with a Developer ID certificate in it (for example exported earlier from Keychain Access on a Mac). Skip the request and certificate steps. Read [Path A](#path-a-if-you-already-have-a-p12) below, then do steps 4 to 7.
- **Path B: you are starting from scratch.** Do steps 1 to 7 in order.

## What you are making

Apple wants three things before a Mac opens an installer without complaining:

1. The app and the audio driver inside it are signed with a **Developer ID Application** certificate.
2. The installer itself is signed with a **Developer ID Installer** certificate.
3. Apple has scanned the installer and stamped it (notarization). This needs an **App Store Connect API key**.

You end up with these values stored as GitHub repo secrets (seven normally; five if one `.p12` holds both certificates):

| Secret | What it is |
|---|---|
| `MACOS_CERT_APP_P12_BASE64` | The Application certificate and its private key, as a `.p12` file, base64 encoded |
| `MACOS_CERT_INSTALLER_P12_BASE64` | The same for the Installer certificate. Leave it out if the Application `.p12` already contains the Installer certificate too |
| `MACOS_CERT_PASSWORD` | The password of the Application `.p12` (and of the Installer one, unless you set the next secret) |
| `MACOS_CERT_INSTALLER_PASSWORD` | Optional. The password of the Installer `.p12` when it differs from the Application one |
| `APPLE_TEAM_ID` | Your 10 character Apple team ID |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID of your team, shown next to the key |
| `ASC_KEY_P8_BASE64` | The API key file (`.p8`), base64 encoded |

## Path A: if you already have a .p12

Apple wants two certificates for a downloadable installer: **Developer ID Application** (signs the app and driver) and **Developer ID Installer** (signs the pkg). A `.p12` holds a certificate together with its private key. Yours might hold either one or both. Find out first.

### Look inside it

Run this in the folder with your file (change `yours.p12` to its name). It asks for the password you chose when you exported it. The key is not printed, because of `-nokeys`.

```sh
openssl pkcs12 -info -in yours.p12 -nokeys
```

If it fails with `unsupported` or `error:0308010C`, your OpenSSL is version 3 and the file uses an older encryption. Add `-legacy`:

```sh
openssl pkcs12 -legacy -info -in yours.p12 -nokeys
```

A wrong password shows `Mac verify error` or `invalid password`. Try again.

Look at the `subject=` lines. Each certificate in the file has one, and the name you want is the `CN =` part:

- `Developer ID Application: Your Name (TEAMID)`
- `Developer ID Installer: Your Name (TEAMID)`

You may also see Apple's intermediate certificates (for example "Developer ID Certification Authority"). Ignore those. The 10 characters in brackets are your Team ID, which you need in step 4.

Then check that a private key is in the file too, without printing it:

```sh
read -rs P12_PASSWORD && export P12_PASSWORD
openssl pkcs12 -legacy -in yours.p12 -nodes -passin env:P12_PASSWORD | grep -c 'PRIVATE KEY'
```

Type the password and press Enter (nothing is shown). Drop `-legacy` if the first command worked without it. The number is how many private keys the file holds. `0` means the key was not exported with the certificate, so the file cannot sign anything. Export again from Keychain Access with the certificate and its key (select the entry under "My Certificates"), or use Path B.

### What you found

| You saw | What to do |
|---|---|
| "Application" and "Installer", and at least one key | This one file is enough. In step 6 set only `MACOS_CERT_APP_P12_BASE64` and `MACOS_CERT_PASSWORD`, and skip the Installer secrets. |
| Only "Application" | You still need the Installer certificate. Use an Installer `.p12` you already have, or make one as described below. |
| Only "Installer" | You still need the Application certificate. Same section below, with Application in place of Installer. |
| Two separate `.p12` files | Use them as they are. If their passwords differ, you can store both (step 6). |

### Adding the missing certificate

You can make the other certificate from the **same private key** that is in your `.p12`, so you do not need a second key. Only the Account Holder can create Developer ID certificates (see "Before you start").

1. Take the key out of the `.p12` (add or drop `-legacy` as before). This writes an unencrypted key file, so keep it private and delete it when you are done:

   ```sh
   openssl pkcs12 -legacy -in yours.p12 -nocerts -nodes -passin env:P12_PASSWORD | openssl pkey -out duette-signing.key
   ```

   If the file held more than one key, the first one is taken. That does not matter when the file only had one certificate.

2. Make a certificate request from it:

   ```sh
   openssl req -new -key duette-signing.key -out duette-signing.csr \
     -subj "/emailAddress=you@example.com/CN=Your Name/C=NL"
   ```

3. Do [step 2](#step-2-get-the-two-certificates-from-apple) for the missing type only: pick **Developer ID Installer** (or **Developer ID Application**), upload `duette-signing.csr`, and download the `.cer`.

4. Turn it into a `.p12` with the same key. For an Installer certificate:

   ```sh
   openssl x509 -inform DER -in installer.cer -out installer.pem
   openssl pkcs12 -export -legacy \
     -inkey duette-signing.key -in installer.pem \
     -name "Duette Developer ID Installer" \
     -passout env:P12_PASSWORD -out installer.p12
   ```

   This `.p12` gets the same password as the variable you set above, so one password covers both files. Drop `-legacy` if your `openssl` does not know it.

### If the Mac runner rejects the file

Normally you can skip this, since a `.p12` from Keychain Access is what macOS expects. If the check in step 7 fails on the import with `MAC verification failed during PKCS12 import` and you are sure the password is right, make a fresh copy of a `.p12` that holds a single identity:

```sh
read -rs NEW_P12_PASSWORD && export NEW_P12_PASSWORD
openssl pkcs12 -legacy -in yours.p12 -nodes -passin env:P12_PASSWORD \
  | openssl pkcs12 -export -legacy -passout env:NEW_P12_PASSWORD -out yours-reexported.p12
```

Use `yours-reexported.p12` and `NEW_P12_PASSWORD` in step 6 instead. This writes one private key with its certificate, so use it for a file with a single identity, not for one that holds both.

### Continue

Do [step 4](#step-4-find-your-team-id) (Team ID), [step 5](#step-5-make-an-app-store-connect-api-key) (API key), [step 6](#step-6-store-everything-as-github-secrets) (secrets) and [step 7](#step-7-check-that-it-works) (check). The API key is separate from your `.p12`, so you need it either way. Skip steps 1 to 3. Then go to [Clean up](#clean-up).

## Path B: starting from scratch

Steps 1 to 3 make the certificates. Steps 4 to 7 are shared with Path A, and so is "Before you start".

## Before you start

- A paid Apple Developer Program membership. Only the **Account Holder** (the person who signed up) can create Developer ID certificates. If that is not you, ask them to do step 2 and send you the `.cer` files (on Path A, only the one you are missing).
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

On Path A, adjust the first three lines to what you have:

- One `.p12` with both certificates: set `MACOS_CERT_APP_P12_BASE64` (from that file) and `MACOS_CERT_PASSWORD`, and skip the Installer line. That leaves five secrets.
- Two `.p12` files with different passwords: set `MACOS_CERT_PASSWORD` to the Application password and add the Installer one with `printf '%s' "$INSTALLER_PASSWORD" | gh secret set MACOS_CERT_INSTALLER_PASSWORD --repo "$REPO"`. Without that secret, the Installer file is opened with `MACOS_CERT_PASSWORD`.

Check that they are all there (seven normally, five or six on Path A):

```sh
gh secret list --repo "$REPO"
```

You can also set them in the browser: the repo's **Settings**, **Secrets and variables**, **Actions**, **New repository secret**. For the `.p12` secrets and the `.p8` secret, paste the output of `base64 -w0 <file>`.

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
| `MAC verification failed during PKCS12 import` or `wrong password` | The `.p12` was made without `-legacy` on OpenSSL 3, or the password secret is not that file's password. If the failing file is the Installer one and it has its own password, set `MACOS_CERT_INSTALLER_PASSWORD`. Otherwise redo step 3 (or the re-export under Path A) and step 6. |
| `no 'Developer ID Application' identity found after the import` | The `.p12` has the wrong certificate in it, or `APPLE_TEAM_ID` does not match the team in the certificate name. |
| `The signing secrets are set but the pkg was not signed and notarized` | Most likely no Installer certificate reached the runner: the Application `.p12` does not contain it and `MACOS_CERT_INSTALLER_P12_BASE64` is not set. The log line `Identities in the temporary keychain` shows what was found. |
| `unable to build chain to self-signed root` | The Apple intermediate certificate is missing on the runner. Download "Developer ID - G2" from <https://www.apple.com/certificateauthority/> and add it to the `.p12` with `-certfile`. |
| Notarization status `Invalid` | Open the log printed above it. The usual causes: a file inside was not signed with the Developer ID certificate, the hardened runtime was off, or the signature has no secure timestamp. |
| `HTTP status code: 401` from `notarytool` | `ASC_KEY_ID`, `ASC_ISSUER_ID` or the `.p8` do not belong together, or the key lacks access. Make a new key in step 5. |
| `Unable to authenticate` or an agreement error | Accept the latest Apple Developer Program License Agreement on developer.apple.com. |
| `Can't open "Duette-x.y.z.pkg" because Apple cannot check it` on the Mac | The pkg is not notarized. The release notes of a test build say whether it was signed and notarized. |

## Clean up

The certificates are valid for about five years, then you repeat this page. If you want to skip steps 1 to 3 next time, keep `duette-signing.key` (or your original `.p12`) and the `.p12` files in a password manager. Never commit any of these files.

When all seven secrets are set and the check passed, delete the working folder:

```sh
cd .. && rm -rf duette-signing
```
