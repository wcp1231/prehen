import { useState } from "react";

interface ThinkingBlockProps {
  thinking: string;
}

export default function ThinkingBlock({ thinking }: ThinkingBlockProps) {
  const [expanded, setExpanded] = useState(false);

  if (!thinking) return null;

  return (
    <div className="thinking-block">
      <button
        className="thinking-toggle"
        onClick={() => setExpanded((v) => !v)}
      >
        <span className="thinking-icon">{expanded ? "▾" : "▸"}</span>
        Thinking
      </button>
      {expanded && <pre className="thinking-content">{thinking}</pre>}
    </div>
  );
}
