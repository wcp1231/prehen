import { create } from "zustand";
import {
  joinSessionChannel,
  type SessionChannelHandle,
} from "../lib/channel";
import { replaySession } from "../lib/api";

export interface ToolCall {
  callId: string;
  name: string;
  arguments: Record<string, unknown>;
  status: "running" | "completed" | "error";
  result?: unknown;
}

export interface Message {
  id: string;
  role: "user" | "assistant";
  content: string;
  toolCalls: ToolCall[];
  thinking: string;
  isStreaming: boolean;
}

export interface SessionState {
  sessionId: string | null;
  messages: Message[];
  lastSeq: number;
  status: "idle" | "connecting" | "connected" | "reconnecting" | "error";
  error: string | null;
  channelHandle: SessionChannelHandle | null;

  connect: (sessionId: string) => Promise<void>;
  restoreAndConnect: (sessionId: string) => Promise<void>;
  disconnect: () => void;
  submitMessage: (text: string) => Promise<void>;
  addUserMessage: (text: string) => void;
  handleEvent: (payload: Record<string, unknown>) => void;
  reset: () => void;
}

let messageCounter = 0;
function nextMessageId(): string {
  return `msg_${++messageCounter}`;
}

/**
 * Track whether the user explicitly requested disconnect.
 * Stored outside Zustand to avoid triggering re-renders.
 */
let intentionalDisconnect = false;

function buildChannelCallbacks(
  get: () => SessionState,
  set: (partial: Partial<SessionState> | ((state: SessionState) => Partial<SessionState>)) => void,
) {
  return {
    getLastSeq: () => get().lastSeq,
    onEvent: (payload: Record<string, unknown>) => get().handleEvent(payload),
    onError: () => {
      // onError fires on temporary disconnects — Phoenix auto-reconnects.
      // Don't destroy state; just show "reconnecting" status.
      if (!intentionalDisconnect) {
        set({ status: "reconnecting" });
      }
    },
    onClose: () => {
      // onClose fires when channel is permanently closed
      // (server-side {:stop, ...} or explicit leave).
      if (!intentionalDisconnect) {
        set({ status: "idle", channelHandle: null });
      }
    },
  };
}

