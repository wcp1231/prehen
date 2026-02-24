import { useEffect, useCallback } from "react";
import { useSessionStore } from "../stores/sessionStore";
import ChatView from "./ChatView";
import MessageInput from "./MessageInput";

interface SessionPageProps {
  sessionId: string;
  onBack: () => void;
}

export default function SessionPage({ sessionId, onBack }: SessionPageProps) {
  const { messages, status, error, restoreAndConnect, disconnect, submitMessage } =
    useSessionStore();

  useEffect(() => {
    restoreAndConnect(sessionId);
    return () => {
      disconnect();
    };
  }, [sessionId, restoreAndConnect, disconnect]);

  const handleSubmit = useCallback(
    (text: string) => {
      submitMessage(text);
    },
    [submitMessage]
  );

  const isStreaming = messages.some((m) => m.isStreaming);
  const canSubmit = status === "connected" || status === "reconnecting";
  const inputDisabled = !canSubmit || isStreaming;

  return (
    <div className="session-page">
      <div className="session-header">
        <button className="btn btn-back" onClick={onBack}>
          ← Back
        </button>
        <span className="session-id">Session: {sessionId.slice(0, 8)}...</span>
        <span className={`connection-status connection-status--${status}`}>
          {status}
        </span>
      </div>

      {error && <div className="session-error">{error}</div>}

      <div className="session-body">
        <ChatView messages={messages} />
      </div>

      <div className="session-footer">
        <MessageInput onSubmit={handleSubmit} disabled={inputDisabled} />
      </div>
    </div>
  );
}
