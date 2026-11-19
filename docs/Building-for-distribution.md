# Building for distribution

`rake artifacts` (or `rake all`) produces the final artifacts for distribution, including signing if code signing details are provided.  Code signing environment variables are defined below.

Build scripts in the `scripts` directory are also provided that clean, then build for all architectures supported on a given platform.

###  Windows

Set environment variables:

| Variable | Value |
|----------|-------|
| PIA_SIGNTOOL_CERTFILE | Path to certificate file (if signing with PFX archived cert) |
| PIA_SIGNTOOL_PASSWORD | Password to decrypt cert file (if signing with encrypted PFX archived cert) |
| PIA_SIGNTOOL_THUMBPRINT | Thumbprint of certificate - signs with cert from cert store instead of PFX archive |
| PIA_SIGNTOOL_DLIB, PIA_SIGNTOOL_DMDF | signtool plugin and its metadata file (e.g. Azure Artifact Signing's `Azure.CodeSigning.Dlib.dll`) - every signature is then timestamped |
| PIA_SIGNTOOL_EXE | (optional) signtool to run instead of the one in `PATH`; a plugin needs a signtool of its own architecture |
| PIA_SIGNTOOL_TIMESTAMP_URL | (optional) RFC 3161 timestamping service (default `http://timestamp.digicert.com`) |

GitHub Actions signs with [Azure Artifact Signing](https://aka.ms/artifactsigning/), using the variables of the `windows-signing` environment (only `master` and `v*` tags can use it) and logging in to Azure with the job's OIDC token, so no secret is stored.  Run `.github/scripts/setup-windows-signing.sh <subscription ID> [<identity validation ID>]` after `az login` to set it up.

Then call `rake BRAND=kyn VARIANT=release all`

### Mac

Set environment variables:

| Variable | Value |
|----------|-------|
| PIA_CODESIGN_CERT | Common name of the signing certificate.  Must be the complete common name, not a partial match. |
| PIA_APPLE_ID_EMAIL | Apple ID used to notarize build. |
| PIA_APPLE_ID_PASSWORD | Password to Apple ID for notarization. |
| PIA_APPLE_TEAM_ID | Team ID used to notarize build. |

Then call `rake BRAND=kyn VARIANT=release ARCHITECTURE=universal all`

A certificate is required for the Mac build to be installable (even for local builds), see below to generate a self-signed certificate for local use.  Unsigned builds can be manually installed by running the install script with `sudo`.

### Linux

Release artifacts are built in an AlmaLinux 9 container, the same environment
[kynvpn-qt](https://github.com/Shells-com/kynvpn-qt) builds Qt in, so the
client runs on anything with glibc 2.34 or newer.  x86_64 and arm64 are built
natively (no cross builds).  See the `linux` job in
[`.github/workflows/build.yml`](../.github/workflows/build.yml) for the exact
package list; locally:

```shell
$ docker run --rm -it -v "$PWD":/src -w /src almalinux:9 bash
# Inside the container: install the packages from the workflow's "Install
# build dependencies" step, then install Qt:
$$ sh qt-6.12.0-kynvpn-linux-x86_64.run -- /opt/Qt-kynvpn --yes
$$ git config --global --add safe.directory /src
$$ QTROOT=/opt/Qt-kynvpn/6.12.0 rake VARIANT=release BRAND=kyn all
```

## GitHub Actions

[`.github/workflows/build.yml`](../.github/workflows/build.yml) builds every
platform on each push to `master` and on pull requests, and keeps the outputs
of `rake artifacts` as workflow artifacts.  Pushing a `v<version>` tag (e.g.
`v1.0.0`) also sets the product version and creates a draft release with the
installers.

### Releases and updates

The release job (`v*` tags only) signs each release with the Ed25519 key in
the `RELEASE_SIGNING_KEY` secret of the `release-signing` environment
([`sign-release.py`](../.github/scripts/sign-release.py)) and attaches:

- `SHA256SUMS` and `SHA256SUMS.sig`, its signature, for people verifying a
  download against [`kynvpn-release.pub`](kynvpn-release.pub)
- `update.json`, the signed update metadata: for each platform, the version,
  the installer's URL and its SHA-256

The client checks `https://github.com/Shells-com/kynvpn-desktop/releases/latest/download/update.json`
(the latest published, non-prerelease release; drafts are not visible).  It
ignores metadata that isn't signed with the key in
`Environment::defaultUpdatePublicKey` (`daemon/src/environment.cpp`, the same
as `kynvpn-release.pub`), and discards a downloaded installer whose SHA-256
doesn't match.  Publishing the draft release is what offers the update to
users.  There is no beta update channel.

The private key is backed up in the login keychain of the Mac it was made on
("Kyn VPN release signing key (Ed25519)").  Losing it means installed clients
can't be updated any more; if it leaks, ship a client with a new key as soon
as possible.  Testing against another key: put its public key in
`update_key_override.pem` in the daemon's settings directory.

Signing is enabled by secrets; builds are unsigned without them.  The macOS
secrets belong to the `macos-signing` environment, which only `master` and
`v*` tags can use, so other branches and pull requests build unsigned.  Run
`.github/scripts/setup-macos-signing.sh <team ID>` on a Mac with the Developer
ID Application certificate in its login keychain to set them up.  Builds of
`master` and of tags are notarized; tag builds also get a release version
number.

| Secret | Use |
|--------|-----|
| `MACOS_CERT_P12` | Base64-encoded .p12 with the Developer ID Application certificate and key |
| `MACOS_CERT_PASSWORD` | Password of the .p12 |
| `MACOS_CODESIGN_IDENTITY` | Common name of the certificate (becomes `PIA_CODESIGN_CERT`) |
| `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID` | Notarization credentials (app-specific password) |
