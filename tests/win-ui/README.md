# Windows UI test: the client's windows on a real desktop

`tests/win-ui/run.ps1` installs a Kyn VPN Windows build and checks that its
Qt Quick windows actually come up:

1. the installer runs silently and the service answers `kynctl`;
2. first run: the Quick Tour opens;
3. its LOG IN button opens the dashboard, attached to the tray icon, on the
   login page;
4. second run, with the dashboard set to a regular window: it opens on the
   login page again.

```powershell
powershell -ExecutionPolicy Bypass -File tests\win-ui\run.ps1 `
    -Installer kyn-windows-x64-1.0.4-00108.exe -OutDir out
```

It needs an elevated prompt on an interactive desktop, and it **installs the
client on the machine it runs on**: use a throwaway one. CI runs it on the
x86_64 and arm64 builds (`windows-ui` in `.github/workflows/build.yml`), and a
release isn't published unless it passes.

## What a window has to do to pass

For each window, three steps are recorded:

- `…-window`: a visible top-level window of the client has the expected title,
  and is still there a few seconds later;
- `…-controls`: UI Automation finds the controls the page should show (for the
  login page: Username, Password, LOG IN), so the QML loaded;
- `…-rendered`: the window's pixels, taken from the compositor, have more than
  a handful of distinct colors, so it isn't blank.

Nothing here logs in or connects; `tests/e2e` covers that on Linux.

## Output

The script prints each step and exits 0 if all passed, 1 if one failed, 2 on a
setup problem. `-OutDir` (the `ui-windows-…-screenshots` artifact in CI) gets:

- `<step>-screen.png`: the whole desktop at that step;
- `<step>-window.png`: the window alone, even if something covers it;
- `<step>-uia.txt`: what UI Automation sees in the client's windows;
- `<step>-windows.txt`: every top-level window of the client, hidden ones too,
  with its position, styles and region;
- `report.json`, `client.log`, `daemon.log`, `install.log`,
  `clientsettings.json`.

When a window doesn't show, `<step>-windows.txt` tells whether it exists but
is hidden, off screen or clipped. To have Qt explain each show and hide in
`client.log`, start the client with
`QT_LOGGING_RULES=qt.quick.window*=true;qt.qpa.window*=true` in its
environment.
