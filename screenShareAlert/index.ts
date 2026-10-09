import NotificationComponent from "@api/Notifications/NotificationComponent";
import { persistNotification } from "@api/Notifications/notificationLog";
import { NotificationData } from "@api/Notifications/Notifications";
import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import { Queue } from "@utils/Queue";
import definePlugin, { OptionType } from "@utils/types";
import { findByCodeLazy, findByPropsLazy } from "@webpack";
import { ApplicationStreamingStore, ChannelRouter, ChannelStore, createRoot, GuildStore, React, UserStore, VoiceStateStore } from "@webpack/common";

const { selectVoiceChannel } = findByPropsLazy("selectVoiceChannel", "selectChannel");
// Discord's exports are mangled. Match the native watch action by its behavior;
// dispatching STREAM_WATCH alone does not focus the stream in the call UI.
const watchApplicationStream = findByCodeLazy('"STREAM_WATCH"', "forceMultiple", "selectParticipant");
const logger = new Logger("ScreenShareAlert");

// Vencord's showNotification() falls back to a native OS notification whenever Discord isn't
// focused (default "useNative" setting). Those get silently swallowed by Windows' Focus Assist
// during screen shares/presentations, so the alert would never appear at all if you tabbed away
// before someone started streaming. We render the same in-app toast unconditionally instead.
const AlertQueue = new Queue();
let alertRoot: ReturnType<typeof createRoot> | undefined;
let alertId = 0;

function getAlertRoot() {
    if (!alertRoot) {
        const container = document.createElement("div");
        container.id = "vc-screenshare-alert-container";
        document.body.append(container);
        alertRoot = createRoot(container);
    }
    return alertRoot;
}

function showAlert(data: NotificationData) {
    persistNotification(data);
    AlertQueue.push(() => new Promise<void>(resolve => {
        const root = getAlertRoot();
        root.render(
            React.createElement(NotificationComponent, {
                key: alertId++,
                ...data,
                onClose: () => {
                    data.onClose?.();
                    root.render(null);
                    resolve();
                }
            })
        );
    }));
}

interface VoiceStateUpdate {
    userId: string;
    channelId?: string;
    guildId?: string;
    selfStream?: boolean;
}

function makeStreamKey(guildId: string | undefined, channelId: string, userId: string) {
    return guildId ? `guild:${guildId}:${channelId}:${userId}` : `call:${channelId}:${userId}`;
}

async function watchStream(streamKey: string, channelId: string) {
    try {
        await openStream(streamKey, channelId);
    } catch (error) {
        logger.error("Could not open screen share", error);
        showAlert({
            title: "Could not open screen share",
            body: error instanceof Error ? error.message : "Try opening the stream from the voice channel."
        });
    }
}

async function openStream(streamKey: string, channelId: string) {
    const me = UserStore.getCurrentUser();
    if (!me) return;
    const alreadyInChannel = VoiceStateStore.getVoiceStateForUser(me.id)?.channelId === channelId;

    if (!alreadyInChannel) {
        await new Promise<void>((resolve, reject) => {
            const cleanup = () => {
                clearTimeout(timeout);
                VoiceStateStore.removeChangeListener(onChange);
            };
            const onChange = () => {
                if (VoiceStateStore.getVoiceStateForUser(me.id)?.channelId !== channelId) return;
                cleanup();
                resolve();
            };
            const timeout = setTimeout(() => {
                cleanup();
                reject(new Error("Could not join the voice channel. Join the call and try again."));
            }, 10000);
            VoiceStateStore.addChangeListener(onChange);
            try {
                selectVoiceChannel(channelId);
                onChange();
            } catch (error) {
                cleanup();
                reject(error);
            }
        });
    }

    const stream = ApplicationStreamingStore.getAllApplicationStreamsForChannel(channelId)
        .find(stream => makeStreamKey(stream.guildId ?? undefined, stream.channelId, stream.ownerId) === streamKey);
    if (!stream) throw new Error("This screen share has ended. Wait for a new screen-share notification.");

    if (settings.store.openFullscreen) {
        ChannelRouter.transitionToChannel(channelId);
    }

    watchApplicationStream(stream, { forceFocus: true });
}

// Tracks the last known selfStream value per user so we can detect the false -> true transition,
// since VOICE_STATE_UPDATES only gives us the new state, not a diff.
const lastStreamState = new Map<string, boolean>();

const settings = definePluginSettings({
    onlyCurrentCall: {
        type: OptionType.BOOLEAN,
        description: "Only notify when the stream is in the voice call you're currently in",
        default: true
    },
    openFullscreen: {
        type: OptionType.BOOLEAN,
        description: "Navigate to the call and watch the stream in full view instead of a small floating window",
        default: true
    }
});

export default definePlugin({
    name: "ScreenShareAlert",
    description: "Shows a click-to-watch notification when someone starts screen sharing in your call",
    authors: [{ name: "ilovecoookiiezzz", id: 175242695508230144n }],
    settings,

    flux: {
        VOICE_STATE_UPDATES({ voiceStates }: { voiceStates: VoiceStateUpdate[]; }) {
            const me = UserStore.getCurrentUser();

            for (const state of voiceStates) {
                const { userId, channelId, guildId } = state;
                const isStreaming = !!state.selfStream;
                const wasStreaming = lastStreamState.get(userId) ?? false;
                lastStreamState.set(userId, isStreaming);

                if (!isStreaming || wasStreaming) continue;
                if (userId === me.id) continue;
                if (!channelId) continue;

                if (settings.store.onlyCurrentCall) {
                    const myChannelId = VoiceStateStore.getVoiceStateForUser(me.id)?.channelId;
                    if (myChannelId !== channelId) continue;
                }

                const streamer = UserStore.getUser(userId);
                const channel = ChannelStore.getChannel(channelId);
                const guild = guildId ? GuildStore.getGuild(guildId) : null;

                const location = guild
                    ? `${channel?.name ?? "a channel"} in ${guild.name}`
                    : channel?.name ?? "your call";

                const streamKey = makeStreamKey(guildId, channelId, userId);

                showAlert({
                    title: `${streamer?.username ?? "Someone"} started screen sharing`,
                    body: `Click to watch in ${location}`,
                    icon: streamer?.getAvatarURL(undefined, undefined, false),
                    onClick: () => watchStream(streamKey, channelId)
                });
            }
        }
    }
});
