// SPDX-License-Identifier: GPL-3.0-or-later
// Requires the build dependencies in an existing Vencord checkout.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
let esbuild;
try { esbuild = require('esbuild'); }
catch { esbuild = require(require.resolve('esbuild', { paths: [path.join(__dirname, '..', 'Vencord')] })); }
const source = fs.readFileSync(path.join(__dirname, '..', 'screenShareAlert', 'index.ts'), 'utf8');
const code = esbuild.transformSync(source, { loader: 'ts', format: 'cjs' }).code;

async function click({ navigateThrows = false, fullscreen = true, guildId = 'guild', ended = false } = {}) {
    const notifications = [];
    const events = [];
    const warnings = [];
    const stream = { guildId, channelId: 'channel', ownerId: 'streamer', streamType: guildId ? 'guild' : 'call' };
    const modules = {
        '@api/Notifications/NotificationComponent': { default: () => {} },
        '@api/Notifications/notificationLog': { persistNotification() {} },
        '@api/Settings': { definePluginSettings: () => ({ store: { onlyCurrentCall: true, openFullscreen: fullscreen } }) },
        '@utils/Logger': { Logger: class { warn(...args) { warnings.push(args); } error() {} } },
        '@utils/Queue': { Queue: class { push(task) { task(); } } },
        '@utils/types': { default: plugin => plugin, OptionType: { BOOLEAN: 1 } },
        '@webpack': {
            findByPropsLazy: () => ({ selectVoiceChannel: () => { throw new Error('Already in the call; must not rejoin'); } }),
            findByCodeLazy: (...filters) => {
                if (filters.length === 1) {
                    assert.equal(filters[0], '.openTextInVoiceIfVoiceChannel');
                    return channelId => {
                        assert.equal(channelId, 'channel');
                        events.push('navigate');
                        if (navigateThrows) throw new Error('Discord navigation action unavailable');
                    };
                }
                assert.deepEqual(filters, ['"STREAM_WATCH"', 'forceMultiple', 'selectParticipant']);
                return (applicationStream, options) => {
                    assert.equal(applicationStream, stream);
                    assert.equal(options.forceFocus, true);
                    events.push('watch');
                };
            }
        },
        '@webpack/common': {
            // Deliberately omit ChannelRouter: it is broken in the user's Vencord version.
            ApplicationStreamingStore: { getAllApplicationStreamsForChannel: () => ended ? [] : [stream] },
            ChannelStore: { getChannel: () => ({ name: 'channel' }) },
            GuildStore: { getGuild: () => ({ name: 'guild' }) },
            UserStore: { getCurrentUser: () => ({ id: 'me' }), getUser: () => ({ username: 'streamer', getAvatarURL: () => undefined }) },
            VoiceStateStore: { getVoiceStateForUser: () => ({ channelId: 'channel' }) },
            createRoot: () => ({ render: element => { if (element) notifications.push(element); } }),
            React: { createElement: (_, props) => props }
        }
    };
    for (const module of Object.values(modules)) module.__esModule = true;
    const context = { module: { exports: {} }, Error,
        require: id => { assert.ok(modules[id], id); return modules[id]; },
        document: { createElement: () => ({}), body: { append() {} } }, setTimeout, clearTimeout };
    vm.runInNewContext(code, context);
    context.module.exports.default.flux.VOICE_STATE_UPDATES({ voiceStates: [{ userId: 'streamer', channelId: 'channel', guildId, selfStream: true }] });
    assert.equal(notifications.length, 1);
    await notifications[0].onClick();
    return { events, warnings, notifications };
}

test('guild and DM clicks navigate and watch without using the broken ChannelRouter', async () => {
    for (const guildId of ['guild', null]) {
        const { events, notifications } = await click({ guildId });
        assert.deepEqual(events, ['navigate', 'watch']);
        assert.equal(notifications.length, 1);
    }
});

test('optional navigation failure still starts and focuses the stream', async () => {
    const { events, warnings, notifications } = await click({ navigateThrows: true });
    assert.deepEqual(events, ['navigate', 'watch']);
    assert.equal(warnings.length, 1);
    assert.equal(notifications.length, 1);
});

test('navigation disabled still starts the stream', async () => {
    const { events } = await click({ fullscreen: false });
    assert.deepEqual(events, ['watch']);
});

test('ended stream is reported without navigating or trying to watch', async () => {
    const { events, notifications } = await click({ ended: true });
    assert.deepEqual(events, []);
    assert.equal(notifications.length, 2);
    assert.match(notifications[1].body, /screen share has ended/);
});
