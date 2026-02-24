import { useEffect, useRef } from "react";
import type { Message } from "../stores/sessionStore";
import ThinkingBlock from "./ThinkingBlock";
import ToolViewer from "./ToolViewer";

interface ChatViewProps {
  messages: Message[];
}

export default function ChatView({ messages }: ChatViewProps) {
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  if (messages.length === 0) {
    return (
      <div className="chat-empty">
        <p>No messages yet. Start a conversation below.</p>
      </div>
    );
  }

  return (
    <div className="chat-view">
      {messages.map((msg) => (
        <div key={msg.id} className={`chat-message chat-message--${msg.role}`}>
          <div className="chat-message-role">
            {msg.role === "user" ? "You" : "Assistant"}
          </div>

          {msg.thinking && <ThinkingBlock thinking={msg.thinking} />}

          {msg.content && (
            <div className="chat-message-content">
              {msg.content}
              {msg.isStreaming && <span className="streaming-cursor" />}
            </div>
          )}

          {msg.toolCalls.length > 0 && (
            <div className="chat-message-tools">
              {msg.toolCalls.map((tc) => (
                <ToolViewer key={tc.callId} toolCall={tc} />
              ))}
            </div>
          )}
        </div>
      ))}
      <div ref={bottomRef} />
    </div>
  );
}
