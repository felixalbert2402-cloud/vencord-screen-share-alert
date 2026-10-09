// SPDX-License-Identifier: GPL-3.0-or-later
// Checks installer failures and custom-build verification without touching Discord.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname, 'inject.cjs'), 'utf8');
const winPath = path.win32;

async function run({ status = 0, signal = null, mode, installerExists = true, downloadStatus = 200, customBuild = true } = {}) {
    const root = 'D:\\Vencord source';
    const discord = 'C:\\Users\\Test\\Discord';
    const patcher = winPath.join(root, 'dist', 'patcher.js');
    const installer = winPath.join(root, 'dist', 'Installer', 'VencordInstallerCli.exe');
    const resources = winPath.join(discord, 'app-1.0.1', 'resources');
    const calls = { spawn: [], fetch: [], rename: [], log: [], error: [] };
    const knownFiles = new Set([patcher, resources, ...(installerExists ? [installer] : [])]);
    const fakeFs = {
        existsSync: file => knownFiles.has(file),
        mkdirSync() {},
        createWriteStream: file => ({ file }),
        renameSync: (from, to) => { calls.rename.push([from, to]); knownFiles.add(to); },
        readdirSync: () => [{ name: 'app-1.0.1', isDirectory: () => true }],
        readFileSync: () => Buffer.from('require(' + JSON.stringify(customBuild ? patcher : 'C:\\Other\\patcher.js') + ')')
    };
    const modules = {
        'node:fs': fakeFs,
        'node:path': winPath,
        'node:child_process': { spawnSync: (...args) => { calls.spawn.push(args); return { status, signal }; } },
        'node:stream': { Readable: { fromWeb: body => body } },
        'node:stream/promises': { pipeline: async () => {} }
    };
    const context = {
        Buffer, AbortSignal,
        process: { platform: 'win32', argv: ['node', 'inject.cjs', root, discord, ...(mode ? [mode] : [])], env: { TEST_ENV: 'preserved' } },
        require: id => { assert.ok(modules[id], id); return modules[id]; },
        fetch: async (...args) => { calls.fetch.push(args); return { ok: downloadStatus === 200, status: downloadStatus, body: {} }; },
        console: { log: text => calls.log.push(text), error: text => calls.error.push(text) }
    };
    await vm.runInNewContext(source, context);
    return { calls, context, root, discord, patcher, installer };
}

test('successful injection targets the selected Discord and uses the custom build', async () => {
    const { calls, context, root, discord, installer } = await run();
    assert.equal(context.process.exitCode, undefined);
    assert.equal(calls.spawn.length, 1);
    const [command, args, options] = calls.spawn[0];
    assert.equal(command, installer);
    assert.deepEqual(Array.from(args), ['-install', '-location', discord]);
    assert.equal(options.env.VENCORD_USER_DATA_DIR, root);
    assert.equal(options.env.VENCORD_DEV_INSTALL, '1');
    assert.equal(options.env.TEST_ENV, 'preserved');
    assert.equal(options.windowsHide, true);
});

test('preparation never runs the installer', async () => {
    const { calls, context } = await run({ mode: '--prepare' });
    assert.equal(context.process.exitCode, undefined);
    assert.equal(calls.spawn.length, 0);
});

test('failed or terminated installer returns failure', async () => {
    for (const opts of [{ status: 1 }, { status: null, signal: 'SIGTERM' }]) {
        const { calls, context } = await run(opts);
        assert.equal(context.process.exitCode, 1);
        assert.match(calls.error[0], /installer failed/);
        assert.equal(calls.log.some(line => line.startsWith('Verified')), false);
    }
});

test('success exit code with the wrong Vencord path is rejected', async () => {
    const { calls, context } = await run({ customBuild: false });
    assert.equal(context.process.exitCode, 1);
    assert.match(calls.error[0], /does not point to this custom Vencord build/);
});

test('download errors stop before installation', async () => {
    const { calls, context } = await run({ installerExists: false, downloadStatus: 503 });
    assert.equal(context.process.exitCode, 1);
    assert.equal(calls.spawn.length, 0);
    assert.equal(calls.rename.length, 0);
    assert.match(calls.error[0], /HTTP 503/);
});

test('new installer comes from the official release and is placed inside the checkout', async () => {
    const { calls, context, installer } = await run({ installerExists: false, mode: '--prepare' });
    assert.equal(context.process.exitCode, undefined);
    assert.equal(calls.fetch[0][0], 'https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe');
    assert.deepEqual(calls.rename[0], [installer + '.download', installer]);
    assert.equal(calls.spawn.length, 0);
});
