# ScreenShareAlert for Vencord

Shows a click-to-watch notification when someone starts sharing their screen in a Discord call. The button uses Discord's native watch action to open and focus the stream.

Version 1.0.1 fixes the `transitionToChannel is not a function` error on recent Discord builds. If optional call navigation fails, the plugin still attempts to watch the stream.

Version 1.1.1 updates the custom build to Vencord 1.15.16 to fix a Discord startup hang.

Version 1.1.0 automatically checks Node.js and Git and downloads portable copies when they are missing or unusable.

## Download and install on Windows

1. Install [Discord desktop](https://discord.com/download). Windows PowerShell 5.1 or newer and internet access are needed; Windows 10/11 include PowerShell.
2. [Download this repository as a ZIP](https://github.com/felixalbert2402-cloud/vencord-screen-share-alert/archive/refs/heads/main.zip). Extract **all** files into a permanent folder, for example `Documents\ScreenShareAlert`.
3. Double-click **Install-ScreenShareAlert.cmd**. Run it as your normal Windows user. It checks for Node.js 22+ and Git. Missing tools are downloaded automatically, along with npm/pnpm and Vencord's build dependencies; this can take several minutes.
4. Discord will close, the custom Vencord build will be injected, and Discord will restart. Closing Discord disconnects active calls.
5. In Discord, open **User Settings > Vencord > Plugins**, search for **ScreenShareAlert**, and enable it. Accept a restart if Discord requests one.
6. Join a voice call. Have someone start a screen share, then click the notification.

**Keep the extracted folder and its Vencord checkout directory.** Discord loads your custom build from that directory. Deleting or moving it breaks the installation. The launcher installs a custom build of Vencord containing this plugin.

## What the launcher does

- Reuses usable Node.js 22+ and Git installations. When needed, downloads official Node.js 22 and Git for Windows MinGit ZIPs, verifies their SHA-256 checksums, and extracts them into `.tools` beside the launcher. No administrator access or permanent system PATH changes are required. Portable tools are reused on later runs.
- Uses an existing Vencord checkout when supplied, or downloads the tested Vencord `v1.15.16` source into `Vencord-v1.15.16` next to the launcher.
- Backs up any existing `screenShareAlert` plugin into `plugin-backups` before copying the bundled source into `src/userplugins/screenShareAlert/index.ts`.
- Builds Vencord before closing Discord. Other plugins in an existing checkout are included in that build.
- Closes the selected Discord branch, runs the official Vencord CLI installer with the custom-build environment, verifies that Discord points to the new build, and starts Discord again.
- Stops on a build or installer error and displays it. If injection fails after Discord closes, it attempts to restart Discord.

This follows Vencord's [custom-plugin workflow](https://docs.vencord.dev/installing/custom-plugins/) and [source installation workflow](https://docs.vencord.dev/installing/). The build is equivalent to `pnpm build`; injection uses the same environment and official installer as `pnpm inject`, with checked exit codes and an explicit Discord location.

## Use an existing Vencord source checkout

Open PowerShell in the extracted folder and run:

```powershell
.\Install-ScreenShareAlert.ps1 -VencordPath 'D:\development\Vencord-current'
```

If PowerShell prevents direct script execution, run the included launcher from Command Prompt:

```bat
Install-ScreenShareAlert.cmd -VencordPath "D:\development\Vencord-current"
```

The launcher uses a process-only PowerShell execution-policy setting; it does not change your system's policy. It automatically supplies Node.js 22+ and Git if your PC lacks usable versions. The portable copies are used only by the launcher and its child processes; they do not replace your system installations.

For PTB or Canary, pass `-Branch ptb` or `-Branch canary`. For a nonstandard installation, pass `-DiscordPath` pointing to the Discord folder containing `app-*` directories. The default is stable Discord under `%LOCALAPPDATA%\Discord`.

```bat
Install-ScreenShareAlert.cmd -VencordPath "D:\development\Vencord-current" -Branch canary
Install-ScreenShareAlert.cmd -DryRun
```

`-DryRun` validates paths and reports missing prerequisites without downloading tools, changing files, or closing Discord. Use `-InstallDependencies` to reinstall missing or stale build dependencies. If a dependency download or checksum check fails, setup stops before Discord is closed.

## Settings

- **Only current call**: notify only for streams in your current voice channel; enabled by default.
- **Open fullscreen**: navigate to the call when opening a stream; enabled by default. This opens Discord's full call view, not operating-system fullscreen.

Notifications remain inside Discord even when it is unfocused. They appear when you return to Discord; they are not an overlay over other applications.

## Updating and restoring

If you used an older release, pull the latest changes or extract the new ZIP, then run Install-ScreenShareAlert.cmd again. With no arguments, it creates or reuses the Vencord checkout for this release and switches Discord to that build. If you maintain your own compatible Vencord checkout, run the launcher with `-VencordPath` pointing to that checkout. Rerunning an old ZIP reinstalls its bundled plugin version. Keep the Vencord checkout in its original location.

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
node --test scripts/test-plugin.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-launcher.ps1

```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Plugin author: `ilovecoookiiezzz`.
