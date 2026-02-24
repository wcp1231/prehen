import { Socket } from "phoenix";

let socket: Socket | null = null;

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {
      params: {},
    });
    socket.connect();
  }
  return socket;
}

export function disconnectSocket(): void {
  if (socket) {
    socket.disconnect();
    socket = null;
  }
}
