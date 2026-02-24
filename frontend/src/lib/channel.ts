import type { Channel } from "phoenix";
import { getSocket } from "./socket";

export interface SessionChannelOptions {
  sessionId: string;
  getLastSeq?: () => number;
  onEvent: (payload: Record<string, unknown>) => void;
  onError?: (reason: unknown) => void;
  onClose?: () => void;
}

export interface SessionChannelHandle {
  submit: (text: string, kind?: string) => Promise<{ request_id: string }>;
  leave: () => void;
  channel: Channel;
}

export function joinSessionChannel(
  options: SessionChannelOptions
): Promise<SessionChannelHandle> {
  const socket = getSocket();
  const topic = `session:${options.sessionId}`;

  // Use a function for params so last_seq is fresh on each rejoin
  const channel = socket.channel(topic, () => {
    const params: Record<string, unknown> = {};
    const lastSeq = options.getLastSeq?.();
    if (lastSeq && lastSeq > 0) {
      params.last_seq = lastSeq;
    }
    return params;
  });

  channel.on("event", (payload) => {
    options.onEvent(payload as Record<string, unknown>);
  });

  if (options.onError) {
    channel.onError(options.onError);
  }

  if (options.onClose) {
    channel.onClose(options.onClose);
  }

  return new Promise((resolve, reject) => {
    channel
      .join()
      .receive("ok", () => {
        const handle: SessionChannelHandle = {
          channel,

          submit(text: string, kind: string = "prompt") {
            return new Promise((res, rej) => {
              channel
                .push("submit", { text, kind })
                .receive("ok", (response) =>
                  res(response as { request_id: string })
                )
                .receive("error", (err: unknown) => rej(err));
            });
          },

          leave() {
            channel.leave();
          },
        };

        resolve(handle);
      })
      .receive("error", (reason: unknown) => {
        reject(reason);
      });
  });
}
