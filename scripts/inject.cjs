// SPDX-License-Identifier: GPL-3.0-or-later
// Same custom-build environment as Vencord's `pnpm inject`, with checked exit codes.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

async function main() {
    const [checkout, discordRoot, mode] = process.argv.slice(2);
    if (!checkout || !discordRoot || (mode && mode !== '--prepare')) {
        throw new Error('Usage: node inject.cjs <Vencord checkout> <Discord install root> [--prepare]');
    }
    if (process.platform !== 'win32') throw new Error('This installer supports Windows desktop Discord.');
    const root = path.resolve(checkout);
    const discord = path.resolve(discordRoot);
    const patcher = path.join(root, 'dist', 'patcher.js');
    if (!fs.existsSync(patcher)) throw new Error('Vencord must be built before injection.');
    const installer = path.join(root, 'dist', 'Installer', 'VencordInstallerCli.exe');
    if (!fs.existsSync(installer)) {
        console.log('Downloading the official Vencord CLI installer...');
        const response = await fetch('https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe', {
            headers: { 'User-Agent': 'ScreenShareAlert installer' }, signal: AbortSignal.timeout(120000)
        });
        if (!response.ok) throw new Error(`Installer download failed: HTTP ${response.status}`);
        fs.mkdirSync(path.dirname(installer), { recursive: true });
        const temporary = installer + '.download';
        await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(temporary));
        // Only move this explicitly named file within the validated checkout's Installer folder.
        fs.renameSync(temporary, installer);
    }
    if (mode === '--prepare') return;
    const result = spawnSync(installer, ['-install', '-location', discord], {
        stdio: 'inherit', windowsHide: true,
        env: { ...process.env, VENCORD_USER_DATA_DIR: root, VENCORD_DEV_INSTALL: '1' }
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`Vencord installer failed (exit ${result.status ?? result.signal}).`);
    // Verify Discord points to this custom build rather than the standard AppData build.
    const appFolders = fs.readdirSync(discord, { withFileTypes: true })
        .filter(entry => entry.isDirectory() && entry.name.startsWith('app-') && fs.existsSync(path.join(discord, entry.name, 'resources')))
        .map(entry => entry.name).sort().reverse();
    const patchedApp = appFolders[0] && path.join(discord, appFolders[0], 'resources', 'app.asar');
    const expectedPath = JSON.stringify(patcher).slice(1, -1);
    if (!patchedApp || !fs.readFileSync(patchedApp).includes(Buffer.from(expectedPath))) {
        throw new Error('Installer exited successfully, but Discord does not point to this custom Vencord build.');
    }
    console.log('Verified: Discord now loads the custom Vencord build.');
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
