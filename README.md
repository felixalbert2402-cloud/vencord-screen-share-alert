# ScreenShareAlert for Vencord

Shows a click-to-watch notification when someone starts sharing their screen in a Discord call. The button uses Discord's native watch action to open and focus the stream.

## Download and install on Windows

1. Install [Discord desktop](https://discord.com/download), [Node.js 22 or newer](https://nodejs.org/en/download), and [Git for Windows](https://git-scm.com/download/win). npm comes with Node.js; the installer obtains the pnpm version required by Vencord automatically.
2. [Download this repository as a ZIP](https://github.com/felixalbert2402-cloud/vencord-screen-share-alert/archive/refs/heads/main.zip). Extract **all** files into a permanent folder, for example `Documents\ScreenShareAlert`.
3. Double-click **Install-ScreenShareAlert.cmd**. Run it as your normal Windows user. The first run downloads the official Vencord source and build dependencies; this can take several minutes.
4. Discord will close, the custom Vencord build will be injected, and Discord will restart. Closing Discord disconnects active calls.
5. In Discord, open **User Settings > Vencord > Plugins**, search for **ScreenShareAlert**, and enable it. Accept a restart if Discord requests one.
6. Join a voice call. Have someone start a screen share, then click the notification.

**Keep the extracted folder and its `Vencord` directory.** Discord loads your custom build from that directory. Deleting or moving it breaks the installation. The launcher installs a custom build of Vencord containing this plugin.

## What the launcher does

- Uses an existing Vencord checkout when supplied, or downloads the tested Vencord `v1.15.1` source into `Vencord` next to the launcher.
- Backs up any existing `screenShareAlert` plugin into `plugin-backups` before copying the bundled source into `src/userplugins/screenShareAlert/index.ts`.
- Builds Vencord before closing Discord. Other plugins in an existing checkout are included in that build.
- Closes the selected Discord branch, runs the official Vencord CLI installer with the custom-build environment, verifies that Discord points to the new build, and starts Discord again.
- Stops on a build or installer error and displays it. If injection fails after Discord closes, it attempts to restart Discord.

This follows Vencord's [custom-plugin workflow](https://docs.vencord.dev/installing/custom-plugins/) and [source installation workflow](https://docs.vencord.dev/installing/). The build is equivalent to `pnpm build`; injection uses the same environment and official installer as `pnpm inject`, with checked exit codes and an explicit Discord location.

## Use an existing Vencord source checkout

Open PowerShell in the extracted folder and run:

```powershell
.\Install-ScreenShareAlert.ps1 -VencordPath 'D:\development\Vencord'
```

If PowerShell prevents direct script execution, run the included launcher from Command Prompt:

```bat
Install-ScreenShareAlert.cmd -VencordPath "D:\development\Vencord"
```

The launcher uses a process-only PowerShell execution-policy setting; it does not change your system's policy. An existing checkout with dependencies already installed can use Node.js 18 or newer; fresh dependency installation requires Node.js 22 or newer.

For PTB or Canary, pass `-Branch ptb` or `-Branch canary`. For a nonstandard installation, pass `-DiscordPath` pointing to the Discord folder containing `app-*` directories. The default is stable Discord under `%LOCALAPPDATA%\Discord`.

```bat
Install-ScreenShareAlert.cmd -VencordPath "D:\development\Vencord" -Branch canary
Install-ScreenShareAlert.cmd -DryRun
```

`-DryRun` validates paths and prerequisites and prints the plan without changing files or closing Discord. Use `-InstallDependencies` to reinstall missing or stale build dependencies.

## Settings

- **Only current call**: notify only for streams in your current voice channel; enabled by default.
- **Open fullscreen**: navigate to the call when opening a stream; enabled by default. This opens Discord's full call view, not operating-system fullscreen.

Notifications remain inside Discord even when it is unfocused. They appear when you return to Discord; they are not an overlay over other applications.

## Updating and restoring

Download an updated plugin ZIP into a separate folder, then run its launcher with `-VencordPath` pointing to the **same permanent Vencord checkout**. Rerunning an old ZIP reinstalls its bundled plugin version. Keep the Vencord checkout in its original location.

The launcher does not automatically pull changes into an existing Vencord checkout. If Discord updates and removes the injection, rerun the launcher. If a future Discord update changes its internal stream actions, the plugin may need another source update.

To restore a plugin backup, copy its files from `plugin-backups` into `src/userplugins/screenShareAlert` in your checkout and rebuild. To remove the custom build entirely, use the [official Vencord installer](https://vencord.dev/download/) to uninstall Vencord or replace it with the standard build.

## Development

The plugin source is `screenShareAlert/index.ts`. Copy that folder into Vencord's `src/userplugins` directory, then run:

```powershell
pnpm build
pnpm inject
```

Restart Discord after injecting. Plugins are compiled into Vencord; a TypeScript plugin file cannot be installed by dropping it into Discord's ordinary plugin settings.

Installer checks (use fake processes and temporary fixtures; do not touch Discord):

```powershell
node --test scripts/test-installer.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-launcher.ps1
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Plugin author: `ilovecoookiiezzz`.
