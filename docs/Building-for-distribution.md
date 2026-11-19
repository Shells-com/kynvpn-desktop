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
| `WINDOWS_CERT_PFX` | Base64-encoded .pfx code signing certificate |
| `WINDOWS_CERT_PASSWORD` | Password of the .pfx |