export const useSessionStore = create<SessionState>((set, get) => ({
  sessionId: null,
  messages: [],
  lastSeq: 0,
  status: "idle",
  error: null,
  channelHandle: null,

  async connect(sessionId: string) {
    intentionalDisconnect = false;
    set({ status: "connecting", sessionId, error: null });

    try {
      const callbacks = buildChannelCallbacks(get, set);
      const handle = await joinSessionChannel({
        sessionId,
        ...callbacks,
      });

      set({ status: "connected", channelHandle: handle });
    } catch (err) {
      set({
        status: "error",
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },

  async restoreAndConnect(sessionId: string) {
    intentionalDisconnect = false;
    set({ status: "connecting", sessionId, messages: [], lastSeq: 0, error: null });

    try {
      const { events } = await replaySession(sessionId);
      for (const event of events) {
        get().handleEvent(event);
      }

      const callbacks = buildChannelCallbacks(get, set);
      const handle = await joinSessionChannel({
        sessionId,
        ...callbacks,
      });

      set({ status: "connected", channelHandle: handle });
    } catch (err) {
      set({
        status: "error",
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },

  disconnect() {
    intentionalDisconnect = true;
    const { channelHandle } = get();
    if (channelHandle) {
      channelHandle.leave();
    }
    set({ channelHandle: null, status: "idle" });
  },

  async submitMessage(text: string) {
    const { channelHandle } = get();
    if (!channelHandle) return;

    get().addUserMessage(text);
    await channelHandle.submit(text);
  },

  addUserMessage(text: string) {
    const msg: Message = {
      id: nextMessageId(),
      role: "user",
      content: text,
      toolCalls: [],
      thinking: "",
      isStreaming: false,
    };
    set((state) => ({ messages: [...state.messages, msg] }));
  },

  handleEvent(payload: Record<string, unknown>) {
    const type = payload.type as string;
    const seq = (payload.seq as number) || 0;

    set((state) => ({
      lastSeq: Math.max(state.lastSeq, seq),
      // Receiving an event while reconnecting means we're back
      ...(state.status === "reconnecting" ? { status: "connected" as const } : {}),
    }));

    switch (type) {
      case "ai.user.message":
        handleUserMessage(payload);
        break;
      case "ai.llm.delta":
        handleDelta(payload);
        break;
      case "ai.tool.call":
        handleToolCall(payload);
        break;
      case "ai.tool.result":
        handleToolResult(payload);
        break;
      case "ai.react.step":
        handleReactStep(payload);
        break;
      case "ai.session.turn.completed":
        handleTurnCompleted();
        break;
      case "ai.request.failed":
        handleRequestFailed(payload);
        break;
      case "session.crashed":
        set({ status: "error", error: payload.reason as string });
        break;
      case "session.ended":
        set({ status: "idle" });
        break;
    }
  },

  reset() {
    intentionalDisconnect = true;
    const { channelHandle } = get();
    if (channelHandle) channelHandle.leave();
    intentionalDisconnect = false;
    set({
      sessionId: null,
      messages: [],
      lastSeq: 0,
      status: "idle",
      error: null,
      channelHandle: null,
    });
  },
}));

function getOrCreateAssistantMessage(): void {
  const state = useSessionStore.getState();
  const lastMsg = state.messages[state.messages.length - 1];

  if (!lastMsg || lastMsg.role !== "assistant" || !lastMsg.isStreaming) {
    const msg: Message = {
      id: nextMessageId(),
      role: "assistant",
      content: "",
      toolCalls: [],
      thinking: "",
      isStreaming: true,
    };
    useSessionStore.setState({ messages: [...state.messages, msg] });
  }
}

function updateLastAssistantMessage(
  updater: (msg: Message) => Message
): void {
  useSessionStore.setState((state) => {
    const msgs = [...state.messages];
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === "assistant") {
        msgs[i] = updater(msgs[i]);
        break;
      }
    }
    return { messages: msgs };
  });
}

function handleUserMessage(payload: Record<string, unknown>) {
  const content = (payload.content as string) || (payload.text as string) || "";
  const msg: Message = {
    id: nextMessageId(),
    role: "user",
    content,
    toolCalls: [],
    thinking: "",
    isStreaming: false,
  };
  useSessionStore.setState((state) => ({
    messages: [...state.messages, msg],
  }));
}

function handleDelta(payload: Record<string, unknown>) {
  getOrCreateAssistantMessage();
  const delta = payload.delta as string;
  updateLastAssistantMessage((msg) => ({
    ...msg,
    content: msg.content + delta,
  }));
}

function handleToolCall(payload: Record<string, unknown>) {
  getOrCreateAssistantMessage();
  const toolCall: ToolCall = {
    callId: payload.call_id as string,
    name: payload.tool_name as string,
    arguments: (payload.arguments as Record<string, unknown>) || {},
    status: "running",
  };
  updateLastAssistantMessage((msg) => ({
    ...msg,
    toolCalls: [...msg.toolCalls, toolCall],
  }));
}

function handleToolResult(payload: Record<string, unknown>) {
  const callId = payload.call_id as string;
  updateLastAssistantMessage((msg) => ({
    ...msg,
    toolCalls: msg.toolCalls.map((tc) =>
      tc.callId === callId
        ? { ...tc, status: "completed" as const, result: payload.result }
        : tc
    ),
  }));
}

function handleReactStep(payload: Record<string, unknown>) {
  if (payload.phase === "thought") {
    getOrCreateAssistantMessage();
    const content = payload.content as string;
    updateLastAssistantMessage((msg) => ({
      ...msg,
      thinking: msg.thinking + (msg.thinking ? "\n" : "") + content,
    }));
  }
}

function handleTurnCompleted() {
  updateLastAssistantMessage((msg) => ({
    ...msg,
    isStreaming: false,
  }));
}

function handleRequestFailed(payload: Record<string, unknown>) {
  getOrCreateAssistantMessage();
  updateLastAssistantMessage((msg) => ({
    ...msg,
    content: msg.content || `Error: ${payload.error || "Request failed"}`,
    isStreaming: false,
  }));
}
