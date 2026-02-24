declare module "phoenix" {
  export interface SocketOpts {
    params?: Record<string, unknown> | (() => Record<string, unknown>);
    timeout?: number;
    heartbeatIntervalMs?: number;
    reconnectAfterMs?: (tries: number) => number;
    longpollerTimeout?: number;
    encode?: (payload: unknown, callback: (encoded: string) => void) => void;
    decode?: (payload: string, callback: (decoded: unknown) => void) => void;
    logger?: (kind: string, msg: string, data: unknown) => void;
    transport?: unknown;
    binaryType?: string;
    vsn?: string;
  }

  export class Socket {
    constructor(endPoint: string, opts?: SocketOpts);
    connect(): void;
    disconnect(callback?: () => void, code?: number, reason?: string): void;
    channel(topic: string, chanParams?: Record<string, unknown> | (() => Record<string, unknown>)): Channel;
    onOpen(callback: () => void): void;
    onClose(callback: (event: unknown) => void): void;
    onError(callback: (error: unknown) => void): void;
    isConnected(): boolean;
    connectionState(): string;
    log(kind: string, msg: string, data?: unknown): void;
  }

  export interface Push {
    receive(status: string, callback: (response: unknown) => void): Push;
  }

  export class Channel {
    constructor(topic: string, params: Record<string, unknown> | (() => Record<string, unknown>), socket: Socket);
    join(timeout?: number): Push;
    leave(timeout?: number): Push;
    push(event: string, payload: Record<string, unknown>, timeout?: number): Push;
    on(event: string, callback: (payload: unknown) => void): number;
    off(event: string, ref?: number): void;
    onError(callback: (reason?: unknown) => void): void;
    onClose(callback: (payload?: unknown, ref?: unknown, joinRef?: unknown) => void): void;
    readonly topic: string;
    readonly state: string;
  }

  export class Presence {
    constructor(channel: Channel, opts?: Record<string, unknown>);
    onJoin(callback: (key: string, currentPresence: unknown, newPresence: unknown) => void): void;
    onLeave(callback: (key: string, currentPresence: unknown, leftPresence: unknown) => void): void;
    onSync(callback: () => void): void;
    list<T>(chooser?: (key: string, presence: unknown) => T): T[];
    static syncState(currentState: unknown, newState: unknown, onJoin?: unknown, onLeave?: unknown): unknown;
    static syncDiff(currentState: unknown, diff: unknown, onJoin?: unknown, onLeave?: unknown): unknown;
    static list<T>(presences: unknown, chooser?: (key: string, presence: unknown) => T): T[];
  }
}
